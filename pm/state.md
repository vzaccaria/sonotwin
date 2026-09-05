# SonoTwin — State

Updated: 2026-09-05

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-8fi` — Near-real-time transcription and contextual assistant. Produce a local live transcript without coupling transcription failures to recording.
   - `audioscribe-8fi.7` — in progress: live save/backlog check recorded; degraded and recovery scenarios remain.
   - `audioscribe-8fi.11` — open: make recording stop independent of transcript drain.

Parked: none.

## Handoff

Written: 2026-09-05 12:43 · OpenAI Codex

Done: captured the live performance/save failure on `audioscribe-8fi.7` and created `audioscribe-8fi.11`. A 437.66 s dual-source recording stopped with 37 queued chunks; the WAV was already finalized and valid, but `RecordingState.stopRecording` kept recording state true while synchronously awaiting transcript drain. Drain completed about 248 s after the latest emitted audio with all 174 chunks transcribed. CPU snapshots were low (app 0.2%, child server 0.0%); the SonoTwin `large-v3-turbo` server held about 1.7 GB RSS. System memory free rose from 23% to 26% after Obsidian was killed. State: app is no longer recording; transcript lifecycle is complete; WAV validates as PCM s16le, 48 kHz, stereo, 437.66 s. Next: 1) implement `audioscribe-8fi.11` so recording completion is independent of transcript drain 2) benchmark and bound dual-source inference throughput/backlog 3) finish degraded and recovery scenarios in `audioscribe-8fi.7`. Gotchas: one runtime consumer serially awaits every system and microphone inference; stop finalizes audio first but does not clear `isRecording` or reply until `finishSession` drains. Blockers: none.
