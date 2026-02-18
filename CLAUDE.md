# AudioScribe

A macOS CLI tool for recording system audio and microphone to WAV files.

## Build

```bash
swift build -c release
cp .build/release/audioscribe AudioScribe.app/Contents/MacOS/
```

## Usage

Use the `ascribe` wrapper script for proper permission handling:

```bash
# System audio only
./ascribe --system-only --duration 30 --output meeting.wav

# Microphone only
./ascribe --mic-only --duration 30 --output voice.wav

# Both system + microphone
./ascribe --duration 30 --output both.wav
```

Press Ctrl+C to stop recording early.

## Architecture

- `AudioScribe.swift` - CLI entry point using ArgumentParser
- `SystemAudioCapture.swift` - ScreenCaptureKit-based system audio capture
- `MicrophoneCapture.swift` - AVAudioEngine-based microphone capture
- `AudioMixer.swift` - Combines audio streams and writes to WAV
- `WAVWriter.swift` - Low-level WAV file writer
- `ascribe` - Bash wrapper handling macOS permission quirks

## macOS Permission Issues

### Microphone Access

**Problem**: CLI binaries cannot trigger the microphone permission prompt on macOS. Running the binary directly results in "Microphone permission denied" without any prompt appearing.

**Solution**: Wrap the binary in an app bundle (`AudioScribe.app`) and launch via `open`:
```bash
open "$(pwd)/AudioScribe.app" --args --mic-only --duration 10 --output test.wav
```

The app bundle must contain:
- `Contents/MacOS/audioscribe` - the binary
- `Contents/Info.plist` - with `NSMicrophoneUsageDescription`

**Note**: When using `open`, stdout/stderr are not visible in the terminal.

### Screen Recording Access

**Problem**: ScreenCaptureKit requires the app to be listed in System Settings > Privacy & Security > Screen Recording.

**Solution**:
1. Add `AudioScribe.app` to Screen Recording permissions
2. The binary can then run directly (no need for `open`)

**Key Finding**: Unlike microphone, screen recording permission works when running the binary directly from the app bundle, without needing `open`.

### Combined Mode (Mic + System)

**Problem**: Combined mode needs both permissions, but:
- Direct run: screen recording ✓, mic ✗
- Via `open`: mic ✓, screen recording may prompt again

**Solution**: "Prime" the screen recording permission by running system-only once directly, then use `open` for combined mode:
```bash
# First run (primes screen recording permission for the app bundle)
./AudioScribe.app/Contents/MacOS/audioscribe --system-only --duration 1 --output /dev/null

# Then combined mode works via open
./ascribe --duration 30 --output both.wav
```

After the first successful system-only run, the app bundle's screen recording permission is cached and works via `open` too.

### ScreenCaptureKit Configuration

**Problem**: Setting `config.width = 1` and `config.height = 1` for "audio-only" capture causes `startCapture()` to fail with "The stream is nil" error.

**Solution**: Use minimum dimensions of 2x2:
```swift
config.width = 2
config.height = 2
config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
config.showsCursor = false
config.pixelFormat = kCVPixelFormatType_32BGRA
```

### AudioMixer Flush

**Problem**: In `--mic-only` and `--system-only` modes, recordings were empty (44 bytes = WAV header only).

**Solution**: Must call `mixer.flush()` before `writer.finalize()` in all recording modes to write buffered samples.

## The `ascribe` Wrapper

The wrapper script handles permission differences:
- `--system-only`: Runs binary directly (screen recording works without `open`)
- Modes with microphone: Uses `open` to launch app bundle (required for mic permission)

This gives proper terminal output for system-only mode while still supporting microphone recording.

## Dependencies

- ScreenCaptureKit (macOS 12.3+)
- AVFoundation
- ArgumentParser (Swift package)
