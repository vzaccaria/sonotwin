# SonoTwin — State

Updated: 2026-09-05

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-8fi` — Near-real-time transcription and contextual assistant. Produce a local live transcript without coupling transcription failures to recording.
   - `audioscribe-8fi.7` — in progress: live save/backlog check recorded; degraded and recovery scenarios remain.
   - `audioscribe-8fi.11` — open: make recording stop independent of transcript drain.

Parked: none.

## Handoff

Written: 2026-09-05 13:03 · OpenAI Codex

Done: completed `audioscribe-8fi.12`; SonoTwin now writes a private ownership record plus a per-process `SONOTWIN_WHISPER_OWNER_TOKEN`, reclaims a recorded server only when its owner is gone and the token still matches, preserves live owners and unrelated/PID-reused processes, and removes ownership on graceful or unexpected exit. Cleanup runs at app launch and is serialized again before server start. Verification: 10 focused Whisper tests pass; all 29 package tests pass; `make debug` passes; verified legacy orphan PID 64229 was terminated while current PID 99385 remained healthy via `sonotwin-ctl status`; free memory rose from 26% to 42%. State: `audioscribe-8fi.7` remains in progress and `audioscribe-8fi.11` is open. Next: 1) implement stop/drain decoupling in `.11` 2) benchmark dual-source throughput/backlog 3) finish degraded and recovery scenarios in `.7`. Gotchas: pre-token legacy orphans cannot be proven by the registry and need one-time manual verification; preserve unrelated asset and generated `.build` worktree changes. Blockers: none.
