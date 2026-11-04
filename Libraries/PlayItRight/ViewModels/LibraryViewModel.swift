import Foundation
import LibraryCore
import Observation

/// How the library is presented.
public enum LibraryDensity: String, CaseIterable, Sendable, Codable, Equatable {
    case grid
    case list

    public var displayName: String {
        switch self {
        case .grid:
            return "Grid"
        case .list:
            return "List"
        }
    }

    public var systemImage: String {
        switch self {
        case .grid:
            return "square.grid.2x2"
        case .list:
            return "list.bullet"
        }
    }
}

/// Loads the keyset-paginated library grid/list, tracks the active sort and
/// density, and supplies watched/progress indicators (MD-11, NFR-1, doc 06 §2.3).
@MainActor
@Observable
public final class LibraryViewModel {
    public enum State: Sendable, Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Loads one more page when the focused item is within this many rows of
    /// the end, so scrolling never waits for a hard boundary.
    public static let prefetchThreshold = 5

    public private(set) var state: State = .idle
    public private(set) var items: [LibraryGridItem] = []
    public private(set) var isLoadingNextPage = false
    public private(set) var hasMore = true

    public private(set) var sort: LibrarySortOrder
    public private(set) var density: LibraryDensity

    public let pageSize: Int
    public let sourceId: String?

    private let reader: MediaDatabaseReader
    private let account: String
    private var cursor: LibrarySortCursor?
    private var watchedEntityRefs: Set<String> = []
    private var inProgressEntityRefs: Set<String> = []

    public init(
        reader: MediaDatabaseReader,
        account: String = "local",
        sourceId: String? = nil,
        pageSize: Int = 50,
        sort: LibrarySortOrder = .title,
        density: LibraryDensity = .grid
    ) {
        self.reader = reader
        self.account = account
        self.sourceId = sourceId
        self.pageSize = max(1, pageSize)
        self.sort = sort
        self.density = density
    }

    public var isEmpty: Bool {
        state == .loaded && items.isEmpty
    }

    /// Loads the first page if the view model is still idle.
    public func loadIfNeeded() async {
        guard state == .idle else {
            return
        }
        await reload()
    }

    /// Resets pagination and loads page one for the current sort.
    public func reload() async {
        guard !isLoadingNextPage else {
            return
        }
        state = .loading
        items = []
        cursor = nil
        hasMore = true
        await loadPage(append: false)
    }

    /// Changes the sort order and reloads from the first page.
    public func setSort(_ sort: LibrarySortOrder) async {
        guard sort != self.sort else {
            return
        }
        self.sort = sort
        await reload()
    }

    public func setDensity(_ density: LibraryDensity) {
        self.density = density
    }

    public func toggleDensity() {
        density = density == .grid ? .list : .grid
    }

    /// Requests the next page when `currentItem` reaches the shelf boundary.
    public func loadNextPageIfNeeded(currentItem: LibraryGridItem) async {
        guard hasMore, !isLoadingNextPage, !items.isEmpty else {
            return
        }
        guard let index = items.firstIndex(where: { $0.id == currentItem.id }) else {
            return
        }
        guard index >= max(0, items.count - Self.prefetchThreshold) else {
            return
        }
        isLoadingNextPage = true
        await loadPage(append: true)
    }

    /// Whether the item's title has been fully watched.
    public func isWatched(_ item: LibraryGridItem) -> Bool {
        if let tmdbId = item.tmdbId {
            return watchedEntityRefs.contains(String(tmdbId))
        }
        return false
    }

    /// Whether the item has partial progress to resume.
    public func isInProgress(_ item: LibraryGridItem) -> Bool {
        if let tmdbId = item.tmdbId {
            return inProgressEntityRefs.contains(String(tmdbId))
        }
        return false
    }

    // MARK: - Private

    private func loadPage(append: Bool) async {
        let reader = reader
        let account = account
        let sort = self.sort
        let pageCursor = append ? self.cursor : nil
        let limit = pageSize
        let sourceId = sourceId

        do {
            let page = try await Task.detached(priority: .userInitiated) {
                let items = try reader.fetchLibraryGridPage(
                    sourceId: sourceId,
                    sortedBy: sort,
                    after: pageCursor,
                    limit: limit
                )
                let states = try reader.fetchWatchStates(account: account)
                return LibraryPage(items: items, watchStates: states)
            }.value

            if append {
                items.append(contentsOf: page.items)
            } else {
                items = page.items
            }
            applyWatchStates(page.watchStates)

            if let last = page.items.last {
                self.cursor = MediaDatabaseReader.cursor(for: last, sortedBy: sort)
            }
            hasMore = page.items.count == limit
            state = .loaded
            isLoadingNextPage = false
        } catch {
            isLoadingNextPage = false
            state = .failed(error.localizedDescription)
        }
    }

    private func applyWatchStates(_ states: [WatchStateRecord]) {
        var watched: Set<String> = []
        var inProgress: Set<String> = []
        for state in states {
            guard state.entityKind == .movie else {
                continue
            }
            if state.watched {
                watched.insert(state.entityRef)
            } else if state.positionMs > 0 {
                inProgress.insert(state.entityRef)
            }
        }
        watchedEntityRefs = watched
        inProgressEntityRefs = inProgress
    }
}

private struct LibraryPage: Sendable {
    let items: [LibraryGridItem]
    let watchStates: [WatchStateRecord]

    nonisolated init(items: [LibraryGridItem], watchStates: [WatchStateRecord]) {
        self.items = items
        self.watchStates = watchStates
    }
}
