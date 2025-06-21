# Gunshot Logger - Raspberry Pi Setup

A complete gunshot detection and logging system for Raspberry Pi using I2S microphones.

## Quick Setup (Fresh Raspberry Pi)

### Prerequisites
- Raspberry Pi 3 or 4 with Raspberry Pi OS
- Google Voice Hat or compatible I2S microphone
- USB drive for storage
- Internet connection

### One-Command Installation

```bash
# Download and run the setup script
curl -sSL https://raw.githubusercontent.com/quickSecureLLC/gunshot-logger/main/setup_raspberry_pi.sh | bash
```

### Manual Setup Steps

If you prefer to run steps manually:

#### 1. Update System
```bash
sudo apt update && sudo apt upgrade -y
```

#### 2. Install Dependencies
```bash
sudo apt install -y python3 python3-pip git alsa-utils util-linux python3-numpy python3-scipy python3-psutil
pip3 install sounddevice --break-system-packages
```

#### 3. Clone Repository
```bash
cd ~
git clone https://github.com/quickSecureLLC/gunshot-logger.git
cd gunshot-logger
```

#### 4. Configure Audio
```bash
# Check audio devices
aplay -l

# Create ALSA config for Google Voice Hat
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
```

#### 5. Test Audio System
```bash
python3 test_audio.py
```

#### 6. Setup USB Storage
```bash
# Create mount directory
sudo mkdir -p /media/pi
sudo chown pi:pi /media/pi

# Insert USB drive and mount
sudo mount /dev/sda1 /media/pi
```

#### 7. Create System Service
```bash
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
```

#### 8. Start Service
```bash
sudo systemctl daemon-reload
sudo systemctl enable gunshot-logger.service
sudo systemctl start gunshot-logger.service
```

## Configuration

Edit `gunshot_logger.py` to adjust settings:

```python
CONFIG = {
    'SAMPLE_RATE': 48000,
    'CHANNELS': 2,
    'BUFFER_DURATION': 3,  # seconds
    'DETECTION_THRESHOLD': -15,  # dBFS - adjust for your environment
    'OPERATING_HOURS': {
        'start': '09:00',
        'end': '19:00'
    },
    'ALSA_DEVICE': 2,  # Audio device number
    # ... other settings
}
```

## Monitoring and Management

### Check Service Status
```bash
sudo systemctl status gunshot-logger.service
```

### View Logs
```bash
# Real-time logs
sudo journalctl -u gunshot-logger.service -f

# Recent logs
sudo journalctl -u gunshot-logger.service --since "1 hour ago"
```

### Check Recorded Files
```bash
ls -la /media/pi/gunshots/
```

### Restart Service
```bash
sudo systemctl restart gunshot-logger.service
```

## Troubleshooting

### Common Issues

1. **No Audio Detected**
   - Check audio device: `aplay -l`
   - Verify ALSA config: `cat /etc/asound.conf`
   - Test microphone: `arecord -D hw:2,0 -c 2 -r 48000 -f S16_LE -d 5 test.wav`

2. **Service Won't Start**
   - Check logs: `sudo journalctl -u gunshot-logger.service -n 50`
   - Verify Python packages: `pip3 list | grep -E "(numpy|sounddevice|scipy|psutil)"`

3. **No Files Saved**
   - Check USB drive: `lsblk`
   - Verify mount: `df -h | grep media`
   - Check permissions: `ls -la /media/pi/`

4. **Too Many False Positives**
   - Increase `DETECTION_THRESHOLD` (e.g., from -15 to -10)
   - Check environment noise levels

5. **Silent Audio Files**
   - Run test: `python3 test_audio.py`
   - Check audio device configuration
   - Verify microphone is working

### Debug Commands

```bash
# Test audio capture
python3 test_audio.py

# Check system resources
htop
df -h
free -h

# Check audio devices
aplay -l
arecord -l

# Monitor real-time system logs
sudo journalctl -f
```

## File Structure

```
gunshot-logger/
├── gunshot_logger.py      # Main application
├── test_audio.py          # Audio system test
├── setup_raspberry_pi.sh  # Setup script
├── verify_setup.sh        # Verification script
├── troubleshoot.sh        # Troubleshooting script
├── gunshot_detection.log  # Application logs
└── gunshot_state.json     # State file
```

## USB Drive Setup

The system saves gunshot recordings to `/media/pi/gunshots/`. To set up automatic mounting:

1. Insert USB drive
2. Find device: `lsblk`
3. Mount: `sudo mount /dev/sda1 /media/pi`
4. For auto-mount, add to `/etc/fstab`:
   ```
   /dev/sda1 /media/pi vfat defaults 0 0
   ```

## Performance Tuning

### For Better Detection
- Adjust `DETECTION_THRESHOLD` based on environment
- Modify `BUFFER_DURATION` for longer/shorter captures
- Change `CAPTURE_DELAY` for timing adjustments

### For System Stability
- Monitor CPU usage: `htop`
- Check memory: `free -h`
- Monitor disk space: `df -h`

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Run `./troubleshoot.sh`
3. Check logs: `sudo journalctl -u gunshot-logger.service -f`
4. Verify setup: `./verify_setup.sh`

## License

This project is proprietary software. All rights reserved. 