#!/bin/bash

# Gunshot Logger - Raspberry Pi Setup Script
# This script sets up the complete gunshot detection system on a fresh Raspberry Pi

set -e  # Exit on any error

echo "=========================================="
echo "Gunshot Logger - Raspberry Pi Setup"
echo "=========================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Step 1: Update system
print_status "Step 1: Updating system packages..."
sudo apt update && sudo apt upgrade -y

# Step 2: Install required packages
print_status "Step 2: Installing required packages..."
sudo apt install -y python3 python3-pip git alsa-utils

# Step 3: Clone repository
print_status "Step 3: Cloning repository..."
cd ~
if [ -d "gunshot-logger" ]; then
    print_warning "gunshot-logger directory already exists, removing..."
    rm -rf gunshot-logger
fi
git clone https://github.com/quickSecureLLC/gunshot-logger.git
cd gunshot-logger

# Step 4: Install Python dependencies
print_status "Step 4: Installing Python dependencies..."
pip3 install numpy sounddevice scipy psutil

# Step 5: Configure audio system
print_status "Step 5: Configuring audio system..."

# Check available audio devices
print_status "Available audio devices:"
aplay -l

print_status "ALSA cards:"
cat /proc/asound/cards

# Create ALSA configuration for Google Voice Hat
print_status "Creating ALSA configuration..."
sudo tee /etc/asound.conf > /dev/null <<EOF
pcm.!default {
    type hw
    card 2
    device 0
}

ctl.!default {
    type hw
    card 2
}
EOF

# Step 6: Test audio system
print_status "Step 6: Testing audio system..."
print_status "Running audio test script..."
python3 test_audio.py

# Step 7: Create USB mount directory
print_status "Step 7: Creating USB mount directory..."
sudo mkdir -p /media/pi
sudo chown pi:pi /media/pi

# Step 8: Create systemd service
print_status "Step 8: Creating systemd service..."
sudo tee /etc/systemd/system/gunshot-logger.service > /dev/null <<EOF
[Unit]
Description=Gunshot Detection and Logging Service
After=multi-user.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/gunshot-logger
Environment="PYTHONUNBUFFERED=1"
ExecStart=/usr/bin/python3 /home/pi/gunshot-logger/gunshot_logger.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Step 9: Enable and start service
print_status "Step 9: Enabling and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable gunshot-logger.service
sudo systemctl start gunshot-logger.service

# Step 10: Create setup verification script
print_status "Step 10: Creating verification script..."
tee verify_setup.sh > /dev/null <<EOF
#!/bin/bash

echo "=========================================="
echo "Gunshot Logger - Setup Verification"
echo "=========================================="

echo "1. Checking service status..."
sudo systemctl status gunshot-logger.service

echo ""
echo "2. Checking recent logs..."
sudo journalctl -u gunshot-logger.service --since "5 minutes ago" --no-pager

echo ""
echo "3. Checking audio devices..."
aplay -l

echo ""
echo "4. Checking USB drive mount..."
lsblk | grep -E "(sda|sdb|sdc)"

echo ""
echo "5. Checking gunshot directory..."
if [ -d "/media/pi/gunshots" ]; then
    echo "Gunshot directory exists"
    ls -la /media/pi/gunshots/
else
    echo "Gunshot directory not found - check USB drive mounting"
fi

echo ""
echo "6. Checking log file..."
if [ -f "gunshot_detection.log" ]; then
    echo "Log file exists"
    tail -10 gunshot_detection.log
else
    echo "Log file not found"
fi

echo ""
echo "Verification complete!"
EOF

chmod +x verify_setup.sh

# Step 11: Create troubleshooting script
print_status "Step 11: Creating troubleshooting script..."
tee troubleshoot.sh > /dev/null <<EOF
#!/bin/bash

echo "=========================================="
echo "Gunshot Logger - Troubleshooting"
echo "=========================================="

echo "1. Restarting service..."
sudo systemctl restart gunshot-logger.service

echo "2. Checking service status..."
sudo systemctl status gunshot-logger.service

echo "3. Viewing real-time logs (Ctrl+C to exit)..."
sudo journalctl -u gunshot-logger.service -f
EOF

chmod +x troubleshoot.sh

# Step 12: Final status check
print_status "Step 12: Final status check..."
sleep 5
sudo systemctl status gunshot-logger.service --no-pager

print_status "Setup complete!"
echo ""
echo "=========================================="
echo "NEXT STEPS:"
echo "=========================================="
echo "1. Insert USB drive and mount it:"
echo "   sudo mount /dev/sda1 /media/pi"
echo ""
echo "2. Verify setup:"
echo "   ./verify_setup.sh"
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
echo "Adjust DETECTION_THRESHOLD and OPERATING_HOURS as needed"
echo "==========================================" 