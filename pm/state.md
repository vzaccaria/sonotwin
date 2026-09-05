# SonoTwin — State

Updated: 2026-09-05

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-8fi` — Near-real-time transcription and contextual assistant. Produce a local live transcript without coupling transcription failures to recording.
   - `audioscribe-8fi.6` — ready: create the global contextual-copilot skill.
   - `audioscribe-8fi.7` — blocked by `.6`: verify the live pipeline and recovery.

Parked: none.

## Handoff

Written: 2026-09-05 11:55 · Vittorio Zaccaria

Done: completed `audioscribe-8fi.10`; Automatic remains the default but every finalized chunk independently sends `language=auto` plus `translate=false`, so an early detection cannot pin the session to English and translation-tagged responses are rejected. The popover now renders the Automatic/Italian/English selector and server paths before capture starts. The real installed whisper-server/model transcribed synthesized Italian as Italian (`capito`) and English as English (`understand`) in Automatic mode; all 25 tests pass and the release bundle was rebuilt. The `.6` design now treats microphone-only clarification phrases such as “non ho capito” and “fammi capire meglio” as immediate, deduplicated triggers over the system-audio context. Next: quit/reopen the currently running app to load the rebuilt bundle, then implement `.6`. Gotchas: this machine still has zero valid code-signing identities, so the ad-hoc signature makes TCC permission build-specific; use `make reset-screen-permission` only for SonoTwin if System Recording is stale. Preserve unrelated asset and build-artifact worktree changes. Blockers: stable cross-build TCC still requires a signing identity.
