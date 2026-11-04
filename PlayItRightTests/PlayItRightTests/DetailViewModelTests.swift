import Foundation
import GRDB
import LibraryCore
import Testing
@testable import PlayItRight

private struct DetailHarness {
    let database: MediaDatabase
    let writer: MediaDatabaseWriter
    let reader: MediaDatabaseReader
}

@MainActor
private func makeHarness() throws -> DetailHarness {
    let database = try MediaDatabase.inMemory()
    try database.write { db in
        try AccountRecord(accountId: "local", displayName: "Local").insert(db)
    }
    let writer = MediaDatabaseWriter(database: database)
    try writer.saveSource(
        SourceRecord(sourceId: "s1", kind: .local, name: "Movies", configRef: "s1")
    )
    return DetailHarness(
        database: database,
        writer: writer,
        reader: MediaDatabaseReader(database: database)
    )
}

private extension DetailHarness {
    func addMovie() throws {
        try writer.saveMovie(
            MovieRecord(
                tmdbId: 42,
                title: "The Matrix",
                releaseDate: "1999-03-31",
                runtimeMin: 136,
                overview: "A hacker learns the truth.",
                ratingScore: 8.7
            )
        )
        try writer.saveMediaFiles([
            MediaFileRecord(
                fileId: "movie-42",
                sourceId: "s1",
                path: "/movies/The Matrix.mkv",
                uri: "file:///movies/The%20Matrix.mkv",
                matchState: .matched,
                matchedMovie: 42
            )
        ])
        try writer.savePeopleAndCredits(
            people: [
                PersonRecord(personId: "person-1", name: "Keanu Reeves"),
                PersonRecord(personId: "person-2", name: "Lana Wachowski")
            ],
            credits: [
                CreditRecord(
                    entityKind: .movie,
                    entityRef: "42",
                    personId: "person-1",
                    creditRole: .actor,
                    character: "Neo",
                    ord: 0
                ),
                CreditRecord(
                    entityKind: .movie,
                    entityRef: "42",
                    personId: "person-2",
                    creditRole: .director,
                    job: "Director",
                    ord: 1
                )
            ]
        )
        try database.write { db in
            try TrackRecord(
                fileId: "movie-42",
                kind: .video,
                index: 0,
                width: 3_840,
                height: 2_160,
                hdrFormat: "Dolby Vision"
            ).insert(db)
            try TrackRecord(
                fileId: "movie-42",
                kind: .audio,
                index: 0,
                lang: "en",
                codec: "truehd",
                channels: 8,
                channelLayout: "Atmos"
            ).insert(db)
            try TrackRecord(
                fileId: "movie-42",
                kind: .subtitle,
                index: 0,
                lang: "en",
                subtitleFormat: "pgs"
            ).insert(db)
        }
    }

    func addShow() throws {
        try writer.saveTVShow(
            TVShowRecord(
                showId: "show-1",
                tmdbId: 99,
                title: "Severance",
                firstAirDate: "2022-02-18",
                ratingScore: 8.7
            )
        )
        try writer.saveSeason(
            SeasonRecord(showId: "show-1", seasonNumber: 1, title: "Season One")
        )
        for episode in 1...3 {
            try writer.saveEpisode(
                EpisodeRecord(
                    showId: "show-1",
                    seasonNumber: 1,
                    episodeNumber: episode,
                    title: "Episode \(episode)",
                    overview: "Episode \(episode) overview",
                    airDate: "2022-02-1\(episode)",
                    runtimeMin: 50
                )
            )
        }
        try writer.saveMediaFiles([
            MediaFileRecord(
                fileId: "show-1-s1e1",
                sourceId: "s1",
                path: "/shows/Severance/S01E01.mkv",
                uri: "file:///shows/Severance/S01E01.mkv",
                matchState: .matched,
                matchedEpisode: "show-1:s1e1",
                matchedShow: "show-1"
            ),
            MediaFileRecord(
                fileId: "show-1-s1e2",
                sourceId: "s1",
                path: "/shows/Severance/S01E02.mkv",
                uri: "file:///shows/Severance/S01E02.mkv",
                matchState: .matched,
                matchedEpisode: "show-1:s1e2",
                matchedShow: "show-1"
            )
        ])
        try writer.saveWatchState(
            WatchStateRecord(
                entityKind: .episode,
                entityRef: "show-1:s1e1",
                account: "local",
                positionMs: 3_000_000,
                durationMs: 3_000_000,
                watched: true,
                lastWatchedAt: 100
            )
        )
    }
}

@MainActor
@Suite("DetailViewModel Tests")
struct DetailViewModelTests {
    @Test("Movie detail loads metadata, files, casts, and tracks")
    func movieDetail() async throws {
        let harness = try makeHarness()
        try harness.addMovie()

        let viewModel = DetailViewModel(
            reader: harness.reader,
            writer: harness.writer,
            target: .movie(tmdbId: 42),
            account: "local"
        )
        await viewModel.load()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.movie?.title == "The Matrix")
        #expect(viewModel.overview == "A hacker learns the truth.")
        #expect(viewModel.mediaFiles.map(\.fileId) == ["movie-42"])

        #expect(viewModel.topCast.count == 1)
        #expect(viewModel.topCast.first?.name == "Keanu Reeves")
        #expect(viewModel.audioTracks.count == 1)
        #expect(viewModel.subtitleTracks.count == 1)
        #expect(viewModel.badges == [.fourK, .dolbyVision, .atmos])

        let target = try #require(viewModel.playTarget)
        #expect(target.entityKind == .movie)
        #expect(target.entityRef == "42")
        #expect(target.fileId == "movie-42")
    }

    @Test("Movie detail reports a missing title")
    func missingMovie() async throws {
        let harness = try makeHarness()
        let viewModel = DetailViewModel(
            reader: harness.reader,
            target: .movie(tmdbId: 404),
            account: "local"
        )
        await viewModel.load()

        guard case .failed(let message) = viewModel.state else {
            Issue.record("Expected a failed state")
            return
        }
        #expect(message.contains("no longer in your library"))
    }

    @Test("Show detail resolves the next unwatched episode and can advance it")
    func nextUnwatchedEpisode() async throws {
        let harness = try makeHarness()
        try harness.addShow()

        let viewModel = DetailViewModel(
            reader: harness.reader,
            writer: harness.writer,
            target: .show(showId: "show-1"),
            account: "local"
        )
        await viewModel.load()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.show?.title == "Severance")
        #expect(viewModel.seasons.map(\.seasonNumber) == [1])
        #expect(viewModel.selectedSeason == 1)
        #expect(viewModel.episodes.count == 3)
        #expect(viewModel.mediaFiles.count == 2)

        // Episode 1 is watched, so the next unwatched episode is episode 2.
        #expect(viewModel.nextUnwatchedEpisode?.episodeNumber == 2)
        #expect(viewModel.playTarget?.entityKind == .episode)
        #expect(viewModel.playTarget?.entityRef == "show-1:s1e2")
        #expect(viewModel.playTarget?.fileId == "show-1-s1e2")

        let progress = viewModel.episodeProgress
        #expect(progress.count == 3)
        #expect(progress[0].watched)
        #expect(progress[0].fraction == 1)
        #expect(progress[1].watched == false)
        #expect(progress[1].fraction == 0)

        try await viewModel.markWatched()
        #expect(viewModel.nextUnwatchedEpisode?.episodeNumber == 3)
        #expect(viewModel.episodeProgress[1].watched)
    }

    @Test("Selecting a season reloads that season's episodes")
    func seasonSelection() async throws {
        let harness = try makeHarness()
        try harness.addShow()
        try harness.writer.saveSeason(
            SeasonRecord(showId: "show-1", seasonNumber: 2, title: "Season Two")
        )
        try harness.writer.saveEpisode(
            EpisodeRecord(
                showId: "show-1",
                seasonNumber: 2,
                episodeNumber: 1,
                title: "New Season",
                airDate: "2023-01-01",
                runtimeMin: 48
            )
        )

        let viewModel = DetailViewModel(
            reader: harness.reader,
            target: .show(showId: "show-1"),
            account: "local"
        )
        await viewModel.load()
        #expect(viewModel.seasons.count == 2)

        await viewModel.selectSeason(2)
        #expect(viewModel.selectedSeason == 2)
        #expect(viewModel.episodes.map(\.episodeNumber) == [1])
        #expect(viewModel.episodes.first?.title == "New Season")

        await viewModel.selectSeason(99)
        #expect(viewModel.selectedSeason == 2)
    }
}
