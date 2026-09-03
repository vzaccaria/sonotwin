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
- Never include generated `SonoTwinApp/.build/` artifacts in commits.
