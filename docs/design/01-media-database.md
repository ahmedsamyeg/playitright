# Design 01 · Media Database (on-device)

Implements: doc 11 (DB-X1…X6, DB-1…DB-12), ARCH-3, ARCH-8, NFR-1, NFR-4,
NFR-16, NFR-18, MD-4/6/7/11/13, SYNC-1/2.

The spec ([11 · Media database](../specs/11-media-database.md)) is the
requirements. This document fixes **how**: where the database lives on the
Apple TV, the exact schema, the connection model, migrations, queries,
recovery, and the test plan. If the two disagree, the spec wins.

## 1. Placement — the database lives on the Apple TV

| Fact | Decision |
|---|---|
| **100% on-device** | One SQLite file in the app sandbox. No server, no hosted database, no downloaded index. The media layer is re-derivable from sources + providers (doc 11 §3.3); the device is the database's home (ARCH-P4, PRD-D2). |
| Path | `Application Support/PlayItRight/library.db` (+ `-wal` / `-shm`). **Application Support, not Documents**: same sandbox guarantees, but not listed in the Files app or the share sheet **[verify tvOS Files-app behavior]**. |
| Siblings | `Application Support/Artwork/` (LRU cache, MD-4) · `tmp/` (download buffer, NFR-3) · `Application Support/Backups/library-<n>.db` (two rolling generations, §6). |
| CloudKit's role | A **sync channel** for the small user-state layer (doc 11 §3.3) — records, not the database. The DB file is never uploaded anywhere. |
| iCloud backup of the box | The container **is** backed up (the DB is small; the migrator keeps N-1 app versions able to open it read-only, NFR-18) → restoring the Apple TV restores the library without a rescan **[verify Apple TV backup/restore behavior]**. |
| Companion (Phase 3) | Each app has its own on-device DB; they converge via CloudKit, not file sharing. No App Group in v1. |
| Free-tier export (SYNC-1) | User-initiated share-sheet copy of the *user-state layer only* (watch state, org, overrides); never automatic, never the whole file. |

## 2. Connection model & concurrency

| Concern | Design |
|---|---|
| Handles | GRDB: one `DatabaseQueue` = **the only writer** (the serial index-writer of doc 02 §6); one `DatabasePool` = readers (grids, search, detail lookups). |
| Concurrency | WAL: readers run concurrently with the writer. `busy_timeout = 5 000 ms`. |
| Per-connection settings | `journal_mode = WAL` (persisted after first open) · `synchronous = NORMAL` (WAL-safe) · `foreign_keys = ON` · `cache_size = -8192` (8 MB). |
| Write batching | One commit per batch: ≤ 500 files or ≤ 2 s of work, whichever first. After each commit the writer emits `IndexChangeEvent{tables, added, updated, removed}` on an `AsyncStream` consumed by UI models (doc 02 §4.1). |
| Reader discipline | One query = one read transaction, closed before yielding to the main actor. Grids use keyset pagination (§5.1) so no query ever scans deep offsets. |
| Real-time audio | The audio render thread never touches the DB. `PipelinePlan` is in memory; watch-state flushes ride the writer queue at 10 s cadence (NFR-16) and on app suspend. |

## 3. Conventions

- **Types.** SQLite affinities: TEXT ids, INTEGER epoch-milliseconds
  timestamps, REAL scores, 0/1 booleans. Date columns are ISO-8601 TEXT
  (provider-shaped), timestamps are INTEGER ms.
- **Entity refs** (doc 11): movie = `<tmdb_id>`; show = `show_id`
  (`tmdb:1396` / `tvrage:81081`); episode = `<show_id>:<s>e<e>`; season =
  `<show_id>:s<n>`; person = `person_id`. Parse rule: split on the **first**
  `:` for the namespace; for episodes the **last** `:` separates `<s>e<e>`.
  Unambiguous because show ids are `namespace:<number>`.
- **JSON columns** (`alternative_titles`, `track_choices`, `last_plan`,
  `filters`, `source_refs`, `socials`): valid JSON or NULL, parsed lazily.
  No v1 SQL *over* JSON — smart-library filters map to whitelisted scalar
  columns (§5.8).
- **Formatted-composite references** (`credits.entity_ref`, `artwork`,
  `watch_state`, `media_genres`, `similar`) cannot be SQLite foreign keys
  (formatted composites). Integrity is enforced by the **single serial writer**
  (the one place these are written) plus the startup consistency scan (DB-1,
  §6.2).
- **Null policy.** Provider text columns are nullable; `NOT NULL` only where a
  row is meaningless without it (ids, names, states). `COALESCE` at read time.

## 4. Full DDL (v1.0 schema)

Created by the migrator in one transaction per migration (order below);
`PRAGMA user_version` is managed by GRDB.

### 4.1 `meta` (DB-1)

```sql
CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- keys: schema_created_at, tmdb_token_registered, omdb_key_registered,
--       last_gc_at, ...   (registration *flags* only — the secrets live in
--                          Keychain, ARCH-8)
```

### 4.2 `sources`

```sql
CREATE TABLE sources (
  source_id    TEXT PRIMARY KEY,
  kind         TEXT NOT NULL CHECK (kind IN
    ('plex','jellyfin','emby','smb','nfs','webdav','ftp','ftps','sftp',
     'http','upnp','gdrive','dropbox','onedrive','box','local')),
  name         TEXT NOT NULL,
  config_ref   TEXT NOT NULL,              -- Keychain item ref; never the secret
  status       TEXT NOT NULL DEFAULT 'ok'
               CHECK (status IN ('ok','unreachable','auth-failed','disabled')),
  last_sync_at INTEGER,
  etag         TEXT,
  last_error   TEXT,
  added_at     INTEGER NOT NULL
);
```

### 4.3 `movies` — PK = TMDB id (DB-2)

```sql
CREATE TABLE movies (
  tmdb_id            INTEGER PRIMARY KEY,
  title              TEXT NOT NULL,
  original_title     TEXT,
  original_language  TEXT,
  alternative_titles TEXT,                 -- JSON [{"lang","title"}]
  release_date       TEXT,                 -- ISO 8601 date
  status             TEXT,
  runtime_min        INTEGER,
  overview           TEXT,
  tagline            TEXT,
  rating_score       REAL,
  rating_votes       INTEGER,
  homepage           TEXT,
  imdb_id            TEXT,
  scraped_at         INTEGER,
  scraped_source     TEXT
);
CREATE INDEX idx_movies_title ON movies(title);
CREATE INDEX idx_movies_imdb  ON movies(imdb_id) WHERE imdb_id IS NOT NULL;
```

### 4.4 `tv_shows` — PK = TMDB id or TVDB id (DB-2)

```sql
CREATE TABLE tv_shows (
  show_id            TEXT PRIMARY KEY,     -- 'tmdb:1396' | 'tvrage:81081'
  tmdb_id            INTEGER UNIQUE,
  tvdb_id            INTEGER UNIQUE,
  title              TEXT NOT NULL,
  original_title     TEXT,
  original_language  TEXT,
  alternative_titles TEXT,
  first_air_date     TEXT,
  last_air_date      TEXT,
  status             TEXT,                 -- 'ended' | 'returning series' | ...
  overview           TEXT,
  rating_score       REAL,
  rating_votes       INTEGER,
  homepage           TEXT,
  imdb_id            TEXT,
  scraped_at         INTEGER,
  scraped_source     TEXT
);
CREATE INDEX idx_shows_title ON tv_shows(title);
```

### 4.5 `seasons` / `episodes`

```sql
CREATE TABLE seasons (
  show_id       TEXT NOT NULL REFERENCES tv_shows(show_id) ON DELETE CASCADE,
  season_number INTEGER NOT NULL,          -- 0 = specials
  title         TEXT,
  overview      TEXT,
  air_date      TEXT,
  PRIMARY KEY (show_id, season_number)
);

CREATE TABLE episodes (
  show_id         TEXT NOT NULL REFERENCES tv_shows(show_id) ON DELETE CASCADE,
  season_number   INTEGER NOT NULL,
  episode_number  INTEGER NOT NULL,
  title           TEXT,
  overview        TEXT,
  air_date        TEXT,
  runtime_min     INTEGER,
  vote_average    REAL,
  tmdb_episode_id INTEGER,
  PRIMARY KEY (show_id, season_number, episode_number)
);
CREATE INDEX idx_episodes_air ON episodes(show_id, air_date);   -- next-episode logic
```

### 4.6 `identifiers` — the crosswalk (DB-2, DB-X3)

```sql
CREATE TABLE identifiers (
  entity_kind TEXT NOT NULL CHECK (entity_kind IN ('movie','show','episode')),
  entity_ref  TEXT NOT NULL,
  provider    TEXT NOT NULL,               -- 'tmdb' | 'tvdb' | 'imdb' | 'omdb' | ...
  id          TEXT NOT NULL,
  PRIMARY KEY (entity_kind, entity_ref, provider),
  UNIQUE (provider, id)                    -- one provider id → at most one entity
);
```

### 4.7 `media_files` — the file entity (DB-3, SRC-19)

```sql
CREATE TABLE media_files (
  file_id          TEXT PRIMARY KEY,       -- hash(sourceId, providerId|path)
  source_id        TEXT NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,
  path             TEXT NOT NULL,
  uri              TEXT NOT NULL,
  container        TEXT,
  size_bytes       INTEGER,
  mtime            INTEGER,
  duration_ms      INTEGER,
  match_state      TEXT NOT NULL DEFAULT 'unmatched'
                   CHECK (match_state IN ('unmatched','needs_review','matched')),
  matched_movie    INTEGER REFERENCES movies(tmdb_id) ON DELETE SET NULL,
  matched_episode  TEXT,                   -- '<show_id>:<s>e<e>' (app-validated, §3)
  matched_show     TEXT REFERENCES tv_shows(show_id) ON DELETE SET NULL,
  match_provenance TEXT CHECK (match_provenance IS NULL
                   OR match_provenance IN ('server-id','nfo','filename','user')),
  added_at         INTEGER NOT NULL,
  UNIQUE (source_id, path),
  CHECK (                                              -- exactly one match target
    (match_state = 'matched') =
      ((matched_movie IS NOT NULL) <> (matched_episode IS NOT NULL))
  )
);
CREATE INDEX idx_files_source    ON media_files(source_id);
CREATE INDEX idx_files_movie     ON media_files(matched_movie)   WHERE matched_movie   IS NOT NULL;
CREATE INDEX idx_files_episode   ON media_files(matched_episode) WHERE matched_episode IS NOT NULL;
CREATE INDEX idx_files_show      ON media_files(matched_show)    WHERE matched_show    IS NOT NULL;
CREATE INDEX idx_files_unmatched ON media_files(match_state)     WHERE match_state <> 'matched';
```

### 4.8 `tracks` (DB-5)

One row per stream; nullable per-kind columns (SQLite rows are variable-length,
so width is cheap).

```sql
CREATE TABLE tracks (
  file_id   TEXT NOT NULL REFERENCES media_files(file_id) ON DELETE CASCADE,
  kind      TEXT NOT NULL CHECK (kind IN ('video','audio','subtitle','chapter')),
  index     INTEGER NOT NULL,
  title     TEXT,
  lang      TEXT,
  is_default INTEGER NOT NULL DEFAULT 0,
  is_forced  INTEGER NOT NULL DEFAULT 0,
  sampled    INTEGER NOT NULL DEFAULT 1,        -- 1 = probed, 0 = server-claimed

  -- video
  codec           TEXT,
  profile         TEXT,
  level           TEXT,
  width           INTEGER,
  height          INTEGER,
  fps_num         INTEGER,
  fps_den         INTEGER,
  bit_depth       INTEGER,
  pix_fmt         TEXT,
  color_primaries TEXT,
  color_trc       TEXT,
  color_space     TEXT,
  hdr_format      TEXT,                          -- sdr|hdr10|hdr10plus|hlg|dovi:<profile>
  sdci_present    INTEGER,

  -- audio
  channels        INTEGER,
  channel_layout  TEXT,
  sample_rate     INTEGER,
  audio_bit_depth INTEGER,

  -- subtitle
  subtitle_format TEXT,                          -- srt|ass|ssa|vtt|pgs|...

  PRIMARY KEY (file_id, kind, index)
);
CREATE INDEX idx_tracks_video_codec
  ON tracks(codec, width, height) WHERE kind = 'video';   -- codec/resolution filters
```

### 4.9 `people` / `credits` — cast & crew (DB-4)

```sql
CREATE TABLE people (
  person_id            TEXT PRIMARY KEY,       -- 'tmdb:32231' | 'local:<slug>'
  tmdb_id              INTEGER UNIQUE,
  name                 TEXT NOT NULL,
  gender               TEXT,
  birthday             TEXT,
  deathday             TEXT,
  known_for_department TEXT,
  biography            TEXT,
  homepage             TEXT,
  socials              TEXT,                   -- JSON
  popularity           REAL,
  scraped_at           INTEGER,
  scraped_source       TEXT
);
CREATE INDEX idx_people_name ON people(name);

CREATE TABLE credits (
  entity_kind TEXT NOT NULL CHECK (entity_kind IN ('movie','show','episode')),
  entity_ref  TEXT NOT NULL,
  person_id   TEXT NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
  credit_role TEXT NOT NULL,
               -- actor | guest | director | producer | writer | music
               -- | editor | camera | self | crew:<Job>
  character   TEXT,
  job         TEXT,
  ord         INTEGER NOT NULL,               -- billed order ("order" is reserved)
  PRIMARY KEY (entity_kind, entity_ref, person_id, credit_role, ord)
);
CREATE INDEX idx_credits_person ON credits(person_id);      -- "filmography" (P1 people pages)
```

### 4.10 `genres` / `media_genres`

```sql
CREATE TABLE genres (
  kind     TEXT NOT NULL,                     -- 'movie' | 'tv'  (separate id spaces)
  genre_id INTEGER NOT NULL,
  name     TEXT NOT NULL,
  PRIMARY KEY (kind, genre_id)
);

CREATE TABLE media_genres (
  entity_kind TEXT NOT NULL,
  entity_ref  TEXT NOT NULL,
  genre_id    INTEGER NOT NULL,
  rank        INTEGER NOT NULL,
  PRIMARY KEY (entity_kind, entity_ref, genre_id)
);
CREATE INDEX idx_genres_browse ON media_genres(genre_id, entity_kind, entity_ref);
```

The writer validates `genres.kind` against `entity_kind` (`movie`→`movie`,
`show`/`episode`→`tv`).

### 4.11 `accounts` / `watch_state` (DB-7, MD-6/7)

```sql
CREATE TABLE accounts (
  account_id  TEXT PRIMARY KEY,               -- local profiles: generated id
  display_name TEXT NOT NULL,
  is_cloud    INTEGER NOT NULL DEFAULT 0,     -- 1 = tied to an Apple ID
  cloud_ref   TEXT                            -- opaque Keychain handle for the
                                              -- Apple ID mapping; never the email
);

CREATE TABLE watch_state (
  entity_kind     TEXT NOT NULL CHECK (entity_kind IN ('movie','episode')),
  entity_ref      TEXT NOT NULL,
  account         TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  position_ms     INTEGER NOT NULL DEFAULT 0,
  duration_ms     INTEGER,
  watched         INTEGER NOT NULL DEFAULT 0,
  last_watched_at INTEGER,
  resume_at       INTEGER,
  user_rating     INTEGER CHECK (user_rating IS NULL OR user_rating BETWEEN 1 AND 10),
  track_choices   TEXT,                       -- JSON {audio: idx, subtitle: idx}
  last_plan       TEXT,                       -- JSON PipelinePlan summary
  updated_at      INTEGER NOT NULL,
  PRIMARY KEY (entity_kind, entity_ref, account)
);
CREATE INDEX idx_ws_continue ON watch_state(account, last_watched_at)
  WHERE watched = 0 AND position_ms > 0;      -- "Continue Watching" row
```

### 4.12 Organization (DB-10, MD-10)

```sql
CREATE TABLE libraries (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  source_refs TEXT NOT NULL,                  -- JSON [source_id, ...]
  visibility  TEXT NOT NULL DEFAULT 'visible',
  ord         INTEGER NOT NULL,
  auto_rule   TEXT                            -- JSON predicate, NULL = manual
);

CREATE TABLE collections (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  artwork_ref TEXT,
  ord         INTEGER NOT NULL
);
CREATE TABLE collection_items (
  collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
  entity_kind   TEXT NOT NULL,                -- canonical media, or
  entity_ref    TEXT NOT NULL,
  file_id       TEXT REFERENCES media_files(file_id) ON DELETE SET NULL,
  added_at      INTEGER NOT NULL,
  PRIMARY KEY (collection_id, entity_kind, entity_ref)
);

CREATE TABLE playlists (
  id      TEXT PRIMARY KEY,
  name    TEXT NOT NULL,
  shuffle INTEGER NOT NULL DEFAULT 0,
  loop    INTEGER NOT NULL DEFAULT 0,
  ord     INTEGER NOT NULL
);
CREATE TABLE playlist_items (
  playlist_id  TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
  ord          INTEGER NOT NULL,
  entity_kind  TEXT NOT NULL,
  entity_ref   TEXT NOT NULL,
  file_id      TEXT REFERENCES media_files(file_id) ON DELETE SET NULL,
  PRIMARY KEY (playlist_id, ord)
);

CREATE TABLE pins (
  entity_kind TEXT NOT NULL,
  entity_ref  TEXT NOT NULL,
  file_id     TEXT REFERENCES media_files(file_id) ON DELETE SET NULL,
  ord         INTEGER NOT NULL,
  PRIMARY KEY (entity_kind, entity_ref)
);

CREATE TABLE smart_libraries (
  id      TEXT PRIMARY KEY,
  name    TEXT NOT NULL,
  filters TEXT NOT NULL,                      -- JSON predicate over whitelisted cols
  ord     INTEGER NOT NULL
);

-- P1 (DB-11) / P2 (DB-12):
CREATE TABLE similar (
  entity_kind TEXT NOT NULL,
  entity_ref  TEXT NOT NULL,
  sim_kind    TEXT NOT NULL,                  -- 'movie' | 'show' | 'person'
  sim_ref     TEXT NOT NULL,
  rank        INTEGER NOT NULL,
  PRIMARY KEY (entity_kind, entity_ref, sim_kind, sim_ref)
);
```

Organization rows carry `entity_kind/entity_ref` (canonical media) **and** a
nullable `file_id` (the concrete file) — playback needs the file, identity
needs the canonical id; both survive re-matching independently (doc 11 §2.14).

### 4.13 `artwork` (DB-8, MD-4)

```sql
CREATE TABLE artwork (
  entity_kind TEXT NOT NULL
               CHECK (entity_kind IN ('movie','show','season','episode','person')),
  entity_ref  TEXT NOT NULL,
  kind        TEXT NOT NULL
               CHECK (kind IN ('poster','backdrop','logo','fanart','still','profile')),
  provider    TEXT NOT NULL,                  -- tmdb | tvdb | omdb | server | local
  variant     TEXT NOT NULL,                  -- w185 … w780 | o
  local_path  TEXT,                           -- rel. to Artwork/; NULL = evicted
  w           INTEGER,
  h           INTEGER,
  fetched_at  INTEGER,
  PRIMARY KEY (entity_kind, entity_ref, kind, provider, variant)
);
CREATE INDEX idx_artwork_redownload ON artwork(local_path) WHERE local_path IS NULL;
```

Bytes live in the LRU cache on disk; the table only references them (DB-8).
Eviction updates `local_path` to NULL, never deletes the row.

### 4.14 Full-text search (DB-6)

One unified FTS5 table (inline content — the writer is the only mutator, so no
shadow tables); routing columns are `UNINDEXED`.

```sql
CREATE VIRTUAL TABLE search_index USING fts5(
  entity_kind UNINDEXED,
  entity_ref  UNINDEXED,
  title,
  alt_titles,
  overview,
  people_names
);
```

Maintenance is done **in the writer, same transaction as the source row**
(doc 11: no drift):

- insert/update of a movies / tv_shows / episodes / people row → recompute the
  six values, then `INSERT INTO search_index(search_index, rowid, …)
  VALUES('delete', <rowid>, <old values>)` followed by the new `INSERT`
  (the standard FTS5 update protocol; the writer already holds both value sets).
- credits changes → recompute `people_names` for the affected entity and
  re-emit its FTS row.
- Repair path: `INSERT INTO search_index(search_index) VALUES('rebuild')` —
  the writer runs it from the source tables on the startup consistency scan
  (§6.2) whenever row counts diverge.

Queries use `MATCH` with quoted user tokens (each token is escaped; `*`
suffix on the first token for prefix); results carry FTS `rank`.

## 5. Query catalog (indexes are designed for these)

### 5.1 Library grid page (MD-11: < 1.5 s first paint, 60 fps scroll)

Keyset pagination — no `OFFSET` deep scans:

```sql
SELECT f.file_id, f.path, f.match_state, f.duration_ms,
       COALESCE(m.title, s.title, f.path) AS display,
       m.tmdb_id, s.show_id
FROM   media_files f
LEFT   JOIN movies   m ON m.tmdb_id  = f.matched_movie
LEFT   JOIN tv_shows s ON s.show_id  = f.matched_show
WHERE  f.source_id = ?
  AND  (f.file_id, COALESCE(m.title, s.title, f.path)) > (?, ?)   -- last row of prev page
ORDER  BY COALESCE(m.title, s.title, f.path), f.file_id
LIMIT  60;
```

Serves on `idx_files_source` + the two FK lookups. Budget: **p95 < 50 ms at
100 k items** on gen 3; the scroll buffer pre-fetches the next page from the
reader pool while the main actor renders.

### 5.2 Continue Watching (Home)

```sql
SELECT w.entity_kind, w.entity_ref, w.position_ms, w.duration_ms, w.last_watched_at
FROM   watch_state w
WHERE  w.account = ? AND w.watched = 0 AND w.position_ms > 0
ORDER  BY w.last_watched_at DESC
LIMIT  12;
```
`idx_ws_continue` (partial). Then one batched IN-lookup for display names.

### 5.3 Next unwatched episode (series row, MD-9)

```sql
SELECT e.*
FROM   episodes e
LEFT   JOIN watch_state w
       ON  w.account = ? AND w.watched = 0
       AND w.entity_kind = 'episode'
       AND w.entity_ref  = e.show_id || ':' || e.season_number || 'e' || e.episode_number
WHERE  e.show_id = ? AND (w.entity_ref IS NULL OR w.position_ms > 0)
ORDER  BY e.air_date, e.season_number, e.episode_number
LIMIT  1;
```
`idx_episodes_air` + `watch_state` PK.

### 5.4 Search (NFR-1: ≤ 300 ms/keystroke)

`MATCH` query (§4.14) → top-20 rowids → one IN-join for display fields.
Debounce 250 ms; per-source scoping adds a `media_files` join when the user
narrows.

### 5.5 Unmatched / needs-review list (MD-2)

`idx_files_unmatched` + `sources` join; grouped by source in the UI.

### 5.6 Cast & crew tab (doc 05 §2, DB-4)

```sql
SELECT c.credit_role, c.character, c.job, c.ord, p.name, p.person_id,
       a.local_path AS headshot
FROM   credits c JOIN people p USING (person_id)
LEFT   JOIN artwork a
       ON a.entity_kind='person' AND a.entity_ref=p.person_id
      AND a.kind='profile' AND a.variant='w185' AND a.local_path IS NOT NULL
WHERE  c.entity_kind = ? AND c.entity_ref = ? AND c.credit_role IN ('actor','guest')
ORDER  BY c.ord;
```
PK prefix on `credits`; headshots from cache (blur-up, MD-4).

### 5.7 Person page (P1)

`idx_credits_person` → credits → entity join (movies/tv_shows/episodes).

### 5.8 Smart-library filters (doc 05 §4)

The JSON predicate is compiled to SQL by a **whitelisted mapper** — only these
column families are addressable: `media_files(source_id, path, mtime,
duration_ms, match_state, container)`, `tracks(kind, codec, width, height,
hdr_format, channels, lang, subtitle_format)`, `movies/tv_shows(title,
release_date, first_air_date, rating_score, status)`, `media_genres`,
`watch_state(watched, position_ms)`. No raw user SQL, no JSON-path SQL.

### 5.9 Orphan GC (DB-10, MD-13)

Low-frequency writer job (on launch if `last_gc_at` > 24 h): provider rows
with no referencing file and no organization row, older than 30 days →
delete; same pass for `watch_state` orphans. Bounded batch, one commit.

## 6. Migrations, backups, recovery

### 6.1 Migrations (DB-1, NFR-18)

- GRDB `DatabaseMigrator` with an append-only sequence; first migration
  applies the full §4 DDL. `user_version` advances automatically.
- v1.x rule: **additive-only** — new tables/columns (with defaults); no
  drops, renames, or type changes without a backfill migration + a recorded
  decision.
- Every migration is a single transaction; round-trip tested (empty DB and
  each previous version); the N-1 app version must open the migrated file
  **read-only** (NFR-18) — CI keeps a fixture ladder for this.

### 6.2 Startup checks

1. `PRAGMA quick_check` (cheap); on failure → §6.3 corruption path.
2. Consistency scan (cheap aggregate counts: files vs FTS rows, orphan
   refs): on divergence → FTS `rebuild` + recompute, all in one transaction.
3. Rolling backup (§6.4) if stale.

### 6.3 Corruption path

Quarantine `library.db*` → `Backups/library.corrupt-<ts>.db`, recreate from
migrations, then:

- **User-state layer** (`accounts`, `watch_state`, organization, `pins`,
  `matchOverride`s) is restored from the newest healthy backup generation.
- **Media layer** (files, tracks, matched rows, identifiers, people, credits,
  genres, artwork refs) is **rebuilt** by re-running the doc 11 §3.2 write
  lifecycle (enumerate → probe → match → enrich) with a visible progress UI —
  it is fully re-derivable, which is what makes a 100% on-device database
  safe: the irreplaceable data is the small user-state layer, and that is
  doubly protected by backup generations *and* CloudKit (Pro).

### 6.4 Rolling local backup

On launch, if the newest backup is > 24 h old or the DB grew > 10%:
`VACUUM INTO 'Backups/library-<n>.db'` on the writer (non-blocking, copies
the live state); keep two generations, evict oldest. Free users' only state
protection is this + the one-time export (SYNC-1); Pro adds CloudKit.

### 6.5 Size & hygiene (DB-8, NFR-4)

- `library.db` ≤ 1 GB per 1 M-item library (metadata + FTS only; artwork
  bytes are in the capped `Artwork/` LRU, MD-4).
- `PRAGMA optimize` on app suspend; `VACUUM` only via the backup path
  (`VACUUM INTO`), never in place on the live file.

## 7. Security & privacy

- **No secrets in the DB** — `sources.config_ref` and `accounts.cloud_ref`
  are opaque Keychain handles (ARCH-8, NFR-7).
- The DB sits in Application Support: not visible in the Files app, not a
  share-sheet source; only the explicit user export (§1) leaves the sandbox.
- App Privacy label stays "**Data Not Collected**": everything in the DB is
  on-device; CloudKit records (Apple infrastructure) carry no content
  metadata beyond user-state fields (doc 09 §4).

## 8. Test plan

| Class | What | Where |
|---|---|---|
| Migrations | apply on empty DB + each previous version; N-1 read-only open; user_version monotonic | CI (macOS harness, ARCH-7) |
| Invariants | the `media_files` match XOR CHECK; formatted-ref integrity scan; FTS row-count ≡ source counts after rebuild | CI |
| Golden library | a 10 k-item fixture (Plex + SMB + local; matched/unmatched; 2 accounts) seeded → snapshots of §5 queries compared to golden JSON | CI + device lab nightly |
| Performance | 100 k-item seed on gen 3/4: grid page p95 < 50 ms, search keystroke < 300 ms, file size vs budget, 60 concurrent watch-state flushes in one 10 s window | device lab |
| Recovery | bit-flip corruption → quarantine → backup restore + media rebuild → golden queries green again; kill mid-backup; kill mid-migration | device lab + CI (simulated) |

The same `LibraryCore` package builds for macOS (ARCH-7), so everything except
the hardware rows runs in CI; the device lab (roadmap) covers the rest.

## 9. Traceability

| Spec requirement | Design section |
|---|---|
| DB-1 (single DB, migrations) | §1, §2, §4.1, §6.1–6.2 |
| DB-2 (provider-id PKs, crosswalk, re-keying) | §3, §4.3–4.4, §4.6 |
| DB-3 (files, match state machine) | §4.7, §3 (writer-validated refs) |
| DB-4 (people/credits) | §4.9, §5.6–5.7 |
| DB-5 (tracks) | §4.8, §5.1/5.8 |
| DB-6 (FTS) | §4.14, §5.4 |
| DB-7 (watch state) | §4.11, §5.2–5.3, §6 |
| DB-8 (size budget) | §1, §4.13, §6.5 |
| DB-9 (sync boundary) | doc 07 (CloudKit side); §1 (DB never uploads) |
| DB-10 (30-day GC) | §5.9, §6.3 |
| DB-11 / DB-12 (similar, season/episode long tail) | §4.12 `similar`, P1/P2 backlog |
| ARCH-3 / ARCH-8, NFR-1/4/16/18, MD-4/6/7/11/13 | as cited per section |
