# 11 · Media Database

The media database is the single local store that everything reads from:
browsing, search, playback planning, watch state, organization, and the sync
engine. It is a **single SQLite file** (`library.db`) in the app container —
GRDB, WAL mode, `PRAGMA foreign_keys = ON` — with a versioned schema
(ARCH-3, doc 02). **[Decision D-3, doc 01]** matched media is keyed by
provider identity (TMDB / TVDB ids); files are a separate table that *points
at* matched media.

**Implementation design** (placement on the Apple TV, full DDL, concurrency,
migrations, recovery, query catalog, tests):
[Design 01 · Media database](../design/01-media-database.md).

## 1. Design principles

| # | Principle | Consequence |
|---|---|---|
| DB-X1 | **Provider ids are primary keys for matched media** | `movies` is keyed by its TMDB id; `tv_shows` by its TMDB or TVDB id. No surrogate "media uuid" layer; a provider id *is* the identity. |
| DB-X2 | **Files and matched media are separate entities** | `media_files` is the runtime "Item" (what plays, from a source); it holds *nullable* refs to a movie/episode. A file can be unmatched; a movie can have several files (alt versions). Nothing about a file's provenance lives in the provider tables, and nothing about a title's metadata lives in the file table. |
| DB-X3 | **Crosswalk, not one key per provider** | An `identifiers` table maps any media entity to every provider id (tmdb, tvdb/tvrage, imdb, …). Discovering a second id for an already-keyed title updates the crosswalk instead of forking the row. |
| DB-X4 | **Provenance and freshness per provider row** | Provider-scraped text carries `scraped_at` + provider so re-scrape (MD-3) and manual overrides (doc 05) can be layered without ambiguity. |
| DB-X5 | **User state is a first-class, syncable citizen** | `watch_state`, ratings-override, and organization tables are small and field-stable — they are what CloudKit syncs (doc 07). Provider metadata re-derives on each device and never syncs. |
| DB-X6 | **Boring SQL** | GRDB migrations, plain tables, FTS5 for search. No embedded document blobs, no graph tricks. Everything is queryable in ≤ 3 joins. |

```
                     ┌──────────────────────────── matched world (provider-keyed) ──┐
 sources ──< media_files ──────────────┬──> movies (PK tmdb_id) ──┐
              │  (the "Item")          │    tv_shows (PK show_id)  │
              │                        │    seasons / episodes     │
              ├────< tracks (streams,  │    people ◀──> credits    │
              │      codecs, color)    │                           │
              │                        └── identifiers (crosswalk: tmdb/tvdb/imdb)
              │
              ├──< watch_state (per account)        artwork (per entity: media + people)
              ├──< libraries / collections / playlists / pins / smart_libraries
              └──< fts (search)
```

## 2. Schema

Column types are SQLite-affinity shorthand. "Entity" = one of
`(media|person, <id>)` with the ref formats in §3.1.

### 2.1 `sources`

| Column | Type | Notes |
|---|---|---|
| `source_id` (PK) | TEXT | stable, per-device |
| `kind` | TEXT | plex / jellyfin / emby / smb / nfs / webdav / ftp / sftp / http / upnp / cloud-* / local |
| `name` | TEXT | user-facing |
| `config_ref` | TEXT | opaque handle → Keychain entry (ARCH-8: secrets never in DB) |
| `status`, `last_sync_at`, `etag` | — | freshness engine state (SRC-20) |

### 2.2 `movies` — PK is the **TMDB id**

Movies always key off TMDB (TVDB covers TV only).

| Column | Type | Notes |
|---|---|---|
| `tmdb_id` (PK) | INTEGER | canonical |
| `title`, `original_title`, `original_language` | TEXT | localized display vs original |
| `alternative_titles` | TEXT (JSON) | per-locale display names |
| `release_date`, `status`, `runtime_min` | — | `status`: released/… |
| `overview`, `tagline` | TEXT | provider text (provenance in `identifiers`/below) |
| `rating_score`, `rating_votes` | REAL / INT | TMDB score + count |
| `homepage`, `imdb_id` | TEXT | imdb id also mirrored in `identifiers` |
| `scraped_at`, `scraped_source` | — | provenance: provider + pass (server / TMDB / OMDb / NFO) |

### 2.3 `tv_shows` — PK is the **TMDB id or the TVDB id**

TVDB ids (a.k.a. TVRage) and TMDB series ids are *different number spaces*.
Rule: if either id is known, `show_id = 'tmdb:<id>'` when a TMDB id exists,
else `'tvrage:<id>'`; both ids are stored and crosswalked in `identifiers`
(§2.6). Shows that match in neither are simply absent here (their files sit
in `media_files` as unmatched).

| Column | Type | Notes |
|---|---|---|
| `show_id` (PK) | TEXT | namespaced, rule above |
| `tmdb_id` | INTEGER NULL UNIQUE | — |
| `tvdb_id` | INTEGER NULL UNIQUE | — |
| `title`, `original_title`, `alternative_titles`, `original_language` | TEXT | |
| `first_air_date`, `last_air_date`, `status` | — | ended/returning series/… |
| `overview`, `rating_score`, `rating_votes`, `homepage`, `imdb_id` | | as `movies` |
| `scraped_at`, `scraped_source` | — | |

### 2.4 `seasons`

| Column | Type | Notes |
|---|---|---|
| `show_id` (FK) + `season_number` | — | **PK (show_id, season_number)**; 0 = specials |
| `title`, `overview`, `air_date` | TEXT | per-season still stored in `artwork` (doc 05 MD) |

### 2.5 `episodes`

| Column | Type | Notes |
|---|---|---|
| `show_id` (FK), `season_number`, `episode_number` | — | **PK (show_id, season_number, episode_number)** — the identity both TMDB and TVDB share |
| `title`, `overview`, `air_date`, `runtime_min`, `vote_average` | | |
| `tmdb_episode_id` | INTEGER NULL | TMDB's separate episode id, kept for trailer/credits lookups; also in `identifiers` |

### 2.6 `identifiers` (crosswalk)

| Column | Type | Notes |
|---|---|---|
| `entity_kind` (PK part) | TEXT | `movie` / `show` / `episode` |
| `entity_ref` (PK part) | TEXT | movie: `<tmdb_id>`; show: `show_id`; episode: `<show_id>:<s>e<e>` |
| `provider` (PK part) | TEXT | `tmdb` / `tvdb` / `imdb` / `omdb` / `tvmaze`… |
| `id` | TEXT | |

`UNIQUE(provider, id)` across the table: one provider id resolves to at most
one entity. This is how a Jellyfin `tvrage` id, a Plex `tmdb` id, and an
`imdb` tt-code all converge on one `tv_shows` row, and how a late-discovered
TMDB id for a `tvrage`-keyed show re-keys the row (migration in one
transaction, crosswalk updated in the same).

### 2.7 `media_files` — the file entity (the "Item")

| Column | Type | Notes |
|---|---|---|
| `file_id` (PK) | TEXT | stable id = `hash(sourceId, providerId|path)` (SRC-19); survives renames |
| `source_id` (FK) | TEXT | owning source |
| `path`, `uri` | TEXT | display path + ranged-read location (`.strm` resolved, SRC-16) |
| `container`, `size`, `mtime`, `duration_ms` | | probe results |
| `match_state` | TEXT | `unmatched` / `matched` / `needs_review` (MD-1/MD-2) |
| `matched_movie` | INTEGER NULL | FK `movies.tmdb_id` |
| `matched_episode` | TEXT NULL | ref `<show_id>:<s>e<e>` → FK `episodes` |
| `matched_show` | TEXT NULL | FK `tv_shows.show_id`; denormalized for show-level queries (grid rows, next-episode logic) |
| `match_provenance` | TEXT | server-id / nfo / filename / user — which rung matched (MD-1) |

Multiple files may share `matched_movie` (1080p/4K versions) — the detail
view lists them as sources and the planner picks per rung.

### 2.8 `tracks` — every stream of every file

| Column | Type | Notes |
|---|---|---|
| `track_id` (PK part) | TEXT | `file_id:kind:index` |
| `file_id` (FK) | TEXT | |
| `kind` (PK part) | TEXT | `video` / `audio` / `subtitle` / `chapter` |
| **video:** `codec, profile, level, width, height, fps, bit_depth, pix_fmt, color_primaries, color_trc, color_space, hdr_format` (`hdr10`/`hdr10plus`/`dovi:<profile>`/`hlg`/`sdr`), `sdci_present` | | feeds the pipeline planner (doc 04) and the codec/HDR badges/filters |
| **audio:** `codec, profile, channels, channel_layout, sample_rate, bit_depth` | | |
| **subtitle:** `codec` (srt/ass/ssa/vtt/pgs/bitmap…), `container_format` | | |
| `lang`, `title` | TEXT | ISO 639-2 / null |
| `is_default`, `is_forced` | INT | |
| `sampled` | INT | 1 = values from a probe; 0 = server-claimed |

`UNIQUE(track_id)`; indexed on `(file_id, kind)`.

### 2.9 `people` — cast & crew, one row per person

| Column | Type | Notes |
|---|---|---|
| `person_id` (PK) | TEXT | namespaced: `tmdb:<id>` when known, else `local:<name-slug>` |
| `name` | TEXT | |
| `gender`, `birthday`, `deathday` | | |
| `known_for_department` | TEXT | actor / director / … |
| `biography`, `homepage`, `socials` | TEXT | |
| `popularity` | REAL | TMDB |
| `scraped_at`, `scraped_source` | | |

### 2.10 `credits` — cast & crew roles (the join table)

| Column | Type | Notes |
|---|---|---|
| `entity_kind` (PK part) | TEXT | `movie` / `show` / `episode` |
| `entity_ref` (PK part) | TEXT | same formats as `identifiers` |
| `person_id` (FK, PK part) | TEXT | |
| `credit_role` (PK part) | TEXT | `actor` (main cast) / `guest` (episode) / `director` / `producer` / `writer` / `music` / `editor` / `camera` / `self` / `crew:<name>` |
| `character` | TEXT NULL | for actor/guest/self |
| `job` | TEXT NULL | crew role detail ("Director of Photography") |
| `order` (PK part) | INT | provider-billed order, stable sort for UI |

`UNIQUE(entity_kind, entity_ref, person_id, credit_role, order)`. All cast
and crew from the provider pass are stored; the UI renders 4–6 headshots and
a full "Cast & Crew" tab (doc 05 §2), so nothing is truncated in the DB.

### 2.11 Genres

- `genres(genre_id PK, kind TEXT /*movie|tv|person-dept*/, name TEXT)`
- `media_genres(entity_kind, entity_ref, genre_id, rank)`,
  PK `(entity_kind, entity_ref, genre_id)`.
  Powers the genre filter (doc 05 §4).

### 2.12 `artwork`

| Column | Type | Notes |
|---|---|---|
| `entity_kind` (PK part) | TEXT | `movie` / `show` / `season` / `episode` / `person` |
| `entity_ref` (PK part) | TEXT | season ref = `<show_id>:s<n>`; episode = `<show_id>:<s>e<e>` |
| `kind` (PK part) | TEXT | poster / backdrop / logo / fanart / still / profile |
| `provider` (PK part) | TEXT | tmdb / tvdb / omdb / server / local |
| `variant` (PK part) | TEXT | w185 … w780 / o (original) |
| `local_path` | TEXT | into the LRU artwork cache (MD-4); the DB row is a *reference* — bytes live in the cache |
| `w`, `h`, `fetched_at` | | |

Dedup is by `(entity, kind, provider, variant)`; cache eviction (LRU, capped)
deletes bytes but keeps the row (re-downloadable).

### 2.13 `accounts` / `watch_state`

`accounts(account_id PK, display_name, is_cloud, cloud_ref)` — `account_id` is
a stable local id; local profiles get a generated id + display name, and
cloud-tied accounts map to the Apple ID via an opaque Keychain handle
(`cloud_ref`, never the email — ARCH-8). MD-7 semantics apply.

`watch_state`:

| Column | Type | Notes |
|---|---|---|
| `entity_kind`, `entity_ref` (PK parts) | | `movie` / `episode` |
| `account` (FK, PK part) | TEXT | `accounts.account_id` (Apple ID or local profile, MD-7) |
| `position_ms`, `duration_ms` | | |
| `watched`, `last_watched_at`, `resume_at` | | heuristics per MD-6; user override wins |
| `user_rating` | INT NULL | manual 1–10, overrides provider |
| `track_choices` | TEXT (JSON) | last audio/subtitle picks |
| `last_plan` | TEXT (JSON) | `PipelinePlan` summary (PB badge history) |

One row per (media, account). Hot writes: 1 s cadence in memory, 10 s disk
flush (NFR-16).

### 2.14 Organization

| Table | Shape |
|---|---|
| `libraries` | `id PK, name, source_refs (JSON), visibility, order, auto_rule (JSON NULL)` |
| `collections` | `id PK, name, artwork_ref, order`; `collection_items(collection_id, entity_kind, entity_ref, added_at)`, PK `(collection_id, entity_kind, entity_ref)` |
| `playlists` | `id PK, name, shuffle, loop`; `playlist_items(playlist_id, ord, entity_kind, entity_ref)`, PK `(playlist_id, ord)` |
| `pins` | `(entity_kind, entity_ref) PK, order` |
| `smart_libraries` | `id PK, name, filters (JSON)` — the combinable filter doc (doc 05 §4) stored as a serializable predicate evaluated against `media_files` + `tracks` + matched rows |

Organization rows reference **canonical media where matched** and fall back to
`file_id` for unmatched items, so pins/collections survive matching and
re-matching (MD-2) without re-pointing.

### 2.15 `meta` + FTS

- `meta(key PK, value)`: `schema_version`, provider token *registration*
  flags (the tokens themselves live in Keychain — ARCH-8), feature flags.
- **`search_index`** (FTS5, one unified table; `entity_kind`/`entity_ref`
  routing columns unindexed): one row per matched movie, show, episode, and
  person with `title`, `alt_titles`, `overview`, `people_names`
  (concatenated billed order); tokenizer `unicode61`, prefix queries enabled.
  Incremental maintenance is part of the same transaction as the source row
  (no drift between table and FTS); full `rebuild` is the repair path
  (design 01 §4.14, §6.2).

## 3. Rules

### 3.1 Identity & matching

- **Canonical selection:** movies → TMDB id (only provider). Shows → TMDB if
  known, else TVDB. People → TMDB if known, else name-slug. This *is* the
  primary key (DB-X1); the `identifiers` crosswalk records the rest.
- **Re-keying:** when a `tvrage`-keyed show later gains a TMDB id (or vice
  versa), the row is re-keyed atomically: new `show_id`, `identifiers`
  updated, children (`seasons`, `episodes`, references) rewritten in one
  transaction. Rare, cheap, and logged.
- **Unmatched files** never create provider rows; they exist only in
  `media_files` (`match_state = 'unmatched' | 'needs_review'`) and remain
  fully playable. The "Fix matching" view (MD-2) is a query over
  `match_state`, never a separate table.
- **Matching ladder** (MD-1) writes `match_provenance`; user re-match
  overwrites both the ref and the provenance (syncs as `matchOverride`, doc 07).
- **Renames/moves** follow SRC-19: same `file_id` ⇒ all refs intact; only
  `path`/`uri` change.

### 3.2 Write lifecycle (source → rows)

```
enumerate  → sources, media_files (match_state=unmatched)
probe      → tracks (from file header; or server-claimed, sampled=0)
match      → movies/tv_shows/seasons/episodes + identifiers + file refs
enrich     → provider text + people + credits + genres + artwork refs (async)
watch      → watch_state
organize   → libraries/collections/playlists/pins/smart_libraries
```

All writes go through one serial index-writer queue (doc 02 §6); readers use
WAL snapshots, so UI never blocks on writes.

### 3.3 Sync boundary

CloudKit syncs **user state and organization only**: `watch_state`,
`user_rating`, `matchOverride` (the `identifiers` row for the chosen provider
+ manual fields), `libraries`, `collections`, `playlists`, `pins`,
`smart_libraries`, prefs. **Never synced:** `media_files` file paths,
`tracks`, provider-scraped rows (`movies`/`tv_shows`/`people`/`credits`),
`artwork` — each device re-derives these identically from sources + providers
(doc 07 §1.1). This keeps the CloudKit zone small and idempotent.

### 3.4 Deletion & retention

- Delete source → `DELETE FROM media_files WHERE source_id = ?` cascades to
  `tracks` + FTS. Provider rows survive (may still be referenced by files from
  *other* sources, or by organization rows).
- Orphaned provider rows (no referencing file, not referenced by
  organization, provider-scraped) are garbage-collected after 30 days — the
  same window as orphaned watch state (MD-13); re-adding the source
  resurrects both.
- `watch_state` keeps the 30-day orphan rule (MD-13).

### 3.5 Size budgets

- `library.db` ≤ **1 GB for a 1 M-item library** (NFR-4): FTS + metadata only,
  no bytes (artwork bytes are in the separately-capped LRU cache, MD-4).
  Practical ceiling for v1 is far lower (100 k items ≈ tens of MB).

## 4. Requirements

| ID | Requirement | Priority |
|---|---|---|
| DB-1 | One local SQLite DB (GRDB, WAL, FK on) is the runtime store; schema is versioned via GRDB migrations, forward-migration tested and N-1-app read-only fallback works (NFR-18). | P0 |
| DB-2 | Provider ids are primary keys for matched media: `movies` by TMDB id; `tv_shows` by TMDB id or TVDB id (namespaced `show_id`); `identifiers` crosswalks all provider ids with `UNIQUE(provider, id)`. Re-keying on a newly discovered preferred id is atomic. | P0 |
| DB-3 | `media_files` is the file entity (stable `file_id` per SRC-19) with nullable matched refs; the `unmatched → matched / needs_review` state machine stays consistent with MD-1/MD-2. Multiple files per media allowed. | P0 |
| DB-4 | Cast & crew live in `people` + `credits` (roles: actor, guest, director, producer, writer, music, editor, camera, self, crew:*) with provider billing order; full lists stored, UI trims (doc 05 §2). | P0 |
| DB-5 | `tracks` records every stream (video codecs/color/HDR, audio layout, subtitle format) from a real probe or server claim; it is the input to the pipeline planner (doc 04) and to codec/HDR/resolution badges & filters. | P0 |
| DB-6 | FTS5 `search_index` over titles, alt-titles, overviews, and people; maintained transactionally with source rows. Local search ≤ 50 ms at 100 k items, ≤ 300 ms per keystroke (NFR-1, MD-11). | P0 |
| DB-7 | `watch_state` per (media, account) with 10 s flush + suspend flush (NFR-16); power cut loses < 10 s of progress. | P0 |
| DB-8 | DB file ≤ 1 GB per 1 M-item library; artwork bytes live only in the capped LRU cache, referenced by rows. | P0 |
| DB-9 | Sync boundary per §3.3: user state + organization sync; provider rows, tracks, and file paths never sync. | P0 (Pro-gated per doc 08) |
| DB-10 | 30-day orphan GC for provider rows and watch state (MD-13); source deletion never deletes shared provider rows still referenced elsewhere. | P1 |
| DB-11 | "Similar titles" (`similar` table, entity ref pairs) for "More like this" (doc 05 §2, P1) and Up Next row. | P1 |
| DB-12 | Season/episode stills, per-episode guest-star UI exposure, TVDB episode-number crosswalk fixes (air order vs absolute) for pre-2015 shows. | P2 |
