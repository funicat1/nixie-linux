# ==============
# iso builder
# ==============
echo "==> nixie linux iso builder"

sysroot=$(pwd)
if [ ! -e "linux-config" ]; then
    cd ..
    sysroot=$(pwd)
    if [ ! -e "linux-config" ]; then
        echo "linux-config not found."
        exit 1
    fi
fi

mkdir -p "$sysroot/build/linux"
mkdir -p "$sysroot/build/iso"

if [ -d "$sysroot/toolchain" ]; then
	cd "$sysroot"/toolchain/src/linux*
else
	echo "toolchain doesnt exist! build nixie linux first!"
	exit 1
fi

echo "==> cleaning linux source tree"
make mrproper

cp "$sysroot/linux-config" "$sysroot/build/linux/.config"

echo "==> building linux"
make O="$sysroot/build/linux" olddefconfig
make O="$sysroot/build/linux" bzImage -j$(nproc)
cp "$sysroot/build/linux/arch/x86/boot/bzImage" "$sysroot/build/iso"
