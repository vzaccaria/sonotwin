# SonoTwin — State

Updated: 2026-09-05

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-8fi` — Near-real-time transcription and contextual assistant. Produce a local live transcript without coupling transcription failures to recording.
   - `audioscribe-8fi.6` — ready: create the global contextual-copilot skill.
   - `audioscribe-8fi.7` — blocked by `.6`: verify the live pipeline and recovery.

Parked: none.

## Handoff

Written: 2026-09-05 11:27 · Vittorio Zaccaria

Done: completed `audioscribe-8fi.9`; System Recording permission now refreshes on app activation, popover open, and explicit Recheck, with ScreenCaptureKit overriding stale CoreGraphics preflight. `make build` signs the complete bundle as `com.sonotwin.app`, supports `SONOTWIN_SIGNING_IDENTITY`, warns for ad-hoc signing, and provides a scoped permission-reset target. State: 22 tests pass; strict bundle signature verification passes with bound Info.plist/resources; `.6` is ready. Next: 1) quit the currently running pre-fix process 2) run `make reset-screen-permission` once, reopen, and grant System Recording 3) configure a stable Apple Development identity before later rebuilds, then continue `.6`. Gotchas: this machine currently has zero valid code-signing identities, so the rebuilt bundle is still ad-hoc and TCC permission remains build-specific even though bundle identity/signing structure is now correct; never reset all apps' Screen Recording permission. Preserve unrelated asset and build-artifact worktree changes. Blockers: stable cross-build TCC requires a signing identity; runtime permission refresh itself is complete.
