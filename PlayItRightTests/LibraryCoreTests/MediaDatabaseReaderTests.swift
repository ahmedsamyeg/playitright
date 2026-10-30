import Testing
import Foundation
import GRDB
@testable import LibraryCore

@Suite("MediaDatabaseReader Tests")
struct MediaDatabaseReaderTests {
    private func makeSystem() throws -> (MediaDatabase, MediaDatabaseWriter, MediaDatabaseReader) {
        let db = try MediaDatabase.inMemory()
        let writer = MediaDatabaseWriter(database: db)
        let reader = MediaDatabaseReader(database: db)
        return (db, writer, reader)
    }

    @Test("Keyset pagination returns contiguous pages without duplicates")
    func keysetPagination() throws {
        let (_, writer, reader) = try makeSystem()

        try writer.saveSource(SourceRecord(sourceId: "s1", kind: .local, name: "Disk", configRef: "ref"))

        // Insert 10 movies named "Movie A" ... "Movie J"
        let alphabet = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"]
        for (idx, letter) in alphabet.enumerated() {
            let tmdbId = 100 + idx
            let movie = MovieRecord(tmdbId: tmdbId, title: "Movie \(letter)")
            try writer.saveMovie(movie)

            let fileId = String(format: "f%02d", idx)
            let file = MediaFileRecord(
                fileId: fileId,
                sourceId: "s1",
                path: "/movies/m_\(letter).mkv",
                uri: "file:///movies/m_\(letter).mkv",
                matchState: .matched,
                matchedMovie: tmdbId
            )
            try writer.saveMediaFiles([file])
        }

        // Page 1: limit 4
        let page1 = try reader.fetchLibraryGrid(sourceId: "s1", cursor: nil, limit: 4)
        #expect(page1.count == 4)
        #expect(page1.map(\.displayTitle) == ["Movie A", "Movie B", "Movie C", "Movie D"])

        // Page 2: using cursor from last item of page 1
        let cursor1 = LibraryGridCursor(
            displayTitle: page1.last!.displayTitle,
            fileId: page1.last!.fileId
        )
        let page2 = try reader.fetchLibraryGrid(sourceId: "s1", cursor: cursor1, limit: 4)
        #expect(page2.count == 4)
        #expect(page2.map(\.displayTitle) == ["Movie E", "Movie F", "Movie G", "Movie H"])

        // Page 3: last 2 items
        let cursor2 = LibraryGridCursor(
            displayTitle: page2.last!.displayTitle,
            fileId: page2.last!.fileId
        )
        let page3 = try reader.fetchLibraryGrid(sourceId: "s1", cursor: cursor2, limit: 4)
        #expect(page3.count == 2)
        #expect(page3.map(\.displayTitle) == ["Movie I", "Movie J"])
    }

    @Test("Continue Watching resolves titles and preserves recency order")
    func continueWatching() throws {
        let (db, writer, reader) = try makeSystem()

        try db.write { db in
            try AccountRecord(accountId: "user1", displayName: "Test User").insert(db)
        }

        // 1. Movie 1: partially watched, last_watched_at = 2000
        let m1 = MovieRecord(tmdbId: 1, title: "Movie 1", runtimeMin: 120)
        try writer.saveMovie(m1)
        try writer.saveWatchState(WatchStateRecord(
            entityKind: .movie,
            entityRef: "1",
            account: "user1",
            positionMs: 300_000,
            watched: false,
            lastWatchedAt: 2000
        ))

        // 2. Movie 2: fully watched -> must NOT appear
        let m2 = MovieRecord(tmdbId: 2, title: "Movie 2", runtimeMin: 90)
        try writer.saveMovie(m2)
        try writer.saveWatchState(WatchStateRecord(
            entityKind: .movie,
            entityRef: "2",
            account: "user1",
            positionMs: 5_400_000,
            watched: true,
            lastWatchedAt: 3000
        ))

        // 3. Episode: partially watched, last_watched_at = 4000 (most recent!)
        let show = TVShowRecord(showId: "tmdb:10", title: "Breaking Bad")
        try writer.saveTVShow(show)
        try writer.saveSeason(SeasonRecord(showId: "tmdb:10", seasonNumber: 1))
        let ep = EpisodeRecord(showId: "tmdb:10", seasonNumber: 1, episodeNumber: 2, title: "Cat's in the Bag...")
        try writer.saveEpisode(ep)
        try writer.saveWatchState(WatchStateRecord(
            entityKind: .episode,
            entityRef: "tmdb:10:s1e2",
            account: "user1",
            positionMs: 600_000,
            watched: false,
            lastWatchedAt: 4000
        ))

        let continueList = try reader.fetchContinueWatching(account: "user1")
        #expect(continueList.count == 2)

        // Episode first because lastWatchedAt 4000 > 2000
        #expect(continueList[0].entityKind == .episode)
        #expect(continueList[0].title == "Cat's in the Bag...")
        #expect(continueList[0].showTitle == "Breaking Bad")
        #expect(continueList[0].seasonNumber == 1)
        #expect(continueList[0].episodeNumber == 2)
        #expect(continueList[0].positionMs == 600_000)

        // Movie second
        #expect(continueList[1].entityKind == .movie)
        #expect(continueList[1].title == "Movie 1")
        #expect(continueList[1].positionMs == 300_000)
    }

    @Test("Next unwatched episode query skips watched episodes")
    func nextUnwatchedEpisode() throws {
        let (db, writer, reader) = try makeSystem()

        try db.write { db in
            try AccountRecord(accountId: "u1", displayName: "User").insert(db)
        }

        let showId = "tmdb:50"
        try writer.saveTVShow(TVShowRecord(showId: showId, title: "Severance"))
        try writer.saveSeason(SeasonRecord(showId: showId, seasonNumber: 1))

        let ep1 = EpisodeRecord(showId: showId, seasonNumber: 1, episodeNumber: 1, title: "Good News About Hell", airDate: "2022-02-18")
        let ep2 = EpisodeRecord(showId: showId, seasonNumber: 1, episodeNumber: 2, title: "Half Loop", airDate: "2022-02-18")
        let ep3 = EpisodeRecord(showId: showId, seasonNumber: 1, episodeNumber: 3, title: "In Perpetuity", airDate: "2022-02-25")
        try writer.saveEpisode(ep1)
        try writer.saveEpisode(ep2)
        try writer.saveEpisode(ep3)

        // Initial: ep 1 is next
        var next = try reader.fetchNextUnwatchedEpisode(showId: showId, account: "u1")
        #expect(next?.episodeNumber == 1)

        // Mark ep 1 as watched
        try writer.saveWatchState(WatchStateRecord(
            entityKind: .episode,
            entityRef: "\(showId):s1e1",
            account: "u1",
            positionMs: 3_000_000,
            watched: true
        ))

        // Now: ep 2 is next
        next = try reader.fetchNextUnwatchedEpisode(showId: showId, account: "u1")
        #expect(next?.episodeNumber == 2)

        // Mark ep 2 as watched
        try writer.saveWatchState(WatchStateRecord(
            entityKind: .episode,
            entityRef: "\(showId):s1e2",
            account: "u1",
            positionMs: 3_000_000,
            watched: true
        ))

        // Now: ep 3 is next
        next = try reader.fetchNextUnwatchedEpisode(showId: showId, account: "u1")
        #expect(next?.episodeNumber == 3)

        // Mark ep 3 as watched
        try writer.saveWatchState(WatchStateRecord(
            entityKind: .episode,
            entityRef: "\(showId):s1e3",
            account: "u1",
            positionMs: 3_000_000,
            watched: true
        ))

        // All episodes watched
        next = try reader.fetchNextUnwatchedEpisode(showId: showId, account: "u1")
        #expect(next == nil)
    }

    @Test("Search queries with tokenization and source filtering")
    func searchWithSourceFiltering() throws {
        let (_, writer, reader) = try makeSystem()

        try writer.saveSource(SourceRecord(sourceId: "s1", kind: .local, name: "Disk1", configRef: "ref1"))
        try writer.saveSource(SourceRecord(sourceId: "s2", kind: .smb, name: "Disk2", configRef: "ref2"))

        let m1 = MovieRecord(tmdbId: 10, title: "The Dark Knight", overview: "Batman raises the stakes in his war on crime.")
        let m2 = MovieRecord(tmdbId: 20, title: "The Dark Crystal", overview: "Another world, another time, in the age of wonder.")
        try writer.saveMovie(m1)
        try writer.saveMovie(m2)

        // File for m1 is in source s1, file for m2 is in source s2
        let f1 = MediaFileRecord(fileId: "f1", sourceId: "s1", path: "dk.mkv", uri: "file://dk.mkv", matchState: .matched, matchedMovie: 10)
        let f2 = MediaFileRecord(fileId: "f2", sourceId: "s2", path: "dc.mkv", uri: "file://dc.mkv", matchState: .matched, matchedMovie: 20)
        try writer.saveMediaFiles([f1, f2])

        // Unfiltered search: returns both Dark Knight and Dark Crystal
        let allDark = try reader.search(query: "Dark")
        #expect(allDark.count == 2)

        // Filtered search for source s1: returns ONLY Dark Knight
        let s1Dark = try reader.search(query: "Dark", sourceId: "s1")
        #expect(s1Dark.count == 1)
        #expect(s1Dark.first?.entityRef == "10")
        #expect(s1Dark.first?.title == "The Dark Knight")
    }

    @Test("Cast and crew lookup includes headshots and billing order")
    func castAndCrew() throws {
        let (_, writer, reader) = try makeSystem()

        let movie = MovieRecord(tmdbId: 500, title: "Oppenheimer")
        try writer.saveMovie(movie)

        let p1 = PersonRecord(personId: "tmdb:2037", name: "Cillian Murphy")
        let p2 = PersonRecord(personId: "tmdb:525", name: "Christopher Nolan")
        let c1 = CreditRecord(entityKind: .movie, entityRef: "500", personId: "tmdb:2037", creditRole: .actor, character: "J. Robert Oppenheimer", ord: 0)
        let c2 = CreditRecord(entityKind: .movie, entityRef: "500", personId: "tmdb:525", creditRole: .director, job: "Director", ord: 1)
        try writer.savePeopleAndCredits(people: [p1, p2], credits: [c1, c2])

        // Add artwork for Cillian Murphy
        let art = ArtworkRecord(
            entityKind: .person,
            entityRef: "tmdb:2037",
            kind: .profile,
            provider: "tmdb",
            variant: "w185",
            localPath: "/artwork/cillian.jpg"
        )
        try writer.saveArtwork([art])

        let castCrew = try reader.fetchCastAndCrew(entityKind: .movie, entityRef: "500")
        #expect(castCrew.count == 2)

        #expect(castCrew[0].name == "Cillian Murphy")
        #expect(castCrew[0].creditRole == .actor)
        #expect(castCrew[0].character == "J. Robert Oppenheimer")
        #expect(castCrew[0].headshotPath == "/artwork/cillian.jpg")

        #expect(castCrew[1].name == "Christopher Nolan")
        #expect(castCrew[1].creditRole == .director)
        #expect(castCrew[1].headshotPath == nil)
    }

    @Test("Smart Library filter compilation and execution")
    func smartLibraryEvaluation() throws {
        let (_, writer, reader) = try makeSystem()

        try writer.saveSource(SourceRecord(sourceId: "s1", kind: .local, name: "Disk", configRef: "ref"))

        let f1 = MediaFileRecord(fileId: "f1", sourceId: "s1", path: "4k_hevc.mkv", uri: "file://4k_hevc.mkv", durationMs: 7_200_000)
        let f2 = MediaFileRecord(fileId: "f2", sourceId: "s1", path: "1080p_h264.mp4", uri: "file://1080p_h264.mp4", durationMs: 3_600_000)
        try writer.saveMediaFiles([f1, f2])

        let t1 = [TrackRecord(fileId: "f1", kind: .video, index: 0, codec: "hevc", width: 3840, height: 2160, hdrFormat: "hdr10")]
        let t2 = [TrackRecord(fileId: "f2", kind: .video, index: 0, codec: "h264", width: 1920, height: 1080)]
        try writer.updateProbeMetadata(fileId: "f1", container: "matroska", tracks: t1)
        try writer.updateProbeMetadata(fileId: "f2", container: "mp4", tracks: t2)

        // Filter: video width >= 3840 AND codec == 'hevc'
        let filter4K = SmartLibraryFilter(
            conjunction: .and,
            rules: [
                SmartFilterRule(field: .width, operator: .greaterThanOrEqual, value: "3840"),
                SmartFilterRule(field: .codec, operator: .equals, value: "hevc")
            ]
        )

        let results4K = try reader.fetchSmartLibraryFiles(filter: filter4K)
        #expect(results4K.count == 1)
        #expect(results4K.first?.fileId == "f1")

        // Filter: container in list "matroska, mp4"
        let filterContainers = SmartLibraryFilter(
            rules: [
                SmartFilterRule(field: .container, operator: .inList, value: "matroska, mp4")
            ]
        )
        let resultsContainers = try reader.fetchSmartLibraryFiles(filter: filterContainers)
        #expect(resultsContainers.count == 2)
    }
}
