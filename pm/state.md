# SonoTwin — State

Updated: 2026-09-05

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-8fi` — Near-real-time transcription and contextual assistant. Produce a local live transcript without coupling transcription failures to recording.
   - `audioscribe-8fi.7` — ready: verify the live pipeline, skill invocation, control, and recovery end to end.

Parked: none.

## Handoff

Written: 2026-09-05 12:26 · Vittorio Zaccaria

Done: completed `audioscribe-8fi.6`; installed `contextual-copilot` in the canonical global skills repository with implicit `?` routing, deterministic snapshotting of finalized transcript JSONL, stable sequence/time provenance, five-minute context expansion, prompt-supplied document context, content-specific explanation/research follow-ups, and no polling. Added explicit SonoTwin `start`/`stop`/`status` control; a bare `?` is read-only, while an explicit start begins recording plus local transcription and stop waits for drain. Updated the global `meetings` skill to reuse the newest complete `.sonotwin` transcript whose manifest recording path exactly matches the selected WAV, invoking Whisper only when no completed match exists. Verification: seven helper/control tests pass; both skills pass the official validator; real app status and live transcript resolution reached session `EC6EDB9F-D5E2-4F70-99B7-B9B51CD4FBCD` through sequence 7; forward simulations produced the requested recap/explanation/actions and preserved transcript/document provenance. Next: execute `audioscribe-8fi.7` end-to-end verification, including a fresh agent session so the startup-time skill registry discovers `contextual-copilot`. Gotchas: the current already-running agent session has a static skill registry and reports the newly installed skill as unknown; a new session should load it. Stable cross-build TCC still requires a real signing identity; preserve unrelated asset and build-artifact worktree changes.
