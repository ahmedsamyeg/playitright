# DEVELOPMENT.md

Everything a developer needs to build, test, and extend PlayItRight. For the
product feature set see [README.md](README.md); for the requirement-level
*what*, see [docs/specs/](docs/specs/README.md); for the task-by-task history,
see [docs/development/IMPLEMENTATION_PLAN.md](docs/development/IMPLEMENTATION_PLAN.md).

## Requirements

- **Xcode 27.1+** with the tvOS, iOS, visionOS, and macOS SDKs (the project
  pins `CreatedOnToolsVersion 27.1` and Swift 6 toolchain settings).
- **Xcode command line:** the Makefile resolves the developer dir itself
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`); you only need
  this when invoking `xcodebuild` manually.
- No other dependencies: the only remote package is
  [GRDB](https://github.com/groue/GRDB.swift), resolved by Xcode.

## Build & test commands

Xcode keeps the schemes for every target; the Makefile wraps the common ones.

```sh
make                # build tvOS app + create dev database
make build          # build the tvOS app + LibraryCore framework (Debug)
make build-release  # same, Release configuration
make test           # full tvOS suite: app unit tests + UI tests
make test-ios       # iOS companion + shared LibraryCore tests (iPhone sim)
make test-suite SUITE=PlaybackKitTests   # run one suite/test name only
make build-mac      # macOS shell (platform=macOS)
make build-vision   # visionOS shell (visionOS Simulator)
```

### Local suite runs

`make test-suite SUITE=<NamePattern>` runs one suite on the tvOS simulator
destination — the fast feedback loop while iterating:

```sh
make test-suite SUITE=HDR10PlusProcessorTests
make test-suite SUITE=SubtitleDownloadClientTests
```

Never run two `xcodebuild` commands concurrently; the simulator is a shared
resource and results will interleave.

### Database management

```sh
make db                # create dev database (db/dev/library.db)
make db ENV=prod       # prod database (db/prod/library.db)
make reset-db ENV=dev  # delete + recreate
make env-info ENV=dev  # show resolved configuration
make check-env         # validate ENV value
```

Valid environments: `dev`, `test`, `prod`.

## Architecture

Six native framework targets, one app target, plus platform shells. Everything
product-relevant lives in `Libraries/`; the tvOS app target is a thin shell
over the frameworks.

| Target | Domain | Highlights |
|---|---|---|
| `LibraryCore` | Data | SQLite (GRDB) media database, models, reader/writer; supports all six Apple platforms |
| `MetadataKit` | Discovery | Filename matching ladder, NFO parser, TMDB/TVDB/OMDb clients, artwork LRUs, OpenSubtitles/Subscene downloads |
| `SourceAdapters` | Ingest | Plex/Jellyfin/Emby APIs, SMB/NFS/WebDAV/FTP/SFTP/HTTP, UPnP, ISO/BDMV, cloud OAuth (Box/Dropbox/GDrive/OneDrive), sync coordinator |
| `PlaybackKit` | Engine | MediaGraph probing, R1–R5 pipeline planner, Metal tone mapper, fMP4 remux, codecs, HDR10+/DoVi processors, subtitles, session |
| `CapKit` | Hardware | Capability matrix + runtime probes ("About This Apple TV") |
| `CoreKit` | Infra | DI container, Keychain, ring-buffer diagnostics, entitlements |
| `SyncKit` | Cloud | CloudKit engine, records, merge rules |
| `StoreKit` | Commerce | StoreKit 2 purchase manager, entitlements, Pro gating |

Two **app targets** beyond tvOS exist: `PlayItRightCompanion` (iOS/iPadOS
browser over the shared database) and, from Phase 4, `PlayItRightMac` and
`PlayItRightVision` — thin SwiftUI shells that open the same LibraryCore
database and adapt presentation per platform.

## Framework target rules (doc §8.2 of the plan)

1. TvOS-first; `Swift 6`; frameworks default to
   `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`, app/companion targets to
   `MainActor`.
2. Sources live under `Libraries/<Module>/` and are wired via
   file-system-synchronized groups.
3. Tests live under `PlayItRightTests/<Module>Tests/` with
   `@testable import <Module>`; UI tests in `PlayItRightUITests/`.
4. Link/embed only what a target actually uses; `PlaybackSpike` compiles into
   the test target only.

## Testing conventions

- **Swift Testing** (`@Suite`, `#expect`) everywhere; no XCTest unit tests.
- throw-assertion caveat: `#expect(throws:label:)` ordering isn't available on
  this SDK — use a do/catch with `caught` + `String(describing:)` comparison,
  or `try #require(caught)`.
- Suites sharing static mock registries (mock `URLProtocol` classes, mock
  `SubtitleHTTPTransport` handlers) must be `@Suite(.serialized)` and call
  `reset()` between tests.
- Mock network targets must be **injectable transports** (protocols, not
  `URLSession.shared` direct calls) so tests never touch the network; tests
  are parallel-safe otherwise.
- Exact expectations: prefer assigning to locals over side-effecting inside
  `#expect`.
- **New network hosts** must be registered in the privacy allowlist test
  (`PlayItRightTests/CoreKitTests/PrivacyAuditTests.swift`) or CI fails.
- Fixtures in `PlayItRightTests/Fixtures/` are tiny real media files (H.264,
  HEVC, HDR, HLG, AC-3, E-AC-3 mini-assets, plus recorded DoVi/Atmos probes)
  used by the alpha conformance gate to assert the 2-second startup budget,
  rung selection, and badge accuracy.

## Conformance & release gates

- **Alpha conformance suite** — real media fixtures, deterministic.
- **Privacy audit** (`PrivacyAuditTests`) — every hardcoded `https?://` host
  must be allowlisted; telemetry SDK imports are rejected; zero-tracking
  privacy-manifest assertions (NFR-11, NFR-13).
- **License audit** — `./scripts/audit-licenses.sh` verifies zero GPL/SSPL
  copyleft references at the source level and that build scripts keep
  `--disable-gpl`/dynamic-LGPL flags (ARCH-6, doc 09).
- Documentation updates accompany every landed feature: the
  [IMPLEMENTATION_PLAN.md](docs/development/IMPLEMENTATION_PLAN.md) dashboard
  and README status.

## Development history

Phases completed in order, as tracked in
[docs/development/IMPLEMENTATION_PLAN.md](docs/development/IMPLEMENTATION_PLAN.md):

- **Phase 0 — De-risking (5 tasks):** playback/protocol/FFmpeg/server/CloudKit
  spikes against real hardware and labs; findings in
  `docs/development/research/`.
- **Phase 1 — MVP Alpha (52 tasks):** core libraries, matching, tvOS UI,
  playback sessions, quality badge, alpha conformance gate.
- **Phase 2 — Public Beta (15 tasks):** extended software codecs, HD audio,
  CloudKit sync, StoreKit Pro, diagnostics export.
- **Phase 3 — Launch (6 tasks):** accessibility, localization, App Store
  packaging (nightly conformance matrix on device-lab remains a standing
  workstream — physical Apple TV gen 2/3/4 units were unavailable; those
  validations are recorded as simulator-based).
- **Phase 4 — v1.x (5 tasks):** macOS + visionOS targets, HDR10+ DVM
  processing, DoVi profile 7/8 → 8.1 remapping, subtitle provider downloads,
  21:9/anamorphic aspect control.

Known caveats kept on record: DoVi RPU byte-level conformance against Dolby's
reference parser, and full-hardware-lab validation of the standing
workstreams (doc 10 §Standing workstreams) — tracked at the plan's
verification notes rather than as open tasks.
