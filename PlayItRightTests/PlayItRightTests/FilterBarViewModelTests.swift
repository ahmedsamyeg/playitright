import Foundation
import GRDB
import LibraryCore
import Testing
@testable import PlayItRight

private struct FilterHarness {
    let database: MediaDatabase
    let writer: MediaDatabaseWriter
    let reader: MediaDatabaseReader
}

@MainActor
private func makeHarness() throws -> FilterHarness {
    let database = try MediaDatabase.inMemory()
    try database.write { db in
        try AccountRecord(accountId: "local", displayName: "Local").insert(db)
    }
    let writer = MediaDatabaseWriter(database: database)
    try writer.saveSource(
        SourceRecord(sourceId: "s1", kind: .local, name: "Movies", configRef: "s1")
    )
    try database.write { db in
        try GenreRecord(kind: .movie, genreId: 28, name: "Action").insert(db)
        try GenreRecord(kind: .movie, genreId: 35, name: "Comedy").insert(db)
    }
    return FilterHarness(
        database: database,
        writer: writer,
        reader: MediaDatabaseReader(database: database)
    )
}

@MainActor
private func makeViewModel(_ harness: FilterHarness) -> FilterBarViewModel {
    FilterBarViewModel(reader: harness.reader, writer: harness.writer)
}

@MainActor
@Suite("FilterBarViewModel Tests")
struct FilterBarViewModelTests {
    @Test("Toggled chips compile to the matching SQL predicate")
    func chipsCompileToPredicate() throws {
        let harness = try makeHarness()
        let viewModel = makeViewModel(harness)

        viewModel.sourceId = "s1"
        viewModel.watched = .inProgress
        viewModel.toggleGenre(28)
        viewModel.toggleGenre(35)
        viewModel.resolution = .uhd4K
        viewModel.codec = "hevc"
        viewModel.hdr = .dolbyVision

        #expect(viewModel.activeGroupCount == 6)

        let filter = viewModel.makeFilter()
        #expect(filter.conjunction == .and)
        #expect(filter.rules.count == 7)

        let compiled = filter.compile()
        #expect(compiled.whereClause.contains("f.source_id = ?"))
        #expect(compiled.whereClause.contains("w.watched = ?"))
        #expect(compiled.whereClause.contains("w.position_ms > ?"))
        #expect(compiled.whereClause.contains("g.genre_id IN (?, ?)"))
        #expect(compiled.whereClause.contains("t.height >= ?"))
        #expect(compiled.whereClause.contains("t.codec = ?"))
        #expect(compiled.whereClause.contains("t.hdr_format LIKE ?"))
        #expect(compiled.joins.count == 3)

        viewModel.clear()
        #expect(viewModel.hasActiveFilters == false)
        #expect(viewModel.makeFilter().rules.isEmpty)
    }

    @Test("Watched and HD filters use the expected rules")
    func watchedAndResolutionRules() throws {
        let harness = try makeHarness()
        let viewModel = makeViewModel(harness)

        viewModel.watched = .watched
        #expect(
            viewModel.makeFilter().rules
                == [SmartFilterRule(field: .watched, operator: .equals, value: "1")]
        )

        viewModel.watched = .unwatched
        #expect(
            viewModel.makeFilter().rules
                == [SmartFilterRule(field: .watched, operator: .equals, value: "0")]
        )

        viewModel.watched = .any
        viewModel.resolution = .hd
        #expect(
            viewModel.makeFilter().rules
                == [SmartFilterRule(field: .height, operator: .lessThan, value: "2000")]
        )

        viewModel.hdr = .hdr10
        #expect(
            viewModel.makeFilter().rules.contains(
                SmartFilterRule(field: .hdrFormat, operator: .contains, value: "HDR")
            )
        )
    }

    @Test("Saving and recalling a Smart Library persists and restores filters")
    func saveAndRecall() async throws {
        let harness = try makeHarness()
        let viewModel = makeViewModel(harness)
        await viewModel.load()
        #expect(viewModel.sources.map(\.sourceId) == ["s1"])
        #expect(viewModel.genres.count == 2)

        viewModel.sourceId = "s1"
        viewModel.watched = .inProgress
        viewModel.toggleGenre(28)
        viewModel.resolution = .uhd4K
        viewModel.codec = "hevc"
        viewModel.hdr = .dolbyVision

        let record = try await viewModel.saveCurrentFilters(name: " 4K Action ")
        #expect(record.name == "4K Action")
        #expect(record.ord == 0)
        #expect(viewModel.savedLibraries.count == 1)

        let stored = try harness.reader.fetchSmartLibraries()
        #expect(stored.map(\.id) == [record.id])

        let reloaded = makeViewModel(harness)
        await reloaded.load()
        let saved = try #require(reloaded.savedLibraries.first)

        reloaded.clear()
        try reloaded.recall(saved)

        #expect(reloaded.sourceId == "s1")
        #expect(reloaded.watched == .inProgress)
        #expect(reloaded.genreIds == [28])
        #expect(reloaded.resolution == .uhd4K)
        #expect(reloaded.codec == "hevc")
        #expect(reloaded.hdr == .dolbyVision)
        #expect(reloaded.activeGroupCount == 6)
    }

    @Test("A Smart Library requires a name and a database")
    func saveValidation() async throws {
        let harness = try makeHarness()
        let viewModel = makeViewModel(harness)

        await #expect(throws: FilterBarError.missingName) {
            try await viewModel.saveCurrentFilters(name: "   ")
        }

        let noWriter = FilterBarViewModel(reader: harness.reader)
        await #expect(throws: FilterBarError.databaseUnavailable) {
            try await noWriter.saveCurrentFilters(name: "Anything")
        }
    }

    @Test("Deleting a saved Smart Library removes it from the database")
    func deleteSaved() async throws {
        let harness = try makeHarness()
        let viewModel = makeViewModel(harness)
        let record = try await viewModel.saveCurrentFilters(name: "Recent")
        #expect(viewModel.savedLibraries.count == 1)

        try await viewModel.deleteSavedLibrary(record)
        #expect(viewModel.savedLibraries.isEmpty)
        #expect(try harness.reader.fetchSmartLibraries().isEmpty)
    }
}
