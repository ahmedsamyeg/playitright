import Testing
import Foundation
import GRDB
@testable import LibraryCore

@Suite("Similar Titles Tests")
struct SimilarTitlesTests {
    private func makeSystem() throws -> (MediaDatabase, MediaDatabaseWriter, MediaDatabaseReader) {
        let db = try MediaDatabase.inMemory()
        let writer = MediaDatabaseWriter(database: db)
        let reader = MediaDatabaseReader(database: db)
        return (db, writer, reader)
    }

    private func seedTitles(_ writer: MediaDatabaseWriter) throws {
        try writer.saveMovie(MovieRecord(tmdbId: 1, title: "Arrival"))
        try writer.saveMovie(MovieRecord(tmdbId: 2, title: "Contact"))
        try writer.saveMovie(MovieRecord(tmdbId: 3, title: "Interstellar"))
        try writer.saveTVShow(TVShowRecord(showId: "tmdb:10", title: "Dark"))
    }

    @Test("Saving similar relations returns them ordered by rank")
    func saveAndFetchOrderedByRank() throws {
        let (_, writer, reader) = try makeSystem()
        try seedTitles(writer)

        // Caller passes an ordered list; the writer normalizes ranks to that order.
        let relations = [
            SimilarRecord(entityKind: .movie, entityRef: "1", simKind: .show, simRef: "tmdb:10", rank: 500),
            SimilarRecord(entityKind: .movie, entityRef: "1", simKind: .movie, simRef: "3", rank: 9),
            SimilarRecord(entityKind: .movie, entityRef: "1", simKind: .movie, simRef: "2", rank: 42)
        ]
        try writer.replaceSimilar(for: .movie(tmdbId: 1), with: relations)

        let similar = try reader.fetchSimilar(to: .movie(tmdbId: 1))
        #expect(similar.map(\.title) == ["Dark", "Interstellar", "Contact"])
        #expect(similar.map(\.rank) == [0, 1, 2])
        #expect(similar.map(\.entityKind) == [.show, .movie, .movie])
        #expect(similar.map(\.entityRef) == ["tmdb:10", "3", "2"])

        // Respect the limit while keeping rank order.
        let limited = try reader.fetchSimilar(to: .movie(tmdbId: 1), limit: 2)
        #expect(limited.map(\.title) == ["Dark", "Interstellar"])
    }

    @Test("Replacing relations does not duplicate previous rows")
    func replaceIsIdempotent() throws {
        let (_, writer, reader) = try makeSystem()
        try seedTitles(writer)

        let first = [
            SimilarRecord(entityKind: .movie, entityRef: "1", simKind: .movie, simRef: "2", rank: 0)
        ]
        try writer.replaceSimilar(for: .movie(tmdbId: 1), with: first)
        try writer.replaceSimilar(for: .movie(tmdbId: 1), with: first)

        let similar = try reader.fetchSimilar(to: .movie(tmdbId: 1))
        #expect(similar.count == 1)
        #expect(similar.first?.entityRef == "2")
    }

    @Test("Deleting an entity removes its similar relations")
    func deleteSimilarForEntity() throws {
        let (_, writer, reader) = try makeSystem()
        try seedTitles(writer)

        try writer.replaceSimilar(for: .movie(tmdbId: 1), with: [
            SimilarRecord(entityKind: .movie, entityRef: "1", simKind: .movie, simRef: "2", rank: 0)
        ])
        try writer.replaceSimilar(for: .movie(tmdbId: 2), with: [
            SimilarRecord(entityKind: .movie, entityRef: "2", simKind: .movie, simRef: "3", rank: 0)
        ])

        try writer.deleteSimilar(for: .movie(tmdbId: 1))

        #expect(try reader.fetchSimilar(to: .movie(tmdbId: 1)).isEmpty)
        #expect(try reader.fetchSimilar(to: .movie(tmdbId: 2)).count == 1)
    }

    @Test("Missing targets are hidden and orphaned relations are garbage-collected")
    func staleTargetCleanup() throws {
        let (db, writer, reader) = try makeSystem()
        try seedTitles(writer)

        try writer.replaceSimilar(for: .movie(tmdbId: 1), with: [
            SimilarRecord(entityKind: .movie, entityRef: "1", simKind: .movie, simRef: "2", rank: 0),
            SimilarRecord(entityKind: .movie, entityRef: "1", simKind: .movie, simRef: "3", rank: 1)
        ])

        // Simulate a removed movie without a dedicated delete API.
        try db.write { db in
            _ = try MovieRecord.deleteOne(db, key: 2)
        }

        // The reader never surfaces relations whose target no longer exists.
        let visible = try reader.fetchSimilar(to: .movie(tmdbId: 1))
        #expect(visible.map(\.entityRef) == ["3"])

        // Orphan GC prunes the stale row itself.
        _ = try writer.runOrphanGC(thresholdEpochMs: Int64.max)
        let remaining = try db.read { db in
            try SimilarRecord.fetchAll(db)
        }
        #expect(remaining.count == 1)
        #expect(remaining.first?.simRef == "3")
    }
}
