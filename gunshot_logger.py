#!/usr/bin/env python3
"""
Gunshot Logger - A program to detect and record gunshots using I2S microphones.
Designed to run on a Raspberry Pi 3 in a gun range environment.

Requirements:
    - ALSA tools: sudo apt-get install alsa-utils
    - Python packages: pip install numpy sounddevice scipy psutil
"""

import os
import sys
import time
import logging
import datetime
import subprocess
import threading
import queue
import json
from pathlib import Path
import numpy as np
import sounddevice as sd
from scipy.io import wavfile
import psutil

# Configuration
CONFIG = {
    'SAMPLE_RATE': 48000,
    'CHANNELS': 2,
    'BUFFER_DURATION': 2,  # seconds
    'DETECTION_THRESHOLD': -15,  # dBFS; adjust after field test
    'OPERATING_HOURS': {
        'start': '09:00',
        'end': '19:00'
    },
    'USB_MOUNT_PATH': '/media/pi',
    'GUNSHOT_DIR': 'gunshots',
    'STATE_FILE': 'gunshot_state.json',
    'LOG_FILE': 'gunshot_detection.log',
    'ALSA_DEVICE': 2,  # Google Voice Hat device number
    'BUFFER_SIZE': 16384,  # Doubled buffer size for better overflow handling
    'LATENCY': 'high',    # High latency for better stability
    'MAX_QUEUE_SIZE': 100,  # Maximum number of detections to queue
    'ERROR_COOLDOWN': 60,  # Seconds to wait between repeated error messages
    'BLOCKS_PER_BUFFER': 4,  # Number of blocks to buffer
}

class CircularBuffer:
    """Circular buffer to store audio data"""
    def __init__(self, duration, sample_rate, channels):
        self.size = int(duration * sample_rate * channels)
        self.data = np.zeros(self.size, dtype=np.float32)
        self.index = 0
        self.is_full = False

    def write(self, data):
        try:
            data_len = len(data)
            if self.index + data_len <= self.size:
                self.data[self.index:self.index + data_len] = data
            else:
                first_part = self.size - self.index
                second_part = data_len - first_part
                self.data[self.index:] = data[:first_part]
                self.data[:second_part] = data[first_part:]
            
            self.index = (self.index + data_len) % self.size
            if self.index == 0:
                self.is_full = True
        except Exception as e:
            logging.error(f"Error writing to circular buffer: {e}")

    def get_buffer(self):
        try:
            if not self.is_full:
                return self.data[:self.index]
            return np.roll(self.data, -self.index)
        except Exception as e:
            logging.error(f"Error getting buffer data: {e}")
            return np.zeros(1, dtype=np.float32)

class GunshotLogger:
    def __init__(self):
        self.setup_logging()
        self.buffer = CircularBuffer(
            CONFIG['BUFFER_DURATION'],
            CONFIG['SAMPLE_RATE'],
            CONFIG['CHANNELS']
        )
        self.file_counter = self.load_state()
        self.detection_queue = queue.Queue(maxsize=CONFIG['MAX_QUEUE_SIZE'])
        self.running = False
        self.usb_path = self.find_usb_drive()
        self.last_usb_log = 0
        self.detection_state = 'IDLE'
        self.trigger_time = None
        self.last_error_time = 0
        self.error_counts = {}
        
    def setup_logging(self):
        """Configure logging to both file and stdout"""
        formatter = logging.Formatter(
            '%(asctime)s - %(levelname)s - %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
        
        # File handler
        file_handler = logging.FileHandler(CONFIG['LOG_FILE'])
        file_handler.setFormatter(formatter)
        
        # Console handler
        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setFormatter(formatter)
        
        # Setup logger
        self.logger = logging.getLogger(__name__)
        self.logger.setLevel(logging.INFO)
        self.logger.addHandler(file_handler)
        self.logger.addHandler(console_handler)

    def rate_limited_log(self, level, message, error_key=None):
        """Rate-limited logging to prevent log spam"""
        current_time = time.time()
        if error_key not in self.error_counts:
            self.error_counts[error_key] = {'count': 0, 'last_time': 0}
        
        if current_time - self.error_counts[error_key]['last_time'] > CONFIG['ERROR_COOLDOWN']:
            count = self.error_counts[error_key]['count']
            if count > 1:
                message = f"{message} (occurred {count} times)"
            if level == 'error':
                self.logger.error(message)
            elif level == 'warning':
                self.logger.warning(message)
            else:
                self.logger.info(message)
            self.error_counts[error_key] = {'count': 0, 'last_time': current_time}
        else:
            self.error_counts[error_key]['count'] += 1

    def load_state(self):
        """Load the last used file counter"""
        try:
            with open(CONFIG['STATE_FILE'], 'r') as f:
                state = json.load(f)
                return state.get('file_counter', 1)
        except (FileNotFoundError, json.JSONDecodeError):
            return 1
        except Exception as e:
            self.rate_limited_log('error', f"Failed to load state: {e}", 'load_state')
            return 1

    def save_state(self):
        """Save current file counter"""
        try:
            with open(CONFIG['STATE_FILE'], 'w') as f:
                json.dump({'file_counter': self.file_counter}, f)
        except Exception as e:
            self.rate_limited_log('error', f"Failed to save state: {e}", 'save_state')

    def find_usb_drive(self):
        """Find the USB drive mount point"""
        try:
            for part in psutil.disk_partitions(all=False):
                if part.mountpoint.startswith('/media/pi'):
                    return Path(part.mountpoint)
            
            current_time = time.time()
            if current_time - self.last_usb_log >= 60:
                self.logger.warning("No USB drive found")
                self.last_usb_log = current_time
                
        except Exception as e:
            self.rate_limited_log('error', f"Failed to find USB drive: {e}", 'find_usb')
        return None

    def calculate_db(self, audio_chunk):
        """Calculate decibel level from audio chunk"""
        try:
            if len(audio_chunk) == 0:
                return -np.inf
            rms = np.sqrt(np.mean(np.square(audio_chunk)))
            db = 20 * np.log10(rms + 1e-10)  # Add small value to avoid log(0)
            return db
        except Exception as e:
            self.rate_limited_log('error', f"Error calculating dB: {e}", 'calc_db')
            return -np.inf

    def is_operating_hours(self):
        """Check if current time is within operating hours"""
        try:
            now = datetime.datetime.now().time()
            start = datetime.datetime.strptime(CONFIG['OPERATING_HOURS']['start'], '%H:%M').time()
            end = datetime.datetime.strptime(CONFIG['OPERATING_HOURS']['end'], '%H:%M').time()
            return start <= now <= end
        except Exception as e:
            self.rate_limited_log('error', f"Error checking operating hours: {e}", 'check_hours')
            return True  # Default to running if there's an error

    def audio_callback(self, indata, frames, time_info, status):
        """Callback for audio stream processing"""
        if status:
            # If we get an overflow, try to recover by processing what we have
            if status.input_overflow:
                self.rate_limited_log('warning', f"Audio callback status: {status}", 'audio_status')
                # Still process the data we have
                pass
            else:
                self.rate_limited_log('warning', f"Audio callback status: {status}", 'audio_status')
                return
        
        try:
            # Always write to circular buffer
            # Use a copy to prevent any potential buffer overruns
            self.buffer.write(indata.copy().flatten())

            # Only process detection during operating hours
            if not self.is_operating_hours():
                return

            # Calculate dB level
            db_level = self.calculate_db(indata)
            
            # State machine for detection
            if self.detection_state == 'IDLE':
                if db_level > CONFIG['DETECTION_THRESHOLD']:
                    self.detection_state = 'TRIGGERED'
                    self.trigger_time = time.time()
                    self.logger.info(f"Gunshot detected at {db_level:.1f} dB")
            
            elif self.detection_state == 'TRIGGERED':
                if time.time() - self.trigger_time >= 2.0:  # 2 seconds post-trigger
                    try:
                        # Use non-blocking put with timeout
                        self.detection_queue.put_nowait((db_level, self.buffer.get_buffer().copy()))
                    except queue.Full:
                        self.rate_limited_log('warning', "Detection queue full, skipping detection", 'queue_full')
                    self.detection_state = 'IDLE'
                    
        except Exception as e:
            self.rate_limited_log('error', f"Error in audio callback: {e}", 'audio_callback')

    def save_gunshot(self, audio_data, db_level):
        """Save detected gunshot to file"""
        if not self.usb_path:
            self.rate_limited_log('error', "No USB drive found", 'no_usb')
            return

        try:
            gunshot_dir = self.usb_path / CONFIG['GUNSHOT_DIR']
            gunshot_dir.mkdir(exist_ok=True)

            filename = f"gunshot_{self.file_counter:03d}.wav"
            filepath = gunshot_dir / filename

            # Reshape audio data for stereo and convert to int32
            audio_data = audio_data.reshape(-1, CONFIG['CHANNELS']).astype(np.int32)
            
            # Save as WAV file
            wavfile.write(str(filepath), CONFIG['SAMPLE_RATE'], audio_data)
            
            # Log detection
            self.logger.info(
                f"gunshot_{self.file_counter:03d} saved with decibel reading of {db_level:.1f} dB"
            )
            
            self.file_counter += 1
            self.save_state()
            
        except Exception as e:
            self.rate_limited_log('error', f"Failed to save gunshot: {e}", 'save_gunshot')

    def detection_worker(self):
        """Worker thread to handle gunshot detections"""
        while self.running:
            try:
                db_level, audio_data = self.detection_queue.get(timeout=1)
                self.save_gunshot(audio_data, db_level)
            except queue.Empty:
                continue
            except Exception as e:
                self.rate_limited_log('error', f"Detection worker error: {e}", 'worker_error')

    def start(self):
        """Start the gunshot logger"""
        try:
            self.running = True
            
            # Start detection worker thread
            self.worker_thread = threading.Thread(target=self.detection_worker)
            self.worker_thread.daemon = True  # Make thread daemon so it exits when main thread exits
            self.worker_thread.start()

            # Configure sounddevice settings
            sd.default.blocksize = CONFIG['BUFFER_SIZE']
            sd.default.latency = ('high', 'high')  # High latency for both input and output
            
            # Start audio stream with improved parameters
            with sd.InputStream(
                device=CONFIG['ALSA_DEVICE'],
                channels=CONFIG['CHANNELS'],
                samplerate=CONFIG['SAMPLE_RATE'],
                blocksize=CONFIG['BUFFER_SIZE'],
                latency=CONFIG['LATENCY'],
                callback=self.audio_callback,
                dtype=np.float32,
                extra_settings=[
                    ('hw:CARD=sndrpigooglevoi', 'periods', str(CONFIG['BLOCKS_PER_BUFFER'])),
                    ('hw:CARD=sndrpigooglevoi', 'buffer_size', str(CONFIG['BUFFER_SIZE'] * CONFIG['BLOCKS_PER_BUFFER']))
                ]
            ):
                self.logger.info(f"Gunshot logger started with buffer size: {CONFIG['BUFFER_SIZE']}")
                while self.running:
                    time.sleep(1)
                    # Periodically check USB drive
                    self.usb_path = self.find_usb_drive()

        except Exception as e:
            self.logger.error(f"Failed to start gunshot logger: {e}")
            self.running = False

    def stop(self):
        """Stop the gunshot logger"""
        self.running = False
        if hasattr(self, 'worker_thread'):
            self.worker_thread.join()
        self.save_state()
        self.logger.info("Gunshot logger stopped")

def main():
    logger = GunshotLogger()
    try:
        logger.start()
    except KeyboardInterrupt:
        logger.stop()

if __name__ == "__main__":
    main()

"""
To run this program on boot using systemd:

1. Create a systemd service file:
   sudo nano /etc/systemd/system/gunshot-logger.service

2. Add the following content:
   [Unit]
   Description=Gunshot Detection and Logging Service
   After=multi-user.target

   [Service]
   Type=simple
   User=pi
   WorkingDirectory=/home/pi
   Environment="PYTHONUNBUFFERED=1"
   ExecStart=/usr/bin/python3 /home/pi/gunshot_logger.py
   Restart=always
   RestartSec=5

   [Install]
   WantedBy=multi-user.target

3. Enable and start the service:
   sudo systemctl enable gunshot-logger.service
   sudo systemctl start gunshot-logger.service

4. Check status:
   sudo systemctl status gunshot-logger.service

5. View logs:
   sudo journalctl -u gunshot-logger.service
""" 