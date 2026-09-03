# SonoTwin — State

Updated: 2026-09-03

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-8fi` — Near-real-time transcription and contextual assistant. Produce a local live transcript without coupling transcription failures to recording.
   - `audioscribe-8fi.3` — ready: supervise a persistent `whisper-server`.
   - `audioscribe-8fi.4` — blocked by `.3`: assemble incremental transcript outputs.
   - `audioscribe-8fi.5` — blocked by `.4`: expose controls and status.
   - `audioscribe-8fi.6` — blocked by `.4`: create the global contextual-copilot skill.
   - `audioscribe-8fi.7` — blocked by `.5` and `.6`: verify the live pipeline and recovery.

Parked: none.

## Handoff

Written: 2026-09-03 16:16 · Vittorio Zaccaria

Done: completed `audioscribe-8fi.2`; the recording engine can now fan successfully archived PCM into a bounded serial pipeline producing atomic 5 s cadence/1 s overlap mono 16 kHz WAV chunks. State: three Swift contract tests pass via `make test`; `.3` is ready and `.4` remains blocked only by `.3`. Next: 1) implement the loopback `whisper-server` supervisor in `.3` 2) connect ready chunk callbacks to sequential inference 3) integrate transcript assembly through `.4`. Gotchas: `RecordingState` intentionally injects no pipeline until configuration work; the default queue cap is 1,920,000 bytes and overflow fails transcription without affecting the archive; finite AVAudioConverter windows require end-of-stream draining and trimming to the exact expected frame count. Preserve unrelated asset and build-artifact worktree changes. Blockers: none for `.3`.
