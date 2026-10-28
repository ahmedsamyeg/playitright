# 01 · Product Overview

## 1. Vision

PlayItRight is a complete Apple tvOS video player and media library app: the
definitive way to watch personal media on Apple TV. It plays every format a
private library contains, organizes it as beautifully as a streaming service,
and never makes the user choose between convenience and fidelity.

Where Infuse quietly hides what it does, PlayItRight shows the work: every
playback displays an honest quality badge (direct / hardware-transcoded /
software-transcoded) and a one-tap pipeline breakdown, and users can pin
quality preferences per source, per codec, and per output.

## 2. Positioning

- **Reference competitor:** Infuse by Firecore
  ([firecore.com/infuse](https://firecore.com/infuse); full reference in
  [appendix A](appendix-a-infuse-reference.md)).
- **Primary platform:** **Apple TV 4K only** (Decision D-2 below): gen 2
  (2021, A12Z), gen 3 (2022, A15), gen 4 (2026, A19); tvOS 18+. 1080p
  "Apple TV HD" models and the 2017 gen 1 box are out of hardware scope —
  the app detects them at first launch and shows a clear "PlayItRight
  requires Apple TV 4K" screen. The core is platform-neutral; iOS/iPadOS/
  macOS/visionOS builds are a Phase 3+ extension, not a v1 requirement.
- **Category:** "Plays it all" private-media player — the answer to
  "why does my 4K Dolby Vision MKV stutter on my TV?"

### Differentiators vs Infuse

| # | Differentiator |
|---|---|
| PRD-D1 | **Transparent pipeline** — visible quality badge + pipeline explanation; per-rule user overrides (quality vs CPU/heat) |
| PRD-D2 | **Local-first privacy** — no telemetry by default, all library data on-device, sync only what the user opts into; source credentials never leave the device |
| PRD-D3 | **Capability-aware** — a maintained, runtime-verified Apple hardware capability matrix drives every decision, so new Apple TV generations get full fidelity on day one without guessing |
| PRD-D4 | **Honest fallbacks** — when software transcoding is the only option, the app says so and offers quality/bandwidth tradeoffs explicitly |

> **Decision D-2 (stakeholder-confirmed 2026-10-27):** the app is scoped to
> the **Apple TV 4K** product line only. Floor = gen 2 (2021) / tvOS 18,
> matching Infuse's own 18-class floor and Apple's current support cycle. The
> 2017 box (A10X) tops out at tvOS 15 **[verify]**, so it cannot meet the
> floor. If the A12Z (gen 2) turns out not to support tvOS 18 **[verify]**,
> the floor tightens to gen 3. No 1080p HD support, ever, in v1.

> **Decision D-3 (stakeholder-directed 2026-10-27):** the media database keys
> matched media by provider identity — **TMDB ids as primary keys for movies,
> TMDB/TVDB ids for TV shows** — with an identifiers crosswalk (TMDB ↔ TVRage
> ↔ IMDB); cast & crew live in dedicated `people` + `credits` tables. Files
> are a separate table that references matched media. Schema: doc 11.

## 3. Personas

| Persona | Needs |
|---|---|
| **Kai, 38 — the collector** | 20 TB NAS of 4K rips (MKV, DoVi P8/P5, Atmos, DTS-HD MKV). Owns Apple TV 4K gen 4 + HDR TV + Atmos receiver. Wants zero-transcode direct play, exact frame pacing, subtitle fidelity. |
| **Rosa, 29 — the casual streamer** | Plex household + a folder of downloaded MP4s. Wants it to "just work", fast library UI, resume where she left off, works on the 10-year-old TV in the bedroom (SDR). |
| **Dan, 52 — the tinkerer** | Runs his own Jellyfin on a mini-PC, mixes sources, cares about codecs, frame rates, audio tracks. Wants per-source settings, HTTP range behavior, debug visibility. |
| **The household** | Multiple Apple TVs / iPhone / iPad in one home; shared watch state, per-member favorites. |

## 4. Feature pillars

| Pillar | Promise | Detailed in |
|---|---|---|
| 1. Play anything | Every format in the [Infuse parity matrix](appendix-a-infuse-reference.md) plays on every supported Apple TV 4K: **Apple hardware acceleration by default; software transcoding only for formats the hardware can't do** (direct → remux → HW transcode → SW transcode, doc 04) | 04 |
| 2. Beautiful library | Auto metadata (TMDB), artwork, cast, ratings, trailers; filters, collections, playlists, pins; "continues watching" — backed by the local media database | 05, 06, 11 |
| 3. Connect everywhere | Plex, Jellyfin, Emby, SMB, NFS, WebDAV, FTP/FTPS/SFTP, HTTP, UPnP/DLNA, cloud drives, local files | 03 |
| 4. Sync & cast | iCloud library + watch-state sync; AirPlay; Google Cast | 07 |
| 5. Private by default | Local-first data, opt-in sync, no tracking | 09 |

## 5. Free vs Pro (summary)

Full tier definition in [08 · Business model](08-business-model.md).

| | Free | Pro (subscription) |
|---|---|---|
| Video codecs | H.264, HEVC (direct + transcode) | + AV1, VP8/VP9, VVC, MPEG-2, VC-1, WMV, DivX, DV… full matrix |
| HDR | HDR10, HLG, DoVi — **all included free** | — |
| Audio | AAC, AC3, E-AC3, PCM | + DTS, DTS-HD, Dolby TrueHD, lossless 24-bit, Atmos downmix |
| Sources | 1 media server or file share; local files | Unlimited sources + all cloud drives |
| Sync & cast | — | iCloud sync, AirPlay, Google Cast |
| Trailers | — | In-app TMDB trailers |
| Updates | Current major only | All updates for the purchase's life (subscription) |

> **Decision D-1 (open):** Infuse gates Dolby Vision/Atmos behind Pro. We
> propose giving all HDR + Atmos playback in Free to position against Infuse,
> and monetizing codec breadth, audio breadth, sync/cast, and cloud.
> Owner to confirm before 08 is finalized.

## 6. Success metrics (first 12 months post-launch)

| KPI | Target |
|---|---|
| App Store rating | ≥ 4.5★, ≥ 300 ratings |
| D30 retention (free) | ≥ 25% |
| Free→Pro conversion | ≥ 4% |
| "Plays first try" (files that start playback without user intervention) | ≥ 98% of supported-format library items |
| Median time-to-first-frame (local 4K HEVC) | < 2 s |
| Playback session survival (no crash/stall > 5 s, network) | ≥ 99% |
| Crash-free rate | ≥ 99.5% sessions |

## 7. Out of scope (v1)

- **Apple TV HD (1080p) models and Apple TV 4K gen 1 (2017, A10X)** — out of hardware scope (D-2); graceful rejection screen, no degraded support.
- Live TV / DVR, radio, podcasts.
- Music and photo libraries (video-only; audio-only files play, without a music UI).
- Multi-seat family sharing of Pro (single Apple ID household sharing only).
- 4K120 output (Apple TV does not do 120 fps even on HDMI 2.1 hardware).
- iOS/macOS/visionOS builds (Phase 3+, architecture allows it).
- Game/piracy-assistance features (no torrent integration, no "search the whole internet" for content).
