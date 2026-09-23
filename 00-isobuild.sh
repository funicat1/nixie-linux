# ==============
# iso builder
# ==============
echo "==> nixie linux iso builder"

sysroot=$(pwd)
mkdir -p "$sysroot/build/linux"
mkdir -p "$sysroot/build/iso"

git clone --depth 1 git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git

cd "$sysroot/linux"

#echo "==> cleaning linux source tree"
#make mrproper

cp "$sysroot/linux-config" "$sysroot/build/linux/.config"

echo "==> building linux"
make O="$sysroot/build/linux" olddefconfig
make O="$sysroot/build/linux" bzImage -j$(nproc)
cp "$sysroot/build/linux/arch/x86/boot/bzImage" "$sysroot/build/iso"
