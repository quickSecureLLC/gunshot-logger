#!/bin/bash

# Gunshot Logger - Raspberry Pi Setup Script
# This script sets up the complete gunshot detection system on a fresh Raspberry Pi
# Enhanced with reliable USB mounting, dynamic device detection, and robust error handling

set -e  # Exit on any error

# Setup logging
exec 1> >(tee -a setup.log)
exec 2> >(tee -a setup.log >&2)

echo "=========================================="
echo "Gunshot Logger - Raspberry Pi Setup"
echo "Started at: $(date)"
echo "=========================================="

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
    
    # Create mount directory structure
    sudo mkdir -p /media/pi/gunshots
    sudo chown pi:pi /media/pi/gunshots
    sudo chmod 755 /media/pi/gunshots
    
    # Detect USB drive
    local usb_identifier=$(detect_usb_drive)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Get filesystem type
    local fstype="vfat"
    if [[ "$usb_identifier" == UUID=* ]]; then
        local uuid=${usb_identifier#UUID=}
        fstype=$(sudo blkid -s TYPE -o value -U "$uuid" 2>/dev/null || echo "vfat")
    else
        fstype=$(sudo blkid -s TYPE -o value "$usb_identifier" 2>/dev/null || echo "vfat")
    fi
    
    print_status "Filesystem type: $fstype"
    
    # Create fstab entry
    local fstab_entry="$usb_identifier /media/pi/gunshots $fstype defaults,noatime,uid=1000,gid=1000 0 2"
    
    # Check if entry already exists
    if ! grep -q "/media/pi/gunshots" /etc/fstab; then
        print_status "Adding USB mount to /etc/fstab..."
        echo "$fstab_entry" | sudo tee -a /etc/fstab > /dev/null
    else
        print_warning "USB mount entry already exists in /etc/fstab"
    fi
    
    # Try to mount
    print_status "Mounting USB drive..."
    if sudo mount /media/pi/gunshots; then
        print_status "USB drive mounted successfully"
        return 0
    else
        print_error "Failed to mount USB drive"
        return 1
    fi
}

# Function to verify USB mount
verify_usb_mount() {
    if ! mountpoint -q /media/pi/gunshots; then
        print_error "USB drive is not mounted at /media/pi/gunshots"
        return 1
    fi
    
    if [ ! -w /media/pi/gunshots ]; then
        print_error "USB drive is not writable"
        return 1
    fi
    
    print_status "USB drive is properly mounted and writable"
    return 0
}

# Step 1: Install required packages (skip OS updates)
print_step "Step 1: Installing required packages..."
retry sudo apt install -y python3 python3-pip git alsa-utils util-linux python3-numpy python3-scipy python3-psutil

# Step 2: Install pip packages that aren't available in apt
print_step "Step 2: Installing additional Python packages..."
retry pip3 install sounddevice --break-system-packages

# Step 3: Clone repository
print_step "Step 3: Cloning repository..."
cd ~
if [ -d "gunshot-logger" ]; then
    print_warning "gunshot-logger directory already exists, removing..."
    rm -rf gunshot-logger
fi
retry git clone https://github.com/quickSecureLLC/gunshot-logger.git
cd gunshot-logger

# Step 4: Configure audio system
print_step "Step 4: Configuring audio system..."

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

# Step 5: Setup USB mounting
print_step "Step 5: Setting up USB mounting..."
if ! setup_usb_mount; then
    print_warning "USB setup failed, continuing without USB mount"
    print_warning "You will need to manually mount USB drive later"
fi

# Step 6: Test audio system
print_step "Step 6: Testing audio system..."
if ! python3 test_audio.py; then
    print_error "Audio test failed"
    exit 1
fi

# Step 7: Create systemd service with pre-checks
print_step "Step 7: Creating systemd service..."
sudo tee /etc/systemd/system/gunshot-logger.service > /dev/null <<EOF
[Unit]
Description=Gunshot Detection and Logging Service
After=multi-user.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/gunshot-logger
Environment="PYTHONUNBUFFERED=1"
ExecStartPre=/bin/bash -c 'if ! mountpoint -q /media/pi/gunshots; then echo "USB not mounted, attempting to mount..."; mount /media/pi/gunshots || exit 1; fi'
ExecStartPre=/bin/bash -c 'if [ ! -w /media/pi/gunshots ]; then echo "USB not writable"; exit 1; fi'
ExecStart=/usr/bin/python3 /home/pi/gunshot-logger/gunshot_logger.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Step 8: Enable and start service
print_step "Step 8: Enabling and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable gunshot-logger.service

# Step 9: Create enhanced verification script
print_step "Step 9: Creating verification script..."
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
if mountpoint -q /media/pi/gunshots; then
    echo "✓ USB drive is mounted"
    df -h /media/pi/gunshots
    ls -la /media/pi/gunshots/
else
    echo "✗ USB drive is not mounted"
    echo "Available USB devices:"
    lsblk | grep -E "(sda|sdb|sdc)"
fi

echo ""
echo "5. Checking fstab entry..."
if grep -q "/media/pi/gunshots" /etc/fstab; then
    echo "✓ fstab entry exists"
    grep "/media/pi/gunshots" /etc/fstab
else
    echo "✗ fstab entry missing"
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

# Step 10: Create enhanced troubleshooting script
print_step "Step 10: Creating troubleshooting script..."
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

# Step 11: Create USB mount helper script
print_step "Step 11: Creating USB mount helper..."
tee mount_usb.sh > /dev/null <<EOF
#!/bin/bash

echo "=========================================="
echo "USB Drive Mount Helper"
echo "=========================================="

echo "Available USB devices:"
lsblk | grep -E "(sda|sdb|sdc)"

echo ""
echo "Attempting to mount USB drive..."

# Try to mount using fstab
if sudo mount /media/pi/gunshots; then
    echo "✓ USB drive mounted successfully"
    df -h /media/pi/gunshots
else
    echo "✗ Failed to mount using fstab"
    echo ""
    echo "Manual mount options:"
    echo "1. Find your USB device: lsblk"
    echo "2. Mount manually: sudo mount /dev/sda1 /media/pi/gunshots"
    echo "3. Or mount by UUID: sudo mount UUID=your-uuid /media/pi/gunshots"
fi
EOF

chmod +x mount_usb.sh

# Step 12: Final verification and start
print_step "Step 12: Final verification and service start..."

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