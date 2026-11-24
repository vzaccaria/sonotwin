# SonoTwin — State

Updated: 2026-11-24

## Roadmap

Active (children + detail in bd; run `bd show <id>`):

1. `audioscribe-dic` — SonoTwin 0.1.0. Detail: `/pm release view`.

Parked: none.

## Handoff

Written: 2026-11-24 · omp

Done: `audioscribe-q3r` persisted microphone picker; compact popover; PM aligned to the current skill; release policy defined (`pm/release-policy.md`: 0.x SemVer, final only, gates build + live smoke + Fable/Astra review for MINOR), `CHANGELOG.md` seeded, app binary and `_CodeSignature/` untracked; 0.1.0 planned (`audioscribe-dic`): transcription on the Tailscale VM 100.84.190.47 via ssh-on-demand whisper.cpp, no local models, chunks queued while the host is unreachable, cancel for huge backlogs. State: `main` committed and working; the working tree holds the uncommitted chunking changes now tracked as `audioscribe-dic.5`. Next: 1) `audioscribe-dic.1` throughput spike on the VM (16 cores, no GPU: it decides the model and whether the plan holds) 2) `audioscribe-dic.5` land the chunking changes 3) `audioscribe-dic.2` remote launch script. Gotchas: the VM is reached through a Tailscale relay, so mind latency; `Info.plist` still says `1.0` until the release commit; a fresh clone needs `make build` before `make run`; the signing certificate must stay on this workstation. Blockers: none.
