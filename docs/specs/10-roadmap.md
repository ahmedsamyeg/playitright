# 10 · Roadmap

Delivery in five phases. Every phase has **exit criteria** — the next phase
starts when they're met, not when the calendar says so.

## Phase 0 — De-risking spikes (4–6 wks, no user-visible product)

The spec's **[verify]** items are all Apple-platform questions. Resolve them
with small throwaway harnesses on **real Apple TV 4K hardware (lab bench:
gen 4, gen 3, gen 2)**:

| Spike | Question | Exit criterion |
|---|---|---|
| **S1 Playback core** | Can AVPlayer/ASBDL drive a remuxed MKV? Does the system tone-map HEVC-HDR→SDR on an SDR display as expected? What composite `CMFormatDescription` does the app observe per display? DoVi P8-on-SDR behavior? Can we read the display's DoVi support? | Doc 04 §3/§5 **[verify]** cells filled with measured answers; 4K DoVi MKV plays on a SDR TV via at least one clean path |
| **S2 File protocols** | Pure-Swift SMB2 + NFS + SFTP clients: feasibility, perf (sustained read ≥ NIC speed on LAN), licensing | A 4K file streams over SMB and NFS at > 100 MB/s with seek |
| **S3 FFmpeg** | Reproducible LGPL dylib (XCFramework, tvOS) with the needed decoders (AV1, VP8/9, VVC, VC-1, DTS, TrueHD, dolbyvision, zscale/tonemap); license audit passes; openh264 for SW H.264 encode | Conformance-mini suite (20 assets) plays via FFmpeg path on all supported box types (gen 2–4); CI license gate green |
| **S4 Server adapters** | Plex token/2FA/pairing flows on a TV (no keyboard), Jellyfin/Emby REST + ETags, watch-state write endpoints | Connect→enumerate→play→report-watch works against all three, self-hosted, over LAN + Tailscale |
| **S5 Sync** | CloudKit record model + merge rules at scale (10 k watchStates), rate envelopes, conflict UI | 1 M-item library syncs < 30 s first time; delta sync < 3 s; kill-switch tests pass |

**Gate:** capability matrix (doc 04 §5.2) fully measured; S1–S3 green.

## Phase 1 — MVP alpha (10–12 wks after Phase 0)

- Library core + **media database** (schema, migrations, FTS, provider-id keys, people/credits — doc 11) + TMDB/OMDb/TVDB metadata + artwork pipeline
- Sources: **Plex, Jellyfin, Emby, SMB, NFS, WebDAV, HTTP** (file-share trio is the long pole)
- Playback: rungs R1–R4 for the **free-tier codec set** (H.264/HEVC) with **full HDR/DoVi handling** (the PRD thesis), audio: AAC/AC3/EAC3/PCM + Atmos downmix
- UI: onboarding, Home, library (grid/list/detail), player with badge, core settings
- Diagnostics + capability sheet

**Exit:** a collector persona's 4K DoVi/Atmos MKV NAS plays end-to-end (direct or honest transcode) on every supported box type (gen 2–4); 10 k-item library browses at budget; conformance suite ≥ 80% green.

## Phase 2 — Public beta (8–10 wks)

- Pro tier: full codec matrix (AV1/VP8/9/VVC/MPEG-2/VC-1/WMV/DivX), DTS/TrueHD/lossless-24-bit
- Remaining sources: FTP/FTPS/SFTP, UPnP, cloud drives (GDrive/Dropbox/OneDrive/Box), disc images (ISO/BDMV/VIDEO_TS)
- Sync (CloudKit) + AirPlay + Google Cast
- Long-tail subtitles, playlists/collections, search (TMDB browse), theming
- StoreKit 2, trial, beta via TestFlight (tvOS beta program)

**Exit:** conformance suite 100% green on supported matrix; beta crash-free ≥ 99.5%; ≥ 500 beta households; D-1 (free HDR/Atmos) decision validated by conversion data.

## Phase 3 — v1.0 launch + companion (6–8 wks)

- App Store release (tvOS 18+, **Apple TV 4K only**), App Privacy "Data Not Collected"
- iOS/iPadOS companion build from the shared core (AirPlay-to-Apple-TV, phone resume → TV resume)
- Localization pass (5 locales), accessibility final gate

**Exit:** public launch; KPIs in doc 01 §6 tracked live.

## Phase 4 — v1.x (continuous)

- macOS + visionOS builds · HDR10+ DVM processing · DoVi→DoVi profile remap
  (ffmpeg, P2 cell in doc 04 §7) · 21:9 anamorphic · subtitle provider
  downloads · per-episode stills · "More like this" · remote rebinding ·
  4K120 path if Apple ever ships it.

## Standing workstreams

| Stream | Cadence |
|---|---|
| Conformance suite (NFR-25) on device lab | every PR touching PlaybackKit; nightly full matrix |
| Capability matrix maintenance (PB-9) | per new Apple hardware, same release |
| License audit (ARCH-6) | every build (CI) |
| Source-adapter protocol drift (Plex/Jellyfin/Emby API changes) | quarterly compatibility review |
