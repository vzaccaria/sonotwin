# SonoTwin — State

Updated: 2026-09-07

## Roadmap

Active (children + detail in bd; run `bd show <id>`): none.

Parked: none.

## Handoff

Written: 2026-09-07 13:40 · OpenAI Codex

Done: closed `audioscribe-y4u`; plain `make build` now signs with the local `SonoTwin Local Development` identity by default, preserving the existing microphone and ScreenCapture TCC grants across rebuilds. State: release build, strict code-signature verification, dual-source permission smoke, and live socket status passed; app is idle with transcription enabled and no server loaded. Next: no active tracked work. Gotchas: this workstation must retain the named certificate; other machines without it can explicitly set `SONOTWIN_SIGNING_IDENTITY=-`; never commit `SonoTwinApp/.build/` or generated bundle artifacts. Blockers: none.
