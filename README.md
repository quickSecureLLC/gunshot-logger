# Gunshot Logger

A Python application designed for Raspberry Pi to detect and record gunshots using I2S microphones in a gun range environment. The program maintains a rolling buffer of audio and saves clips when gunshots are detected, along with detailed logging.

## Features

- Real-time gunshot detection using dBFS threshold
- Stereo audio recording with I2S microphones
- 2-second pre-trigger and 2-second post-trigger audio capture
- Automatic USB drive detection and file storage
- Configurable operating hours
- Robust error handling and logging
- Systemd service integration

## Requirements

### Hardware
- Raspberry Pi 3 or newer
- I2S MEMS microphones
- USB drive for storage

### Software
```bash
# System packages
sudo apt-get update
sudo apt-get install -y alsa-utils python3-pip

# Python packages
pip3 install numpy sounddevice scipy psutil
```

## Installation

1. Clone the repository:
```bash
git clone https://github.com/yourusername/gunshot-logger.git
cd gunshot-logger
```

2. Make the script executable:
```bash
chmod +x gunshot_logger.py
```

3. Set up the systemd service:
```bash
sudo cp gunshot-logger.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable gunshot-logger
sudo systemctl start gunshot-logger
```

## Configuration

Edit the `CONFIG` dictionary in `gunshot_logger.py` to customize:
- Sample rate and channels
- Detection threshold
- Operating hours
- USB mount path
- File naming and locations

## Usage

### Running Manually
```bash
python3 gunshot_logger.py
```

### Service Management
```bash
# Start the service
sudo systemctl start gunshot-logger

# Check status
sudo systemctl status gunshot-logger

# View logs
sudo journalctl -u gunshot-logger -f
```

### File Structure
- Gunshot recordings: `/media/pi/USB_DRIVE/gunshots/gunshot_XXX.wav`
- Log file: `gunshot_detection.log`
- State file: `gunshot_state.json`

## Troubleshooting

1. No USB Drive Detected
   - Ensure USB drive is properly formatted and mounted
   - Check mount point matches CONFIG['USB_MOUNT_PATH']

2. Audio Issues
   - Verify I2S is enabled in raspi-config
   - Check ALSA device number in CONFIG['ALSA_DEVICE']
   - Test microphone connections

3. Service Not Starting
   - Check logs: `sudo journalctl -u gunshot-logger -n 50`
   - Verify Python dependencies are installed
   - Ensure correct file permissions

## License

MIT License - See LICENSE file for details 