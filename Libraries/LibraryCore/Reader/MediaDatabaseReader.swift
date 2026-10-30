import Foundation
import GRDB

public final class MediaDatabaseReader: Sendable {
    public let database: MediaDatabase

    public init(database: MediaDatabase) {
        self.database = database
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
                SELECT f.file_id, f.path, f.match_state, f.duration_ms,
                       COALESCE(m.title, s.title, f.path) AS display,
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

                return LibraryGridItem(
                    fileId: fileId,
                    path: path,
                    matchState: matchState,
                    durationMs: durationMs,
                    displayTitle: display,
                    tmdbId: tmdbId,
                    showId: showId
                )
            }
        }
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
