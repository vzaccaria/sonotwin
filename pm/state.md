# SonoTwin — State

Updated: 2026-09-03

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-8fi` — Near-real-time transcription and contextual assistant. Produce a local live transcript without coupling transcription failures to recording.
   - `audioscribe-8fi.8` — ready: route separate microphone and system chunks.
   - `audioscribe-8fi.4` — blocked by `.8`: assemble source-aware transcript outputs.
   - `audioscribe-8fi.5` — blocked by `.4`: expose controls and status.
   - `audioscribe-8fi.6` — blocked by `.4`: create the global contextual-copilot skill.
   - `audioscribe-8fi.7` — blocked by `.5` and `.6`: verify the live pipeline and recovery.

Parked: none.

## Handoff

Written: 2026-09-03 18:58 · Vittorio Zaccaria

Done: completed `audioscribe-8fi.3`; added a source-aware actor supervisor that launches one `whisper-server` directly, allocates a loopback port, verifies `/health`, serializes inference, pins language after the first non-empty result, bounds diagnostics, and owns restart/termination. Also created `.8` after approving separate microphone/system transcription. State: eight tests pass via `make test`; a real cold-load Italian inference with `ggml-large-v3-turbo` passed in 4.618 s; `.8` is ready and `.4` is blocked only by it. Next: 1) route normalized mic/system PCM through separate chunkers in `.8` 2) feed both tagged streams to the supervisor 3) merge results through `.4`. Gotchas: only finalized `.wav` chunks are accepted; one server handles both sources sequentially; silence does not pin auto language; `RecordingState` still injects no transcription pipeline. Preserve unrelated asset and build-artifact worktree changes. Blockers: none for `.8`.
