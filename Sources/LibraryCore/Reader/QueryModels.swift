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

    public var id: String { fileId }

    public init(
        fileId: String,
        path: String,
        matchState: MatchState,
        durationMs: Int64?,
        displayTitle: String,
        tmdbId: Int?,
        showId: String?
    ) {
        self.fileId = fileId
        self.path = path
        self.matchState = matchState
        self.durationMs = durationMs
        self.displayTitle = displayTitle
        self.tmdbId = tmdbId
        self.showId = showId
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
