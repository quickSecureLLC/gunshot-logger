# I2S MEMS Microphone Documentation

## Overview
This documentation covers the implementation and usage of I2S MEMS microphones in stereo mode configuration. The system uses Adafruit I2S MEMS microphone breakouts for high-quality audio capture.

## Hardware Specifications

### Microphone Details
- Type: MEMS (Micro-Electrical-Mechanical Systems) Microphone
- Interface: I2S (Inter-IC Sound)
- Manufacturer: Adafruit
- Model: SPH0645LM4H-B
- Sample Rate: Up to 48kHz
- Resolution: 24-bit

### Key Features
- Digital I2S output
- High SNR (Signal-to-Noise Ratio)
- Low power consumption
- Compact form factor
- Compatible with Raspberry Pi and similar single-board computers

## Stereo Mode Operation

### Configuration
In stereo mode, two I2S MEMS microphones are used together to create a stereo audio capture system. The setup requires:

1. Two SPH0645LM4H-B microphones
2. Proper I2S bus configuration
3. Correct left/right channel assignment

### Pin Configuration
For stereo operation, the microphones are connected as follows:

#### Left Channel Microphone
- BCLK (Bit Clock) → I2S BCLK
- DOUT (Data Out) → I2S DOUT
- LRCLK (Left/Right Clock) → I2S LRCLK
- GND → Ground
- 3V → 3.3V Power Supply
- SEL → GND (for Left Channel)

#### Right Channel Microphone
- BCLK (Bit Clock) → I2S BCLK
- DOUT (Data Out) → I2S DOUT
- LRCLK (Left/Right Clock) → I2S LRCLK
- GND → Ground
- 3V → 3.3V Power Supply
- SEL → 3.3V (for Right Channel)

### Signal Processing
The I2S protocol handles the synchronization and data transfer for both channels:
- BCLK: Provides the bit-level timing
- LRCLK: Indicates left/right channel selection
- DOUT: Carries the audio data

## Software Implementation

### I2S Configuration
The I2S interface must be properly configured with:
- Sample rate (typically 48kHz)
- Bit depth (24-bit)
- Channel mode (Stereo)
- Master/Slave configuration

### Data Format
- Audio data is received in 24-bit format
- Left and right channels are interleaved
- Data is signed and in two's complement format

## Best Practices

### Installation
1. Mount microphones securely to minimize vibration
2. Keep signal lines short to reduce interference
3. Use proper shielding for cables
4. Maintain adequate separation between microphones for proper stereo imaging

### Troubleshooting
Common issues and solutions:
1. No audio output
   - Check power connections
   - Verify I2S configuration
   - Ensure proper channel selection

2. Channel imbalance
   - Verify SEL pin configuration
   - Check software channel mapping
   - Confirm equal gain settings

3. Noise issues
   - Check ground connections
   - Verify power supply quality
   - Ensure proper shielding

## Performance Considerations

### Audio Quality
- SNR: 65dBA typical
- Frequency Response: 50Hz - 15kHz
- THD: 1% maximum

### Power Consumption
- Active Mode: ~1mA typical
- Sleep Mode: <10µA

## Application Examples

### Common Use Cases
1. Stereo audio recording
2. Sound direction detection
3. Acoustic measurement
4. Voice recognition systems

### Integration Tips
1. Use appropriate sampling rates for your application
2. Implement proper buffering for continuous recording
3. Consider implementing gain control if needed
4. Monitor CPU usage when processing stereo data

## Code Implementation and Usage

### Required Dependencies
```python
# Install required packages
pip install adafruit-circuitpython-i2s
pip install sounddevice
pip install numpy
```

### Basic Setup Code
```python
import board
import audiobusio
import array
import time
import numpy as np

# Configure I2S pins for Raspberry Pi
# Modify these according to your specific pin connections
I2S_BCLK = board.D18    # Bit Clock
I2S_LRC = board.D19     # Left/Right Clock
I2S_DIN = board.D20     # Data In

# Initialize I2S device
i2s = audiobusio.I2SIn(
    bit_clock=I2S_BCLK,
    word_select=I2S_LRC,
    data=I2S_DIN,
    sample_rate=48000,
    bit_depth=24
)
```

### Recording Function
```python
def record_audio(duration_seconds=5, sample_rate=48000):
    """
    Record audio from the I2S microphones
    
    Args:
        duration_seconds (float): Recording duration in seconds
        sample_rate (int): Sample rate in Hz
    
    Returns:
        numpy.ndarray: Recorded audio data
    """
    samples = array.array('h', [0] * (sample_rate * duration_seconds * 2))  # *2 for stereo
    
    # Start recording
    i2s.record(samples, len(samples))
    
    # Convert to numpy array and reshape for stereo
    audio_data = np.array(samples).reshape(-1, 2)
    return audio_data

```

### Real-time Audio Processing
```python
def process_audio_stream(callback, buffer_size=4096):
    """
    Process audio in real-time with a callback function
    
    Args:
        callback (function): Function to process audio chunks
        buffer_size (int): Size of audio buffer
    """
    buffer = array.array('h', [0] * buffer_size)
    
    while True:
        i2s.record(buffer, len(buffer))
        audio_chunk = np.array(buffer).reshape(-1, 2)
        callback(audio_chunk)
```

### Example Usage
```python
# Basic recording example
def main():
    try:
        print("Starting audio recording...")
        audio_data = record_audio(duration_seconds=5)
        print(f"Recorded {len(audio_data)} stereo samples")
        
        # Save to WAV file
        import scipy.io.wavfile as wav
        wav.write("stereo_recording.wav", 48000, audio_data)
        
    except KeyboardInterrupt:
        print("\nRecording stopped by user")
    finally:
        i2s.deinit()

# Real-time processing example
def audio_callback(audio_chunk):
    # Example: Calculate audio levels for left and right channels
    left_level = np.abs(audio_chunk[:, 0]).mean()
    right_level = np.abs(audio_chunk[:, 1]).mean()
    print(f"Left: {left_level:.2f} | Right: {right_level:.2f}")

# Start real-time processing
process_audio_stream(audio_callback)
```

### Command Line Usage
```bash
# Install required system packages (Raspberry Pi)
sudo apt-get update
sudo apt-get install -y python3-pip python3-numpy
sudo apt-get install -y libportaudio2

# Enable I2S in Raspberry Pi config
sudo raspi-config
# Navigate to: Interface Options -> I2S -> Enable

# Run the recording script
python3 microphone_recording.py
```

### Error Handling and Debugging
```python
def initialize_microphones():
    """
    Safe initialization of I2S microphones with error handling
    """
    try:
        i2s = audiobusio.I2SIn(
            bit_clock=I2S_BCLK,
            word_select=I2S_LRC,
            data=I2S_DIN,
            sample_rate=48000,
            bit_depth=24
        )
        return i2s
    except ValueError as e:
        print(f"Error initializing I2S: {e}")
        print("Check pin configurations and connections")
        return None
    except RuntimeError as e:
        print(f"Runtime error: {e}")
        print("Make sure I2S is enabled in raspi-config")
        return None
```

### Advanced Configuration
```python
# Advanced I2S configuration options
I2S_CONFIG = {
    'sample_rate': 48000,
    'bit_depth': 24,
    'channel_count': 2,
    'buffer_size': 4096,
    'dma_buffer_size': 65536,  # For Raspberry Pi DMA transfers
}

# Apply advanced configuration
def configure_i2s_advanced(config):
    """
    Configure I2S with advanced options
    """
    i2s = audiobusio.I2SIn(
        bit_clock=board.D18,
        word_select=board.D19,
        data=board.D20,
        sample_rate=config['sample_rate'],
        bit_depth=config['bit_depth'],
        channel_count=config['channel_count'],
        buffer_size=config['buffer_size']
    )
    return i2s
```

## References
- Adafruit I2S MEMS Microphone Breakout Documentation
- I2S Protocol Specification
- SPH0645LM4H-B Datasheet

## Maintenance and Updates
- Regularly check for firmware updates
- Clean microphones periodically
- Verify calibration if used for measurement
- Monitor system performance

This documentation serves as a comprehensive guide for implementing and using I2S MEMS microphones in stereo mode. For specific implementation details, refer to the accompanying code examples and hardware documentation. 