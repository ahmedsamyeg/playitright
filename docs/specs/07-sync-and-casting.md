# 07 · Sync & Casting

Two distinct problems: (a) keeping *one user's* library/world consistent
across their Apple devices, and (b) moving *playback* to another screen or
speaker. Parity target: Infuse Pro's "iCloud sync" + "AirPlay & Google Cast"
([appendix A](appendix-a-infuse-reference.md)).

## 1. CloudKit sync

### 1.1 What syncs

| Record class | Fields | Notes |
|---|---|---|
| `library` | id, name, sourceRefs, visibility, order, filters | sourceRefs are *handles* (kind + opaque id), not credentials |
| `collection` / `playlist` | members (item refs), order, shuffle/loop flags | item refs = canonical media id (doc 11) where matched, else (sourceHandle, fileStableId) |
| `pin` / `favorite` | item ref | — |
| `watchState` | item ref, account, position, watched, lastWatchedAt, track choices, pipeline summary | the hot record; high write frequency |
| `prefs` | quality bias, color mode, subtitle style, sink profile, per-source locks | user's "how I like it" |
| `matchOverride` | item ref, chosen provider id (writes the `identifiers` crosswalk, doc 11), manual fields | re-matches travel with you |

**Never syncs:** API keys/tokens/2FA secrets (Keychain, per-device), artwork
(re-downloaded per device from provider CDN), raw file paths of local items,
diagnostics data — and the whole provider-derived media layer (`movies`,
`tv_shows`, `tracks`, `people`, `credits`: each device re-derives it from
sources + providers, doc 11 §3.3).

- **SYNC-1** Sync is a **Pro** feature (doc 08). Free users get a one-time
  "copy my library to this device" migration (AirDrop/manual export file) and
  local-only persistence. *(P0)*

### 1.2 Engine

- CloudKit public **+ private** databases; one user zone per Apple ID; records
  carry `clientModTimestamp` + monotonically-increasing client seq.
- **Merge rules:** scalar fields = last-writer-wins by server timestamp;
  `watchState.position` = max(position) with recency guard (a 0:00 reset beats
  99% if newer); collections/playlists = per-member last-writer-wins with
  tombstones; conflicts that lose user-visible data are logged to a
  "sync notes" list (never silent data loss).
- `watchState` writes are batched (≤ 1 write / 30 s / item in steady state;
  coalesced on exit) to stay inside CloudKit rate envelopes.
- **SYNC-2** Offline queue: all local changes persist to the index immediately
  (local UX never blocks on the cloud); sync engine drains the delta queue on
  reachability; backoff + jitter; a persistent "sync pending (N)" pill with a
  plain-language state. *(P0)*
- **SYNC-3** Sign-in on TV: iCloud sign-in via tvOS system sheet (no manual
  credential entry); on denial → graceful local-only mode with a single
  re-offer per week max. *(P0)*
- **SYNC-4** Cross-device resume: play an item on iPhone (future build) →
  resume on Apple TV within the same session with ≤ 1 s position error.
  For v1 (tvOS-only shipping): Apple ID continuity across *multiple Apple TVs*
  is the concrete scenario. *(P0 multi-TV; iPhone continuity ships with Phase 3)*
- **SYNC-5** "Delete my data" (Privacy, doc 09) = wipe all user-zone records +
  local index; idempotent, confirmed in-UI. *(P0)*

## 2. AirPlay

| Direction | Spec | Priority |
|---|---|---|
| **Apple TV → HomePod / HomePod pair** (audio) | `AVRoutePickerView`/`AVAudioSession` remote; audio-only follow (video stays local) or full move; 5.1→stereo downmix per sink | P0 (Pro) |
| **iPhone/iPad → Apple TV** (video) | `AVPlayer` + AirPlay route on the *companion* build (Phase 3); subtitle passthrough + surround audio per doc 04 audio table | Phase 3 |
| **Apple TV → TV over AirPlay 2** | mirror/extend not applicable (Apple TV *is* the box); treat as N/A — casting *from* Apple TV is audio-only or to Cast | N/A |

- **SYNC-6** AirPlay route changes are observed live and feed the sink
  profile (doc 04 §3), triggering re-plan per PB-6. *(P0)*

## 3. Google Cast

- Cast SDK for tvOS (sender = the app; cast targets = Chromecast /
  Chromecast-with-screen / receiver apps).
- **SYNC-7** Cast a *currently playing* item: sends URL/segment stream where
  the source supports it (HTTP/SMB-share-hosted files exposed via our
  read-ranged URL where the server allows); **files on private shares without
  network reachability from the Cast device are declined with a clear
  explanation** (never a silent failure). *(P1, Pro)*
- **SYNC-8** Cast audio-only (HomePod-alike behavior on Chromecast audio
  devices) for audio files. *(P2)*

## 4. Multi-device model (v1 concrete)

```
Apple ID (CloudKit)
 ├── Apple TV (living room)  ─┐
 ├── Apple TV (bedroom)       ├─ shared: libraries, org, watchState, prefs
 └── (Phase 3: iPhone/iPad)   ┘ per-device: credentials, artwork cache,
                                local files, device capability profile
```

- **SYNC-9** Household: sync is per Apple ID; multiple family members use
  Apple ID switching (tvOS system-level) → per-profile watch state (MD-7).
  No multi-seat Pro sharing in v1 (doc 01 §7). *(P0)*
