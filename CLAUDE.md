# AudioScribe

A macOS audio recording toolkit with two interfaces:
1. **CLI Tool** (`audioscribe`) - Command-line recorder for scripting
2. **Menu Bar App** (`AudioScribeApp`) - GUI with VU meters and CLI control

Both can record system audio, microphone, or both mixed together to WAV files.

## Quick Start

### Menu Bar App (Recommended)
```bash
cd AudioScribeApp && ./build.sh
open AudioScribeApp/AudioScribeApp.app
```

Then use the CLI controller while the app runs:
```bash
./ascribe-ctl start --output meeting.wav
./ascribe-ctl status
./ascribe-ctl stop
```

### CLI Tool
```bash
swift build -c release
cp .build/release/audioscribe AudioScribe.app/Contents/MacOS/
./ascribe --system-only --duration 30 --output meeting.wav
```

## Project Structure

```
audioscribe/
├── Sources/                    # CLI tool sources
│   ├── AudioScribe.swift       # CLI entry point (ArgumentParser)
│   ├── SystemAudioCapture.swift
│   ├── MicrophoneCapture.swift
│   ├── AudioMixer.swift
│   └── WAVWriter.swift
│
├── AudioScribeApp/             # Menu bar app
│   ├── Package.swift
│   ├── build.sh
│   ├── AudioScribeApp.app/     # App bundle
│   └── Sources/AudioScribeApp/
│       ├── App/                # Entry point & AppDelegate
│       ├── Core/               # Audio capture (copied from CLI)
│       ├── Audio/              # LevelMeter, RecordingEngine
│       ├── State/              # @Observable state management
│       ├── UI/                 # SwiftUI views
│       └── Socket/             # Unix socket server for CLI control
│
├── ascribe                     # CLI wrapper script
├── ascribe-ctl                 # Menu bar app CLI controller
└── AudioScribe.app/            # CLI app bundle (for permissions)
```

## Architecture

### CLI Tool (`Sources/`)

- `AudioScribe.swift` - CLI entry point using ArgumentParser
- `SystemAudioCapture.swift` - ScreenCaptureKit-based system audio capture
- `MicrophoneCapture.swift` - AVCaptureSession-based microphone capture (resamples to 48kHz)
- `AudioMixer.swift` - Combines audio streams and writes to WAV
- `WAVWriter.swift` - Low-level WAV file writer
- `ascribe` - Bash wrapper handling macOS permission quirks

### Menu Bar App (`AudioScribeApp/`)

See `AudioScribeApp/README.md` for detailed architecture.

Key components:
- **AppDelegate** - NSStatusItem with popover
- **RecordingEngine** - Orchestrates capture classes
- **LevelMeter** - RMS/peak calculation using Accelerate framework
- **SocketServer** - Unix socket for `ascribe-ctl` commands
- **SwiftUI Views** - VU meters, permission status, recording controls

### Why AVCaptureSession instead of AVAudioEngine for microphone?

AVAudioEngine's `installTap()` callback never fires when the app is launched via `open` (required for microphone permission). AVCaptureSession works correctly in both contexts. The microphone may deliver audio at a different sample rate (e.g., 24kHz for AirPods), so AVAudioConverter resamples to 48kHz for consistency with system audio.

## macOS Permission Issues

### Microphone Access

**Problem**: CLI binaries cannot trigger the microphone permission prompt on macOS. Running the binary directly results in "Microphone permission denied" without any prompt appearing.

**Solution**: Wrap the binary in an app bundle and launch via `open`:
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
1. Add the app bundle to Screen Recording permissions
2. The binary can then run directly (no need for `open`)

**Key Finding**: Unlike microphone, screen recording permission works when running the binary directly from the app bundle, without needing `open`.

### Combined Mode (Mic + System)

**Problem**: Combined mode needs both permissions, but:
- Direct run: screen recording ✓, mic ✗
- Via `open`: mic ✓, screen recording needs to be pre-granted

**Solution**: Add the app to Screen Recording in System Settings, then launch via `open` for microphone access. The screen recording permission works when pre-granted.

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

## CLI Wrapper Scripts

### `ascribe` (for CLI tool)

Handles permission differences:
- `--system-only`: Runs binary directly (screen recording works without `open`)
- Modes with microphone: Uses `open` to launch app bundle (required for mic permission)

### `ascribe-ctl` (for menu bar app)

Controls the running menu bar app via Unix socket:
```bash
ascribe-ctl start [--output FILE] [--duration SECS] [--system-only] [--mic-only]
ascribe-ctl stop
ascribe-ctl status
```

## Dependencies

- ScreenCaptureKit (macOS 12.3+)
- AVFoundation
- Accelerate (for VU meters)
- ArgumentParser (Swift package, CLI only)
- macOS 14+ (for @Observable, menu bar app only)
