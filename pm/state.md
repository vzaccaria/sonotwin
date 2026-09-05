# SonoTwin — State

Updated: 2026-09-05

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-8fi` — Near-real-time transcription and contextual assistant. Produce a local live transcript without coupling transcription failures to recording.
   - `audioscribe-8fi.6` — ready: create the global contextual-copilot skill.
   - `audioscribe-8fi.7` — blocked by `.6`: verify the live pipeline and recovery.

Parked: none.

## Handoff

Written: 2026-09-05 11:14 · Vittorio Zaccaria

Done: completed `audioscribe-8fi.4` and `.5`; the app now assembles recoverable source-aware JSONL/TXT transcripts, owns a persistent health-checked `whisper-server`, and exposes shared lifecycle/backlog/error/output-path status in the popover, socket, and CLI. The UI includes persisted configuration, a server Check action, and copy/Finder actions for recording, session, and transcript paths. State: 20 tests pass via `make test`; real `ggml-large-v3-turbo` health passed in 3.542 s; CLI status/check smoke passed against a Unix-socket fixture; `.6` is ready. Next: 1) restart the currently running app to load the rebuilt popover 2) implement the global contextual-copilot skill in `.6` 3) run permissioned live capture/recovery verification in `.7`. Gotchas: invalid ASR never blocks archive recording; transcript v1 now requires `source` and timestamp monotonicity is per source; successful sessions delete chunks but failed/incomplete sessions retain them; app termination waits for drain/server shutdown. Preserve unrelated asset and build-artifact worktree changes. Blockers: none for `.6`.
