# PlayItRight

A complete Apple tvOS video player and media library app built for the **Apple TV 4K** — a full alternative to [Infuse by Firecore](https://firecore.com/infuse).

## Feature set

### Playback
- **Hardware-first pipeline ladder (R1–R5).** Every file resolves through the cheapest pipeline the sink supports: direct play → remux → hardware transcode → software transcode → FFmpeg fallback. The planner is honest about the chosen rung, and the badge in the player always matches reality.
- **Every video codec.** Apple hardware acceleration for H.264, HEVC, VP9 (gen 4), and AV1 (gen 4); a bundled software decoder covers the rest — AV1, VP8/VP9, VVC/H.266, MPEG-1/2, VC-1, WMV, DivX/Xvid, and more.
- **Every HDR format.** HDR10, HDR10+ (with dynamic-metadata processing), HLG, and Dolby Vision Profiles 5 / 8 / 8.1. Profile 7 (dual-track UHD Blu-ray) and Profile 8 RPUs are remapped to 8.1 in real time so gen-4 hardware decodes them directly; picture data is never touched.
- **Every audio format.** **Dolby Atmos, E-AC-3/JOC, DTS, DTS-HD Master Audio, and TrueHD** decode in software where hardware can't and pass through to receivers that can; configurable downmix.
- **Subtitles.** SRT, WebVTT, ASS/SSA, and PGS/SUP rendering with language/track switching mid-playback, plus *user-initiated* downloads from OpenSubtitles and Subscene with automatic sidecar caching.
- **Aspect control.** Contained, anamorphic de-squeeze, custom 2.39:1 letterbox cropping, and user stretch — including full 21:9 ultrawide panel support.

### Library
- **Local-first media database** (SQLite via GRDB) storing movies, shows, seasons, episodes, cast & crew, files, and watch state, keyed on provider IDs.
- **Automatic metadata** from TMDB, TVDB, and OMDb, a NFO sidecar parser, and a filename-matching ladder with a *Fix Matching* workflow for unmatched files.
- **Artwork pipeline** with LRU caching; posters, backdrops, and cast images.
- **Smart Libraries** — saved filters for genre, codec, watch state, source, and more — plus virtualized grid/list views with sort and density controls.

### Sources
- **Media servers:** Plex, Jellyfin, Emby.
- **File shares & network:** SMB, NFS, WebDAV, FTP, SFTP, HTTP(S), UPnP/DLNA, and local files.
- **Disc images:** ISO and BDMV (Blu-ray folder structure) parsing.
- **Cloud drives:** Box, Dropbox, Google Drive, and OneDrive with OAuth device-flow sign-in.

### Sync, casting & multi-platform
- **CloudKit sync** for library state, watch progress, and resume points across devices, with conflict-safe merge rules.
- **AirPlay and Google Cast** out of the player.
- **Companion apps:** an iOS/iPadOS library browser, and macOS (14+) and visionOS (2+) shells of the shared library framework.

### Trust & transparency
- **Zero telemetry.** No third-party analytics or crash SDKs; a privacy manifest declares no tracking and no collected data, and a CI-enforced audit allowlists every network host in the codebase.
- **Redacted diagnostics export** users control; credentials, paths, and IPs are stripped before leaving the device.
- **Honest quality badge** — what the pipeline is actually doing (which rung, which decoder, which tone-map) with a technical drill-down sheet.
- **Friendware pricing** (doc 08): a fair free tier, with a StoreKit 2 Pro tier unlocking premium formats and features; validated subscription flow with entitlement gating.

## Quick start

Open `PlayItRight.xcodeproj`, select the `PlayItRight` scheme, and run on an Apple TV 4K (simulator or device), or use the command-line:

```sh
make build          # build the tvOS app + LibraryCore framework
make test           # app, core, and UI tests on the tvOS simulator
make test-ios       # iOS companion and shared LibraryCore tests
make build-mac      # macOS shell of the shared LibraryCore framework
make build-vision   # visionOS shell of the shared LibraryCore framework (Simulator)
```

See **[DEVELOPMENT.md](DEVELOPMENT.md)** for environment setup, the full command reference, architecture overview, testing conventions, and the development-history log.

## Repository layout

```
PlayItRight.xcodeproj/          tvOS project + all targets and shared schemes
PlayItRight/                    tvOS app target (App shell, Features, Resources)
PlayItRightTests/               700 unit tests across 92 suites
PlayItRightUITests/             App-level UI tests
Libraries/
  CapKit/                       Capability matrix, runtime hardware probes, registry
  CoreKit/                      DI, Keychain, diagnostics, system services
  LibraryCore/                  SQLite media database, models, reader/writer
  MetadataKit/                  Matching, NFO, TMDB/TVDB/OMDb, artwork, subtitle downloads
  SourceAdapters/               Plex/Jellyfin/Emby, SMB/NFS/WebDAV/FTP/SFTP, UPnP, disc, cloud
  PlaybackKit/                  MediaGraph, pipeline planner, HDR color, audio, subtitles, session
  StoreKit/                     StoreKit 2 purchases, entitlements, Pro gating
  SyncKit/                      CloudKit sync engine, records, merge rules
  PlayItRightCompanion/         iOS/iPadOS companion app
  PlayItRightMac/               macOS shell (shared LibraryCore)
  PlayItRightVision/            visionOS shell (shared LibraryCore)
  PlaybackSpike/                Phase 0 spikes (test-target-only support code)
```

All product code lives in six native framework targets inside the Xcode project; GRDB is the single remote Swift package dependency (of `LibraryCore`). There is no local Swift package.

## Documentation

| Document | Contents |
|---|---|
| [DEVELOPMENT.md](DEVELOPMENT.md) | Developer guide: setup, commands, architecture, testing, history |
| [docs/specs/README.md](<docs/specs/README.md>) | Spec index, requirement IDs, glossary |
| [docs/specs/*.md](<docs/specs/README.md>) | Domain specs: product, architecture, sources, playback, metadata, UI, sync, business, NFRs, roadmap, database |
| [docs/design/README.md](<docs/design/README.md>) | Design index (the *how*; the specs are the *what*) |
| [docs/design/01-media-database.md](<docs/design/01-media-database.md>) | Database design: DDL, concurrency, migrations, recovery |
| [docs/development/IMPLEMENTATION_PLAN.md](<docs/development/IMPLEMENTATION_PLAN.md>) | Master task tracker & agent log (83/83 complete) |
| [docs/development/research/](<docs/development/research/s1-playback-results.md>) | Phase 0 hardware/spike findings (playback, protocols, FFmpeg, servers, CloudKit) |
| [AppStoreMetadata/](AppStoreMetadata/app-store-metadata.md) | App Store metadata, release notes, screenshots |

## Status

**All 83 planned tasks across Phases 0–4 are complete** — from de-risking spikes through MVP, public beta, the v1.0 launch (accessibility + localization), and the Phase 4 platform expansion (macOS/visionOS targets, HDR10+ DVM processing, Dolby Vision profile remapping, subtitle provider downloads, and 21:9/aspect control). The full, task-by-task history lives in [docs/development/IMPLEMENTATION_PLAN.md](<docs/development/IMPLEMENTATION_PLAN.md>).
