# SonoTwin — State

Updated: 2026-11-24

## Roadmap

Active (children + detail in bd; run `bd show <id>`): none.

Parked: none.

## Handoff

Written: 2026-11-24 · omp

Done: `audioscribe-q3r` persisted microphone picker (device in popover and `sonotwin-ctl status`); compact popover (transcription as one status line, collapsed Details); `SonoTwinApp/.build/` untracked; PM aligned to the current skill. State: `main` committed and working; the working tree holds uncommitted, untracked-in-bd transcription changes (28 s chunks with 2 s overlap, silent-chunk skip in `TranscriptionChunkPipeline`, README note) not authored in this session. Next: 1) decide whether those changes get a bead, tests and a commit 2) open a bead for cancelling a large transcription drain backlog if still wanted. Gotchas: no release tags or `release:*` labels yet — run `/pm release define-policy` before the first release; the signing certificate must stay on this workstation; never commit `SonoTwinApp/.build/`. Blockers: none.
