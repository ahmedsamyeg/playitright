// xcode: set sdk=tvOS

import Foundation

/// Type-safe representation and parsing of entity references in the database.
///
/// Ref patterns (Design 01 §3):
/// - movie: `"<tmdb_id>"` (e.g. `"550"`)
/// - show: `"<namespace>:<id>"` (e.g. `"tmdb:1396"`, `"tvrage:81081"`)
/// - season: `"<show_id>:s<season_number>"` (e.g. `"tmdb:1396:s1"`)
/// - episode: `"<show_id>:s<season_number>e<episode_number>"` (e.g. `"tmdb:1396:s1e5"`)
/// - person: `"<namespace>:<id>"` (e.g. `"tmdb:32231"`, `"local:christopher-nolan"`)
public enum EntityRef: Equatable, Hashable, Sendable {
    case movie(tmdbId: Int)
    case show(showId: String)
    case season(showId: String, seasonNumber: Int)
    case episode(showId: String, seasonNumber: Int, episodeNumber: Int)
    case person(personId: String)

    /// The string representation stored in `entity_ref` columns.
    public var rawValue: String {
        switch self {
        case .movie(let tmdbId):
            return String(tmdbId)
        case .show(let showId):
            return showId
        case .season(let showId, let seasonNumber):
            return "\(showId):s\(seasonNumber)"
        case .episode(let showId, let seasonNumber, let episodeNumber):
            return "\(showId):s\(seasonNumber)e\(episodeNumber)"
        case .person(let personId):
            return personId
        }
    }

    /// The entity kind corresponding to this reference.
    public var entityKind: EntityKind {
        switch self {
        case .movie:
            return .movie
        case .show:
            return .show
        case .season:
            return .season
        case .episode:
            return .episode
        case .person:
            return .person
        }
    }

    /// Parse an entity ref given its string and known entity kind.
    public static func parse(_ raw: String, kind: EntityKind) -> EntityRef? {
        switch kind {
        case .movie:
            guard let tmdbId = Int(raw) else { return nil }
            return .movie(tmdbId: tmdbId)

        case .show:
            // Must contain a namespace, e.g. "tmdb:1396" or "tvrage:81081"
            guard raw.contains(":") else { return nil }
            return .show(showId: raw)

        case .season:
            // Format: "<show_id>:s<n>"
            guard let lastColon = raw.range(of: ":s", options: .backwards) else { return nil }
            let showId = String(raw[..<lastColon.lowerBound])
            let seasonPart = raw[lastColon.upperBound...]
            guard let seasonNum = Int(seasonPart) else { return nil }
            return .season(showId: showId, seasonNumber: seasonNum)

        case .episode:
            // Format: "<show_id>:s<n>e<m>"
            guard let lastColon = raw.range(of: ":s", options: .backwards) else { return nil }
            let showId = String(raw[..<lastColon.lowerBound])
            let epPart = String(raw[lastColon.upperBound...])
            let components = epPart.split(separator: "e", maxSplits: 1)
            guard components.count == 2,
                  let seasonNum = Int(components[0]),
                  let episodeNum = Int(components[1]) else { return nil }
            return .episode(showId: showId, seasonNumber: seasonNum, episodeNumber: episodeNum)

        case .person:
            return .person(personId: raw)
        }
    }

    /// Format movie ref
    public static func movieRef(_ tmdbId: Int) -> String {
        String(tmdbId)
    }

    /// Format show ref
    public static func showRef(tmdbId: Int) -> String {
        "tmdb:\(tmdbId)"
    }

    public static func showRef(tvdbId: Int) -> String {
        "tvrage:\(tvdbId)"
    }

    /// Format season ref
    public static func seasonRef(showId: String, seasonNumber: Int) -> String {
        "\(showId):s\(seasonNumber)"
    }

    /// Format episode ref
    public static func episodeRef(showId: String, seasonNumber: Int, episodeNumber: Int) -> String {
        "\(showId):s\(seasonNumber)e\(episodeNumber)"
    }

    /// Format person ref
    public static func personRef(tmdbId: Int) -> String {
        "tmdb:\(tmdbId)"
    }

    public static func personRef(localSlug: String) -> String {
        "local:\(localSlug)"
    }
}
