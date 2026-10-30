import Testing
import GRDB
@testable import LibraryCore

@Suite("Schema & Migration Tests")
struct MigrationTests {
    private func makeTestDatabase() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(configuration: config)
        try DatabaseMigrations.migrator.migrate(dbQueue)
        return dbQueue
    }

    @Test("Migrator creates schema and meta table successfully")
    func schemaCreated() throws {
        let dbQueue = try makeTestDatabase()

        try dbQueue.read { db in
            let metaRecord = try MetaRecord.fetchOne(db, key: "schema_created_at")
            #expect(metaRecord != nil)
            #expect(metaRecord?.key == "schema_created_at")
            #expect(Int64(metaRecord?.value ?? "") != nil)

            // Verify tables exist
            let tables = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;"
            )
            let expectedTables = [
                "accounts", "artwork", "collection_items", "collections", "credits",
                "episodes", "genres", "identifiers", "libraries", "media_files",
                "media_genres", "meta", "movies", "people", "playlist_items",
                "playlists", "pins", "seasons", "similar", "smart_libraries",
                "sources", "tracks", "tv_shows", "watch_state"
            ]
            for table in expectedTables {
                #expect(tables.contains(table), "Expected table \(table) was not found")
            }
        }
    }

    @Test("MediaFiles XOR constraint enforcement on matched status")
    func mediaFilesMatchConstraint() throws {
        let dbQueue = try makeTestDatabase()

        try dbQueue.write { db in
            let source = SourceRecord(sourceId: "s1", kind: .local, name: "Local Disk", configRef: "ref1")
            try source.insert(db)

            let movie = MovieRecord(tmdbId: 100, title: "Inception")
            try movie.insert(db)

            let show = TVShowRecord(showId: "tmdb:200", title: "Breaking Bad")
            try show.insert(db)

            let episode = EpisodeRecord(showId: "tmdb:200", seasonNumber: 1, episodeNumber: 1, title: "Pilot")
            try episode.insert(db)

            // 1. Unmatched with no targets: valid
            let file1 = MediaFileRecord(
                fileId: "f1",
                sourceId: "s1",
                path: "/movies/f1.mkv",
                uri: "file:///movies/f1.mkv",
                matchState: .unmatched
            )
            try file1.insert(db)

            // 2. Matched with movie target: valid
            let file2 = MediaFileRecord(
                fileId: "f2",
                sourceId: "s1",
                path: "/movies/f2.mkv",
                uri: "file:///movies/f2.mkv",
                matchState: .matched,
                matchedMovie: 100
            )
            try file2.insert(db)

            // 3. Matched with episode target: valid
            let file3 = MediaFileRecord(
                fileId: "f3",
                sourceId: "s1",
                path: "/shows/f3.mkv",
                uri: "file:///shows/f3.mkv",
                matchState: .matched,
                matchedEpisode: "tmdb:200:s1e1",
                matchedShow: "tmdb:200"
            )
            try file3.insert(db)

            // 4. Matched but missing both targets: must FAIL
            let fileInvalidNoTarget = MediaFileRecord(
                fileId: "f4",
                sourceId: "s1",
                path: "/movies/f4.mkv",
                uri: "file:///movies/f4.mkv",
                matchState: .matched
            )
            #expect(throws: Error.self) {
                try fileInvalidNoTarget.insert(db)
            }

            // 5. Matched with BOTH movie and episode: must FAIL (XOR constraint)
            let fileInvalidBothTargets = MediaFileRecord(
                fileId: "f5",
                sourceId: "s1",
                path: "/movies/f5.mkv",
                uri: "file:///movies/f5.mkv",
                matchState: .matched,
                matchedMovie: 100,
                matchedEpisode: "tmdb:200:s1e1"
            )
            #expect(throws: Error.self) {
                try fileInvalidBothTargets.insert(db)
            }

            // 6. Unmatched but having movie target: must FAIL (state is unmatched)
            let fileInvalidUnmatchedWithTarget = MediaFileRecord(
                fileId: "f6",
                sourceId: "s1",
                path: "/movies/f6.mkv",
                uri: "file:///movies/f6.mkv",
                matchState: .unmatched,
                matchedMovie: 100
            )
            #expect(throws: Error.self) {
                try fileInvalidUnmatchedWithTarget.insert(db)
            }
        }
    }

    @Test("Foreign key cascade deletions")
    func foreignKeyCascades() throws {
        let dbQueue = try makeTestDatabase()

        try dbQueue.write { db in
            let source = SourceRecord(sourceId: "s1", kind: .smb, name: "NAS", configRef: "nas_ref")
            try source.insert(db)

            let file = MediaFileRecord(
                fileId: "f1",
                sourceId: "s1",
                path: "NAS/movie.mp4",
                uri: "smb://nas/movie.mp4"
            )
            try file.insert(db)

            let track = TrackRecord(fileId: "f1", kind: .video, index: 0, codec: "h264")
            try track.insert(db)

            let collection = CollectionRecord(id: "col1", name: "Favorites", ord: 0)
            try collection.insert(db)

            let colItem = CollectionItemRecord(
                collectionId: "col1",
                entityKind: .movie,
                entityRef: "100",
                fileId: "f1"
            )
            try colItem.insert(db)

            // Verify file and track exist
            #expect(try MediaFileRecord.fetchOne(db, key: "f1") != nil)
            #expect(try TrackRecord.fetchOne(db, key: ["file_id": "f1", "kind": "video", "index": 0]) != nil)

            // Delete source: should cascade-delete file and track
            _ = try SourceRecord.deleteOne(db, key: "s1")

            #expect(try MediaFileRecord.fetchOne(db, key: "f1") == nil)
            #expect(try TrackRecord.fetchOne(db, key: ["file_id": "f1", "kind": "video", "index": 0]) == nil)

            // And collection_items.file_id should be SET NULL
            let fetchedColItem = try CollectionItemRecord.fetchOne(
                db,
                key: ["collection_id": "col1", "entity_kind": "movie", "entity_ref": "100"]
            )
            #expect(fetchedColItem != nil)
            #expect(fetchedColItem?.fileId == nil)
        }
    }

    @Test("TV Show cascade delete cascades to seasons and episodes")
    func showCascade() throws {
        let dbQueue = try makeTestDatabase()

        try dbQueue.write { db in
            let show = TVShowRecord(showId: "tmdb:10", title: "Show")
            try show.insert(db)

            let season = SeasonRecord(showId: "tmdb:10", seasonNumber: 1, title: "Season 1")
            try season.insert(db)

            let ep = EpisodeRecord(showId: "tmdb:10", seasonNumber: 1, episodeNumber: 1, title: "Ep 1")
            try ep.insert(db)

            _ = try TVShowRecord.deleteOne(db, key: "tmdb:10")

            #expect(try SeasonRecord.fetchOne(db, key: ["show_id": "tmdb:10", "season_number": 1]) == nil)
            #expect(try EpisodeRecord.fetchOne(
                db,
                key: ["show_id": "tmdb:10", "season_number": 1, "episode_number": 1]
            ) == nil)
        }
    }

    @Test("FTS5 table insertion and MATCH query")
    func searchIndex() throws {
        let dbQueue = try makeTestDatabase()

        try dbQueue.write { db in
            let entry = SearchIndexRecord(
                entityKind: .movie,
                entityRef: "550",
                title: "Fight Club",
                altTitles: "El Club de la Pelea",
                overview: "An insomniac office worker and a devil-may-care soap maker form an underground fight club.",
                peopleNames: "Brad Pitt, Edward Norton, David Fincher"
            )
            try entry.insert(db)

            let results = try Row.fetchAll(
                db,
                sql: """
                SELECT entity_kind, entity_ref, rank
                FROM search_index
                WHERE search_index MATCH 'insomniac*'
                ORDER BY rank;
                """
            )
            #expect(results.count == 1)
            #expect(results.first?["entity_ref"] == "550")
        }
    }
}
