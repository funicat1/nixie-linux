# locate sysroot
sysroot=$(pwd)

if [ ! -e "$sysroot/linux-config" ]; then
    cd ..
    sysroot=$(pwd)

    if [ ! -e "$sysroot/linux-config" ]; then
        log_error "linux-config not found. are you in the nixie linux directory?"
        exit 1
    fi
fi

username="${SUDO_USER:-$USER}"
echo "# chown -R "$username:$username" $sysroot"
sudo chown -R "$username:$username" $sysroot
echo "Done"
