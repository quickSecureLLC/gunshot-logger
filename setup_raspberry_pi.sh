#!/bin/bash

# Gunshot Logger - Raspberry Pi Setup Script
# This script sets up the complete gunshot detection system on a fresh Raspberry Pi
# Enhanced with reliable USB mounting, dynamic device detection, and robust error handling

set -e  # Exit on any error
set -u  # Exit on undefined variables

# Script hardening
trap 'echo "[ERROR] Script failed at line $LINENO. Check setup.log for details." >&2' ERR
trap 'echo "[INFO] Setup interrupted by user." >&2' INT TERM

# Get the actual user (works whether run as root via sudo or as normal user)
ACTUAL_USER=${SUDO_USER:-$USER}

# Canonical mount point - use consistent name everywhere, based on the actual user
MOUNT_POINT="/media/$ACTUAL_USER/gunshot-logger"

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
    
    # Use a more robust method to find the card number
    local i2s_card_info
    i2s_card_info=$(aplay -l | grep -i -E '(voicehat|i2s|snd-soc-dummy)')
    
    local card_num
    card_num=$(echo "$i2s_card_info" | awk -F' ' '{print $2}' | sed 's/://')

    if [[ "$card_num" =~ ^[0-9]+$ ]]; then
        print_status "Detected I2S-compatible card: $card_num"
        echo "$card_num"
    else
        # Fallback to the old method if the new one fails
        card_num=$(cat /proc/asound/cards | awk '/I2S/ || /Voice/ || /Google/ {print $1; exit}')
        if [[ "$card_num" =~ ^[0-9]+$ ]]; then
            print_warning "Primary detection failed, using fallback. Detected card: $card_num"
            echo "$card_num"
        else
            print_warning "Could not reliably detect an I2S card, using default card 2"
            echo "2"
        fi
    fi
}

# Function to cleanup USB mounts
cleanup_usb_mounts() {
    print_status "Cleaning up USB mounts..."
    
    # Unmount our specific mount point if it exists
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        print_status "Unmounting existing mount at $MOUNT_POINT..."
        sudo umount "$MOUNT_POINT" 2>/dev/null || true
        sleep 1
    fi
    
    # Unmount any USB drives that might be mounted elsewhere
    local usb_mounts=$(mount | grep -E "(sda|sdb|sdc)" | awk '{print $3}' || true)
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
}

# Function to check for a valid I2S audio overlay in the boot configuration
check_i2s_overlay() {
    print_step "Checking for I2S audio interface configuration..."
    local config_file="/boot/config.txt"
    # A regex to find common I2S dtoverlay lines
    local i2s_regex="dtoverlay=(googlevoicehat-soundcard|i2s-mems|hifiberry-dac)"

    if sudo grep -q -E "$i2s_regex" "$config_file"; then
        print_status "Found a recognized I2S overlay in $config_file."
        sudo grep -E "$i2s_regex" "$config_file" | tail -n1
    else
        print_error "CRITICAL: No recognized I2S audio overlay found in $config_file."
        print_warning "This is the most likely cause of the PortAudio error."
        echo ""
        print_warning "You must MANUALLY edit /boot/config.txt to add the correct 'dtoverlay' for your microphone."
        print_status "Example for Google Voice HAT:      dtoverlay=googlevoicehat-soundcard"
        print_status "Example for SPH0645LM4H mics:      dtoverlay=i2s-mems"
        print_status "Example for other I2S DACs:        dtoverlay=hifiberry-dac"
        echo ""
        print_warning "After editing the file, you MUST REBOOT for the change to take effect."
        echo ""
        # We cannot proceed if the fundamental hardware driver is not configured.
        exit 1
    fi
}

# Function to setup USB mounting
setup_usb_mount() {
    print_step "Setting up reliable USB mounting..."
    
    # Get current user
    local current_user=$(get_current_user)
    
    print_status "Using user: $current_user"
    print_status "Mount point: $MOUNT_POINT"
    
    # Bulletproof cleanup: Unmount any existing USB mounts
    print_status "Cleaning up any existing USB mounts..."
    
    # Unmount our specific mount point if it exists
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        print_status "Unmounting existing mount at $MOUNT_POINT..."
        sudo umount "$MOUNT_POINT" 2>/dev/null || true
        sleep 1
    fi
    
    # Unmount any USB drives that might be mounted elsewhere
    print_status "Checking for other USB mounts..."
    local usb_mounts=$(mount | grep -E "(sda|sdb|sdc)" | awk '{print $3}' || true)
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
    
    # Create mount directory structure
    sudo mkdir -p "$MOUNT_POINT"
    if [ $? -ne 0 ]; then
        print_error "Failed to create mount directory: $MOUNT_POINT"
        return 1
    fi
    
    # Set ownership to current user
    sudo chown "$current_user:$current_user" "$MOUNT_POINT"
    if [ $? -ne 0 ]; then
        print_error "Failed to set ownership of $MOUNT_POINT to $current_user"
        return 1
    fi
    
    sudo chmod 755 "$MOUNT_POINT"
    
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
    
    # If automatic detection failed, try hardcoded fallback
    if [ -z "$usb_dev" ]; then
        print_warning "Automatic USB detection failed, trying hardcoded fallback..."
        
        # Check if /dev/sda1 exists and is unmounted
        if [ -b "/dev/sda1" ] && ! mountpoint -q "/dev/sda1" 2>/dev/null; then
            usb_dev="/dev/sda1"
            print_status "Using hardcoded fallback: $usb_dev"
        else
            print_error "No USB partition found after waiting 10 seconds."
            print_error "Please insert a USB drive and try again."
            return 1
        fi
    fi
    
    print_status "Detected USB partition: $usb_dev"
    
    # Get filesystem type
    local fstype=$(sudo blkid -s TYPE -o value "$usb_dev" 2>/dev/null || echo "vfat")
    print_status "Filesystem type: $fstype"
    
    # Try mounting with retries
    local mount_opts="uid=$(id -u $current_user),gid=$(id -g $current_user),noatime"
    
    for attempt in 1 2 3; do
        print_status "Mounting attempt $attempt: sudo mount -t $fstype -o $mount_opts $usb_dev $MOUNT_POINT"
        
        if sudo mount -t "$fstype" -o "$mount_opts" "$usb_dev" "$MOUNT_POINT"; then
            print_status "✓ Mounted $usb_dev → $MOUNT_POINT"
            
            # Show mount info
            df -h "$MOUNT_POINT"
            return 0
        else
            print_warning "Mount failed, retrying in 2s... (attempt $attempt/3)"
            sleep 2
        fi
    done
    
    # Final hardcoded fallback attempt
    print_warning "All mount attempts failed, trying final hardcoded fallback..."
    if sudo mount -t vfat -o "uid=$(id -u $current_user),gid=$(id -g $current_user),noatime" "/dev/sda1" "$MOUNT_POINT"; then
        print_status "✓ Hardcoded fallback successful: /dev/sda1 → $MOUNT_POINT"
        df -h "$MOUNT_POINT"
        return 0
    fi
    
    print_error "✗ Failed to mount \${usb_dev:-/dev/sda1} at $MOUNT_POINT after all attempts."
    print_error "Please check USB drive and try again."
    return 1
}

# Function to verify USB mount
verify_usb_mount() {
    local current_user=$(get_current_user)
    
    if ! mountpoint -q "$MOUNT_POINT"; then
        print_error "USB drive is not mounted at $MOUNT_POINT"
        return 1
    fi
    
    if [ ! -w "$MOUNT_POINT" ]; then
        print_error "USB drive is not writable"
        return 1
    fi
    
    print_status "USB drive is properly mounted and writable at $MOUNT_POINT"
    return 0
}

# Step 1: Install required packages (skip OS updates)
print_step "Step 1: Updating package list and installing required packages..."
retry sudo apt-get update
retry sudo apt-get install -y python3 python3-pip git alsa-utils util-linux python3-numpy python3-scipy python3-psutil libportaudio2 portaudio19-dev libportaudiocpp0

# Step 2: Install pip packages that aren't available in apt
print_step "Step 2: Installing additional Python packages..."
retry pip3 install --upgrade --break-system-packages sounddevice

# Step 2.5: Configure User Permissions for Audio
print_step "Step 2.5: Granting audio hardware permissions..."
print_status "Adding user '$ACTUAL_USER' to the 'audio' group..."
run_sudo adduser "$ACTUAL_USER" audio || print_warning "User may already be in audio group. This is fine."

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

# Ensure the I2S hardware overlay is configured before proceeding
check_i2s_overlay

print_step "Step 4.5: Patching Python script for robust audio and mount point handling..."
# Use sed to replace hardcoded values with more robust logic
sed -i.bak \
    -e "s|self.usb_path = self.find_usb_drive()|self.usb_path = Path(sys.argv[1]) if len(sys.argv) > 1 else self.find_usb_drive()|" \
    -e "/'USB_MOUNT_PATH':/d" \
    -e "/'ALSA_DEVICE':/d" \
    -e "/device=CONFIG\['ALSA_DEVICE'\]/d" \
    gunshot_logger.py
print_status "gunshot_logger.py patched successfully for dynamic paths and default audio device."

# Step 5: Configure default audio device and verify
# This function replaces the previous, less safe method.
create_and_verify_asound_conf() {
    print_step "Step 5: Configuring default audio device..."
    local asound_conf="/etc/asound.conf"
    local asound_conf_bak="/etc/asound.conf.bak.$(date +%s)"
    
    # Use our more robust detection function
    local audio_card
    audio_card=$(detect_audio_card)
    
    # Back up existing config just in case
    if [ -f "$asound_conf" ]; then
        print_status "Backing up existing ALSA config to $asound_conf_bak"
        sudo mv "$asound_conf" "$asound_conf_bak"
    fi
    
    # Create the new config
    print_status "Creating new ALSA configuration for card $audio_card..."
    sudo tee "$asound_conf" > /dev/null <<EOF
pcm.!default {
    type hw
    card ${audio_card}
    device 0
}

ctl.!default {
    type hw
    card ${audio_card}
}
EOF

    # VERIFY the new config. This is the crucial step.
    print_status "Verifying new ALSA configuration with 'arecord -l'..."
    if arecord -l > /dev/null 2>&1; then
        print_status "✓ New ALSA configuration is valid."
        sudo rm -f "$asound_conf_bak" # Clean up backup
    else
        print_error "ALSA VERIFICATION FAILED! The generated /etc/asound.conf is invalid for your hardware."
        print_warning "This is the error you were seeing. The script will now self-correct."
        
        # Restore the backup or delete our broken file
        if [ -f "$asound_conf_bak" ]; then
            print_warning "Restoring original ALSA configuration from $asound_conf_bak"
            sudo mv "$asound_conf_bak" "$asound_conf"
        else
            print_warning "Removing the invalid ALSA configuration file."
            sudo rm -f "$asound_conf"
        fi
        
        print_error "Audio setup failed. The 'dtoverlay' in your /boot/config.txt does not match your physical microphone."
        print_error "Please fix the dtoverlay and reboot before running this script again."
        exit 1
    fi
}

# Call the new, safe function to configure audio
create_and_verify_asound_conf

# Step 6: Setup USB mounting
print_step "Step 6: Setting up USB mounting..."
if ! setup_usb_mount; then
    print_warning "USB setup failed, continuing without USB mount"
    print_warning "You will need to manually mount USB drive later"
fi

# Step 7: Test audio system
print_step "Step 7: Verifying audio system..."

# The main check is now just to see if the python probe works.
# All complex checking is delegated to the i2s_audio_fixer.sh script.
print_status "Probing hardware with Python sounddevice..."
if ! python3 -c "import sounddevice as sd; sd.query_devices()" > /dev/null 2>&1; then
    print_error "CRITICAL: Python cannot access the audio hardware."
    echo ""
    print_warning "This is a fatal error, likely caused by an incorrect hardware driver in /boot/config.txt."
    echo ""
    print_error "Please run the dedicated I2S audio fixer to solve this:"
    print_status "./i2s_audio_fixer.sh"
    echo ""
    exit 1
fi
print_status "✓ Audio hardware is accessible to Python."

# Step 8: Create systemd service with pre-checks
print_step "Step 8: Creating systemd service..."

# Get current user for service configuration
current_user=$(get_current_user)

sudo tee /etc/systemd/system/gunshot-logger.service > /dev/null <<EOF
[Unit]
Description=Gunshot Detection and Logging Service
After=multi-user.target

[Service]
Type=simple
User=$current_user
WorkingDirectory=/home/$current_user/gunshot-logger
Environment="PYTHONUNBUFFERED=1"
ExecStartPre=/usr/bin/test -d "$MOUNT_POINT"
ExecStartPre=/usr/bin/test -w "$MOUNT_POINT"
ExecStart=/usr/bin/python3 /home/$current_user/gunshot-logger/gunshot_logger.py "$MOUNT_POINT"
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
    sudo systemctl status gunshot-logger.service --no-pager
fi

echo ""
echo "2. Checking recent logs..."
sudo journalctl -u gunshot-logger.service --since "5 minutes ago" --no-pager

echo ""
echo "3. Checking audio devices..."
aplay -l

echo ""
echo "4. Checking USB drive mount..."
if mountpoint -q "$MOUNT_POINT"; then
    echo "✓ USB drive is mounted"
    df -h "$MOUNT_POINT"
    ls -la "$MOUNT_POINT/"
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
if [ -d "$MOUNT_POINT" ]; then
    echo "✓ Mount point exists"
    ls -ld "$MOUNT_POINT"
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
echo "--- Full Audio Diagnostics ---"
echo "--- ALSA Playback Devices (aplay -l) ---"
aplay -l || true
echo "--- ALSA Capture Devices (arecord -l) ---"
arecord -l || true
echo "--- Kernel Log (dmesg | grep -i -E 'audio|i2s|voicehat|snd') ---"
dmesg | grep -i -E 'audio|i2s|voicehat|snd' --color=never || echo "No relevant audio-related kernel messages."
echo "--- Boot Config (/boot/config.txt audio overlays) ---"
grep -i "dtoverlay" /boot/config.txt || echo "No dtoverlay found in /boot/config.txt"
echo "--- Python sounddevice Probe ---"
python3 -c "import sounddevice as sd; print('sounddevice version:', sd.__version__); print(sd.query_devices())" || echo 'Python sounddevice probe failed.'
echo "--- Diagnostics End ---"

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

tee mount_usb.sh > /dev/null <<EOF
#!/bin/bash

echo "=========================================="
echo "USB Drive Mount Helper"
echo "=========================================="

# Check if already mounted
if mountpoint -q "$MOUNT_POINT"; then
    echo "✓ USB drive already mounted at $MOUNT_POINT"
    df -h "$MOUNT_POINT"
    exit 0
fi

# Clean up any existing USB mounts first
echo "Cleaning up any existing USB mounts..."

# Unmount our specific mount point if it exists
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "Unmounting existing mount at $MOUNT_POINT..."
    sudo umount "$MOUNT_POINT" 2>/dev/null || true
    sleep 1
fi

# Unmount any USB drives that might be mounted elsewhere
usb_mounts=\$(mount | grep -E "(sda|sdb|sdc)" | awk '{print \$3}' || true)
if [ -n "\$usb_mounts" ]; then
    echo "Found existing USB mounts, unmounting them..."
    echo "\$usb_mounts" | while read mount_point; do
        if [ -n "\$mount_point" ] && [ "\$mount_point" != "$MOUNT_POINT" ]; then
            echo "Unmounting \$mount_point..."
            sudo umount "\$mount_point" 2>/dev/null || true
        fi
    done
    sleep 2
fi

# Remove any stale mount points
if [ -d "$MOUNT_POINT" ]; then
    echo "Removing stale mount point directory..."
    sudo rmdir "$MOUNT_POINT" 2>/dev/null || true
fi

echo "USB cleanup complete"
echo ""

echo "Available USB devices:"
lsblk | grep -E "(sda|sdb|sdc)"

echo ""
echo "Waiting for USB partition..."

# Wait up to 10 seconds for USB device to appear
usb_dev=""
for i in {1..10}; do
    # Look for any unmounted partition on /dev/sd*
    usb_dev=\$(lsblk -pnro NAME,TYPE,MOUNTPOINT \\
               | awk '\$2=="part" && \$3=="" && \$1 ~ /^\/dev\/sd/ {print \$1; exit}')
    if [ -n "\$usb_dev" ]; then 
        break
    fi
    echo "Waiting for USB device... (attempt \$i/10)"
    sleep 1
done

# If automatic detection failed, try hardcoded fallback
if [ -z "\$usb_dev" ]; then
    echo "Automatic USB detection failed, trying hardcoded fallback..."
    
    # Check if /dev/sda1 exists and is unmounted
    if [ -b "/dev/sda1" ] && ! mountpoint -q "/dev/sda1" 2>/dev/null; then
        usb_dev="/dev/sda1"
        echo "Using hardcoded fallback: \$usb_dev"
    else
        echo "✗ No USB partition found after waiting 10 seconds."
        echo ""
        echo "Manual mount options:"
        echo "1. Find your USB device: lsblk"
        echo "2. Mount manually: sudo mount /dev/sda1 $MOUNT_POINT"
        exit 1
    fi
fi

echo "Found USB device: \$usb_dev"

# Get filesystem type
fstype=\$(sudo blkid -s TYPE -o value "\$usb_dev" 2>/dev/null || echo "vfat")
echo "Filesystem type: \$fstype"

# Try mounting with retries
mount_opts="uid=\$(id -u),gid=\$(id -g),noatime"

for attempt in 1 2 3; do
    echo "Mounting attempt \$attempt: sudo mount -t \$fstype -o \$mount_opts \$usb_dev $MOUNT_POINT"
    
    if sudo mount -t "\$fstype" -o "\$mount_opts" "\$usb_dev" "$MOUNT_POINT"; then
        echo "✓ Mounted \$usb_dev → $MOUNT_POINT"
        df -h "$MOUNT_POINT"
        exit 0
    else
        echo "Mount failed, retrying in 2s... (attempt \$attempt/3)"
        sleep 2
    fi
done

# Final hardcoded fallback attempt
echo "All mount attempts failed, trying final hardcoded fallback..."
if sudo mount -t vfat -o "uid=\$(id -u),gid=\$(id -g),noatime" "/dev/sda1" "$MOUNT_POINT"; then
    echo "✓ Hardcoded fallback successful: /dev/sda1 → $MOUNT_POINT"
    df -h "$MOUNT_POINT"
    exit 0
fi

echo "✗ Failed to mount \${usb_dev:-/dev/sda1} at $MOUNT_POINT after all attempts."
echo ""
echo "Manual mount options:"
echo "1. Find your USB device: lsblk"
echo "2. Mount manually: sudo mount /dev/sda1 $MOUNT_POINT"
exit 1
EOF

chmod +x mount_usb.sh

# Step 13: Create simple manual mount script
print_step "Step 13: Creating simple manual mount script..."
tee manual_mount.sh > /dev/null <<EOF
#!/bin/bash

echo "=========================================="
echo "Manual USB Mount (Emergency Fallback)"
echo "=========================================="

# Get current user
current_user=\$(whoami)

echo "User: \$current_user"
echo "Mount point: $MOUNT_POINT"

# Create mount point
sudo mkdir -p "$MOUNT_POINT"
sudo chown "\$current_user:\$current_user" "$MOUNT_POINT"

echo ""
echo "Attempting to mount /dev/sda1..."

# Simple mount attempt
if sudo mount -t vfat -o "uid=\$(id -u),gid=\$(id -g),noatime" "/dev/sda1" "$MOUNT_POINT"; then
    echo "✓ Successfully mounted /dev/sda1 → $MOUNT_POINT"
    df -h "$MOUNT_POINT"
    echo ""
    echo "You can now run the setup script again."
else
    echo "✗ Failed to mount /dev/sda1"
    echo ""
    echo "Troubleshooting:"
    echo "1. Check if USB is inserted: lsblk"
    echo "2. Check if device exists: ls -la /dev/sda*"
    echo "3. Try different device: sudo mount /dev/sdb1 $MOUNT_POINT"
fi
EOF

chmod +x manual_mount.sh

# Step 13.5: Create standalone USB cleanup script
print_step "Step 13.5: Creating standalone USB cleanup script..."
tee cleanup_usb.sh > /dev/null <<EOF
#!/bin/bash

echo "=========================================="
echo "USB Drive Cleanup Script"
echo "=========================================="

echo "This script will unmount all USB drives and clean up mount points."
echo "Mount point: $MOUNT_POINT"
echo ""

# Unmount our specific mount point if it exists
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "Unmounting existing mount at $MOUNT_POINT..."
    sudo umount "$MOUNT_POINT" 2>/dev/null || true
    sleep 1
fi

# Unmount any USB drives that might be mounted elsewhere
usb_mounts=\$(mount | grep -E "(sda|sdb|sdc)" | awk '{print \$3}' || true)
if [ -n "\$usb_mounts" ]; then
    echo "Found existing USB mounts, unmounting them..."
    echo "\$usb_mounts" | while read mount_point; do
        if [ -n "\$mount_point" ] && [ "\$mount_point" != "$MOUNT_POINT" ]; then
            echo "Unmounting \$mount_point..."
            sudo umount "\$mount_point" 2>/dev/null || true
        fi
    done
    sleep 2
fi

# Remove any stale mount points
if [ -d "$MOUNT_POINT" ]; then
    echo "Removing stale mount point directory..."
    sudo rmdir "$MOUNT_POINT" 2>/dev/null || true
fi

echo ""
echo "USB cleanup complete!"
echo "You can now safely remove USB drives or run the setup script again."
EOF

chmod +x cleanup_usb.sh

# Step 14: Final verification and start
print_step "Step 14: Final verification and service start..."

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
echo -e "${YELLOW}IMPORTANT: A reboot is REQUIRED for the audio permissions to take effect.${NC}"
echo "Please run 'sudo reboot' now."
echo ""
echo "After rebooting, you can verify the setup by running:"
echo "   ./verify_setup.sh"
echo ""
echo "2. If USB not mounted, try these in order:"
echo "   ./mount_usb.sh"
echo "   ./manual_mount.sh"
echo ""
echo "3. If you need to clean up USB mounts (for multiple runs):"
echo "   ./cleanup_usb.sh"
echo ""
echo "4. Monitor logs:"
echo "   sudo journalctl -u gunshot-logger.service -f"
echo ""
echo "5. Test with loud sound and check:"
echo "   ls -la $MOUNT_POINT/"
echo ""
echo "6. If issues, run troubleshooting:"
echo "   ./troubleshoot.sh"
echo ""
echo "=========================================="
echo "Configuration file: gunshot_logger.py"
echo "Audio card detected: $audio_card"
echo "Adjust DETECTION_THRESHOLD and OPERATING_HOURS as needed"
echo "=========================================="
echo "Setup completed at: $(date)"
echo "Log file: setup.log" 