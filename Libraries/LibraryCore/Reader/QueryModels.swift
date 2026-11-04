import Foundation

public struct LibraryGridCursor: Sendable, Equatable, Hashable {
    public let displayTitle: String
    public let fileId: String

    public init(displayTitle: String, fileId: String) {
        self.displayTitle = displayTitle
        self.fileId = fileId
    }
}

public struct LibraryGridItem: Sendable, Equatable, Identifiable {
    public let fileId: String
    public let path: String
    public let matchState: MatchState
    public let durationMs: Int64?
    public let displayTitle: String
    public let tmdbId: Int?
    public let showId: String?
    public let sourceId: String?
    public let year: Int?
    public let ratingScore: Double?
    public let addedAt: Int64
    public let has4K: Bool
    public let hasDolbyVision: Bool
    public let hasAtmos: Bool

    public var id: String { fileId }

    public init(
        fileId: String,
        path: String,
        matchState: MatchState,
        durationMs: Int64?,
        displayTitle: String,
        tmdbId: Int?,
        showId: String?,
        sourceId: String? = nil,
        year: Int? = nil,
        ratingScore: Double? = nil,
        addedAt: Int64 = 0,
        has4K: Bool = false,
        hasDolbyVision: Bool = false,
        hasAtmos: Bool = false
    ) {
        self.fileId = fileId
        self.path = path
        self.matchState = matchState
        self.durationMs = durationMs
        self.displayTitle = displayTitle
        self.tmdbId = tmdbId
        self.showId = showId
        self.sourceId = sourceId
        self.year = year
        self.ratingScore = ratingScore
        self.addedAt = addedAt
        self.has4K = has4K
        self.hasDolbyVision = hasDolbyVision
        self.hasAtmos = hasAtmos
    }
}

/// Sort options offered by the library grid and list (MD-11).
public enum LibrarySortOrder: String, Sendable, CaseIterable, Codable, Equatable {
    case title
    case year
    case dateAdded
    case rating

    public var displayName: String {
        switch self {
        case .title:
            return "Title"
        case .year:
            return "Year"
        case .dateAdded:
            return "Date Added"
        case .rating:
            return "Rating"
        }
    }

    /// Title sorts A–Z; the other options show the newest/best first.
    public var isDescending: Bool {
        self != .title
    }
}

/// Keyset cursor for a sorted library page.
public struct LibrarySortCursor: Sendable, Equatable, Hashable {
    public let sortKey: String
    public let fileId: String

    public init(sortKey: String, fileId: String) {
        self.sortKey = sortKey
        self.fileId = fileId
    }
}

public struct ContinueWatchingItem: Sendable, Equatable, Identifiable {
    public let entityKind: EntityKind
    public let entityRef: String
    public let title: String
    public let showTitle: String?
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let positionMs: Int64
    public let durationMs: Int64?
    public let lastWatchedAt: Int64?

    public var id: String { "\(entityKind.rawValue):\(entityRef)" }

    public init(
        entityKind: EntityKind,
        entityRef: String,
        title: String,
        showTitle: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        positionMs: Int64,
        durationMs: Int64?,
        lastWatchedAt: Int64?
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.title = title
        self.showTitle = showTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.lastWatchedAt = lastWatchedAt
    }
}

/// A file in the "Recently Added" shelf (MD-9).
///
/// `title` prefers the matched movie/show title and falls back to the file path
/// so newly scanned, not-yet-matched files still appear immediately.
public struct RecentlyAddedItem: Sendable, Equatable, Identifiable {
    public let fileId: String
    public let title: String
    public let sourceId: String
    public let addedAt: Int64
    public let durationMs: Int64?
    public let tmdbId: Int?
    public let showId: String?

    public var id: String { fileId }

    public init(
        fileId: String,
        title: String,
        sourceId: String,
        addedAt: Int64,
        durationMs: Int64?,
        tmdbId: Int?,
        showId: String?
    ) {
        self.fileId = fileId
        self.title = title
        self.sourceId = sourceId
        self.addedAt = addedAt
        self.durationMs = durationMs
        self.tmdbId = tmdbId
        self.showId = showId
    }
}

/// Summary of one configured source that appears as its own Home shelf.
public struct LibraryShelfSummary: Sendable, Equatable, Identifiable {
    public let sourceId: String
    public let name: String
    public let itemCount: Int

    public var id: String { sourceId }

    public init(sourceId: String, name: String, itemCount: Int) {
        self.sourceId = sourceId
        self.name = name
        self.itemCount = itemCount
    }
}

public struct SearchResultItem: Sendable, Equatable {
    public let entityKind: EntityKind
    public let entityRef: String
    public let title: String
    public let overview: String?
    public let peopleNames: String?
    public let rank: Double

    public init(
        entityKind: EntityKind,
        entityRef: String,
        title: String,
        overview: String?,
        peopleNames: String?,
        rank: Double
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.title = title
        self.overview = overview
        self.peopleNames = peopleNames
        self.rank = rank
    }
}

public struct SimilarTitleItem: Sendable, Equatable, Identifiable {
    public let entityKind: EntityKind
    public let entityRef: String
    public let title: String
    public let rank: Int

    public var id: String { "\(entityKind.rawValue):\(entityRef)" }

    public init(
        entityKind: EntityKind,
        entityRef: String,
        title: String,
        rank: Int
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.title = title
        self.rank = rank
    }
}

public struct CreditDetailItem: Sendable, Equatable, Identifiable {
    public let creditRole: CreditRole
    public let character: String?
    public let job: String?
    public let ord: Int
    public let name: String
    public let personId: String
    public let headshotPath: String?

    public var id: String { "\(personId):\(creditRole.rawValue):\(ord)" }

    public init(
        creditRole: CreditRole,
        character: String?,
        job: String?,
        ord: Int,
        name: String,
        personId: String,
        headshotPath: String?
    ) {
        self.creditRole = creditRole
        self.character = character
        self.job = job
        self.ord = ord
        self.name = name
        self.personId = personId
        self.headshotPath = headshotPath
    }
}
