#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# configuration
# ============================================================

MAIN="$(pwd)"
TOOLCHAIN="$MAIN/toolchain"
ROOTFS="$MAIN/rootfs"
SOURCES="$MAIN/sources"

CCACHE_DIR="${CCACHE_DIR:-$MAIN/.ccache}"

BINUTILS_VER="2.46.0"
GCC_VER="16.2.0"
GLIBC_VER="2.42"
LINUX_VER="7.2.3"
COREUTILS_VER="9.11"
LIBCAP_VER="2.78"
BASH_VER="5.3"
SYSTEMD_VER="261.3"
LESS_VER="704"
WHICH_VER="2.25"
FILE_VER="5.45"
GREP_VER="3.12"
SED_VER="4.10"
GAWK_VER="5.4.0"
TAR_VER="1.35"
GZIP_VER="1.14"
XZ_VER="5.8.3"
FINDUTILS_VER="4.11.0"
NCURSES_VER="6.6"
PAM_VER="1.7.2"
UTIL_LINUX_VER="2.42.3"
LIBXCRYPT_VER="4.5.2"

TARGET="x86_64-nixie-linux-gnu"

# default: clean everything
CLEAN=1

# default: dont download (if skipping)
DOWNLOAD=0

# default: build from the beginning
SKIP_TO=""

# ============================================================
# argument parsing
# ============================================================

usage() {
    cat <<EOF2
usage: $0 [options]

options:
  --no-clean              preserve the existing toolchain and rootfs
  --clean                 remove toolchain and rootfs before building
  --skip-to <step>        skip directly to a build step
  -h, --help              show this help
  --download              still download + extract even if skip is on. really recommended for me

steps:
  download
  extract
  linux-headers
  binutils
  gcc-bootstrap
  glibc-headers
  bootstrap-libgcc
  glibc
  gcc
  coreutils
  bash
  libcap
  systemd-deps
  systemd
  rootfs
  sanity
  packages

examples:
  $0
  $0 --no-clean
  $0 --no-clean --skip-to systemd
  $0 --no-clean --skip-to rootfs
  $0 --no-clean --skip-to gcc
  $0 --no-clean --skip-to packages --download
EOF2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-clean)
            CLEAN=0
            shift
            ;;

        --clean)
            CLEAN=1
            shift
            ;;
        
        --download)
            DOWNLOAD=1
            shift
            ;;

        --skip-to)
            if [ "$#" -lt 2 ]; then
                echo "error: --skip-to requires a step name" >&2
                usage
                exit 1
            fi

            SKIP_TO="$2"
            shift 2
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            echo "error: unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

VALID_STEPS=(
    download
    extract
    linux-headers
    binutils
    gcc-bootstrap
    glibc-headers
    bootstrap-libgcc
    glibc
    gcc
    coreutils
    bash
    libcap
    systemd-deps
    systemd
    rootfs
    sanity
    packages
    flavor
)

START_INDEX=0

if [ -n "$SKIP_TO" ]; then
    found_step=0

    for i in "${!VALID_STEPS[@]}"; do
        if [ "${VALID_STEPS[$i]}" = "$SKIP_TO" ]; then
            START_INDEX="$i"
            found_step=1
            break
        fi
    done

    if [ "$found_step" -ne 1 ]; then
        echo "error: unknown step: $SKIP_TO" >&2
        echo
        usage
        exit 1
    fi
fi

CURRENT_INDEX=0

should_run() {
    [ "$CURRENT_INDEX" -ge "$START_INDEX" ]
}

next_step() {
    CURRENT_INDEX=$((CURRENT_INDEX + 1))
}

# ============================================================
# colors / logging
# ============================================================

RESET='\033[0m'
LOG_PREFIX_COLOR='\033[1;36m'
LOG_TEXT_COLOR='\033[0;37m'
LOG_ERROR_COLOR='\033[1;31m'

log() {
    printf '%b==>%b %b%s%b\n' \
        "$LOG_PREFIX_COLOR" \
        "$RESET" \
        "$LOG_TEXT_COLOR" \
        "$*" \
        "$RESET"
}

log_error() {
    printf '%berror:%b %s\n' \
        "$LOG_ERROR_COLOR" \
        "$RESET" \
        "$*"
}

# ============================================================
# configuration summary
# ============================================================

log "nixie linux bootstrap"

if [ "$EUID" != "0" ]; then
    log_error "This script should be ran as root."
    exit 1
fi

if [ "$CLEAN" -eq 1 ]; then
    log "clean build: yes"
else
    log "clean build: no"
fi

if [ -n "$SKIP_TO" ]; then
    log "starting from step: $SKIP_TO"
else
    log "starting from step: download"
fi

echo

# ============================================================
# host prerequisites
# ============================================================

for tool in ccache meson ninja gcc g++ make curl pkg-config gperf python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_error "$tool is required."
        echo "install it with your distro's package manager first."
        exit 1
    fi
done

if ! python3 - <<'PY'
import jinja2
PY
then
    log_error "python3-jinja2 is required to build systemd."
    echo "install the jinja2 Python package with your distro's package manager first."
    exit 1
fi

mkdir -p "$CCACHE_DIR"

export CCACHE_DIR
export CCACHE_BASEDIR="$MAIN"
export CCACHE_COMPILERCHECK=content

# host-side compilation
export HOSTCC="ccache gcc"
export HOSTCXX="ccache g++"

log "ccache:"
ccache --version | head -n 1
log "ccache dir: $CCACHE_DIR"
echo

# ============================================================
# cleanup
# ============================================================

if [ "$CLEAN" -eq 1 ]; then
    log "clearing previous toolchain and rootfs"

    rm -rf "$TOOLCHAIN" "$ROOTFS"
else
    log "preserving existing toolchain and rootfs"
fi

mkdir -p \
    "$TOOLCHAIN/src" \
    "$TOOLCHAIN/build" \
    "$TOOLCHAIN/bin" \
    "$ROOTFS/usr" \
    "$SOURCES"

export PATH="$TOOLCHAIN/bin:$PATH"

# ============================================================
# download helper
# ============================================================

download() {
    local url="$1"
    local file="$2"

    if [ -f "$SOURCES/$file" ]; then
        log "already downloaded: $file"
        return
    fi

    log "downloading $file..."
    curl -fL --retry 3 -o "$SOURCES/$file" "$url"
}

build_autotools_package() {
        local name="$1"
        local src="$2"
        shift 2

        log "building ${name}..."
        cd "$TOOLCHAIN/build"
        rm -rf "$name"
        mkdir "$name"
        cd "$name"

        "$src/configure" \
            --build="$BUILD" \
            --host="$TARGET" \
            --prefix=/usr \
            --disable-nls \
            "$@"

        make -j"$(nproc)"
        make DESTDIR="$ROOTFS" install
    }

# ============================================================
# download
# ============================================================

if should_run || [ $DOWNLOAD -ge 1 ]; then
    log "downloading sources"

    download \
        "https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz" \
        "binutils-${BINUTILS_VER}.tar.xz"

    download \
        "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz" \
        "gcc-${GCC_VER}.tar.xz"

    download \
        "https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VER}.tar.xz" \
        "glibc-${GLIBC_VER}.tar.xz"

    download \
        "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${LINUX_VER}.tar.xz" \
        "linux-${LINUX_VER}.tar.xz"

    download \
        "https://ftp.gnu.org/gnu/coreutils/coreutils-${COREUTILS_VER}.tar.xz" \
        "coreutils-${COREUTILS_VER}.tar.xz"

    download \
        "https://www.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-${LIBCAP_VER}.tar.xz" \
        "libcap-${LIBCAP_VER}.tar.xz"

    download \
        "https://ftp.gnu.org/gnu/bash/bash-${BASH_VER}.tar.gz" \
        "bash-${BASH_VER}.tar.gz"

    download \
        "https://github.com/systemd/systemd/archive/refs/tags/v${SYSTEMD_VER}.tar.gz" \
        "systemd-${SYSTEMD_VER}.tar.gz"

    download \
        "https://mirror.metanet.ch/gnu/less/less-${LESS_VER}.tar.gz" \
        "less-${LESS_VER}.tar.gz"

    download \
        "https://ftp.gnu.org/gnu/which/which-${WHICH_VER}.tar.gz" \
        "which-${WHICH_VER}.tar.gz"

    download \
        "https://ftp.funet.fi/pub/mirrors/ftp.astron.com/pub/file/file-${FILE_VER}.tar.gz" \
        "file-${FILE_VER}.tar.gz"

    download \
        "https://ftp.gnu.org/gnu/grep/grep-${GREP_VER}.tar.xz" \
        "grep-${GREP_VER}.tar.xz"

    download \
        "https://ftp.gnu.org/gnu/sed/sed-${SED_VER}.tar.xz" \
        "sed-${SED_VER}.tar.xz"

    download \
        "https://ftp.gnu.org/gnu/gawk/gawk-${GAWK_VER}.tar.xz" \
        "gawk-${GAWK_VER}.tar.xz"

    download \
        "https://ftp.gnu.org/gnu/tar/tar-${TAR_VER}.tar.xz" \
        "tar-${TAR_VER}.tar.xz"

    download \
        "https://ftp.gnu.org/gnu/gzip/gzip-${GZIP_VER}.tar.xz" \
        "gzip-${GZIP_VER}.tar.xz"

    download \
        "https://tukaani.org/xz/xz-${XZ_VER}.tar.gz" \
        "xz-${XZ_VER}.tar.gz"

    download \
        "https://ftp.gnu.org/gnu/findutils/findutils-${FINDUTILS_VER}.tar.xz" \
        "findutils-${FINDUTILS_VER}.tar.xz"

    download \
        "https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz" \
        "ncurses-${NCURSES_VER}.tar.gz"

    download \
        "https://github.com/linux-pam/linux-pam/releases/download/v${PAM_VER}/Linux-PAM-${PAM_VER}.tar.xz" \
        "Linux-PAM-${PAM_VER}.tar.xz"

    download \
        "https://www.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-${UTIL_LINUX_VER}.tar.xz" \
        "util-linux-${UTIL_LINUX_VER}.tar.xz"
    
    download \
        "https://github.com/besser82/libxcrypt/releases/download/v${LIBXCRYPT_VER}/libxcrypt-${LIBXCRYPT_VER}.tar.xz" \
        "libxcrypt-${LIBXCRYPT_VER}.tar.xz"
fi

next_step

# ============================================================
# extract
# ============================================================

if should_run || [ $DOWNLOAD -ge 1 ]; then
    log "extracting sources..."

    cd "$TOOLCHAIN/src"

    log "extract $SOURCES/binutils-${BINUTILS_VER}.tar.xz"
    tar -xf "$SOURCES/binutils-${BINUTILS_VER}.tar.xz"

    log "extract $SOURCES/gcc-${GCC_VER}.tar.xz"
    tar -xf "$SOURCES/gcc-${GCC_VER}.tar.xz"

    log "extract $SOURCES/glibc-${GLIBC_VER}.tar.xz"
    tar -xf "$SOURCES/glibc-${GLIBC_VER}.tar.xz"

    log "extract $SOURCES/linux-${LINUX_VER}.tar.xz"
    tar -xf "$SOURCES/linux-${LINUX_VER}.tar.xz"

    log "extract $SOURCES/coreutils-${COREUTILS_VER}.tar.xz"
    tar -xf "$SOURCES/coreutils-${COREUTILS_VER}.tar.xz"

    log "extract $SOURCES/libcap-${LIBCAP_VER}.tar.xz"
    tar -xf "$SOURCES/libcap-${LIBCAP_VER}.tar.xz"

    log "extract $SOURCES/bash-${BASH_VER}.tar.gz"
    tar -xf "$SOURCES/bash-${BASH_VER}.tar.gz"

    log "extract $SOURCES/systemd-${SYSTEMD_VER}.tar.gz"
    tar -xf "$SOURCES/systemd-${SYSTEMD_VER}.tar.gz"

    log "extract $SOURCES/less-${LESS_VER}.tar.gz"
    tar -xf "$SOURCES/less-${LESS_VER}.tar.gz"

    log "extract $SOURCES/which-${WHICH_VER}.tar.gz"
    tar -xf "$SOURCES/which-${WHICH_VER}.tar.gz"

    log "extract $SOURCES/file-${FILE_VER}.tar.gz"
    tar -xf "$SOURCES/file-${FILE_VER}.tar.gz"

    log "extract $SOURCES/grep-${GREP_VER}.tar.xz"
    tar -xf "$SOURCES/grep-${GREP_VER}.tar.xz"

    log "extract $SOURCES/sed-${SED_VER}.tar.xz"
    tar -xf "$SOURCES/sed-${SED_VER}.tar.xz"

    log "extract $SOURCES/gawk-${GAWK_VER}.tar.xz"
    tar -xf "$SOURCES/gawk-${GAWK_VER}.tar.xz"

    log "extract $SOURCES/tar-${TAR_VER}.tar.xz"
    tar -xf "$SOURCES/tar-${TAR_VER}.tar.xz"

    log "extract $SOURCES/gzip-${GZIP_VER}.tar.xz"
    tar -xf "$SOURCES/gzip-${GZIP_VER}.tar.xz"

    log "extract $SOURCES/xz-${XZ_VER}.tar.gz"
    tar -xf "$SOURCES/xz-${XZ_VER}.tar.gz"

    log "extract $SOURCES/findutils-${FINDUTILS_VER}.tar.xz"
    tar -xf "$SOURCES/findutils-${FINDUTILS_VER}.tar.xz"

    log "extract $SOURCES/ncurses-${NCURSES_VER}.tar.gz"
    tar -xf "$SOURCES/ncurses-${NCURSES_VER}.tar.gz"

    log "extract $SOURCES/Linux-PAM-${PAM_VER}.tar.xz"
    tar -xf "$SOURCES/Linux-PAM-${PAM_VER}.tar.xz"

    log "extract $SOURCES/util-linux-${UTIL_LINUX_VER}.tar.xz"
    tar -xf "$SOURCES/util-linux-${UTIL_LINUX_VER}.tar.xz"
   
    log "extract $SOURCES/libxcrypt-${LIBXCRYPT_VER}.tar.xz"
    tar -xf "$SOURCES/libxcrypt-${LIBXCRYPT_VER}.tar.xz"
fi

SYSTEMD_SRC="$TOOLCHAIN/src/systemd-${SYSTEMD_VER}"
LIBCAP_SRC="$TOOLCHAIN/src/libcap-${LIBCAP_VER}"
LESS_SRC="$TOOLCHAIN/src/less-${LESS_VER}"
WHICH_SRC="$TOOLCHAIN/src/which-${WHICH_VER}"
FILE_SRC="$TOOLCHAIN/src/file-${FILE_VER}"
GREP_SRC="$TOOLCHAIN/src/grep-${GREP_VER}"
SED_SRC="$TOOLCHAIN/src/sed-${SED_VER}"
GAWK_SRC="$TOOLCHAIN/src/gawk-${GAWK_VER}"
TAR_SRC="$TOOLCHAIN/src/tar-${TAR_VER}"
GZIP_SRC="$TOOLCHAIN/src/gzip-${GZIP_VER}"
XZ_SRC="$TOOLCHAIN/src/xz-${XZ_VER}"
FINDUTILS_SRC="$TOOLCHAIN/src/findutils-${FINDUTILS_VER}"
NCURSES_SRC="$TOOLCHAIN/src/ncurses-${NCURSES_VER}"
PAM_SRC="$TOOLCHAIN/src/Linux-PAM-${PAM_VER}"
UTIL_LINUX_SRC="$TOOLCHAIN/src/util-linux-${UTIL_LINUX_VER}"
LIBXCRYPT_SRC="$TOOLCHAIN/src/libxcrypt-${LIBXCRYPT_VER}"

next_step

# ============================================================
# gcc prerequisites
# ============================================================

if should_run; then
    log "downloading gcc prerequisites..."

    cd "$TOOLCHAIN/src/gcc-${GCC_VER}"
    ./contrib/download_prerequisites
fi

# don't count gcc prerequisites as a resume step
# ============================================================
# linux userspace headers
# ============================================================

if should_run; then
    log "installing linux headers..."

    mkdir -p "$ROOTFS/usr"

    cd "$TOOLCHAIN/src/linux-${LINUX_VER}"

    make ARCH=x86_64 \
        headers_install \
        INSTALL_HDR_PATH="$ROOTFS/usr"
fi

next_step

# ============================================================
# binutils
# ============================================================

if should_run; then
    log "building binutils..."

    cd "$TOOLCHAIN/build"

    rm -rf binutils
    mkdir binutils
    cd binutils

    "$TOOLCHAIN/src/binutils-${BINUTILS_VER}/configure" \
        --target="$TARGET" \
        --prefix="$TOOLCHAIN" \
        --with-sysroot="$ROOTFS" \
        --disable-nls \
        --disable-werror \
        --disable-multilib

    make -j"$(nproc)"
    make install
fi

next_step

# ============================================================
# bootstrap gcc
# ============================================================

if should_run; then
    log "building bootstrap gcc..."

    cd "$TOOLCHAIN/build"

    rm -rf gcc-bootstrap
    mkdir gcc-bootstrap
    cd gcc-bootstrap

    "$TOOLCHAIN/src/gcc-${GCC_VER}/configure" \
        --target="$TARGET" \
        --prefix="$TOOLCHAIN" \
        --with-sysroot="$ROOTFS" \
        --without-headers \
        --disable-nls \
        --disable-shared \
        --disable-threads \
        --disable-libssp \
        --disable-libquadmath \
        --disable-libvtv \
        --disable-libgomp \
        --disable-libatomic \
        --disable-multilib \
        --enable-languages=c

    make all-gcc -j"$(nproc)"
    make install-gcc
fi

next_step

# ============================================================
# glibc headers + startup objects
# ============================================================

if should_run; then
    log "installing glibc headers..."

    cd "$TOOLCHAIN/build"

    rm -rf glibc
    mkdir glibc
    cd glibc

    unset CXX
    unset CXXFLAGS

    "$TOOLCHAIN/src/glibc-${GLIBC_VER}/configure" \
        --prefix=/usr \
        --host="$TARGET" \
        --build="$(
            "$TOOLCHAIN/src/glibc-${GLIBC_VER}/scripts/config.guess"
        )" \
        --with-headers="$ROOTFS/usr/include" \
        --disable-werror \
        --disable-multilib \
        --disable-static-c++-tests \
        libc_cv_have_libgcc_s=no \
        libc_cv_forced_unwind=yes \
        libc_cv_c_cleanup=yes

    make install-bootstrap-headers=yes \
        install-headers \
        DESTDIR="$ROOTFS"

    make csu/subdir_lib

    mkdir -p "$ROOTFS/usr/lib"

    cp -v \
        csu/crt1.o \
        csu/crti.o \
        csu/crtn.o \
        "$ROOTFS/usr/lib/"

    touch "$ROOTFS/usr/include/gnu/stubs.h"
fi

next_step

# ============================================================
# bootstrap libgcc
# ============================================================

if should_run; then
    log "building bootstrap libgcc..."

    cd "$TOOLCHAIN/build/gcc-bootstrap"

    make all-target-libgcc -j"$(nproc)"
    make install-target-libgcc
fi

next_step

# ============================================================
# glibc libc
# ============================================================

if should_run; then
    log "building glibc..."

    cd "$TOOLCHAIN/build/glibc"

    export CC="${TARGET}-gcc"
    export CXX=""
    export AR="${TARGET}-ar"
    export RANLIB="${TARGET}-ranlib"
    export CFLAGS="-O2 -pipe"
    export CXXFLAGS=""

    make CXX= -j"$(nproc)"
    make install DESTDIR="$ROOTFS"

    unset CC
    unset AR
    unset RANLIB
fi

next_step

# ============================================================
# final gcc
# ============================================================

if should_run; then
    log "building final gcc..."

    cd "$TOOLCHAIN/build"

    rm -rf gcc
    mkdir gcc
    cd gcc

    "$TOOLCHAIN/src/gcc-${GCC_VER}/configure" \
        --target="$TARGET" \
        --prefix="$TOOLCHAIN" \
        --with-sysroot="$ROOTFS" \
        --enable-languages=c,c++ \
        --enable-shared \
        --enable-threads=posix \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-multilib

    make -j"$(nproc)"
    make install

    make all-target-libgcc -j"$(nproc)"
    make install-target-libgcc
fi

next_step

# ============================================================
# target build environment
# ============================================================

export CC="ccache ${TARGET}-gcc"
export CXX="ccache ${TARGET}-g++"
export AR="${TARGET}-ar"
export AS="${TARGET}-as"
export LD="${TARGET}-ld"
export NM="${TARGET}-nm"
export OBJCOPY="${TARGET}-objcopy"
export OBJDUMP="${TARGET}-objdump"
export RANLIB="${TARGET}-ranlib"
export READELF="${TARGET}-readelf"
export STRIP="${TARGET}-strip"

export CFLAGS="-O2 -pipe"
export CXXFLAGS="-O2 -pipe"

BUILD="$(gcc -dumpmachine)"

# ============================================================
# usr-merge rootfs layout
# ============================================================

# systemd requires a merged /usr filesystem. Keep the compatibility
# symlinks so the early userspace still sees the traditional paths.
ensure_usr_merge() {
    mkdir -p \
        "$ROOTFS/usr/bin" \
        "$ROOTFS/usr/sbin" \
        "$ROOTFS/usr/lib" \
        "$ROOTFS/usr/libexec" \
        "$ROOTFS/etc" \
        "$ROOTFS/var" \
        "$ROOTFS/run"

    ln -sfn usr/bin "$ROOTFS/bin"
    ln -sfn usr/bin "$ROOTFS/sbin"
    ln -sfn usr/lib "$ROOTFS/lib"

    if [ -d "$ROOTFS/usr/lib64" ]; then
        ln -sfn usr/lib64 "$ROOTFS/lib64"
    else
        mkdir -p "$ROOTFS/usr/lib64"
        ln -sfn usr/lib64 "$ROOTFS/lib64"
    fi
}

ensure_usr_merge

# ============================================================
# coreutils
# ============================================================

if should_run; then
    log "building coreutils..."

    cd "$TOOLCHAIN/build"

    rm -rf coreutils
    mkdir coreutils
    cd coreutils

    "$TOOLCHAIN/src/coreutils-${COREUTILS_VER}/configure" \
        --build="$BUILD" \
        --host="$TARGET" \
        --prefix=/usr \
        --disable-nls \
        --disable-libcap \
        --without-selinux

    make -j"$(nproc)"

    make DESTDIR="$ROOTFS" \
        install
fi

next_step

# ============================================================
# bash
# ============================================================

if should_run; then
    log "building bash..."

    cd "$TOOLCHAIN/build"
    rm -rf bash
    mkdir bash
    cd bash

    "$TOOLCHAIN/src/bash-${BASH_VER}/configure" \
        --build="$BUILD" \
        --host="$TARGET" \
        --prefix=/usr \
        --bindir=/usr/bin \
        --without-bash-malloc \
        --disable-nls

    make -j"$(nproc)"

    make DESTDIR="$ROOTFS" \
        install

    ln -sfn bash "$ROOTFS/usr/bin/sh"
fi

next_step

# ============================================================
# libcap
# ============================================================

if should_run; then
    log "building libcap..."

    cd "$LIBCAP_SRC"

    make clean >/dev/null 2>&1 || true

    make -j"$(nproc)" \
        CC="ccache ${TARGET}-gcc" \
        BUILD_CC="ccache gcc" \
        AR="${TARGET}-ar" \
        RANLIB="${TARGET}-ranlib" \
        CFLAGS="-O2 -pipe -fPIC" \
        BUILD_CFLAGS="-O2 -pipe"

    make install \
        DESTDIR="$ROOTFS" \
        prefix=/usr

    log "libcap installed into target rootfs."

    echo

    log "creating target pkg-config wrapper..."

    cat > "$TOOLCHAIN/bin/${TARGET}-pkg-config" <<EOF2
#!/usr/bin/env bash

export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"

export PKG_CONFIG_LIBDIR="$ROOTFS/usr/lib64/pkgconfig:$ROOTFS/usr/lib/pkgconfig:$ROOTFS/usr/share/pkgconfig"

export PKG_CONFIG_PATH="$ROOTFS/usr/lib64/pkgconfig:$ROOTFS/usr/lib/pkgconfig:$ROOTFS/usr/share/pkgconfig"

exec /usr/bin/pkg-config "\$@"
EOF2

    chmod +x "$TOOLCHAIN/bin/${TARGET}-pkg-config"
fi

next_step

# ============================================================
# systemd dependencies
# ============================================================

if should_run; then
 
    cd "$TOOLCHAIN/build"
    rm -rf ncurses-wide
    mkdir ncurses-wide
    cd ncurses-wide

    "$NCURSES_SRC/configure" \
        --build="$BUILD" \
        --host="$TARGET" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --with-shared \
        --without-debug \
        --without-ada \
        --with-build-cc="$HOSTCC" \
        --enable-widec \
        --enable-pc-files \
        --with-termlib=tinfo \
        --disable-stripping

    make -j"$(nproc)"
    make DESTDIR="$ROOTFS" install

    # ============================================================
    # libxcrypt
    # ============================================================

    log "building libxcrypt ${LIBXCRYPT_VER}..."

    cd "$TOOLCHAIN/build"
    rm -rf libxcrypt
    mkdir libxcrypt
    cd libxcrypt

    "$LIBXCRYPT_SRC/configure" \
        --build="$BUILD" \
        --host="$TARGET" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --enable-shared \
        --disable-static

    make -j"$(nproc)"

    make DESTDIR="$ROOTFS" install

    log "libxcrypt installed into target rootfs."
    
    # Linux-PAM 1.7.x uses Meson. Optional integrations stay disabled here.
    log "building linux-pam ${PAM_VER}..."
    cd "$TOOLCHAIN/build"
    rm -rf linux-pam

    cat > "$TOOLCHAIN/build/pam-cross.txt" <<EOF2
[binaries]
c = ['ccache', '${TARGET}-gcc']
cpp = ['ccache', '${TARGET}-g++']
ar = '${TARGET}-ar'
strip = '${TARGET}-strip'
pkg-config = '${TARGET}-pkg-config'

[properties]
sys_root = '$ROOTFS'
needs_exe_wrapper = true

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF2

    meson setup linux-pam \
        "$PAM_SRC" \
        --cross-file "$TOOLCHAIN/build/pam-cross.txt" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --sysconfdir=/etc \
        --buildtype=release \
        -Ddocs=disabled \
        -Dselinux=disabled \
        -Daudit=disabled \
        -Dopenssl=disabled \
        -Dpam_lastlog=disabled

    meson compile -C linux-pam -j"$(nproc)"
    DESTDIR="$ROOTFS" meson install -C linux-pam

    mkdir -p \
        "$ROOTFS/etc/pam.d" \
        "$ROOTFS/etc/security" \
        "$ROOTFS/usr/lib/security"
        

    log "patching util-linux ${UTIL_LINUX_VER}! (https://kernel.googlesource.com/pub/scm/utils/util-linux/util-linux.git/%2B/7e2e010874b10b3aabdc3c4c844c9ffc46a4a374)"
    cd "$UTIL_LINUX_SRC"
    # fix hook_idmap.c
	sed -i '/#include "all-io.h"/a #include "fileutils.h"' \
	    libmount/src/hook_idmap.c

	# fix fileutils.h so it gets the real kernel definitions
	sed -i '/#include <sys\/stat.h>/a\
	#ifdef HAVE_LINUX_OPENAT2_H\
	# include <linux/openat2.h>\
	#endif' \
	    include/fileutils.h

	# fix the incorrect fallback in 2.42.3
	sed -i 's/# define RESOLVE_NO_SYMLINKS[[:space:]]*0x02/# define RESOLVE_NO_SYMLINKS 0x04/' \
	    include/fileutils.h
    # util-linux is last because it can use both ncurses and PAM.
    build_autotools_package "util-linux" "$UTIL_LINUX_SRC" \
        --libdir=/usr/lib64 \
        --bindir=/usr/bin \
        --sbindir=/usr/sbin \
        --enable-shared \
        --enable-libmount \
        --enable-libblkid \
        --enable-libsmartcols \
        --enable-libuuid \
        --enable-pam \
        --without-python \
        --without-btrfs \
        --without-selinux \
        --without-audit \
        --without-cryptsetup \
        --without-zstd \
        --without-bzip2
fi

# ============================================================
# systemd
# ============================================================

if should_run; then 
    log "building systemd ${SYSTEMD_VER}..."
    
    cd "$TOOLCHAIN/build"

    rm -rf systemd

    cat > "$TOOLCHAIN/build/systemd-cross.txt" <<EOF2
[binaries]
c = ['ccache', '${TARGET}-gcc']
cpp = ['ccache', '${TARGET}-g++']
ar = '${TARGET}-ar'
strip = '${TARGET}-strip'
pkg-config = '${TARGET}-pkg-config'

[properties]
sys_root = '$ROOTFS'
needs_exe_wrapper = true

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF2

    meson setup systemd \
        "$SYSTEMD_SRC" \
        --cross-file "$TOOLCHAIN/build/systemd-cross.txt" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --libexecdir=/usr/lib/systemd \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --buildtype=release \
        -Dmode=release \
        -Dlibc=glibc \
        -Dinitrd=true \
        -Dlogind=true \
        -Dnetworkd=true \
        -Dresolve=true \
        -Dtimesyncd=true \
        -Dhostnamed=true \
        -Dlocaled=true \
        -Dmachined=true \
        -Dtimedated=true \
        -Dcoredump=true \
        -Doomd=true \
        -Dnspawn=enabled \
        -Dsysusers=true \
        -Dtmpfiles=true \
        -Dhwdb=true \
        -Drfkill=true \
        -Denvironment-d=true \
        -Dbinfmt=true \
        -Dfirstboot=true \
        -Drandomseed=true \
        -Dvconsole=true \
        -Dbacklight=true \
        -Dnss-systemd=true \
        -Dnss-myhostname=true \
        -Dnss-resolve=enabled \
        -Djournal-storage-default=persistent \
        -Dcreate-log-dirs=true \
        -Dman=disabled \
        -Dhtml=disabled \
        -Dtranslations=false \
        -Dbootloader=disabled \
        -Defi=false \
        -Dtpm=false \
        -Dlibmount=enabled \
        -Dblkid=enabled \
        -Dfdisk=disabled \
        -Dkmod=disabled \
        -Dpam=enabled \
        -Dacl=disabled \
        -Daudit=disabled \
        -Dlibcryptsetup=disabled \
        -Dopenssl=disabled \
        -Dgnutls=disabled \
        -Dlibidn2=disabled \
        -Dpcre2=disabled \
        -Dzlib=disabled \
        -Dbzip2=disabled \
        -Dxz=disabled \
        -Dlz4=disabled \
        -Dzstd=disabled \
        -Delfutils=disabled \
        -Dlibarchive=disabled \
        -Dbpf-framework=disabled

    meson compile \
        -C systemd \
        -j"$(nproc)"

    DESTDIR="$ROOTFS" \
        meson install \
        -C systemd
fi

next_step

# ============================================================
# rootfs setup
# ============================================================

if should_run; then
    log "creating systemd rootfs directories..."

    mkdir -p \
        "$ROOTFS/dev" \
        "$ROOTFS/proc" \
        "$ROOTFS/sys" \
        "$ROOTFS/run" \
        "$ROOTFS/tmp" \
        "$ROOTFS/var" \
        "$ROOTFS/var/log" \
        "$ROOTFS/var/log/journal" \
        "$ROOTFS/var/run" \
        "$ROOTFS/etc" \
        "$ROOTFS/etc/systemd" \
        "$ROOTFS/etc/systemd/system" \
        "$ROOTFS/etc/systemd/network" \
        "$ROOTFS/etc/udev/rules.d" \
        "$ROOTFS/etc/sysusers.d" \
        "$ROOTFS/etc/tmpfiles.d"

    chmod 1777 "$ROOTFS/tmp"

    # machine-id may be generated on first boot. An empty file is valid
    # for the initial rootfs and keeps systemd from trying to mutate the
    # build host's machine-id.
    : > "$ROOTFS/etc/machine-id"

    # /var/run is the traditional spelling; systemd uses /run.
    ln -sfn /run "$ROOTFS/var/run"

    # systemd as PID 1.
    if [ -x "$ROOTFS/usr/lib/systemd/systemd" ]; then
        ln -sfn /usr/lib/systemd/systemd "$ROOTFS/sbin/init"
    else
        log_error "systemd binary was not installed."
        exit 1
    fi

    # Do not forcibly replace existing /bin, /sbin, /lib or /lib64
    # directories here.  A bootstrap rootfs may already contain real
    # directories, and `ln -sfn` does not safely merge/replace them.
    #
    # systemd itself is installed under /usr, while the glibc bootstrap
    # may place the dynamic loader under /lib64.
fi

next_step

# ============================================================
# glibc dynamic loader sanity
# ============================================================

if should_run; then
    log "checking glibc dynamic loader..."

    if [ -e "$ROOTFS/lib64/ld-linux-x86-64.so.2" ]; then
        log "glibc dynamic loader installed in /lib64."

    elif [ -e "$ROOTFS/lib/ld-linux-x86-64.so.2" ]; then
        log "glibc dynamic loader installed in /lib."

    elif [ -e "$ROOTFS/usr/lib64/ld-linux-x86-64.so.2" ]; then
        log "glibc dynamic loader installed in /usr/lib64."

    elif [ -e "$ROOTFS/usr/lib/ld-linux-x86-64.so.2" ]; then
        log "glibc dynamic loader installed in /usr/lib."

    else
        log_error "glibc dynamic loader was not found."
        log_error "checked /lib64, /lib, /usr/lib64 and /usr/lib."
        exit 1
    fi
fi

# ============================================================
# sanity checks
# ============================================================

if should_run; then
    log "running systemd component sanity checks..."

    required_bins=(
        "$ROOTFS/usr/lib/systemd/systemd"
        "$ROOTFS/usr/lib/systemd/systemd-udevd"
        "$ROOTFS/usr/lib/systemd/systemd-logind"
        "$ROOTFS/usr/lib/systemd/systemd-networkd"
        "$ROOTFS/usr/lib/systemd/systemd-resolved"
        "$ROOTFS/usr/lib/systemd/systemd-timesyncd"
        "$ROOTFS/usr/lib/systemd/systemd-journald"
        "$ROOTFS/usr/bin/systemctl"
        "$ROOTFS/usr/bin/journalctl"
        "$ROOTFS/usr/bin/loginctl"
        "$ROOTFS/usr/bin/udevadm"
        "$ROOTFS/usr/bin/networkctl"
        "$ROOTFS/usr/bin/busctl"
    )

    for binary in "${required_bins[@]}"; do
        if [ ! -e "$binary" ]; then
            log_error "missing systemd component: $binary"
            exit 1
        fi
    done

    if [ ! -L "$ROOTFS/sbin/init" ]; then
        log_error "/sbin/init is not a symlink to systemd."
        exit 1
    fi

    log "systemd component checks passed."
fi

# ============================================================
# nixie rootfs identity
# ============================================================

if should_run; then
    log "creating nixie os-release..."

    cat > "$ROOTFS/etc/os-release" <<'EOF'
NAME="Nixie Linux"
PRETTY_NAME="Nixie Linux"
ID=nixie
ID_LIKE=linux
VERSION_ID="rolling"
HOME_URL="https://example.com/"
EOF

    cat > "$ROOTFS/etc/hostname" <<'EOF'
nixie
EOF

    cat > "$ROOTFS/etc/issue" <<'EOF'
Nixie Linux \r (\l)
EOF

    cat > "$ROOTFS/etc/profile" <<'EOF'
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
export PS1='\[\e[1;35m\]nixie\[\e[0m\]@\[\e[1;36m\]\h\[\e[0m\]:\[\e[1;35m\]\w\[\e[0m\]\$ '
# ls / dircolors
if command -v dircolors >/dev/null 2>&1; then
    eval "$(dircolors -b)"
fi

alias ls='ls --color=auto'
alias ll='ls -lh --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'

# grep
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

# diff
if command -v diff >/dev/null 2>&1; then
    alias diff='diff --color=auto'
fi

# iproute2
if command -v ip >/dev/null 2>&1; then
    alias ip='ip --color=auto'
fi

# dmesg
if command -v dmesg >/dev/null 2>&1; then
    alias dmesg='dmesg --color=auto'
fi

# journalctl
if command -v journalctl >/dev/null 2>&1; then
    alias journalctl='journalctl --color=auto'
fi

# systemd
export SYSTEMD_COLORS=1

# git
if command -v git >/dev/null 2>&1; then
    git config --global color.ui auto 2>/dev/null || true
fi

# gcc diagnostic colors
export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# terminal color capability
export COLORTERM=truecolor
EOF

    # chroot does not start a login shell, so /etc/profile is not sourced
    # automatically. For an interactive shell, use: chroot "$ROOTFS" /bin/bash -il
fi
next_step

# ============================================================
# extra base packages
# ============================================================

if should_run; then
    log "building post-sanity base packages..."

    build_autotools_package "less" "$LESS_SRC" \
        --with-regex=posix

    build_autotools_package "which" "$WHICH_SRC"

    #build_autotools_package "file" "$FILE_SRC" \
    #    --disable-zlib \
    #    --disable-bzlib

    build_autotools_package "grep" "$GREP_SRC" \
        --without-included-regex

    build_autotools_package "sed" "$SED_SRC"

    build_autotools_package "gawk" "$GAWK_SRC" \
        --without-mpfr

    build_autotools_package "tar" "$TAR_SRC"

    build_autotools_package "gzip" "$GZIP_SRC"

    build_autotools_package "xz" "$XZ_SRC" \
        --disable-doc \
        --disable-scripts

    build_autotools_package "findutils" "$FINDUTILS_SRC" \
        --disable-locate
fi

next_step

# ============================================================
# cleanup environment
# ============================================================

unset CC
unset CXX
unset AR
unset AS
unset LD
unset NM
unset OBJCOPY
unset OBJDUMP
unset RANLIB
unset READELF
unset STRIP
unset CFLAGS
unset CXXFLAGS
unset PKG_CONFIG
unset PKG_CONFIG_PATH
unset PKG_CONFIG_LIBDIR
unset PKG_CONFIG_SYSROOT_DIR

log "Fixing permissions..."
username="${SUDO_USER:-$USER}"
log "chown -R "$username:$username" $ROOTFS"
sudo chown -R "$username:$username" $ROOTFS
log "chown -R "$username:$username" $TOOLCHAIN"
sudo chown -R "$username:$username" $TOOLCHAIN
log "chown -R "$username:$username" $SOURCES"
sudo chown -R "$username:$username" $SOURCES

echo
printf '%b=======================%b\n' \
    "$LOG_PREFIX_COLOR" \
    "$RESET"

printf '%b  bootstrap complete!%b\n' \
    "$LOG_TEXT_COLOR" \
    "$RESET"

printf '%b=======================%b\n' \
    "$LOG_PREFIX_COLOR" \
    "$RESET"
