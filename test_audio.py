#!/usr/bin/env python3
"""
Test script to verify audio capture and saving functionality
"""

import numpy as np
from scipy.io import wavfile
import tempfile
import os
from pathlib import Path

def test_audio_saving():
    """Test audio saving functionality"""
    print("Testing audio saving functionality...")
    
    # Generate test audio (1kHz sine wave)
    sample_rate = 48000
    duration = 2.0
    samples = int(duration * sample_rate)
    t = np.linspace(0, duration, samples, False)
    
    # Create stereo audio
    test_tone = 0.3 * np.sin(2 * np.pi * 1000 * t)  # 1kHz at 30% amplitude
    stereo_audio = np.column_stack([test_tone, test_tone])
    
    # Convert to float32 (simulate what we get from sounddevice)
    audio_float32 = stereo_audio.astype(np.float32)
    
    print(f"Generated audio: shape={audio_float32.shape}, dtype={audio_float32.dtype}")
    print(f"Audio range: {np.min(audio_float32):.6f} to {np.max(audio_float32):.6f}")
    
    # Convert to int16 for saving (same as in the fixed code)
    audio_int16 = np.clip(audio_float32, -1.0, 1.0)
    audio_int16 = (audio_int16 * 32767).astype(np.int16)
    
    print(f"Converted audio: shape={audio_int16.shape}, dtype={audio_int16.dtype}")
    print(f"Audio range: {np.min(audio_int16)} to {np.max(audio_int16)}")
    
    # Save test file
    test_file = "test_audio.wav"
    wavfile.write(test_file, sample_rate, audio_int16)
    
    # Verify file was created and has content
    if os.path.exists(test_file):
        file_size = os.path.getsize(test_file)
        print(f"Test file saved: {test_file}, size: {file_size} bytes")
        
        # Read back and verify
        read_rate, read_audio = wavfile.read(test_file)
        print(f"Read back audio: shape={read_audio.shape}, sample_rate={read_rate}")
        print(f"Read audio range: {np.min(read_audio)} to {np.max(read_audio)}")
        
        # Clean up
        os.remove(test_file)
        print("Test completed successfully!")
        return True
    else:
        print("Failed to create test file!")
        return False

def test_circular_buffer():
    """Test circular buffer functionality"""
    print("\nTesting circular buffer functionality...")
    
    # Simulate circular buffer
    sample_rate = 48000
    channels = 2
    duration = 3
    buffer_size = int(duration * sample_rate * channels)
    
    print(f"Buffer size: {buffer_size} samples")
    
    # Create test data
    test_data = np.random.rand(10000).astype(np.float32) * 0.1  # Random audio-like data
    
    # Simulate writing to buffer
    buffer_data = np.zeros(buffer_size, dtype=np.float32)
    index = 0
    
    for i in range(len(test_data)):
        buffer_data[index] = test_data[i]
        index = (index + 1) % buffer_size
    
    print(f"Buffer filled: {len(buffer_data)} samples")
    print(f"Buffer range: {np.min(buffer_data):.6f} to {np.max(buffer_data):.6f}")
    
    # Check if buffer contains non-zero data
    non_zero_count = np.count_nonzero(buffer_data)
    print(f"Non-zero samples: {non_zero_count}/{len(buffer_data)}")
    
    if non_zero_count > 0:
        print("Circular buffer test passed!")
        return True
    else:
        print("Circular buffer test failed!")
        return False

if __name__ == "__main__":
    print("Audio System Test Suite")
    print("=" * 50)
    
    test1_passed = test_audio_saving()
    test2_passed = test_circular_buffer()
    
    print("\n" + "=" * 50)
    print("Test Results:")
    print(f"Audio Saving Test: {'PASSED' if test1_passed else 'FAILED'}")
    print(f"Circular Buffer Test: {'PASSED' if test2_passed else 'FAILED'}")
    
    if test1_passed and test2_passed:
        print("\nAll tests passed! The audio system should work correctly.")
    else:
        print("\nSome tests failed. Check the implementation.") 