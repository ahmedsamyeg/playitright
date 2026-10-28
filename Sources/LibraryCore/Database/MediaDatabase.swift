import Foundation
import GRDB

public enum MediaDatabaseError: Error, LocalizedError {
    case corruptionDetected(String)
    case backupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .corruptionDetected(let message):
            return "Database corruption detected: \(message)"
        case .backupFailed(let message):
            return "Backup failed: \(message)"
        }
    }
}

/// The core media database coordinator.
///
/// Encapsulates:
/// - One serial writer `DatabaseQueue` (doc 02 §6)
/// - Reader `DatabasePool` (or in-memory queue for tests)
/// - Full WAL & PRAGMA configuration (Design 01 §2)
/// - Startup checks (quick_check & consistency scan) (Design 01 §6.2)
/// - Rolling backups and optimization (Design 01 §6.4, §6.5)
/// - `IndexChangeEvent` async stream for UI models
public final class MediaDatabase: Sendable {
    public let configuration: MediaDatabaseConfiguration
    public let databaseURL: URL?

    private let writerQueue: DatabaseQueue
    private let readerHandle: any DatabaseReader

    private let (changeStream, changeContinuation) = AsyncStream<IndexChangeEvent>.makeStream()

    /// Async stream of index changes
    public var changeEvents: AsyncStream<IndexChangeEvent> {
        changeStream
    }

    /// Direct access to writer connection queue
    public var writer: DatabaseQueue {
        writerQueue
    }

    /// Direct access to reader pool / reader handle
    public var reader: any DatabaseReader {
        readerHandle
    }

    // MARK: - Initializers

    /// Opens or creates the database at the specified file URL.
    public static func open(
        at url: URL = MediaDatabaseConfiguration.defaultDatabaseURL,
        configuration: MediaDatabaseConfiguration = MediaDatabaseConfiguration()
    ) throws -> MediaDatabase {
        // Ensure parent directory exists
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var writerConfig = Configuration()
        writerConfig.foreignKeysEnabled = true
        writerConfig.busyMode = .timeout(configuration.busyTimeout)
        writerConfig.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA synchronous = NORMAL;")
            try db.execute(sql: "PRAGMA cache_size = -\(configuration.cacheSizeInKiB);")
        }

        let writer = try DatabaseQueue(path: url.path, configuration: writerConfig)
        try DatabaseMigrations.migrator.migrate(writer)

        var readerConfig = Configuration()
        readerConfig.readonly = true
        readerConfig.busyMode = .timeout(configuration.busyTimeout)
        readerConfig.foreignKeysEnabled = true
        readerConfig.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL;")
            try db.execute(sql: "PRAGMA cache_size = -\(configuration.cacheSizeInKiB);")
        }

        let readerPool = try DatabasePool(path: url.path, configuration: readerConfig)

        return MediaDatabase(
            writer: writer,
            reader: readerPool,
            databaseURL: url,
            configuration: configuration
        )
    }

    /// Creates an in-memory database for testing or ephemeral operations.
    public static func inMemory(
        configuration: MediaDatabaseConfiguration = MediaDatabaseConfiguration()
    ) throws -> MediaDatabase {
        var writerConfig = Configuration()
        writerConfig.foreignKeysEnabled = true
        writerConfig.busyMode = .timeout(configuration.busyTimeout)
        writerConfig.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL;")
            try db.execute(sql: "PRAGMA cache_size = -\(configuration.cacheSizeInKiB);")
        }

        let writer = try DatabaseQueue(configuration: writerConfig)
        try DatabaseMigrations.migrator.migrate(writer)

        return MediaDatabase(
            writer: writer,
            reader: writer,
            databaseURL: nil,
            configuration: configuration
        )
    }

    private init(
        writer: DatabaseQueue,
        reader: any DatabaseReader,
        databaseURL: URL?,
        configuration: MediaDatabaseConfiguration
    ) {
        self.writerQueue = writer
        self.readerHandle = reader
        self.databaseURL = databaseURL
        self.configuration = configuration
    }

    // MARK: - Read & Write Operations

    /// Executes a read transaction on the reader pool.
    public func read<T: Sendable>(_ block: (Database) throws -> T) throws -> T {
        try readerHandle.read(block)
    }

    /// Executes a write transaction on the serial writer queue.
    public func write<T: Sendable>(_ block: (Database) throws -> T) throws -> T {
        try writerQueue.write(block)
    }

    /// Notifies observers of a committed index change.
    public func emitChange(_ event: IndexChangeEvent) {
        changeContinuation.yield(event)
    }

    // MARK: - Startup Checks & Integrity

    /// Runs `PRAGMA quick_check`. Throws `MediaDatabaseError.corruptionDetected` if corrupted.
    @discardableResult
    public func runQuickCheck() throws -> Bool {
        try readerHandle.read { db in
            let row = try Row.fetchOne(db, sql: "PRAGMA quick_check;")
            guard let result = row?[0] as? String else {
                throw MediaDatabaseError.corruptionDetected("No quick_check result returned")
            }
            if result.lowercased() == "ok" {
                return true
            } else {
                throw MediaDatabaseError.corruptionDetected(result)
            }
        }
    }

    /// Performs the startup consistency scan (Design 01 §6.2):
    /// Compares search_index row count with total entities.
    /// If counts diverge, automatically triggers a search_index rebuild.
    @discardableResult
    public func performStartupConsistencyScan() throws -> Bool {
        let (ftsCount, entityCount) = try readerHandle.read { db -> (Int, Int) in
            let fts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index;") ?? 0
            let movies = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM movies;") ?? 0
            let shows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tv_shows;") ?? 0
            let episodes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM episodes;") ?? 0
            let people = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM people;") ?? 0
            return (fts, movies + shows + episodes + people)
        }

        if ftsCount != entityCount {
            try rebuildSearchIndex()
            return false // was diverged, now repaired
        }
        return true
    }

    /// Rebuilds the unified FTS5 search index completely from the canonical source tables in one transaction.
    public func rebuildSearchIndex() throws {
        try writerQueue.write { db in
            try db.execute(sql: "DELETE FROM search_index;")

            // Movies
            try db.execute(sql: """
                INSERT INTO search_index (entity_kind, entity_ref, title, alt_titles, overview, people_names)
                SELECT
                    'movie',
                    CAST(m.tmdb_id AS TEXT),
                    m.title,
                    m.alternative_titles,
                    m.overview,
                    (
                        SELECT GROUP_CONCAT(p.name, ', ')
                        FROM credits c
                        JOIN people p USING (person_id)
                        WHERE c.entity_kind = 'movie' AND c.entity_ref = CAST(m.tmdb_id AS TEXT)
                    )
                FROM movies m;
                """)

            // Shows
            try db.execute(sql: """
                INSERT INTO search_index (entity_kind, entity_ref, title, alt_titles, overview, people_names)
                SELECT
                    'show',
                    s.show_id,
                    s.title,
                    s.alternative_titles,
                    s.overview,
                    (
                        SELECT GROUP_CONCAT(p.name, ', ')
                        FROM credits c
                        JOIN people p USING (person_id)
                        WHERE c.entity_kind = 'show' AND c.entity_ref = s.show_id
                    )
                FROM tv_shows s;
                """)

            // Episodes
            try db.execute(sql: """
                INSERT INTO search_index (entity_kind, entity_ref, title, alt_titles, overview, people_names)
                SELECT
                    'episode',
                    e.show_id || ':s' || e.season_number || 'e' || e.episode_number,
                    e.title,
                    NULL,
                    e.overview,
                    (
                        SELECT GROUP_CONCAT(p.name, ', ')
                        FROM credits c
                        JOIN people p USING (person_id)
                        WHERE c.entity_kind = 'episode'
                          AND c.entity_ref = e.show_id || ':s' || e.season_number || 'e' || e.episode_number
                    )
                FROM episodes e;
                """)

            // People
            try db.execute(sql: """
                INSERT INTO search_index (entity_kind, entity_ref, title, alt_titles, overview, people_names)
                SELECT
                    'person',
                    p.person_id,
                    p.name,
                    NULL,
                    p.biography,
                    NULL
                FROM people p;
                """)

            // Optimize FTS index structures
            try db.execute(sql: "INSERT INTO search_index(search_index) VALUES('optimize');")
        }
    }

    // MARK: - Backups & Maintenance

    /// Creates a non-blocking snapshot backup into the target file URL using `VACUUM INTO`.
    public func createBackup(to destinationURL: URL) throws {
        try writerQueue.writeWithoutTransaction { db in
            let escapedPath = destinationURL.path.replacingOccurrences(of: "'", with: "''")
            try db.execute(sql: "VACUUM INTO '\(escapedPath)';")
        }
    }

    /// Performs rolling backup into the specified or default backups directory (Design 01 §6.4).
    /// Maintains up to `configuration.maxBackupGenerations` generations, evicting older ones.
    @discardableResult
    public func performRollingBackup(
        toBackupDirectory directory: URL = MediaDatabaseConfiguration.defaultBackupsDirectory
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let timestamp = Int64(Date().timeIntervalSince1970)
        let backupFile = directory.appendingPathComponent("library-\(timestamp).db")

        try createBackup(to: backupFile)

        // Prune older backups beyond maxBackupGenerations
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )

        let backupFiles = contents.filter { $0.lastPathComponent.hasPrefix("library-") && $0.pathExtension == "db" }
            .sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return date1 > date2
            }

        if backupFiles.count > configuration.maxBackupGenerations {
            for oldFile in backupFiles.dropFirst(configuration.maxBackupGenerations) {
                try? fileManager.removeItem(at: oldFile)
            }
        }

        return backupFile
    }

    /// Runs `PRAGMA optimize` on the database (called on app suspend, Design 01 §6.5).
    public func optimize() throws {
        try writerQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA optimize;")
        }
    }
}
