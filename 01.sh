#!/bin/bash
# arch-install-btrfs-sdboot-fixed.sh
# Исправленная версия - решает проблемы с EFI и правами доступа

set -euo pipefail

# ===============================
# CONFIGURATION
# ===============================
HOSTNAME=""                         # Оставьте пустым для интерактивного ввода
USERNAME=""                         # Оставьте пустым для интерактивного ввода
ROOTPASS=""                         # Оставьте пустым для интерактивного ввода
USERPASS=""                         # Оставьте пустым для интерактивного ввода
TIMEZONE="Europe/Moscow"            # Часовой пояс
LOCALE="en_US.UTF-8"                # Локаль
KEYMAP="us"                         # Раскладка клавиатуры
SWAP_SIZE=4G                        # Размер файла подкачки

# ===============================
# CHECK ENVIRONMENT
# ===============================
[[ "$(id -u)" -ne 0 ]] && { echo "Run script as root"; exit 1; }
[[ ! -d /sys/firmware/efi ]] && { echo "UEFI not detected"; exit 1; }

echo "========================================"
echo "Arch Linux Installer (без шифрования)"
echo "========================================"

# ===============================
# INTERACTIVE INPUT (без изменений)
# ===============================
# ... [весь блок интерактивного ввода остается без изменений] ...

# ===============================
# SELECT DISK
# ===============================
mapfile -t DISKS < <(lsblk -d -p -n -o NAME,SIZE,MODEL | grep -vE 'loop|zram')
PS3="Select disk: "
select d in "${DISKS[@]}"; do
    [[ -n $d ]] && { DISK=${d%% *}; break; }
done
echo "⚠️  ALL DATA on $DISK will be erased!"
read -rp "Type 'yes' to continue: " confirm
[[ "$confirm" != "yes" ]] && { echo "Aborted."; exit 1; }

# ===============================
# PARTITIONING
# ===============================
echo "Creating partitions..."
[[ $DISK =~ [0-9]$ ]] && PARTP=p || PARTP=

sgdisk -Z "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$DISK"
sgdisk -n 2:0:0  -t 2:8300 -c 2:ROOT "$DISK"

# Получаем PARTUUID корневого раздела
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "${DISK}${PARTP}2")

# ===============================
# BTRFS SUBVOLUMES
# ===============================
echo "Creating Btrfs filesystem and subvolumes..."
mkfs.btrfs -f -L ArchRoot "${DISK}${PARTP}2"
mount "${DISK}${PARTP}2" /mnt

for vol in @ @home @snapshots @log @pkg @tmp @opt @swap; do
    btrfs subvolume create "/mnt/$vol"
done

umount /mnt

# ===============================
# MOUNT SUBVOLUMES
# ===============================
echo "Mounting subvolumes..."
mount_opts="noatime,ssd,discard=async,compress=zstd"
special_opts="nodatacow,compress=no"

mount -o "$mount_opts,subvol=@" "${DISK}${PARTP}2" /mnt

declare -A subvolumes=( 
    [@home]="/mnt/home" 
    [@snapshots]="/mnt/.snapshots" 
    [@log]="/mnt/var/log" 
    [@opt]="/mnt/opt" 
)
declare -A special_subvols=( 
    [@pkg]="/mnt/var/cache/pacman/pkg" 
    [@tmp]="/mnt/var/tmp" 
    [@swap]="/mnt/.swap" 
)

mkdir -p /mnt/boot "${subvolumes[@]}" "${special_subvols[@]}"

for sv in "${!subvolumes[@]}"; do
    mount -o "$mount_opts,subvol=$sv" "${DISK}${PARTP}2" "${subvolumes[$sv]}"
done

for sv in "${!special_subvols[@]}"; do
    mount -o "$special_opts,subvol=$sv" "${DISK}${PARTP}2" "${special_subvols[$sv]}"
    chattr +C "${special_subvols[$sv]}" 2>/dev/null || true
done

# ===============================
# EFI PARTITION
# ===============================
echo "Formatting EFI partition..."
mkfs.fat -F32 -n EFI "${DISK}${PARTP}1"
mount "${DISK}${PARTP}1" /mnt/boot

# ===============================
# CREATE SWAPFILE
# ===============================
echo "Creating swapfile..."
swapfile="/mnt/.swap/swapfile"
btrfs filesystem mkswapfile --size "$SWAP_SIZE" "$swapfile"
swapon "$swapfile"

# ===============================
# UPDATE MIRRORS
# ===============================
echo "Updating mirrorlist..."

success=false
for attempt in 1 2; do
    echo "  -> Attempt $attempt: updating mirrors via reflector..."
    if reflector -c Russia,Finland,Germany,Netherlands,Switzerland \
        --protocol https --latest 5 --ipv4 --save /etc/pacman.d/mirrorlist; then
        echo "  -> Success"
        success=true
        break
    else
        echo "  -> Failed to update mirrors"
    fi
done

if [ "$success" != true ]; then
    echo "  -> Using fallback mirrors"
    cat > /etc/pacman.d/mirrorlist <<MIRRORS
Server = https://mirror.pseudoform.org/\$repo/os/\$arch
Server = https://pkg.fef.moe/archlinux/\$repo/os/\$arch
Server = https://berlin.mirror.pkgbuild.com/\$repo/os/\$arch
Server = https://cdnmirror.com/archlinux/\$repo/os/\$arch
Server = https://mirror.ubrco.de/archlinux/\$repo/os/\$arch
MIRRORS
fi

# ===============================
# PACSTRAP
# ===============================
echo "Installing base system..."
pacstrap -K /mnt base linux linux-firmware linux-headers \
    btrfs-progs sudo vim nano networkmanager

# ===============================
# FSTAB
# ===============================
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# ===============================
# CHROOT CONFIGURATION - ИСПРАВЛЕННАЯ ЧАСТЬ
# ===============================
echo "Configuring system in chroot..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# Timezone & locale
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sed -i 's/^#ru_RU.UTF-8/ru_RU.UTF-8/' /etc/locale.gen
locale-gen

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<H
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
H

# Root password
echo "root:$ROOTPASS" | chpasswd --crypt-method SHA512

# User
useradd -m -G wheel,storage,power,audio,video $USERNAME
echo "$USERNAME:$USERPASS" | chpasswd --crypt-method SHA512
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel

# Initramfs
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Исправляем права доступа к /boot перед установкой загрузчика
chmod 755 /boot
chmod 700 /boot/loader 2>/dev/null || true

# Bootloader - исправленная установка
if mountpoint -q /boot; then
    bootctl install --path=/boot
else
    echo "ERROR: /boot is not mounted!"
    exit 1
fi

# Конфигурация загрузчика
cat > /boot/loader/loader.conf <<LOADER
default arch
timeout 3
console-mode max
editor no
LOADER

cat > /boot/loader/entries/arch.conf <<ENTRY
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=PARTUUID=$ROOT_PARTUUID rootflags=subvol=@ rd.vconsole.keymap=$KEYMAP rw
ENTRY

# Создаем резервную запись
cp /boot/loader/entries/arch.conf /boot/loader/entries/arch-fallback.conf
sed -i 's/initramfs-linux.img/initramfs-linux-fallback.img/' /boot/loader/entries/arch-fallback.conf

# Фиксим права для загрузчика
chmod 600 /boot/loader/entries/*.conf 2>/dev/null || true
chmod 600 /boot/loader/loader.conf 2>/dev/null || true

# Enable NetworkManager
systemctl enable NetworkManager

EOF

# ===============================
# РУЧНАЯ ПРОВЕРКА И ДОНАСТРОЙКА
# ===============================
echo "Performing post-installation checks..."

# Проверяем, что загрузчик установлен
if [[ -f /mnt/boot/EFI/systemd/systemd-bootx64.efi ]]; then
    echo "✓ systemd-boot installed successfully"
else
    echo "⚠️  systemd-boot files not found, attempting manual installation"
    arch-chroot /mnt bootctl install --path=/boot
fi

# Проверяем записи загрузчика
if [[ -f /mnt/boot/loader/entries/arch.conf ]]; then
    echo "✓ Boot entry created successfully"
else
    echo "⚠️  Boot entry not found, creating manually"
    cat > /mnt/boot/loader/entries/arch.conf <<ENTRY
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=PARTUUID=$ROOT_PARTUUID rootflags=subvol=@ rd.vconsole.keymap=$KEYMAP rw
ENTRY
fi

# ===============================
# СОЗДАНИЕ EFI ЗАПИСИ ВРУЧНУЮ (если нужно)
# ===============================
echo "Creating EFI boot entry..."
# Проверяем, смонтированы ли efivars
if [[ -d /sys/firmware/efi/efivars ]]; then
    echo "EFI variables available, creating boot entry..."
    # Пытаемся создать запись через efibootmgr
    EFI_PART="${DISK}${PARTP}1"
    if command -v efibootmgr >/dev/null 2>&1; then
        efibootmgr -c -d "$DISK" -p 1 -L "Arch Linux" -l '\EFI\systemd\systemd-bootx64.efi' || \
        echo "Note: Could not create EFI entry automatically"
    fi
else
    echo "Note: EFI variables not accessible from chroot"
    echo "You may need to create boot entry manually in BIOS"
fi

# ===============================
# FINISH
# ===============================
echo "Cleaning up..."
swapoff "$swapfile" 2>/dev/null || true
umount -R /mnt 2>/dev/null || true

echo -e "\n✅ Installation complete!"
echo "========================================"
echo "Installation Summary:"
echo "----------------------------------------"
echo "Hostname: $HOSTNAME"
echo "Username: $USERNAME"
echo "Timezone: $TIMEZONE"
echo "Root disk: $DISK"
echo "Root PARTUUID: $ROOT_PARTUUID"
echo "========================================"
echo
echo "⚠️  IMPORTANT MANUAL STEPS (if needed):"
echo "1. If system doesn't boot, check BIOS boot order"
echo "2. Ensure 'Arch Linux' is in boot menu"
echo "3. If not, add manual boot entry pointing to:"
echo "   /EFI/systemd/systemd-bootx64.efi"
echo
echo "Next steps after reboot:"
echo "1. Login with your user: $USERNAME"
echo "2. Update system: sudo pacman -Syu"
echo "3. Install additional software as needed"
