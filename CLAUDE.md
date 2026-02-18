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
- `architecture.excalidraw` - Component diagram

See [README.md](README.md) for full documentation.
