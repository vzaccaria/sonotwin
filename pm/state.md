# SonoTwin — State

Updated: 2026-09-07

## Roadmap

Active (children + detail in bd; run `bd show <id>`): none.

Parked: none.

## Handoff

Written: 2026-09-07 10:59 · OpenAI Codex

Done: closed `audioscribe-8fi.7` and its parent epic after the reference-Mac latency, degradation, recovery, and contextual-skill matrix passed. Restart recovery now persists the active transcript bundle, repairs a trailing partial JSONL record, resumes pending atomic chunks, and clears recovery state after completion. State: full suite 31/31 passes; `make debug` passes; stable-signed release build passes; live socket status is idle. Next: no active tracked work. Gotchas: release builds must use the local `SonoTwin Local Development` signing identity so macOS TCC grants survive rebuilds; never commit `SonoTwinApp/.build/`. Blockers: none.
