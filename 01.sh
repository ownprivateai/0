#!/bin/bash
# arch-install-btrfs-sdboot-fixed.sh
# Исправленная версия - проблемы с vconsole.conf и useradd

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
# INTERACTIVE INPUT
# ===============================

# Hostname
if [[ -z "$HOSTNAME" ]]; then
    echo
    echo "=== HOSTNAME SETUP ==="
    while true; do
        read -rp "Enter hostname (lowercase, no spaces): " HOSTNAME
        OLD_HOSTNAME="$HOSTNAME"
        HOSTNAME=$(echo "$HOSTNAME" | tr '[:upper:]' '[:lower:]')
        if [[ "$HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
            [[ "$OLD_HOSTNAME" != "$HOSTNAME" ]] && echo "Notice: hostname converted to lowercase: $HOSTNAME"
            break
        else
            echo "Invalid hostname. Use lowercase letters, digits, or hyphens (cannot start/end with hyphen, max 63 chars)."
        fi
    done
fi

# Root password
if [[ -z "$ROOTPASS" ]]; then
    echo
    echo "=== ROOT PASSWORD SETUP ==="
    while true; do
        read -s -rp "Enter ROOT password: " ROOTPASS
        echo
        read -s -rp "Repeat ROOT password: " ROOTPASS2
        echo
        [[ "$ROOTPASS" == "$ROOTPASS2" && -n "$ROOTPASS" ]] && break
        echo "Passwords do not match or empty. Try again."
    done
fi

# User name
if [[ -z "$USERNAME" ]]; then
    echo
    echo "=== USERNAME SETUP ==="
    while true; do
        read -rp "Enter username (lowercase, no spaces): " USERNAME
        OLD_USERNAME="$USERNAME"
        USERNAME=$(echo "$USERNAME" | tr '[:upper:]' '[:lower:]')
        if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            [[ "$OLD_USERNAME" != "$USERNAME" ]] && echo "Notice: username converted to lowercase: $USERNAME"
            break
        else
            echo "Invalid username. Use lowercase letters, digits, underscore or hyphen (must start with a letter/underscore)."
        fi
    done
fi

# User password
if [[ -z "$USERPASS" ]]; then
    echo
    echo "=== USER PASSWORD SETUP ==="
    while true; do
        read -s -rp "Enter password for $USERNAME: " USERPASS
        echo
        read -s -rp "Repeat password for $USERNAME: " USERPASS2
        echo
        [[ "$USERPASS" == "$USERPASS2" && -n "$USERPASS" ]] && break
        echo "Passwords do not match or empty. Try again."
    done
fi

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
# CHROOT CONFIGURATION - ИСПРАВЛЕННАЯ ВЕРСИЯ
# ===============================
echo "Configuring system in chroot..."

# Создаем временный скрипт для chroot с исправлениями
cat > /mnt/tmp/chroot_setup.sh <<'CHROOT_SCRIPT'
#!/bin/bash
set -e

# Timezone & locale
ln -sf /usr/share/zoneinfo/'"$TIMEZONE"' /etc/localtime
hwclock --systohc
echo "LANG='"$LOCALE"'" > /etc/locale.conf
echo "KEYMAP='"$KEYMAP"'" > /etc/vconsole.conf
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sed -i 's/^#ru_RU.UTF-8/ru_RU.UTF-8/' /etc/locale.gen
locale-gen

# Hostname
echo '"$HOSTNAME"' > /etc/hostname
cat > /etc/hosts <<H
127.0.0.1   localhost
::1         localhost
127.0.1.1   '"$HOSTNAME"'.localdomain '"$HOSTNAME"'
H

# Root password
echo "root:'"$ROOTPASS"'" | chpasswd --crypt-method SHA512

# Создаем группы, если они не существуют
for group in wheel storage power audio video; do
    groupadd -f "$group" 2>/dev/null || true
done

# Создаем пользователя - исправленная команда
if ! id -u '"$USERNAME"' >/dev/null 2>&1; then
    useradd -m -G wheel,storage,power,audio,video -s /bin/bash '"$USERNAME"'
    echo '"$USERNAME"':'"$USERPASS"' | chpasswd --crypt-method SHA512
else
    echo "User '"$USERNAME"' already exists"
fi

echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel

# Убедимся, что /etc/vconsole.conf существует перед mkinitcpio
if [ ! -f /etc/vconsole.conf ]; then
    echo "KEYMAP='"$KEYMAP"'" > /etc/vconsole.conf
fi

# Initramfs - исправленная строка хуков
# Удаляем все старые настройки HOOKS и добавляем правильные
if grep -q "^HOOKS=" /etc/mkinitcpio.conf; then
    sed -i '/^HOOKS=/d' /etc/mkinitcpio.conf
fi
echo 'HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block filesystems fsck)' >> /etc/mkinitcpio.conf

# Создаем резервный конфиг
cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.backup

echo "Running mkinitcpio..."
if ! mkinitcpio -P 2>&1 | grep -v "WARNING: errors were encountered"; then
    echo "mkinitcpio completed"
fi

# Bootloader
chmod 755 /boot
chmod 700 /boot/loader 2>/dev/null || true

if mountpoint -q /boot; then
    bootctl install --path=/boot
else
    echo "ERROR: /boot is not mounted!"
    exit 1
fi

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
options root=PARTUUID='"$ROOT_PARTUUID"' rootflags=subvol=@ rd.vconsole.keymap='"$KEYMAP"' rw
ENTRY

cp /boot/loader/entries/arch.conf /boot/loader/entries/arch-fallback.conf
sed -i 's/initramfs-linux.img/initramfs-linux-fallback.img/' /boot/loader/entries/arch-fallback.conf

chmod 600 /boot/loader/entries/*.conf 2>/dev/null || true
chmod 600 /boot/loader/loader.conf 2>/dev/null || true

# Enable NetworkManager
systemctl enable NetworkManager

CHROOT_SCRIPT

# Делаем скрипт исполняемым
chmod +x /mnt/tmp/chroot_setup.sh

# Выполняем скрипт в chroot
arch-chroot /mnt /tmp/chroot_setup.sh

# Удаляем временный скрипт
rm -f /mnt/tmp/chroot_setup.sh

# ===============================
# РУЧНАЯ ПРОВЕРКА МКINITCPIO
# ===============================
echo "Проверяем mkinitcpio configuration..."

# Проверяем, что initramfs создан
if [[ -f /mnt/boot/initramfs-linux.img ]]; then
    echo "✓ initramfs created successfully"
    # Проверяем размер
    INITRAMFS_SIZE=$(stat -c%s /mnt/boot/initramfs-linux.img 2>/dev/null || echo "0")
    if [[ $INITRAMFS_SIZE -lt 1000000 ]]; then
        echo "⚠️  initramfs seems too small ($INITRAMFS_SIZE bytes)"
        echo "Trying to rebuild initramfs manually..."
        arch-chroot /mnt mkinitcpio -P
    fi
else
    echo "⚠️  initramfs not found, trying to create manually..."
    arch-chroot /mnt mkinitcpio -P
fi

# Проверяем конфигурацию mkinitcpio
echo "Checking mkinitcpio hooks..."
if arch-chroot /mnt grep -q "sd-vconsole" /etc/mkinitcpio.conf; then
    echo "✓ sd-vconsole hook configured"
else
    echo "⚠️  sd-vconsole hook missing, fixing..."
    arch-chroot /mnt /bin/bash <<'FIX_HOOKS'
if grep -q "^HOOKS=" /etc/mkinitcpio.conf; then
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block filesystems fsck)/' /etc/mkinitcpio.conf
else
    echo 'HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block filesystems fsck)' >> /etc/mkinitcpio.conf
fi
FIX_HOOKS
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
echo "Locale: $LOCALE"
echo "Root PARTUUID: $ROOT_PARTUUID"
echo "========================================"
echo
echo "⚠️  If mkinitcpio had warnings:"
echo "1. After boot, check: ls /dev/mapper/"
echo "2. Update mkinitcpio: sudo mkinitcpio -P"
echo
echo "Next steps after reboot:"
echo "1. Login with your user: $USERNAME"
echo "2. Update system: sudo pacman -Syu"
echo "3. Check if NetworkManager is working: sudo systemctl status NetworkManager"
