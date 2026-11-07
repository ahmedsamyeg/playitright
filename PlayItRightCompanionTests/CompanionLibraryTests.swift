import Foundation
import LibraryCore
import Testing

/// Verifies the shared LibraryCore data layer works under an iOS destination
/// and feeds the companion browser.
@Suite("CompanionLibrary Tests")
struct CompanionLibraryTests {
    @Test("The companion reads recently added items through LibraryCore")
    func readsRecentlyAdded() throws {
        let database = try MediaDatabase.inMemory()
        try seed(database)

        let reader = MediaDatabaseReader(database: database)
        let items = try reader.fetchRecentlyAdded(limit: 10)

        #expect(items.count == 1)
        #expect(items.first?.fileId == "file-1")
        #expect(items.first?.title == "Blade Runner 2049")
        #expect(items.first?.durationMs == 9_840_000)
    }

    @Test("The companion lists shared library shelves")
    func readsShelves() throws {
        let database = try MediaDatabase.inMemory()
        try seed(database)

        let shelves = try MediaDatabaseReader(database: database).fetchLibraryShelves()

        #expect(shelves.count == 1)
        #expect(shelves.first?.sourceId == "source-1")
        #expect(shelves.first?.itemCount == 1)
    }

    @Test("An empty companion library is a valid state")
    func emptyLibrary() throws {
        let database = try MediaDatabase.inMemory()
        let reader = MediaDatabaseReader(database: database)

        let items = try reader.fetchRecentlyAdded()
        let shelves = try reader.fetchLibraryShelves()

        #expect(items.isEmpty)
        #expect(shelves.isEmpty)
    }

    private func seed(_ database: MediaDatabase) throws {
        try database.write { db in
            try SourceRecord(
                sourceId: "source-1",
                kind: .plex,
                name: "Living Room",
                configRef: "keychain://source-1",
                addedAt: 1_000
            ).insert(db)

            try MovieRecord(
                tmdbId: 335_984,
                title: "Blade Runner 2049"
            ).insert(db)

            try MediaFileRecord(
                fileId: "file-1",
                sourceId: "source-1",
                path: "/Movies/Blade Runner 2049.mkv",
                uri: "plex://source-1/file-1",
                durationMs: 9_840_000,
                matchState: .matched,
                matchedMovie: 335_984,
                addedAt: 2_000
            ).insert(db)
        }
    }
}
