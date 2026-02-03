#!/bin/bash
# arch-install-btrfs-sdboot.sh
# Clean Arch Linux installation: Btrfs + systemd-boot (с опциональным LUKS)

set -euo pipefail

# ===============================
# CONFIGURATION - НАСТРОЙТЕ ЗДЕСЬ
# ===============================
ENABLE_LUKS=false                    # true = с шифрованием, false = без шифрования
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

# ===============================
# DISPLAY CURRENT CONFIG
# ===============================
echo "========================================"
echo "Arch Linux Installer Configuration"
echo "========================================"
echo "Encryption (LUKS): $([ "$ENABLE_LUKS" = true ] && echo "ENABLED" || echo "DISABLED")"
echo "Timezone: $TIMEZONE"
echo "Locale: $LOCALE"
echo "Keymap: $KEYMAP"
echo "Swap size: $SWAP_SIZE"
echo "========================================"
echo

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
        HOSTNAME=$(echo "$HOSTNAME" | tr '[:upper:]' '[:lower:]')   # авто-лоуэркейз
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
    echo "!!! ROOT PASSWORD WILL BE USED FOR SYSTEM ADMINISTRATION !!!"
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
        USERNAME=$(echo "$USERNAME" | tr '[:upper:]' '[:lower:]')   # авто-лоуэркейз
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
[[ $DISK =~ [0-9]$ ]] && PARTP=p || PARTP=

echo "Cleaning disk and creating partitions..."
sgdisk -Z "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$DISK"
sgdisk -n 2:0:0  -t 2:8300 -c 2:ROOT "$DISK"

# ===============================
# LUKS ENCRYPTION (УСЛОВНО)
# ===============================
if [[ "$ENABLE_LUKS" = true ]]; then
    echo "Setting up LUKS encryption..."
    cryptsetup luksFormat --perf-no_read_workqueue --perf-no_write_workqueue --iter-time 2000 "${DISK}${PARTP}2"
    cryptsetup open --allow-discards "${DISK}${PARTP}2" cryptroot
    ROOT_DEVICE="/dev/mapper/cryptroot"
    ROOT_UUID=$(blkid -s UUID -o value "${DISK}${PARTP}2")
else
    echo "Skipping LUKS encryption..."
    ROOT_DEVICE="${DISK}${PARTP}2"
    ROOT_PARTUUID=$(blkid -s PARTUUID -o value "${DISK}${PARTP}2")
fi

# ===============================
# BTRFS SUBVOLUMES
# ===============================
echo "Creating Btrfs filesystem and subvolumes..."
mkfs.btrfs -f -L ArchRoot "$ROOT_DEVICE"
mount "$ROOT_DEVICE" /mnt

for vol in @ @home @snapshots @log @pkg @tmp @opt @swap; do
    btrfs subvolume create "/mnt/$vol"
done

umount /mnt

# ===============================
# MOUNT SUBVOLUMES
# ===============================
mount_opts="noatime,ssd,discard=async,compress=zstd"
special_opts="nodatacow,compress=no"

mount -o "$mount_opts,subvol=@" "$ROOT_DEVICE" /mnt

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
    mount -o "$mount_opts,subvol=$sv" "$ROOT_DEVICE" "${subvolumes[$sv]}"
done

for sv in "${!special_subvols[@]}"; do
    mount -o "$special_opts,subvol=$sv" "$ROOT_DEVICE" "${special_subvols[$sv]}"
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

if [[ "$ENABLE_LUKS" = true ]]; then
    echo "Installing encryption packages..."
    pacstrap -K /mnt cryptsetup
fi

# ===============================
# FSTAB
# ===============================
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# ===============================
# CHROOT CONFIGURATION
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

# Initramfs configuration
if [[ "$ENABLE_LUKS" = true ]]; then
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
else
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block filesystems fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

# Bootloader
bootctl install
cat > /boot/loader/loader.conf <<LOADER
default arch
timeout 3
console-mode max
editor no
LOADER

# Create boot entry based on encryption setting
if [[ "$ENABLE_LUKS" = true ]]; then
    cat > /boot/loader/entries/arch.conf <<ENTRY
title Arch Linux (LUKS Encrypted)
linux /vmlinuz-linux
initrd /initramfs-linux.img
options rd.luks.name=$ROOT_UUID=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rd.luks.options=discard rd.vconsole.keymap=$KEYMAP rw
ENTRY
else
    cat > /boot/loader/entries/arch.conf <<ENTRY
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=PARTUUID=$ROOT_PARTUUID rootflags=subvol=@ rd.vconsole.keymap=$KEYMAP rw
ENTRY
fi

# Create a fallback entry
cp /boot/loader/entries/arch.conf /boot/loader/entries/arch-fallback.conf
sed -i 's/initramfs-linux.img/initramfs-linux-fallback.img/' /boot/loader/entries/arch-fallback.conf

# Enable NetworkManager
systemctl enable NetworkManager

EOF

# ===============================
# FINISH
# ===============================
swapoff "$swapfile" 2>/dev/null || true
umount -R /mnt

if [[ "$ENABLE_LUKS" = true ]]; then
    cryptsetup close cryptroot
fi

echo -e "\n✅ Installation complete!"
echo "========================================"
echo "Installation Summary:"
echo "----------------------------------------"
echo "Hostname: $HOSTNAME"
echo "Username: $USERNAME"
echo "Encryption: $([ "$ENABLE_LUKS" = true ] && echo "ENABLED" || echo "DISABLED")"
echo "Timezone: $TIMEZONE"
echo "Locale: $LOCALE"
echo "========================================"
echo
echo "Next steps:"
echo "1. Reboot the system: sudo reboot"
echo "2. After login: sudo pacman -Syu"
echo "3. Install additional packages as needed"
echo
if [[ "$ENABLE_LUKS" = true ]]; then
    echo "⚠️  IMPORTANT: You will be prompted for LUKS password on boot!"
fi
