# SonoTwin — State

Updated: 2026-09-03

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-8fi` — Near-real-time transcription and contextual assistant. Produce a local live transcript without coupling transcription failures to recording.
   - `audioscribe-8fi.2` — ready: build the off-callback PCM chunk pipeline.
   - `audioscribe-8fi.3` — ready: supervise a persistent `whisper-server`.
   - `audioscribe-8fi.4` — blocked by `.2` and `.3`: assemble incremental transcript outputs.
   - `audioscribe-8fi.5` — blocked by `.4`: expose controls and status.
   - `audioscribe-8fi.6` — blocked by `.4`: create the global contextual-copilot skill.
   - `audioscribe-8fi.7` — blocked by `.5` and `.6`: verify the live pipeline and recovery.

Parked: none.

## Handoff

Written: 2026-09-03 15:55 · Vittorio Zaccaria

Done: completed `audioscribe-8fi.1`; benchmarked `ggml-large-v3-turbo` on the M2 and fixed the 5 s cadence, 1 s overlap, auto-once language policy, JSONL v1 contract, recovery rules, and ≤8 s latency budget. State: contract locked in the closed bead; no application code changed or built; `.2` and `.3` are independently ready. Next: 1) implement the bounded PCM/chunk branch in `.2` 2) implement the loopback process supervisor in `.3` 3) integrate both through `.4`. Gotchas: server readiness was 4.4 s with ~1.57 GiB RSS; 5 s auto-language inference median was 2.52 s, then 1.38 s after pinning Italian; longer cadences miss the end-to-text budget. Preserve unrelated asset and build-artifact worktree changes. Blockers: none for `.2` or `.3`.
