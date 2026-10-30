import Foundation
import GRDB

public enum DatabaseMigrations {
    /// Creates and configures the DatabaseMigrator with all schema migrations.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v1.0: Full DDL schema per Design 01 §4
        migrator.registerMigration("v1.0") { db in
            try applySchemaV1(db)
        }

        return migrator
    }

    /// Applies the complete v1.0 schema.
    public static func applySchemaV1(_ db: Database) throws {
        // 4.1 meta
        try db.execute(sql: """
            CREATE TABLE meta (
              key   TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            """)

        let nowMs = String(Int64(Date().timeIntervalSince1970 * 1000))
        try db.execute(
            sql: "INSERT INTO meta (key, value) VALUES (?, ?);",
            arguments: ["schema_created_at", nowMs]
        )

        // 4.2 sources
        try db.execute(sql: """
            CREATE TABLE sources (
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
            """)

        // 4.3 movies
        try db.execute(sql: """
            CREATE TABLE movies (
              tmdb_id            INTEGER PRIMARY KEY,
              title              TEXT NOT NULL,
              original_title     TEXT,
              original_language  TEXT,
              alternative_titles TEXT,
              release_date       TEXT,
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
            """)

        // 4.4 tv_shows
        try db.execute(sql: """
            CREATE TABLE tv_shows (
              show_id            TEXT PRIMARY KEY,
              tmdb_id            INTEGER UNIQUE,
              tvdb_id            INTEGER UNIQUE,
              title              TEXT NOT NULL,
              original_title     TEXT,
              original_language  TEXT,
              alternative_titles TEXT,
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
            CREATE INDEX idx_shows_title ON tv_shows(title);
            """)

        // 4.5 seasons / episodes
        try db.execute(sql: """
            CREATE TABLE seasons (
              show_id       TEXT NOT NULL REFERENCES tv_shows(show_id) ON DELETE CASCADE,
              season_number INTEGER NOT NULL,
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
            CREATE INDEX idx_episodes_air ON episodes(show_id, air_date);
            """)

        // 4.6 identifiers
        try db.execute(sql: """
            CREATE TABLE identifiers (
              entity_kind TEXT NOT NULL CHECK (entity_kind IN ('movie','show','episode')),
              entity_ref  TEXT NOT NULL,
              provider    TEXT NOT NULL,
              id          TEXT NOT NULL,
              PRIMARY KEY (entity_kind, entity_ref, provider),
              UNIQUE (provider, id)
            );
            """)

        // 4.7 media_files
        try db.execute(sql: """
            CREATE TABLE media_files (
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
            CREATE INDEX idx_files_source    ON media_files(source_id);
            CREATE INDEX idx_files_movie     ON media_files(matched_movie)   WHERE matched_movie   IS NOT NULL;
            CREATE INDEX idx_files_episode   ON media_files(matched_episode) WHERE matched_episode IS NOT NULL;
            CREATE INDEX idx_files_show      ON media_files(matched_show)    WHERE matched_show    IS NOT NULL;
            CREATE INDEX idx_files_unmatched ON media_files(match_state)     WHERE match_state <> 'matched';
            """)

        // 4.8 tracks
        try db.execute(sql: """
            CREATE TABLE tracks (
              file_id   TEXT NOT NULL REFERENCES media_files(file_id) ON DELETE CASCADE,
              kind      TEXT NOT NULL CHECK (kind IN ('video','audio','subtitle','chapter')),
              "index"   INTEGER NOT NULL,
              title     TEXT,
              lang      TEXT,
              is_default INTEGER NOT NULL DEFAULT 0,
              is_forced  INTEGER NOT NULL DEFAULT 0,
              sampled    INTEGER NOT NULL DEFAULT 1,

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

              channels        INTEGER,
              channel_layout  TEXT,
              sample_rate     INTEGER,
              audio_bit_depth INTEGER,

              subtitle_format TEXT,

              PRIMARY KEY (file_id, kind, "index")
            );
            CREATE INDEX idx_tracks_video_codec
              ON tracks(codec, width, height) WHERE kind = 'video';
            """)

        // 4.9 people / credits
        try db.execute(sql: """
            CREATE TABLE people (
              person_id            TEXT PRIMARY KEY,
              tmdb_id              INTEGER UNIQUE,
              name                 TEXT NOT NULL,
              gender               TEXT,
              birthday             TEXT,
              deathday             TEXT,
              known_for_department TEXT,
              biography            TEXT,
              homepage             TEXT,
              socials              TEXT,
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
              character   TEXT,
              job         TEXT,
              ord         INTEGER NOT NULL,
              PRIMARY KEY (entity_kind, entity_ref, person_id, credit_role, ord)
            );
            CREATE INDEX idx_credits_person ON credits(person_id);
            """)

        // 4.10 genres / media_genres
        try db.execute(sql: """
            CREATE TABLE genres (
              kind     TEXT NOT NULL,
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
            """)

        // 4.11 accounts / watch_state
        try db.execute(sql: """
            CREATE TABLE accounts (
              account_id   TEXT PRIMARY KEY,
              display_name TEXT NOT NULL,
              is_cloud     INTEGER NOT NULL DEFAULT 0,
              cloud_ref    TEXT
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
              track_choices   TEXT,
              last_plan       TEXT,
              updated_at      INTEGER NOT NULL,
              PRIMARY KEY (entity_kind, entity_ref, account)
            );
            CREATE INDEX idx_ws_continue ON watch_state(account, last_watched_at)
              WHERE watched = 0 AND position_ms > 0;
            """)

        // 4.12 Organization
        try db.execute(sql: """
            CREATE TABLE libraries (
              id          TEXT PRIMARY KEY,
              name        TEXT NOT NULL,
              source_refs TEXT NOT NULL,
              visibility  TEXT NOT NULL DEFAULT 'visible',
              ord         INTEGER NOT NULL,
              auto_rule   TEXT
            );

            CREATE TABLE collections (
              id          TEXT PRIMARY KEY,
              name        TEXT NOT NULL,
              artwork_ref TEXT,
              ord         INTEGER NOT NULL
            );
            CREATE TABLE collection_items (
              collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
              entity_kind   TEXT NOT NULL,
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
              filters TEXT NOT NULL,
              ord     INTEGER NOT NULL
            );

            CREATE TABLE similar (
              entity_kind TEXT NOT NULL,
              entity_ref  TEXT NOT NULL,
              sim_kind    TEXT NOT NULL,
              sim_ref     TEXT NOT NULL,
              rank        INTEGER NOT NULL,
              PRIMARY KEY (entity_kind, entity_ref, sim_kind, sim_ref)
            );
            """)

        // 4.13 artwork
        try db.execute(sql: """
            CREATE TABLE artwork (
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
            CREATE INDEX idx_artwork_redownload ON artwork(local_path) WHERE local_path IS NULL;
            """)

        // 4.14 search_index (FTS5)
        try db.execute(sql: """
            CREATE VIRTUAL TABLE search_index USING fts5(
              entity_kind UNINDEXED,
              entity_ref  UNINDEXED,
              title,
              alt_titles,
              overview,
              people_names,
              tokenize = 'unicode61'
            );
            """)
    }
}
