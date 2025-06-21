#!/bin/bash

# Gunshot Logger - Raspberry Pi Setup Script
# This script sets up the complete gunshot detection system on a fresh Raspberry Pi
# Enhanced with reliable USB mounting, dynamic device detection, and robust error handling

set -e  # Exit on any error
set -u  # Exit on undefined variables

# Script hardening
trap 'echo "[ERROR] Script failed at line $LINENO. Check setup.log for details." >&2' ERR
trap 'echo "[INFO] Setup interrupted by user." >&2' INT TERM

# Setup logging
exec 1> >(tee -a setup.log)
exec 2> >(tee -a setup.log >&2)

echo "=========================================="
echo "Gunshot Logger - Raspberry Pi Setup"
echo "Started at: $(date)"
echo "Script version: $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
echo "=========================================="

echo "[INFO] This script can be run as:"
echo "  - Normal user: ./setup_raspberry_pi.sh"
echo "  - With sudo: sudo ./setup_raspberry_pi.sh"
echo "  - As root: ./setup_raspberry_pi.sh (if already root)"
echo ""

# Validate environment
if [ "$EUID" -eq 0 ] && [ "$SUDO_USER" = "" ]; then
    echo "[ERROR] Do not run this script directly as root. Run as your normal user."
    echo "[INFO] Usage: ./setup_raspberry_pi.sh (not sudo ./setup_raspberry_pi.sh)"
    exit 1
fi

# Get the actual user (works whether run as root via sudo or as normal user)
ACTUAL_USER=${SUDO_USER:-$USER}

if ! command -v sudo >/dev/null 2>&1; then
    echo "[ERROR] sudo is required but not installed."
    exit 1
fi

# Test sudo access (only if not already root)
if [ "$EUID" -ne 0 ]; then
    echo "[INFO] Testing sudo access..."
    sudo true || {
        echo "[ERROR] No sudo access. Please ensure your user has sudo privileges."
        exit 1
    }
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
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

# Cleanup function
cleanup() {
    local exit_code=$?
    echo ""
    if [ $exit_code -eq 0 ]; then
        print_status "Setup completed successfully!"
    else
        print_error "Setup failed with exit code $exit_code"
        print_error "Check setup.log for detailed error information"
    fi
    echo "Setup completed at: $(date)"
    exit $exit_code
}

# Set cleanup trap
trap cleanup EXIT

# Retry function for unreliable operations
retry() {
    local n=0
    local max_attempts=3
    local delay=2
    
    until [ $n -ge $max_attempts ]; do
        if "$@"; then
            return 0
        else
            n=$((n+1))
            if [ $n -lt $max_attempts ]; then
                print_warning "Command failed, retrying in ${delay}s... (attempt $n/$max_attempts)"
                sleep $delay
            fi
        fi
    done
    
    print_error "Command '$*' failed after $max_attempts attempts"
    return 1
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to run commands with sudo (handles both root and normal user)
run_sudo() {
    if [ "$EUID" -eq 0 ]; then
        # Already root, run command directly
        "$@"
    else
        # Not root, use sudo
        sudo "$@"
    fi
}

# Function to detect current user
get_current_user() {
    # Use the actual user we detected at script start
    if [ -n "$ACTUAL_USER" ]; then
        echo "$ACTUAL_USER"
    else
        # Fallback to whoami
        local user=$(whoami)
        if [ -z "$user" ]; then
            print_error "Could not determine current user"
            exit 1
        fi
        echo "$user"
    fi
}

# Function to detect USB drive
detect_usb_drive() {
    print_status "Detecting USB drive..."
    
    # Wait for USB devices to be recognized
    sleep 2
    
    # Look for USB storage devices
    local usb_devices=($(lsblk -no NAME,TYPE,MOUNTPOINT | awk '$2=="part" && $3=="" {print $1}'))
    
    if [ ${#usb_devices[@]} -eq 0 ]; then
        print_error "No USB drive detected. Please insert a USB drive and run setup again."
        return 1
    fi
    
    # Use the first USB device found
    local usb_device="/dev/${usb_devices[0]}"
    print_status "Found USB device: $usb_device"
    
    # Get UUID and filesystem type
    local uuid=$(sudo blkid -s UUID -o value "$usb_device" 2>/dev/null || echo "")
    local fstype=$(sudo blkid -s TYPE -o value "$usb_device" 2>/dev/null || echo "vfat")
    
    if [ -z "$uuid" ]; then
        print_warning "Could not get UUID for $usb_device, using device name"
        echo "$usb_device"
    else
        print_status "USB UUID: $uuid"
        echo "UUID=$uuid"
    fi
}

# Function to detect audio card
detect_audio_card() {
    print_status "Detecting audio devices..."
    
    # Show all audio cards
    aplay -l
    
    # Try to detect I2S/Google Voice Hat card
    local i2s_card=$(cat /proc/asound/cards | awk '/I2S/ || /Voice/ || /Google/ {print $1; exit}')
    
    if [ -n "$i2s_card" ]; then
        print_status "Detected I2S card: $i2s_card"
        echo "$i2s_card"
    else
        # Fallback to card 2 (common for Google Voice Hat)
        print_warning "Could not detect I2S card, using default card 2"
        echo "2"
    fi
}

# Function to setup USB mounting
setup_usb_mount() {
    print_step "Setting up reliable USB mounting..."
    
    # Get current user
    local current_user=$(get_current_user)
    local mount_point="/media/$current_user/gunshots"
    
    print_status "Using user: $current_user"
    print_status "Mount point: $mount_point"
    
    # Create mount directory structure
    sudo mkdir -p "$mount_point"
    if [ $? -ne 0 ]; then
        print_error "Failed to create mount directory: $mount_point"
        return 1
    fi
    
    # Set ownership to current user
    sudo chown "$current_user:$current_user" "$mount_point"
    if [ $? -ne 0 ]; then
        print_error "Failed to set ownership of $mount_point to $current_user"
        return 1
    fi
    
    sudo chmod 755 "$mount_point"
    
    # Bulletproof USB mounting with retries
    print_status "Waiting for USB partition..."
    local usb_dev=""
    
    # Wait up to 10 seconds for USB device to appear
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
    
    if [ -z "$usb_dev" ]; then
        print_error "No USB partition found after waiting 10 seconds."
        print_error "Please insert a USB drive and try again."
        return 1
    fi
    
    print_status "Detected USB partition: $usb_dev"
    
    # Get filesystem type
    local fstype=$(sudo blkid -s TYPE -o value "$usb_dev" 2>/dev/null || echo "vfat")
    print_status "Filesystem type: $fstype"
    
    # Try mounting with retries
    local mount_opts="uid=$(id -u $current_user),gid=$(id -g $current_user),noatime"
    
    for attempt in 1 2 3; do
        print_status "Mounting attempt $attempt: sudo mount -t $fstype -o $mount_opts $usb_dev $mount_point"
        
        if sudo mount -t "$fstype" -o "$mount_opts" "$usb_dev" "$mount_point"; then
            print_status "✓ Mounted $usb_dev → $mount_point"
            
            # Show mount info
            df -h "$mount_point"
            return 0
        else
            print_warning "Mount failed, retrying in 2s... (attempt $attempt/3)"
            sleep 2
        fi
    done
    
    print_error "Failed to mount $usb_dev at $mount_point after 3 attempts."
    print_error "Please check USB drive and try again."
    return 1
}

# Function to verify USB mount
verify_usb_mount() {
    local current_user=$(get_current_user)
    local mount_point="/media/$current_user/gunshots"
    
    if ! mountpoint -q "$mount_point"; then
        print_error "USB drive is not mounted at $mount_point"
        return 1
    fi
    
    if [ ! -w "$mount_point" ]; then
        print_error "USB drive is not writable"
        return 1
    fi
    
    print_status "USB drive is properly mounted and writable at $mount_point"
    return 0
}

# Step 1: Install required packages (skip OS updates)
print_step "Step 1: Installing required packages..."
retry sudo apt install -y python3 python3-pip git alsa-utils util-linux python3-numpy python3-scipy python3-psutil

# Step 2: Install pip packages that aren't available in apt
print_step "Step 2: Installing additional Python packages..."
retry pip3 install sounddevice --break-system-packages

# Step 3: Kill existing service if running
print_step "Step 3: Stopping existing service if running..."
if sudo systemctl is-active --quiet gunshot-logger.service; then
    print_status "Stopping existing gunshot-logger service..."
    sudo systemctl stop gunshot-logger.service
    sudo systemctl disable gunshot-logger.service
    sleep 2
fi

# Step 4: Clone repository
print_step "Step 4: Cloning repository..."
cd ~
if [ -d "gunshot-logger" ]; then
    print_warning "gunshot-logger directory already exists, removing..."
    rm -rf gunshot-logger
fi
retry git clone https://github.com/quickSecureLLC/gunshot-logger.git
cd gunshot-logger

# Step 5: Configure audio system
print_step "Step 5: Configuring audio system..."

# Detect audio card dynamically
audio_card=$(detect_audio_card)

# Create ALSA configuration
print_status "Creating ALSA configuration for card $audio_card..."
sudo tee /etc/asound.conf > /dev/null <<EOF
pcm.!default {
    type hw
    card $audio_card
    device 0
}

ctl.!default {
    type hw
    card $audio_card
}
EOF

# Step 6: Setup USB mounting
print_step "Step 6: Setting up USB mounting..."
if ! setup_usb_mount; then
    print_warning "USB setup failed, continuing without USB mount"
    print_warning "You will need to manually mount USB drive later"
fi

# Step 7: Test audio system
print_step "Step 7: Testing audio system..."
if ! python3 test_audio.py; then
    print_error "Audio test failed"
    exit 1
fi

# Step 8: Create systemd service with pre-checks
print_step "Step 8: Creating systemd service..."

# Get current user for service configuration
current_user=$(get_current_user)
mount_point="/media/$current_user/gunshots"

sudo tee /etc/systemd/system/gunshot-logger.service > /dev/null <<EOF
[Unit]
Description=Gunshot Detection and Logging Service
After=multi-user.target

[Service]
Type=simple
User=$current_user
WorkingDirectory=/home/$current_user/gunshot-logger
Environment="PYTHONUNBUFFERED=1"
ExecStartPre=/bin/bash -c 'if [ ! -d "$mount_point" ]; then echo "Mount point does not exist"; exit 1; fi'
ExecStartPre=/bin/bash -c 'if [ ! -w "$mount_point" ]; then echo "Mount point not writable"; exit 1; fi'
ExecStart=/usr/bin/python3 /home/$current_user/gunshot-logger/gunshot_logger.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Step 9: Enable and start service
print_step "Step 9: Enabling and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable gunshot-logger.service

# Step 10: Create enhanced verification script
print_step "Step 10: Creating verification script..."

# Get current user for verification script
current_user=$(get_current_user)
mount_point="/media/$current_user/gunshots"

tee verify_setup.sh > /dev/null <<EOF
#!/bin/bash

echo "=========================================="
echo "Gunshot Logger - Enhanced Setup Verification"
echo "=========================================="

# Check service status
echo "1. Checking service status..."
if sudo systemctl is-active --quiet gunshot-logger.service; then
    echo "✓ Service is running"
    sudo systemctl status gunshot-logger.service --no-pager -l
else
    echo "✗ Service is not running"
    sudo systemctl status gunshot-logger.service --no-pager -l
fi

echo ""
echo "2. Checking recent logs..."
sudo journalctl -u gunshot-logger.service --since "5 minutes ago" --no-pager

echo ""
echo "3. Checking audio devices..."
aplay -l

echo ""
echo "4. Checking USB drive mount..."
if mountpoint -q "$mount_point"; then
    echo "✓ USB drive is mounted"
    df -h "$mount_point"
    ls -la "$mount_point/"
else
    echo "✗ USB drive is not mounted"
    echo "Available USB devices:"
    lsblk | grep -E "(sda|sdb|sdc)"
    echo ""
    echo "To mount USB drive manually:"
    echo "./mount_usb.sh"
fi

echo ""
echo "5. Checking mount point permissions..."
if [ -d "$mount_point" ]; then
    echo "✓ Mount point exists"
    ls -ld "$mount_point"
else
    echo "✗ Mount point does not exist"
fi

echo ""
echo "6. Checking log file..."
if [ -f "gunshot_detection.log" ]; then
    echo "✓ Log file exists"
    tail -10 gunshot_detection.log
else
    echo "✗ Log file not found"
fi

echo ""
echo "7. Testing audio system..."
if python3 test_audio.py > /dev/null 2>&1; then
    echo "✓ Audio test passed"
else
    echo "✗ Audio test failed"
fi

echo ""
echo "8. Checking Python dependencies..."
python3 -c "import numpy, sounddevice, scipy, psutil; print('✓ All dependencies installed')" 2>/dev/null || echo "✗ Missing dependencies"

echo ""
echo "Verification complete!"
EOF

chmod +x verify_setup.sh

# Step 11: Create enhanced troubleshooting script
print_step "Step 11: Creating troubleshooting script..."

# Get current user for troubleshooting script
current_user=$(get_current_user)
mount_point="/media/$current_user/gunshots"

tee troubleshoot.sh > /dev/null <<EOF
#!/bin/bash

echo "=========================================="
echo "Gunshot Logger - Enhanced Troubleshooting"
echo "=========================================="

echo "1. Checking system status..."
echo "CPU usage:"
top -bn1 | grep "Cpu(s)" | awk '{print \$2}' | cut -d'%' -f1

echo "Memory usage:"
free -h

echo "Disk usage:"
df -h

echo ""
echo "2. Checking USB drive..."
echo "USB devices:"
lsblk | grep -E "(sda|sdb|sdc)"

echo ""
echo "Mount status:"
mount | grep media

echo ""
echo "3. Checking audio system..."
echo "Audio cards:"
cat /proc/asound/cards

echo ""
echo "ALSA config:"
cat /etc/asound.conf

echo ""
echo "4. Restarting service..."
sudo systemctl restart gunshot-logger.service

echo ""
echo "5. Checking service status..."
sudo systemctl status gunshot-logger.service --no-pager

echo ""
echo "6. Viewing real-time logs (Ctrl+C to exit)..."
sudo journalctl -u gunshot-logger.service -f
EOF

chmod +x troubleshoot.sh

# Step 12: Create USB mount helper script
print_step "Step 12: Creating USB mount helper..."

# Get current user for mount helper
current_user=$(get_current_user)
mount_point="/media/$current_user/gunshots"

tee mount_usb.sh > /dev/null <<EOF
#!/bin/bash

echo "=========================================="
echo "USB Drive Mount Helper"
echo "=========================================="

# Check if already mounted
if mountpoint -q "$mount_point"; then
    echo "✓ USB drive already mounted at $mount_point"
    df -h "$mount_point"
    exit 0
fi

echo "Available USB devices:"
lsblk | grep -E "(sda|sdb|sdc)"

echo ""
echo "Waiting for USB partition..."

# Wait up to 10 seconds for USB device to appear
usb_dev=""
for i in {1..10}; do
    # Look for any unmounted partition on /dev/sd*
    usb_dev=$(lsblk -pnro NAME,TYPE,MOUNTPOINT \
               | awk '$2=="part" && $3=="" && $1 ~ /^\/dev\/sd/ {print $1; exit}')
    if [ -n "$usb_dev" ]; then 
        break
    fi
    echo "Waiting for USB device... (attempt $i/10)"
    sleep 1
done

if [ -z "$usb_dev" ]; then
    echo "✗ No USB partition found after waiting 10 seconds."
    echo ""
    echo "Manual mount options:"
    echo "1. Find your USB device: lsblk"
    echo "2. Mount manually: sudo mount /dev/sda1 $mount_point"
    exit 1
fi

echo "Found USB device: $usb_dev"

# Get filesystem type
fstype=$(sudo blkid -s TYPE -o value "$usb_dev" 2>/dev/null || echo "vfat")
echo "Filesystem type: $fstype"

# Try mounting with retries
mount_opts="uid=$(id -u),gid=$(id -g),noatime"

for attempt in 1 2 3; do
    echo "Mounting attempt $attempt: sudo mount -t $fstype -o $mount_opts $usb_dev $mount_point"
    
    if sudo mount -t "$fstype" -o "$mount_opts" "$usb_dev" "$mount_point"; then
        echo "✓ Mounted $usb_dev → $mount_point"
        df -h "$mount_point"
        exit 0
    else
        echo "Mount failed, retrying in 2s... (attempt $attempt/3)"
        sleep 2
    fi
done

echo "✗ Failed to mount $usb_dev at $mount_point after 3 attempts."
echo ""
echo "Manual mount options:"
echo "1. Find your USB device: lsblk"
echo "2. Mount manually: sudo mount /dev/sda1 $mount_point"
exit 1
EOF

chmod +x mount_usb.sh

# Step 13: Final verification and start
print_step "Step 13: Final verification and service start..."

# Verify USB mount before starting service
if verify_usb_mount; then
    print_status "Starting gunshot logger service..."
    sudo systemctl start gunshot-logger.service
    
    # Wait a moment and check status
    sleep 3
    if sudo systemctl is-active --quiet gunshot-logger.service; then
        print_status "✓ Service started successfully"
    else
        print_error "✗ Service failed to start"
        sudo systemctl status gunshot-logger.service --no-pager
    fi
else
    print_warning "USB not mounted, starting service anyway..."
    sudo systemctl start gunshot-logger.service
fi

print_status "Setup complete!"
echo ""
echo "=========================================="
echo "SETUP COMPLETE - NEXT STEPS:"
echo "=========================================="
echo "1. Verify setup:"
echo "   ./verify_setup.sh"
echo ""
echo "2. If USB not mounted, run:"
echo "   ./mount_usb.sh"
echo ""
echo "3. Monitor logs:"
echo "   sudo journalctl -u gunshot-logger.service -f"
echo ""
echo "4. Test with loud sound and check:"
echo "   ls -la /media/pi/gunshots/"
echo ""
echo "5. If issues, run troubleshooting:"
echo "   ./troubleshoot.sh"
echo ""
echo "=========================================="
echo "Configuration file: gunshot_logger.py"
echo "Audio card detected: $audio_card"
echo "Adjust DETECTION_THRESHOLD and OPERATING_HOURS as needed"
echo "=========================================="
echo "Setup completed at: $(date)"
echo "Log file: setup.log" 