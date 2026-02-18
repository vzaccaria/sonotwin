# AudioScribe

A macOS menu bar app for recording system audio and microphone with real-time VU meters. Includes CLI control via Unix socket.

## Quick Start

```bash
# Build
make build

# Run
make run
# Or: open AudioScribeApp/AudioScribeApp.app

# Control via CLI (while app is running)
./ascribe-ctl status
./ascribe-ctl start --output meeting.wav
./ascribe-ctl stop
```

## Project Structure

```
audioscribe/
├── AudioScribeApp/                 # Menu bar app
│   ├── Package.swift
│   ├── AudioScribeApp.app/         # App bundle
│   │   └── Contents/
│   │       ├── Info.plist          # Permission descriptions
│   │       └── MacOS/              # Binary goes here
│   └── Sources/AudioScribeApp/
│       ├── App/                    # Entry point & AppDelegate
│       ├── Core/                   # Audio capture classes
│       ├── Audio/                  # LevelMeter, RecordingEngine
│       ├── State/                  # @Observable state management
│       ├── UI/                     # SwiftUI views
│       └── Socket/                 # Unix socket for CLI control
│
├── ascribe-ctl                     # CLI controller script
├── Makefile                        # Build system
└── CLAUDE.md                       # This file
```

## Architecture

### App Components

| Component | Purpose |
|-----------|---------|
| `AppDelegate` | NSStatusItem (menu bar icon) + NSPopover management |
| `RecordingState` | @Observable state container for UI |
| `RecordingEngine` | Orchestrates capture → mix → write pipeline |
| `LevelMeter` | RMS/peak calculation using Accelerate framework |
| `SocketServer` | Unix socket server for CLI control |
| `CommandHandler` | JSON command processing |

### Audio Capture

| Class | Source | Framework |
|-------|--------|-----------|
| `SystemAudioCapture` | Other apps' audio | ScreenCaptureKit |
| `MicrophoneCapture` | Microphone input | AVCaptureSession |
| `AudioMixer` | Combines streams | Custom buffering |
| `WAVWriter` | File output | Foundation |

### SwiftUI Views

- `PopoverContentView` - Main container
- `VUMeterView` - Gradient meter with peak indicator
- `RecordingControlsView` - Start/stop, source toggles
- `PermissionStatusView` - Permission status indicators

## CLI Control Protocol

The app listens on `/tmp/audioscribe.sock` for JSON commands:

```bash
# Start recording
echo '{"action":"start","output":"/path/to/file.wav"}' | nc -U /tmp/audioscribe.sock

# Stop recording
echo '{"action":"stop"}' | nc -U /tmp/audioscribe.sock

# Get status
echo '{"action":"status"}' | nc -U /tmp/audioscribe.sock
```

Response format:
```json
{"success":true,"recording":true,"elapsedSeconds":42,"outputPath":"/path/to/file.wav"}
```

The `ascribe-ctl` script provides a friendly interface to these commands.

## macOS Permissions

The app requires:
- **Microphone** - For microphone recording
- **Screen Recording** - For system audio (ScreenCaptureKit requirement)

Both are declared in `AudioScribeApp/AudioScribeApp.app/Contents/Info.plist`.

On first launch, click "Grant" in the permission status area or go to System Settings > Privacy & Security.

## Build Commands

```bash
make build    # Build release
make debug    # Build debug
make run      # Build and launch
make clean    # Remove build artifacts
make help     # Show help
```

## Dependencies

- macOS 14+ (for @Observable)
- ScreenCaptureKit (system audio)
- AVFoundation (microphone)
- Accelerate (VU meters)
- SwiftUI (UI)
