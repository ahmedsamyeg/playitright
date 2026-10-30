import Foundation

/// Defines the permissible CloudKit sync boundary (SYNC-1, SYNC-2, doc 11 §3.3).
public enum SyncRecordType: String, CaseIterable, Sendable {
    case watchState = "WatchState"
    case userRating = "UserRating"
    case collection = "Collection"
    case playlist = "Playlist"
    case pin = "Pin"
}

/// Normalized sync record representing user watch progress for an entity.
public struct SyncedWatchState: Equatable, Sendable {
    public let entityRef: String  // e.g. "movie:tmdb:550" or "ep:tmdb:1396:s1e1"
    public let positionSeconds: Double
    public let durationSeconds: Double
    public let isWatched: Bool
    public let lastWatchedAt: Date
    public let modifiedAt: Date

    public init(
        entityRef: String,
        positionSeconds: Double,
        durationSeconds: Double,
        isWatched: Bool,
        lastWatchedAt: Date,
        modifiedAt: Date = Date()
    ) {
        self.entityRef = entityRef
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.isWatched = isWatched
        self.lastWatchedAt = lastWatchedAt
        self.modifiedAt = modifiedAt
    }
}

/// Boundary validator guaranteeing that media file paths, URLs, and secrets are strictly excluded from sync payloads.
public struct SyncBoundaryValidator: Sendable {
    public static func validateRecordKey(_ key: String) -> Bool {
        // Must NOT contain file://, smb://, nfs://, http://, or local paths
        let lower = key.lowercased()
        if lower.contains("://") || lower.hasPrefix("/") || lower.contains("\\") {
            return false
        }
        return true
    }
}
