import Foundation

/// Resolved environment configuration for PlayItRight data layer and services.
public struct EnvironmentConfiguration: Sendable, Equatable {
    public let environment: AppEnvironment
    public let variables: [String: String]

    public init(
        environment: AppEnvironment = .current,
        variables: [String: String]? = nil,
        searchDirectory: URL? = nil
    ) {
        self.environment = environment
        if let variables {
            self.variables = variables
        } else {
            let dir = searchDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            self.variables = DotEnv.load(environment: environment, directory: dir)
        }
    }

    /// Whether the configured database should run in-memory (e.g. for unit tests)
    public var isInMemoryDatabase: Bool {
        let explicit = (variables["PLAYITRIGHT_DB_PATH"] ?? variables["DATABASE_PATH"])?.lowercased()
        if explicit == ":memory:" {
            return true
        }
        if explicit == nil && environment == .testing {
            return true
        }
        return false
    }

    /// Resolved file URL for the database (nil if in-memory)
    public var databaseURL: URL? {
        if isInMemoryDatabase {
            return nil
        }

        if let explicit = variables["PLAYITRIGHT_DB_PATH"] ?? variables["DATABASE_PATH"] {
            return URL(fileURLWithPath: explicit)
        }

        switch environment {
        case .development:
            let devDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("db", isDirectory: true)
                .appendingPathComponent("dev", isDirectory: true)
            return devDir.appendingPathComponent("library.db")

        case .testing:
            let testDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("db", isDirectory: true)
                .appendingPathComponent("test", isDirectory: true)
            return testDir.appendingPathComponent("library.db")

        case .production:
            return MediaDatabaseConfiguration.defaultDatabaseURL
        }
    }

    /// Resolved backups directory
    public var backupsDirectory: URL {
        if let explicit = variables["PLAYITRIGHT_BACKUP_DIR"] ?? variables["BACKUP_DIR"] {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }

        switch environment {
        case .development:
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("db", isDirectory: true)
                .appendingPathComponent("dev", isDirectory: true)
                .appendingPathComponent("backups", isDirectory: true)

        case .testing:
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("PlayItRightTestBackups", isDirectory: true)

        case .production:
            return MediaDatabaseConfiguration.defaultBackupsDirectory
        }
    }

    /// Resolved artwork cache directory
    public var artworkDirectory: URL {
        if let explicit = variables["PLAYITRIGHT_ARTWORK_DIR"] ?? variables["ARTWORK_DIR"] {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }

        switch environment {
        case .development:
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("db", isDirectory: true)
                .appendingPathComponent("dev", isDirectory: true)
                .appendingPathComponent("artwork", isDirectory: true)

        case .testing:
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("PlayItRightTestArtwork", isDirectory: true)

        case .production:
            return MediaDatabaseConfiguration.defaultArtworkDirectory
        }
    }

    /// Busy timeout in seconds
    public var busyTimeout: TimeInterval {
        if let explicit = variables["PLAYITRIGHT_BUSY_TIMEOUT"],
           let val = Double(explicit) {
            return val
        }
        return 5.0
    }

    /// SQLite cache size in KiB
    public var cacheSizeInKiB: Int {
        if let explicit = variables["PLAYITRIGHT_CACHE_SIZE_KB"],
           let val = Int(explicit) {
            return val
        }
        return 8192
    }

    /// Maximum rolling backup generations
    public var maxBackupGenerations: Int {
        if let explicit = variables["PLAYITRIGHT_MAX_BACKUP_GENS"],
           let val = Int(explicit) {
            return val
        }
        return 2
    }

    /// Produces a MediaDatabaseConfiguration reflecting this environment's settings
    public func makeDatabaseConfiguration() -> MediaDatabaseConfiguration {
        MediaDatabaseConfiguration(
            busyTimeout: busyTimeout,
            cacheSizeInKiB: cacheSizeInKiB,
            maxBackupGenerations: maxBackupGenerations
        )
    }
}
