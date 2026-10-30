# Appendix A · Infuse Reference

Extracted **2026-10-27** from [firecore.com/infuse](https://firecore.com/infuse)
(the single canonical feature/spec page; sub-pages 404). This is the parity
floor cited throughout the spec set. Firecore's live product also spans
iOS/iPadOS/macOS/visionOS — we match features, and deliberately differ on
platform focus (**tvOS, Apple TV 4K only** — PRD D-2) and on the free/Pro
split (Decision D-1, doc 01/08).

## 1. Product claims (landing page, verbatim summaries)

| Area | Claim |
|---|---|
| Positioning | "A player that plays it all." Bridges the media collection and every Apple device; "stunning organization, effortless streaming, playback that just works" |
| Library | Automatically fetches rich metadata, artwork, cast info, ratings, trailers "from any source" — local files, NAS, or cloud drive; "everything looks like it belongs in the App Store". Powered by **TMDB**; keeps library fresh as new seasons air. Filter by **genre, rating, resolution, watched status**; pin favorites; custom **collections and playlists** |
| Playback | Handles **MKV, MP4, ISO, VIDEO_TS, BDMV** without transcoding; hardware-accelerated decoding on Apple Silicon; "Full **Dolby Vision (Profile 5 & 8), HDR10, HDR10+, and HLG** support on compatible hardware. **Dolby Atmos (E-AC3) passthrough** available when connected to a compatible receiver. Intelligent buffering keeps playback smooth even on slower connections" |
| Streaming | "No server required": Mac/PC/NAS over **SMB, NFS, FTP, WebDAV**, or **Emby, Jellyfin, Plex**; cloud: **Dropbox, Google Drive, OneDrive, Box, more** "without downloading a single file" |
| Pro | "4K Dolby Vision to lossless audio and unlimited sources"; iCloud sync of library/watched/in-progress; AirPlay & Google Cast with surround sound and subtitles |

## 2. Pro feature list (verbatim) & pricing

> **$1.99 / month · $16.99 / year · $99.99 / lifetime** — free 7-day trial,
> cancel anytime.

| Pro feature (verbatim) |
|---|
| **Additional video formats** — "even more video formats and save yourself from hours and hours of file conversions" |
| **Lossless HD audio** — "studio-quality sound with support for lossless 24-bit HD audio" |
| **AirPlay & Google Cast** — "stream videos to the big screen with surround sound and subtitles" |
| **Dolby Vision and Atmos** — "Dolby Vision (Profile 5 & 8) and Dolby Atmos (E-AC3)" |
| **Trailers** — "high-quality video trailers for movies and TV shows" |
| **Advanced library sync** — "libraries, playback progress, and watched history in sync with other devices using iCloud" |
| **Cloud streaming** — "Dropbox, Google Drive, OneDrive, Box, pCloud, Yandex.Disk, MEGA, Aliyun Drive, and more" |
| **Updates for life** — "all future updates — even major releases like v9, v10, and beyond" |

## 3. Technical specifications (verbatim table)

| Category | Formats |
|---|---|
| **Video** | 3GP, ASF, AV1, AVI, BDMV, DivX, DVDMEDIA, DVR-MS, FLV, H.264 (AVC), H.265 (HEVC), H.266 (VVC), ISO/IMG, M4V, MKV, MOV, MP4, MPEG-1/MPEG-2, MTS/M2TS, MXF, OGM, OGV, RMVB, STRM, STRMLNK, TS, VC-1, VIDEO_TS, VOB, VP8, VP9, WebM, WMV, WTV |
| **Audio** | AAC, AIFF, Dolby Digital (AC3), Dolby Digital Plus (E-AC3), Dolby TrueHD, DTS, DTS-HD MA, FLAC, MP3, Ogg, PCM, TTA, WAV, WMA |
| **Subtitles** | DVB, DVDSub, MicroDVD, MPL2, PGS, SMI, SRT, SSA/ASS, SUB, SUP, Timed Text, TMP, TXT, VobSub, VTT, XSUB |
| **Network protocols** | SMB, NFS, FTP, FTPES, FTPS, SFTP, HTTP/HTTPS, UPnP/DLNA, WebDAV |
| **Media servers** | Emby, Jellyfin, Plex |
| **Cloud services** | Dropbox, Google Drive, OneDrive, Box, pCloud, Yandex.Disk, MEGA, Aliyun Drive, 123 Drive, 115 Drive, Baidu NetDisk, GuangYaPan |
| **Requirements** | iOS 18+, iPadOS 18+, **tvOS 18.5+**, macOS 15+, visionOS 26+ |

> Note: Infuse's own floor is tvOS 18.5. We floor at **tvOS 18.0** and scope
> the app to the **Apple TV 4K line only** (gen 2–4, PRD D-2, doc 09 NFR-19)
> — the capability matrix, not the OS floor, is what gates feature breadth.

## 4. Mapping to PlayItRight documents

| Infuse area | Where we spec it | Delta |
|---|---|---|
| Video/audio/subtitle matrices | 04 §2 | identical floor; we add the *how* (HW vs SW rung per codec) Infuse doesn't document |
| Media servers | 03 §2 | same three; we add explicit per-adapter behavior (freshness, watch-state, transcode policy) |
| Network + cloud + local | 03 §3–5 | same list; cloud split into P0/P1; local is P1 (tvOS file-API reality) |
| "Plays MKV/ISO/BDMV without transcoding" | 04 §4 (R2 remux), PB-3 | we say precisely what "without transcoding" means per container |
| DoVi 5 & 8 / HDR10 / HDR10+ / HLG | 04 §5, §7 | we add **Profile 8.1** (gen-4 Apple TV), the full display×content matrix, and tone-map semantics; **free tier** (D-1) |
| Atmos E-AC3 passthrough | 04 §6 | we add declared-sink negotiation + auto-fallback on silence, DTS/TrueHD SW decode + named downmix presets |
| TMDB metadata, filters, collections, playlists, pins | 05 §1, §4 | + OMdb/TVDB/NFO ladder, matching-review UX, FTS search |
| iCloud sync | 07 §1 | + explicit never-sync list, merge rules, offline queue, free-tier migration |
| AirPlay & Google Cast | 07 §2–3 | + sink-profile feedback loop into the pipeline planner |
| Pro gating | 08 | **inverted** on HDR/Atmos (free) per D-1 |
| (not stated by Infuse) | 04 §4 PB-5, 02 ARCH-5 | pipeline transparency: quality badge + plan sheet |

## 5. Apple hardware sources used for the capability matrix (doc 04 §5)

| Source | Used for |
|---|---|
| Apple's Apple TV 4K tech-spec pages, 3rd-gen vs 4th-gen comparison via [The Mac Observer, 2026-10-14](https://www.macobserver.com/news/apple-tv-4k-av1-dolby-vision-profile-8-1/) | gen 3: AVC/HEVC/H.264/MPEG-4, DoVi Profile 5, HDR10+/HDR10/HLG, HDMI 2.1, Wi-Fi 6. **gen 4: AV1 (dedicated A19 decoder), VP9, H.265/HEVC, H.264/AVC, MPEG-4, Dolby Vision Profile 8.1 + 5, HDR10/HDR10+/HLG, HDMI 2.1, Wi-Fi 7, built-in Ethernet** |
| Apple press: "A19 chip also includes a new, dedicated AV1 decoder" (via [streamingmeme](https://www.streamingmeme.com/articles/apple-tv-4k-fourth-generation-adds-a19-chip-and-av1-decoding), [9to5mac](https://9to5mac.com/2026/10/13/new-apple-tv-4k-vs-previous-model-heres-everything-new/), [FlatpanelsHD](https://www.flatpanelshd.com/news.php?sub)) | AV1 HW decode = gen 4 only; $299; no 4K120 (HDMI 2.1 present but 60 fps max) |
| [Apple Support 102218](https://support.apple.com/en-us/102218) (Atmos/surround on Apple TV 4K) | system auto-selects highest supported audio; manual re-encode to Dolby Digital 5.1; Atmos via TV/soundbar/receiver/HomePod; Continuous Audio (Dolby MAT) |
| Apple hardware video support docs (per-device) | H.264/HEVC baseline per model; ★ cells pending Phase 0 probe (S1) |

**Known gaps we must close in Phase 0 (S1):** display-capability introspection
API on tvOS; Apple's exact per-model *app-level* AVFoundation decode/encode
support (Apple lists formats for its own apps, not third-party APIs); DoVi
compositing behavior per display class; audio passthrough semantics for
DTS/TrueHD via AVPlayer.
