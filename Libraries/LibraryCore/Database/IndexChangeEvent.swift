import Foundation

/// Emitted after writer commits to notify UI and observing models of index changes.
public struct IndexChangeEvent: Sendable, Equatable {
    public let tables: Set<String>
    public let added: Int
    public let updated: Int
    public let removed: Int
    public let timestamp: Date

    public init(
        tables: Set<String>,
        added: Int = 0,
        updated: Int = 0,
        removed: Int = 0,
        timestamp: Date = Date()
    ) {
        self.tables = tables
        self.added = added
        self.updated = updated
        self.removed = removed
        self.timestamp = timestamp
    }
}
