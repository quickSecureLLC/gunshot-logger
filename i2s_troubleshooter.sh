#!/bin/bash
#
# I2S Audio Troubleshooter for Raspberry Pi
# This script helps diagnose and fix issues with I2S microphones.
#

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
    echo -e "\n${BLUE}========== $1 ==========${NC}"
}

# --- SCRIPT START ---
echo "=========================================="
echo "I2S Microphone Troubleshooter"
echo "=========================================="
echo "This script will help diagnose issues with your I2S microphone setup."
echo "It will inspect your system configuration but will ask for permission before making any changes."


# --- STEP 1: GATHER SYSTEM INFORMATION ---
print_step "STEP 1: Gathering System Information"
pi_model=$(cat /proc/device-tree/model)
kernel_version=$(uname -r)
print_status "Raspberry Pi Model: $pi_model"
print_status "Kernel Version:     $kernel_version"


# --- STEP 2: CHECK BOOT CONFIGURATION ---
print_step "STEP 2: Checking Boot Configuration (/boot/config.txt)"
config_file="/boot/config.txt"
i2s_overlays=$(grep -E "^dtoverlay=(i2s-mems|googlevoicehat-soundcard|hifiberry-dac|audioinjector-wm8731-als|iqaudio-dac)" "$config_file" || echo "No I2S overlays found")
print_status "Found I2S-related overlays:"
echo -e "${YELLOW}$i2s_overlays${NC}"


# --- STEP 3: CHECK ALSA CONFIGURATION ---
print_step "STEP 3: Checking ALSA Audio System"
print_status "Running 'arecord -l' to list capture devices..."
if ! arecord -l; then
    print_error "ALSA command 'arecord -l' failed. This is a strong indicator of a misconfiguration."
    print_warning "This is likely caused by an incorrect 'dtoverlay' in $config_file for your hardware."
else
    print_status "ALSA command 'arecord -l' succeeded. Your system can see the capture hardware."
fi

if [ -f "/etc/asound.conf" ]; then
    print_status "Contents of /etc/asound.conf:"
    cat /etc/asound.conf
fi


# --- STEP 4: INTERACTIVE DIAGNOSIS ---
print_step "STEP 4: Interactive Hardware Diagnosis"
echo "Please identify the I2S microphone hardware you are using."
options=(
    "Google Voice HAT / AIY Voice Kit v1"
    "Adafruit I2S MEMS Microphone (SPH0645)"
    "Adafruit I2S 3W Stereo Speaker Bonnet"
    "A different I2S board (e.g., HifiBerry, IQaudio, etc.)"
    "I'm not sure"
)
select opt in "${options[@]}"; do
    case $opt in
        "Google Voice HAT / AIY Voice Kit v1")
            suggestion="dtoverlay=googlevoicehat-soundcard"
            break
            ;;
        "Adafruit I2S MEMS Microphone (SPH0645)")
            suggestion="dtoverlay=i2s-mems"
            break
            ;;
        "Adafruit I2S 3W Stereo Speaker Bonnet")
            suggestion="dtoverlay=hifiberry-dac"
            break
            ;;
        "A different I2S board (e.g., HifiBerry, IQaudio, etc.)")
            print_warning "Please consult your hardware manufacturer's documentation for the correct 'dtoverlay' line."
            suggestion=""
            break
            ;;
        "I'm not sure")
            print_warning "Hardware identification is crucial. Please check your purchase history or look for markings on the board."
            suggestion=""
            break
            ;;
    esac
done


# --- STEP 5: APPLY FIX ---
print_step "STEP 5: Configuration Fix"
if [ -n "$suggestion" ]; then
    print_status "Based on your selection, the recommended overlay is:"
    echo -e "${GREEN}${suggestion}${NC}"
    
    read -p "Do you want this script to automatically comment out old audio overlays and add this new one to /boot/config.txt? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_status "Backing up $config_file to ${config_file}.bak"
        sudo cp "$config_file" "${config_file}.bak"
        
        print_status "Commenting out existing audio overlays..."
        sudo sed -i -E "s/^(dtoverlay=(i2s-mems|googlevoicehat-soundcard|hifiberry-dac|audioinjector-wm8731-als|iqaudio-dac|pcf8523-rtc|i2c-rtc,pcf8523))/#\1/" "$config_file"
        
        print_status "Adding new overlay..."
        echo -e "\n# Added by I2S Troubleshooter\n$suggestion\n" | sudo tee -a "$config_file" > /dev/null
        
        print_warning "Configuration has been changed!"
        print_error "A REBOOT IS REQUIRED for changes to take effect."
        read -p "Reboot now? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo reboot
        fi
    fi
else
    print_status "No changes have been made. Please manually edit your configuration."
fi

# --- STEP 6: WIRING ---
print_step "STEP 6: Final Checks"
print_warning "If problems persist after a reboot, please double-check your physical GPIO wiring."
print_status "Common I2S Wiring:"
print_status "  - BCLK (Pin 12)"
print_status "  - LRCL (Pin 35)"
print_status "  - DIN or DOUT (Pin 40 or Pin 38)"
print_status "  - VCC (to 3.3V) and GND (to Ground)"
echo ""
print_status "Troubleshooting complete." 