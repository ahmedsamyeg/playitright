import Foundation
import GRDB
import LibraryCore
import Testing
@testable import PlayItRight

// MARK: - Harness

private struct LibraryHarness {
    let database: MediaDatabase
    let writer: MediaDatabaseWriter
    let reader: MediaDatabaseReader
}

@MainActor
private func makeHarness() throws -> LibraryHarness {
    let database = try MediaDatabase.inMemory()
    try database.write { db in
        try AccountRecord(accountId: "local", displayName: "Local").insert(db)
    }
    try MediaDatabaseWriter(database: database).saveSource(
        SourceRecord(
            sourceId: "s1",
            kind: .local,
            name: "Movies",
            configRef: "s1"
        )
    )
    return LibraryHarness(
        database: database,
        writer: MediaDatabaseWriter(database: database),
        reader: MediaDatabaseReader(database: database)
    )
}

@MainActor
private func makeViewModel(
    _ harness: LibraryHarness,
    pageSize: Int = 50
) -> LibraryViewModel {
    LibraryViewModel(
        reader: harness.reader,
        account: "local",
        sourceId: "s1",
        pageSize: pageSize
    )
}

private extension LibraryHarness {
    struct MovieSpec {
        var tmdbId: Int
        var title: String
        var releaseDate: String?
        var rating: Double?
        var addedAt: Int64
        var fileId: String { "file-\(tmdbId)" }
    }

    func addMovie(_ spec: MovieSpec) throws {
        try writer.saveMovie(
            MovieRecord(
                tmdbId: spec.tmdbId,
                title: spec.title,
                releaseDate: spec.releaseDate,
                ratingScore: spec.rating
            )
        )
        try writer.saveMediaFiles([
            MediaFileRecord(
                fileId: spec.fileId,
                sourceId: "s1",
                path: "/movies/\(spec.title).mkv",
                uri: "file:///movies/\(spec.title).mkv",
                matchState: .matched,
                matchedMovie: spec.tmdbId,
                addedAt: spec.addedAt
            )
        ])
    }
}

// MARK: - Tests

@MainActor
@Suite("LibraryViewModel Tests")
struct LibraryViewModelTests {
    @Test("Pagination loads the next page at the shelf boundary")
    func paginationAtBoundary() async throws {
        let harness = try makeHarness()
        for index in 0..<120 {
            try harness.addMovie(
                .init(
                    tmdbId: index + 1,
                    title: String(format: "Movie %03d", index),
                    releaseDate: "2000-01-01",
                    rating: 7,
                    addedAt: Int64(1_700_000_000_000 + index)
                )
            )
        }

        let viewModel = makeViewModel(harness)
        await viewModel.reload()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.items.count == 50)
        #expect(viewModel.hasMore)
        #expect(viewModel.items.first?.displayTitle == "Movie 000")

        // Far from the boundary: no page load.
        await viewModel.loadNextPageIfNeeded(currentItem: viewModel.items[0])
        #expect(viewModel.items.count == 50)

        // Last visible card triggers page two.
        await viewModel.loadNextPageIfNeeded(currentItem: viewModel.items[49])
        #expect(viewModel.items.count == 100)
        #expect(viewModel.hasMore)
        #expect(Set(viewModel.items.map(\.id)).count == 100)

        await viewModel.loadNextPageIfNeeded(currentItem: viewModel.items[99])
        #expect(viewModel.items.count == 120)
        #expect(viewModel.hasMore == false)
        #expect(Set(viewModel.items.map(\.id)).count == 120)
    }

    @Test("Sorting by title, year, date added, and rating")
    func sorting() async throws {
        let harness = try makeHarness()
        try harness.addMovie(
            .init(
                tmdbId: 1,
                title: "Alpha",
                releaseDate: "1999-05-01",
                rating: 5.0,
                addedAt: 300
            )
        )
        try harness.addMovie(
            .init(
                tmdbId: 2,
                title: "Bravo",
                releaseDate: "2020-06-01",
                rating: 8.5,
                addedAt: 100
            )
        )
        try harness.addMovie(
            .init(
                tmdbId: 3,
                title: "Charlie",
                releaseDate: "2010-07-01",
                rating: 7.0,
                addedAt: 200
            )
        )

        let viewModel = makeViewModel(harness)
        await viewModel.reload()
        #expect(viewModel.items.map(\.displayTitle) == ["Alpha", "Bravo", "Charlie"])

        await viewModel.setSort(.year)
        #expect(viewModel.sort == .year)
        #expect(viewModel.items.map(\.displayTitle) == ["Bravo", "Charlie", "Alpha"])

        await viewModel.setSort(.dateAdded)
        #expect(viewModel.items.map(\.displayTitle) == ["Alpha", "Charlie", "Bravo"])

        await viewModel.setSort(.rating)
        #expect(viewModel.items.map(\.displayTitle) == ["Bravo", "Charlie", "Alpha"])
    }

    @Test("Watched and in-progress indicators come from watch state")
    func watchIndicators() async throws {
        let harness = try makeHarness()
        try harness.addMovie(
            .init(tmdbId: 1, title: "Watched", releaseDate: "2000-01-01", rating: 7, addedAt: 1)
        )
        try harness.addMovie(
            .init(tmdbId: 2, title: "Partial", releaseDate: "2001-01-01", rating: 7, addedAt: 2)
        )
        try harness.writer.saveWatchState(
            WatchStateRecord(
                entityKind: .movie,
                entityRef: "1",
                account: "local",
                positionMs: 7_200_000,
                watched: true,
                lastWatchedAt: 100
            )
        )
        try harness.writer.saveWatchState(
            WatchStateRecord(
                entityKind: .movie,
                entityRef: "2",
                account: "local",
                positionMs: 600_000,
                watched: false,
                lastWatchedAt: 200
            )
        )

        let viewModel = makeViewModel(harness)
        await viewModel.reload()

        let watched = try #require(viewModel.items.first { $0.displayTitle == "Watched" })
        let partial = try #require(viewModel.items.first { $0.displayTitle == "Partial" })
        #expect(viewModel.isWatched(watched))
        #expect(viewModel.isInProgress(watched) == false)
        #expect(viewModel.isWatched(partial) == false)
        #expect(viewModel.isInProgress(partial))
    }

    @Test("Density toggles between grid and list")
    func densityToggle() async throws {
        let harness = try makeHarness()
        let viewModel = makeViewModel(harness)
        #expect(viewModel.density == .grid)
        viewModel.toggleDensity()
        #expect(viewModel.density == .list)
        viewModel.setDensity(.grid)
        #expect(viewModel.density == .grid)
    }

    @Test("Technology badges reflect probed tracks")
    func technologyBadges() async throws {
        let harness = try makeHarness()
        try harness.addMovie(
            .init(tmdbId: 1, title: "Demo", releaseDate: "2020-01-01", rating: 8, addedAt: 1)
        )
        try harness.database.write { db in
            try TrackRecord(
                fileId: "file-1",
                kind: .video,
                index: 0,
                width: 3_840,
                height: 2_160,
                hdrFormat: "Dolby Vision"
            ).insert(db)
            try TrackRecord(
                fileId: "file-1",
                kind: .audio,
                index: 0,
                codec: "truehd",
                channels: 8,
                channelLayout: "Atmos"
            ).insert(db)
        }

        let viewModel = makeViewModel(harness)
        await viewModel.reload()

        let item = try #require(viewModel.items.first)
        #expect(item.has4K)
        #expect(item.hasDolbyVision)
        #expect(item.hasAtmos)
        #expect(MediaBadge.badges(for: item) == [.fourK, .dolbyVision, .atmos])
    }
}
