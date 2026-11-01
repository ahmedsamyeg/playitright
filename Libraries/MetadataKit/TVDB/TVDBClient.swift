import Foundation

// MARK: - Configuration

/// Configuration for ``TVDBClient``.
public struct TVDBConfiguration: Sendable, Equatable {
    /// Default TVDB v4 API root.
    public static let defaultBaseURL = URL(string: "https://api4.thetvdb.com/v4")!

    /// API root, normally `https://api4.thetvdb.com/v4`.
    public var baseURL: URL

    /// TVDB v4 API key.
    public var apiKey: String?

    /// Optional subscriber PIN required by some TVDB accounts.
    public var pin: String?

    /// Per-request URL session timeout.
    public var requestTimeout: TimeInterval

    public init(
        apiKey: String? = nil,
        pin: String? = nil,
        baseURL: URL = TVDBConfiguration.defaultBaseURL,
        requestTimeout: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.pin = pin
        self.baseURL = baseURL
        self.requestTimeout = max(1, requestTimeout)
    }

    /// Reads `TVDB_API_KEY` and `TVDB_PIN` from environment variables.
    public static func fromEnvironment(
        _ variables: [String: String] = ProcessInfo.processInfo.environment
    ) -> TVDBConfiguration {
        TVDBConfiguration(
            apiKey: variables["TVDB_API_KEY"],
            pin: variables["TVDB_PIN"]
        )
    }
}

/// Errors raised by ``TVDBClient``.
public enum TVDBError: Error, Sendable, Equatable, LocalizedError {
    /// No API key was configured.
    case missingAPIKey

    /// The request URL could not be constructed.
    case invalidURL(String)

    /// The server returned a non-HTTP response.
    case invalidResponse

    /// Login succeeded but returned no usable token.
    case loginFailed(String)

    /// The requested series could not be found.
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
            return "No TVDB API key is configured."
        case .invalidURL(let value):
            return "Could not build a TVDB request URL for '\(value)'."
        case .invalidResponse:
            return "TVDB returned a response that was not HTTP."
        case .loginFailed(let message):
            return "TVDB login failed: \(message)"
        case .notFound(let message):
            return message
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                return "TVDB returned HTTP \(status): \(message)"
            }
            return "TVDB returned HTTP \(status)."
        case .decoding(let message):
            return "Could not decode the TVDB response: \(message)"
        case .transport(let message):
            return "TVDB request failed: \(message)"
        }
    }
}

// MARK: - Models

/// A compact series result from `/search`.
public struct TVDBSearchResult: Codable, Sendable, Equatable {
    public var tvdbId: String?
    public var name: String?
    public var primaryType: String?
    public var firstAirTime: String?
    public var overview: String?
    public var imageUrl: String?
    public var country: String?

    /// Numeric TVDB series id, when the string id could be parsed.
    public var seriesID: Int? {
        tvdbId.flatMap(Int.init)
    }
}

/// A TVDB series status record.
public struct TVDBStatus: Codable, Sendable, Equatable {
    public var id: Int?
    public var name: String?

    /// Human-readable status, matching the older string-shaped API field.
    public var stringValue: String? {
        name
    }
}

/// A TVDB series record.
public struct TVDBSeries: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String?
    public var slug: String?
    public var image: String?
    public var firstAired: String?
    public var lastAired: String?
    public var overview: String?
    public var status: TVDBStatus?
    public var averageRuntime: Int?
    public var year: String?

    /// First-air year parsed from TVDB's `YYYY-MM-DD` date.
    public var firstAiredYear: Int? {
        guard let firstAired, firstAired.count >= 4 else {
            return nil
        }
        return Int(firstAired.prefix(4))
    }
}

/// A TVDB episode record.
public struct TVDBEpisode: Codable, Sendable, Equatable, Identifiable {
    public var id: Int?
    public var seriesId: Int?
    public var name: String?
    public var aired: String?
    public var runtime: Int?
    public var image: String?
    public var number: Int?
    public var seasonNumber: Int?
    public var absoluteNumber: Int?
    public var overview: String?
    public var finaleType: String?
}

/// The `data` payload for `/series/{id}/episodes/default`.
public struct TVDBEpisodeCollection: Codable, Sendable, Equatable {
    public var series: TVDBSeries?
    public var episodes: [TVDBEpisode]?
}

/// A season/episode pair derived from TVDB's flat episode list.
public struct TVDBEpisodeMapping: Codable, Sendable, Equatable {
    public var seasonNumber: Int
    public var episodeNumber: Int
    public var absoluteNumber: Int?
    public var name: String?
    public var airDate: String?

    public init(
        seasonNumber: Int,
        episodeNumber: Int,
        absoluteNumber: Int? = nil,
        name: String? = nil,
        airDate: String? = nil
    ) {
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.absoluteNumber = absoluteNumber
        self.name = name
        self.airDate = airDate
    }
}

// MARK: - Envelopes

private struct TVDBEnvelope<Value: Decodable>: Decodable {
    var status: String?
    var data: Value?
    var message: String?
}

private struct TVDBLoginData: Decodable {
    var token: String?
}

private struct TVDBLoginResponse: Decodable {
    var status: String?
    var data: TVDBLoginData?
    var message: String?
}

private struct TVDBLoginRequest: Encodable {
    var apikey: String
    var pin: String?
}

// MARK: - Client

/// Async actor for the TVDB v4 API.
///
/// TVDB uses bearer tokens obtained from `/login`. The actor caches the token
/// for the lifetime of the client, re-authenticates after a `401`, and exposes
/// flat episode lists plus season/episode mappings for the show catalog.
public actor TVDBClient {
    public let configuration: TVDBConfiguration

    private let session: URLSession
    private var token: String?

    public init(
        configuration: TVDBConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: Authentication

    /// Returns a cached token or logs in to TVDB.
    @discardableResult
    public func login(force: Bool = false) async throws -> String {
        if !force, let token {
            return token
        }

        guard let apiKey = nonEmpty(configuration.apiKey) else {
            throw TVDBError.missingAPIKey
        }

        var request = try makeRequest(path: "login")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = TVDBLoginRequest(
            apikey: apiKey,
            pin: nonEmpty(configuration.pin)
        )
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw TVDBError.decoding(String(describing: error))
        }

        let data = try await send(request)
        let response: TVDBLoginResponse = try decode(data)

        guard let token = response.data?.token, !token.isEmpty else {
            throw TVDBError.loginFailed(
                response.message ?? response.status ?? "No token returned."
            )
        }

        self.token = token
        return token
    }

    // MARK: Series lookup

    /// Searches TVDB for series matching a title.
    public func searchSeries(
        query: String
    ) async throws -> [TVDBSearchResult] {
        let data = try await authorized(
            path: "search",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "type", value: "series")
            ]
        )
        let envelope: TVDBEnvelope<[TVDBSearchResult]> = try decode(data)
        return envelope.data ?? []
    }

    /// Resolves a title to a TVDB series id.
    ///
    /// Exact case/diacritic-insensitive matches win, then prefix matches, then
    /// the first search result.
    public func seriesID(forTitle title: String) async throws -> Int? {
        let results = try await searchSeries(query: title)
        let normalizedTitle = normalized(title)

        if let exact = results.first(where: {
            normalized($0.name ?? "") == normalizedTitle
        }), let id = exact.seriesID {
            return id
        }

        if let prefix = results.first(where: {
            normalized($0.name ?? "").hasPrefix(normalizedTitle)
        }), let id = prefix.seriesID {
            return id
        }

        return results.first?.seriesID
    }

    /// Fetches a series by id.
    public func series(id: Int) async throws -> TVDBSeries {
        let data = try await authorized(path: "series/\(id)")
        let envelope: TVDBEnvelope<TVDBSeries> = try decode(data)

        guard let series = envelope.data else {
            throw TVDBError.notFound("TVDB series \(id) was not found.")
        }
        return series
    }

    /// Fetches the flat episode list for a series.
    public func episodes(seriesID: Int) async throws -> [TVDBEpisode] {
        let data = try await authorized(
            path: "series/\(seriesID)/episodes/default"
        )
        let envelope: TVDBEnvelope<TVDBEpisodeCollection> = try decode(data)
        return envelope.data?.episodes ?? []
    }

    /// Fetches episodes and converts them into sorted season/episode mappings.
    public func episodeMappings(
        seriesID: Int
    ) async throws -> [TVDBEpisodeMapping] {
        let episodes = try await episodes(seriesID: seriesID)
        return Self.mappings(from: episodes)
    }

    /// Converts a flat TVDB episode list into sorted season/episode mappings.
    ///
    /// Episodes without both a season and an episode number cannot be placed
    /// in the catalog and are ignored.
    public nonisolated static func mappings(
        from episodes: [TVDBEpisode]
    ) -> [TVDBEpisodeMapping] {
        episodes
            .compactMap { episode -> TVDBEpisodeMapping? in
                guard let season = episode.seasonNumber,
                      let number = episode.number else {
                    return nil
                }
                return TVDBEpisodeMapping(
                    seasonNumber: season,
                    episodeNumber: number,
                    absoluteNumber: episode.absoluteNumber,
                    name: episode.name,
                    airDate: episode.aired
                )
            }
            .sorted { lhs, rhs in
                if lhs.seasonNumber != rhs.seasonNumber {
                    return lhs.seasonNumber < rhs.seasonNumber
                }
                if lhs.episodeNumber != rhs.episodeNumber {
                    return lhs.episodeNumber < rhs.episodeNumber
                }
                return (lhs.absoluteNumber ?? 0) < (rhs.absoluteNumber ?? 0)
            }
    }

    // MARK: HTTP

    private func authorized(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        var didRetry = false

        while true {
            let token = try await login()
            var request = try makeRequest(path: path, queryItems: queryItems)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            do {
                return try await send(request)
            } catch let error as TVDBError {
                guard case .httpStatus(let status, _) = error,
                      status == 401,
                      !didRetry else {
                    throw error
                }
                didRetry = true
                self.token = nil
                try await login(force: true)
            }
        }
    }

    private func makeRequest(
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        let url = configuration.baseURL.appendingPathComponent(path)
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw TVDBError.invalidURL(url.absoluteString)
        }

        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let finalURL = components.url else {
            throw TVDBError.invalidURL(url.absoluteString)
        }

        var request = URLRequest(
            url: finalURL,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TVDBError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TVDBError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            throw TVDBError.httpStatus(
                http.statusCode,
                message: Self.apiMessage(from: data)
            )
        }

        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            throw TVDBError.decoding(String(describing: error))
        }
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            var message: String?
        }

        return try? JSONDecoder()
            .decode(ErrorEnvelope.self, from: data)
            .message
    }
}
