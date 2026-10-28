# 03 · Media Sources

Sources are the places media comes from. This document defines the source
abstraction and one adapter per source type, including parity with Infuse's
supported source list ([appendix A](appendix-a-infuse-reference.md)).

## 1. SourceAdapter contract

```swift
protocol SourceAdapter: Sendable {
    var kind: SourceKind { get }                       // .plex, .jellyfin, .emby, .smb, …
    func connect(config: SourceConfig) async throws -> SourceSession   // auth, capability discovery
    func enumerate(session: SourceSession, scope: LibraryScope) async throws -> ItemStream
    func read(session: SourceSession, item: Item, range: ByteRange?) -> AsyncThrowingStream<Data, Error> // ranged stream
    func pushWatchState(session: SourceSession, item: Item, state: WatchState) async throws  // best-effort
    func freshness(session: SourceSession) async throws -> FreshnessInfo  // webhooks | etags | mtime
    func disconnect(session: SourceSession) async
}
```

Rules:

- **SRC-1** Adapters are the *only* code that knows a vendor's wire protocol.
  Library and playback code depend on the protocol only. *(P0)*
- **SRC-2** `read()` must honor byte ranges (HTTP `Range`, SMB read offsets,
  cloud ranged GETs) so the pipeline can seek without re-reading. *(P0)*
- **SRC-3** Credentials: stored in Keychain per source; adapter returns
  structured auth errors (needs re-auth, 2FA challenge, host unreachable). *(P0)*
- **SRC-4** Every adapter exposes a **direct-play preference hint**
  (e.g., Plex: "ask for DirectStream") consumed by the pipeline planner (doc 04). *(P0)*

## 2. Media servers

### 2.1 Plex *(parity: Infuse lists Plex)*

| Concern | Spec |
|---|---|
| Auth | `X-Plex-Token` (server settings token) **and** user-token flow: open device-pairing URL / QR-less link flow on TV; support 2FA app-code entry; remember tokens in Keychain |
| Discovery | Manual host entry + LAN auto-discovery via `plex.direct`/GDM-1 mDNS; TLS with pinned Apple CA (user may self-host HTTP — warn) |
| Enumeration | `GET /library/sections`, `/library/all?X-Plex-Container-Size=-1`; sections → Libraries; agent metadata (movie/episode ids) mapped to items; honor section `type` (movie/episode/artist) — **video sections only** in v1 |
| Freshness | Plex **webhooks** (push) primary; container ETag + periodic poll fallback; "rescan" button triggers server-side scan via `PUT /library/sections/{id}?1=scan` **[verify endpoint]** |
| Streaming | Prefer `DirectStream`/`DirectPlay` via `GET /library/metadata/{id}/stream?...`; if the Plex *server* must transcode (codec our Apple TV can't play natively and remote transcode allowed), use Plex's transcode endpoint; our own transcoding (doc 04) is always preferred over letting the user's server burn CPU unless user chooses "server transcode" |
| Watch state | Report via `/watchHistory` (item-level, account-scoped) **[verify]**; read for cross-device |
| Metadata | Plex agent metadata (TMDB-backed) ingested into index; we still run our own TMDB pass to fill gaps (episode art, similar) |

### 2.2 Jellyfin

| Concern | Spec |
|---|---|
| Auth | `X-Emby-Token` API key (Jellyfin API v1: `POST /Users/{id}/Ping`, `POST /users/{id}`); remember user + token |
| Discovery | Manual host entry; `GET /System/Info/Public` for version/brand check (distinguish Jellyfin from Emby server builds) |
| Enumeration | `GET /Items?Recursive=true&IncludeItemTypes=Movie,Episode&Fields=...` paged; map `MediaSources` → streams; `ParentId` tree for seasons |
| Freshness | ETags on `/Items` + `/Notifications` socket (SSE over `?ApiKey`) for live updates |
| Streaming | `GET /Videos/{id}/stream?Container=...`; direct when codec/container is natively playable; server transcode as fallback (Jellyfin quality preset mapping) |
| Watch state | `POST /Items/{id}/PlayedBy` + positions; read via `/Users/{id}/Items/...` |

### 2.3 Emby

- Same REST surface as Jellyfin (Emby API); version-gated: Emby 4.x and 6.x differ (6.x renamed endpoints, `EstimatePremiereDate`, etc.) — adapter keeps a small version-compat table. *(P0 for 4.x; P1 for 6.x specifics)*
- Emby's **Plex-interop** is irrelevant to us (we're not a Plex client for Emby).

### 2.4 Media-server common requirements

- **SRC-5** Server adapters must work **offline-tolerant**: after first enumeration, full browse/playback from local index; re-sync on reconnect. *(P0)*
- **SRC-6** Watch-state writes are best-effort with retry queue; never block playback. *(P0)*
- **SRC-7** Multiple instances of the same kind supported (two Plex homes, home + work). Free tier = 1 source total (doc 08). *(P0)*
- **SRC-8** Server-side transcoding is a *user-selectable* fallback ("let my server transcode"), never the silent default. *(P0)*

## 3. Network file shares

| Adapter | Protocol details | Notes |
|---|---|---|
| **SMB** *(SMB2/3)* | In-process client: sessions, trees, oplocks off, signing, AES-GCM/CMCC encryption options; credentials per share; UNC + IP entry | tvOS has no SMB API — pure-Swift SMB2 client (Spike S2) **[verify]**; parity with Infuse |
| **NFS** | In-process NFSv3 (and v4 if feasible) client: mount, read/write with `Range` | Pure-Swift or audited C interop (Spike S2) **[verify]** |
| **WebDAV** | `URLSession`: PROPFIND (depth 1/∞), GET with Range, conditional GET (ETag/If-Modified-Since) | Easiest; good default for "it just works" |
| **FTP / FTPES** | In-process FTP client; FTPES = TLS implicit/explicit | Rarely used; P1 |
| **SFTP** | SSH-2 in-process (pure-Swift or libssh2-derived, permissive fork) | P1 |
| **HTTP/HTTPS** | Direct file URLs; supports `.strm` pointing anywhere; Range mandatory | P0 — the "add a single file" path |
| **UPnP/DLNA** | SSDP discovery (`M-SEARCH`), Service A-V 1.0 browse (`Browse` SOAP), transfer via advertised HTTP; render-only role (we're the controller) | P1 — discovery in Settings, full browse P1 |

- **SRC-9** File-protocol adapters expose: enumerate (recursive with include/exclude glob filters), ranged read, last-modified, size, and file-change detection (mtime/ETag) for freshness. *(P0)*
- **SRC-10** Network resiliency: per-request timeouts, exponential backoff, mid-stream reconnect with resume from current offset (never restart a 2-hour movie over a dropped link). *(P0)*
- **SRC-11** Include/exclude: per-source glob filters (e.g., `*.nfo`, `samples/`), case-insensitive; default filters hide common non-media clutter. *(P0)*

## 4. Cloud drives *(Pro tier)*

Parity with Infuse's cloud list ([appendix A](appendix-a-infuse-reference.md)):
Dropbox, Google Drive, OneDrive, Box, pCloud, MEGA, Yandex.Disk, Aliyun Drive,
123 Drive, 115 Drive, Baidu NetDisk, GuangYaPan.

- **SRC-12** Cloud adapters: OAuth 2.0 (device-code flow for TV: show code + URL, poll for token — no keyboard-heavy entry), Keychain token storage, refresh automation. *(P0 for: Google Drive, Dropbox, OneDrive, Box; P1 for the rest)*
- **SRC-13** **Stream without download**: all cloud adapters must support ranged GET; the player plays the object in place. Full-file download is a user option ("download for offline"). *(P0 for the four above)*
- **SRC-14** Quota/size awareness: surface file size; warn (not block) before starting a 4K file over a slow uplink, offering "start in 1080p" pre-buffer. *(P1)*

## 5. Local files

- **SRC-15** "On My Apple TV" storage + iCloud Drive via the tvOS file APIs
  (`UIDocumentBrowserViewController` / `FileManager` URLForSecurityScoped)
  **[verify tvOS availability of document browser; if absent, local = files copied via "Files" share sheet]**. *(P1 — network sources are the primary add-path on TV)*
- **SRC-16** `.strm` and `.strmlnk` files inside any source (local, share, server) are followed: their content is a URL or UNC path that becomes the real stream target. *(P0)*
- **SRC-17** Disk-image playback: `.iso`/`.img` (DVD/Blu-ray images) and `VIDEO_TS` / `BDMV` **folders** mount as a "disc" pseudo-item exposing APE/VOB playlists and (BDMV) title selection. Pseudo-filesystem over the adapter's ranged reads (Spike S1). *(P1 — MKV/MP4 first; disc images are a v1.x item)*

## 6. Library model (shared by all sources)

```
Source(1) ──< Library(1) ──< Item(1) ──< Track(stream: video|audio|subtitle|chapter)
Item: stableId = hash(sourceId, providerId|path)   // survives renames when provider id exists
     container, resolution, duration, fps, size, mtime, location(URI)
     metadata ref, watchState(s) per account, artwork refs, collection memberships
```

- **SRC-18** One source may expose multiple libraries (Plex sections, root folders per user-defined library); the UI can group sources into user-defined Libraries ("All", per-source, mixed). *(P0)*
- **SRC-19** Identity & renames: when a file moves, rename detection (same size + duration + provider id or content hash of header) preserves watch state and artwork; ambiguous cases surface in a "changes" list. *(P0)*
- **SRC-20** Freshness engine: per-source strategy (webhook > push socket > ETag poll > mtime walk), with user-controllable interval and a manual "check for updates". *(P0)*
- **SRC-21** Add-source UX must cover, per kind: host/credential entry, connection test with human-readable failure ("2FA required — enter 6-digit code"), first-enum progress, and a library-naming step. *(P0)*

## 7. Coverage vs Infuse

| Infuse source | PlayItRight | Priority |
|---|---|---|
| Plex, Jellyfin, Emby | ✅ §2 | P0 |
| SMB, NFS, WebDAV, HTTP/HTTPS | ✅ §3 | P0 |
| FTP/FTPES/FTPS, SFTP | ✅ §3 | P1 |
| UPnP/DLNA | ✅ §3 | P1 |
| Dropbox, Google Drive, OneDrive, Box, pCloud | ✅ §4 | P0 (first 3) / P1 (rest) |
| Yandex, Aliyun, 123, 115, Baidu, GuangYaPan | region-specific | P2 |
| Local files | §5 | P1 |
