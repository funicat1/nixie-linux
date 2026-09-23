
if [ ! -d "rootfs" ]; then
    cd ..
    if [ ! -d "rootfs" ]; then
        echo "Rootfs not found. didnt run build?"
        exit 1
    fi
fi

if [ "$EUID" != "0" ]; then
    echo "This script should be ran as root."
    exit 1
fi

truncate -s 4G nixie-rootfs.img
mkfs.ext4 nixie-rootfs.img

mkdir rootfs-mount
sudo mount -o loop nixie-rootfs.img rootfs-mount

sudo cp -a rootfs/. rootfs-mount/

sudo umount rootfs-mount
rmdir rootfs-mount
