import Foundation

/// Configuration for ``TMDBClient``.
public struct TMDBConfiguration: Sendable, Equatable {
    /// Default TMDB v3 API root.
    public static let defaultBaseURL = URL(string: "https://api.themoviedb.org/3")!

    /// Default TMDB image CDN root.
    public static let defaultImageBaseURL = URL(string: "https://image.tmdb.org/t/p")!

    /// API root, normally `https://api.themoviedb.org/3`.
    public var baseURL: URL

    /// v4 read access token sent as a bearer token.
    public var accessToken: String?

    /// Legacy v3 API key, used only when no access token is configured.
    public var apiKey: String?

    /// Language requested first for localized fields.
    public var defaultLanguage: String

    /// TMDB image CDN root used by ``TMDBClient/imageURL(path:size:)``.
    public var imageBaseURL: URL

    /// How many times a `429` response is retried before failing.
    public var maxRateLimitRetries: Int

    /// Fallback cooldown when a `429` response has no `Retry-After` header.
    public var defaultRetryAfter: TimeInterval

    /// Per-request URL session timeout.
    public var requestTimeout: TimeInterval

    public init(
        accessToken: String? = nil,
        apiKey: String? = nil,
        defaultLanguage: String = "en-US",
        baseURL: URL = TMDBConfiguration.defaultBaseURL,
        imageBaseURL: URL = TMDBConfiguration.defaultImageBaseURL,
        maxRateLimitRetries: Int = 2,
        defaultRetryAfter: TimeInterval = 5,
        requestTimeout: TimeInterval = 20
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.apiKey = apiKey
        self.defaultLanguage = defaultLanguage
        self.imageBaseURL = imageBaseURL
        self.maxRateLimitRetries = max(0, maxRateLimitRetries)
        self.defaultRetryAfter = max(0, defaultRetryAfter)
        self.requestTimeout = max(1, requestTimeout)
    }

    /// Reads credentials and the preferred language from environment
    /// variables.
    ///
    /// Supported keys are `TMDB_ACCESS_TOKEN`, `TMDB_API_KEY`, and
    /// `TMDB_LANGUAGE`.
    public static func fromEnvironment(
        _ variables: [String: String] = ProcessInfo.processInfo.environment,
        defaultLanguage: String? = nil
    ) -> TMDBConfiguration {
        let token = nonEmpty(variables["TMDB_ACCESS_TOKEN"])
            ?? nonEmpty(variables["TMDB_READ_ACCESS_TOKEN"])
        let key = nonEmpty(variables["TMDB_API_KEY"])
        let language = defaultLanguage
            ?? nonEmpty(variables["TMDB_LANGUAGE"])
            ?? currentLanguageTag()

        return TMDBConfiguration(
            accessToken: token,
            apiKey: key,
            defaultLanguage: language
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Converts the current locale into a TMDB language tag such as `fr-FR`.
    public static func currentLanguageTag(
        locale: Locale = .current
    ) -> String {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        return identifier.isEmpty ? "en-US" : identifier
    }
}

/// Errors raised by ``TMDBClient``.
public enum TMDBError: Error, Sendable, Equatable, LocalizedError {
    /// Neither a read access token nor an API key was configured.
    case missingCredentials

    /// The request URL could not be constructed.
    case invalidURL(String)

    /// The server returned a non-HTTP response.
    case invalidResponse

    /// The server returned a non-success status.
    case httpStatus(Int, message: String?)

    /// A `429` response persisted after every retry.
    case rateLimited(retryAfter: TimeInterval)

    /// The response body did not match the expected DTO.
    case decoding(String)

    /// The transport failed before a response was received.
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No TMDB access token or API key is configured."
        case .invalidURL(let value):
            return "Could not build a TMDB request URL for '\(value)'."
        case .invalidResponse:
            return "TMDB returned a response that was not HTTP."
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                return "TMDB returned HTTP \(status): \(message)"
            }
            return "TMDB returned HTTP \(status)."
        case .rateLimited(let retryAfter):
            return "TMDB rate limit exceeded; retry after \(retryAfter) seconds."
        case .decoding(let message):
            return "Could not decode the TMDB response: \(message)"
        case .transport(let message):
            return "TMDB request failed: \(message)"
        }
    }
}

/// Async client for the TMDB v3 API.
///
/// Every request is gated by a ``TMDBRateLimiter`` (40 requests per 10 seconds
/// by default). `429` responses are retried after the server's `Retry-After`
/// delay. Localized endpoints request the preferred language first, then
/// fall back through the configured default language and `en-US`, filling in
/// any text fields the primary response left empty.
public final class TMDBClient: Sendable {
    public let configuration: TMDBConfiguration
    public let rateLimiter: TMDBRateLimiter

    private let session: URLSession

    public init(
        configuration: TMDBConfiguration,
        session: URLSession = .shared,
        rateLimiter: TMDBRateLimiter = TMDBRateLimiter()
    ) {
        self.configuration = configuration
        self.session = session
        self.rateLimiter = rateLimiter
    }

    // MARK: - Search

    /// Searches TMDB for movies by title.
    ///
    /// When the preferred language returns no results, the search is retried
    /// with each fallback language in order.
    public func searchMovies(
        query: String,
        year: Int? = nil,
        page: Int = 1,
        language: String? = nil
    ) async throws -> TMDBMovieSearchResponse {
        var queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        if let year {
            queryItems.append(URLQueryItem(name: "year", value: String(year)))
        }

        var lastResponse: TMDBMovieSearchResponse?
        for language in languageChain(preferred: language) {
            let response: TMDBMovieSearchResponse = try await get(
                path: "search/movie",
                queryItems: queryItems,
                language: language
            )
            lastResponse = response
            if !response.results.isEmpty {
                return response
            }
        }

        guard let lastResponse else {
            throw TMDBError.invalidResponse
        }
        return lastResponse
    }

    /// Searches TMDB for TV shows by title.
    public func searchTV(
        query: String,
        firstAirDateYear: Int? = nil,
        page: Int = 1,
        language: String? = nil
    ) async throws -> TMDBTVSearchResponse {
        var queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        if let firstAirDateYear {
            queryItems.append(
                URLQueryItem(
                    name: "first_air_date_year",
                    value: String(firstAirDateYear)
                )
            )
        }

        var lastResponse: TMDBTVSearchResponse?
        for language in languageChain(preferred: language) {
            let response: TMDBTVSearchResponse = try await get(
                path: "search/tv",
                queryItems: queryItems,
                language: language
            )
            lastResponse = response
            if !response.results.isEmpty {
                return response
            }
        }

        guard let lastResponse else {
            throw TMDBError.invalidResponse
        }
        return lastResponse
    }

    // MARK: - Details

    /// Fetches a movie with localized text fallbacks.
    public func movie(
        id: Int,
        language: String? = nil
    ) async throws -> TMDBMovie {
        try await fetchLocalized(
            path: "movie/\(id)",
            language: language,
            isComplete: { movie in
                !movie.title.isEmpty && !(movie.overview ?? "").isEmpty
            },
            merge: Self.merging
        )
    }

    /// Fetches a TV show with localized text fallbacks.
    public func tvShow(
        id: Int,
        language: String? = nil
    ) async throws -> TMDBTVShow {
        try await fetchLocalized(
            path: "tv/\(id)",
            language: language,
            isComplete: { show in
                !show.name.isEmpty && !(show.overview ?? "").isEmpty
            },
            merge: Self.merging
        )
    }

    /// Fetches a season and its episodes with localized text fallbacks.
    public func season(
        tvID: Int,
        seasonNumber: Int,
        language: String? = nil
    ) async throws -> TMDBSeasonDetail {
        try await fetchLocalized(
            path: "tv/\(tvID)/season/\(seasonNumber)",
            language: language,
            isComplete: { season in
                !season.name.isEmpty
                    && !(season.overview ?? "").isEmpty
                    && (season.episodes?.isEmpty == false)
            },
            merge: Self.merging
        )
    }

    // MARK: - Credits & videos

    /// Fetches cast and crew for a movie.
    public func movieCredits(
        id: Int,
        language: String? = nil
    ) async throws -> TMDBCredits {
        try await get(path: "movie/\(id)/credits", language: language)
    }

    /// Fetches cast and crew for a TV show.
    public func tvCredits(
        id: Int,
        language: String? = nil
    ) async throws -> TMDBCredits {
        try await get(path: "tv/\(id)/credits", language: language)
    }

    /// Fetches trailers, teasers, and featurettes for a movie.
    public func movieVideos(
        id: Int,
        language: String? = nil
    ) async throws -> TMDBVideosResponse {
        try await get(path: "movie/\(id)/videos", language: language)
    }

    /// Fetches trailers, teasers, and featurettes for a TV show.
    public func tvVideos(
        id: Int,
        language: String? = nil
    ) async throws -> TMDBVideosResponse {
        try await get(path: "tv/\(id)/videos", language: language)
    }

    // MARK: - Images

    /// Builds an absolute TMDB image URL for a size such as `w780` or
    /// `original`.
    public func imageURL(path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else {
            return nil
        }
        let relativePath = path.hasPrefix("/")
            ? String(path.dropFirst())
            : path
        return configuration.imageBaseURL
            .appendingPathComponent(size)
            .appendingPathComponent(relativePath)
    }

    // MARK: - Localized fetch

    private func fetchLocalized<T: Decodable & Sendable>(
        path: String,
        language: String?,
        isComplete: (T) -> Bool,
        merge: (T, T) -> T
    ) async throws -> T {
        var result: T?

        for language in languageChain(preferred: language) {
            let response: T = try await get(path: path, language: language)

            if let current = result {
                result = isComplete(current) ? current : merge(current, response)
            } else {
                result = response
            }

            if let result, isComplete(result) {
                return result
            }
        }

        guard let result else {
            throw TMDBError.invalidResponse
        }
        return result
    }

    /// Returns the preferred language followed by configured fallbacks,
    /// without duplicates.
    public func languageChain(preferred: String?) -> [String] {
        var languages: [String] = []

        func append(_ value: String?) {
            guard let value else {
                return
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return
            }
            guard !languages.contains(where: {
                $0.caseInsensitiveCompare(trimmed) == .orderedSame
            }) else {
                return
            }
            languages.append(trimmed)
        }

        append(preferred)
        append(configuration.defaultLanguage)
        append("en-US")
        return languages
    }

    private static func merging(
        _ movie: TMDBMovie,
        with fallback: TMDBMovie
    ) -> TMDBMovie {
        var merged = movie
        if merged.title.isEmpty {
            merged.title = fallback.title
        }
        if merged.overview?.isEmpty != false {
            merged.overview = fallback.overview
        }
        if merged.tagline?.isEmpty != false {
            merged.tagline = fallback.tagline
        }
        if merged.homepage?.isEmpty != false {
            merged.homepage = fallback.homepage
        }
        if merged.posterPath == nil {
            merged.posterPath = fallback.posterPath
        }
        if merged.backdropPath == nil {
            merged.backdropPath = fallback.backdropPath
        }
        return merged
    }

    private static func merging(
        _ show: TMDBTVShow,
        with fallback: TMDBTVShow
    ) -> TMDBTVShow {
        var merged = show
        if merged.name.isEmpty {
            merged.name = fallback.name
        }
        if merged.overview?.isEmpty != false {
            merged.overview = fallback.overview
        }
        if merged.tagline?.isEmpty != false {
            merged.tagline = fallback.tagline
        }
        if merged.homepage?.isEmpty != false {
            merged.homepage = fallback.homepage
        }
        if merged.posterPath == nil {
            merged.posterPath = fallback.posterPath
        }
        if merged.backdropPath == nil {
            merged.backdropPath = fallback.backdropPath
        }
        return merged
    }

    private static func merging(
        _ season: TMDBSeasonDetail,
        with fallback: TMDBSeasonDetail
    ) -> TMDBSeasonDetail {
        var merged = season
        if merged.name.isEmpty {
            merged.name = fallback.name
        }
        if merged.overview?.isEmpty != false {
            merged.overview = fallback.overview
        }
        if merged.posterPath == nil {
            merged.posterPath = fallback.posterPath
        }

        guard let fallbackEpisodes = fallback.episodes else {
            return merged
        }
        guard var episodes = merged.episodes, !episodes.isEmpty else {
            merged.episodes = fallbackEpisodes
            return merged
        }

        for index in episodes.indices {
            guard let fallbackEpisode = fallbackEpisodes.first(where: {
                $0.episodeNumber == episodes[index].episodeNumber
            }) else {
                continue
            }
            if episodes[index].name.isEmpty {
                episodes[index].name = fallbackEpisode.name
            }
            if episodes[index].overview?.isEmpty != false {
                episodes[index].overview = fallbackEpisode.overview
            }
            if episodes[index].stillPath == nil {
                episodes[index].stillPath = fallbackEpisode.stillPath
            }
        }
        merged.episodes = episodes
        return merged
    }

    // MARK: - HTTP

    private func get<T: Decodable & Sendable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        language: String? = nil
    ) async throws -> T {
        var items = queryItems
        if let language, !language.isEmpty {
            items.append(URLQueryItem(name: "language", value: language))
        }

        let request = try makeRequest(path: path, queryItems: items)
        let data = try await perform(request)
        return try decode(data)
    }

    private func makeRequest(
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URLRequest {
        let url = configuration.baseURL.appendingPathComponent(path)
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw TMDBError.invalidURL(url.absoluteString)
        }

        var items = queryItems
        var headers = [
            "Accept": "application/json"
        ]

        if let token = Self.nonEmpty(configuration.accessToken) {
            headers["Authorization"] = "Bearer \(token)"
        } else if let key = Self.nonEmpty(configuration.apiKey) {
            items.append(URLQueryItem(name: "api_key", value: key))
        } else {
            throw TMDBError.missingCredentials
        }

        components.queryItems = items.isEmpty ? nil : items
        guard let finalURL = components.url else {
            throw TMDBError.invalidURL(url.absoluteString)
        }

        var request = URLRequest(
            url: finalURL,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        var rateLimitRetries = 0

        while true {
            try await rateLimiter.acquire()

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw TMDBError.transport(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw TMDBError.invalidResponse
            }

            if http.statusCode == 429 {
                let retryAfter = Self.retryAfter(from: http)
                    ?? configuration.defaultRetryAfter
                await rateLimiter.handleRateLimit(retryAfter: retryAfter)

                if rateLimitRetries < configuration.maxRateLimitRetries {
                    rateLimitRetries += 1
                    continue
                }
                throw TMDBError.rateLimited(retryAfter: retryAfter)
            }

            guard (200..<300).contains(http.statusCode) else {
                throw TMDBError.httpStatus(
                    http.statusCode,
                    message: Self.apiMessage(from: data)
                )
            }

            return data
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            throw TMDBError.decoding(String(describing: error))
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func retryAfter(
        from response: HTTPURLResponse
    ) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return max(0, date.timeIntervalSinceNow)
        }

        return nil
    }

    private static func apiMessage(from data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            var statusMessage: String?
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(ErrorEnvelope.self, from: data).statusMessage
    }
}
