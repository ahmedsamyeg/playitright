import Foundation

// MARK: - Shared value types

/// A TMDB genre such as `Action` or `Drama`.
public struct TMDBGenre: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
}

/// A production company attached to a movie or show.
public struct TMDBProductionCompany: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var logoPath: String?
    public var originCountry: String?
}

/// A production country attached to a movie or show.
public struct TMDBProductionCountry: Codable, Sendable, Equatable {
    public var iso31661: String
    public var name: String
}

/// A spoken language attached to a movie or show.
public struct TMDBSpokenLanguage: Codable, Sendable, Equatable {
    public var iso6391: String
    public var englishName: String
    public var name: String
}

/// A TV network attached to a show.
public struct TMDBTVNetwork: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var logoPath: String?
    public var originCountry: String?
}

/// A collection that groups related movies (for example a franchise).
public struct TMDBCollection: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var posterPath: String?
    public var backdropPath: String?
}

/// A person as returned by list and credit endpoints.
public struct TMDBPerson: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var originalName: String?
    public var profilePath: String?
    public var knownForDepartment: String?
    public var gender: Int?
    public var popularity: Double?
    public var adult: Bool?
}

// MARK: - Search

/// The response envelope for `/search/movie`.
public struct TMDBMovieSearchResponse: Codable, Sendable, Equatable {
    public var page: Int
    public var results: [TMDBMovieSearchResult]
    public var totalPages: Int
    public var totalResults: Int
}

/// A movie result from `/search/movie`.
public struct TMDBMovieSearchResult: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var title: String
    public var originalTitle: String?
    public var originalLanguage: String?
    public var overview: String?
    public var releaseDate: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var genreIds: [Int]?
    public var popularity: Double?
    public var voteAverage: Double?
    public var voteCount: Int?
    public var adult: Bool?
    public var video: Bool?
}

/// The response envelope for `/search/tv`.
public struct TMDBTVSearchResponse: Codable, Sendable, Equatable {
    public var page: Int
    public var results: [TMDBTVSearchResult]
    public var totalPages: Int
    public var totalResults: Int
}

/// A show result from `/search/tv`.
public struct TMDBTVSearchResult: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var originalName: String?
    public var originalLanguage: String?
    public var overview: String?
    public var firstAirDate: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var genreIds: [Int]?
    public var popularity: Double?
    public var voteAverage: Double?
    public var voteCount: Int?
    public var originCountry: [String]?
    public var adult: Bool?
}

// MARK: - Movie detail

/// The full movie record returned by `/movie/{id}`.
public struct TMDBMovie: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var imdbId: String?
    public var title: String
    public var originalTitle: String?
    public var originalLanguage: String?
    public var overview: String?
    public var tagline: String?
    public var status: String?
    public var releaseDate: String?
    public var runtime: Int?
    public var budget: Int?
    public var revenue: Int?
    public var homepage: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var adult: Bool?
    public var popularity: Double?
    public var voteAverage: Double?
    public var voteCount: Int?
    public var genres: [TMDBGenre]?
    public var productionCompanies: [TMDBProductionCompany]?
    public var productionCountries: [TMDBProductionCountry]?
    public var spokenLanguages: [TMDBSpokenLanguage]?
    public var belongsToCollection: TMDBCollection?
}

// MARK: - TV detail

/// A season as it appears inside a show response.
public struct TMDBSeasonSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var overview: String?
    public var airDate: String?
    public var episodeCount: Int?
    public var posterPath: String?
    public var seasonNumber: Int
}

/// The full show record returned by `/tv/{id}`.
public struct TMDBTVShow: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var originalName: String?
    public var originalLanguage: String?
    public var overview: String?
    public var tagline: String?
    public var status: String?
    public var type: String?
    public var homepage: String?
    public var firstAirDate: String?
    public var lastAirDate: String?
    public var inProduction: Bool?
    public var numberOfSeasons: Int?
    public var numberOfEpisodes: Int?
    public var episodeRunTime: [Int]?
    public var popularity: Double?
    public var posterPath: String?
    public var backdropPath: String?
    public var voteAverage: Double?
    public var voteCount: Int?
    public var adult: Bool?
    public var originCountry: [String]?
    public var languages: [String]?
    public var genres: [TMDBGenre]?
    public var networks: [TMDBTVNetwork]?
    public var productionCompanies: [TMDBProductionCompany]?
    public var productionCountries: [TMDBProductionCountry]?
    public var spokenLanguages: [TMDBSpokenLanguage]?
    public var createdBy: [TMDBPerson]?
    public var seasons: [TMDBSeasonSummary]?
    public var lastEpisodeToAir: TMDBEpisode?
    public var nextEpisodeToAir: TMDBEpisode?
}

/// A season with its full episode list, returned by
/// `/tv/{id}/season/{season_number}`.
public struct TMDBSeasonDetail: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var overview: String?
    public var airDate: String?
    public var seasonNumber: Int
    public var posterPath: String?
    public var episodes: [TMDBEpisode]?
    public var networks: [TMDBTVNetwork]?
}

/// An episode inside a season or a show's next/last episode fields.
public struct TMDBEpisode: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var overview: String?
    public var airDate: String?
    public var episodeNumber: Int?
    public var seasonNumber: Int?
    public var productionCode: String?
    public var stillPath: String?
    public var runtime: Int?
    public var voteAverage: Double?
    public var voteCount: Int?
    public var crew: [TMDBCrewMember]?
    public var guestStars: [TMDBCastMember]?
}

// MARK: - Credits

/// A cast credit from `/movie/{id}/credits` or `/tv/{id}/credits`.
public struct TMDBCastMember: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var originalName: String?
    public var character: String?
    public var creditId: String?
    public var order: Int?
    public var profilePath: String?
    public var knownForDepartment: String?
    public var gender: Int?
    public var popularity: Double?
    public var adult: Bool?
}

/// A crew credit from `/movie/{id}/credits` or `/tv/{id}/credits`.
public struct TMDBCrewMember: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var originalName: String?
    public var creditId: String?
    public var department: String?
    public var job: String?
    public var profilePath: String?
    public var knownForDepartment: String?
    public var gender: Int?
    public var popularity: Double?
    public var adult: Bool?
}

/// The credits envelope returned by the credits endpoints.
public struct TMDBCredits: Codable, Sendable, Equatable {
    public var id: Int
    public var cast: [TMDBCastMember]
    public var crew: [TMDBCrewMember]
}

// MARK: - Videos

/// A trailer, teaser, or featurette returned by the videos endpoints.
public struct TMDBVideo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var iso6391: String?
    public var iso31661: String?
    public var name: String
    public var key: String
    public var site: String
    public var size: Int?
    public var type: String
    public var official: Bool?
    public var publishedAt: String?
}

/// The videos envelope returned by `/movie/{id}/videos` and
/// `/tv/{id}/videos`.
public struct TMDBVideosResponse: Codable, Sendable, Equatable {
    public var id: Int
    public var results: [TMDBVideo]
}

// MARK: - Convenience

public extension TMDBMovieSearchResult {
    /// Release year parsed from TMDB's `YYYY-MM-DD` release date.
    var releaseYear: Int? {
        TMDBDateParser.year(from: releaseDate)
    }
}

public extension TMDBTVSearchResult {
    /// First-air year parsed from TMDB's `YYYY-MM-DD` date.
    var firstAirYear: Int? {
        TMDBDateParser.year(from: firstAirDate)
    }
}

public extension TMDBMovie {
    /// Release year parsed from TMDB's `YYYY-MM-DD` release date.
    var releaseYear: Int? {
        TMDBDateParser.year(from: releaseDate)
    }
}

public extension TMDBTVShow {
    /// First-air year parsed from TMDB's `YYYY-MM-DD` date.
    var firstAirYear: Int? {
        TMDBDateParser.year(from: firstAirDate)
    }
}

/// Parses the date strings TMDB uses (`YYYY-MM-DD`).
public enum TMDBDateParser {
    /// Returns the year component of an ISO-style TMDB date, if present.
    public static func year(from value: String?) -> Int? {
        guard let value, value.count >= 4 else {
            return nil
        }
        return Int(value.prefix(4))
    }

    /// Parses a TMDB `YYYY-MM-DD` date in the Gregorian calendar.
    public static func date(from value: String?) -> Date? {
        guard let value else {
            return nil
        }
        let components = value.split(separator: "-")
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        )
    }
}
