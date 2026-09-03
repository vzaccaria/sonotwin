# SonoTwin

A macOS menu bar app for recording system audio and microphone with real-time VU meters.

## Build

```bash
make build
make run
```

## CLI Control

```bash
./sonotwin-ctl status
./sonotwin-ctl start --output recording.wav
./sonotwin-ctl stop
```

## Project Structure

- `SonoTwinApp/` - SwiftUI menu bar app (macOS 14+)
- `sonotwin-ctl` - CLI controller (bash script)
- `Assets/architecture.excalidraw` - Component diagram

See [README.md](README.md) for full documentation.

## Development: Permission Reset After Rebuild

macOS tracks privacy permissions (Screen Recording, Microphone) by app identity, which includes code signature and binary hash. After rebuilding, you may need to:

1. Open **System Settings > Privacy & Security > Screen Recording**
2. Remove the old `SonoTwinApp` entry
3. Re-add the newly built app

This happens because unsigned/ad-hoc signed development builds change identity on each rebuild. To clear all screen recording permissions at once:

```bash
tccutil reset ScreenCapture
```

With proper Developer ID code signing, permissions persist across rebuilds.


## Project management

This repository uses the `/pm` workflow. `pm/` holds strategy and session state;
`bd` is the single source of truth for tracked work.

- Run `/pm open` before starting a session.
- Create and update work items with `bd`; run `bd prime` for command details.
- Run `/pm close` to update the handoff and commit locally.
- Push Git and Dolt state only through `/pm sync`.
- Do not maintain markdown backlogs or completed-work logs.
