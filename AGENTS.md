# AGENTS.md — PlayItRight

Guidance for AI coding agents working in this repository. Read this fully
before writing code; it encodes the conventions that CI and the maintainer
expect, plus the traps that have already cost time once.

## Project in one paragraph

Apple tvOS 4K media player + library app, an Infuse alternative. Six native
Swift frameworks (`LibraryCore`, `MetadataKit`, `SourceAdapters`,
`PlaybackKit`, `CapKit`, `CoreKit`, plus `SyncKit`/`StoreKit`) linked into one
tvOS app target, with additional iOS/macOS/visionOS shells. All 83 planned
tasks are complete; agents should expect to work on fixes, small features, or
the standing workstreams, and must keep the tracking docs honest.

## First moves

1. Read [README.md](README.md) for the feature set and
   [DEVELOPMENT.md](DEVELOPMENT.md) for build/test commands.
2. Read the domain spec for whatever you touch: `docs/specs/` is the *what*
   (with `DOMAIN-NNN` requirement IDs), `docs/design/` the *how*.
3. Check `docs/development/IMPLEMENTATION_PLAN.md` — it is the task tracker,
   not history-only. New work should be added there as a tracked task with
   verified status, not done off-book.

## Build & verify

```sh
make build                            # tvOS app + frameworks (Debug)
make test                             # full suite (unit + UI, tvOS sim)
make test-suite SUITE=<NamePattern>   # one suite — the fast loop
make build-mac                        # macOS shell
make build-vision                     # visionOS shell
./scripts/audit-licenses.sh           # license gate, run at the end
```

- **Never run two `xcodebuild` commands concurrently.** The simulator is a
  shared resource; interleaved results waste 10-minute builds.
- The Makefile resolves `DEVELOPER_DIR` itself; direct `xcodebuild` calls
  need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Gate rule: no task is complete until the affected suite passes and a full
  `make test` was run at the end of a work session.

## Hard rules

1. **Do not disturb unrelated uncommitted work.** Check `git status` first;
   leave files you didn't need to touch untouched.
2. **Zero telemetry.** No third-party analytics/crash SDKs. Any new network
   host must be added to the allowlist in
   `PlayItRightTests/CoreKitTests/PrivacyAuditTests.swift` or the privacy
   audit test fails CI. Subtitle downloads and similar user-initiated traffic
   must stay user-initiated — no background prefetch paths.
3. **Licensing (ARCH-6):** nothing GPL/SSPL; FFmpeg stays dynamically linked
   with `--disable-gpl`. The audit script scans source only — do not re-widen
   it to build artifacts.
4. **Docs move with code.** A landed change updates: the affected spec
   section if requirements changed, `docs/development/IMPLEMENTATION_PLAN.md`
   (dashboard + task entry), and `README.md` if the feature set changed.
5. **Privacy manifest / destructuring**: `PrivacyInfo.xcprivacy` must keep
   declaring no tracking and no collected data; database content never leaves
   the device except through the redacted diagnostics exporter.

## Swift / framework conventions

- Swift 6. Framework targets (`Libraries/*`) default
  `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`; app and companion targets
  default `MainActor`. UI-facing types are `@MainActor`; library logic stays
  nonisolated and `Sendable` where concurrency surfaces.
- Tests use **Swift Testing** (`@Suite`, `#expect`), not XCTest.
- Sources live in `Libraries/<Module>/Domain/`-style folders, wired via
  file-system-synchronized pbxproj groups — adding a file to one of those
  folders requires **no pbxproj edit**; only new targets/groups do.
- Public API surface: mark types `public` deliberately (they cross framework
  boundaries); keep internal helpers private.
- Platform shells (`PlayItRightMac`, `PlayItRightVision`,
  `PlayItRightCompanion`) open the shared `LibraryCore` database through
  `MediaDatabaseReader`; never give a shell its own schema.

## Swift Testing pitfalls (this toolchain)

- `#expect(throws:)` label order (`throws:` first) is **not** supported —
  that macro-expansion error wastes a build cycle. Use:
  ```swift
  var caught: Error?
  do { _ = try f() } catch { caught = error }
  #expect(String(describing: try #require(caught))
      == String(describing: ExpectedError.specificCase))
  ```
  (`any Error` is not `Equatable`, so compare via `String(describing:)`.)
  Also valid: `#expect(performing: { … }, throws: { err in … })` with a
  predicate closure.
- Suites sharing static mock registries (mock `URLProtocol` subclasses, mock
  `SubtitleHTTPTransport` handler tables) must be `@Suite(.serialized)` and
  `reset()` the registry between tests — parallel execution races them.
- Use injectable transports (protocol wrappers over `URLSession`), never
  `URLSession.shared` directly; tests must be able to hit every network path
  with a mock.
- No mutating calls inside `#expect`; assign to a local, then assert.

## pbxproj pitfalls (hand-editing)

`PlayItRight.xcodeproj/project.pbxproj` is hand-edited (objectVersion 110,
IDs `2EE1…`/`AA…`/`DD…`; new targets use the `EE00000000000000000000XX`
24-hex prefix). When editing:

- Replacing a multi-line anchor often silently deletes neighboring lines —
  after **every** edit, grep for the objects you touched *and* the ones
  adjacent (products list, `TargetAttributes`, `PBXTargetDependency`) to
  confirm counts.
- Keep a scratch checklist: build file, file reference, FS-sync group,
  sources/frameworks/resources phases, copy-files phase, `PBXNativeTarget`,
  container proxy, target dependency, project `targets` list,
  `TargetAttributes`, four configs, config list, product entry in Products
  group.
- Validate with `xcodebuild -list -project PlayItRight.xcodeproj` before
  building anything.
- `SUPPORTED_PLATFORMS` widening changes must cover **all** config blocks of
  a target (use `replaceAll` deliberately).

## Test data & fixtures

- `PlayItRightTests/Fixtures/` holds tiny real media assets (H.264, HEVC,
  HDR/HLG, AC-3/E-AC-3, recorded DoVi/Atmos probes). Conformance tests assert
  real behavior against them; don't replace them with mocks.
- Hand-crafted bitstreams (HDR10+ SEI, DoVi RPU) are built with paired
  encoders in the same source file; keep parser/encoder symmetry when
  touching either.
- Malformed-input tests must assert the *specific* error case, not just
  "threw".

## Commit & status hygiene

- Follow the existing commit style: short imperative subjects, e.g.
  `TASK-1.6.9 Completed`. One logical task per commit when possible.
- The tracker's dashboard must always be arithmetically consistent with the
  task checkboxes (totals, percentages, subsystem rows).
- If a verification differs from the plan's stated method, record it in the
  task's `Verified With:` line rather than weakening the plan silently.

## Known standing workstreams (don't re-invent them)

- Conformance suite on device-lab (nightly), capability matrix updates per
  Apple hardware, license audit per build, quarterly Plex/Jellyfin/Emby
  protocol-drift review (doc 10 §Standing workstreams).
- Recorded caveats, not open tasks: physical Apple TV gen 2/3/4 validation
  was simulator-fallback; DoVi RPU byte-conformance against the Dolby
  reference parser is deferred to device-lab.
