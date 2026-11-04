import Foundation
import LibraryCore
import Observation

/// The percentage shown in a Continue Watching progress ring (MD-9).
public struct ContinueWatchingProgress: Sendable, Equatable {
    public let positionMs: Int64
    public let durationMs: Int64?

    public init(positionMs: Int64, durationMs: Int64?) {
        self.positionMs = max(0, positionMs)
        self.durationMs = durationMs
    }

    /// Fraction watched, clamped to 0...1. Unknown durations show an empty ring.
    public var fraction: Double {
        guard let durationMs, durationMs > 0 else {
            return 0
        }
        return min(1, max(0, Double(positionMs) / Double(durationMs)))
    }

    /// Whole-number percentage for the ring's label.
    public var percentage: Int {
        Int((fraction * 100).rounded())
    }

    public var label: String {
        "\(percentage)%"
    }

    public var isNearlyFinished: Bool {
        fraction >= 0.9
    }
}

/// A Continue Watching card and its resume state.
public struct ContinueWatchingCard: Sendable, Equatable, Identifiable {
    public let item: ContinueWatchingItem

    public var id: String { item.id }
    public var title: String { item.title }
    public var progress: ContinueWatchingProgress {
        ContinueWatchingProgress(
            positionMs: item.positionMs,
            durationMs: item.durationMs
        )
    }

    /// Episode cards use the show as the subtitle; movies fall back to nothing.
    public var subtitle: String? {
        guard let showTitle = item.showTitle else {
            return nil
        }
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            return "\(showTitle) · S\(season) E\(episode)"
        }
        return showTitle
    }

    public init(item: ContinueWatchingItem) {
        self.item = item
    }
}

/// One item in a Home shelf.
public enum HomeShelfItem: Sendable, Equatable, Identifiable {
    case continueWatching(ContinueWatchingCard)
    case recentlyAdded(RecentlyAddedItem)
    case library(LibraryGridItem)

    public var id: String {
        switch self {
        case .continueWatching(let card):
            return "continue:\(card.id)"
        case .recentlyAdded(let item):
            return "recent:\(item.id)"
        case .library(let item):
            return "file:\(item.id)"
        }
    }

    public var title: String {
        switch self {
        case .continueWatching(let card):
            return card.title
        case .recentlyAdded(let item):
            return item.title
        case .library(let item):
            return item.displayTitle
        }
    }

    public var subtitle: String? {
        switch self {
        case .continueWatching(let card):
            return card.subtitle
        case .recentlyAdded, .library:
            return nil
        }
    }

    public var progress: ContinueWatchingProgress? {
        if case .continueWatching(let card) = self {
            return card.progress
        }
        return nil
    }
}

/// A reorderable row on the Home screen.
public struct HomeShelf: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case continueWatching
        case recentlyAdded
        case library(sourceId: String)
    }

    public let kind: Kind
    public let title: String
    public let items: [HomeShelfItem]

    public var id: String {
        switch kind {
        case .continueWatching:
            return "continue-watching"
        case .recentlyAdded:
            return "recently-added"
        case .library(let sourceId):
            return "library:\(sourceId)"
        }
    }

    public init(kind: Kind, title: String, items: [HomeShelfItem]) {
        self.kind = kind
        self.title = title
        self.items = items
    }
}

/// Persists the user's shelf order across launches.
public protocol HomeShelfOrderStore: Sendable {
    func loadOrder() -> [String]
    func saveOrder(_ ids: [String])
}

/// `UserDefaults`-backed shelf ordering.
public final class UserDefaultsHomeShelfOrderStore: HomeShelfOrderStore, @unchecked Sendable {
    public static let defaultKey = "home.shelf.order"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = UserDefaultsHomeShelfOrderStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func loadOrder() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    public func saveOrder(_ ids: [String]) {
        defaults.set(ids, forKey: key)
    }
}

/// A source and the first page of its library shelf.
public struct HomeLibraryShelf: Sendable, Equatable, Identifiable {
    public let summary: LibraryShelfSummary
    public let items: [LibraryGridItem]

    public var id: String { summary.sourceId }

    nonisolated public init(summary: LibraryShelfSummary, items: [LibraryGridItem]) {
        self.summary = summary
        self.items = items
    }
}

/// Loads the Home screen shelves and keeps their order (MD-9, doc 06 §2.2).
@MainActor
@Observable
public final class HomeViewModel {
    public enum State: Sendable, Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public static let continueWatchingTitle = "Continue Watching"
    public static let recentlyAddedTitle = "Recently Added"

    public private(set) var state: State = .idle
    public private(set) var continueWatching: [ContinueWatchingCard] = []
    public private(set) var recentlyAdded: [RecentlyAddedItem] = []
    public private(set) var libraryShelves: [HomeLibraryShelf] = []
    public private(set) var shelfOrder: [String] = []

    private let reader: MediaDatabaseReader
    private let account: String
    private let shelfLimit: Int
    private let orderStore: any HomeShelfOrderStore

    public init(
        reader: MediaDatabaseReader,
        account: String = "local",
        shelfLimit: Int = 20,
        orderStore: any HomeShelfOrderStore = UserDefaultsHomeShelfOrderStore()
    ) {
        self.reader = reader
        self.account = account
        self.shelfLimit = max(1, shelfLimit)
        self.orderStore = orderStore
        self.shelfOrder = orderStore.loadOrder()
    }

    public var isEmpty: Bool {
        continueWatching.isEmpty
            && recentlyAdded.isEmpty
            && libraryShelves.allSatisfy(\.items.isEmpty)
    }

    /// Shelves in the user's saved order, followed by any new shelves.
    public var shelves: [HomeShelf] {
        let shelves = defaultShelves
        let lookup = Dictionary(
            uniqueKeysWithValues: shelves.enumerated().map { ($1.id, $0) }
        )
        let known = shelfOrder.compactMap { lookup[$0] }
        let knownSet = Set(known)
        let remaining = shelves.indices.filter { !knownSet.contains($0) }
        return (known + remaining).map { shelves[$0] }
    }

    /// Loads all Home shelves from the library database off the main actor.
    public func load() async {
        state = .loading
        let reader = reader
        let account = account
        let limit = shelfLimit

        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                let continueWatching = try reader.fetchContinueWatching(
                    account: account,
                    limit: limit
                )
                let recentlyAdded = try reader.fetchRecentlyAdded(limit: limit)
                let summaries = try reader.fetchLibraryShelves()
                let libraries = try summaries.map { summary in
                    HomeLibraryShelf(
                        summary: summary,
                        items: try reader.fetchLibraryGrid(
                            sourceId: summary.sourceId,
                            limit: limit
                        )
                    )
                }
                return HomeSnapshot(
                    continueWatching: continueWatching,
                    recentlyAdded: recentlyAdded,
                    libraries: libraries
                )
            }.value

            apply(snapshot)
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Moves a shelf and persists the new order.
    public func moveShelf(from source: Int, to destination: Int) {
        var ordered = shelves
        guard ordered.indices.contains(source),
              ordered.indices.contains(destination),
              source != destination else {
            return
        }
        let shelf = ordered.remove(at: source)
        ordered.insert(shelf, at: destination)
        shelfOrder = ordered.map(\.id)
        orderStore.saveOrder(shelfOrder)
    }

    public func moveShelfUp(_ id: String) {
        guard let index = shelves.firstIndex(where: { $0.id == id }) else {
            return
        }
        moveShelf(from: index, to: max(0, index - 1))
    }

    public func moveShelfDown(_ id: String) {
        guard let index = shelves.firstIndex(where: { $0.id == id }) else {
            return
        }
        moveShelf(from: index, to: min(shelves.count - 1, index + 1))
    }

    public func resetShelfOrder() {
        shelfOrder = []
        orderStore.saveOrder([])
    }

    // MARK: - Private

    private var defaultShelves: [HomeShelf] {
        var shelves: [HomeShelf] = []

        if !continueWatching.isEmpty {
            shelves.append(
                HomeShelf(
                    kind: .continueWatching,
                    title: Self.continueWatchingTitle,
                    items: continueWatching.map(HomeShelfItem.continueWatching)
                )
            )
        }

        if !recentlyAdded.isEmpty {
            shelves.append(
                HomeShelf(
                    kind: .recentlyAdded,
                    title: Self.recentlyAddedTitle,
                    items: recentlyAdded.map(HomeShelfItem.recentlyAdded)
                )
            )
        }

        for library in libraryShelves where !library.items.isEmpty {
            shelves.append(
                HomeShelf(
                    kind: .library(sourceId: library.summary.sourceId),
                    title: library.summary.name,
                    items: library.items.map(HomeShelfItem.library)
                )
            )
        }

        return shelves
    }

    private func apply(_ snapshot: HomeSnapshot) {
        continueWatching = snapshot.continueWatching
            .sorted {
                ($0.lastWatchedAt ?? 0) > ($1.lastWatchedAt ?? 0)
            }
            .map(ContinueWatchingCard.init(item:))

        recentlyAdded = snapshot.recentlyAdded
        libraryShelves = snapshot.libraries

        // Keep previously saved shelves first; new shelves are appended.
        let currentIDs = Set(defaultShelves.map(\.id))
        shelfOrder = shelfOrder.filter { currentIDs.contains($0) }
    }
}

private struct HomeSnapshot: Sendable {
    let continueWatching: [ContinueWatchingItem]
    let recentlyAdded: [RecentlyAddedItem]
    let libraries: [HomeLibraryShelf]

    nonisolated init(
        continueWatching: [ContinueWatchingItem],
        recentlyAdded: [RecentlyAddedItem],
        libraries: [HomeLibraryShelf]
    ) {
        self.continueWatching = continueWatching
        self.recentlyAdded = recentlyAdded
        self.libraries = libraries
    }
}
