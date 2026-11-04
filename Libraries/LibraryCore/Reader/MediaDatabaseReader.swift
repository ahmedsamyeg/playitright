import Foundation
import GRDB

public final class MediaDatabaseReader: Sendable {
    public let database: MediaDatabase

    public init(database: MediaDatabase) {
        self.database = database
    }

    // MARK: - Source Sync

    /// Fetches the sync-state row for a source.
    public func fetchSource(sourceId: String) throws -> SourceRecord? {
        try database.read { db in
            try SourceRecord.fetchOne(db, key: sourceId)
        }
    }

    /// Fetches every indexed file for a source.
    ///
    /// The source sync coordinator uses this to diff a fresh enumeration
    /// against the local index without re-reading the whole library grid.
    public func fetchFiles(sourceId: String) throws -> [MediaFileRecord] {
        try database.read { db in
            try MediaFileRecord
                .filter(MediaFileRecord.Columns.sourceId == sourceId)
                .fetchAll(db)
        }
    }

    /// Fetches every watch-state row for an account so list/grid views can
    /// render watched and in-progress indicators without per-row queries.
    public func fetchWatchStates(account: String) throws -> [WatchStateRecord] {
        try database.read { db in
            try WatchStateRecord
                .filter(WatchStateRecord.Columns.account == account)
                .fetchAll(db)
        }
    }

    /// Fetches genre names for filter chips.
    public func fetchGenres(kind: GenreKind? = nil) throws -> [GenreRecord] {
        try database.read { db in
            var query = GenreRecord.all()
            if let kind {
                query = query.filter(GenreRecord.Columns.kind == kind.rawValue)
            }
            return try query.order(GenreRecord.Columns.name).fetchAll(db)
        }
    }

    /// Fetches every saved Smart Library in display order.
    public func fetchSmartLibraries() throws -> [SmartLibraryRecord] {
        try database.read { db in
            try SmartLibraryRecord
                .order(SmartLibraryRecord.Columns.ord, SmartLibraryRecord.Columns.id)
                .fetchAll(db)
        }
    }

    // MARK: - Detail Screens (doc 05 §2, doc 06 §2.3)

    public func fetchMovie(tmdbId: Int) throws -> MovieRecord? {
        try database.read { db in
            try MovieRecord.fetchOne(db, key: tmdbId)
        }
    }

    public func fetchShow(showId: String) throws -> TVShowRecord? {
        try database.read { db in
            try TVShowRecord.fetchOne(db, key: showId)
        }
    }

    public func fetchSeasons(showId: String) throws -> [SeasonRecord] {
        try database.read { db in
            try SeasonRecord
                .filter(SeasonRecord.Columns.showId == showId)
                .order(SeasonRecord.Columns.seasonNumber)
                .fetchAll(db)
        }
    }

    public func fetchEpisodes(
        showId: String,
        seasonNumber: Int
    ) throws -> [EpisodeRecord] {
        try database.read { db in
            try EpisodeRecord
                .filter(EpisodeRecord.Columns.showId == showId)
                .filter(EpisodeRecord.Columns.seasonNumber == seasonNumber)
                .order(EpisodeRecord.Columns.episodeNumber)
                .fetchAll(db)
        }
    }

    public func fetchMediaFiles(movieId: Int) throws -> [MediaFileRecord] {
        try database.read { db in
            try MediaFileRecord
                .filter(MediaFileRecord.Columns.matchedMovie == movieId)
                .order(MediaFileRecord.Columns.path)
                .fetchAll(db)
        }
    }

    public func fetchMediaFiles(showId: String) throws -> [MediaFileRecord] {
        try database.read { db in
            try MediaFileRecord
                .filter(MediaFileRecord.Columns.matchedShow == showId)
                .order(MediaFileRecord.Columns.path)
                .fetchAll(db)
        }
    }

    public func fetchMediaFiles(episodeRef: String) throws -> [MediaFileRecord] {
        try database.read { db in
            try MediaFileRecord
                .filter(MediaFileRecord.Columns.matchedEpisode == episodeRef)
                .order(MediaFileRecord.Columns.path)
                .fetchAll(db)
        }
    }

    public func fetchTracks(fileId: String) throws -> [TrackRecord] {
        try database.read { db in
            try TrackRecord
                .filter(TrackRecord.Columns.fileId == fileId)
                .order(TrackRecord.Columns.kind, TrackRecord.Columns.index)
                .fetchAll(db)
        }
    }

    public func fetchArtwork(
        entityKind: EntityKind,
        entityRef: String,
        kind: ArtworkKind
    ) throws -> ArtworkRecord? {
        try database.read { db in
            try ArtworkRecord
                .filter(ArtworkRecord.Columns.entityKind == entityKind.rawValue)
                .filter(ArtworkRecord.Columns.entityRef == entityRef)
                .filter(ArtworkRecord.Columns.kind == kind.rawValue)
                .filter(ArtworkRecord.Columns.localPath != nil)
                .order(ArtworkRecord.Columns.variant)
                .fetchOne(db)
        }
    }

    // MARK: - Home Shelves (Design 01 §5.1, MD-9)

    /// Fetches every configured source, oldest first, for per-library shelves.
    public func fetchSources() throws -> [SourceRecord] {
        try database.read { db in
            try SourceRecord
                .order(SourceRecord.Columns.addedAt, SourceRecord.Columns.sourceId)
                .fetchAll(db)
        }
    }

    /// Fetches the most recently indexed files across every source.
    ///
    /// Uses a simple `added_at` keyset-friendly ordering so the home shelf can
    /// page with `addedAt`/`fileId` cursors without offset scans (NFR-1).
    public func fetchRecentlyAdded(
        limit: Int = 20,
        before: (addedAt: Int64, fileId: String)? = nil
    ) throws -> [RecentlyAddedItem] {
        try database.read { db in
            var sql = """
                SELECT f.file_id, f.source_id, f.added_at, f.duration_ms,
                       COALESCE(m.title, s.title, f.path) AS display,
                       m.tmdb_id, s.show_id
                FROM media_files f
                LEFT JOIN movies m ON m.tmdb_id = f.matched_movie
                LEFT JOIN tv_shows s ON s.show_id = f.matched_show
                """
            var args: [DatabaseValueConvertible] = []

            if let before {
                sql += """
                     WHERE (f.added_at < ? OR (f.added_at = ? AND f.file_id < ?))
                    """
                args.append(before.addedAt)
                args.append(before.addedAt)
                args.append(before.fileId)
            }

            sql += " ORDER BY f.added_at DESC, f.file_id DESC LIMIT ?;"
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row in
                guard let fileId: String = row["file_id"],
                      let sourceId: String = row["source_id"],
                      let addedAt: Int64 = row["added_at"],
                      let display: String = row["display"] else {
                    return nil
                }
                let durationMs: Int64? = row["duration_ms"]
                let tmdbId: Int? = row["tmdb_id"]
                let showId: String? = row["show_id"]

                return RecentlyAddedItem(
                    fileId: fileId,
                    title: display,
                    sourceId: sourceId,
                    addedAt: addedAt,
                    durationMs: durationMs,
                    tmdbId: tmdbId,
                    showId: showId
                )
            }
        }
    }

    /// Returns source shelves with their current item counts.
    public func fetchLibraryShelves() throws -> [LibraryShelfSummary] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.source_id, s.name, COUNT(f.file_id) AS item_count
                    FROM sources s
                    LEFT JOIN media_files f ON f.source_id = s.source_id
                    WHERE s.status <> 'disabled'
                    GROUP BY s.source_id, s.name, s.added_at
                    ORDER BY s.added_at, s.source_id;
                    """
            )
            return rows.compactMap { row in
                guard let sourceId: String = row["source_id"],
                      let name: String = row["name"],
                      let itemCount: Int = row["item_count"] else {
                    return nil
                }
                return LibraryShelfSummary(
                    sourceId: sourceId,
                    name: name,
                    itemCount: itemCount
                )
            }
        }
    }

    // MARK: - Keyset-Paginated Library Grid (Design 01 §5.1, MD-11)

    /// Fetches a page of library grid items using keyset pagination.
    public func fetchLibraryGrid(
        sourceId: String? = nil,
        cursor: LibraryGridCursor? = nil,
        limit: Int = 60
    ) throws -> [LibraryGridItem] {
        try database.read { db in
            var sql = """
                SELECT f.file_id, f.path, f.match_state, f.duration_ms, f.source_id,
                       f.added_at,
                       COALESCE(m.title, s.title, f.path) AS display,
                       COALESCE(CAST(substr(m.release_date,1,4) AS INTEGER),
                                CAST(substr(s.first_air_date,1,4) AS INTEGER)) AS year,
                       COALESCE(m.rating_score, s.rating_score) AS rating,
                       EXISTS(
                           SELECT 1 FROM tracks t
                           WHERE t.file_id = f.file_id AND t.kind = 'video'
                             AND (t.width >= 3800 OR t.height >= 2100)
                       ) AS has_4k,
                       EXISTS(
                           SELECT 1 FROM tracks t
                           WHERE t.file_id = f.file_id AND t.kind = 'video'
                             AND (LOWER(COALESCE(t.hdr_format,'')) LIKE '%dolby%'
                                  OR LOWER(COALESCE(t.profile,'')) LIKE '%dv%')
                       ) AS has_dolby_vision,
                       EXISTS(
                           SELECT 1 FROM tracks t
                           WHERE t.file_id = f.file_id AND t.kind = 'audio'
                             AND (LOWER(COALESCE(t.channel_layout,'')) LIKE '%atmos%'
                                  OR (t.channels >= 8 AND t.codec IN ('truehd','eac3')))
                       ) AS has_atmos,
                       m.tmdb_id, s.show_id
                FROM media_files f
                LEFT JOIN movies m ON m.tmdb_id = f.matched_movie
                LEFT JOIN tv_shows s ON s.show_id = f.matched_show
                WHERE 1=1
                """
            var args: [DatabaseValueConvertible] = []

            if let sourceId {
                sql += " AND f.source_id = ?"
                args.append(sourceId)
            }

            if let cursor {
                sql += " AND (COALESCE(m.title, s.title, f.path) > ? OR (COALESCE(m.title, s.title, f.path) = ? AND f.file_id > ?))"
                args.append(cursor.displayTitle)
                args.append(cursor.displayTitle)
                args.append(cursor.fileId)
            }

            sql += " ORDER BY display, f.file_id LIMIT ?;"
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row in
                guard let fileId: String = row["file_id"],
                      let path: String = row["path"],
                      let matchStateStr: String = row["match_state"],
                      let matchState = MatchState(rawValue: matchStateStr),
                      let display: String = row["display"] else {
                    return nil
                }
                let durationMs: Int64? = row["duration_ms"]
                let tmdbId: Int? = row["tmdb_id"]
                let showId: String? = row["show_id"]
                let sourceId: String? = row["source_id"]
                let year: Int? = row["year"]
                let rating: Double? = row["rating"]
                let addedAt: Int64 = row["added_at"] ?? 0
                let has4K: Bool = row["has_4k"] ?? false
                let hasDolbyVision: Bool = row["has_dolby_vision"] ?? false
                let hasAtmos: Bool = row["has_atmos"] ?? false

                return LibraryGridItem(
                    fileId: fileId,
                    path: path,
                    matchState: matchState,
                    durationMs: durationMs,
                    displayTitle: display,
                    tmdbId: tmdbId,
                    showId: showId,
                    sourceId: sourceId,
                    year: year,
                    ratingScore: rating,
                    addedAt: addedAt,
                    has4K: has4K,
                    hasDolbyVision: hasDolbyVision,
                    hasAtmos: hasAtmos
                )
            }
        }
    }

    /// Fetches a keyset-paginated library page sorted by title, year, date
    /// added, or rating (MD-11, NFR-1).
    public func fetchLibraryGridPage(
        sourceId: String? = nil,
        sortedBy: LibrarySortOrder = .title,
        after cursor: LibrarySortCursor? = nil,
        limit: Int = 50
    ) throws -> [LibraryGridItem] {
        try database.read { db in
            let sortExpression: String
            switch sortedBy {
            case .title:
                sortExpression = "COALESCE(m.title, s.title, f.path) COLLATE NOCASE"
            case .year:
                sortExpression = """
                    printf('%010d', COALESCE(
                        CAST(substr(m.release_date,1,4) AS INTEGER),
                        CAST(substr(s.first_air_date,1,4) AS INTEGER),
                        0))
                    """
            case .dateAdded:
                sortExpression = "printf('%020lld', f.added_at)"
            case .rating:
                sortExpression = "printf('%08.3f', COALESCE(m.rating_score, s.rating_score, 0))"
            }

            var sql = """
                SELECT f.file_id, f.path, f.match_state, f.duration_ms, f.source_id,
                       f.added_at, \(sortExpression) AS sort_key,
                       COALESCE(m.title, s.title, f.path) AS display,
                       COALESCE(CAST(substr(m.release_date,1,4) AS INTEGER),
                                CAST(substr(s.first_air_date,1,4) AS INTEGER)) AS year,
                       COALESCE(m.rating_score, s.rating_score) AS rating,
                       EXISTS(
                           SELECT 1 FROM tracks t
                           WHERE t.file_id = f.file_id AND t.kind = 'video'
                             AND (t.width >= 3800 OR t.height >= 2100)
                       ) AS has_4k,
                       EXISTS(
                           SELECT 1 FROM tracks t
                           WHERE t.file_id = f.file_id AND t.kind = 'video'
                             AND (LOWER(COALESCE(t.hdr_format,'')) LIKE '%dolby%'
                                  OR LOWER(COALESCE(t.profile,'')) LIKE '%dv%')
                       ) AS has_dolby_vision,
                       EXISTS(
                           SELECT 1 FROM tracks t
                           WHERE t.file_id = f.file_id AND t.kind = 'audio'
                             AND (LOWER(COALESCE(t.channel_layout,'')) LIKE '%atmos%'
                                  OR (t.channels >= 8 AND t.codec IN ('truehd','eac3')))
                       ) AS has_atmos,
                       m.tmdb_id, s.show_id
                FROM media_files f
                LEFT JOIN movies m ON m.tmdb_id = f.matched_movie
                LEFT JOIN tv_shows s ON s.show_id = f.matched_show
                WHERE 1=1
                """
            var args: [DatabaseValueConvertible] = []

            if let sourceId {
                sql += " AND f.source_id = ?"
                args.append(sourceId)
            }

            if let cursor {
                let comparison = sortedBy.isDescending ? "<" : ">"
                sql += """
                     AND (sort_key \(comparison) ? OR (sort_key = ? AND f.file_id \(comparison) ?))
                    """
                args.append(cursor.sortKey)
                args.append(cursor.sortKey)
                args.append(cursor.fileId)
            }

            let direction = sortedBy.isDescending ? "DESC" : "ASC"
            sql += " ORDER BY sort_key \(direction), f.file_id \(direction) LIMIT ?;"
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row in
                guard let fileId: String = row["file_id"],
                      let path: String = row["path"],
                      let matchStateStr: String = row["match_state"],
                      let matchState = MatchState(rawValue: matchStateStr),
                      let display: String = row["display"] else {
                    return nil
                }
                let durationMs: Int64? = row["duration_ms"]
                let tmdbId: Int? = row["tmdb_id"]
                let showId: String? = row["show_id"]
                let sourceId: String? = row["source_id"]
                let year: Int? = row["year"]
                let rating: Double? = row["rating"]
                let addedAt: Int64 = row["added_at"] ?? 0
                let has4K: Bool = row["has_4k"] ?? false
                let hasDolbyVision: Bool = row["has_dolby_vision"] ?? false
                let hasAtmos: Bool = row["has_atmos"] ?? false

                return LibraryGridItem(
                    fileId: fileId,
                    path: path,
                    matchState: matchState,
                    durationMs: durationMs,
                    displayTitle: display,
                    tmdbId: tmdbId,
                    showId: showId,
                    sourceId: sourceId,
                    year: year,
                    ratingScore: rating,
                    addedAt: addedAt,
                    has4K: has4K,
                    hasDolbyVision: hasDolbyVision,
                    hasAtmos: hasAtmos
                )
            }
        }
    }

    /// Builds the cursor for the last item of a sorted page.
    public static func cursor(
        for item: LibraryGridItem,
        sortedBy: LibrarySortOrder
    ) -> LibrarySortCursor {
        let key: String
        switch sortedBy {
        case .title:
            key = item.displayTitle
        case .year:
            key = String(format: "%010d", item.year ?? 0)
        case .dateAdded:
            key = String(format: "%020lld", item.addedAt)
        case .rating:
            key = String(format: "%08.3f", item.ratingScore ?? 0)
        }
        return LibrarySortCursor(sortKey: key, fileId: item.fileId)
    }

    // MARK: - Continue Watching (Design 01 §5.2)

    /// Fetches Continue Watching row for a given account.
    public func fetchContinueWatching(account: String, limit: Int = 12) throws -> [ContinueWatchingItem] {
        try database.read { db in
            let sql = """
                SELECT w.entity_kind, w.entity_ref, w.position_ms, w.duration_ms, w.last_watched_at
                FROM watch_state w
                WHERE w.account = ? AND w.watched = 0 AND w.position_ms > 0
                ORDER BY w.last_watched_at DESC
                LIMIT ?;
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [account, limit])

            var results: [ContinueWatchingItem] = []
            for row in rows {
                guard let kindStr: String = row["entity_kind"],
                      let kind = EntityKind(rawValue: kindStr),
                      let entityRef: String = row["entity_ref"],
                      let positionMs: Int64 = row["position_ms"] else {
                    continue
                }
                let durationMs: Int64? = row["duration_ms"]
                let lastWatchedAt: Int64? = row["last_watched_at"]

                switch kind {
                case .movie:
                    if let tmdbId = Int(entityRef),
                       let movie = try MovieRecord.fetchOne(db, key: tmdbId) {
                        results.append(ContinueWatchingItem(
                            entityKind: .movie,
                            entityRef: entityRef,
                            title: movie.title,
                            positionMs: positionMs,
                            durationMs: durationMs ?? (movie.runtimeMin != nil ? Int64(movie.runtimeMin! * 60_000) : nil),
                            lastWatchedAt: lastWatchedAt
                        ))
                    }

                case .episode:
                    // Parsed ref: show_id:s<season>e<ep>
                    if let ref = EntityRef.parse(entityRef, kind: .episode),
                       case .episode(let showId, let sNum, let epNum) = ref {
                        let episode = try EpisodeRecord.fetchOne(
                            db,
                            key: ["show_id": showId, "season_number": sNum, "episode_number": epNum]
                        )
                        let show = try TVShowRecord.fetchOne(db, key: showId)
                        results.append(ContinueWatchingItem(
                            entityKind: .episode,
                            entityRef: entityRef,
                            title: episode?.title ?? "Episode \(epNum)",
                            showTitle: show?.title,
                            seasonNumber: sNum,
                            episodeNumber: epNum,
                            positionMs: positionMs,
                            durationMs: durationMs,
                            lastWatchedAt: lastWatchedAt
                        ))
                    }

                default:
                    break
                }
            }
            return results
        }
    }

    // MARK: - Next Unwatched Episode (Design 01 §5.3, MD-9)

    /// Finds the next unwatched episode for a show given an account.
    public func fetchNextUnwatchedEpisode(showId: String, account: String) throws -> EpisodeRecord? {
        try database.read { db in
            let sql = """
                SELECT e.*
                FROM episodes e
                LEFT JOIN watch_state w
                  ON w.account = ?
                 AND w.watched = 1
                 AND w.entity_kind = 'episode'
                 AND w.entity_ref = e.show_id || ':s' || e.season_number || 'e' || e.episode_number
                WHERE e.show_id = ?
                  AND w.entity_ref IS NULL
                ORDER BY e.air_date, e.season_number, e.episode_number
                LIMIT 1;
                """
            return try EpisodeRecord.fetchOne(db, sql: sql, arguments: [account, showId])
        }
    }

    // MARK: - Similar Titles / "More Like This" (Design 01 §5.7, DB-11)

    /// Fetches similar titles for an entity, ordered by rank.
    ///
    /// Only relations whose target still exists as a movie or TV show are
    /// returned, so stale rows never surface in the UI.
    public func fetchSimilar(to entity: EntityRef, limit: Int = 12) throws -> [SimilarTitleItem] {
        try database.read { db in
            let sql = """
                SELECT sim.sim_kind, sim.sim_ref, sim.rank,
                       COALESCE(m.title, s.title) AS display_title
                FROM similar sim
                LEFT JOIN movies m
                  ON sim.sim_kind = 'movie' AND CAST(m.tmdb_id AS TEXT) = sim.sim_ref
                LEFT JOIN tv_shows s
                  ON sim.sim_kind = 'show' AND s.show_id = sim.sim_ref
                WHERE sim.entity_kind = ? AND sim.entity_ref = ?
                ORDER BY sim.rank, sim.sim_ref
                LIMIT ?;
                """
            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: [entity.entityKind.rawValue, entity.rawValue, limit]
            )

            return rows.compactMap { row in
                guard let kindStr: String = row["sim_kind"],
                      let simKind = SimilarKind(rawValue: kindStr),
                      let entityRef: String = row["sim_ref"],
                      let title: String = row["display_title"],
                      let rank: Int = row["rank"] else {
                    return nil
                }

                switch simKind {
                case .movie:
                    return SimilarTitleItem(entityKind: .movie, entityRef: entityRef, title: title, rank: rank)
                case .show:
                    return SimilarTitleItem(entityKind: .show, entityRef: entityRef, title: title, rank: rank)
                case .person:
                    return nil
                }
            }
        }
    }

    // MARK: - Full-Text Search (Design 01 §5.4, NFR-1)

    /// Executes full-text search against the FTS5 search index.
    public func search(
        query: String,
        sourceId: String? = nil,
        limit: Int = 20
    ) throws -> [SearchResultItem] {
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }

        return try database.read { db in
            var sql: String
            var args: [DatabaseValueConvertible]

            if let sourceId {
                sql = """
                    SELECT s.entity_kind, s.entity_ref, s.title, s.overview, s.people_names, s.rank
                    FROM search_index s
                    WHERE search_index MATCH ?
                      AND (
                        (s.entity_kind = 'movie' AND CAST(s.entity_ref AS INTEGER) IN (
                            SELECT matched_movie FROM media_files WHERE source_id = ? AND matched_movie IS NOT NULL
                        ))
                        OR
                        (s.entity_kind = 'show' AND s.entity_ref IN (
                            SELECT matched_show FROM media_files WHERE source_id = ? AND matched_show IS NOT NULL
                        ))
                        OR
                        (s.entity_kind = 'episode' AND s.entity_ref IN (
                            SELECT matched_episode FROM media_files WHERE source_id = ? AND matched_episode IS NOT NULL
                        ))
                      )
                    ORDER BY s.rank
                    LIMIT ?;
                    """
                args = [sanitized, sourceId, sourceId, sourceId, limit]
            } else {
                sql = """
                    SELECT entity_kind, entity_ref, title, overview, people_names, rank
                    FROM search_index
                    WHERE search_index MATCH ?
                    ORDER BY rank
                    LIMIT ?;
                    """
                args = [sanitized, limit]
            }

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row in
                guard let kindStr: String = row["entity_kind"],
                      let kind = EntityKind(rawValue: kindStr),
                      let entityRef: String = row["entity_ref"],
                      let title: String = row["title"],
                      let rank: Double = row["rank"] else {
                    return nil
                }
                let overview: String? = row["overview"]
                let peopleNames: String? = row["people_names"]

                return SearchResultItem(
                    entityKind: kind,
                    entityRef: entityRef,
                    title: title,
                    overview: overview,
                    peopleNames: peopleNames,
                    rank: rank
                )
            }
        }
    }

    // MARK: - Unmatched / Needs Review List (Design 01 §5.5, MD-2)

    /// Fetches files that are unmatched or need review.
    public func fetchUnmatchedFiles(
        sourceId: String? = nil,
        limit: Int = 100
    ) throws -> [MediaFileRecord] {
        try database.read { db in
            var query = MediaFileRecord.filter(MediaFileRecord.Columns.matchState != MatchState.matched.rawValue)
            if let sourceId {
                query = query.filter(MediaFileRecord.Columns.sourceId == sourceId)
            }
            return try query
                .order(MediaFileRecord.Columns.addedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Cast & Crew (Design 01 §5.6, doc 05 §2)

    /// Fetches credits with joined person name and headshot artwork.
    public func fetchCastAndCrew(
        entityKind: EntityKind,
        entityRef: String
    ) throws -> [CreditDetailItem] {
        try database.read { db in
            let sql = """
                SELECT c.credit_role, c.character, c.job, c.ord, p.name, p.person_id,
                       a.local_path AS headshot
                FROM credits c
                JOIN people p USING (person_id)
                LEFT JOIN artwork a
                  ON a.entity_kind = 'person'
                 AND a.entity_ref = p.person_id
                 AND a.kind = 'profile'
                 AND a.variant = 'w185'
                 AND a.local_path IS NOT NULL
                WHERE c.entity_kind = ? AND c.entity_ref = ?
                ORDER BY c.ord;
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [entityKind.rawValue, entityRef])
            return rows.compactMap { row in
                guard let roleStr: String = row["credit_role"],
                      let role = CreditRole(rawValue: roleStr),
                      let ord: Int = row["ord"],
                      let name: String = row["name"],
                      let personId: String = row["person_id"] else {
                    return nil
                }
                let character: String? = row["character"]
                let job: String? = row["job"]
                let headshot: String? = row["headshot"]

                return CreditDetailItem(
                    creditRole: role,
                    character: character,
                    job: job,
                    ord: ord,
                    name: name,
                    personId: personId,
                    headshotPath: headshot
                )
            }
        }
    }

    // MARK: - Smart Library Evaluation (Design 01 §5.8)

    /// Evaluates a smart library filter returning matching media files.
    public func fetchSmartLibraryFiles(
        filter: SmartLibraryFilter,
        limit: Int = 100
    ) throws -> [MediaFileRecord] {
        let (whereClause, arguments, joins) = filter.compile()
        return try database.read { db in
            var sql = "SELECT DISTINCT f.* FROM media_files f"
            if !joins.isEmpty {
                sql += " " + joins.joined(separator: " ")
            }
            if !whereClause.isEmpty {
                sql += " WHERE " + whereClause
            }
            sql += " LIMIT \(limit);"

            return try MediaFileRecord.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    // MARK: - Private Query Helpers

    /// Formats search text into quoted FTS5 prefix tokens (e.g. `foo bar` -> `"foo"* "bar"*`)
    private func sanitizeFTSQuery(_ raw: String) -> String {
        let tokens = raw.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }
}
