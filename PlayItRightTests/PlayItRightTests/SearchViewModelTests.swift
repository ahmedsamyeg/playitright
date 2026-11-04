import Foundation
import GRDB
import LibraryCore
import Testing
@testable import PlayItRight

// MARK: - Fakes

private final class StubCandidateProvider: MatchCandidateProvider {
    var candidates: [MatchCandidate]
    private(set) var queries: [String] = []

    init(candidates: [MatchCandidate]) {
        self.candidates = candidates
    }

    func candidates(for query: String) async throws -> [MatchCandidate] {
        queries.append(query)
        return candidates
    }
}

private struct SearchHarness {
    let database: MediaDatabase
    let writer: MediaDatabaseWriter
    let reader: MediaDatabaseReader
}

@MainActor
private func makeHarness() throws -> SearchHarness {
    let database = try MediaDatabase.inMemory()
    let writer = MediaDatabaseWriter(database: database)
    try writer.saveSource(
        SourceRecord(sourceId: "s1", kind: .local, name: "Movies", configRef: "s1")
    )
    return SearchHarness(
        database: database,
        writer: writer,
        reader: MediaDatabaseReader(database: database)
    )
}

private extension SearchHarness {
    func addMovie(tmdbId: Int, title: String, overview: String? = nil) throws {
        try writer.saveMovie(
            MovieRecord(tmdbId: tmdbId, title: title, overview: overview)
        )
    }

    @discardableResult
    func addUnmatchedFile(
        fileId: String = "unmatched-1",
        path: String = "/movies/The.Matrix.1999.mkv",
        matchState: MatchState = .needsReview
    ) throws -> MediaFileRecord {
        let file = MediaFileRecord(
            fileId: fileId,
            sourceId: "s1",
            path: path,
            uri: "file://\(path)",
            matchState: matchState,
            addedAt: 1_700_000_000_000
        )
        try writer.saveMediaFiles([file])
        return file
    }
}

// MARK: - Tests

@MainActor
@Suite("SearchViewModel Tests")
struct SearchViewModelTests {
    @Test("Search updates with prefix token matching")
    func prefixTokenSearch() async throws {
        let harness = try makeHarness()
        try harness.addMovie(tmdbId: 603, title: "The Matrix")
        try harness.addMovie(tmdbId: 604, title: "The Matrix Reloaded")
        try harness.addMovie(tmdbId: 605, title: "John Wick")

        let viewModel = SearchViewModel(
            reader: harness.reader,
            writer: harness.writer,
            debounce: .zero
        )

        viewModel.queryChanged("Matri")
        await viewModel.waitForPendingSearch()

        #expect(viewModel.state == .loaded)
        #expect(viewModel.results.map(\.title).sorted() == [
            "The Matrix",
            "The Matrix Reloaded"
        ])
        #expect(viewModel.hasQuery)

        viewModel.queryChanged("Wick")
        await viewModel.waitForPendingSearch()
        #expect(viewModel.results.map(\.title) == ["John Wick"])

        viewModel.clearQuery()
        #expect(viewModel.results.isEmpty)
        #expect(viewModel.hasQuery == false)
    }

    @Test("Rapid keystrokes coalesce into the final query")
    func debounceCoalescesKeystrokes() async throws {
        let harness = try makeHarness()
        try harness.addMovie(tmdbId: 1, title: "Matrix")
        try harness.addMovie(tmdbId: 2, title: "Mad Max")

        let viewModel = SearchViewModel(
            reader: harness.reader,
            writer: harness.writer,
            debounce: .milliseconds(20)
        )

        viewModel.queryChanged("Mat")
        viewModel.queryChanged("Mad")
        await viewModel.waitForPendingSearch()

        #expect(viewModel.results.map(\.title) == ["Mad Max"])
    }

    @Test("Unmatched files load newest first")
    func unmatchedFilesLoad() async throws {
        let harness = try makeHarness()
        try harness.addUnmatchedFile(
            fileId: "old",
            path: "/movies/Old.mkv",
            matchState: .unmatched
        )
        try harness.addUnmatchedFile(
            fileId: "new",
            path: "/movies/New.mkv",
            matchState: .needsReview
        )
        try harness.addMovie(tmdbId: 9, title: "Matched")
        try harness.writer.saveMediaFiles([
            MediaFileRecord(
                fileId: "matched",
                sourceId: "s1",
                path: "/movies/Matched.mkv",
                uri: "file:///movies/Matched.mkv",
                matchState: .matched,
                matchedMovie: 9,
                addedAt: 1_700_000_000_500
            )
        ])

        let viewModel = SearchViewModel(reader: harness.reader)
        await viewModel.loadUnmatchedFiles()

        #expect(viewModel.unmatchedFiles.map(\.fileId) == ["new", "old"])
    }

    @Test("Selecting a file asks the provider for candidates")
    func selectFileLoadsCandidates() async throws {
        let harness = try makeHarness()
        let file = try harness.addUnmatchedFile()
        let provider = StubCandidateProvider(candidates: [
            MatchCandidate(
                tmdbId: 603,
                title: "The Matrix",
                year: 1999,
                overview: "A hacker learns the truth.",
                posterPath: "https://image.tmdb.org/t/p/w342/matrix.jpg"
            ),
            MatchCandidate(tmdbId: 604, title: "The Matrix Reloaded", year: 2003)
        ])

        let viewModel = SearchViewModel(
            reader: harness.reader,
            writer: harness.writer,
            candidateProvider: provider
        )
        await viewModel.loadUnmatchedFiles()
        await viewModel.selectFile(file)

        #expect(provider.queries == ["The Matrix 1999"])
        #expect(viewModel.selectedFile?.fileId == file.fileId)
        #expect(viewModel.candidates.map(\.tmdbId) == [603, 604])
        #expect(viewModel.isLoadingCandidates == false)

        viewModel.clearSelection()
        #expect(viewModel.selectedFile == nil)
        #expect(viewModel.candidates.isEmpty)
    }

    @Test("Manual match writes matched_movie with user provenance")
    func manualMatchUpdatesDatabase() async throws {
        let harness = try makeHarness()
        let file = try harness.addUnmatchedFile()

        let viewModel = SearchViewModel(
            reader: harness.reader,
            writer: harness.writer,
            candidateProvider: StubCandidateProvider(candidates: [
                MatchCandidate(tmdbId: 603, title: "The Matrix")
            ])
        )
        await viewModel.loadUnmatchedFiles()
        await viewModel.selectFile(file)
        try await viewModel.applyMovieMatch(tmdbId: 603)

        let stored = try #require(
            harness.reader.fetchFiles(sourceId: "s1").first { $0.fileId == file.fileId }
        )
        #expect(stored.matchState == .matched)
        #expect(stored.matchedMovie == 603)
        #expect(stored.matchProvenance == .user)
        #expect(viewModel.lastMatchFileId == file.fileId)
        #expect(viewModel.unmatchedFiles.isEmpty)
        #expect(viewModel.selectedFile == nil)
    }

    @Test("Manual match requires a selected file and a writer")
    func manualMatchValidation() async throws {
        let harness = try makeHarness()

        let noSelection = SearchViewModel(reader: harness.reader, writer: harness.writer)
        await #expect(throws: SearchError.noFileSelected) {
            try await noSelection.applyMovieMatch(tmdbId: 1)
        }

        let file = try harness.addUnmatchedFile()
        let noWriter = SearchViewModel(reader: harness.reader)
        await noWriter.loadUnmatchedFiles()
        await noWriter.selectFile(file)
        await #expect(throws: SearchError.databaseUnavailable) {
            try await noWriter.applyMovieMatch(tmdbId: 1)
        }
    }

    @Test("Keeping a file needing review clears the selection")
    func markNeedsReview() async throws {
        let harness = try makeHarness()
        let file = try harness.addUnmatchedFile(matchState: .unmatched)

        let viewModel = SearchViewModel(reader: harness.reader, writer: harness.writer)
        await viewModel.loadUnmatchedFiles()
        await viewModel.selectFile(file)
        try await viewModel.markSelectedNeedsReview()

        let stored = try #require(
            harness.reader.fetchFiles(sourceId: "s1").first { $0.fileId == file.fileId }
        )
        #expect(stored.matchState == .needsReview)
        #expect(viewModel.unmatchedFiles.isEmpty)
        #expect(viewModel.selectedFile == nil)
    }

    @Test("File names become readable candidate queries")
    func fileNameQuery() {
        #expect(
            SearchViewModel.titleFromFileName("/movies/The.Matrix.1999.1080p.mkv")
                == "The Matrix 1999 1080p"
        )
        #expect(
            SearchViewModel.titleFromFileName("The_Office_S02E03.mp4")
                == "The Office S02E03"
        )
        #expect(
            SearchViewModel.titleFromFileName("Blade-Runner-2049.m4v")
                == "Blade Runner 2049"
        )
    }
}
