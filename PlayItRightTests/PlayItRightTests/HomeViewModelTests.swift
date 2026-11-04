import Foundation
import GRDB
import LibraryCore
import Testing
@testable import PlayItRight

// MARK: - Fakes

private final class MemoryShelfOrderStore: HomeShelfOrderStore, @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []

    nonisolated init(order: [String] = []) {
        self.order = order
    }

    func loadOrder() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    func saveOrder(_ ids: [String]) {
        lock.lock()
        defer { lock.unlock() }
        order = ids
    }
}

private struct HomeHarness {
    let database: MediaDatabase
    let writer: MediaDatabaseWriter
    let reader: MediaDatabaseReader
    let orderStore: MemoryShelfOrderStore
}

@MainActor
private func makeHarness(order: [String] = []) throws -> HomeHarness {
    let database = try MediaDatabase.inMemory()
    try database.write { db in
        try AccountRecord(accountId: "local", displayName: "Local").insert(db)
    }
    return HomeHarness(
        database: database,
        writer: MediaDatabaseWriter(database: database),
        reader: MediaDatabaseReader(database: database),
        orderStore: MemoryShelfOrderStore(order: order)
    )
}

@MainActor
private func makeViewModel(_ harness: HomeHarness) -> HomeViewModel {
    HomeViewModel(
        reader: harness.reader,
        account: "local",
        shelfLimit: 20,
        orderStore: harness.orderStore
    )
}

private extension HomeHarness {
    func addSource(id: String, name: String, addedAt: Int64 = 1_700_000_000_000) throws {
        try writer.saveSource(
            SourceRecord(
                sourceId: id,
                kind: .local,
                name: name,
                configRef: id,
                addedAt: addedAt
            )
        )
    }

    @discardableResult
    func addMovie(
        tmdbId: Int,
        title: String,
        sourceId: String = "s1",
        fileId: String? = nil,
        addedAt: Int64 = 1_700_000_000_000,
        runtimeMin: Int? = 120
    ) throws -> MovieRecord {
        let movie = MovieRecord(tmdbId: tmdbId, title: title, runtimeMin: runtimeMin)
        try writer.saveMovie(movie)
        let resolvedFileId = fileId ?? "file-\(tmdbId)"
        try writer.saveMediaFiles([
            MediaFileRecord(
                fileId: resolvedFileId,
                sourceId: sourceId,
                path: "/movies/\(title).mkv",
                uri: "file:///movies/\(title).mkv",
                matchState: .matched,
                matchedMovie: tmdbId,
                addedAt: addedAt
            )
        ])
        return movie
    }

    func addProgress(
        tmdbId: Int,
        positionMs: Int64,
        lastWatchedAt: Int64
    ) throws {
        try writer.saveWatchState(
            WatchStateRecord(
                entityKind: .movie,
                entityRef: String(tmdbId),
                account: "local",
                positionMs: positionMs,
                watched: false,
                lastWatchedAt: lastWatchedAt
            )
        )
    }
}

// MARK: - Tests

@MainActor
@Suite("HomeViewModel Tests")
struct HomeViewModelTests {
    @Test("Continue Watching loads in descending last-watched order")
    func continueWatchingOrder() async throws {
        let harness = try makeHarness()
        try harness.addSource(id: "s1", name: "Local Movies")
        try harness.addMovie(tmdbId: 1, title: "Oldest")
        try harness.addMovie(tmdbId: 2, title: "Newest")
        try harness.addMovie(tmdbId: 3, title: "Middle")

        // Insert deliberately out of order to prove the query/sort ordering.
        try harness.addProgress(tmdbId: 1, positionMs: 60_000, lastWatchedAt: 1_000)
        try harness.addProgress(tmdbId: 2, positionMs: 120_000, lastWatchedAt: 3_000)
        try harness.addProgress(tmdbId: 3, positionMs: 30_000, lastWatchedAt: 2_000)

        let viewModel = makeViewModel(harness)
        await viewModel.load()

        #expect(viewModel.state == .loaded)
        #expect(
            viewModel.continueWatching.map(\.title)
                == ["Newest", "Middle", "Oldest"]
        )
        #expect(
            viewModel.continueWatching.map(\.item.lastWatchedAt)
                == [3_000, 2_000, 1_000]
        )
        #expect(viewModel.shelves.first?.kind == .continueWatching)
    }

    @Test("Progress ring percentage clamps and handles unknown durations")
    func progressPercentage() {
        #expect(
            ContinueWatchingProgress(positionMs: 25_000, durationMs: 100_000)
                .percentage == 25
        )
        #expect(
            ContinueWatchingProgress(positionMs: 30_000, durationMs: 120_000)
                .label == "25%"
        )
        #expect(
            ContinueWatchingProgress(positionMs: 80_000, durationMs: 100_000)
                .fraction == 0.8
        )
        #expect(
            ContinueWatchingProgress(positionMs: 800_000, durationMs: 100_000)
                .percentage == 100
        )
        #expect(
            ContinueWatchingProgress(positionMs: 800_000, durationMs: 100_000)
                .isNearlyFinished
        )
        #expect(
            ContinueWatchingProgress(positionMs: 10_000, durationMs: nil)
                .percentage == 0
        )
        #expect(
            ContinueWatchingProgress(positionMs: 0, durationMs: 0)
                .percentage == 0
        )
        #expect(
            ContinueWatchingProgress(positionMs: 90_000, durationMs: 100_000)
                .isNearlyFinished
        )
    }

    @Test("Recently Added is newest first and library shelves group by source")
    func recentlyAddedAndLibraries() async throws {
        let harness = try makeHarness()
        try harness.addSource(id: "s1", name: "Movies", addedAt: 1_000)
        try harness.addSource(id: "s2", name: "Shows", addedAt: 2_000)

        try harness.addMovie(tmdbId: 10, title: "First Scan", fileId: "f10", addedAt: 100)
        try harness.addMovie(tmdbId: 11, title: "Later Scan", fileId: "f11", addedAt: 300)
        try harness.addMovie(tmdbId: 12, title: "Middle Scan", fileId: "f12", addedAt: 200)

        let viewModel = makeViewModel(harness)
        await viewModel.load()

        #expect(
            viewModel.recentlyAdded.map(\.title)
                == ["Later Scan", "Middle Scan", "First Scan"]
        )
        #expect(viewModel.libraryShelves.map(\.summary.name) == ["Movies", "Shows"])
        #expect(viewModel.libraryShelves[0].summary.itemCount == 3)
        #expect(viewModel.libraryShelves[1].items.isEmpty)

        let shelfIDs = viewModel.shelves.map(\.id)
        #expect(
            shelfIDs == ["recently-added", "library:s1"]
        )
        #expect(viewModel.isEmpty == false)
    }

    @Test("An empty library reports the add-a-source empty state")
    func emptyLibrary() async throws {
        let harness = try makeHarness()
        let viewModel = makeViewModel(harness)
        await viewModel.load()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.isEmpty)
        #expect(viewModel.shelves.isEmpty)
    }

    @Test("Shelf reordering persists through the order store")
    func shelfReordering() async throws {
        let harness = try makeHarness()
        try harness.addSource(id: "s1", name: "Movies")
        try harness.addMovie(tmdbId: 1, title: "One", addedAt: 100)
        try harness.addProgress(tmdbId: 1, positionMs: 60_000, lastWatchedAt: 1_000)

        let viewModel = makeViewModel(harness)
        await viewModel.load()
        #expect(viewModel.shelves.map(\.id) == ["continue-watching", "recently-added", "library:s1"])

        viewModel.moveShelf(from: 0, to: 1)
        #expect(viewModel.shelves.map(\.id) == ["recently-added", "continue-watching", "library:s1"])
        #expect(
            harness.orderStore.loadOrder()
                == ["recently-added", "continue-watching", "library:s1"]
        )

        let restored = makeViewModel(harness)
        await restored.load()
        #expect(
            restored.shelves.map(\.id)
                == ["recently-added", "continue-watching", "library:s1"]
        )

        restored.moveShelfUp("library:s1")
        #expect(
            restored.shelves.map(\.id)
                == ["recently-added", "library:s1", "continue-watching"]
        )
    }

    @Test("Unknown saved shelves are ignored after a source is removed")
    func unknownSavedShelves() async throws {
        let harness = try makeHarness(
            order: ["library:gone", "recently-added", "continue-watching"]
        )
        try harness.addSource(id: "s1", name: "Movies")
        try harness.addMovie(tmdbId: 1, title: "One", addedAt: 100)

        let viewModel = makeViewModel(harness)
        await viewModel.load()

        #expect(
            viewModel.shelves.map(\.id)
                == ["recently-added", "library:s1"]
        )
    }
}
