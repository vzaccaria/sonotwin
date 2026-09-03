# SonoTwin

## Purpose

SonoTwin is a macOS 14+ menu bar application that records system audio, microphone audio, or both to WAV files. A shell CLI controls the running app through a local Unix socket.

## Architecture

- `SonoTwinApp` is a single Swift Package executable embedded in a menu bar app bundle.
- The app layer owns the status item, popover lifecycle, and composition root.
- State and UI remain on `MainActor`; recording orchestration bridges them to capture and file-writing components.
- The audio boundary captures system and microphone streams, mixes them, computes levels, and writes WAV output.
- An optional bounded transcription branch converts archived PCM to atomic mono 16 kHz WAV chunks without blocking recording.
- The socket boundary exposes start, stop, and status commands as JSON over `/tmp/sonotwin.sock`; `sonotwin-ctl` is its shell client.
- `Assets/` contains architecture and concurrency diagrams; `README.md` documents the user-facing protocol and behavior.

## Build & test

- `make debug` — compile a debug executable.
- `make build` — compile release and copy the executable into `SonoTwinApp.app`.
- `make run` — build and launch the menu bar app.
- `./sonotwin-ctl status` — smoke-check the socket protocol while the app runs.
- `make test` — run the Swift package contract tests.

## Conventions

- Keep UI-visible state and AppKit/SwiftUI updates on `MainActor`.
- Keep real-time audio callbacks bounded; synchronize shared callback state explicitly and avoid avoidable allocation.
- Preserve the JSON socket contract documented in `README.md` when changing app or CLI commands.
- Development builds are unsigned/ad-hoc: rebuilding can invalidate Screen Recording and Microphone permissions.
- Track work only in `bd`; keep strategy and session handoff only in `pm/`.
