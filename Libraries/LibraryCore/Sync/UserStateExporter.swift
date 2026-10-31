import Foundation
import GRDB

/// A portable snapshot of the user-state layer.
///
/// The export contains watch progress, ratings, collections, playlists, pins,
/// and preferences. It deliberately excludes provider rows, media files, raw
/// source paths, artwork, and credentials (SYNC-1, NFR-12).
public struct UserStateExport: Codable, Sendable, Equatable {
    /// Increment when the on-disk format changes incompatibly.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let exportedAt: Int64
    public let accounts: [AccountRecord]
    public let watchStates: [WatchStateRecord]
    public let collections: [CollectionRecord]
    public let collectionItems: [CollectionItemRecord]
    public let playlists: [PlaylistRecord]
    public let playlistItems: [PlaylistItemRecord]
    public let pins: [PinRecord]
    public let preferences: [String: String]

    public init(
        schemaVersion: Int = UserStateExport.currentSchemaVersion,
        exportedAt: Int64,
        accounts: [AccountRecord] = [],
        watchStates: [WatchStateRecord] = [],
        collections: [CollectionRecord] = [],
        collectionItems: [CollectionItemRecord] = [],
        playlists: [PlaylistRecord] = [],
        playlistItems: [PlaylistItemRecord] = [],
        pins: [PinRecord] = [],
        preferences: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.accounts = accounts
        self.watchStates = watchStates
        self.collections = collections
        self.collectionItems = collectionItems
        self.playlists = playlists
        self.playlistItems = playlistItems
        self.pins = pins
        self.preferences = preferences
    }

    /// Encodes the snapshot as JSON for manual/AirDrop migration.
    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a snapshot from JSON.
    public static func decode(from data: Data) throws -> UserStateExport {
        try JSONDecoder().decode(UserStateExport.self, from: data)
    }
}

/// Reads the user-state layer into a portable snapshot.
public struct UserStateExporter: Sendable {
    private let database: MediaDatabase

    public init(database: MediaDatabase) {
        self.database = database
    }

    /// Builds an in-memory snapshot.
    ///
    /// Rows referencing local media files or artwork are emitted with those
    /// references stripped so the file can move between devices safely.
    public func export(now: Date = Date()) throws -> UserStateExport {
        let exportedAt = Int64(now.timeIntervalSince1970 * 1000)

        return try database.reader.read { db in
            let accounts = try AccountRecord
                .order(Column("account_id"))
                .fetchAll(db)
                .map { account in
                    AccountRecord(
                        accountId: account.accountId,
                        displayName: account.displayName,
                        isCloud: account.isCloud,
                        cloudRef: nil
                    )
                }

            let watchStates = try WatchStateRecord
                .order(Column("entity_kind"), Column("entity_ref"), Column("account"))
                .fetchAll(db)
                .map(scrub)

            let collections = try CollectionRecord
                .order(Column("ord"), Column("id"))
                .fetchAll(db)
                .map { CollectionRecord(id: $0.id, name: $0.name, artworkRef: nil, ord: $0.ord) }

            let collectionItems = try CollectionItemRecord
                .order(Column("collection_id"), Column("entity_kind"), Column("entity_ref"))
                .fetchAll(db)
                .map { CollectionItemRecord(
                    collectionId: $0.collectionId,
                    entityKind: $0.entityKind,
                    entityRef: $0.entityRef,
                    fileId: nil,
                    addedAt: $0.addedAt
                ) }

            let playlists = try PlaylistRecord
                .order(Column("ord"), Column("id"))
                .fetchAll(db)

            let playlistItems = try PlaylistItemRecord
                .order(Column("playlist_id"), Column("ord"))
                .fetchAll(db)
                .map { PlaylistItemRecord(
                    playlistId: $0.playlistId,
                    ord: $0.ord,
                    entityKind: $0.entityKind,
                    entityRef: $0.entityRef,
                    fileId: nil
                ) }

            let pins = try PinRecord
                .order(Column("ord"), Column("entity_kind"), Column("entity_ref"))
                .fetchAll(db)
                .map { PinRecord(
                    entityKind: $0.entityKind,
                    entityRef: $0.entityRef,
                    fileId: nil,
                    ord: $0.ord
                ) }

            return UserStateExport(
                exportedAt: exportedAt,
                accounts: accounts,
                watchStates: watchStates,
                collections: collections,
                collectionItems: collectionItems,
                playlists: playlists,
                playlistItems: playlistItems,
                pins: pins,
                preferences: [:]
            )
        }
    }

    /// Encodes the snapshot as JSON.
    public func exportJSON(now: Date = Date(), prettyPrinted: Bool = true) throws -> Data {
        try export(now: now).jsonData(prettyPrinted: prettyPrinted)
    }

    /// Writes the snapshot to `url`.
    public func export(to url: URL, now: Date = Date()) throws {
        try exportJSON(now: now).write(to: url, options: .atomic)
    }

    private func scrub(_ record: WatchStateRecord) -> WatchStateRecord {
        // `last_plan` can embed source URLs; keep only portable user choices.
        WatchStateRecord(
            entityKind: record.entityKind,
            entityRef: record.entityRef,
            account: record.account,
            positionMs: record.positionMs,
            durationMs: record.durationMs,
            watched: record.watched,
            lastWatchedAt: record.lastWatchedAt,
            resumeAt: record.resumeAt,
            userRating: record.userRating,
            trackChoices: record.trackChoices,
            lastPlan: nil,
            updatedAt: record.updatedAt
        )
    }
}
