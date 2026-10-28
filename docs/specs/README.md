# PlayItRight — Specification

**Status:** DRAFT v0.1 · 2026-10-27
**Primary platform:** tvOS — **Apple TV 4K only** (gen 2–4, tvOS 18+) · **Scope:** complete alternative to Infuse

This folder is the source of truth for what PlayItRight is and does. Each
document covers one domain; requirement IDs in `DOMAIN-NNN` form are unique
across the whole set and are referenced by the roadmap and (later) the issue
tracker.

## Document map

| # | Document | Domain |
|---|---|---|
| 01 | [Product overview](01-product-overview.md) | Vision, personas, pillars, tiering, KPIs |
| 02 | [Architecture](02-architecture.md) | Modules, tech stack, data flows, build/licensing |
| 03 | [Media sources](03-media-sources.md) | Plex, Jellyfin, Emby, file shares, cloud, local |
| 04 | [Playback engine](04-playback-engine.md) | Formats, capability matrix, pipeline planner, HDR/audio, subtitles |
| 05 | [Metadata & library](05-metadata-and-library.md) | Scraping, matching, artwork, watch state, organization |
| 06 | [UI/UX](06-ui-ux.md) | 10-foot design, screens, accessibility |
| 07 | [Sync & casting](07-sync-and-casting.md) | CloudKit, AirPlay, Google Cast |
| 08 | [Business model](08-business-model.md) | Free/Pro, StoreKit 2, entitlements |
| 09 | [Non-functional requirements](09-non-functional-requirements.md) | Perf, power, security, privacy, i18n, compatibility |
| 10 | [Roadmap](10-roadmap.md) | Phases, milestones, exit criteria |
| 11 | [Media database](11-media-database.md) | SQLite schema: provider-keyed media, files, cast & crew, state, sync boundary |
| A | [Infuse reference](appendix-a-infuse-reference.md) | Competitor specs extracted from firecore.com |

## How to read

- **Requirement IDs.** `PB-014` = playback engine, requirement 14. `SRC-`,
  `MD-`, `UI-`, `SYNC-`, `BIZ-`, `NFR-`, `ARCH-`, `PRD-`, `DB-` follow the same
  pattern. Every ID carries a priority:
  - **P0** — must ship in v1.0 (App Store release)
  - **P1** — planned for v1.x
  - **P2** — backlog / future
- **Verification flags.** Where a behavior depends on Apple platform
  capabilities that are not publicly documented (or are model-specific), the
  requirement is marked **[verify]**. Phase 0 spikes (see roadmap) resolve all
  **[verify]** items into the capability database (doc 04, §5) before they are
  scheduled as P0. The one governing rule behind the matrix: **Apple hardware
  acceleration for every format the model supports; bundled software
  (FFmpeg) only where the hardware does not** (ARCH-P6, doc 02).
- **Infuse parity.** Where a requirement exists to match Infuse's documented
  behavior, it cites the [reference appendix](appendix-a-infuse-reference.md).
  Parity is a floor, not a ceiling: our differentiators are the transparent
  playback pipeline and local-first privacy.

## Glossary

| Term | Meaning |
|---|---|
| **Source** | A configured place media comes from (a Plex server, an SMB share, a cloud drive, local files…) |
| **Library** | A user-visible collection of items belonging to one source or a curated combination |
| **Item** | A playable asset (movie, episode, audio file) plus its metadata |
| **Pipeline** | The concrete decode→transform→encode→output path chosen for one playback |
| **Direct play** | No re-encoding: bits from the source are demuxed and decoded natively |
| **Remux** | Demux + repack into an Apple-friendly container, no re-encode |
| **Transcode** | Re-encode video and/or audio (hardware- or software-backed) |
| **Tone map** | HDR→SDR luminance mapping (PQ/HLG → BT.1886/sRGB) |
| **DoVi** | Dolby Vision; Profile 5 (pure DoVi HEVC), 8 (HEVC base + RPU), 8.1 (per Apple 4th-gen Apple TV) |
| **RPU** | Dolby Vision's dynamic-metadata (Pulse) data |
| **Sink** | The final output (TV panel via HDMI, receiver, AirPlay endpoint, Cast device) |
| **Capability matrix** | Per-device table of what the hardware can do; maintained as data + runtime-verified |
| **Canonical media id** | The provider id that *is* the primary key of a matched title (TMDB for movies, TMDB-or-TVDB for shows) — doc 11 |
| **Entity** | Schema referent: a matched movie/show/episode (canonical id) or a person; files are a separate `media_files` entity |

## Conventions

- **Supported fleet = Apple TV 4K only**: gen 2 (2021, A12Z), gen 3 (2022, A15),
  gen 4 (2026, A19) — see Decision D-2 in doc 01. Gen 1 (2017, A10X) and all
  1080p "Apple TV HD" models are out of scope. Capability matrix: doc 04 §5.
- **Identity.** Matched media is keyed by provider identity (TMDB / TVDB ids —
  Decision D-3 in doc 01); files are a separate table that references matched
  media (doc 11). Organization and watch state reference canonical ids, never
  paths.
- All clocks are UTC; all resolutions use `WxH`.
- "HDR" without qualification means HDR10 (static metadata, BT.2020, PQ).
