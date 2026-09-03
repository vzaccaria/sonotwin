# SonoTwin — State

Updated: 2026-09-03

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-8fi` — Near-real-time transcription and contextual assistant. Produce a local live transcript without coupling transcription failures to recording.
   - `audioscribe-8fi.1` — ready: define the session contract and latency budget.
   - `audioscribe-8fi.2` — blocked by `.1`: build the off-callback PCM chunk pipeline.
   - `audioscribe-8fi.3` — blocked by `.1`: supervise a persistent `whisper-server`.
   - `audioscribe-8fi.4` — blocked by `.2` and `.3`: assemble incremental transcript outputs.
   - `audioscribe-8fi.5` — blocked by `.4`: expose controls and status.
   - `audioscribe-8fi.6` — blocked by `.4`: create the global contextual-copilot skill.
   - `audioscribe-8fi.7` — blocked by `.5` and `.6`: verify the live pipeline and recovery.

Parked: none.

## Handoff

Written: 2026-09-03 15:38 · Vittorio Zaccaria

Done: approved the persistent `whisper-server` architecture and created epic `audioscribe-8fi` with seven dependency-ordered children. State: planning complete; no application code changed or built; `.1` is ready and all later work is blocked as designed. Next: 1) claim `.1` 2) benchmark candidate models and chunk windows on the M2 3) lock the JSONL/session contract and latency target before implementation. Gotchas: do not expose the growing archival WAV—its header is finalized only at stop; `whisper-cli` is batch-oriented and `whisper-stream` captures its own microphone, so the approved backend is a loopback `whisper-server` fed finalized atomic chunks. Preserve unrelated asset and build-artifact worktree changes. Blockers: none for `.1`.
