# SonoTwin — State

Updated: 2026-09-05

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-8fi` — Near-real-time transcription and contextual assistant. Produce a local live transcript without coupling transcription failures to recording.
   - `audioscribe-8fi.7` — in progress: live save/backlog check recorded; degraded and recovery scenarios remain.
   - `audioscribe-8fi.11` — open: make recording stop independent of transcript drain.

Parked: none.

## Handoff

Written: 2026-09-05 13:34 · OpenAI Codex

Done: completed `audioscribe-8fi.13`; contextual-copilot now begins with no transcript selected, never auto-adopts app status, environment, or recent files, and annotates only a successful skill-driven start with `selectedTranscriptPath` for conversation-local reuse. A bare `?` without selection performs no socket discovery; selected prompts use one 60 s snapshot, direct responses normally under 80 words, compact provenance, no automatic context expansion, and no unsolicited follow-up menu. Verification: 8 helper tests pass; official skill validation passes; real `status` exposed the completed session without selecting it, the following default snapshot returned “no transcript selected” in 0.09 s, and explicit path selection resolved in 0.11 s. Global skill commit: `ad9a6b6`. State: `audioscribe-8fi.7` remains in progress and `audioscribe-8fi.11` is open. Next: 1) implement stop/drain decoupling in `.11` 2) benchmark dual-source throughput/backlog 3) finish degraded and recovery scenarios in `.7`. Gotchas: transcript selection is intentionally not persisted; a new agent session may be needed to reload implicit skill-routing metadata, while this conversation can follow the new contract directly; preserve unrelated asset and generated `.build` changes. Blockers: none.
