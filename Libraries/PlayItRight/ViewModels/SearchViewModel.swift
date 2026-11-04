import Foundation
import LibraryCore
import MetadataKit
import Observation

/// One possible TMDB match for an unmatched file.
public struct MatchCandidate: Sendable, Equatable, Identifiable {
    public let tmdbId: Int
    public let title: String
    public let year: Int?
    public let overview: String?
    public let posterPath: String?

    public var id: Int { tmdbId }

    public init(
        tmdbId: Int,
        title: String,
        year: Int? = nil,
        overview: String? = nil,
        posterPath: String? = nil
    ) {
        self.tmdbId = tmdbId
        self.title = title
        self.year = year
        self.overview = overview
        self.posterPath = posterPath
    }
}

/// Supplies candidate titles for the Fix Matching screen.
@MainActor
public protocol MatchCandidateProvider {
    func candidates(for query: String) async throws -> [MatchCandidate]
}

/// TMDB-backed candidate provider used by the app.
@MainActor
public final class TMDBMatchCandidateProvider: MatchCandidateProvider {
    private let client: TMDBClient

    public init(configuration: TMDBConfiguration = .fromEnvironment()) {
        self.client = TMDBClient(configuration: configuration)
    }

    public func candidates(for query: String) async throws -> [MatchCandidate] {
        let response = try await client.searchMovies(query: query)
        return response.results.map { result in
            MatchCandidate(
                tmdbId: result.id,
                title: result.title,
                year: result.releaseDate.flatMap { Int($0.prefix(4)) },
                overview: result.overview,
                posterPath: client.imageURL(path: result.posterPath, size: "w342")?.absoluteString
            )
        }
    }
}

/// Instant search over the local FTS index plus the Fix Matching workflow
/// (MD-1, MD-2, doc 05 §1, doc 06 §2.6).
@MainActor
@Observable
public final class SearchViewModel {
    public enum State: Sendable, Equatable {
        case idle
        case searching
        case loaded
        case failed(String)
    }

    public static let defaultDebounce = Duration.milliseconds(250)

    public private(set) var state: State = .idle
    public private(set) var query = ""
    public private(set) var results: [SearchResultItem] = []
    public private(set) var unmatchedFiles: [MediaFileRecord] = []
    public private(set) var candidates: [MatchCandidate] = []
    public private(set) var selectedFile: MediaFileRecord?
    public private(set) var isLoadingCandidates = false
    public private(set) var lastMatchFileId: String?

    public let debounce: Duration
    public let sourceId: String?

    private let reader: MediaDatabaseReader
    private let writer: MediaDatabaseWriter?
    private let candidateProvider: (any MatchCandidateProvider)?
    private var pendingSearch: Task<Void, Never>?

    public init(
        reader: MediaDatabaseReader,
        writer: MediaDatabaseWriter? = nil,
        sourceId: String? = nil,
        candidateProvider: (any MatchCandidateProvider)? = nil,
        debounce: Duration = SearchViewModel.defaultDebounce
    ) {
        self.reader = reader
        self.writer = writer
        self.sourceId = sourceId
        self.candidateProvider = candidateProvider
        self.debounce = debounce
    }

    public var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isEmpty: Bool {
        state == .loaded && results.isEmpty
    }

    /// Debounced entry point for every keystroke.
    public func queryChanged(_ text: String) {
        query = text
        pendingSearch?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            state = .loaded
            return
        }

        pendingSearch = Task { [weak self] in
            guard let self else {
                return
            }
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled else {
                return
            }
            await performSearch(trimmed)
        }
    }

    /// Cancels the debounce and searches immediately (used by the UI when the
    /// keyboard's Search key is pressed).
    public func searchImmediately() async {
        pendingSearch?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            state = .loaded
            return
        }
        await performSearch(trimmed)
    }

    /// Waits for the debounced search, if one is pending. Tests use this to
    /// avoid sleeping on wall-clock time.
    public func waitForPendingSearch() async {
        await pendingSearch?.value
    }

    public func clearQuery() {
        pendingSearch?.cancel()
        query = ""
        results = []
        state = .loaded
    }

    // MARK: - Fix Matching

    public func loadUnmatchedFiles() async {
        let reader = reader
        let sourceId = sourceId
        do {
            unmatchedFiles = try await Task.detached(priority: .userInitiated) {
                try reader.fetchUnmatchedFiles(sourceId: sourceId)
            }.value
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Selects an unmatched file and asks the provider for candidate titles.
    public func selectFile(_ file: MediaFileRecord) async {
        selectedFile = file
        candidates = []

        guard let candidateProvider else {
            return
        }
        isLoadingCandidates = true
        defer { isLoadingCandidates = false }

        let derived = Self.titleFromFileName(file.path)
        do {
            candidates = try await candidateProvider.candidates(for: derived)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func clearSelection() {
        selectedFile = nil
        candidates = []
    }

    /// Applies a manual movie match and records the user provenance.
    public func applyMovieMatch(tmdbId: Int) async throws {
        guard let file = selectedFile else {
            throw SearchError.noFileSelected
        }
        guard let writer else {
            throw SearchError.databaseUnavailable
        }

        let writerCopy = writer
        let readerCopy = reader
        let fileId = file.fileId
        let title = candidates.first { $0.tmdbId == tmdbId }?.title
            ?? "TMDB \(tmdbId)"
        try await Task.detached(priority: .userInitiated) {
            // The candidate may not be indexed yet; insert a minimal movie row
            // so the media_files foreign key is satisfied.
            if try readerCopy.fetchMovie(tmdbId: tmdbId) == nil {
                try writerCopy.saveMovie(
                    MovieRecord(tmdbId: tmdbId, title: title)
                )
            }
            try writerCopy.matchFileToMovie(
                fileId: fileId,
                tmdbId: tmdbId,
                provenance: .user
            )
        }.value

        lastMatchFileId = fileId
        unmatchedFiles.removeAll { $0.fileId == fileId }
        clearSelection()
    }

    /// Marks the selected file for review instead of guessing a match.
    public func markSelectedNeedsReview() async throws {
        guard let file = selectedFile else {
            throw SearchError.noFileSelected
        }
        guard let writer else {
            throw SearchError.databaseUnavailable
        }
        let writerCopy = writer
        let fileId = file.fileId
        try await Task.detached(priority: .userInitiated) {
            try writerCopy.markFileNeedsReview(fileId: fileId)
        }.value
        unmatchedFiles.removeAll { $0.fileId == fileId }
        clearSelection()
    }

    // MARK: - Private

    private func performSearch(_ text: String) async {
        state = .searching
        let reader = reader
        let sourceId = sourceId

        do {
            let matches = try await Task.detached(priority: .userInitiated) {
                try reader.search(query: text, sourceId: sourceId)
            }.value
            results = matches
            state = .loaded
        } catch {
            results = []
            state = .failed(error.localizedDescription)
        }
    }

    /// Turns a file name into a query, e.g. `/Movies/The.Matrix.1999.mkv` into
    /// `The Matrix 1999`.
    nonisolated public static func titleFromFileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let withoutExtension = (name as NSString).deletingPathExtension
        let cleaned = withoutExtension
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return cleaned
            .split(separator: " ")
            .joined(separator: " ")
    }
}

public enum SearchError: Error, Sendable, Equatable, LocalizedError {
    case noFileSelected
    case databaseUnavailable

    public var errorDescription: String? {
        switch self {
        case .noFileSelected:
            return "Choose a file to match first."
        case .databaseUnavailable:
            return "The library database is unavailable."
        }
    }
}
