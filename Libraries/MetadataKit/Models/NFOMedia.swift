import Foundation

/// The kind of local metadata file that was parsed.
public enum NFOMediaKind: String, Codable, Sendable, Equatable {
    case movie
    case tvShow = "tvshow"
    case episode
}

/// A cast or crew entry from an NFO file.
public struct NFOCastMember: Codable, Sendable, Equatable {
    public var name: String
    public var role: String?
    public var order: Int?
    public var imageURL: String?

    public init(
        name: String,
        role: String? = nil,
        order: Int? = nil,
        imageURL: String? = nil
    ) {
        self.name = name
        self.role = role
        self.order = order
        self.imageURL = imageURL
    }
}

/// Metadata read from a local Kodi/Emby NFO or sidecar text file.
///
/// Local metadata is the highest-priority text source in the matching ladder
/// (doc 05 §1): when present, these fields override server- and provider-
/// supplied values for the same field.
public struct NFOMedia: Codable, Sendable, Equatable {
    public var kind: NFOMediaKind
    public var title: String
    public var originalTitle: String?
    public var sortTitle: String?
    public var year: Int?
    public var plot: String?
    public var tagline: String?
    public var rating: Double?
    public var votes: Int?
    public var runtimeMinutes: Int?
    public var mpaa: String?
    public var genres: [String]
    public var directors: [String]
    public var cast: [NFOCastMember]
    public var tmdbID: Int?
    public var imdbID: String?
    public var tvdbID: Int?
    public var season: Int?
    public var episode: Int?
    public var absoluteEpisode: Int?
    public var aired: String?

    public init(
        kind: NFOMediaKind,
        title: String,
        originalTitle: String? = nil,
        sortTitle: String? = nil,
        year: Int? = nil,
        plot: String? = nil,
        tagline: String? = nil,
        rating: Double? = nil,
        votes: Int? = nil,
        runtimeMinutes: Int? = nil,
        mpaa: String? = nil,
        genres: [String] = [],
        directors: [String] = [],
        cast: [NFOCastMember] = [],
        tmdbID: Int? = nil,
        imdbID: String? = nil,
        tvdbID: Int? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        absoluteEpisode: Int? = nil,
        aired: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.originalTitle = originalTitle
        self.sortTitle = sortTitle
        self.year = year
        self.plot = plot
        self.tagline = tagline
        self.rating = rating
        self.votes = votes
        self.runtimeMinutes = runtimeMinutes
        self.mpaa = mpaa
        self.genres = genres
        self.directors = directors
        self.cast = cast
        self.tmdbID = tmdbID
        self.imdbID = imdbID
        self.tvdbID = tvdbID
        self.season = season
        self.episode = episode
        self.absoluteEpisode = absoluteEpisode
        self.aired = aired
    }

    /// Returns a copy where `self` (local NFO) wins for every field it defines.
    ///
    /// Empty strings, empty arrays, and `nil` values fall through to `remote`
    /// so a sparse NFO can still be gap-filled by a provider.
    public func overriding(_ remote: NFOMedia) -> NFOMedia {
        var merged = remote
        merged.kind = kind

        if !title.isEmpty {
            merged.title = title
        }
        merged.originalTitle = originalTitle ?? remote.originalTitle
        merged.sortTitle = sortTitle ?? remote.sortTitle
        merged.year = year ?? remote.year
        merged.plot = plot ?? remote.plot
        merged.tagline = tagline ?? remote.tagline
        merged.rating = rating ?? remote.rating
        merged.votes = votes ?? remote.votes
        merged.runtimeMinutes = runtimeMinutes ?? remote.runtimeMinutes
        merged.mpaa = mpaa ?? remote.mpaa
        merged.genres = genres.isEmpty ? remote.genres : genres
        merged.directors = directors.isEmpty ? remote.directors : directors
        merged.cast = cast.isEmpty ? remote.cast : cast
        merged.tmdbID = tmdbID ?? remote.tmdbID
        merged.imdbID = imdbID ?? remote.imdbID
        merged.tvdbID = tvdbID ?? remote.tvdbID
        merged.season = season ?? remote.season
        merged.episode = episode ?? remote.episode
        merged.absoluteEpisode = absoluteEpisode ?? remote.absoluteEpisode
        merged.aired = aired ?? remote.aired
        return merged
    }
}
