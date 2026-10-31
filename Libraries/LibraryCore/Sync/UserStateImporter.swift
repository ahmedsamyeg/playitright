import Foundation
import GRDB

/// Errors raised while importing a user-state snapshot.
public enum UserStateImportError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported user-state schema version \(version)."
        }
    }
}

/// Counts describing what an import changed.
public struct UserStateImportSummary: Codable, Sendable, Equatable {
    public var accountsImported = 0
    public var watchStatesInserted = 0
    public var watchStatesUpdated = 0
    public var watchStatesSkipped = 0
    public var collectionsImported = 0
    public var collectionItemsImported = 0
    public var playlistsImported = 0
    public var playlistItemsImported = 0
    public var pinsImported = 0
    public var preferencesImported = 0

    public init() {}

    public var totalImported: Int {
        accountsImported
            + watchStatesInserted
            + watchStatesUpdated
            + collectionsImported
            + collectionItemsImported
            + playlistsImported
            + playlistItemsImported
            + pinsImported
    }
}

/// Merges a portable user-state snapshot into the local database.
///
/// Watch state uses `max(last_watched_at)` as its conflict rule: an incoming
/// record only replaces a local record when it is strictly newer. Other user
/// organization rows are last-writer-wins by primary key.
///
/// All rows use SQLite UPSERT (`ON CONFLICT ... DO UPDATE`) rather than
/// `INSERT OR REPLACE`. REPLACE deletes the conflicting row before inserting,
/// which fires `ON DELETE CASCADE` and would wipe child rows such as a user's
/// watch state when only the parent account is re-imported.
public struct UserStateImporter: Sendable {
    private let database: MediaDatabase

    public init(database: MediaDatabase) {
        self.database = database
    }

    /// Imports a decoded snapshot.
    @discardableResult
    public func importState(_ state: UserStateExport) throws -> UserStateImportSummary {
        guard state.schemaVersion == UserStateExport.currentSchemaVersion else {
            throw UserStateImportError.unsupportedSchemaVersion(state.schemaVersion)
        }

        return try database.writer.write { db in
            var summary = UserStateImportSummary()
            summary.preferencesImported = state.preferences.count

            for account in state.accounts {
                try db.execute(
                    sql: """
                        INSERT INTO accounts
                            (account_id, display_name, is_cloud, cloud_ref)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(account_id) DO UPDATE SET
                            display_name = excluded.display_name,
                            is_cloud = excluded.is_cloud,
                            cloud_ref = excluded.cloud_ref;
                        """,
                    arguments: [
                        account.accountId,
                        account.displayName,
                        account.isCloud ? 1 : 0,
                        account.cloudRef
                    ]
                )
                summary.accountsImported += 1
            }

            for record in state.watchStates {
                try ensureAccountExists(record.account, in: db)

                let existing = try WatchStateRecord.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM watch_state
                        WHERE entity_kind = ? AND entity_ref = ? AND account = ?;
                        """,
                    arguments: [record.entityKind.rawValue, record.entityRef, record.account]
                )

                if let existing {
                    guard isNewer(record, than: existing) else {
                        summary.watchStatesSkipped += 1
                        continue
                    }
                    try saveWatchState(record, in: db)
                    summary.watchStatesUpdated += 1
                } else {
                    try saveWatchState(record, in: db)
                    summary.watchStatesInserted += 1
                }
            }

            for collection in state.collections {
                try db.execute(
                    sql: """
                        INSERT INTO collections (id, name, artwork_ref, ord)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            name = excluded.name,
                            artwork_ref = excluded.artwork_ref,
                            ord = excluded.ord;
                        """,
                    arguments: [collection.id, collection.name, collection.artworkRef, collection.ord]
                )
                summary.collectionsImported += 1
            }

            for item in state.collectionItems {
                let collectionExists = try Int.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM collections WHERE id = ?);",
                    arguments: [item.collectionId]
                ) == 1
                guard collectionExists else {
                    continue
                }

                try db.execute(
                    sql: """
                        INSERT INTO collection_items
                            (collection_id, entity_kind, entity_ref, file_id, added_at)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(collection_id, entity_kind, entity_ref) DO UPDATE SET
                            file_id = excluded.file_id,
                            added_at = excluded.added_at;
                        """,
                    arguments: [
                        item.collectionId,
                        item.entityKind.rawValue,
                        item.entityRef,
                        item.fileId,
                        item.addedAt
                    ]
                )
                summary.collectionItemsImported += 1
            }

            for playlist in state.playlists {
                try db.execute(
                    sql: """
                        INSERT INTO playlists (id, name, shuffle, loop, ord)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            name = excluded.name,
                            shuffle = excluded.shuffle,
                            loop = excluded.loop,
                            ord = excluded.ord;
                        """,
                    arguments: [
                        playlist.id,
                        playlist.name,
                        playlist.shuffle ? 1 : 0,
                        playlist.loop ? 1 : 0,
                        playlist.ord
                    ]
                )
                summary.playlistsImported += 1
            }

            for item in state.playlistItems {
                let playlistExists = try Int.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM playlists WHERE id = ?);",
                    arguments: [item.playlistId]
                ) == 1
                guard playlistExists else {
                    continue
                }

                try db.execute(
                    sql: """
                        INSERT INTO playlist_items
                            (playlist_id, ord, entity_kind, entity_ref, file_id)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(playlist_id, ord) DO UPDATE SET
                            entity_kind = excluded.entity_kind,
                            entity_ref = excluded.entity_ref,
                            file_id = excluded.file_id;
                        """,
                    arguments: [
                        item.playlistId,
                        item.ord,
                        item.entityKind.rawValue,
                        item.entityRef,
                        item.fileId
                    ]
                )
                summary.playlistItemsImported += 1
            }

            for pin in state.pins {
                try db.execute(
                    sql: """
                        INSERT INTO pins (entity_kind, entity_ref, file_id, ord)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(entity_kind, entity_ref) DO UPDATE SET
                            file_id = excluded.file_id,
                            ord = excluded.ord;
                        """,
                    arguments: [pin.entityKind.rawValue, pin.entityRef, pin.fileId, pin.ord]
                )
                summary.pinsImported += 1
            }

            return summary
        }
    }

    /// Decodes and imports a JSON snapshot.
    @discardableResult
    public func importJSON(_ data: Data) throws -> UserStateImportSummary {
        try importState(UserStateExport.decode(from: data))
    }

    /// Reads and imports a JSON snapshot from `url`.
    @discardableResult
    public func importState(from url: URL) throws -> UserStateImportSummary {
        try importJSON(Data(contentsOf: url))
    }

    // MARK: - Private

    private func ensureAccountExists(_ accountId: String, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO accounts (account_id, display_name, is_cloud)
                VALUES (?, ?, 0);
                """,
            arguments: [accountId, accountId]
        )
    }

    private func isNewer(_ incoming: WatchStateRecord, than existing: WatchStateRecord) -> Bool {
        let incomingTime = incoming.lastWatchedAt ?? incoming.updatedAt
        let existingTime = existing.lastWatchedAt ?? existing.updatedAt
        return incomingTime > existingTime
    }

    private func saveWatchState(_ record: WatchStateRecord, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO watch_state (
                    entity_kind, entity_ref, account, position_ms, duration_ms,
                    watched, last_watched_at, resume_at, user_rating,
                    track_choices, last_plan, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(entity_kind, entity_ref, account) DO UPDATE SET
                    position_ms = excluded.position_ms,
                    duration_ms = excluded.duration_ms,
                    watched = excluded.watched,
                    last_watched_at = excluded.last_watched_at,
                    resume_at = excluded.resume_at,
                    user_rating = excluded.user_rating,
                    track_choices = excluded.track_choices,
                    last_plan = excluded.last_plan,
                    updated_at = excluded.updated_at;
                """,
            arguments: [
                record.entityKind.rawValue,
                record.entityRef,
                record.account,
                record.positionMs,
                record.durationMs,
                record.watched ? 1 : 0,
                record.lastWatchedAt,
                record.resumeAt,
                record.userRating,
                record.trackChoices,
                record.lastPlan,
                record.updatedAt
            ]
        )
    }
}
