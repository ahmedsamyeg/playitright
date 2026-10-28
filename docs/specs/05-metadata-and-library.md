# 05 · Metadata & Library

The library is the app's face: every item from every source, normalized into
one browsable world with rich metadata — the "looks like it belongs in the
App Store" bar that Infuse sets ([appendix A](appendix-a-infuse-reference.md)).

## 1. Metadata providers

| Provider | Role | Notes |
|---|---|---|
| **TMDB** | Primary enrichment | v3 API (dev token); movies, TV, people, media (backdrops/posters/logos), credits, videos (trailers), similar, external ids. Rate-limited (client-side token bucket, 429-aware) |
| **OMDb** | Fallback match/enrich | covers older/foreign titles TMDB misses |
| **TVDB** | TV identity + enrichment | also a **primary-key provider for shows** when TMDB has no record (canonical `show_id`, doc 11); season/episode naming + artwork for very old shows *(P1, Pro? no — free)* |
| **Local (NFO / `.txt` / `.read.txt`)** | Source of truth when present | standard Kodi-style XML; overrides remote for text fields |
| **Server-native** (Plex/Jellyfin/Emby agents) | First pass | server metadata ingested as-is, then gap-filled by our TMDB/OMDb pass (episode art, similar, alternate titles) |

Priority (per field): `local NFO > server > TMDB/OMDb > filename-derived > empty`
User manual overrides (rename, re-match) beat all.

- **MD-1** Matching ladder: provider id from server > local NFO ids > **filename parser** (movies: `Title (Year) [extras]`; episodes: `Show S01E02`, multi-ep, `Episode 12`, index-only, dotted `1x02`; robust to `2160p/x265/DoV.5.1.Atmos` clutter) > interactive picker (top-5 candidates with posters, searchable). *(P0)*
- **MD-2** Ambiguity handling: matches below confidence threshold → item flagged `unmatched`/`needs-review`; a "Fix matching" view lists all flagged items with candidates. *(P0)*
- **MD-3** Re-scrape: per-item and per-library "refresh metadata"; new releases re-pull artwork within 24 h of season/episode air dates (TMDB release-calendar poll, batched). *(P1)*

## 2. Enrichment artifacts

| Artifact | TMDB targets (tvOS 4K) | Fallback |
|---|---|---|
| Poster | 780×1170 (w780) | server art → placeholder card (title on backdrop gradient) |
| Backdrop | 1920×1080 (w1280 for grid, original for detail hero) | — |
| Logo | original | generated title text |
| Fanart/season still | TV: per-season backdrops (P1) | show backdrop |
| Cast & crew | full cast + crew stored in `people`/`credits` (doc 11); UI renders 4–6 headshots (w185) + full list tab | names only |
| Ratings | TMDB score+count, user rating (local, per account) | — |
| Trailer | one best video, HLS from TMDB (1280) | none (Pro-gated, doc 08) |
| Similar/Up Next | "More like this" row (P1) | — |

- **MD-4** Artwork pipeline: async download, disk LRU cache (cap: 2 GB default, user-adjustable 0.5–10 GB), 4K-capable, dedup by (provider, media-type, variant); grid renders from cache with blur-up (low-res first). *(P0)*
- **MD-5** Offline: the index (incl. all metadata text + cached artwork) must be fully browsable offline. *(P0)*

## 3. Watch state

```
WatchState(item, account):
  position (ms), duration, watched(bool), lastWatchedAt, resumeAt,
  per-track choices (audio lang, subtitle), lastPipelinePlan summary
```

- **MD-6** Positions recorded at 1 s cadence; `watched` set automatically at ≥ 90% (and ≤ 10 s from end), never below 5% (avoids "started" noise); user "mark watched/unwatched" wins over heuristics. *(P0)*
- **MD-7** Multi-account: watch state is per Apple ID (or per manually named profile on-device; profiles are local-only, sync maps to Apple ID). *(P0 local profiles; sync = current Apple ID only, doc 07)*
- **MD-8** Push to source (Plex/Jellyfin/Emby played-state) is best-effort, debounced, retried offline. *(P0)*
- **MD-9** TV semantics: a season is "in progress" if any episode is; an episode watched if ≥90%; series card shows next-episode logic (next unwatched by air order). *(P0)*

## 4. Organization (user-facing)

| Feature | Spec |
|---|---|
| **Home** | "Continue Watching" row (resume position ring, per item) + per-library rows; ordered by user; "Recently added" |
| **Library views** | Poster grid (default), List (title/year/rating/progress), Detail; per-library and global; sort (title/year/added/rating/progress); density toggle |
| **Filters** | genre, year, rating (TMDB + user), **resolution (4K/1080/…) and codec badges**, watched/in-progress/unwatched, source; combinable + saveable as "Smart Library" |
| **Collections** | user-curated (add/remove items); provider collections imported as *suggestions* (TMDB lists? P2) |
| **Playlists** | ordered, shuffle/loop, plays as a continuous session with gapless-ish transitions |
| **Pins/Favorites** | pinned items + libraries appear on Home |
| **Search** | local index (FTS5 over titles, alt-titles, overviews, people — doc 11 `search_index`) + remote TMDB browse; per-source scoping; "play results" |
| **On Now / Up Next** | next-in-series from last watched; "series" row |

- **MD-10** All organization above is local (free) and syncs via CloudKit (Pro, doc 07). *(P0 local; P0 sync-gated)*
- **MD-11** Library performance: 100 k-item source must load its grid in < 1.5 s (index-backed, no re-scan); scrolling holds 60 fps with 4K art at ≤ 40% GPU. *(P0)*
- **MD-12** "What changed" view: new items, re-matched items, missing/renamed items since last sync, per source. *(P1)*

## 5. Library identity model

- Item ids are stable across renames (doc 03 SRC-19); libraries, collections,
  playlists, and pins reference ids, never paths.
- **Canonical media identity (doc 11, Decision D-3):** matched media is keyed
  by provider id — movies by TMDB id, shows by TMDB-or-TVDB id (namespaced
  `show_id`) with an `identifiers` crosswalk. Organization and watch state
  reference the canonical id where matched and fall back to the file's stable
  `file_id` when unmatched, so they survive re-matching. Full schema:
  [11 · Media database](11-media-database.md).
- **MD-13** Deleting a source removes its items from the *global* views but keeps
  orphaned watch-state for 30 days (re-adding the same source resurrects state). *(P1)*
