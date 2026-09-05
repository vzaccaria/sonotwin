# SonoTwin — State

Updated: 2026-09-05

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-8fi` — Near-real-time transcription and contextual assistant. Produce a local live transcript without coupling transcription failures to recording.
   - `audioscribe-8fi.7` — in progress: live save/backlog check recorded; degraded and recovery scenarios remain.

Parked: none.

## Handoff

Written: 2026-09-05 13:53 · OpenAI Codex

Done: completed `audioscribe-8fi.11`; stop now finalizes and publishes the WAV plus `"recording": false` before `TranscriptionRuntime` drains queued inference in its own task. The stop response exposes `"draining"` and the fixed backlog immediately; a transcription-enabled restart is rejected until completion, while audio-only recording remains available. The queue is sealed at drain start and each request retains its 15 s timeout, so post-stop work cannot grow or block recording finalization. Updated UI wording, disabled-state logic, socket/runtime contract tests, and README semantics. Verification: 8 focused tests pass; full suite 30/30 passes; `make debug` passes; live `sonotwin-ctl status` succeeds; the stop contract returned in 0.061 s with four chunks still draining and no synchronous finish call. State: `audioscribe-8fi.7` remains in progress. Next: 1) benchmark dual-source inference throughput/backlog under the updated stop behavior 2) exercise degraded and interrupted recovery 3) finish the end-to-end `.7` acceptance matrix. Gotchas: the installed running app must be rebuilt/relaunched to pick up this source change; preserve unrelated asset and generated `.build` changes. Blockers: none.
