#!/bin/bash
# AI-OS Bootstrap Script (Arch Linux Base)
# WARNING: This script will format the target disk. Use with extreme caution.
# Usage: ./bootstrap_ai_os.sh /dev/nvme0n1

DISK=$1

if [ -z "$DISK" ]; then
    echo "Usage: $0 /dev/nvme0n1"
    exit 1
fi

echo "!!! WARNING: ALL DATA ON $DISK WILL BE ERASED !!!"
read -p "Are you sure? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

# 1. Partitioning
echo "Partitioning $DISK..."
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart "ESP" fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart "AI_ROOT" xfs 513MiB 100%

# 2. Formatting
echo "Formatting..."
if [[ "$DISK" == *"nvme"* ]]; then
    PART1="${DISK}p1"
    PART2="${DISK}p2"
else
    PART1="${DISK}1"
    PART2="${DISK}2"
fi

mkfs.fat -F32 "$PART1"
mkfs.xfs -f "$PART2"

mount "$PART2" /mnt
mkdir -p /mnt/boot
mount "$PART1" /mnt/boot"

# 3. Mounting
echo "Mounting..."
mount "${DISK}p2" /mnt
mkdir -p /mnt/boot
mount "${DISK}p1" /mnt/boot

# 4. Bootstrap
echo "Installing Base System..."
# Using Intel ucode as requested for i7
pacstrap /mnt base base-devel linux-firmware intel-ucode vim git networkmanager openssh zram-generator

# 5. Fstab
echo "Generating Fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# 5.1 Copy Custom Configs
echo "Applying AI-OS Configurations..."
SCRIPT_DIR=$(dirname "$(realpath "$0")")
CONFIG_DIR="$SCRIPT_DIR/../configs"

if [ -d "$CONFIG_DIR" ]; then
    echo "Found custom configs in $CONFIG_DIR"
    cp "$CONFIG_DIR/99-ai-os.conf" /mnt/etc/sysctl.d/
    cp "$CONFIG_DIR/ollama.service" /mnt/etc/systemd/system/
    cp "$CONFIG_DIR/makepkg.conf" /mnt/etc/makepkg.conf
    cp "$CONFIG_DIR/blacklist.conf" /mnt/etc/modprobe.d/
else
    echo "WARNING: Config directory not found. Skipping customization."
fi

# 6. Basic Config Script for Chroot
cat <<EOF > /mnt/setup_chroot.sh
#!/bin/bash
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "ai-os" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "127.0.1.1 ai-os.localdomain ai-os" >> /etc/hosts

# Set root password
echo "Set root password:"
passwd

# Create AI user
useradd -m -G wheel -s /bin/bash ai-user
echo "Set ai-user password:"
passwd ai-user
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# Enable ZRAM (100% RAM size)
echo "[zram0]" > /etc/systemd/zram-generator.conf
echo "zram-size = ram" >> /etc/systemd/zram-generator.conf
echo "compression-algorithm = zstd" >> /etc/systemd/zram-generator.conf

# Bootloader (systemd-boot)
bootctl install
echo "title   AI-OS" > /boot/loader/entries/arch.conf
echo "linux   /vmlinuz-linux" >> /boot/loader/entries/arch.conf
echo "initrd  /intel-ucode.img" >> /boot/loader/entries/arch.conf
echo "initrd  /initramfs-linux.img" >> /boot/loader/entries/arch.conf
echo "options root=PARTUUID=\$(blkid -s PARTUUID -o value ${DISK}p2) rw auditing=0 mitigations=off" >> /boot/loader/entries/arch.conf

# Enable Network
systemctl enable NetworkManager

EOF

chmod +x /mnt/setup_chroot.sh

echo "Bootstrap complete. Chrooting..."
arch-chroot /mnt ./setup_chroot.sh

echo "Done! You can reboot now."
