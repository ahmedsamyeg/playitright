# PlayItRight

A complete Apple tvOS video player and media library app, built for the **Apple TV 4K** — a full alternative to
[Infuse by Firecore](https://firecore.com/infuse).

PlayItRight plays anything you own or stream:

- **Play it all** — MKV, MP4, ISO, BDMV, WEBM, and every other format. For
  every format the hardware supports, PlayItRight uses **Apple hardware
  acceleration**; bundled software transcoding steps in only for formats the
  Apple TV can't do in hardware — so Dolby Vision, HDR10, HDR10+, HLG, Dolby
  Atmos, and DTS content always plays, on any display.
- **Beautiful library** — automatic metadata, artwork, cast, ratings, and
  trailers from any source, organized the way you think — backed by a local
  media database keyed on TMDB/TVDB ids with full cast & crew records.
- **Every source** — Plex, Jellyfin, Emby, SMB, NFS, WebDAV, FTP/SFTP, UPnP,
  cloud drives, and local files.
- **Synced** — libraries, watch state, and in-progress resume across your
  devices, plus AirPlay and Google Cast.

## Repository layout

```
PlayItRight.xcodeproj/          tvOS app project + shared scheme
PlayItRight/
  App/                          App entry point and shell
  Features/
    Library/                    Library screen and its view model
  Resources/                    Asset catalogs and other resources
PlayItRightTests/
  CapKitTests/                  Capability matrix and probe tests
  MetadataKitTests/            Filename matching, NFO, provider, and artwork tests
  SourceAdaptersTests/          Source adapter contract, protocol, and sync tests
  PlaybackKitTests/             Media graph, planner, pipeline, and session tests
  CoreKitTests/                 Dependency injection and infrastructure tests
  LibraryCoreTests/             LibraryCore framework tests
  ConformanceTests/             Alpha playback conformance matrix
  Fixtures/                     Tiny real media assets for conformance tests
  PlaybackSpikeTests/           Playback spike tests (test target only)
PlayItRightUITests/             App UI tests
Libraries/
  CapKit/                       Capability matrix, runtime probes, registry
  CoreKit/                      DI, security, diagnostics, and system services
  LibraryCore/                  Media database, models, reader/writer framework
  MetadataKit/                  Filename matching, NFO, metadata providers, artwork
  SourceAdapters/               Source adapters, byte ranges, source models, sync coordinator
  PlaybackSpike/                Phase 0 playback/protocol/sync harnesses
  PlaybackKit/                  MediaGraph probing, pipeline planning, playback sessions
```

`LibraryCore`, `CoreKit`, `CapKit`, `MetadataKit`, `SourceAdapters`, and `PlaybackKit`
are native framework targets inside `PlayItRight.xcodeproj`. The app target links and embeds
them; GRDB is a remote Swift package dependency of `LibraryCore`. `PlaybackSpike` is test-only
support code compiled into `PlayItRightTests`. There is no local Swift package.

Open `PlayItRight.xcodeproj`, select the `PlayItRight` scheme, and run on an
Apple TV 4K simulator or device. The command-line equivalents are:

```sh
make build          # build the tvOS app + LibraryCore framework
make test           # app, core, and UI tests on the tvOS simulator
make xcode-build    # alias for make build
make xcode-test     # alias for make test
```

## Documentation

| Document | Contents |
|---|---|
| [docs/specs/README.md](<docs/specs/README.md>) | Spec index, how to read, glossary, requirement IDs |
| [docs/specs/01-product-overview.md](<docs/specs/01-product-overview.md>) | Vision, personas, feature pillars, free/Pro tiers, KPIs |
| [docs/specs/02-architecture.md](<docs/specs/02-architecture.md>) | Module design, tech stack, data flows, build & licensing |
| [docs/specs/03-media-sources.md](<docs/specs/03-media-sources.md>) | Plex / Jellyfin / Emby / file share / cloud / local source adapters |
| [docs/specs/04-playback-engine.md](<docs/specs/04-playback-engine.md>) | Format matrices, Apple TV capability matrix, pipeline planner, HDR/DoVi & audio transcoding |
| [docs/specs/05-metadata-and-library.md](<docs/specs/05-metadata-and-library.md>) | Scraping, matching, artwork, watch state, organization |
| [docs/specs/06-ui-ux.md](<docs/specs/06-ui-ux.md>) | 10-foot UI, screens, accessibility |
| [docs/specs/07-sync-and-casting.md](<docs/specs/07-sync-and-casting.md>) | CloudKit sync, AirPlay, Google Cast |
| [docs/specs/08-business-model.md](<docs/specs/08-business-model.md>) | Free vs Pro, StoreKit, entitlements |
| [docs/specs/09-non-functional-requirements.md](<docs/specs/09-non-functional-requirements.md>) | Performance, power, security, privacy, i18n, reliability |
| [docs/specs/10-roadmap.md](<docs/specs/10-roadmap.md>) | Phased delivery plan |
| [docs/specs/11-media-database.md](<docs/specs/11-media-database.md>) | Media database schema: provider-keyed movies/shows, files, cast & crew, watch state, sync boundary |
| [docs/specs/appendix-a-infuse-reference.md](<docs/specs/appendix-a-infuse-reference.md>) | Infuse reference specs (extracted from firecore.com) |
| [docs/design/README.md](<docs/design/README.md>) | Design index (implementation how; specs are the what) |
| [docs/design/01-media-database.md](<docs/design/01-media-database.md>) | Media database design: on-device storage, full DDL, concurrency, migrations, recovery, query catalog, tests |
| [docs/IMPLEMENTATION_PLAN.md](<docs/IMPLEMENTATION_PLAN.md>) | Master Implementation Plan & Agent Tracking System |

## Status

**Phase 1 (MVP Alpha) is complete.** `CoreKit`, `CapKit`, `LibraryCore`, `MetadataKit`, `SourceAdapters`, and `PlaybackKit` are complete and verified. `PlaybackKit` covers stream probing, sink negotiation, the R1–R5 pipeline ladder, the Metal tone mapper, fMP4 remux/transcode, audio passthrough/downmix, and SRT/WebVTT/ASS/PGS subtitle rendering, plus playback session coordination with drift correction and watch-state flushing, and the honest quality-badge view model with its technical drill-down. The tvOS app has its 10-foot design system and focus foundation, the first-launch onboarding flow that saves the sink profile and connects the first source with live scan counts, a Home screen with reorderable Continue Watching, Recently Added, and per-library shelves, virtualized library grid/list views with sort, density, watched indicators, and 4K/DoVi/Atmos badges, the filter bar that saves and recalls Smart Libraries, rich movie/show detail screens with cast, tracks, season/episode progress, and next-unwatched playback, the auto-hiding player overlay with chapter navigation, track menus, and debounced scrubbing, the honest quality badge with its pipeline detail sheet and per-source/codec path lock, the settings screen with source management, playback preferences, artwork-cache maintenance, and the "About This Apple TV" capability sheet, instant local search and the Fix Matching workflow for unmatched files, and redacted diagnostics export with the playback error-recovery card. The Phase 1 alpha conformance gate now runs real H.264/HEVC/HDR/HLG/AC-3/E-AC-3 mini-assets plus recorded Dolby Vision and Atmos probes, asserting the 2-second startup budget, rung selection, and badge accuracy. For detailed progress, workstreams, and tasks, consult [docs/IMPLEMENTATION_PLAN.md](<docs/IMPLEMENTATION_PLAN.md>).
