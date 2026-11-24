# SonoTwin — Release policy

## Lines and numbering

- Single line: `main`. No maintenance branches; fixes ship in the next release.
- SemVer `0.MINOR.PATCH` until the socket JSON contract and the transcript
  session format (`transcript.jsonl`, `session.json`) are declared stable;
  `1.0.0` marks that decision. First release: `0.1.0`.
- MINOR: new feature, or any change to the socket contract or session format.
- PATCH: fixes only, contract and format unchanged.
- Version lives in `SonoTwinApp/SonoTwinApp.app/Contents/Info.plist`:
  `CFBundleShortVersionString` = `<version>`, `CFBundleVersion` = `<version>`.
  Tag `v<version>` (annotated).

## Stages

| Stage | Guarantees | May still change | Gate before tagging |
| --- | --- | --- | --- |
| final | Tests green, signed release build, live recording + transcription smoke passed on this Mac; MINOR releases independently reviewed | Anything in the next MINOR | `build` + `smoke` + `review` (MINOR) |

No pre-release stages: single user, the release is used in the next meeting.

## Gates

All gates run on this workstation (it holds the signing certificate and TCC
grants), clean tree, at the commit to tag. Any failure blocks the tag.

`build` — about 2 min:

- `make test`, then `make build`, then
  `codesign --verify --strict SonoTwinApp/SonoTwinApp.app`.

`smoke` — about 2 min, needs speech or system audio during the recording:

- `make run`; `./sonotwin-ctl status` reports both permissions granted and the
  selected microphone.
- `./sonotwin-ctl start -o /tmp/sonotwin-gate-<version>.wav -d 30 --transcribe`
  (microphone + system), then `./sonotwin-ctl status` until the transcription
  state is `complete`.
- Pass: WAV exists and is non-silent, `transcript.jsonl` in the sibling
  `.sonotwin/` session has at least one non-empty line, no transcription error.

`review` — MINOR releases (`0.x.0`) only; PATCH releases skip it:

- Two independent read-only reviews run at the same time, one Fable-role
  (`con-fable-5`) and one Astra-role (`con-astra-6`), of
  `git diff v<previous>..HEAD` (first release: whole tree). Focus: real-time
  audio callback safety (allocation, locking, bounded work), `MainActor` and
  concurrency, socket contract compatibility, transcript loss and recovery
  after crash or stop, child-process lifecycle of whisper-server, audio leaving
  the machine, dead code left by cutovers, test gaps.
- Findings are classified blocking or non-blocking. Blocking ones become beads
  under the release epic that the gate bead depends on, fixed and re-checked
  before the cut; non-blocking ones become backlog beads.
- Runs before the release commit; `build` and `smoke` then run on the release
  commit.

## Evidence

Gate bead notes record: commit SHA, date, hostname, `make test` counts
(passed/failed/skipped), `codesign --verify` result, smoke WAV path and size,
transcript line count, and for MINOR releases the two reviews (reviewer, diff
range, blocking and non-blocking findings, beads created). The tag note states
the gates passed and points to the gate bead (`Refs:` trailer).

## Artifacts at the tag

One release commit `chore(release): v<version>` containing:

- `CHANGELOG.md`: `## Unreleased` renamed to `## <version> — YYYY-MM-DD`, with a
  fresh empty `## Unreleased` above it.
- Version bump in `Info.plist` (both keys above).

The app binary and its code signature are not tracked: the bundle is rebuilt
with `make build`.

## History conventions

- Commits: conventional commits (`feat(scope): …`, `fix(…)`, `chore(…)`), no
  bead IDs in subject or body; at most a `Refs: <id>` trailer.
- `CHANGELOG.md`: user-visible changes under Added / Changed / Fixed, no bead
  IDs, no file paths. Add the entry to `## Unreleased` in the commit that lands
  the feature or fix, not at release time.
- Tag note: version, 3–8 line summary from the changelog section, gate result.
