#!/usr/bin/env bash
set -euo pipefail

# ============================================
# I2S Audio Fixer for Raspberry Pi
# This script performs a clean reset of your Pi's audio configuration
# to fix deep hardware and driver-level issues.
# ============================================

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Helper Functions ---
print_step() { echo -e "\n${BLUE}==> $1${NC}"; }
print_status() { echo -e "    ${GREEN}→${NC} $1"; }
print_warning() { echo -e "    ${YELLOW}‼${NC} $1"; }
print_error() { echo -e "    ${RED}✗${NC} $1"; }

# --- Introduction ---
clear
echo "=========================================="
echo "I2S Audio Fixer"
echo "=========================================="
print_warning "This script will perform a complete reset of your Raspberry Pi's audio configuration."
print_warning "It will back up, then modify system files like /boot/config.txt and /etc/asound.conf."
read -p "Do you wish to proceed? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# --- Step 1: Clean Slate ---
print_step "1) Creating a clean slate for audio configuration..."
# Remove the ALSA config file that is causing 'arecord -l' to fail.
if [ -f /etc/asound.conf ]; then
    print_status "Backing up and removing potentially corrupt /etc/asound.conf"
    sudo mv /etc/asound.conf /etc/asound.conf.bak-$(date +%s)
fi

# Determine the correct boot config file path
if [ -f /boot/firmware/config.txt ]; then
  cfile=/boot/firmware/config.txt
elif [ -f /boot/config.txt ]; then
  cfile=/boot/config.txt
else
  print_error "Could not find a valid /boot/config.txt path. Aborting."
  exit 1
fi
print_status "Found boot configuration at: $cfile"

# Back up the boot config
print_status "Backing up $cfile"
sudo cp "$cfile" "$cfile.bak-$(date +%s)"

# Comment out all potentially conflicting audio overlays
print_status "Commenting out all existing I2S/audio overlays in $cfile..."
sudo sed -i -E "s/^(dtoverlay=(i2s-mems|googlevoicehat-soundcard|hifiberry-dac|audioinjector-wm8731-als|iqaudio-dac|pcf8523-rtc|i2c-rtc,pcf8523))/#\1/" "$cfile"
print_status "Audio configuration has been reset."


# --- Step 2: Install System Libraries ---
print_step "2) Installing PortAudio and system dependencies..."
sudo apt-get update
sudo apt-get install -y libportaudio2 portaudio19-dev libportaudiocpp0
print_status "PortAudio libraries installed."


# --- Step 3: Identify Your Hardware ---
print_step "3) Please identify your I2S microphone hardware"
echo "This is the most critical step. Please choose the board you are using."
options=(
    "Google Voice HAT / AIY Voice Kit v1"
    "Adafruit I2S MEMS Microphone (SPH0645)"
    "Adafruit I2S 3W Stereo Speaker Bonnet"
    "Other/Unsure (I will edit the file manually)"
)
select opt in "${options[@]}"; do
    case $opt in
        "Google Voice HAT / AIY Voice Kit v1")
            suggestion="dtoverlay=googlevoicehat-soundcard"
            break;;
        "Adafruit I2S MEMS Microphone (SPH0645)")
            suggestion="dtoverlay=i2s-mems"
            break;;
        "Adafruit I2S 3W Stereo Speaker Bonnet")
            suggestion="dtoverlay=hifiberry-dac"
            break;;
        "Other/Unsure (I will edit the file manually)")
            suggestion=""
            break;;
    esac
done


# --- Step 4: Apply the Correct Driver ---
print_step "4) Applying the new hardware driver..."
if [ -n "$suggestion" ]; then
    print_status "Adding the following line to $cfile:"
    echo -e "    ${GREEN}$suggestion${NC}"
    echo -e "\n# Added by I2S Audio Fixer\n$suggestion\n" | sudo tee -a "$cfile" > /dev/null
    print_status "Boot configuration has been updated."
else
    print_warning "No driver was selected."
    print_status "Please manually edit $cfile and add the correct 'dtoverlay' for your hardware."
fi


# --- Step 5: Final Steps ---
print_step "5) Finalizing permissions and next steps..."
user_name=${SUDO_USER:-$(whoami)}
print_status "Adding user '$user_name' to the 'audio' group for hardware access..."
sudo usermod -aG audio "$user_name"

echo
print_error "A system reboot is REQUIRED for these changes to take effect."
echo
print_status "After rebooting, please run the main setup script again:"
print_status "  ./setup_raspberry_pi.sh"
echo
read -p "Reboot now? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_warning "Rebooting now..."
    sudo reboot
fi

echo "Done." 