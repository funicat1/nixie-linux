# ==============
# iso builder
# ==============

set -e

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

log "nixie linux iso builder"

# locate sysroot
sysroot=$(pwd)

if [ ! -e "$sysroot/linux-config" ]; then
    cd ..
    sysroot=$(pwd)

    if [ ! -e "$sysroot/linux-config" ]; then
        log_error "linux-config not found."
        exit 1
    fi
fi

# required files/directories
if [ ! -d "$sysroot/toolchain" ]; then
    log_error "toolchain doesn't exist! build nixie linux first!"
    exit 1
fi

if [ ! -d "$sysroot/busybox" ]; then
    log_error "busybox source tree doesn't exist at $sysroot/busybox"
    exit 1
fi

if [ ! -e "$sysroot/busybox-config" ]; then
    log_error "busybox-config not found."
    exit 1
fi

if [ ! -d "$sysroot/limine" ]; then
    log_error "limine source tree doesn't exist at $sysroot/limine"
    exit 1
fi

# locate linux source tree
linux_src=$(find "$sysroot/toolchain/src" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'linux*' \
    -print -quit)

if [ -z "$linux_src" ]; then
    log_error "linux source tree not found in $sysroot/toolchain/src"
    exit 1
fi

# clean iso staging area
rm -rf "$sysroot/build/iso"

mkdir -p "$sysroot/build/linux"
mkdir -p "$sysroot/build/iso/boot"
mkdir -p "$sysroot/build/iso/EFI/BOOT"
mkdir -p "$sysroot/build/limine"

# ==============
# linux kernel
# ==============

cd "$linux_src"

if [ ! -e "$sysroot/build/linux/arch/x86/boot/bzImage" ]; then
    log "cleaning linux source tree"
    make mrproper

    log "installing linux config"
    cp "$sysroot/linux-config" \
        "$sysroot/build/linux/.config"

    log "building linux"
    make O="$sysroot/build/linux" olddefconfig
    make O="$sysroot/build/linux" bzImage -j"$(nproc)"
else
    log "$sysroot/build/linux/arch/x86/boot/bzImage already exists. not building the kernel again"
fi

# ==============
# limine
# ==============

if [ ! -e "$sysroot/build/limine/bin/limine-bios.sys" ]; then
    log "building limine"

    cd "$sysroot/limine"
    ./bootstrap

    cd "$sysroot/build/limine"

    "$sysroot/limine/configure" \
        --enable-uefi-x86-64 \
        --enable-uefi-cd \
        --enable-bios \
        --prefix="$sysroot/rootfs"

    make -j"$(nproc)"
    make install
else
    log "limine already exists. not rebuilding it"
fi

# ==============
# iso staging
# ==============

log "staging kernel"

cp "$sysroot/build/linux/arch/x86/boot/bzImage" \
   "$sysroot/build/iso/boot/vmlinuz"

log "staging limine"

cp "$sysroot/build/limine/bin/limine-bios.sys" \
   "$sysroot/build/iso/boot/"

cp "$sysroot/build/limine/bin/limine-bios-cd.bin" \
   "$sysroot/build/iso/boot/"

cp "$sysroot/build/limine/bin/limine-uefi-cd.bin" \
   "$sysroot/build/iso/boot/"

cp "$sysroot/build/limine/bin/BOOTX64.EFI" \
   "$sysroot/build/iso/EFI/BOOT/"

# ==============
# squashfs
# ==============

log "building squashfs"

mkdir -p "$sysroot/build/iso/live"

mksquashfs \
    "$sysroot/rootfs/" \
    "$sysroot/build/iso/live/live.sqsh" \
    -all-root

# ==============
# busybox
# ==============

log "building busybox"

mkdir -p "$sysroot/build/busybox"

cp "$sysroot/busybox-config" \
   "$sysroot/build/busybox/.config"


make -C "$sysroot/busybox" \
    O="$sysroot/build/busybox" \
    -j"$(nproc)"

# ==============
# initramfs
# ==============

log "building initramfs"

rm -rf "$sysroot/build/initramfs"
mkdir -p "$sysroot/build/initramfs"

make -C "$sysroot/busybox" \
    O="$sysroot/build/busybox" \
    CONFIG_PREFIX="$sysroot/build/initramfs" \
    install

cat > "$sysroot/build/initramfs/init" <<'EOF'
#!/bin/sh

# nixie linux initramfs

log() {
    echo "[ INIT ]: $*"
}

mkdir -p \
    /dev \
    /proc \
    /sys \
    /run \
    /newroot \
    /lower \
    /upper \
    /work \
    /live \
    /live/test

mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys

log "booting nixie linux from iso"

# let devtmpfs populate
sleep 4

LIVEDEV=""

for dev in /dev/*; do
    [ -b "$dev" ] || continue

    # don't hide the error while debugging
    if mount -o ro "$dev" /live/test 2>/dev/null; then
        echo

        # support either layout
        if [ -f /live/test/live.sqsh ]; then
            LIVEDEV="$dev"
            SQUASHFS_PATH="/live/live.sqsh"
        elif [ -f /live/test/live/live.sqsh ]; then
            LIVEDEV="$dev"
            SQUASHFS_PATH="/live/live/live.sqsh"
        fi

        umount /live/test

        if [ -n "$LIVEDEV" ]; then
            log "found squashfs on $LIVEDEV"
            break
        fi
    fi
done

if [ -z "$LIVEDEV" ]; then
    # let devtmpfs populate
    log "cant find installation media, trying again"
sleep 4

LIVEDEV=""

for dev in /dev/*; do
    [ -b "$dev" ] || continue

    # don't hide the error while debugging
    if mount -o ro "$dev" /live/test 2>/dev/null; then
        echo

        # support either layout
        if [ -f /live/test/live.sqsh ]; then
            LIVEDEV="$dev"
            SQUASHFS_PATH="/live/live.sqsh"
        elif [ -f /live/test/live/live.sqsh ]; then
            LIVEDEV="$dev"
            SQUASHFS_PATH="/live/live/live.sqsh"
        fi

        umount /live/test

        if [ -n "$LIVEDEV" ]; then
            log "found squashfs on $LIVEDEV"
            break
        fi
    fi
done

if [ -z "$LIVEDEV" ]; then
    log "error: could not find live.sqsh"
    log "block devices reported by kernel:"
    cat /proc/partitions
    echo
    log "dropping to shell"
    exec sh
fi
fi

rmdir /live/test 2>/dev/null

log "mounting live filesystem from $LIVEDEV"
mount -o ro "$LIVEDEV" /live || {
    log "error: failed to mount $LIVEDEV"
    exec sh
}

log "mounting squashfs: $SQUASHFS_PATH"
mount -t squashfs -o ro \
    "$SQUASHFS_PATH" \
    /lower || {
        log "error: failed to mount squashfs"
        exec sh
    }

log "creating writable layer"

mount -t tmpfs tmpfs /upper || {
    log "error: failed to mount tmpfs"
    exec sh
}

mkdir -p \
    /upper/upper \
    /upper/work

log "mounting overlayfs"

mount -t overlay overlay \
    -o lowerdir=/lower,upperdir=/upper/upper,workdir=/upper/work \
    /newroot || {
        log "error: failed to mount overlay"
        exec sh
    }

log "preparing kernel filesystems"

mkdir -p \
    /newroot/dev \
    /newroot/proc \
    /newroot/sys \
    /newroot/run

mount --move /dev /newroot/dev
mount --move /proc /newroot/proc
mount --move /sys /newroot/sys

mount -t tmpfs tmpfs /newroot/run

log "switching to nixie linux"

exec switch_root /newroot /sbin/init
EOF

chmod +x "$sysroot/build/initramfs/init"

# force everything in the cpio archive to be root-owned
cd "$sysroot/build/initramfs"

find . -print0 |
    cpio \
        --null \
        --owner=0:0 \
        -ov \
        --format=newc |
    gzip -9 > "$sysroot/build/iso/boot/initramfs.cpio.gz"

cd "$sysroot"

# ==============
# limine config
# ==============

log "writing limine configuration"

cat > "$sysroot/build/iso/boot/limine.conf" <<'EOF'
timeout: 30
interface_resolution: 640x480
interface_branding: nixie linux
interface_branding_colour: aa88ff
interface_help_colour: 8888ff

graphics: yes
term_foreground: c0c0c0
term_background: 80000000
term_margin: 24
term_margin_gradient: 4

/Install Nixie Linux
    protocol: linux
    path: boot():/boot/vmlinuz
    module_path: boot():/boot/initramfs.cpio.gz
    cmdline: loglevel=3
EOF

# ==============
# create iso
# ==============

log "creating nixie linux iso"

xorriso -as mkisofs \
    -b boot/limine-bios-cd.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    "$sysroot/build/iso" \
    -o "$sysroot/nixie-linux.iso"

log "iso created: $sysroot/nixie-linux.iso"
