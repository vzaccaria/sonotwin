# SonoTwin — State

Updated: 2026-09-05

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-8fi` — Near-real-time transcription and contextual assistant. Produce a local live transcript without coupling transcription failures to recording.
   - `audioscribe-8fi.4` — ready: assemble source-aware transcript outputs.
   - `audioscribe-8fi.5` — blocked by `.4`: expose controls and status.
   - `audioscribe-8fi.6` — blocked by `.4`: create the global contextual-copilot skill.
   - `audioscribe-8fi.7` — blocked by `.5` and `.6`: verify the live pipeline and recovery.

Parked: none.

## Handoff

Written: 2026-09-05 10:41 · Vittorio Zaccaria

Done: completed `audioscribe-8fi.8`; microphone and system PCM are now tapped before mixing and routed through independent bounded chunkers under `chunks/<source>`. Every chunk carries its source and comparable monotonic-session timestamps; the mixed archival WAV remains outside ASR. The supervisor now consumes source-bearing chunks directly. State: 12 tests pass via `make test`; `.4` is ready. Next: 1) assemble JSONL/text outputs from both tagged streams in `.4` 2) connect chunk callbacks to the single serialized supervisor 3) expose runtime controls/status in `.5`. Gotchas: `RecordingState` intentionally injects no transcription pipelines until the remaining session composition work; first-buffer timestamps use capture arrival minus buffer duration, then exact frame counts; ASR backlog/failure is per source and never controls archive writes. Preserve unrelated asset and build-artifact worktree changes. Blockers: none for `.4`.
