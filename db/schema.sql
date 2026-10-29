-- =====================================================================
-- PlayItRight · Media Database Schema (v1.0)
-- Specification: docs/design/01-media-database.md & docs/specs/11-media-database.md
-- Engine: SQLite 3.39+ / WAL Mode / FTS5
-- =====================================================================

-- Recommended PRAGMAs for PlayItRight connections
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
PRAGMA cache_size = -8192; -- 8 MB in KiB

-- ---------------------------------------------------------------------
-- 4.1 Schema metadata and state flags
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- ---------------------------------------------------------------------
-- 4.2 Storage & media sources (SMB, WebDAV, Plex, Jellyfin, Local, etc.)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sources (
  source_id    TEXT PRIMARY KEY,
  kind         TEXT NOT NULL CHECK (kind IN
    ('plex','jellyfin','emby','smb','nfs','webdav','ftp','ftps','sftp',
     'http','upnp','gdrive','dropbox','onedrive','box','local')),
  name         TEXT NOT NULL,
  config_ref   TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'ok'
               CHECK (status IN ('ok','unreachable','auth-failed','disabled')),
  last_sync_at INTEGER,
  etag         TEXT,
  last_error   TEXT,
  added_at     INTEGER NOT NULL
);

-- ---------------------------------------------------------------------
-- 4.3 Movies
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS movies (
  tmdb_id            INTEGER PRIMARY KEY,
  title              TEXT NOT NULL,
  original_title     TEXT,
  original_language  TEXT,
  alternative_titles TEXT,              -- JSON [{"lang":"...","title":"..."}]
  release_date       TEXT,              -- ISO 8601 date YYYY-MM-DD
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

CREATE INDEX IF NOT EXISTS idx_movies_title ON movies(title);
CREATE INDEX IF NOT EXISTS idx_movies_imdb  ON movies(imdb_id) WHERE imdb_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 4.4 TV Shows
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tv_shows (
  show_id            TEXT PRIMARY KEY,  -- 'tmdb:<id>' or 'tvrage:<id>'
  tmdb_id            INTEGER UNIQUE,
  tvdb_id            INTEGER UNIQUE,
  title              TEXT NOT NULL,
  original_title     TEXT,
  original_language  TEXT,
  alternative_titles TEXT,              -- JSON [{"lang":"...","title":"..."}]
  first_air_date     TEXT,
  last_air_date      TEXT,
  status             TEXT,
  overview           TEXT,
  rating_score       REAL,
  rating_votes       INTEGER,
  homepage           TEXT,
  imdb_id            TEXT,
  scraped_at         INTEGER,
  scraped_source     TEXT
);

CREATE INDEX IF NOT EXISTS idx_shows_title ON tv_shows(title);

-- ---------------------------------------------------------------------
-- 4.5 Seasons & Episodes
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS seasons (
  show_id       TEXT NOT NULL REFERENCES tv_shows(show_id) ON DELETE CASCADE,
  season_number INTEGER NOT NULL,
  title         TEXT,
  overview      TEXT,
  air_date      TEXT,
  PRIMARY KEY (show_id, season_number)
);

CREATE TABLE IF NOT EXISTS episodes (
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

CREATE INDEX IF NOT EXISTS idx_episodes_air ON episodes(show_id, air_date);

-- ---------------------------------------------------------------------
-- 4.6 External Identifiers Crosswalk
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS identifiers (
  entity_kind TEXT NOT NULL CHECK (entity_kind IN ('movie','show','episode')),
  entity_ref  TEXT NOT NULL,
  provider    TEXT NOT NULL,
  id          TEXT NOT NULL,
  PRIMARY KEY (entity_kind, entity_ref, provider),
  UNIQUE (provider, id)
);

-- ---------------------------------------------------------------------
-- 4.7 Discovered & Scanned Media Files
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS media_files (
  file_id          TEXT PRIMARY KEY,
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
  matched_episode  TEXT,
  matched_show     TEXT REFERENCES tv_shows(show_id) ON DELETE SET NULL,
  match_provenance TEXT CHECK (match_provenance IS NULL
                   OR match_provenance IN ('server-id','nfo','filename','user')),
  added_at         INTEGER NOT NULL,
  UNIQUE (source_id, path),
  CHECK (
    (match_state = 'matched') =
      ((matched_movie IS NOT NULL) <> (matched_episode IS NOT NULL))
  )
);

CREATE INDEX IF NOT EXISTS idx_files_source    ON media_files(source_id);
CREATE INDEX IF NOT EXISTS idx_files_movie     ON media_files(matched_movie)   WHERE matched_movie   IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_files_episode   ON media_files(matched_episode) WHERE matched_episode IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_files_show      ON media_files(matched_show)    WHERE matched_show    IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_files_unmatched ON media_files(match_state)     WHERE match_state <> 'matched';

-- ---------------------------------------------------------------------
-- 4.8 Audio, Video, Subtitle & Chapter Tracks
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tracks (
  file_id         TEXT NOT NULL REFERENCES media_files(file_id) ON DELETE CASCADE,
  kind            TEXT NOT NULL CHECK (kind IN ('video','audio','subtitle','chapter')),
  "index"         INTEGER NOT NULL,
  title           TEXT,
  lang            TEXT,
  is_default      INTEGER NOT NULL DEFAULT 0,
  is_forced       INTEGER NOT NULL DEFAULT 0,
  sampled         INTEGER NOT NULL DEFAULT 1,

  -- Video attributes
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
  hdr_format      TEXT,
  sdci_present    INTEGER,

  -- Audio attributes
  channels        INTEGER,
  channel_layout  TEXT,
  sample_rate     INTEGER,
  audio_bit_depth INTEGER,

  -- Subtitle attributes
  subtitle_format TEXT,

  PRIMARY KEY (file_id, kind, "index")
);

CREATE INDEX IF NOT EXISTS idx_tracks_video_codec
  ON tracks(codec, width, height) WHERE kind = 'video';

-- ---------------------------------------------------------------------
-- 4.9 People & Credits
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS people (
  person_id            TEXT PRIMARY KEY, -- 'tmdb:<id>' or 'local:<slug>'
  tmdb_id              INTEGER UNIQUE,
  name                 TEXT NOT NULL,
  gender               TEXT,
  birthday             TEXT,
  deathday             TEXT,
  known_for_department TEXT,
  biography            TEXT,
  homepage             TEXT,
  socials              TEXT,             -- JSON
  popularity           REAL,
  scraped_at           INTEGER,
  scraped_source       TEXT
);

CREATE INDEX IF NOT EXISTS idx_people_name ON people(name);

CREATE TABLE IF NOT EXISTS credits (
  entity_kind TEXT NOT NULL CHECK (entity_kind IN ('movie','show','episode')),
  entity_ref  TEXT NOT NULL,
  person_id   TEXT NOT NULL REFERENCES people(person_id) ON DELETE CASCADE,
  credit_role TEXT NOT NULL,
  character   TEXT,
  job         TEXT,
  ord         INTEGER NOT NULL,
  PRIMARY KEY (entity_kind, entity_ref, person_id, credit_role, ord)
);

CREATE INDEX IF NOT EXISTS idx_credits_person ON credits(person_id);

-- ---------------------------------------------------------------------
-- 4.10 Genres & Media Associations
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS genres (
  kind     TEXT NOT NULL CHECK (kind IN ('movie','tv')),
  genre_id INTEGER NOT NULL,
  name     TEXT NOT NULL,
  PRIMARY KEY (kind, genre_id)
);

CREATE TABLE IF NOT EXISTS media_genres (
  entity_kind TEXT NOT NULL,
  entity_ref  TEXT NOT NULL,
  genre_id    INTEGER NOT NULL,
  rank        INTEGER NOT NULL,
  PRIMARY KEY (entity_kind, entity_ref, genre_id)
);

CREATE INDEX IF NOT EXISTS idx_genres_browse ON media_genres(genre_id, entity_kind, entity_ref);

-- ---------------------------------------------------------------------
-- 4.11 Accounts & Watch State
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS accounts (
  account_id   TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  is_cloud     INTEGER NOT NULL DEFAULT 0,
  cloud_ref    TEXT
);

CREATE TABLE IF NOT EXISTS watch_state (
  entity_kind     TEXT NOT NULL CHECK (entity_kind IN ('movie','episode')),
  entity_ref      TEXT NOT NULL,
  account         TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  position_ms     INTEGER NOT NULL DEFAULT 0,
  duration_ms     INTEGER,
  watched         INTEGER NOT NULL DEFAULT 0,
  last_watched_at INTEGER,
  resume_at       INTEGER,
  user_rating     INTEGER CHECK (user_rating IS NULL OR user_rating BETWEEN 1 AND 10),
  track_choices   TEXT,             -- JSON {audio: idx, subtitle: idx}
  last_plan       TEXT,             -- JSON summary of pipeline plan
  updated_at      INTEGER NOT NULL,
  PRIMARY KEY (entity_kind, entity_ref, account)
);

CREATE INDEX IF NOT EXISTS idx_ws_continue ON watch_state(account, last_watched_at)
  WHERE watched = 0 AND position_ms > 0;

-- ---------------------------------------------------------------------
-- 4.12 Organization: Libraries, Collections, Playlists, Pins, Similar
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS libraries (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  source_refs TEXT NOT NULL,        -- JSON array [source_id, ...]
  visibility  TEXT NOT NULL DEFAULT 'visible',
  ord         INTEGER NOT NULL,
  auto_rule   TEXT                  -- JSON predicate
);

CREATE TABLE IF NOT EXISTS collections (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  artwork_ref TEXT,
  ord         INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS collection_items (
  collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
  entity_kind   TEXT NOT NULL,
  entity_ref    TEXT NOT NULL,
  file_id       TEXT REFERENCES media_files(file_id) ON DELETE SET NULL,
  added_at      INTEGER NOT NULL,
  PRIMARY KEY (collection_id, entity_kind, entity_ref)
);

CREATE TABLE IF NOT EXISTS playlists (
  id      TEXT PRIMARY KEY,
  name    TEXT NOT NULL,
  shuffle INTEGER NOT NULL DEFAULT 0,
  loop    INTEGER NOT NULL DEFAULT 0,
  ord     INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS playlist_items (
  playlist_id  TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
  ord          INTEGER NOT NULL,
  entity_kind  TEXT NOT NULL,
  entity_ref   TEXT NOT NULL,
  file_id      TEXT REFERENCES media_files(file_id) ON DELETE SET NULL,
  PRIMARY KEY (playlist_id, ord)
);

CREATE TABLE IF NOT EXISTS pins (
  entity_kind TEXT NOT NULL,
  entity_ref  TEXT NOT NULL,
  file_id     TEXT REFERENCES media_files(file_id) ON DELETE SET NULL,
  ord         INTEGER NOT NULL,
  PRIMARY KEY (entity_kind, entity_ref)
);

CREATE TABLE IF NOT EXISTS smart_libraries (
  id      TEXT PRIMARY KEY,
  name    TEXT NOT NULL,
  filters TEXT NOT NULL,            -- JSON predicate
  ord     INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS similar (
  entity_kind TEXT NOT NULL,
  entity_ref  TEXT NOT NULL,
  sim_kind    TEXT NOT NULL CHECK (sim_kind IN ('movie','show','person')),
  sim_ref     TEXT NOT NULL,
  rank        INTEGER NOT NULL,
  PRIMARY KEY (entity_kind, entity_ref, sim_kind, sim_ref)
);

-- ---------------------------------------------------------------------
-- 4.13 Artwork Cache Metadata
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS artwork (
  entity_kind TEXT NOT NULL
               CHECK (entity_kind IN ('movie','show','season','episode','person')),
  entity_ref  TEXT NOT NULL,
  kind        TEXT NOT NULL
               CHECK (kind IN ('poster','backdrop','logo','fanart','still','profile')),
  provider    TEXT NOT NULL,
  variant     TEXT NOT NULL,
  local_path  TEXT,
  w           INTEGER,
  h           INTEGER,
  fetched_at  INTEGER,
  PRIMARY KEY (entity_kind, entity_ref, kind, provider, variant)
);

CREATE INDEX IF NOT EXISTS idx_artwork_redownload ON artwork(local_path) WHERE local_path IS NULL;

-- ---------------------------------------------------------------------
-- 4.14 Unified Full-Text Search Virtual Table (FTS5)
-- ---------------------------------------------------------------------
CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(
  entity_kind UNINDEXED,
  entity_ref  UNINDEXED,
  title,
  alt_titles,
  overview,
  people_names,
  tokenize = 'unicode61'
);
