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

Phase 1 (MVP Alpha) implementation in progress. `LibraryCore` on-device SQLite database engine, migrations, FTS5 search, reader, and writer are implemented and verified. For detailed progress, workstreams, and tasks, consult [docs/IMPLEMENTATION_PLAN.md](<docs/IMPLEMENTATION_PLAN.md>).
