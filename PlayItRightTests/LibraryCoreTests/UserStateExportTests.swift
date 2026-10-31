import Foundation
import GRDB
import Testing
@testable import LibraryCore

@Suite("UserStateExport Tests")
struct UserStateExportTests {
    private func makeDatabase() throws -> MediaDatabase {
        try MediaDatabase.inMemory()
    }

    private func seedUserState(in database: MediaDatabase) throws {
        try database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts (account_id, display_name, is_cloud, cloud_ref)
                    VALUES ('a1', 'Alex', 0, 'cloud-ref');
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO sources
                        (source_id, kind, name, config_ref, status, added_at)
                    VALUES ('s1', 'smb', 'Home NAS', 'secret-config', 'ok', 1);
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO media_files
                        (file_id, source_id, path, uri, added_at)
                    VALUES ('f1', 's1', '/Users/alex/Movies/Inception.mkv',
                            'smb://user:pass@192.168.1.5/share/Inception.mkv', 1);
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO watch_state (
                        entity_kind, entity_ref, account, position_ms, duration_ms,
                        watched, last_watched_at, resume_at, user_rating,
                        track_choices, last_plan, updated_at
                    ) VALUES (
                        'movie', 'tmdb:603', 'a1', 12000, 90000, 0, 111, 12000, 8,
                        '{"audio":0,"subtitle":1}',
                        'smb://user:pass@192.168.1.5/share/Inception.mkv', 111
                    );
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO collections (id, name, artwork_ref, ord)
                    VALUES ('c1', 'Favourites', '/Users/alex/artwork/c1.jpg', 0);
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO collection_items
                        (collection_id, entity_kind, entity_ref, file_id, added_at)
                    VALUES ('c1', 'movie', 'tmdb:603', 'f1', 111);
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO playlists (id, name, shuffle, loop, ord)
                    VALUES ('p1', 'Weekend', 1, 0, 0);
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO playlist_items
                        (playlist_id, ord, entity_kind, entity_ref, file_id)
                    VALUES ('p1', 0, 'movie', 'tmdb:603', 'f1');
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO pins (entity_kind, entity_ref, file_id, ord)
                    VALUES ('movie', 'tmdb:603', 'f1', 0);
                    """
            )
        }
    }

    @Test("Export includes user state and strips local references")
    func exportStripsPrivateData() throws {
        let database = try makeDatabase()
        try seedUserState(in: database)

        let export = try UserStateExporter(database: database)
            .export(now: Date(timeIntervalSince1970: 500))

        #expect(export.schemaVersion == 1)
        #expect(export.exportedAt == 500_000)
        #expect(export.accounts.count == 1)
        #expect(export.accounts.first?.cloudRef == nil)
        #expect(export.watchStates.count == 1)
        #expect(export.watchStates.first?.positionMs == 12_000)
        #expect(export.watchStates.first?.userRating == 8)
        #expect(export.watchStates.first?.lastPlan == nil)
        #expect(export.collections.count == 1)
        #expect(export.collections.first?.artworkRef == nil)
        #expect(export.collectionItems.first?.fileId == nil)
        #expect(export.playlistItems.first?.fileId == nil)
        #expect(export.pins.first?.fileId == nil)
        #expect(export.playlists.first?.shuffle == true)
    }

    @Test("Exported JSON never contains credentials or private paths")
    func exportJSONOmitsSecrets() throws {
        let database = try makeDatabase()
        try seedUserState(in: database)

        let data = try UserStateExporter(database: database).exportJSON()
        let json = String(decoding: data, as: UTF8.self)

        #expect(!json.contains("user:pass"))
        #expect(!json.contains("192.168.1.5"))
        #expect(!json.contains("/Users/alex"))
        #expect(!json.contains("secret-config"))
        #expect(!json.contains("cloud-ref"))
        #expect(json.contains("Favourites"))
        #expect(json.contains("Weekend"))
    }

    @Test("Export round-trips through JSON")
    func exportRoundTrips() throws {
        let database = try makeDatabase()
        try seedUserState(in: database)

        let exporter = UserStateExporter(database: database)
        let export = try exporter.export(now: Date(timeIntervalSince1970: 100))
        let decoded = try UserStateExport.decode(from: exporter.exportJSON(
            now: Date(timeIntervalSince1970: 100)
        ))

        #expect(decoded == export)
    }

    @Test("Importing into a fresh database restores progress and playlists")
    func importRestoresUserState() throws {
        let source = try makeDatabase()
        try seedUserState(in: source)
        let export = try UserStateExporter(database: source).export()

        let destination = try makeDatabase()
        let summary = try UserStateImporter(database: destination).importState(export)

        #expect(summary.accountsImported == 1)
        #expect(summary.watchStatesInserted == 1)
        #expect(summary.collectionsImported == 1)
        #expect(summary.collectionItemsImported == 1)
        #expect(summary.playlistsImported == 1)
        #expect(summary.playlistItemsImported == 1)
        #expect(summary.pinsImported == 1)

        let restored = try destination.reader.read { db in
            (
                watch: try WatchStateRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM watch_state WHERE entity_ref = ?;",
                    arguments: ["tmdb:603"]
                ),
                playlists: try PlaylistRecord.fetchAll(db),
                playlistItems: try PlaylistItemRecord.fetchAll(db),
                collections: try CollectionRecord.fetchAll(db),
                pins: try PinRecord.fetchAll(db),
                accounts: try AccountRecord.fetchAll(db)
            )
        }

        #expect(restored.watch?.positionMs == 12_000)
        #expect(restored.watch?.userRating == 8)
        #expect(restored.watch?.trackChoices == #"{"audio":0,"subtitle":1}"#)
        #expect(restored.playlists.map(\.name) == ["Weekend"])
        #expect(restored.playlistItems.count == 1)
        #expect(restored.collections.map(\.name) == ["Favourites"])
        #expect(restored.pins.count == 1)
        #expect(restored.accounts.map(\.accountId) == ["a1"])
    }

    @Test("Watch state merges using max(last_watched_at)")
    func watchStateConflictRule() throws {
        let database = try makeDatabase()
        let importer = UserStateImporter(database: database)

        let account = AccountRecord(accountId: "a1", displayName: "Alex")
        func state(position: Int64, lastWatchedAt: Int64) -> WatchStateRecord {
            WatchStateRecord(
                entityKind: .movie,
                entityRef: "tmdb:603",
                account: "a1",
                positionMs: position,
                lastWatchedAt: lastWatchedAt,
                updatedAt: lastWatchedAt
            )
        }

        _ = try importer.importState(UserStateExport(
            exportedAt: 1,
            accounts: [account],
            watchStates: [state(position: 5_000, lastWatchedAt: 100)]
        ))

        // Older snapshot must not overwrite newer local progress.
        let older = try importer.importState(UserStateExport(
            exportedAt: 1,
            accounts: [account],
            watchStates: [state(position: 1_000, lastWatchedAt: 50)]
        ))
        #expect(older.watchStatesSkipped == 1)
        #expect(older.watchStatesUpdated == 0)

        // Newer snapshot wins.
        let newer = try importer.importState(UserStateExport(
            exportedAt: 1,
            accounts: [account],
            watchStates: [state(position: 9_000, lastWatchedAt: 200)]
        ))
        #expect(newer.watchStatesUpdated == 1)

        let stored = try database.reader.read { db in
            try WatchStateRecord.fetchOne(
                db,
                sql: "SELECT * FROM watch_state WHERE entity_ref = ?;",
                arguments: ["tmdb:603"]
            )
        }
        #expect(stored?.positionMs == 9_000)
        #expect(stored?.lastWatchedAt == 200)
    }

    @Test("Importing creates missing accounts for orphan watch state")
    func importCreatesMissingAccount() throws {
        let database = try makeDatabase()
        let state = UserStateExport(
            exportedAt: 1,
            watchStates: [
                WatchStateRecord(
                    entityKind: .episode,
                    entityRef: "ep-1",
                    account: "unknown",
                    positionMs: 42,
                    lastWatchedAt: 10
                )
            ]
        )

        let summary = try UserStateImporter(database: database).importState(state)

        #expect(summary.watchStatesInserted == 1)
        let accounts = try database.reader.read { try AccountRecord.fetchAll($0) }
        #expect(accounts.map(\.accountId) == ["unknown"])
    }

    @Test("Importing a JSON file works end to end")
    func importFromFile() throws {
        let source = try makeDatabase()
        try seedUserState(in: source)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("state.json")
        try UserStateExporter(database: source).export(to: url)

        let destination = try makeDatabase()
        let summary = try UserStateImporter(database: destination).importState(from: url)

        #expect(summary.watchStatesInserted == 1)
        #expect(summary.playlistsImported == 1)
    }

    @Test("Unsupported schema versions are rejected")
    func rejectsUnsupportedSchema() throws {
        let database = try makeDatabase()
        let state = UserStateExport(schemaVersion: 99, exportedAt: 0)

        #expect(throws: UserStateImportError.unsupportedSchemaVersion(99)) {
            _ = try UserStateImporter(database: database).importState(state)
        }
    }
}
