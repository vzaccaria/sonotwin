# AudioScribe

A macOS menu bar app for recording system audio and microphone with real-time VU meters.

## Build

```bash
make build
make run
```

## CLI Control

```bash
./ascribe-ctl status
./ascribe-ctl start --output recording.wav
./ascribe-ctl stop
```

## Project Structure

- `AudioScribeApp/` - SwiftUI menu bar app (macOS 14+)
- `ascribe-ctl` - CLI controller (bash script)
- `Assets/architecture.excalidraw` - Component diagram

See [README.md](README.md) for full documentation.

## Development: Permission Reset After Rebuild

macOS tracks privacy permissions (Screen Recording, Microphone) by app identity, which includes code signature and binary hash. After rebuilding, you may need to:

1. Open **System Settings > Privacy & Security > Screen Recording**
2. Remove the old `AudioScribeApp` entry
3. Re-add the newly built app

This happens because unsigned/ad-hoc signed development builds change identity on each rebuild. To clear all screen recording permissions at once:

```bash
tccutil reset ScreenCapture
```

With proper Developer ID code signing, permissions persist across rebuilds.
