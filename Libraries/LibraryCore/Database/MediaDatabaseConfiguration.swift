import Foundation

public struct MediaDatabaseConfiguration: Sendable {
    public var busyTimeout: TimeInterval
    public var cacheSizeInKiB: Int
    public var maxBackupGenerations: Int
    public var backupInterval: TimeInterval // default 24 hours

    public init(
        busyTimeout: TimeInterval = 5.0,
        cacheSizeInKiB: Int = 8192,
        maxBackupGenerations: Int = 2,
        backupInterval: TimeInterval = 24 * 3600
    ) {
        self.busyTimeout = busyTimeout
        self.cacheSizeInKiB = cacheSizeInKiB
        self.maxBackupGenerations = maxBackupGenerations
        self.backupInterval = backupInterval
    }

    /// Default application support base directory for PlayItRight
    public static var defaultBaseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent("PlayItRight", isDirectory: true)
    }

    /// Default database file URL (`Application Support/PlayItRight/library.db`)
    public static var defaultDatabaseURL: URL {
        defaultBaseDirectory.appendingPathComponent("library.db")
    }

    /// Default backups directory (`Application Support/PlayItRight/Backups`)
    public static var defaultBackupsDirectory: URL {
        defaultBaseDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    /// Default artwork directory (`Application Support/PlayItRight/Artwork`)
    public static var defaultArtworkDirectory: URL {
        defaultBaseDirectory.appendingPathComponent("Artwork", isDirectory: true)
    }
}
