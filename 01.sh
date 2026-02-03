#!/bin/bash
# minimal-install.sh

set -e

# Основные переменные
DISK="/dev/sda"
HOSTNAME="archlinux"
USERNAME="user"

# Разметка
sgdisk -Z $DISK
sgdisk -n 1:0:+1G -t 1:ef00 $DISK
sgdisk -n 2:0:0 -t 2:8300 $DISK

# Форматирование
mkfs.fat -F32 ${DISK}1
mkfs.ext4 ${DISK}2

# Монтирование
mount ${DISK}2 /mnt
mkdir /mnt/boot
mount ${DISK}1 /mnt/boot

# Установка
pacstrap /mnt base linux linux-firmware sudo networkmanager

# Базовая настройка
genfstab -U /mnt >> /mnt/etc/fstab
arch-chroot /mnt bash -c "
    echo '$HOSTNAME' > /etc/hostname
    ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
    hwclock --systohc
    echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
    locale-gen
    echo 'LANG=en_US.UTF-8' > /etc/locale.conf
    useradd -m -G wheel $USERNAME
    echo '$USERNAME:password' | chpasswd
    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
    systemctl enable NetworkManager
    mkinitcpio -P
    bootctl install
    echo 'default arch' > /boot/loader/loader.conf
    echo 'timeout 3' >> /boot/loader/loader.conf
    echo 'title Arch Linux' > /boot/loader/entries/arch.conf
    echo 'linux /vmlinuz-linux' >> /boot/loader/entries/arch.conf
    echo 'initrd /initramfs-linux.img' >> /boot/loader/entries/arch.conf
    echo 'options root=PARTUUID=$(blkid -s PARTUUID -o value ${DISK}2) rw' >> /boot/loader/entries/arch.conf
"

echo "Installation complete!"
