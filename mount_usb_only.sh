#!/bin/bash

# USB Mount Only Script - No Audio Configuration
# This script ONLY mounts USB drives without touching any audio settings

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Get the actual user
ACTUAL_USER=${SUDO_USER:-$USER}
MOUNT_POINT="/media/$ACTUAL_USER/gunshot-logger"

print_step "USB Mount Only - No Audio Configuration"
echo "This script will ONLY mount your USB drive."
echo "It will NOT touch any audio configuration."
echo ""

# Check if already mounted
if mountpoint -q "$MOUNT_POINT"; then
    print_status "USB drive already mounted at $MOUNT_POINT"
    df -h "$MOUNT_POINT"
    echo ""
    print_status "You can now run: python3 gunshot_logger.py \"$MOUNT_POINT\""
    exit 0
fi

# Clean up any existing USB mounts
print_step "Cleaning up existing USB mounts..."

# Unmount our specific mount point if it exists
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    print_status "Unmounting existing mount at $MOUNT_POINT..."
    sudo umount "$MOUNT_POINT" 2>/dev/null || true
    sleep 1
fi

# Unmount any USB drives that might be mounted elsewhere
usb_mounts=$(mount | grep -E "(sda|sdb|sdc)" | awk '{print $3}' || true)
if [ -n "$usb_mounts" ]; then
    print_warning "Found existing USB mounts, unmounting them..."
    echo "$usb_mounts" | while read mount_point; do
        if [ -n "$mount_point" ] && [ "$mount_point" != "$MOUNT_POINT" ]; then
            print_status "Unmounting $mount_point..."
            sudo umount "$mount_point" 2>/dev/null || true
        fi
    done
    sleep 2
fi

# Remove any stale mount points
if [ -d "$MOUNT_POINT" ]; then
    print_status "Removing stale mount point directory..."
    sudo rmdir "$MOUNT_POINT" 2>/dev/null || true
fi

print_status "USB cleanup complete"
echo ""

# Show available USB devices
print_step "Available USB devices:"
lsblk | grep -E "(sda|sdb|sdc)"

echo ""
print_step "Waiting for USB partition..."

# Wait up to 10 seconds for USB device to appear
usb_dev=""
for i in {1..10}; do
    # Look for any unmounted partition on /dev/sd*
    usb_dev=$(lsblk -pnro NAME,TYPE,MOUNTPOINT \
               | awk '$2=="part" && $3=="" && $1 ~ /^\/dev\/sd/ {print $1; exit}')
    if [ -n "$usb_dev" ]; then 
        break
    fi
    print_status "Waiting for USB device... (attempt $i/10)"
    sleep 1
done

# If automatic detection failed, try hardcoded fallback
if [ -z "$usb_dev" ]; then
    print_warning "Automatic USB detection failed, trying hardcoded fallback..."
    
    # Check if /dev/sda1 exists and is unmounted
    if [ -b "/dev/sda1" ] && ! mountpoint -q "/dev/sda1" 2>/dev/null; then
        usb_dev="/dev/sda1"
        print_status "Using hardcoded fallback: $usb_dev"
    else
        print_error "No USB partition found after waiting 10 seconds."
        echo ""
        print_error "Manual mount options:"
        print_status "1. Find your USB device: lsblk"
        print_status "2. Mount manually: sudo mount /dev/sda1 $MOUNT_POINT"
        exit 1
    fi
fi

print_status "Found USB device: $usb_dev"

# Get filesystem type
fstype=$(sudo blkid -s TYPE -o value "$usb_dev" 2>/dev/null || echo "vfat")
print_status "Filesystem type: $fstype"

# Create mount directory
print_status "Creating mount directory..."
sudo mkdir -p "$MOUNT_POINT"
sudo chown "$ACTUAL_USER:$ACTUAL_USER" "$MOUNT_POINT"
sudo chmod 755 "$MOUNT_POINT"

# Try mounting with retries
mount_opts="uid=$(id -u $ACTUAL_USER),gid=$(id -g $ACTUAL_USER),noatime"

for attempt in 1 2 3; do
    print_status "Mounting attempt $attempt: sudo mount -t $fstype -o $mount_opts $usb_dev $MOUNT_POINT"
    
    if sudo mount -t "$fstype" -o "$mount_opts" "$usb_dev" "$MOUNT_POINT"; then
        print_status "✓ Mounted $usb_dev → $MOUNT_POINT"
        df -h "$MOUNT_POINT"
        echo ""
        print_status "USB mount successful!"
        print_status "You can now run: python3 gunshot_logger.py \"$MOUNT_POINT\""
        exit 0
    else
        print_warning "Mount failed, retrying in 2s... (attempt $attempt/3)"
        sleep 2
    fi
done

# Final hardcoded fallback attempt
print_warning "All mount attempts failed, trying final hardcoded fallback..."
if sudo mount -t vfat -o "uid=$(id -u $ACTUAL_USER),gid=$(id -g $ACTUAL_USER),noatime" "/dev/sda1" "$MOUNT_POINT"; then
    print_status "✓ Hardcoded fallback successful: /dev/sda1 → $MOUNT_POINT"
    df -h "$MOUNT_POINT"
    echo ""
    print_status "USB mount successful!"
    print_status "You can now run: python3 gunshot_logger.py \"$MOUNT_POINT\""
    exit 0
fi

print_error "Failed to mount ${usb_dev:-/dev/sda1} at $MOUNT_POINT after all attempts."
echo ""
print_error "Manual mount options:"
print_status "1. Find your USB device: lsblk"
print_status "2. Mount manually: sudo mount /dev/sda1 $MOUNT_POINT"
print_status "3. Then run: python3 gunshot_logger.py \"$MOUNT_POINT\""
exit 1 