# SonoTwin — State

Updated: 2026-11-24

## Roadmap

Active (children + detail in bd; run `bd show <id>`): none.

Parked: none.

## Handoff

Written: 2026-11-24 · omp

Done: `audioscribe-q3r` persisted microphone picker (device in popover and `sonotwin-ctl status`); compact popover (transcription as one status line, collapsed Details); PM aligned to the current skill; release policy defined (`pm/release-policy.md`: 0.x SemVer, final only, gates build + live smoke + Fable/Astra review for MINOR), `CHANGELOG.md` seeded for 0.1.0, app binary and `_CodeSignature/` untracked. State: `main` committed and working; the working tree holds uncommitted, untracked-in-bd transcription changes (28 s chunks with 2 s overlap, silent-chunk skip in `TranscriptionChunkPipeline`, README note) not authored in this session. Next: 1) decide whether those changes get a bead, tests, a CHANGELOG entry and a commit 2) `/pm release plan 0.1.0` when ready. Gotchas: `Info.plist` still says `1.0` until the 0.1.0 release commit; a fresh clone needs `make build` before `make run`; the signing certificate must stay on this workstation. Blockers: none.
