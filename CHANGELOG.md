# Changelog

## Unreleased

### Added

- Menu bar app that records system audio, microphone, or both to a WAV file,
  with live level meters.
- `sonotwin-ctl` to start, stop and inspect recordings of the running app.
- Optional live transcription with a local Whisper server: microphone and
  system audio are transcribed separately into `transcript.txt` and
  `transcript.jsonl` next to the recording, with progress in the popover and in
  `sonotwin-ctl status`.
- Choice of the microphone, remembered across launches, with the device in use
  shown in the popover and in `sonotwin-ctl status`.

### Changed

- Compact popover: transcription shown as one status line with collapsible
  details; permissions appear only when missing.
- `make build` signs with the local development identity by default, so
  macOS privacy permissions survive rebuilds.

### Fixed

- Stopping a recording no longer waits for the transcription backlog; the
  remaining audio is transcribed afterwards.
- Transcriptions interrupted by a crash resume on the next launch, and a leftover
  Whisper server is stopped.
- The spoken language is kept instead of being translated to English.
- Permission status refreshes after granting access in System Settings.
