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
DBUS_VER="1.16.2"
LESS_VER="704"
WHICH_VER="2.25"
FILE_VER="5.45"
GREP_VER="3.12"
SED_VER="4.10"
GAWK_VER="5.4.0"
TAR_VER="1.35"
GZIP_VER="1.14"
XZ_VER="5.8.3"
SHADOW_VER="4.20.2"
FINDUTILS_VER="4.11.0"
NCURSES_VER="6.6"
PAM_VER="1.7.2"
UTIL_LINUX_VER="2.42.3"
LIBXCRYPT_VER="4.5.2"
FASTFETCH_VER="2.68.1"
NETWORKMANAGER_VER="1.48.10"
LIBNDP_VER="1.9"
NETTLE_VER="3.10"
GNUTLS_VER="3.8.7.1"
GLIB_VER="2.82.2"
OPENSSL_VER="3.3.2"
GMP_VER="6.3.0"
LIBPSL_VER="0.21.5"
LIBIDN_VER="2.3.8"
LIBUNI_VER="1.4.1"
CURL_VER="8.10.1"
READLINE_VER="8.3"
NEWT_VER="0.52.24"
SLANG_VER="2.3.3"
POPT_VER="1.19"
KMOD_VER="34.2"
GDBM_VER="1.26"
PERL_VER="5.44.0"

# new build tools & man doc dependencies
M4_VER="1.4.19"
AUTOCONF_VER="2.72"
AUTOMAKE_VER="1.17"
LIBTOOL_VER="2.5.3"
MAKE_VER="4.4.1"
BISON_VER="3.8.2"
FLEX_VER="2.6.4"
PKGCONFIG_VER="0.29.2"
NINJA_VER="1.12.1"
MESON_VER="1.5.1"
TEXINFO_VER="7.3"
LIBPIPELINE_VER="1.5.8"
GROFF_VER="1.23.0"
MAN_DB_VER="2.13.0"
MAN_PAGES_VER="6.9"

TARGET="x86_64-nixie-linux-gnu"

NIXIE_LOG="$(pwd)/nixie.log"

# default: clean everything
CLEAN=1

# default: https://en.wikipedia.org/wiki/Verbose_mode
SILENT=0

# default: dont download (if skipping)
DOWNLOAD=0

# default: build from the beginning
SKIP_TO=""

alias make="make -s "

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
  --quieter               decreases amount of logs dumped into terminal. logs are saved to "$NIXIE_LOG"

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
  openssl
  gnutls
  systemd
  dbus
  shadow
  networkmanager-deps
  networkmanager
  rootfs
  sanity
  packages
  native-toolchain
  build-tools

examples:
  $0
  $0 --no-clean
  $0 --no-clean --skip-to systemd
  $0 --no-clean --skip-to rootfs
  $0 --no-clean --skip-to gcc
  $0 --no-clean --skip-to build-tools --download
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
        
        --quieter)
            export SILENT=1
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
    openssl
    gnutls
    systemd
    dbus
    shadow
    networkmanager-deps
    networkmanager
    rootfs
    sanity
    packages
    native-toolchain
    build-tools
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
    if [ "$SILENT" -eq 1 ]; then
        printf '==> %s\n' \
        "$*" >> ""$NIXIE_LOG""
    fi
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

log "build machine specifications:"
log "cpu:      $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)"
log "os:       $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")"
log "hostname: $(hostname)"
log "memory:   $(awk '/MemTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
log "storage:  $(df -h / | awk 'NR==2 {printf "%s total, %s available", $2, $4}')"

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

if [ "$SILENT" -eq 0 ]; then
    log "quieter: no"
    
else
    log "quieter: yes"
    export MAKEFLAGS="-s V=0 QUIET=1 VERBOSE=0"
fi

echo

# ============================================================
# host prerequisites
# ============================================================

for tool in ccache meson ninja gcc g++ make curl pkg-config gperf python3 bison flex makeinfo; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_error "$tool is required on host."
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

    # fix C23 / gcc 14+ K&R prototype errors on legacy gnulib host files
    if [ -f "$src/lib/malloc.c" ]; then
        sed -i 's/void \*malloc ();/void \*malloc (size_t);/' "$src/lib/malloc.c"
        log "patching lib/malloc.c"
    fi
    if [ -f "$src/lib/realloc.c" ]; then
        sed -i 's/void \*realloc ();/void \*realloc (void \*, size_t);/' "$src/lib/realloc.c"
        log "patching lib/realloc.c"
    fi
    if [ -f "$src/system.h" ]; then
        sed -i 's|extern char \*strerror ();|// extern char *strerror ();|' "$src/system.h"
    fi
    cd "$TOOLCHAIN/build"
    rm -rf "$name"
    mkdir "$name"
    cd "$name"

    export ac_cv_func_malloc_0_nonnull=yes
    export ac_cv_func_realloc_0_nonnull=yes
    export glib_cv_stack_grows=no
    export glib_cv_uscore=no 
    if [ "$SILENT" -eq 0 ]; then
        "$src/configure" \
            --build="$BUILD" \
            --host="$TARGET" \
            --prefix=/usr \
            --disable-nls \
            glib_cv_stack_grows=no \
            glib_cv_uscore=no \
            "$@"
        make -j"$(nproc)"
        make DESTDIR="$ROOTFS" install
     else
         unset MAKEFLAGS
         echo "=== CONFIGURE PACKAGE ${name} ===" >> "$NIXIE_LOG"
         "$src/configure" \
            --build="$BUILD" \
            --host="$TARGET" \
            --prefix=/usr \
            --disable-nls \
            glib_cv_stack_grows=no \
            glib_cv_uscore=no \
            "$@" >> "$NIXIE_LOG"
        echo "=== BUILD PACKAGE ${name} ===" >> "$NIXIE_LOG"
        make -j"$(nproc)" >> "$NIXIE_LOG"
        echo "=== INSTALL PACKAGE ${name} ===" >> "$NIXIE_LOG"
        make DESTDIR="$ROOTFS" install >> "$NIXIE_LOG"
        export MAKEFLAGS="-s V=0 QUIET=1 VERBOSE=0"
     fi
}
# ============================================================
# download
# ============================================================

if should_run || [ $DOWNLOAD -ge 1 ]; then
    log "downloading sources"

    download "https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VER}.tar.xz" "binutils-${BINUTILS_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz" "gcc-${GCC_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/glibc/glibc-${GLIBC_VER}.tar.xz" "glibc-${GLIBC_VER}.tar.xz"
    download "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${LINUX_VER}.tar.xz" "linux-${LINUX_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/coreutils/coreutils-${COREUTILS_VER}.tar.xz" "coreutils-${COREUTILS_VER}.tar.xz"
    download "https://www.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-${LIBCAP_VER}.tar.xz" "libcap-${LIBCAP_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/bash/bash-${BASH_VER}.tar.gz" "bash-${BASH_VER}.tar.gz"
    download "https://github.com/systemd/systemd/archive/refs/tags/v${SYSTEMD_VER}.tar.gz" "systemd-${SYSTEMD_VER}.tar.gz"
    download "https://mirror.metanet.ch/gnu/less/less-${LESS_VER}.tar.gz" "less-${LESS_VER}.tar.gz"
    download "https://ftp.gnu.org/gnu/which/which-${WHICH_VER}.tar.gz" "which-${WHICH_VER}.tar.gz"
    download "https://ftp.funet.fi/pub/mirrors/ftp.astron.com/pub/file/file-${FILE_VER}.tar.gz" "file-${FILE_VER}.tar.gz"
    download "https://ftp.gnu.org/gnu/grep/grep-${GREP_VER}.tar.xz" "grep-${GREP_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/sed/sed-${SED_VER}.tar.xz" "sed-${SED_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/gawk/gawk-${GAWK_VER}.tar.xz" "gawk-${GAWK_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/tar/tar-${TAR_VER}.tar.xz" "tar-${TAR_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/gzip/gzip-${GZIP_VER}.tar.xz" "gzip-${GZIP_VER}.tar.xz"
    download "https://tukaani.org/xz/xz-${XZ_VER}.tar.gz" "xz-${XZ_VER}.tar.gz"
    download "https://ftp.gnu.org/gnu/findutils/findutils-${FINDUTILS_VER}.tar.xz" "findutils-${FINDUTILS_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz" "ncurses-${NCURSES_VER}.tar.gz"
    download "https://github.com/linux-pam/linux-pam/releases/download/v${PAM_VER}/Linux-PAM-${PAM_VER}.tar.xz" "Linux-PAM-${PAM_VER}.tar.xz"
    download "https://www.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-${UTIL_LINUX_VER}.tar.xz" "util-linux-${UTIL_LINUX_VER}.tar.xz"
    download "https://github.com/besser82/libxcrypt/releases/download/v${LIBXCRYPT_VER}/libxcrypt-${LIBXCRYPT_VER}.tar.xz" "libxcrypt-${LIBXCRYPT_VER}.tar.xz"
    download "https://dbus.freedesktop.org/releases/dbus/dbus-${DBUS_VER}.tar.xz" "dbus-${DBUS_VER}.tar.xz"
    download "https://github.com/shadow-maint/shadow/releases/download/${SHADOW_VER}/shadow-${SHADOW_VER}.tar.xz" "shadow-${SHADOW_VER}.tar.xz"
    download "https://github.com/fastfetch-cli/fastfetch/releases/download/${FASTFETCH_VER}/fastfetch-linux-amd64.tar.gz" "fastfetch-${FASTFETCH_VER}.tar.gz"
    download "https://github.com/madnight/nano/archive/refs/heads/master.tar.gz" "nano-edge.tar.gz"
    download "https://gitlab.com/procps-ng/procps/-/archive/master/procps-master.tar.gz?ref_type=heads" "procps-ng-edge.tar.gz"
    download "https://github.com/htop-dev/htop/archive/refs/heads/main.tar.gz" "htop-edge.tar.gz"
    download "https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/archive/${NETWORKMANAGER_VER}/NetworkManager-${NETWORKMANAGER_VER}.tar.gz" "NetworkManager-${NETWORKMANAGER_VER}.tar.gz"
    download "https://github.com/jpirko/libndp/archive/refs/tags/v1.9.tar.gz" "libndp-1.9.tar.gz"
    download "https://download.gnome.org/sources/glib/2.82/glib-${GLIB_VER}.tar.xz" "glib-${GLIB_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/nettle/nettle-${NETTLE_VER}.tar.gz" "nettle-${NETTLE_VER}.tar.gz"
    download "https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-${GNUTLS_VER}.tar.xz" "gnutls-${GNUTLS_VER}.tar.xz"
    download "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz" "openssl-${OPENSSL_VER}.tar.gz"
    download "https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz" "gmp-${GMP_VER}.tar.xz"
    download "https://github.com/rockdaboot/libpsl/releases/download/${LIBPSL_VER}/libpsl-${LIBPSL_VER}.tar.gz" "libpsl-${LIBPSL_VER}.tar.gz"
    download "https://ftp.gnu.org/gnu/libunistring/libunistring-${LIBUNI_VER}.tar.gz" "libunistring-${LIBUNI_VER}.tar.gz"
    download "https://ftp.gnu.org/gnu/libidn/libidn2-${LIBIDN_VER}.tar.gz" "libidn2-${LIBIDN_VER}.tar.gz"
    download "https://curl.se/download/curl-${CURL_VER}.tar.xz" "curl-${CURL_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/readline/readline-${READLINE_VER}.tar.gz" "readline-${READLINE_VER}.tar.gz"
    download "https://releases.pagure.org/newt/newt-${NEWT_VER}.tar.gz" "newt-${NEWT_VER}.tar.gz"
    download "https://www.jedsoft.org/releases/slang/slang-${SLANG_VER}.tar.bz2" "slang-${SLANG_VER}.tar.bz2"
    download "https://ftp.osuosl.org/pub/rpm/popt/releases/popt-1.x/popt-${POPT_VER}.tar.gz" "popt-${POPT_VER}.tar.gz"
    download "https://curl.se/ca/cacert.pem" "ca-certificates.crt"
    download "https://cdn.kernel.org/pub/linux/utils/kernel/kmod/kmod-${KMOD_VER}.tar.xz" "kmod-${KMOD_VER}.tar.xz"

    # new build tools downloads
    download "https://ftp.gnu.org/gnu/m4/m4-${M4_VER}.tar.xz" "m4-${M4_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/autoconf/autoconf-${AUTOCONF_VER}.tar.xz" "autoconf-${AUTOCONF_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/automake/automake-${AUTOMAKE_VER}.tar.xz" "automake-${AUTOMAKE_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/libtool/libtool-${LIBTOOL_VER}.tar.xz" "libtool-${LIBTOOL_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/make/make-${MAKE_VER}.tar.gz" "make-${MAKE_VER}.tar.gz"
    download "https://ftp.gnu.org/gnu/bison/bison-${BISON_VER}.tar.xz" "bison-${BISON_VER}.tar.xz"
    download "https://github.com/westes/flex/releases/download/v${FLEX_VER}/flex-${FLEX_VER}.tar.gz" "flex-${FLEX_VER}.tar.gz"
    download "https://pkgconfig.freedesktop.org/releases/pkg-config-${PKGCONFIG_VER}.tar.gz" "pkg-config-${PKGCONFIG_VER}.tar.gz"
    download "https://github.com/ninja-build/ninja/archive/refs/tags/v${NINJA_VER}.tar.gz" "ninja-${NINJA_VER}.tar.gz"
    download "https://github.com/mesonbuild/meson/releases/download/${MESON_VER}/meson-${MESON_VER}.tar.gz" "meson-${MESON_VER}.tar.gz"
    download "https://ftp.gnu.org/gnu/texinfo/texinfo-${TEXINFO_VER}.tar.xz" "texinfo-${TEXINFO_VER}.tar.xz"
    download "https://download.savannah.gnu.org/releases/libpipeline/libpipeline-${LIBPIPELINE_VER}.tar.gz" "libpipeline-${LIBPIPELINE_VER}.tar.gz"
    download "https://ftp.gnu.org/gnu/groff/groff-${GROFF_VER}.tar.gz" "groff-${GROFF_VER}.tar.gz"
    download "https://download.savannah.gnu.org/releases/man-db/man-db-${MAN_DB_VER}.tar.xz" "man-db-${MAN_DB_VER}.tar.xz"
    download "https://cdn.kernel.org/pub/linux/docs/man-pages/man-pages-${MAN_PAGES_VER}.tar.xz" "man-pages-${MAN_PAGES_VER}.tar.xz"
    download "https://ftp.gnu.org/gnu/gdbm/gdbm-${GDBM_VER}.tar.gz" "gdbm-${GDBM_VER}.tar.gz"
    download "https://www.cpan.org/src/5.0/perl-${PERL_VER}.tar.gz" "perl-${PERL_VER}.tar.gz"
    download "https://raw.githubusercontent.com/funicat1/nxpm-src/refs/heads/main/nxbuild" "nxbuild"
fi

next_step

# ============================================================
# extract
# ============================================================

if should_run || [ $DOWNLOAD -ge 1 ]; then
    log "extracting sources..."

    cd "$TOOLCHAIN/src"

    tar -xf "$SOURCES/binutils-${BINUTILS_VER}.tar.xz"
    tar -xf "$SOURCES/gcc-${GCC_VER}.tar.xz"
    tar -xf "$SOURCES/glibc-${GLIBC_VER}.tar.xz"
    tar -xf "$SOURCES/linux-${LINUX_VER}.tar.xz"
    tar -xf "$SOURCES/coreutils-${COREUTILS_VER}.tar.xz"
    tar -xf "$SOURCES/libcap-${LIBCAP_VER}.tar.xz"
    tar -xf "$SOURCES/bash-${BASH_VER}.tar.gz"
    tar -xf "$SOURCES/systemd-${SYSTEMD_VER}.tar.gz"
    tar -xf "$SOURCES/less-${LESS_VER}.tar.gz"
    tar -xf "$SOURCES/which-${WHICH_VER}.tar.gz"
    tar -xf "$SOURCES/file-${FILE_VER}.tar.gz"
    tar -xf "$SOURCES/grep-${GREP_VER}.tar.xz"
    tar -xf "$SOURCES/sed-${SED_VER}.tar.xz"
    tar -xf "$SOURCES/gawk-${GAWK_VER}.tar.xz"
    tar -xf "$SOURCES/tar-${TAR_VER}.tar.xz"
    tar -xf "$SOURCES/gzip-${GZIP_VER}.tar.xz"
    tar -xf "$SOURCES/xz-${XZ_VER}.tar.gz"
    tar -xf "$SOURCES/findutils-${FINDUTILS_VER}.tar.xz"
    tar -xf "$SOURCES/ncurses-${NCURSES_VER}.tar.gz"
    tar -xf "$SOURCES/Linux-PAM-${PAM_VER}.tar.xz"
    tar -xf "$SOURCES/util-linux-${UTIL_LINUX_VER}.tar.xz"
    tar -xf "$SOURCES/libxcrypt-${LIBXCRYPT_VER}.tar.xz"
    tar -xf "$SOURCES/dbus-${DBUS_VER}.tar.xz"
    tar -xf "$SOURCES/shadow-${SHADOW_VER}.tar.xz"
    tar -xf "$SOURCES/fastfetch-${FASTFETCH_VER}.tar.gz"
    tar -xf "$SOURCES/nano-edge.tar.gz"
    tar -xf "$SOURCES/procps-ng-edge.tar.gz"
    tar -xf "$SOURCES/htop-edge.tar.gz"
    tar -xf "$SOURCES/NetworkManager-${NETWORKMANAGER_VER}.tar.gz"
    tar -xf "$SOURCES/libndp-${LIBNDP_VER}.tar.gz"
    tar -xf "$SOURCES/glib-${GLIB_VER}.tar.xz"
    tar -xf "$SOURCES/nettle-${NETTLE_VER}.tar.gz"
    tar -xf "$SOURCES/gnutls-${GNUTLS_VER}.tar.xz"
    tar -xf "$SOURCES/openssl-${OPENSSL_VER}.tar.gz"
    tar -xf "$SOURCES/gmp-${GMP_VER}.tar.xz"
    tar -xf "$SOURCES/libpsl-${LIBPSL_VER}.tar.gz"
    tar -xf "$SOURCES/libunistring-${LIBUNI_VER}.tar.gz"
    tar -xf "$SOURCES/libidn2-${LIBIDN_VER}.tar.gz"
    tar -xf "$SOURCES/curl-${CURL_VER}.tar.xz"
    tar -xf "$SOURCES/readline-${READLINE_VER}.tar.gz"
    tar -xf "$SOURCES/newt-${NEWT_VER}.tar.gz"
    tar -xf "$SOURCES/slang-${SLANG_VER}.tar.bz2"
    tar -xf "$SOURCES/popt-${POPT_VER}.tar.gz"
    tar -xf "$SOURCES/kmod-${KMOD_VER}.tar.xz"
    tar -xf "$SOURCES/gdbm-${GDBM_VER}.tar.gz"
    tar -xf "$SOURCES/perl-${PERL_VER}.tar.gz"

    # extract build tools
    tar -xf "$SOURCES/m4-${M4_VER}.tar.xz"
    tar -xf "$SOURCES/autoconf-${AUTOCONF_VER}.tar.xz"
    tar -xf "$SOURCES/automake-${AUTOMAKE_VER}.tar.xz"
    tar -xf "$SOURCES/libtool-${LIBTOOL_VER}.tar.xz"
    tar -xf "$SOURCES/make-${MAKE_VER}.tar.gz"
    tar -xf "$SOURCES/bison-${BISON_VER}.tar.xz"
    tar -xf "$SOURCES/flex-${FLEX_VER}.tar.gz"
    tar -xf "$SOURCES/pkg-config-${PKGCONFIG_VER}.tar.gz"
    tar -xf "$SOURCES/ninja-${NINJA_VER}.tar.gz"
    tar -xf "$SOURCES/meson-${MESON_VER}.tar.gz"
    tar -xf "$SOURCES/texinfo-${TEXINFO_VER}.tar.xz"
    tar -xf "$SOURCES/libpipeline-${LIBPIPELINE_VER}.tar.gz"
    tar -xf "$SOURCES/groff-${GROFF_VER}.tar.gz"
    tar -xf "$SOURCES/man-db-${MAN_DB_VER}.tar.xz"
    tar -xf "$SOURCES/man-pages-${MAN_PAGES_VER}.tar.xz"
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
SHADOW_SRC="$TOOLCHAIN/src/shadow-${SHADOW_VER}"
FASTFETCH_SRC="$TOOLCHAIN/src/fastfetch-linux-amd64"
NANO_SRC="$TOOLCHAIN/src/nano-master"
PROCPS_SRC="$TOOLCHAIN/src/procps-master"
HTOP_SRC="$TOOLCHAIN/src/htop-main"
DBUS_SRC="$TOOLCHAIN/src/dbus-${DBUS_VER}"
NETWORKMANAGER_SRC="$TOOLCHAIN/src/NetworkManager-${NETWORKMANAGER_VER}"
LIBNDP_SRC="$TOOLCHAIN/src/libndp-${LIBNDP_VER}"
GLIB_SRC="$TOOLCHAIN/src/glib-${GLIB_VER}"
NETTLE_SRC="$TOOLCHAIN/src/nettle-${NETTLE_VER}"
GNUTLS_SRC="$TOOLCHAIN/src/gnutls-3.8.7"
OPENSSL_SRC="$TOOLCHAIN/src/openssl-${OPENSSL_VER}"
GMP_SRC="$TOOLCHAIN/src/gmp-${GMP_VER}"
LIBPSL_SRC="$TOOLCHAIN/src/libpsl-${LIBPSL_VER}"
LIBUNI_SRC="$TOOLCHAIN/src/libunistring-${LIBUNI_VER}"
LIBIDN_SRC="$TOOLCHAIN/src/libidn2-${LIBIDN_VER}"
CURL_SRC="$TOOLCHAIN/src/curl-${CURL_VER}"
READLINE_SRC="$TOOLCHAIN/src/readline-${READLINE_VER}"
NEWT_SRC="$TOOLCHAIN/src/newt-${NEWT_VER}"
SLANG_SRC="$TOOLCHAIN/src/slang-${SLANG_VER}"
POPT_SRC="$TOOLCHAIN/src/popt-${POPT_VER}"
KMOD_SRC="$TOOLCHAIN/src/kmod-${KMOD_VER}"
GDBM_SRC="$TOOLCHAIN/src/gdbm-${GDBM_VER}"


next_step

# ============================================================
# gcc prerequisites
# ============================================================

if should_run; then
    log "downloading gcc prerequisites..."
    cd "$TOOLCHAIN/src/gcc-${GCC_VER}"
    ./contrib/download_prerequisites
fi

# ============================================================
# linux userspace headers
# ============================================================

if should_run; then
    log "installing linux headers..."
    mkdir -p "$ROOTFS/usr"
    cd "$TOOLCHAIN/src/linux-${LINUX_VER}"
    make ARCH=x86_64 headers_install INSTALL_HDR_PATH="$ROOTFS/usr"
fi

next_step

# ============================================================
# binutils
# ============================================================

if should_run; then
    log "building cross binutils..."
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
        --build="$( "$TOOLCHAIN/src/glibc-${GLIBC_VER}/scripts/config.guess" )" \
        --with-headers="$ROOTFS/usr/include" \
        --disable-werror \
        --disable-multilib \
        --disable-static-c++-tests \
        libc_cv_have_libgcc_s=no \
        libc_cv_forced_unwind=yes \
        libc_cv_c_cleanup=yes

    make install-bootstrap-headers=yes install-headers DESTDIR="$ROOTFS"
    make csu/subdir_lib

    mkdir -p "$ROOTFS/usr/lib"
    cp -v csu/crt1.o csu/crti.o csu/crtn.o "$ROOTFS/usr/lib/"
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
# final cross gcc
# ============================================================

if should_run; then
    log "building final cross gcc..."
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
    make DESTDIR="$ROOTFS" install
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
    make DESTDIR="$ROOTFS" install
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

    make install DESTDIR="$ROOTFS" prefix=/usr

    cat > "$TOOLCHAIN/bin/${TARGET}-pkg-config" <<EOF2
#!/usr/bin/env bash
export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"
export PKG_CONFIG_LIBDIR="/usr/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
exec /usr/bin/pkg-config "\$@"
EOF2

    chmod +x "$TOOLCHAIN/bin/${TARGET}-pkg-config"
fi

next_step

# ============================================================
# systemd dependencies
# ============================================================

if should_run; then
    cat > "$ROOTFS/etc/ld.so.conf" <<'EOF'
/usr/lib
/usr/lib64
EOF

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
        --disable-stripping \
        --with-pkg-config-libdir=/usr/lib64/pkgconfig

    make -j"$(nproc)"
    make DESTDIR="$ROOTFS" install

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

    mkdir -p "$ROOTFS/etc/pam.d" "$ROOTFS/etc/security" "$ROOTFS/usr/lib/security"

    log "patching util-linux ${UTIL_LINUX_VER}..."
    cd "$UTIL_LINUX_SRC"
    sed -i '/#include "all-io.h"/a #include "fileutils.h"' libmount/src/hook_idmap.c
    sed -i '/#include <sys\/stat.h>/a\
#ifdef HAVE_LINUX_OPENAT2_H\
# include <linux/openat2.h>\
#endif' include/fileutils.h
    sed -i 's/# define RESOLVE_NO_SYMLINKS[[:space:]]*0x02/# define RESOLVE_NO_SYMLINKS 0x04/' include/fileutils.h

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

next_step

# ============================================================
# openssl
# ============================================================

if should_run; then
    log "building openssl ${OPENSSL_VER}..."
    cd "$TOOLCHAIN/build"
    rm -rf openssl
    cp -r "$OPENSSL_SRC" openssl
    cd openssl

    CC="ccache ${TARGET}-gcc" \
    CXX="ccache ${TARGET}-g++" \
    AR="${TARGET}-ar" \
    RANLIB="${TARGET}-ranlib" \
    ./Configure linux-x86_64 \
        --prefix=/usr \
        --openssldir=/etc/ssl \
        --libdir=lib64 \
        shared \
        no-tests

    make -j"$(nproc)"
    make DESTDIR="$ROOTFS" install_sw install_ssldirs install_docs
fi

next_step

# ============================================================
# gmp, nettle & gnutls
# ============================================================

if should_run; then
    log "building gmp ${GMP_VER}..."
    CC="${TARGET}-gcc" CXX="${TARGET}-g++" CFLAGS="-O2 -pipe -std=gnu17" CXXFLAGS="-O2 -pipe" \
    build_autotools_package "gmp" "$GMP_SRC" \
        --libdir=/usr/lib64 \
        --enable-cxx

    log "building nettle ${NETTLE_VER}..."
    build_autotools_package "nettle" "$NETTLE_SRC" \
        --libdir=/usr/lib64 \
        --enable-public-key

    log "building gnutls ${GNUTLS_VER}..."
    build_autotools_package "gnutls" "$GNUTLS_SRC" \
        --libdir=/usr/lib64 \
        --disable-tests \
        --disable-tools \
        --with-included-libtasn1 \
        --with-included-unistring \
        --without-p11-kit
fi

next_step

# ============================================================
# systemd
# ============================================================

if should_run; then 
    log "building kmod..."
    cd "$TOOLCHAIN/build"
    rm -rf kmod
    mkdir kmod
    cd kmod

    "$KMOD_SRC/configure" \
        --build="$BUILD" \
        --host="$TARGET" \
        --prefix=/usr \
        --sysconfdir=/etc \
        --libdir=/usr/lib64 \
        --with-xz=no \
        --with-zstd=no \
        --with-zlib=no \
        --with-openssl=no

    make -j"$(nproc)"
    make DESTDIR="$ROOTFS" install

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
        -Dnetworkd=false \
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
        -Dman=enabled \
        -Dhtml=disabled \
        -Dtranslations=false \
        -Dbootloader=disabled \
        -Defi=false \
        -Dtpm=false \
        -Dlibmount=enabled \
        -Dblkid=enabled \
        -Dfdisk=disabled \
        -Dkmod=enabled \
        -Dpam=enabled \
        -Dacl=disabled \
        -Daudit=disabled \
        -Dlibcryptsetup=disabled \
        -Dopenssl=enabled \
        -Dgnutls=enabled \
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

    meson compile -C systemd -j"$(nproc)"
    DESTDIR="$ROOTFS" meson install -C systemd
fi

next_step

# ============================================================
# dbus
# ============================================================

if should_run; then
    log "building dbus ${DBUS_VER}..."
    cd "$TOOLCHAIN/build"
    rm -rf dbus

    cat > "$TOOLCHAIN/build/dbus-cross.txt" <<EOF2
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

    meson setup dbus \
        "$DBUS_SRC" \
        --cross-file "$TOOLCHAIN/build/dbus-cross.txt" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --buildtype=release \
        -Dmessage_bus=true \
        -Dsystemd=enabled \
        -Duser_session=true \
        -Dtraditional_activation=true \
        -Dtools=true \
        -Dmodular_tests=disabled \
        -Dinstalled_tests=false \
        -Ddoxygen_docs=disabled \
        -Dducktype_docs=disabled \
        -Dxml_docs=enabled \
        -Dqt_help=disabled \
        -Dx11_autolaunch=disabled \
        -Dselinux=disabled \
        -Dapparmor=disabled \
        -Dlibaudit=disabled \
        -Dvalgrind=disabled \
        -Dsystemd_system_unitdir=/usr/lib/systemd/system \
        -Dsystemd_user_unitdir=/usr/lib/systemd/user \
        -Druntime_dir=/run \
        -Dsystem_socket=/run/dbus/system_bus_socket \
        -Ddbus_user=messagebus

    meson compile -C dbus -j"$(nproc)"
    DESTDIR="$ROOTFS" meson install -C dbus
fi

next_step

# ============================================================
# shadow
# ============================================================

if should_run; then
    log "building shadow ${SHADOW_VER}..."
    cd "$TOOLCHAIN/build"
    rm -rf shadow
    mkdir shadow
    cd shadow

    "$SHADOW_SRC/configure" \
        --build="$BUILD" \
        --host="$TARGET" \
        --prefix=/usr \
        --sysconfdir=/etc \
        --libdir=/usr/lib64 \
        --sbindir=/usr/sbin \
        --enable-shared \
        --with-libpam \
        --without-selinux \
        --without-audit \
        --without-tcb \
        --without-libbsd \
        --disable-nls \
        --disable-account-tools-setuid

    make -j"$(nproc)"
    make DESTDIR="$ROOTFS" install
fi

next_step

# ============================================================
# networkmanager dependencies
# ============================================================

if should_run; then
    export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
    
    (cd "$LIBNDP_SRC" && ./autogen.sh)
    build_autotools_package "libndp" "$LIBNDP_SRC" --libdir=/usr/lib64
    
    log "building libunistring ${LIBUNI_VER}"
    cd "$TOOLCHAIN/build"
    rm -rf libunistring
    mkdir libunistring
    cd libunistring
    "$LIBUNI_SRC/configure" --prefix=/usr --disable-static --enable-shared
    make -j"$(nproc)"
    make DESTDIR="$ROOTFS" install
    
    log "building libidn2 ${LIBIDN_VER}"
    cd "$TOOLCHAIN/build"
    rm -rf libidn2
    mkdir libidn2
    cd libidn2
    "$LIBIDN_SRC/configure" --prefix=/usr --disable-static --enable-shared
    make -j"$(nproc)"
    make DESTDIR="$ROOTFS" install
    rm -f "$ROOTFS/usr/lib/libunistring.la" "$ROOTFS/usr/lib/libidn2.la"
    
    log "building libpsl ${LIBPSL_VER}"
    cd "$TOOLCHAIN/build"
    rm -rf libpsl
    mkdir libpsl
    cd libpsl
    "$LIBPSL_SRC/configure" --prefix=/usr --sysconfdir=/etc --disable-static --enable-shared
    make -j"$(nproc)"
    make DESTDIR="$ROOTFS" install
    
    log "building curl ${CURL_VER}..."
    cd "$TOOLCHAIN/build"
    rm -rf curl
    mkdir curl
    cd curl

    export PKG_CONFIG="$TOOLCHAIN/bin/${TARGET}-pkg-config"

    "$CURL_SRC/configure" \
        --build="$BUILD" \
        --host="$TARGET" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --with-ca-path=/etc/ssl/certs/ \
        --with-openssl \
        --with-libpsl \
        --with-libidn2 \
        --enable-shared \
        --disable-static \
        --disable-ldap \
        --disable-ldaps \
        --disable-rtsp \
        --disable-dict \
        --disable-gopher \
        --disable-imap \
        --disable-pop3 \
        --disable-smtp \
        --disable-telnet \
        --disable-tftp \
        --disable-smb \
        --disable-mqtt \
        --without-brotli \
        --without-zstd \
        --without-libssh2 \
        --without-nghttp2

    make -j"$(nproc)"
    make DESTDIR="$ROOTFS" install

    unset PKG_CONFIG
    
    log "building glib ${GLIB_VER}..."
    cd "$TOOLCHAIN/build"
    rm -rf glib

    cat > "$TOOLCHAIN/build/glib-cross.txt" <<EOF2
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

    meson setup glib \
        "$GLIB_SRC" \
        --cross-file "$TOOLCHAIN/build/glib-cross.txt" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --buildtype=release \
        -Dtests=false \
        -Dsysprof=disabled \
        -Dlibmount=enabled \
        -Dman-pages=enabled

    meson compile -C glib -j"$(nproc)"
    DESTDIR="$ROOTFS" meson install -C glib

    cd "$TOOLCHAIN/build"
    rm -rf glib-native

    (
        unset CC CXX CPP AR AS LD NM OBJCOPY OBJDUMP RANLIB READELF STRIP PKG_CONFIG PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_LIBDIR PKG_CONFIG_PATH
        export CC="/usr/bin/gcc" CXX="/usr/bin/g++" AR="/usr/bin/ar" AS="/usr/bin/as" LD="/usr/bin/ld" NM="/usr/bin/nm" OBJCOPY="/usr/bin/objcopy" OBJDUMP="/usr/bin/objdump" RANLIB="/usr/bin/ranlib" READELF="/usr/bin/readelf" STRIP="/usr/bin/strip"

        meson setup "$TOOLCHAIN/build/glib-native" \
            "$GLIB_SRC" \
            --prefix="$TOOLCHAIN/native" \
            --libdir=lib \
            --buildtype=release \
            -Dtests=false \
            -Dsysprof=disabled \
            -Dlibmount=disabled \
            -Dman-pages=disabled \
            -Ddocumentation=false \
            -Dlibelf=disabled

        meson compile -C "$TOOLCHAIN/build/glib-native" -j"$(nproc)"
        meson install -C "$TOOLCHAIN/build/glib-native"
    )

    log "building readline ${READLINE_VER}..."
    cd "$TOOLCHAIN/build"
    rm -rf readline
    mkdir readline
    cd readline

    export CPPFLAGS="-I$ROOTFS/usr/include"
    export LDFLAGS="-L$ROOTFS/usr/lib64 -Wl,-rpath,/usr/lib64"
    export LIBS="-ltinfo"

    SHLIB_LIBS="-ltinfo" "$READLINE_SRC/configure" \
        --build="$BUILD" \
        --host="$TARGET" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --enable-shared \
        --disable-static

    make SHLIB_LIBS="-ltinfo" -j"$(nproc)"
    make SHLIB_LIBS="-ltinfo" DESTDIR="$ROOTFS" install

    unset CPPFLAGS LDFLAGS LIBS

    log "building slang ${SLANG_VER}..."
    cd "$SLANG_SRC"
    make distclean >/dev/null 2>&1 || true

    ./configure \
        --build="$BUILD" \
        --host="$TARGET" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --without-x

    make
    make DESTDIR="$ROOTFS" install

    log "building popt ${POPT_VER}..."
    cd "$TOOLCHAIN/build"
    rm -rf popt
    mkdir popt
    cd popt

    "$POPT_SRC/configure" \
        --build="$BUILD" \
        --host="$TARGET" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --disable-static

    make
    make DESTDIR="$ROOTFS" install

    log "building libnewt ${NEWT_VER}..."
    cd "$NEWT_SRC"
    make distclean >/dev/null 2>&1 || true

    ./configure \
        --build="$BUILD" \
        --host="$TARGET" \
        --prefix=/usr \
        --libdir=/usr/lib64

    make -j"$(nproc)" CC="$CC" AR="$AR" RANLIB="$RANLIB"
    make DESTDIR="$ROOTFS" install
fi

next_step

# ============================================================
# networkmanager itself
# ============================================================

if should_run; then
    export PATH="$TOOLCHAIN/native/bin:$ROOTFS/usr/bin:$PATH"
    unset PKG_CONFIG PKG_CONFIG_LIBDIR CPPFLAGS LDFLAGS LIBS

    log "building NetworkManager ${NETWORKMANAGER_VER}..."
    cd "$TOOLCHAIN/build"
    rm -rf networkmanager

    meson setup networkmanager \
        "$NETWORKMANAGER_SRC" \
        --cross-file "$TOOLCHAIN/build/glib-cross.txt" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --buildtype=release \
        -Dsystemdsystemunitdir=/usr/lib/systemd/system \
        -Dsession_tracking=systemd \
        -Dsuspend_resume=systemd \
        -Dmodify_system=true \
        -Dpolkit=false \
        -Dppp=false \
        -Dmodem_manager=false \
        -Dtests=no \
        -Ddocs=false \
        -Dvapi=false \
        -Dintrospection=false \
        -Dqt=false \
        -Dselinux=false \
        -Dlibaudit=no \
        -Dcrypto=gnutls \
        -Dovs=false

    meson compile -C networkmanager -j"$(nproc)"
    DESTDIR="$ROOTFS" meson install -C networkmanager
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
    : > "$ROOTFS/etc/machine-id"
    ln -sfn /run "$ROOTFS/var/run"

    if [ -x "$ROOTFS/usr/lib/systemd/systemd" ]; then
        ln -sfn /usr/lib/systemd/systemd "$ROOTFS/sbin/init"
    else
        log_error "systemd binary was not installed."
        exit 1
    fi

    mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
    ln -sfn /usr/lib/systemd/system/NetworkManager.service \
        "$ROOTFS/etc/systemd/system/multi-user.target.wants/NetworkManager.service"

    mkdir -p "$ROOTFS/etc/NetworkManager/conf.d"
    cat > "$ROOTFS/etc/NetworkManager/conf.d/10-globally-managed-devices.conf" <<'EOF'
[keyfile]
unmanaged-devices=none
EOF

    cat > "$ROOTFS/etc/NetworkManager/conf.d/dns.conf" <<'EOF'
[main]
dns=systemd-resolved
EOF
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
        exit 1
    fi
fi

next_step

# ============================================================
# sanity checks
# ============================================================

if should_run; then
    log "running systemd component sanity checks..."

    required_bins=(
        "$ROOTFS/usr/lib/systemd/systemd"
        "$ROOTFS/usr/lib/systemd/systemd-udevd"
        "$ROOTFS/usr/lib/systemd/systemd-logind"
        "$ROOTFS/usr/lib/systemd/systemd-resolved"
        "$ROOTFS/usr/lib/systemd/systemd-timesyncd"
        "$ROOTFS/usr/lib/systemd/systemd-journald"
        "$ROOTFS/usr/sbin/NetworkManager"
        "$ROOTFS/usr/bin/nmcli"
        "$ROOTFS/usr/bin/systemctl"
        "$ROOTFS/usr/bin/journalctl"
        "$ROOTFS/usr/bin/loginctl"
        "$ROOTFS/usr/bin/udevadm"
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
VERSION_ID="v3.0"
EOF

    log "installing certificates"
    mkdir -p "$ROOTFS/etc/ssl/certs"
    cp "$SOURCES/ca-certificates.crt" "$ROOTFS/etc/ssl/certs/ca-certificates.crt"

    cat > "$ROOTFS/etc/hostname" <<'EOF'
nixie
EOF

    cat > "$ROOTFS/etc/motd" <<'EOF'
[38;2;91;41;251m [39m[38;2;87;44;252m [39m[38;2;83;47;253m [39m[38;2;79;50;253m [39m[38;2;75;54;254m [39m[38;2;71;57;254m [39m[38;2;67;61;254m [39m[38;2;64;64;254m_[39m[38;2;60;68;254m [39m[38;2;56;72;254m [39m[38;2;53;76;254m [39m[38;2;50;80;253m [39m[38;2;46;84;253m [39m[38;2;43;88;252m [39m[38;2;40;92;251m_[39m[38;2;37;96;250m [39m[38;2;34;100;249m[39m
[38;2;79;50;253m [39m[38;2;75;54;254m_[39m[38;2;71;57;254m_[39m[38;2;67;61;254m_[39m[38;2;64;64;254m_[39m[38;2;60;68;254m [39m[38;2;56;72;254m([39m[38;2;53;76;254m_[39m[38;2;50;80;253m)[39m[38;2;46;84;253m_[39m[38;2;43;88;252m [39m[38;2;40;92;251m [39m[38;2;37;96;250m_[39m[38;2;34;100;249m([39m[38;2;31;104;247m_[39m[38;2;29;108;246m)[39m[38;2;26;112;244m [39m[38;2;23;117;243m_[39m[38;2;21;121;241m_[39m[38;2;19;125;239m_[39m[38;2;17;129;237m [39m[38;2;15;133;234m[39m
[38;2;67;61;254m/[39m[38;2;64;64;254m [39m[38;2;60;68;254m [39m[38;2;56;72;254m_[39m[38;2;53;76;254m [39m[38;2;50;80;253m\[39m[38;2;46;84;253m|[39m[38;2;43;88;252m [39m[38;2;40;92;251m\[39m[38;2;37;96;250m [39m[38;2;34;100;249m\[39m[38;2;31;104;247m/[39m[38;2;29;108;246m [39m[38;2;26;112;244m/[39m[38;2;23;117;243m [39m[38;2;21;121;241m|[39m[38;2;19;125;239m/[39m[38;2;17;129;237m [39m[38;2;15;133;234m_[39m[38;2;13;138;232m [39m[38;2;11;142;230m\[39m[38;2;9;146;227m[39m
[38;2;56;72;254m|[39m[38;2;53;76;254m [39m[38;2;50;80;253m|[39m[38;2;46;84;253m [39m[38;2;43;88;252m|[39m[38;2;40;92;251m [39m[38;2;37;96;250m|[39m[38;2;34;100;249m [39m[38;2;31;104;247m|[39m[38;2;29;108;246m>[39m[38;2;26;112;244m [39m[38;2;23;117;243m [39m[38;2;21;121;241m<[39m[38;2;19;125;239m|[39m[38;2;17;129;237m [39m[38;2;15;133;234m|[39m[38;2;13;138;232m [39m[38;2;11;142;230m [39m[38;2;9;146;227m_[39m[38;2;8;150;224m_[39m[38;2;7;154;222m/[39m[38;2;5;159;219m [39m[38;2;4;163;216m [39m[38;2;3;167;213m[39m
[38;2;46;84;253m|[39m[38;2;43;88;252m_[39m[38;2;40;92;251m|[39m[38;2;37;96;250m [39m[38;2;34;100;249m|[39m[38;2;31;104;247m_[39m[38;2;29;108;246m|[39m[38;2;26;112;244m_[39m[38;2;23;117;243m/[39m[38;2;21;121;241m_[39m[38;2;19;125;239m/[39m[38;2;17;129;237m\[39m[38;2;15;133;234m_[39m[38;2;13;138;232m\[39m[38;2;11;142;230m_[39m[38;2;9;146;227m|[39m[38;2;8;150;224m\[39m[38;2;7;154;222m_[39m[38;2;5;159;219m_[39m[38;2;4;163;216m_[39m[38;2;3;167;213m|[39m[38;2;2;171;209m [39m[38;2;2;175;206m[39m
===============================================
Welcome to nixie linux! (v3.0)
EOF

    mkdir -p "$ROOTFS/etc/fastfetch"

    cat > "$ROOTFS/etc/fastfetch/logo.txt" <<'EOF'
$1       $3_$1      $3_ $2
$1 ____ $3(_)$1_  _$3(_)$2 ___ 
$1/  _ \| \ \/ $2/ |/ _ \
$1| | | | |> $2 <| |  __/  
$1|_| |_|_/$2_/\_\_|\___|  
EOF

    cat > "$ROOTFS/etc/fastfetch/config.jsonc" <<'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/master/doc/json_schema.json",
  "logo": {
    "type": "file",
    "source": "/etc/fastfetch/logo.txt",
    "color": {
        "2": "cyan",
        "1": "blue",
        "3": "cyan"
    }
  },
  "modules": [
    "title",
    "separator",
    "os",
    "host",
    "kernel",
    "uptime",
    "packages",
    "shell",
    "display",
    "de",
    "wm",
    "wmtheme",
    "theme",
    "icons",
    "font",
    "cursor",
    "terminal",
    "terminalfont",
    "cpu",
    "gpu",
    "memory",
    "swap",
    "disk",
    "localip",
    "battery",
    "poweradapter",
    "locale",
    "break",
    "colors"
  ]
}
EOF

    cat > "$ROOTFS/etc/issue" <<'EOF'
Nixie Linux v3.0
EOF

    cat > "$ROOTFS/etc/profile" <<'EOF'
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
export PS1='(\[\e[95m\]\u\[\e[0m\]@\[\e[36;1m\]\h\[\e[0m\]:\[\e[35;1m\]\w\[\e[0m\]) \$ '
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
    log "Setting up autologin.."
    mkdir -p rootfs/etc/systemd/system/getty.target.wants

    ln -sfn \
        rootfs/usr/lib/systemd/system/getty@.service \
        rootfs/etc/systemd/system/getty.target.wants/getty@tty1.service
    
    cat > "$ROOTFS/etc/pam.d/login" <<'EOF'
auth       required   pam_unix.so
account    required   pam_unix.so
session    required   pam_unix.so
session    optional   pam_motd.so
EOF

    cat > "$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
EOF

    cat > "$ROOTFS/etc/group" <<'EOF'
root:x:0:
EOF

    mkdir -p "$ROOTFS/root"
    chmod 755 "$ROOTFS/root"
    hash="$(openssl passwd -6 root)"
    last_change=$(( $(date +%s) / 86400 ))

    cat > "$ROOTFS/etc/shadow" <<EOF
root:$hash:$last_change:0:99999:7:::
EOF

    chmod 600 "$ROOTFS/etc/shadow"
    
    mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"

cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/sbin/agetty --autologin root --noclear %I $TERM
EOF
    

    cat > "$ROOTFS/etc/login.defs" <<'EOF'
FAIL_DELAY 3
LOG_UNKFAIL_ENAB no
LOG_OK_LOGINS no
LASTLOG_ENAB yes

MAIL_CHECK_ENAB no

ENV_SUPATH PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV_PATH    PATH=/usr/local/bin:/usr/bin:/bin

TTYPERM 0600
EOF
    log "good boy"
fi

next_step

# ============================================================
# extra base packages
# ============================================================

if should_run; then
    log "building post-sanity base packages..."

    log "copying fastfetch..."
    cp -a "$FASTFETCH_SRC"/* "$ROOTFS/"
    
    log "copying nxbuild..."
    cp "$SOURCES/nxbuild" "$ROOTFS/usr/bin"
    chmod +x "$ROOTFS/nxbuild"

    build_autotools_package "xz" "$XZ_SRC" --disable-scripts
    
    
    log "building htop..."
    cd "$HTOP_SRC"
    ./autogen.sh

    export PKG_CONFIG="$TOOLCHAIN/bin/${TARGET}-pkg-config"

    ./configure \
        --build="$(gcc -dumpmachine)" \
        --host=x86_64-nixie-linux-gnu \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --sysconfdir=/etc \
        --enable-unicode \
        --disable-sensors \
        --disable-delayacct
    
    make -j"$(nproc)"
    make DESTDIR="$ROOTFS" install
    
    log "building procps-ng..."
    cd "$PROCPS_SRC"
    export CPPFLAGS="-I$ROOTFS/usr/include"
    export LDFLAGS="-L$ROOTFS/usr/lib64"
    make distclean 2>/dev/null || true

    ./autogen.sh
    ./configure \
        --build="$(gcc -dumpmachine)" \
        --host=x86_64-nixie-linux-gnu \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --sysconfdir=/etc \
        --disable-nls

    make -j"$(nproc)"
    make DESTDIR="$ROOTFS" install
    
    log "building nano..."
    cd "$NANO_SRC"
    ./autogen.sh
    ./configure \
        --prefix=/usr \
        --host=x86_64-nixie-linux-gnu \
        --build="$(gcc -dumpmachine)" \
        LIBS="-ltinfo"
    make clean
    make -j"$(nproc)" LIBS="-lncursesw -ltinfo"
    make DESTDIR="$ROOTFS" install

    unset PKG_CONFIG CPPFLAGS LDFLAGS

    build_autotools_package "less" "$LESS_SRC" --with-regex=posix
    build_autotools_package "which" "$WHICH_SRC"
    build_autotools_package "grep" "$GREP_SRC" --without-included-regex
    build_autotools_package "sed" "$SED_SRC"
    build_autotools_package "gawk" "$GAWK_SRC" --without-mpfr
    build_autotools_package "gzip" "$GZIP_SRC"
    build_autotools_package "tar" "$TAR_SRC"
    build_autotools_package "findutils" "$FINDUTILS_SRC" --disable-locate
fi

next_step

# ============================================================
# native gcc & binutils into rootfs
# ============================================================

if should_run; then

    log "building native binutils for rootfs..."
    cd "$TOOLCHAIN/build"
    rm -rf binutils-target
    mkdir binutils-target
    cd binutils-target

    "$TOOLCHAIN/src/binutils-${BINUTILS_VER}/configure" \
        --build="$BUILD" \
        --host="$TARGET" \
        --target="$TARGET" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --disable-nls \
        --disable-werror \
        --disable-multilib \
        --enable-shared

    make -j"$(nproc)"
    make DESTDIR="$ROOTFS" install

    log "building native gcc into rootfs..."
    cd "$TOOLCHAIN/build"
    rm -rf gcc-target
    mkdir gcc-target
    cd gcc-target

    "$TOOLCHAIN/src/gcc-${GCC_VER}/configure" \
        --build="$BUILD" \
        --host="$TARGET" \
        --target="$TARGET" \
        --prefix=/usr \
        --libdir=/usr/lib64 \
        --with-sysroot=/ \
        --enable-languages=c,c++ \
        --enable-shared \
        --enable-threads=posix \
        --enable-default-pie \
        --enable-default-ssp \
        --disable-multilib \
        --disable-nls

    make -j"$(nproc)"
    make DESTDIR="$ROOTFS" install

    ln -sfn gcc "$ROOTFS/usr/bin/cc"
    ln -sfn g++ "$ROOTFS/usr/bin/c++"

fi

next_step

# ============================================================
# build tools & man doc packages into rootfs
# ============================================================

if should_run; then
    

    log "building development & build tools into rootfs..."

    CFLAGS="-std=gnu11" build_autotools_package "m4" "$TOOLCHAIN/src/m4-${M4_VER}"
    build_autotools_package "autoconf" "$TOOLCHAIN/src/autoconf-${AUTOCONF_VER}"
    build_autotools_package "automake" "$TOOLCHAIN/src/automake-${AUTOMAKE_VER}"
    build_autotools_package "libtool" "$TOOLCHAIN/src/libtool-${LIBTOOL_VER}" --libdir=/usr/lib64
    build_autotools_package "make" "$TOOLCHAIN/src/make-${MAKE_VER}"
    build_autotools_package "bison" "$TOOLCHAIN/src/bison-${BISON_VER}"
    build_autotools_package "flex" "$TOOLCHAIN/src/flex-${FLEX_VER}" --libdir=/usr/lib64 
    ln -sfn flex "$ROOTFS/usr/bin/lex"
    tar -xf "$SOURCES/pkg-config-${PKGCONFIG_VER}.tar.gz" \
    -C "$TOOLCHAIN/src/" \
    "pkg-config-${PKGCONFIG_VER}/glib/glib/goption.c"
    CFLAGS="-O2 -pipe -std=gnu11" \
    glib_cv_stack_grows=no \
    glib_cv_uscore=no \
    glib_cv_posix_getpwuid_r=yes \
    ac_cv_func_posix_getpwuid_r=yes \
    glib_cv_posix_getgrgid_r=yes \
    ac_cv_func_posix_getgrgid_r=yes \
    glib_cv_sane_realloc=yes \
    glib_cv_va_val_copy=yes \
    glib_cv_long_long_format=ll \
    build_autotools_package "pkg-config" "$TOOLCHAIN/src/pkg-config-${PKGCONFIG_VER}" --with-internal-glib 


cat << "EOF" > texinfo.cache
gl_cv_func_iconv_works=yes
am_cv_func_iconv_works=yes
ac_cv_func_iconv_works=yes
am_cv_func_iconv_supports_utf8=yes
gl_cv_func_iconv_supports_utf8=yes
gl_cv_func_wcrtomb_retval=yes
gl_cv_func_mbrtowc_retval=yes
EOF

    am_cv_func_iconv_works=yes \
    gl_cv_func_iconv_works=yes \
    am_cv_func_iconv=yes
    build_autotools_package "texinfo" "$TOOLCHAIN/src/texinfo-${TEXINFO_VER}" texinfo_cv_sys_iconv_converts_euc_cn="xyes"
    
    build_autotools_package "gdbm" \
    "$TOOLCHAIN/src/gdbm-${GDBM_VER}" \
    --enable-libgdbm-compat

    log "building perl ${PERL_VER} in chroot..."
    
    sh -c "rm -rf '$ROOTFS/perl-${PERL_VER}'"
    cp -r "$TOOLCHAIN/src/perl-${PERL_VER}" "$ROOTFS/"
    mount --bind /dev "$ROOTFS/dev"
    chroot "$ROOTFS" /bin/bash -c "
    # Inside chroot:
mkdir -p /usr/include/x86_64-linux-gnu
cd /usr/include
for d in asm asm-generic bits gnu linux sys; do
    [ -e '\$d' ] && ln -sfn '../'\$d 'x86_64-linux-gnu/'\$d
done
    cd /perl-${PERL_VER}
    rm -f config.sh Policy.sh
    ./Configure -des \
        -Dprefix=/usr \
        -Dman1dir=/usr/share/man/man1 \
        -Dman3dir=/usr/share/man/man3 \
        -Dusethreads \
        -Dlibs='-lpthread -ldl -lm -lcrypt -lutil -lc'
    make -j$(nproc)
    make install
    ldconfig
    rm -rf /perl-${PERL_VER}
"
    umount "$ROOTFS/dev"

    log "building ninja ${NINJA_VER}..."
    cd "$TOOLCHAIN/src/ninja-${NINJA_VER}"
    python3 configure.py --bootstrap
    install -vm755 ninja "$ROOTFS/usr/bin/ninja"

    log "installing meson ${MESON_VER}..."
    cd "$TOOLCHAIN/src/meson-${MESON_VER}"
    python3 setup.py install --prefix=/usr --root="$ROOTFS"

    log "installing man pages & man-db..."
    cd "$TOOLCHAIN/src/man-pages-${MAN_PAGES_VER}"
    make DESTDIR="$ROOTFS" install

    build_autotools_package "libpipeline" "$TOOLCHAIN/src/libpipeline-${LIBPIPELINE_VER}" --libdir=/usr/lib64
    build_autotools_package "groff" "$TOOLCHAIN/src/groff-${GROFF_VER}" PAGE=A4
    build_autotools_package "man-db" "$TOOLCHAIN/src/man-db-${MAN_DB_VER}" \
        --libdir=/usr/lib64 \
        --sysconfdir=/etc \
        --disable-setuid \
        --enable-cache-owner=root \
        --with-browser=/usr/bin/less \
        --with-vpath
fi

next_step

# ============================================================
# cleanup environment
# ============================================================

unset CC CXX AR AS LD NM OBJCOPY OBJDUMP RANLIB READELF STRIP CFLAGS CXXFLAGS PKG_CONFIG PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR

log "Fixing permissions..."
username="${SUDO_USER:-$USER}"
log "chown -R $username:$username $ROOTFS"
sudo chown -R "$username:$username" "$ROOTFS"
log "chown -R $username:$username $TOOLCHAIN"
sudo chown -R "$username:$username" "$TOOLCHAIN"
log "chown -R $username:$username $SOURCES"
sudo chown -R "$username:$username" "$SOURCES"

log "Running ldconfig..."
ldconfig -r "$ROOTFS"
cp "$ROOTFS/sbin/ldconfig" "$ROOTFS/usr/sbin/ldconfig" 



echo
printf '%b=======================%b\n' "$LOG_PREFIX_COLOR" "$RESET"
printf '%b  bootstrap complete!%b\n' "$LOG_TEXT_COLOR" "$RESET"
printf '%b=======================%b\n' "$LOG_PREFIX_COLOR" "$RESET"
