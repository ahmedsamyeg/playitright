import Testing
import Foundation
import GRDB
@testable import LibraryCore

@Suite("MediaDatabaseWriter Tests")
struct MediaDatabaseWriterTests {
    private func makeWriter() throws -> (MediaDatabase, MediaDatabaseWriter) {
        let db = try MediaDatabase.inMemory()
        let writer = MediaDatabaseWriter(database: db)
        return (db, writer)
    }

    @Test("Batch file ingestion and probe update")
    func batchIngestionAndProbe() throws {
        let (db, writer) = try makeWriter()

        let source = SourceRecord(sourceId: "s1", kind: .smb, name: "NAS", configRef: "nas")
        try writer.saveSource(source)

        let files = (1...15).map { i in
            MediaFileRecord(
                fileId: "f\(i)",
                sourceId: "s1",
                path: "/nas/video\(i).mkv",
                uri: "smb://nas/video\(i).mkv"
            )
        }
        try writer.saveMediaFiles(files, batchSize: 5)

        let count = try db.read { db in
            try MediaFileRecord.fetchCount(db)
        }
        #expect(count == 15)

        // Update probe metadata & tracks
        let tracks = [
            TrackRecord(fileId: "f1", kind: .video, index: 0, codec: "hevc", width: 3840, height: 2160, hdrFormat: "hdr10"),
            TrackRecord(fileId: "f1", kind: .audio, index: 1, channels: 6, channelLayout: "5.1", sampleRate: 48000)
        ]
        try writer.updateProbeMetadata(
            fileId: "f1",
            container: "matroska",
            sizeBytes: 4_000_000_000,
            durationMs: 7_200_000,
            tracks: tracks
        )

        let probed = try db.read { db in
            try MediaFileRecord.fetchOne(db, key: "f1")
        }
        #expect(probed?.container == "matroska")
        #expect(probed?.durationMs == 7_200_000)

        let fetchedTracks = try db.read { db in
            try TrackRecord.filter(TrackRecord.Columns.fileId == "f1").fetchAll(db)
        }
        #expect(fetchedTracks.count == 2)
    }

    @Test("File matching and unmatching transitions")
    func matchingTransitions() throws {
        let (db, writer) = try makeWriter()

        try writer.saveSource(SourceRecord(sourceId: "s1", kind: .local, name: "Disk", configRef: "ref"))
        let file = MediaFileRecord(fileId: "f1", sourceId: "s1", path: "a.mkv", uri: "file://a.mkv")
        try writer.saveMediaFiles([file])

        let movie = MovieRecord(tmdbId: 10, title: "Alien")
        try writer.saveMovie(movie)

        let show = TVShowRecord(showId: "tmdb:20", title: "Dark")
        try writer.saveTVShow(show)
        try writer.saveSeason(SeasonRecord(showId: "tmdb:20", seasonNumber: 1))
        try writer.saveEpisode(EpisodeRecord(showId: "tmdb:20", seasonNumber: 1, episodeNumber: 1, title: "Secrets"))

        // 1. Match to movie
        try writer.matchFileToMovie(fileId: "f1", tmdbId: 10, provenance: .filename)
        var record = try db.read { db in try MediaFileRecord.fetchOne(db, key: "f1") }
        #expect(record?.matchState == .matched)
        #expect(record?.matchedMovie == 10)
        #expect(record?.matchedEpisode == nil)

        // 2. Match to episode
        try writer.matchFileToEpisode(fileId: "f1", showId: "tmdb:20", seasonNumber: 1, episodeNumber: 1, provenance: .user)
        record = try db.read { db in try MediaFileRecord.fetchOne(db, key: "f1") }
        #expect(record?.matchState == .matched)
        #expect(record?.matchedMovie == nil)
        #expect(record?.matchedEpisode == "tmdb:20:s1e1")
        #expect(record?.matchedShow == "tmdb:20")
        #expect(record?.matchProvenance == .user)

        // 3. Mark needs review
        try writer.markFileNeedsReview(fileId: "f1")
        record = try db.read { db in try MediaFileRecord.fetchOne(db, key: "f1") }
        #expect(record?.matchState == .needsReview)
        #expect(record?.matchedMovie == nil)
        #expect(record?.matchedEpisode == nil)

        // 4. Unmatch
        try writer.unmatchFile(fileId: "f1")
        record = try db.read { db in try MediaFileRecord.fetchOne(db, key: "f1") }
        #expect(record?.matchState == .unmatched)
    }

    @Test("Metadata save automatically synchronizes FTS index and people names")
    func metadataFTSSync() throws {
        let (db, writer) = try makeWriter()

        let movie = MovieRecord(
            tmdbId: 100,
            title: "Interstellar",
            alternativeTitles: "[\"Interestelar\"]",
            overview: "A team of explorers travel through a wormhole in space."
        )
        try writer.saveMovie(movie)

        // Verify in FTS
        let foundMovieRef = try db.read { db -> String? in
            let row = try Row.fetchOne(db, sql: "SELECT entity_ref FROM search_index WHERE search_index MATCH 'wormhole*';")
            return row?["entity_ref"]
        }
        #expect(foundMovieRef == "100")

        // Add person and credits for Interstellar
        let person = PersonRecord(personId: "tmdb:10297", name: "Matthew McConaughey")
        let credit = CreditRecord(
            entityKind: .movie,
            entityRef: "100",
            personId: "tmdb:10297",
            creditRole: .actor,
            character: "Cooper",
            ord: 0
        )
        try writer.savePeopleAndCredits(people: [person], credits: [credit])

        // Verify McConaughey is now searchable and associated with the movie in FTS
        let (foundByActorRef, actorPeopleNames) = try db.read { db -> (String?, String?) in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT entity_ref, people_names FROM search_index WHERE entity_kind = 'movie' AND search_index MATCH 'McConaughey*';"
            )
            return (row?["entity_ref"], row?["people_names"])
        }
        #expect(foundByActorRef == "100")
        #expect(actorPeopleNames == "Matthew McConaughey")
    }

    @Test("Atomic TV show re-keying cascades to all dependent tables")
    func atomicShowRekeying() throws {
        let (db, writer) = try makeWriter()

        // 1. Setup show with tvrage id
        let oldShowId = "tvrage:81081"
        let newShowId = "tmdb:1396"

        try writer.saveSource(SourceRecord(sourceId: "s1", kind: .local, name: "Disk", configRef: "ref"))

        let show = TVShowRecord(showId: oldShowId, tvdbId: 81081, title: "Breaking Bad")
        try writer.saveTVShow(show)

        let season = SeasonRecord(showId: oldShowId, seasonNumber: 1, title: "Season 1")
        try writer.saveSeason(season)

        let episode = EpisodeRecord(showId: oldShowId, seasonNumber: 1, episodeNumber: 1, title: "Pilot")
        try writer.saveEpisode(episode)

        let file = MediaFileRecord(
            fileId: "f1",
            sourceId: "s1",
            path: "bb_s1e1.mkv",
            uri: "file://bb_s1e1.mkv",
            matchState: .matched,
            matchedEpisode: "\(oldShowId):s1e1",
            matchedShow: oldShowId
        )
        try writer.saveMediaFiles([file])

        let identifier = IdentifierRecord(entityKind: .show, entityRef: oldShowId, provider: "tvdb", id: "81081")
        let epIdentifier = IdentifierRecord(entityKind: .episode, entityRef: "\(oldShowId):s1e1", provider: "tvdb", id: "1001")
        try db.write { db in
            try identifier.insert(db)
            try epIdentifier.insert(db)
        }

        let person = PersonRecord(personId: "tmdb:17419", name: "Bryan Cranston")
        let credit = CreditRecord(entityKind: .show, entityRef: oldShowId, personId: "tmdb:17419", creditRole: .actor, ord: 0)
        try writer.savePeopleAndCredits(people: [person], credits: [credit])

        let artwork = ArtworkRecord(entityKind: .show, entityRef: oldShowId, kind: .poster, provider: "tmdb", variant: "w500")
        try writer.saveArtwork([artwork])

        try db.write { db in
            try AccountRecord(accountId: "acc1", displayName: "User").insert(db)
        }

        try writer.saveWatchState(WatchStateRecord(
            entityKind: .episode,
            entityRef: "\(oldShowId):s1e1",
            account: "acc1",
            positionMs: 60000
        ))

        // 2. Perform Atomic Re-Key
        try writer.rekeyTVShow(from: oldShowId, to: newShowId, newTmdbId: 1396, newTvdbId: 81081)

        // 3. Verify all tables updated
        try db.read { db in
            // Old show is gone, new show exists with both IDs
            #expect(try TVShowRecord.fetchOne(db, key: oldShowId) == nil)
            let updatedShow = try TVShowRecord.fetchOne(db, key: newShowId)
            #expect(updatedShow != nil)
            #expect(updatedShow?.tmdbId == 1396)
            #expect(updatedShow?.tvdbId == 81081)

            // Season
            #expect(try SeasonRecord.fetchOne(db, key: ["show_id": oldShowId, "season_number": 1]) == nil)
            #expect(try SeasonRecord.fetchOne(db, key: ["show_id": newShowId, "season_number": 1]) != nil)

            // Episode
            #expect(try EpisodeRecord.fetchOne(db, key: ["show_id": oldShowId, "season_number": 1, "episode_number": 1]) == nil)
            #expect(try EpisodeRecord.fetchOne(db, key: ["show_id": newShowId, "season_number": 1, "episode_number": 1]) != nil)

            // Media file
            let updatedFile = try MediaFileRecord.fetchOne(db, key: "f1")
            #expect(updatedFile?.matchedShow == newShowId)
            #expect(updatedFile?.matchedEpisode == "\(newShowId):s1e1")

            // Identifiers
            let showIdent = try IdentifierRecord.fetchOne(db, key: ["entity_kind": "show", "entity_ref": newShowId, "provider": "tvdb"])
            #expect(showIdent?.id == "81081")
            let epIdent = try IdentifierRecord.fetchOne(db, key: ["entity_kind": "episode", "entity_ref": "\(newShowId):s1e1", "provider": "tvdb"])
            #expect(epIdent?.id == "1001")

            // Credits
            let showCredit = try CreditRecord.fetchOne(db, key: ["entity_kind": "show", "entity_ref": newShowId, "person_id": "tmdb:17419", "credit_role": "actor", "ord": 0])
            #expect(showCredit != nil)

            // Artwork
            let showArt = try ArtworkRecord.fetchOne(db, key: ["entity_kind": "show", "entity_ref": newShowId, "kind": "poster", "provider": "tmdb", "variant": "w500"])
            #expect(showArt != nil)

            // Watch state
            let ws = try WatchStateRecord.fetchOne(db, key: ["entity_kind": "episode", "entity_ref": "\(newShowId):s1e1", "account": "acc1"])
            #expect(ws?.positionMs == 60000)

            // Search index
            let ftsShow = try Row.fetchOne(db, sql: "SELECT entity_ref FROM search_index WHERE entity_kind = 'show';")
            #expect(ftsShow?["entity_ref"] == newShowId)
        }
    }

    @Test("Watch progress fast flushes and user rating")
    func watchProgressAndRating() throws {
        let (db, writer) = try makeWriter()

        try db.write { db in
            try AccountRecord(accountId: "acc1", displayName: "User").insert(db)
        }

        try writer.updateWatchProgress(
            account: "acc1",
            entityKind: .movie,
            entityRef: "550",
            positionMs: 120000,
            durationMs: 7200000,
            watched: false
        )

        var ws = try db.read { db in
            try WatchStateRecord.fetchOne(db, key: ["entity_kind": "movie", "entity_ref": "550", "account": "acc1"])
        }
        #expect(ws?.positionMs == 120000)
        #expect(ws?.durationMs == 7200000)
        #expect(ws?.watched == false)

        // Set user rating
        try writer.setUserRating(account: "acc1", entityKind: .movie, entityRef: "550", rating: 9)

        ws = try db.read { db in
            try WatchStateRecord.fetchOne(db, key: ["entity_kind": "movie", "entity_ref": "550", "account": "acc1"])
        }
        #expect(ws?.userRating == 9)
        #expect(ws?.positionMs == 120000) // progress preserved
    }

    @Test("Orphan GC removes unreferenced provider rows older than threshold")
    func orphanGC() throws {
        let (db, writer) = try makeWriter()

        let oldScrapedAt: Int64 = 1000
        let newScrapedAt: Int64 = 50000
        let threshold: Int64 = 25000

        // 1. Orphaned movie older than threshold
        let orphanMovie = MovieRecord(tmdbId: 1, title: "Old Orphan", scrapedAt: oldScrapedAt)
        try writer.saveMovie(orphanMovie)

        // 2. Movie older than threshold BUT referenced by file -> must NOT be deleted
        try writer.saveSource(SourceRecord(sourceId: "s1", kind: .local, name: "Disk", configRef: "ref"))
        let referencedMovie = MovieRecord(tmdbId: 2, title: "Old Referenced", scrapedAt: oldScrapedAt)
        try writer.saveMovie(referencedMovie)
        let file = MediaFileRecord(fileId: "f1", sourceId: "s1", path: "m.mkv", uri: "file://m.mkv", matchState: .matched, matchedMovie: 2)
        try writer.saveMediaFiles([file])

        // 3. Movie newer than threshold -> must NOT be deleted
        let freshMovie = MovieRecord(tmdbId: 3, title: "Fresh Movie", scrapedAt: newScrapedAt)
        try writer.saveMovie(freshMovie)

        // Run GC
        let result = try writer.runOrphanGC(thresholdEpochMs: threshold)
        #expect(result.moviesDeleted == 1)

        try db.read { db in
            #expect(try MovieRecord.fetchOne(db, key: 1) == nil)
            #expect(try MovieRecord.fetchOne(db, key: 2) != nil)
            #expect(try MovieRecord.fetchOne(db, key: 3) != nil)

            let metaGC = try MetaRecord.fetchOne(db, key: "last_gc_at")
            #expect(metaGC != nil)
        }
    }
}
