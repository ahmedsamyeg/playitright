# 02 · Architecture

## 1. Design principles

| # | Principle | Consequence |
|---|---|---|
| ARCH-P1 | **Capability-driven, not feature-coded** | No `if #available` sprawl for fidelity features. One **CapabilityRegistry** (doc 04 §5) answers "can this box do X?"; UI/pipeline code asks it. New Apple TV 4K hardware = data update. |
| ARCH-P2 | **Platform-neutral core** | All heavy lifting (demux, metadata, library index, sync engine, pipeline planner) is a set of SPM packages that build on tvOS *and* iOS/macOS. Only the app shell and platform adapters are platform-specific. |
| ARCH-P3 | **Plugin source adapters** | Media sources implement a `SourceAdapter` protocol (doc 03 §1). Adding a source must not touch library or playback code. |
| ARCH-P4 | **Local-first** | The on-device SQLite index is the runtime source of truth. Servers/cloude provide truth *into* the index; playback and browsing work offline from it. |
| ARCH-P5 | **Honest pipeline** | Every playback session carries a `PipelinePlan` object (doc 04 §4) that the UI renders and the user can override/lock. |
| ARCH-P6 | **Apple hardware acceleration first** | For every supported format, every pipeline stage (decode, color, audio, encode) defaults to **Apple hardware acceleration** on Apple silicon (VideoToolbox, system HDR compositing, native audio I/O). The bundled software path (FFmpeg / openh264) engages **only** for (format × operation) pairs this Apple TV 4K model does not support in hardware, or when a user explicitly locks a path. **Software is the fallback rung, never the default** (PB-G2, doc 04). |
| ARCH-P7 | **Graceful degradation** | Every transformation (decode, color, audio) has a hardware path *and* a software path; the planner picks by cost. Nothing is a dead end. |
| ARCH-P8 | **Boring reliability** | Swift, AVFoundation, VideoToolbox, Metal, CloudKit, StoreKit 2. Exotic tech only where Apple provides none (demux of non-Apple containers, some decoders) — i.e., a single LGPL FFmpeg module. |

## 2. Module map

```
┌────────────────────────────────────────────────────────────────────────┐
│                        PlayItRight App (tvOS shell)                    │
│  Onboarding · Library UI · Player UI · Settings · Subscription         │
└───────────────┬────────────────────────────────────────────────────────┘
                │
┌───────────────▼────────────────────────────────────────────────────────┐
│  PlaybackKit          PipelinePlanner ── CapabilityRegistry            │
│  ┌──────────────┐    ┌──────────────┐     ┌───────────────────┐        │
│  │ Source I/O   │───▶│ MediaGraph   │────▶│ RenderGraph:      │        │
│  │ (demux/IO)   │    │ (tracks,     │     │  Decode (VT|FF)   │        │
│  │ AVAsset|FF   │    │  chapters,   │     │  Color (CI/Metal) │        │
│  │              │    │  subs, tone) │     │  Audio (AU|FF)    │        │
│  └──────┬───────┘    └──────┬───────┘     │  Encode (VT|FF)   │        │
│         │                   │             │  Output (AVPlayer │        │
│         │                   │             │   | ASBDL | pipe) │        │
│         │                   │             └───────────────────┘        │
│         │                   │                  ▲                        │
│         │           ┌───────▼───────┐          │                        │
│         └──────────▶│ SyncKit       │──────────┘  (remote transcode)    │
│                     │ (CloudKit,    │                                  │
│                     │  deltas, CRDT)│                                  │
│                     └───────┬───────┘                                  │
└─────────────────────────────┼──────────────────────────────────────────┘
                              │
┌─────────────────────────────▼──────────────────────────────────────────┐
│  LibraryCore      SourceAdapters (protocol)                            │
│  SQLite index ──  Plex · Jellyfin · Emby · SMB · NFS · WebDAV ·        │
│  (GRDB, FTS5)     FTP/S · HTTP · UPnP · Cloud* · Local                 │
│        ▲          *cloud = Pro tier, OAuth adapters                     │
│        │                                                                   │
│  MetadataKit  TMDB · OMDB · TVDB · NFO · filename matcher · artwork CDN │
└─────────────────────────────────────────────────────────────────────────┘
Shared: CoreKit (DI, logging, Keychain, entitlements, i18n) · CapKit (probes)
LibraryCore's SQLite store is the media database — full schema, identity rules,
sync boundary: [11 · Media database](11-media-database.md)
```

## 3. Tech stack

| Layer | Choice | Rationale / notes |
|---|---|---|
| UI | SwiftUI + minimal UIKit interop | 10-foot layout, focus system; UIKit only where tvOS APIs demand it (e.g., document browser) |
| Player surface | AVKit `AVPlayerViewController` for direct play; `AVSampleBufferDisplayLayer` + `AVPlayerItemVideoOutput`-style render loop for transcoded pipelines | Direct play stays on Apple's most-optimized path; transcoded frames need the transform graph in between |
| Native media | AVFoundation, VideoToolbox, Core Image + Metal, AudioToolbox (`AVAudioEngine`/`AUAudioUnit`) | Decode/encode/color-mix in hardware |
| Non-Apple media | **FFmpeg (LGPL build), shipped as a dynamic library** inside an XCFramework | Demux MKV/AVI/WebM/OGG/FLV/MXF/…; decode codecs the Apple TV 4K lacks in hardware (AV1/VP9 on gen 2/3 — gen 4 decodes AV1+VP9 in HW; VVC, VC-1, WMV, DTS, DTS-HD, TrueHD, TTA, WMA…; per ARCH-P6); audio downmix; `zscale`/`tonemap` color ops. **Must be LGPL-only** (no `--enable-gpl`): see §5 licensing. x264 (GPL) excluded from App Store build; software H.264 encode uses **openh264** (BSD) or is avoided in favor of VideoToolbox. |
| Index/database | SQLite via **GRDB** (FTS5 full-text search, WAL) | Single file in app container; survives across launches. Schema (tables, provider-id primary keys, migrations): doc 11 |
| Artwork/data cache | On-disk HTTP cache (URLCache-style, LRU, size-capped) + TMDB images | 4K-backdrop-sized assets |
| Sync | CloudKit (`CKSyncEngine` pattern: record-zone deltas, optimistic concurrency) | tvOS-native, Apple accounts already trusted by users |
| File protocols | SMB: in-process client (Samba-derived, permissive-licensed fork or `smb2` Swift impl) **[verify]**; NFS: in-process NFSv3/v4 client (e.g., swift-nfs or C port) **[verify]**; WebDAV: URLSession (HTTP); FTP/FTPS/SFTP: URLSession (TLS/SSH via in-process SFTP, e.g., libssh2 fork) **[verify]** | tvOS gives apps no filesystem mount capability — all in-process |
| Discovery | UPnP/DLNA via SSDP (multicast HTTP) + SOAP A-V 1.0 | Standard, in-process |
| Diagnostics | Structured in-memory ring-buffer logs + opt-in export (file download via "Files"); opt-in crash reports | NFR-6 |
| Min OS / hardware | **tvOS 18.0** · **Apple TV 4K only**: gen 2 (2021, A12Z) **[verify tvOS 18 support]**, gen 3 (2022, A15), gen 4 (2026, A19) | 4K product line only (PRD D-2, doc 01). 1080p HD boxes and the 2017 gen 1 box get a first-launch rejection screen; feature breadth gates on the capability matrix, never on model strings in UI code |

## 4. Key data flows

### 4.1 Library build (source → index → UI)

```
SourceAdapter.connect (auth)
  → enumerate items (server API  |  directory walk  |  UPnP browse)
  → for each file: build Item (id = source+path, container sniff, streams probe)
  → MetadataKit.match (server-provided md  >  local NFO  >  filename  >  TMDB search)
  → write index (doc 11: media_files, tracks, matched media, people/credits,
    identifiers, state) + queue artwork download
  → notify UI (Combine/AsyncStream of index changes)
Freshness: webhooks (Plex) / ETag polling (Jellyfin/Emby) / re-scan schedules
```

### 4.2 Playback (item → pixels)

```
Item + SinkCapabilities (display, audio, resolution)
  → MediaGraph (demux probe: containers, codecs, color, HDR, DTS/DoVi, subs)
  → CapabilityRegistry (this Apple TV, this tvOS, this display)
  → PipelinePlanner → PipelinePlan {decode, color, audio, encode, output}
  → RenderGraph runs; emits QualityBadge to UI; honors user override/lock
  → WatchState writer (progress, resume, watched) → SyncKit (if opted in)
```

Full semantics: [04 · Playback engine](04-playback-engine.md).

### 4.3 Sync

```
local index changes ─▶ SyncEngine ─▶ CloudKit zone (records w/ timestamps)
remote changes   ◀─ delta pull ── merge rules (per-field last-writer-wins,
                                 progress = max(resume ts) + conflict UI)
```

Secrets (API keys, share passwords) **never** sync. [07 · Sync & casting](07-sync-and-casting.md)

## 5. Build & licensing

| Component | License | Delivery |
|---|---|---|
| App + SPM packages | Proprietary | static into app |
| FFmpeg | LGPL 2.1+ (config: `--enable-nonfree` **off**, `--enable-gpl` **off**) | dynamically linked `.dylib` inside the app (LGPL §6 compliant); source available for binary users |
| openh264 | BSD (+ Cisco patent grant) | static |
| Samba-derived SMB client / libssh2 / NFS | GPL-licensed upstreams are **not** statically linkable: use permissive forks (libcsmb? — no, Samba is GPLv3) → **preferred: pure-Swift SMB2 and SFTP clients** so no GPL linkage **[verify feasibility in Phase 0 spike S2]** | static |

> **Licensing rule (tracked as ARCH-6 / ARCH-7 in §7):** nothing GPL is statically linked. Dynamic
> linking of a GPL library is permissible for App Store distribution but
> avoided where a permissive/pure-Swift implementation exists. LGPL dylibs
> are fine. CI runs a license audit (e.g., `swift package` SBOM +
> license-check) on every build.

## 6. Runtime model

- **Queues:** demux I/O (concurrent, network-aware), decode (VideoToolbox
  hardware queues / FFmpeg worker pool, CPU-budgeted), color (Metal command
  queue), audio render (real-time audio thread — never blocks on network),
  index (serial writer), UI (main).
- **Thermal:** `ProcessInfo.thermalState` observed continuously; at
  `.serious/.critical` the planner drops one rung (4K→1080p encode, 10-bit→8-bit,
  reduce SW decode to 8-bit) per [NFR-2](09-non-functional-requirements.md).
- **Background:** audio session activation for audio-only gaps; `BGAppRefreshTask`
  for library freshness while foregrounded-adjacent; app suspends fully on idle.
- **Memory:** hard budget for the render graph (doc 09); grids are virtualized.

## 7. Architecture requirements

| ID | Requirement | Priority |
|---|---|---|
| ARCH-1 | CapabilityRegistry is the single authority for hardware features; no feature code may inspect `UIDevice` model strings directly (Apple TV 4K gen 2–4 only) | P0 |
| ARCH-2 | All source integrations implement `SourceAdapter`; library & playback code is source-agnostic | P0 |
| ARCH-3 | Library index is a local SQLite DB (GRDB, FTS5) — the runtime truth for browsing/playback; works fully offline after first sync. Schema is versioned per doc 11 (DB-1) | P0 |
| ARCH-4 | Every playback emits a serializable `PipelinePlan` consumed by UI (badge), diagnostics, and analytics-free logs | P0 |
| ARCH-5 | FFmpeg is a single LGPL dynamic library; build is reproducible (pinned commit, config script, checksums) | P0 |
| ARCH-6 | No GPL static linkage; CI license gate | P0 |
| ARCH-7 | Platform-neutral packages: playback core, library core, sync engine build for tvOS + iOS + macOS (tvOS is the only one *shipped* in v1) | P1 |
| ARCH-8 | Secrets stored in Keychain; never written to sync payloads, logs, or the SQLite index | P0 |
| ARCH-9 | Diagnostics: bounded ring-buffer logs + user-exportable report; crash reporting strictly opt-in | P0 |
| ARCH-10 | New Apple TV 4K model = capability data update + CI conformance pass, no code change | P1 |
