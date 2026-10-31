import Foundation
import GRDB

public final class MediaDatabaseWriter: Sendable {
    public let database: MediaDatabase

    public init(database: MediaDatabase) {
        self.database = database
    }

    // MARK: - Sources

    public func saveSource(_ source: SourceRecord) throws {
        try database.write { db in
            try source.save(db)
        }
        database.emitChange(IndexChangeEvent(tables: ["sources"], updated: 1))
    }

    public func deleteSource(sourceId: String) throws {
        try database.write { db in
            _ = try SourceRecord.deleteOne(db, key: sourceId)
        }
        database.emitChange(IndexChangeEvent(tables: ["sources", "media_files", "tracks"], removed: 1))
    }

    // MARK: - Media Files & Ingestion

    /// Saves a batch of discovered or updated media files, committing in batches of ≤ 500 files.
    public func saveMediaFiles(_ files: [MediaFileRecord], batchSize: Int = 500) throws {
        guard !files.isEmpty else { return }

        var totalSaved = 0
        for batch in stride(from: 0, to: files.count, by: batchSize) {
            let chunk = Array(files[batch..<min(batch + batchSize, files.count)])
            try database.write { db in
                for file in chunk {
                    try file.save(db)
                }
            }
            totalSaved += chunk.count
            database.emitChange(IndexChangeEvent(tables: ["media_files"], added: chunk.count))
        }
    }

    /// Updates probe metadata and replaces tracks for a file.
    public func updateProbeMetadata(
        fileId: String,
        container: String? = nil,
        sizeBytes: Int64? = nil,
        mtime: Int64? = nil,
        durationMs: Int64? = nil,
        tracks: [TrackRecord] = []
    ) throws {
        try database.write { db in
            // Update media_file probe columns
            try db.execute(
                sql: """
                UPDATE media_files
                SET container = COALESCE(?, container),
                    size_bytes = COALESCE(?, size_bytes),
                    mtime = COALESCE(?, mtime),
                    duration_ms = COALESCE(?, duration_ms)
                WHERE file_id = ?;
                """,
                arguments: [container, sizeBytes, mtime, durationMs, fileId]
            )

            // Replace tracks for this file
            try TrackRecord.filter(TrackRecord.Columns.fileId == fileId).deleteAll(db)
            for track in tracks {
                try track.insert(db)
            }
        }
        database.emitChange(IndexChangeEvent(tables: ["media_files", "tracks"], updated: 1))
    }

    // MARK: - File Matching

    /// Matches a file to a movie.
    public func matchFileToMovie(
        fileId: String,
        tmdbId: Int,
        provenance: MatchProvenance = .filename
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                UPDATE media_files
                SET match_state = 'matched',
                    matched_movie = ?,
                    matched_episode = NULL,
                    matched_show = NULL,
                    match_provenance = ?
                WHERE file_id = ?;
                """,
                arguments: [tmdbId, provenance.rawValue, fileId]
            )
        }
        database.emitChange(IndexChangeEvent(tables: ["media_files"], updated: 1))
    }

    /// Matches a file to a TV episode.
    public func matchFileToEpisode(
        fileId: String,
        showId: String,
        seasonNumber: Int,
        episodeNumber: Int,
        provenance: MatchProvenance = .filename
    ) throws {
        let epRef = EntityRef.episodeRef(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
        try database.write { db in
            try db.execute(
                sql: """
                UPDATE media_files
                SET match_state = 'matched',
                    matched_movie = NULL,
                    matched_episode = ?,
                    matched_show = ?,
                    match_provenance = ?
                WHERE file_id = ?;
                """,
                arguments: [epRef, showId, provenance.rawValue, fileId]
            )
        }
        database.emitChange(IndexChangeEvent(tables: ["media_files"], updated: 1))
    }

    /// Marks a file as needs_review.
    public func markFileNeedsReview(fileId: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                UPDATE media_files
                SET match_state = 'needs_review',
                    matched_movie = NULL,
                    matched_episode = NULL,
                    matched_show = NULL,
                    match_provenance = NULL
                WHERE file_id = ?;
                """,
                arguments: [fileId]
            )
        }
        database.emitChange(IndexChangeEvent(tables: ["media_files"], updated: 1))
    }

    /// Unmatches a file.
    public func unmatchFile(fileId: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                UPDATE media_files
                SET match_state = 'unmatched',
                    matched_movie = NULL,
                    matched_episode = NULL,
                    matched_show = NULL,
                    match_provenance = NULL
                WHERE file_id = ?;
                """,
                arguments: [fileId]
            )
        }
        database.emitChange(IndexChangeEvent(tables: ["media_files"], updated: 1))
    }

    // MARK: - Metadata & FTS Synchronization

    /// Saves a movie along with crosswalk identifiers and genre associations, updating search_index in the same transaction.
    public func saveMovie(
        _ movie: MovieRecord,
        identifiers: [IdentifierRecord] = [],
        genres: [Int] = []
    ) throws {
        try database.write { db in
            try movie.save(db)

            for identifier in identifiers {
                try identifier.save(db)
            }

            if !genres.isEmpty {
                try MediaGenreRecord.filter(
                    MediaGenreRecord.Columns.entityKind == EntityKind.movie.rawValue &&
                    MediaGenreRecord.Columns.entityRef == String(movie.tmdbId)
                ).deleteAll(db)

                for (rank, genreId) in genres.enumerated() {
                    let rec = MediaGenreRecord(
                        entityKind: .movie,
                        entityRef: String(movie.tmdbId),
                        genreId: genreId,
                        rank: rank
                    )
                    try rec.insert(db)
                }
            }

            // Sync FTS search_index
            try syncMovieSearchIndex(db, tmdbId: movie.tmdbId, title: movie.title, altTitles: movie.alternativeTitles, overview: movie.overview)
        }
        database.emitChange(IndexChangeEvent(tables: ["movies", "identifiers", "media_genres", "search_index"], updated: 1))
    }

    /// Saves a TV show, updating search_index in the same transaction.
    public func saveTVShow(
        _ show: TVShowRecord,
        identifiers: [IdentifierRecord] = [],
        genres: [Int] = []
    ) throws {
        try database.write { db in
            try show.save(db)

            for identifier in identifiers {
                try identifier.save(db)
            }

            if !genres.isEmpty {
                try MediaGenreRecord.filter(
                    MediaGenreRecord.Columns.entityKind == EntityKind.show.rawValue &&
                    MediaGenreRecord.Columns.entityRef == show.showId
                ).deleteAll(db)

                for (rank, genreId) in genres.enumerated() {
                    let rec = MediaGenreRecord(
                        entityKind: .show,
                        entityRef: show.showId,
                        genreId: genreId,
                        rank: rank
                    )
                    try rec.insert(db)
                }
            }

            // Sync FTS search_index
            try syncShowSearchIndex(db, showId: show.showId, title: show.title, altTitles: show.alternativeTitles, overview: show.overview)
        }
        database.emitChange(IndexChangeEvent(tables: ["tv_shows", "identifiers", "media_genres", "search_index"], updated: 1))
    }

    /// Saves a season.
    public func saveSeason(_ season: SeasonRecord) throws {
        try database.write { db in
            try season.save(db)
        }
        database.emitChange(IndexChangeEvent(tables: ["seasons"], updated: 1))
    }

    /// Saves an episode, updating search_index in the same transaction.
    public func saveEpisode(
        _ episode: EpisodeRecord,
        identifiers: [IdentifierRecord] = []
    ) throws {
        try database.write { db in
            try episode.save(db)

            for identifier in identifiers {
                try identifier.save(db)
            }

            let epRef = episode.episodeRef
            try syncEpisodeSearchIndex(db, episodeRef: epRef, title: episode.title ?? "", overview: episode.overview)
        }
        database.emitChange(IndexChangeEvent(tables: ["episodes", "identifiers", "search_index"], updated: 1))
    }

    /// Saves people and credits, updating affected FTS index rows for associated entities.
    public func savePeopleAndCredits(
        people: [PersonRecord],
        credits: [CreditRecord]
    ) throws {
        try database.write { db in
            for person in people {
                try person.save(db)
                // Sync person to search_index
                try db.execute(
                    sql: "DELETE FROM search_index WHERE entity_kind = 'person' AND entity_ref = ?;",
                    arguments: [person.personId]
                )
                try db.execute(
                    sql: """
                    INSERT INTO search_index (entity_kind, entity_ref, title, alt_titles, overview, people_names)
                    VALUES ('person', ?, ?, NULL, ?, NULL);
                    """,
                    arguments: [person.personId, person.name, person.biography]
                )
            }

            for credit in credits {
                try credit.save(db)
            }

            // Update people_names in search_index for all affected entities
            let affectedEntities = Set(credits.map { "\($0.entityKind.rawValue)|\($0.entityRef)" })
            for entity in affectedEntities {
                let parts = entity.split(separator: "|")
                if parts.count == 2 {
                    let kind = String(parts[0])
                    let ref = String(parts[1])
                    try updateEntityPeopleNamesInFTS(db, entityKind: kind, entityRef: ref)
                }
            }
        }
        database.emitChange(IndexChangeEvent(tables: ["people", "credits", "search_index"], updated: 1))
    }

    // MARK: - Similar Titles / "More Like This" (DB-11)

    /// Atomically replaces the "more like this" relations for an entity.
    ///
    /// Rankings are normalized to their array order so callers can pass a
    /// freshly ranked list without managing rank integers.
    public func replaceSimilar(for entity: EntityRef, with relations: [SimilarRecord]) throws {
        try database.write { db in
            try SimilarRecord
                .filter(
                    SimilarRecord.Columns.entityKind == entity.entityKind.rawValue &&
                    SimilarRecord.Columns.entityRef == entity.rawValue
                )
                .deleteAll(db)

            for (index, relation) in relations.enumerated() {
                let record = SimilarRecord(
                    entityKind: entity.entityKind,
                    entityRef: entity.rawValue,
                    simKind: relation.simKind,
                    simRef: relation.simRef,
                    rank: index
                )
                try record.insert(db)
            }
        }
        database.emitChange(IndexChangeEvent(tables: ["similar"], updated: relations.count))
    }

    /// Removes all "more like this" relations originating from an entity.
    public func deleteSimilar(for entity: EntityRef) throws {
        let deleted = try database.write { db in
            try SimilarRecord
                .filter(
                    SimilarRecord.Columns.entityKind == entity.entityKind.rawValue &&
                    SimilarRecord.Columns.entityRef == entity.rawValue
                )
                .deleteAll(db)
        }
        if deleted > 0 {
            database.emitChange(IndexChangeEvent(tables: ["similar"], removed: deleted))
        }
    }

    /// Saves artwork metadata rows.
    public func saveArtwork(_ artwork: [ArtworkRecord]) throws {
        try database.write { db in
            for item in artwork {
                try item.save(db)
            }
        }
        database.emitChange(IndexChangeEvent(tables: ["artwork"], updated: artwork.count))
    }

    // MARK: - Atomic Show Re-Keying (doc 11 §3.1, DB-2)

    /// Atomically re-keys a TV show (e.g. from `tvrage:81081` to `tmdb:1396`) across all dependent tables.
    public func rekeyTVShow(
        from oldShowId: String,
        to newShowId: String,
        newTmdbId: Int? = nil,
        newTvdbId: Int? = nil
    ) throws {
        guard oldShowId != newShowId else { return }

        try database.write { db in
            // Defer foreign keys during the atomic re-key transaction
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON;")

            // 1. tv_shows table
            try db.execute(
                sql: """
                UPDATE tv_shows
                SET show_id = ?,
                    tmdb_id = COALESCE(?, tmdb_id),
                    tvdb_id = COALESCE(?, tvdb_id)
                WHERE show_id = ?;
                """,
                arguments: [newShowId, newTmdbId, newTvdbId, oldShowId]
            )

            // 2. seasons
            try db.execute(
                sql: "UPDATE seasons SET show_id = ? WHERE show_id = ?;",
                arguments: [newShowId, oldShowId]
            )

            // 3. episodes
            try db.execute(
                sql: "UPDATE episodes SET show_id = ? WHERE show_id = ?;",
                arguments: [newShowId, oldShowId]
            )

            // 4. media_files
            let oldPrefix = "\(oldShowId):"
            let newPrefix = "\(newShowId):"
            let oldPrefixLen = oldPrefix.count + 1

            try db.execute(
                sql: "UPDATE media_files SET matched_show = ? WHERE matched_show = ?;",
                arguments: [newShowId, oldShowId]
            )
            try db.execute(
                sql: """
                UPDATE media_files
                SET matched_episode = ? || SUBSTR(matched_episode, ?)
                WHERE matched_episode LIKE ?;
                """,
                arguments: [newPrefix, oldPrefixLen, "\(oldPrefix)%"]
            )

            // 5. identifiers
            try db.execute(
                sql: "UPDATE identifiers SET entity_ref = ? WHERE entity_kind = 'show' AND entity_ref = ?;",
                arguments: [newShowId, oldShowId]
            )
            try db.execute(
                sql: """
                UPDATE identifiers
                SET entity_ref = ? || SUBSTR(entity_ref, ?)
                WHERE entity_kind = 'episode' AND entity_ref LIKE ?;
                """,
                arguments: [newPrefix, oldPrefixLen, "\(oldPrefix)%"]
            )

            // 6. credits
            try db.execute(
                sql: "UPDATE credits SET entity_ref = ? WHERE entity_kind = 'show' AND entity_ref = ?;",
                arguments: [newShowId, oldShowId]
            )
            try db.execute(
                sql: """
                UPDATE credits
                SET entity_ref = ? || SUBSTR(entity_ref, ?)
                WHERE entity_kind = 'episode' AND entity_ref LIKE ?;
                """,
                arguments: [newPrefix, oldPrefixLen, "\(oldPrefix)%"]
            )

            // 7. artwork
            try db.execute(
                sql: "UPDATE artwork SET entity_ref = ? WHERE entity_kind = 'show' AND entity_ref = ?;",
                arguments: [newShowId, oldShowId]
            )
            try db.execute(
                sql: """
                UPDATE artwork
                SET entity_ref = ? || SUBSTR(entity_ref, ?)
                WHERE entity_kind IN ('season', 'episode') AND entity_ref LIKE ?;
                """,
                arguments: [newPrefix, oldPrefixLen, "\(oldPrefix)%"]
            )

            // 8. watch_state
            try db.execute(
                sql: """
                UPDATE watch_state
                SET entity_ref = ? || SUBSTR(entity_ref, ?)
                WHERE entity_kind = 'episode' AND entity_ref LIKE ?;
                """,
                arguments: [newPrefix, oldPrefixLen, "\(oldPrefix)%"]
            )

            // 9. collections, playlists, pins, similar
            try db.execute(
                sql: "UPDATE collection_items SET entity_ref = ? WHERE entity_kind = 'show' AND entity_ref = ?;",
                arguments: [newShowId, oldShowId]
            )
            try db.execute(
                sql: """
                UPDATE collection_items
                SET entity_ref = ? || SUBSTR(entity_ref, ?)
                WHERE entity_kind = 'episode' AND entity_ref LIKE ?;
                """,
                arguments: [newPrefix, oldPrefixLen, "\(oldPrefix)%"]
            )

            try db.execute(
                sql: "UPDATE playlist_items SET entity_ref = ? WHERE entity_kind = 'show' AND entity_ref = ?;",
                arguments: [newShowId, oldShowId]
            )
            try db.execute(
                sql: """
                UPDATE playlist_items
                SET entity_ref = ? || SUBSTR(entity_ref, ?)
                WHERE entity_kind = 'episode' AND entity_ref LIKE ?;
                """,
                arguments: [newPrefix, oldPrefixLen, "\(oldPrefix)%"]
            )

            try db.execute(
                sql: "UPDATE pins SET entity_ref = ? WHERE entity_kind = 'show' AND entity_ref = ?;",
                arguments: [newShowId, oldShowId]
            )
            try db.execute(
                sql: """
                UPDATE pins
                SET entity_ref = ? || SUBSTR(entity_ref, ?)
                WHERE entity_kind = 'episode' AND entity_ref LIKE ?;
                """,
                arguments: [newPrefix, oldPrefixLen, "\(oldPrefix)%"]
            )

            try db.execute(
                sql: "UPDATE similar SET entity_ref = ? WHERE entity_kind = 'show' AND entity_ref = ?;",
                arguments: [newShowId, oldShowId]
            )
            try db.execute(
                sql: "UPDATE similar SET sim_ref = ? WHERE sim_kind = 'show' AND sim_ref = ?;",
                arguments: [newShowId, oldShowId]
            )

            // 10. media_genres
            try db.execute(
                sql: "UPDATE media_genres SET entity_ref = ? WHERE entity_kind = 'show' AND entity_ref = ?;",
                arguments: [newShowId, oldShowId]
            )

            // 11. search_index
            try db.execute(
                sql: "UPDATE search_index SET entity_ref = ? WHERE entity_kind = 'show' AND entity_ref = ?;",
                arguments: [newShowId, oldShowId]
            )
            try db.execute(
                sql: """
                UPDATE search_index
                SET entity_ref = ? || SUBSTR(entity_ref, ?)
                WHERE entity_kind = 'episode' AND entity_ref LIKE ?;
                """,
                arguments: [newPrefix, oldPrefixLen, "\(oldPrefix)%"]
            )
        }

        database.emitChange(IndexChangeEvent(
            tables: ["tv_shows", "seasons", "episodes", "media_files", "identifiers", "credits", "artwork", "watch_state", "search_index"],
            updated: 1
        ))
    }

    // MARK: - Watch State Operations (DB-7, MD-6/7)

    /// Upserts watch state progress and metadata.
    public func saveWatchState(_ record: WatchStateRecord) throws {
        try database.write { db in
            try record.save(db)
        }
        database.emitChange(IndexChangeEvent(tables: ["watch_state"], updated: 1))
    }

    /// Fast flush for playback position (hot writes at 10 s cadence, NFR-16).
    public func updateWatchProgress(
        account: String,
        entityKind: EntityKind,
        entityRef: String,
        positionMs: Int64,
        durationMs: Int64?,
        watched: Bool
    ) throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO watch_state (
                    entity_kind, entity_ref, account, position_ms, duration_ms,
                    watched, last_watched_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(entity_kind, entity_ref, account) DO UPDATE SET
                    position_ms = excluded.position_ms,
                    duration_ms = COALESCE(excluded.duration_ms, watch_state.duration_ms),
                    watched = excluded.watched,
                    last_watched_at = excluded.last_watched_at,
                    updated_at = excluded.updated_at;
                """,
                arguments: [
                    entityKind.rawValue, entityRef, account, positionMs, durationMs,
                    watched ? 1 : 0, nowMs, nowMs
                ]
            )
        }
        database.emitChange(IndexChangeEvent(tables: ["watch_state"], updated: 1))
    }

    /// Sets user rating override (1–10).
    public func setUserRating(
        account: String,
        entityKind: EntityKind,
        entityRef: String,
        rating: Int?
    ) throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO watch_state (
                    entity_kind, entity_ref, account, user_rating, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(entity_kind, entity_ref, account) DO UPDATE SET
                    user_rating = excluded.user_rating,
                    updated_at = excluded.updated_at;
                """,
                arguments: [entityKind.rawValue, entityRef, account, rating, nowMs]
            )
        }
        database.emitChange(IndexChangeEvent(tables: ["watch_state"], updated: 1))
    }

    // MARK: - Orphan GC (Design 01 §5.9, DB-10, MD-13)

    /// Garbage-collects provider rows and watch state older than `thresholdEpochMs` with no referencing files or organization rows.
    @discardableResult
    public func runOrphanGC(thresholdEpochMs: Int64) throws -> (moviesDeleted: Int, showsDeleted: Int, watchStateDeleted: Int) {
        var moviesDeleted = 0
        var showsDeleted = 0
        var watchStateDeleted = 0

        try database.write { db in
            // 1. Delete orphaned movies: scraped before threshold, not in media_files, not in collections/playlists/pins
            try db.execute(sql: """
                DELETE FROM movies
                WHERE scraped_at < ?
                  AND tmdb_id NOT IN (
                    SELECT matched_movie FROM media_files WHERE matched_movie IS NOT NULL
                  )
                  AND CAST(tmdb_id AS TEXT) NOT IN (
                    SELECT entity_ref FROM collection_items WHERE entity_kind = 'movie'
                    UNION
                    SELECT entity_ref FROM playlist_items WHERE entity_kind = 'movie'
                    UNION
                    SELECT entity_ref FROM pins WHERE entity_kind = 'movie'
                  );
                """, arguments: [thresholdEpochMs])
            moviesDeleted = db.changesCount

            // Clean FTS for deleted movies
            try db.execute(sql: """
                DELETE FROM search_index
                WHERE entity_kind = 'movie'
                  AND entity_ref NOT IN (SELECT CAST(tmdb_id AS TEXT) FROM movies);
                """)

            // 2. Delete orphaned shows: scraped before threshold, not in media_files, not in collections/playlists/pins
            try db.execute(sql: """
                DELETE FROM tv_shows
                WHERE scraped_at < ?
                  AND show_id NOT IN (
                    SELECT matched_show FROM media_files WHERE matched_show IS NOT NULL
                  )
                  AND show_id NOT IN (
                    SELECT entity_ref FROM collection_items WHERE entity_kind = 'show'
                    UNION
                    SELECT entity_ref FROM playlist_items WHERE entity_kind = 'show'
                    UNION
                    SELECT entity_ref FROM pins WHERE entity_kind = 'show'
                  );
                """, arguments: [thresholdEpochMs])
            showsDeleted = db.changesCount

            // Clean FTS for deleted shows
            try db.execute(sql: """
                DELETE FROM search_index
                WHERE entity_kind = 'show'
                  AND entity_ref NOT IN (SELECT show_id FROM tv_shows);
                """)

            // 3. Delete orphaned watch_state older than threshold with no movie or episode
            try db.execute(sql: """
                DELETE FROM watch_state
                WHERE updated_at < ?
                  AND NOT (
                    (entity_kind = 'movie' AND CAST(entity_ref AS INTEGER) IN (SELECT tmdb_id FROM movies))
                    OR
                    (entity_kind = 'episode' AND entity_ref IN (
                        SELECT show_id || ':s' || season_number || 'e' || episode_number FROM episodes
                    ))
                  );
                """, arguments: [thresholdEpochMs])
            watchStateDeleted = db.changesCount

            // 4. Delete "more like this" rows whose source or target entity no longer exists
            try db.execute(sql: """
                DELETE FROM similar
                WHERE (entity_kind = 'movie'
                        AND CAST(entity_ref AS INTEGER) NOT IN (SELECT tmdb_id FROM movies))
                   OR (entity_kind = 'show'
                        AND entity_ref NOT IN (SELECT show_id FROM tv_shows))
                   OR (entity_kind = 'person'
                        AND entity_ref NOT IN (SELECT person_id FROM people))
                   OR (sim_kind = 'movie'
                        AND CAST(sim_ref AS INTEGER) NOT IN (SELECT tmdb_id FROM movies))
                   OR (sim_kind = 'show'
                        AND sim_ref NOT IN (SELECT show_id FROM tv_shows))
                   OR (sim_kind = 'person'
                        AND sim_ref NOT IN (SELECT person_id FROM people));
                """)

            // Update meta last_gc_at
            let nowMs = String(Int64(Date().timeIntervalSince1970 * 1000))
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES ('last_gc_at', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                arguments: [nowMs]
            )
        }

        database.emitChange(IndexChangeEvent(
            tables: ["movies", "tv_shows", "watch_state", "similar", "search_index"],
            removed: moviesDeleted + showsDeleted + watchStateDeleted
        ))

        return (moviesDeleted, showsDeleted, watchStateDeleted)
    }

    // MARK: - Private FTS Helpers

    private func syncMovieSearchIndex(
        _ db: Database,
        tmdbId: Int,
        title: String,
        altTitles: String?,
        overview: String?
    ) throws {
        let ref = String(tmdbId)
        try db.execute(
            sql: "DELETE FROM search_index WHERE entity_kind = 'movie' AND entity_ref = ?;",
            arguments: [ref]
        )

        let peopleNames = try String.fetchOne(
            db,
            sql: """
            SELECT GROUP_CONCAT(p.name, ', ')
            FROM credits c
            JOIN people p USING (person_id)
            WHERE c.entity_kind = 'movie' AND c.entity_ref = ?
            ORDER BY c.ord;
            """,
            arguments: [ref]
        )

        try db.execute(
            sql: """
            INSERT INTO search_index (entity_kind, entity_ref, title, alt_titles, overview, people_names)
            VALUES ('movie', ?, ?, ?, ?, ?);
            """,
            arguments: [ref, title, altTitles, overview, peopleNames]
        )
    }

    private func syncShowSearchIndex(
        _ db: Database,
        showId: String,
        title: String,
        altTitles: String?,
        overview: String?
    ) throws {
        try db.execute(
            sql: "DELETE FROM search_index WHERE entity_kind = 'show' AND entity_ref = ?;",
            arguments: [showId]
        )

        let peopleNames = try String.fetchOne(
            db,
            sql: """
            SELECT GROUP_CONCAT(p.name, ', ')
            FROM credits c
            JOIN people p USING (person_id)
            WHERE c.entity_kind = 'show' AND c.entity_ref = ?
            ORDER BY c.ord;
            """,
            arguments: [showId]
        )

        try db.execute(
            sql: """
            INSERT INTO search_index (entity_kind, entity_ref, title, alt_titles, overview, people_names)
            VALUES ('show', ?, ?, ?, ?, ?);
            """,
            arguments: [showId, title, altTitles, overview, peopleNames]
        )
    }

    private func syncEpisodeSearchIndex(
        _ db: Database,
        episodeRef: String,
        title: String,
        overview: String?
    ) throws {
        try db.execute(
            sql: "DELETE FROM search_index WHERE entity_kind = 'episode' AND entity_ref = ?;",
            arguments: [episodeRef]
        )

        let peopleNames = try String.fetchOne(
            db,
            sql: """
            SELECT GROUP_CONCAT(p.name, ', ')
            FROM credits c
            JOIN people p USING (person_id)
            WHERE c.entity_kind = 'episode' AND c.entity_ref = ?
            ORDER BY c.ord;
            """,
            arguments: [episodeRef]
        )

        try db.execute(
            sql: """
            INSERT INTO search_index (entity_kind, entity_ref, title, alt_titles, overview, people_names)
            VALUES ('episode', ?, ?, NULL, ?, ?);
            """,
            arguments: [episodeRef, title, overview, peopleNames]
        )
    }

    private func updateEntityPeopleNamesInFTS(
        _ db: Database,
        entityKind: String,
        entityRef: String
    ) throws {
        let peopleNames = try String.fetchOne(
            db,
            sql: """
            SELECT GROUP_CONCAT(p.name, ', ')
            FROM credits c
            JOIN people p USING (person_id)
            WHERE c.entity_kind = ? AND c.entity_ref = ?
            ORDER BY c.ord;
            """,
            arguments: [entityKind, entityRef]
        )

        // FTS update protocol: delete and re-insert with new people_names
        let existing = try Row.fetchOne(
            db,
            sql: "SELECT title, alt_titles, overview FROM search_index WHERE entity_kind = ? AND entity_ref = ?;",
            arguments: [entityKind, entityRef]
        )
        if let existing {
            let title: String? = existing["title"]
            let altTitles: String? = existing["alt_titles"]
            let overview: String? = existing["overview"]

            try db.execute(
                sql: "DELETE FROM search_index WHERE entity_kind = ? AND entity_ref = ?;",
                arguments: [entityKind, entityRef]
            )
            try db.execute(
                sql: """
                INSERT INTO search_index (entity_kind, entity_ref, title, alt_titles, overview, people_names)
                VALUES (?, ?, ?, ?, ?, ?);
                """,
                arguments: [entityKind, entityRef, title, altTitles, overview, peopleNames]
            )
        }
    }
}
