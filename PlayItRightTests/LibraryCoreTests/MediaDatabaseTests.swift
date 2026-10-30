import Testing
import Foundation
import GRDB
@testable import LibraryCore

@Suite("MediaDatabase Engine Tests")
struct MediaDatabaseTests {
    @Test("In-memory MediaDatabase initialization and read-write")
    func inMemoryDatabase() throws {
        let database = try MediaDatabase.inMemory()

        try database.write { db in
            let movie = MovieRecord(tmdbId: 42, title: "Hitchhiker")
            try movie.insert(db)
        }

        let fetched = try database.read { db in
            try MovieRecord.fetchOne(db, key: 42)
        }
        #expect(fetched?.title == "Hitchhiker")
        #expect(try database.runQuickCheck() == true)
    }

    @Test("File-based MediaDatabase with WAL mode and concurrent reads")
    func fileBasedDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("library.db")
        let database = try MediaDatabase.open(at: dbURL)

        try database.write { db in
            let show = TVShowRecord(showId: "tmdb:100", title: "Test TV Show")
            try show.insert(db)
        }

        let show = try database.read { db in
            try TVShowRecord.fetchOne(db, key: "tmdb:100")
        }
        #expect(show?.title == "Test TV Show")
        #expect(try database.runQuickCheck() == true)

        // Verify WAL files exist
        let walURL = tempDir.appendingPathComponent("library.db-wal")
        #expect(FileManager.default.fileExists(atPath: walURL.path))
    }

    @Test("Consistency scan detects divergence and rebuilds FTS")
    func consistencyScanAndFTSRebuild() throws {
        let database = try MediaDatabase.inMemory()

        // Insert movie, TV show, and person into DB without search_index entries
        try database.write { db in
            let movie = MovieRecord(
                tmdbId: 550,
                title: "Fight Club",
                overview: "A movie about underground fighting."
            )
            try movie.insert(db)

            let person = PersonRecord(
                personId: "tmdb:287",
                name: "Brad Pitt"
            )
            try person.insert(db)

            let credit = CreditRecord(
                entityKind: .movie,
                entityRef: "550",
                personId: "tmdb:287",
                creditRole: .actor,
                character: "Tyler Durden",
                ord: 0
            )
            try credit.insert(db)
        }

        // Before scan: FTS count is 0, entity count is 2 (1 movie + 1 person)
        let ftsCountBefore = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index;") ?? 0
        }
        #expect(ftsCountBefore == 0)

        // Run consistency scan - should return false because it found divergence and repaired it
        let wasClean = try database.performStartupConsistencyScan()
        #expect(wasClean == false)

        // Now FTS count should match entities (2)
        let ftsCountAfter = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index;") ?? 0
        }
        #expect(ftsCountAfter == 2)

        // Verify FTS search matches
        let (entityRef, peopleNames) = try database.read { db -> (String?, String?) in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT entity_ref, people_names FROM search_index WHERE search_index MATCH 'Tyler*' OR search_index MATCH 'Pitt*';"
            )
            return (row?["entity_ref"], row?["people_names"])
        }
        #expect(entityRef == "550")
        #expect(peopleNames == "Brad Pitt")

        // Second run of scan should be clean
        let wasCleanSecond = try database.performStartupConsistencyScan()
        #expect(wasCleanSecond == true)
    }

    @Test("Snapshot backup and rolling backup generation management")
    func rollingBackup() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("library.db")
        let backupsDir = tempDir.appendingPathComponent("Backups")

        var config = MediaDatabaseConfiguration()
        config.maxBackupGenerations = 2
        let database = try MediaDatabase.open(at: dbURL, configuration: config)

        try database.write { db in
            let movie = MovieRecord(tmdbId: 1, title: "Backup Test Movie")
            try movie.insert(db)
        }

        // First backup
        let b1 = try database.performRollingBackup(toBackupDirectory: backupsDir)
        #expect(FileManager.default.fileExists(atPath: b1.path))

        // Open backup file to verify data integrity
        let backupQueue = try DatabaseQueue(path: b1.path)
        let fetchedMovie = try backupQueue.read { db in
            try MovieRecord.fetchOne(db, key: 1)
        }
        #expect(fetchedMovie?.title == "Backup Test Movie")

        // Create 2nd backup
        Thread.sleep(forTimeInterval: 1.1)
        _ = try database.performRollingBackup(toBackupDirectory: backupsDir)

        // Create 3rd backup -> should evict the oldest, keeping only 2
        Thread.sleep(forTimeInterval: 1.1)
        _ = try database.performRollingBackup(toBackupDirectory: backupsDir)

        let files = try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)
            .filter { $0.hasPrefix("library-") && $0.hasSuffix(".db") }
        #expect(files.count == 2)

        // Test optimize
        try database.optimize()
    }

    @Test("Change events emission")
    func changeEvents() async throws {
        let database = try MediaDatabase.inMemory()

        let task = Task { () -> IndexChangeEvent in
            for await event in database.changeEvents {
                return event
            }
            throw MediaDatabaseError.backupFailed("Stream ended prematurely")
        }

        database.emitChange(IndexChangeEvent(tables: ["movies"], added: 1))

        let receivedEvent = try await task.value
        #expect(receivedEvent.tables.contains("movies"))
        #expect(receivedEvent.added == 1)
    }
}
