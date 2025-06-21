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
    'BUFFER_DURATION': 3,  # Increased to 3 seconds to capture more audio
    'DETECTION_THRESHOLD': -20,  # Raised threshold to avoid false positives (was -50)
    'GUNSHOT_DIR': 'gunshots',
    'STATE_FILE': 'gunshot_state.json',
    'LOG_FILE': 'gunshot_detection.log',
    'BUFFER_SIZE': 1024,  # Smaller buffer for faster, more responsive detection
    'LATENCY': 'low',    # Low latency for faster response
    'MAX_QUEUE_SIZE': 100,  # Maximum number of detections to queue
    'ERROR_COOLDOWN': 60,  # Seconds to wait between repeated error messages
    'BLOCKS_PER_BUFFER': 4,  # Number of blocks to buffer
    'CAPTURE_DELAY': 0.5,  # Delay after trigger to capture gunshot (seconds)
    'DEBUG_INTERVAL': 5,  # How often to log audio levels (seconds)
}

class CircularBuffer:
    """Circular buffer to store audio data"""
    def __init__(self, duration, sample_rate, channels):
        self.size = int(duration * sample_rate * channels)
        self.data = np.zeros(self.size, dtype=np.float32)
        self.index = 0
        self.is_full = False
        self.total_samples_written = 0

    def write(self, data):
        try:
            data_len = len(data)
            if data_len == 0:
                return
                
            # Write data to circular buffer
            for i in range(data_len):
                self.data[self.index] = data[i]
                self.index = (self.index + 1) % self.size
                if self.index == 0:
                    self.is_full = True
            
            self.total_samples_written += data_len
            
        except Exception as e:
            logging.error(f"Error writing to circular buffer: {e}")

    def get_buffer(self):
        try:
            if not self.is_full:
                # Buffer not full yet, return what we have
                return self.data[:self.index].copy()
            else:
                # Buffer is full, return the most recent data
                # Roll the data so the most recent samples are at the end
                return np.roll(self.data, -self.index).copy()
        except Exception as e:
            logging.error(f"Error getting buffer data: {e}")
            return np.zeros(1, dtype=np.float32)

class GunshotLogger:
    def __init__(self, usb_mount_path=None):
        self.setup_logging()
        
        # Set USB mount path - use command line argument, then default
        if usb_mount_path:
            self.usb_mount_path = Path(usb_mount_path)
        else:
            # Get current user and use the correct mount point
            current_user = os.getenv('USER') or subprocess.check_output(['whoami'], text=True).strip()
            self.usb_mount_path = Path(f"/media/{current_user}/gunshot-logger")
        
        # Verify USB mount before starting
        if not self.verify_usb_mount():
            self.logger.error(f"USB drive not properly mounted at {self.usb_mount_path}. Please run ./mount_usb_only.sh or mount manually.")
            raise RuntimeError("USB drive not mounted")
        
        self.buffer = CircularBuffer(
            CONFIG['BUFFER_DURATION'],
            CONFIG['SAMPLE_RATE'],
            CONFIG['CHANNELS']
        )
        
        # Log buffer configuration
        self.logger.info(
            f"Circular buffer initialized: duration={CONFIG['BUFFER_DURATION']}s, "
            f"sample_rate={CONFIG['SAMPLE_RATE']}, channels={CONFIG['CHANNELS']}, "
            f"buffer_size={self.buffer.size} samples"
        )
        
        self.file_counter = self.load_state()
        self.detection_queue = queue.Queue(maxsize=CONFIG['MAX_QUEUE_SIZE'])
        self.running = False
        self.usb_path = self.usb_mount_path  # Use the verified mount path
        self.last_usb_log = 0
        self.detection_state = 'IDLE'
        self.trigger_time = None
        self.last_error_time = 0
        self.error_counts = {}
        self.last_debug_time = 0
        self.audio_levels = []  # Store recent audio levels for debugging
        
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

    def verify_usb_mount(self):
        """Verify that USB drive is properly mounted and writable"""
        try:
            import subprocess
            import os
            
            # Use the mount path that was set in __init__
            mount_point = str(self.usb_mount_path)
            
            # Check if mount point exists and is mounted
            result = subprocess.run(['mountpoint', '-q', mount_point], 
                                  capture_output=True, text=True)
            if result.returncode != 0:
                self.logger.error(f"USB drive is not mounted at {mount_point}")
                return False
            
            # Check if directory is writable
            test_file = Path(mount_point) / '.test_write'
            try:
                test_file.touch()
                test_file.unlink()
            except Exception as e:
                self.logger.error(f"USB drive is not writable: {e}")
                return False
            
            self.logger.info(f"USB drive is properly mounted and writable at {mount_point}")
            return True
            
        except Exception as e:
            self.logger.error(f"Error verifying USB mount: {e}")
            return False

    def find_usb_drive(self):
        """Find the USB drive mount point"""
        try:
            # Use the mount path that was set in __init__
            mount_point = str(self.usb_mount_path)
            
            # Check if mount point exists and is mounted
            result = subprocess.run(['mountpoint', '-q', mount_point], 
                                  capture_output=True, text=True)
            if result.returncode == 0:
                return Path(mount_point)
            
            # Fallback to checking all mounted media
            for part in psutil.disk_partitions(all=False):
                if part.mountpoint.startswith('/media/'):
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

            # Calculate dB level for this chunk
            db_level = self.calculate_db(indata)
            
            # Store audio level for debugging
            self.audio_levels.append(db_level)
            if len(self.audio_levels) > 100:  # Keep last 100 readings
                self.audio_levels.pop(0)
            
            # Debug logging every few seconds
            current_time = time.time()
            if current_time - self.last_debug_time >= CONFIG['DEBUG_INTERVAL']:
                if self.audio_levels:
                    avg_level = sum(self.audio_levels) / len(self.audio_levels)
                    max_level = max(self.audio_levels)
                    min_level = min(self.audio_levels)
                    self.logger.info(f"Audio levels - Current: {db_level:.1f}dB, Avg: {avg_level:.1f}dB, Max: {max_level:.1f}dB, Min: {min_level:.1f}dB, Threshold: {CONFIG['DETECTION_THRESHOLD']}dB")
                self.last_debug_time = current_time

            # State machine for detection
            if self.detection_state == 'IDLE':
                if db_level > CONFIG['DETECTION_THRESHOLD']:
                    self.detection_state = 'TRIGGERED'
                    self.trigger_time = time.time()
                    self.logger.info(f"🎯 GUNSHOT DETECTED at {db_level:.1f} dB (threshold: {CONFIG['DETECTION_THRESHOLD']}dB)")
            
            elif self.detection_state == 'TRIGGERED':
                # Wait for the configured delay after trigger to capture the full gunshot sound
                # This ensures we get the initial impact and the reverberation
                if time.time() - self.trigger_time >= CONFIG['CAPTURE_DELAY']:
                    try:
                        # Get the buffer data which should contain the gunshot
                        buffer_data = self.buffer.get_buffer().copy()
                        buffer_rms = np.sqrt(np.mean(np.square(buffer_data)))
                        buffer_db = 20 * np.log10(buffer_rms + 1e-10)
                        
                        self.logger.info(
                            f"💾 Capturing gunshot audio, buffer size: {len(buffer_data)}, "
                            f"buffer RMS: {buffer_rms:.6f}, buffer dB: {buffer_db:.1f}"
                        )
                        
                        # Use non-blocking put with timeout
                        self.detection_queue.put_nowait((db_level, buffer_data))
                    except queue.Full:
                        self.rate_limited_log('warning', "Detection queue full, skipping detection", 'queue_full')
                    self.detection_state = 'IDLE'
                    
        except Exception as e:
            self.rate_limited_log('error', f"Error in audio callback: {e}", 'audio_callback')

    def validate_audio_data(self, audio_data):
        """Validate that audio data contains actual sound"""
        try:
            if len(audio_data) == 0:
                return False, "Empty audio data"
            
            # Check if audio is all zeros (silent)
            if np.all(audio_data == 0):
                return False, "Audio data is all zeros (silent)"
            
            # Check RMS level
            rms = np.sqrt(np.mean(np.square(audio_data)))
            if rms < 1e-6:  # Very low RMS indicates essentially silent audio
                return False, f"Audio RMS too low: {rms:.8f}"
            
            # Check dynamic range
            max_amp = np.max(np.abs(audio_data))
            if max_amp < 1e-4:  # Very low amplitude
                return False, f"Audio amplitude too low: {max_amp:.8f}"
            
            return True, f"Valid audio - RMS: {rms:.6f}, Max: {max_amp:.6f}"
            
        except Exception as e:
            return False, f"Error validating audio: {e}"

    def save_gunshot(self, audio_data, db_level):
        """Save detected gunshot to file"""
        if not self.usb_path:
            self.rate_limited_log('error', "No USB drive found", 'no_usb')
            return

        try:
            # Validate audio data first
            is_valid, validation_msg = self.validate_audio_data(audio_data)
            if not is_valid:
                self.rate_limited_log('error', f"Invalid audio data: {validation_msg}", 'invalid_audio')
                return

            gunshot_dir = self.usb_path / CONFIG['GUNSHOT_DIR']
            gunshot_dir.mkdir(exist_ok=True)

            filename = f"gunshot_{self.file_counter:03d}.wav"
            filepath = gunshot_dir / filename

            # Reshape audio data for stereo
            if CONFIG['CHANNELS'] == 2:
                # Ensure we have an even number of samples for stereo
                if len(audio_data) % 2 != 0:
                    audio_data = audio_data[:-1]  # Remove last sample if odd
                audio_data = audio_data.reshape(-1, 2)
            else:
                audio_data = audio_data.reshape(-1, 1)

            # Convert from float32 (-1.0 to 1.0) to int16 (-32768 to 32767)
            # Apply proper scaling and clipping
            audio_data = np.clip(audio_data, -1.0, 1.0)
            audio_data = (audio_data * 32767).astype(np.int16)
            
            # Save as WAV file
            wavfile.write(str(filepath), CONFIG['SAMPLE_RATE'], audio_data)
            
            # Log detection with additional info
            self.logger.info(
                f"gunshot_{self.file_counter:03d} saved with decibel reading of {db_level:.1f} dB, "
                f"audio shape: {audio_data.shape}, max amplitude: {np.max(np.abs(audio_data))}, "
                f"validation: {validation_msg}"
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

    def test_audio_capture(self):
        """Test method to verify audio capture is working with REAL microphone input"""
        try:
            self.logger.info("🔍 Testing REAL microphone input (not generating test tone)...")
            
            # Test with actual microphone input for 3 seconds
            test_duration = 3.0
            test_samples = int(test_duration * CONFIG['SAMPLE_RATE'])
            
            # Record actual audio from microphone
            self.logger.info(f"Recording {test_duration} seconds of real audio...")
            audio_data = sd.rec(test_samples, 
                               samplerate=CONFIG['SAMPLE_RATE'], 
                               channels=CONFIG['CHANNELS'], 
                               dtype=np.float32)
            sd.wait()  # Wait for recording to complete
            
            # Flatten the audio data
            audio_data = audio_data.flatten()
            
            # Write to buffer
            self.buffer.write(audio_data)
            
            # Get buffer data
            buffer_data = self.buffer.get_buffer()
            
            # Calculate levels
            rms = np.sqrt(np.mean(np.square(audio_data)))
            db_level = 20 * np.log10(rms + 1e-10)
            max_amp = np.max(np.abs(audio_data))
            
            # Validate
            is_valid, validation_msg = self.validate_audio_data(buffer_data)
            
            self.logger.info(f"🎤 REAL Audio Test Results:")
            self.logger.info(f"   - Audio RMS: {rms:.6f}")
            self.logger.info(f"   - Audio dB: {db_level:.1f}dB")
            self.logger.info(f"   - Max Amplitude: {max_amp:.6f}")
            self.logger.info(f"   - Buffer Size: {len(buffer_data)}")
            self.logger.info(f"   - Validation: {validation_msg}")
            
            # Save the test file to the USB drive
            try:
                test_filename = "preliminary_test.wav"
                test_filepath = self.usb_path / test_filename

                # Reshape and convert to int16
                audio_to_save = buffer_data.copy()
                if CONFIG['CHANNELS'] == 2:
                    if len(audio_to_save) % 2 != 0:
                        audio_to_save = audio_to_save[:-1]
                    audio_to_save = audio_to_save.reshape(-1, 2)
                
                audio_data_int16 = np.clip(audio_to_save, -1.0, 1.0)
                audio_data_int16 = (audio_data_int16 * 32767).astype(np.int16)
                
                wavfile.write(str(test_filepath), CONFIG['SAMPLE_RATE'], audio_data_int16)
                self.logger.info(f"✅ Preliminary audio test saved to: {test_filepath}")
            except Exception as e:
                self.logger.error(f"❌ Failed to save preliminary test file: {e}")

            if db_level > -60:  # If we're getting any reasonable audio level
                self.logger.info("✅ Microphone is working and picking up sound!")
            else:
                self.logger.warning("⚠️  Microphone levels are very low - check microphone connection")
            
            return is_valid
            
        except Exception as e:
            self.logger.error(f"❌ Audio capture test failed: {e}")
            return False

    def start(self):
        """Start the gunshot logger"""
        try:
            self.running = True
            
            # Show current audio devices more robustly
            self.logger.info("🔊 Available audio devices:")
            try:
                devices = sd.query_devices()
                if not isinstance(devices, list): # Handles case where only one device is returned as a dict
                    devices = [devices]
                for i, device in enumerate(devices):
                    try:
                        # Log details for devices that have inputs
                        if device.get('max_input_channels', 0) > 0:
                             self.logger.info(f"   - Device {i}: {device['name']} (inputs: {device['max_input_channels']})")
                    except Exception:
                        self.logger.warning(f"   - Could not fully query Device {i}: {device.get('name', 'Unknown')}")
            except Exception as e:
                self.logger.warning(f"Could not query any audio devices: {e}")

            # Show default device
            try:
                default_device = sd.query_devices(kind='input')
                self.logger.info(f"🎤 Using default input device: {default_device['name']}")
            except Exception as e:
                self.logger.warning(f"Could not get default device: {e}")
            
            # Run audio capture test
            self.logger.info("Running REAL audio capture test...")
            if self.test_audio_capture():
                self.logger.info("✅ Audio capture test passed")
            else:
                self.logger.warning("⚠️  Audio capture test failed - check audio configuration")
            
            # Start detection worker thread
            self.worker_thread = threading.Thread(target=self.detection_worker)
            self.worker_thread.daemon = True  # Make thread daemon so it exits when main thread exits
            self.worker_thread.start()

            # Configure sounddevice settings
            sd.default.blocksize = CONFIG['BUFFER_SIZE']
            sd.default.latency = CONFIG['LATENCY']
            
            # Start audio stream with improved parameters - use default device
            with sd.InputStream(
                channels=CONFIG['CHANNELS'],
                samplerate=CONFIG['SAMPLE_RATE'],
                blocksize=CONFIG['BUFFER_SIZE'],
                latency=CONFIG['LATENCY'],
                callback=self.audio_callback,
                dtype=np.float32
            ) as stream:
                # Configure device-specific settings if needed
                if hasattr(stream, '_streaminfo'):
                    stream._streaminfo.suggestedLatency = 0.2
                
                self.logger.info(f"🎯 Gunshot logger started! Monitoring for sounds above {CONFIG['DETECTION_THRESHOLD']}dB")
                self.logger.info(f"   Buffer size: {CONFIG['BUFFER_SIZE']}")
                self.logger.info(f"   Sample rate: {CONFIG['SAMPLE_RATE']}Hz")
                self.logger.info(f"   Channels: {CONFIG['CHANNELS']}")
                self.logger.info("   Make some noise to test detection!")
                
                while self.running:
                    time.sleep(1)
                    # Periodically check USB drive
                    self.usb_path = self.find_usb_drive()

        except Exception as e:
            self.logger.error(f"❌ Failed to start gunshot logger: {e}")
            self.running = False

    def stop(self):
        """Stop the gunshot logger"""
        self.running = False
        if hasattr(self, 'worker_thread'):
            self.worker_thread.join()
        self.save_state()
        self.logger.info("Gunshot logger stopped")

def main():
    """Main function"""
    try:
        # Check if USB mount path was provided as command line argument
        usb_mount_path = sys.argv[1] if len(sys.argv) > 1 else None
        
        logger = GunshotLogger(usb_mount_path)
        logger.start()
        
        try:
            # Keep the main thread alive
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            print("\nShutting down...")
            logger.stop()
            
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

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