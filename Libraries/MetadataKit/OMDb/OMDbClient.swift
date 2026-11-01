import Foundation

// MARK: - Configuration

/// Configuration for ``OMDbClient``.
public struct OMDbConfiguration: Sendable, Equatable {
    /// Default OMDb API root.
    public static let defaultBaseURL = URL(string: "https://www.omdbapi.com/")!

    /// API root, normally `https://www.omdbapi.com/`.
    public var baseURL: URL

    /// OMDb API key.
    public var apiKey: String?

    /// Per-request URL session timeout.
    public var requestTimeout: TimeInterval

    public init(
        apiKey: String? = nil,
        baseURL: URL = OMDbConfiguration.defaultBaseURL,
        requestTimeout: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.requestTimeout = max(1, requestTimeout)
    }

    /// Reads `OMDB_API_KEY` (or `OMDB_APIKEY`) from environment variables.
    public static func fromEnvironment(
        _ variables: [String: String] = ProcessInfo.processInfo.environment
    ) -> OMDbConfiguration {
        let key = (variables["OMDB_API_KEY"] ?? variables["OMDB_APIKEY"])
        return OMDbConfiguration(apiKey: key)
    }
}

/// Errors raised by ``OMDbClient``.
public enum OMDbError: Error, Sendable, Equatable, LocalizedError {
    /// No API key was configured.
    case missingAPIKey

    /// The request URL could not be constructed.
    case invalidURL(String)

    /// The server returned a non-HTTP response.
    case invalidResponse

    /// OMDb answered successfully but had no matching title.
    case notFound(String)

    /// The server returned a non-success status.
    case httpStatus(Int, message: String?)

    /// The response body did not match the expected DTO.
    case decoding(String)

    /// The transport failed before a response was received.
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No OMDb API key is configured."
        case .invalidURL(let value):
            return "Could not build an OMDb request URL for '\(value)'."
        case .invalidResponse:
            return "OMDb returned a response that was not HTTP."
        case .notFound(let message):
            return message
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                return "OMDb returned HTTP \(status): \(message)"
            }
            return "OMDb returned HTTP \(status)."
        case .decoding(let message):
            return "Could not decode the OMDb response: \(message)"
        case .transport(let message):
            return "OMDb request failed: \(message)"
        }
    }
}

// MARK: - Models

/// The kind of title OMDb should match.
public enum OMDbMediaType: String, Codable, Sendable, CaseIterable {
    case movie
    case series
    case episode
}

/// How much plot OMDb should return.
public enum OMDbPlot: String, Sendable, CaseIterable {
    case short
    case full
}

/// A rating from one OMDb source.
public struct OMDbRating: Codable, Sendable, Equatable {
    public var source: String
    public var value: String

    public init(source: String, value: String) {
        self.source = source
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case source = "Source"
        case value = "Value"
    }
}

/// A title returned by an OMDb lookup.
///
/// OMDb reports "not found" as a successful HTTP response with
/// `Response: "False"`, so the raw response fields are retained alongside the
/// decoded media fields.
public struct OMDbMedia: Codable, Sendable, Equatable {
    public var title: String?
    public var year: String?
    public var rated: String?
    public var released: String?
    public var runtime: String?
    public var genre: String?
    public var director: String?
    public var writer: String?
    public var actors: String?
    public var plot: String?
    public var language: String?
    public var country: String?
    public var awards: String?
    public var poster: String?
    public var ratings: [OMDbRating]?
    public var metascore: String?
    public var imdbRating: String?
    public var imdbVotes: String?
    public var imdbID: String?
    public var type: String?
    public var dvd: String?
    public var boxOffice: String?
    public var production: String?
    public var website: String?
    public var response: String?
    public var error: String?
    public var totalSeasons: String?
    public var season: String?
    public var episode: String?
    public var seriesID: String?

    /// Whether OMDb matched the request.
    public var isSuccess: Bool {
        response?.caseInsensitiveCompare("True") == .orderedSame
    }

    /// First year parsed from a value such as `2010` or `2010–2015`.
    public var yearStart: Int? {
        guard let year else {
            return nil
        }
        let digits = year.prefix(4)
        return Int(digits)
    }

    /// Runtime in minutes parsed from a value such as `148 min`.
    public var runtimeMinutes: Int? {
        guard let runtime else {
            return nil
        }
        return Int(runtime.prefix { $0.isNumber })
    }

    /// Genre names split from OMDb's comma-separated value.
    public var genreNames: [String] {
        Self.splitList(genre)
    }

    /// Director names split from OMDb's comma-separated value.
    public var directorNames: [String] {
        Self.splitList(director)
    }

    /// Writer names split from OMDb's comma-separated value.
    public var writerNames: [String] {
        Self.splitList(writer)
    }

    /// Actor names split from OMDb's comma-separated value.
    public var actorNames: [String] {
        Self.splitList(actors)
    }

    /// Language names split from OMDb's comma-separated value.
    public var languageNames: [String] {
        Self.splitList(language)
    }

    /// Country names split from OMDb's comma-separated value.
    public var countryNames: [String] {
        Self.splitList(country)
    }

    /// IMDb rating as a number, when OMDb supplied one.
    public var imdbRatingValue: Double? {
        guard let imdbRating else {
            return nil
        }
        return Double(imdbRating)
    }

    /// IMDb vote count with thousands separators removed.
    public var imdbVoteCount: Int? {
        guard let imdbVotes else {
            return nil
        }
        return Int(imdbVotes.replacingOccurrences(of: ",", with: ""))
    }

    /// Values for ratings keyed by source, for example
    /// `"Rotten Tomatoes": "87%"`.
    public var ratingsBySource: [String: String] {
        Dictionary(
            uniqueKeysWithValues: (ratings ?? []).map {
                ($0.source, $0.value)
            }
        )
    }

    private static func splitList(_ value: String?) -> [String] {
        guard let value else {
            return []
        }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare("N/A") != .orderedSame }
    }

    enum CodingKeys: String, CodingKey {
        case title = "Title"
        case year = "Year"
        case rated = "Rated"
        case released = "Released"
        case runtime = "Runtime"
        case genre = "Genre"
        case director = "Director"
        case writer = "Writer"
        case actors = "Actors"
        case plot = "Plot"
        case language = "Language"
        case country = "Country"
        case awards = "Awards"
        case poster = "Poster"
        case ratings = "Ratings"
        case metascore = "Metascore"
        case imdbRating = "imdbRating"
        case imdbVotes = "imdbVotes"
        case imdbID = "imdbID"
        case type = "Type"
        case dvd = "DVD"
        case boxOffice = "BoxOffice"
        case production = "Production"
        case website = "Website"
        case response = "Response"
        case error = "Error"
        case totalSeasons = "totalSeasons"
        case season = "Season"
        case episode = "Episode"
        case seriesID = "seriesID"
    }
}

/// A compact result from OMDb's `s=` search endpoint.
public struct OMDbSearchResult: Codable, Sendable, Equatable, Identifiable {
    public var title: String
    public var year: String?
    public var imdbID: String
    public var type: String?
    public var poster: String?

    public var id: String {
        imdbID
    }

    /// First year parsed from the result's year string.
    public var yearStart: Int? {
        guard let year else {
            return nil
        }
        return Int(year.prefix(4))
    }

    enum CodingKeys: String, CodingKey {
        case title = "Title"
        case year = "Year"
        case imdbID = "imdbID"
        case type = "Type"
        case poster = "Poster"
    }
}

/// The envelope returned by OMDb's search endpoint.
public struct OMDbSearchResponse: Codable, Sendable, Equatable {
    public var search: [OMDbSearchResult]?
    public var totalResults: String?
    public var response: String?
    public var error: String?

    /// Whether OMDb matched the search request.
    public var isSuccess: Bool {
        response?.caseInsensitiveCompare("True") == .orderedSame
    }

    /// Total matches as a number.
    public var totalResultCount: Int? {
        totalResults.flatMap(Int.init)
    }

    enum CodingKeys: String, CodingKey {
        case search = "Search"
        case totalResults = "totalResults"
        case response = "Response"
        case error = "Error"
    }
}

// MARK: - Client

/// Async client for the OMDb fallback provider.
///
/// OMDb is used to enrich movies by IMDb id or to find a title when TMDB has
/// no record (doc 05 §1).
public final class OMDbClient: Sendable {
    public let configuration: OMDbConfiguration

    private let session: URLSession

    public init(
        configuration: OMDbConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    /// Looks up a title by its IMDb id.
    public func lookup(
        imdbID: String,
        plot: OMDbPlot = .full
    ) async throws -> OMDbMedia {
        try await mediaRequest(
            queryItems: [URLQueryItem(name: "i", value: imdbID)],
            plot: plot
        )
    }

    /// Looks up a title by name, optionally constrained by year and type.
    public func lookup(
        title: String,
        year: Int? = nil,
        type: OMDbMediaType? = nil,
        plot: OMDbPlot = .full
    ) async throws -> OMDbMedia {
        var queryItems = [URLQueryItem(name: "t", value: title)]
        if let year {
            queryItems.append(URLQueryItem(name: "y", value: String(year)))
        }
        if let type {
            queryItems.append(URLQueryItem(name: "type", value: type.rawValue))
        }
        return try await mediaRequest(queryItems: queryItems, plot: plot)
    }

    /// Searches OMDb for matching titles.
    public func search(
        title: String,
        year: Int? = nil,
        type: OMDbMediaType? = nil,
        page: Int = 1
    ) async throws -> OMDbSearchResponse {
        var queryItems = [
            URLQueryItem(name: "s", value: title),
            URLQueryItem(name: "page", value: String(max(1, page)))
        ]
        if let year {
            queryItems.append(URLQueryItem(name: "y", value: String(year)))
        }
        if let type {
            queryItems.append(URLQueryItem(name: "type", value: type.rawValue))
        }

        let request = try makeRequest(queryItems: queryItems)
        let data = try await perform(request)
        let response: OMDbSearchResponse = try decode(data)

        guard response.isSuccess else {
            throw OMDbError.notFound(response.error ?? "No OMDb results.")
        }
        return response
    }

    private func mediaRequest(
        queryItems: [URLQueryItem],
        plot: OMDbPlot
    ) async throws -> OMDbMedia {
        var items = queryItems
        items.append(URLQueryItem(name: "plot", value: plot.rawValue))

        let request = try makeRequest(queryItems: items)
        let data = try await perform(request)
        let media: OMDbMedia = try decode(data)

        guard media.isSuccess else {
            throw OMDbError.notFound(media.error ?? "No OMDb match.")
        }
        return media
    }

    private func makeRequest(
        queryItems: [URLQueryItem]
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw OMDbError.invalidURL(configuration.baseURL.absoluteString)
        }

        guard let apiKey = nonEmpty(configuration.apiKey) else {
            throw OMDbError.missingAPIKey
        }

        components.queryItems = queryItems
            + [URLQueryItem(name: "apikey", value: apiKey)]

        guard let url = components.url else {
            throw OMDbError.invalidURL(configuration.baseURL.absoluteString)
        }

        var request = URLRequest(
            url: url,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OMDbError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OMDbError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            throw OMDbError.httpStatus(
                http.statusCode,
                message: Self.apiMessage(from: data)
            )
        }

        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OMDbError.decoding(String(describing: error))
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func apiMessage(from data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            var error: String?

            enum CodingKeys: String, CodingKey {
                case error = "Error"
            }
        }

        return try? JSONDecoder()
            .decode(ErrorEnvelope.self, from: data)
            .error
    }
}
