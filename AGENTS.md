# Agent Instructions

## Project management

This repository uses the `/pm` workflow. `pm/` holds strategy and session state;
`bd` is the single source of truth for tracked work.

- Run `/pm open` before starting a session.
- Create and update work items with `bd`; run `bd prime` for command details.
- Run `/pm close` to update the handoff and commit locally.
- Push Git and Dolt state only through `/pm sync`.
- Do not maintain markdown backlogs or completed-work logs.

## Verification

- Build with `make debug` or `make build`.
- Smoke-test socket changes with `./sonotwin-ctl status` while the app runs.
- Never commit generated artifacts: `SonoTwinApp/.build/`, the app binary in
  `SonoTwinApp.app/Contents/MacOS/`, or `_CodeSignature/`.

## Releases

Releases follow `pm/release-policy.md`. In every commit:

- use conventional commits, with no bead IDs (at most a `Refs:` trailer);
- when it lands a user-visible feature or fix, add its entry under
  `## Unreleased` in `CHANGELOG.md`.
