import Foundation
import Testing
@testable import MetadataKit

// MARK: - Test doubles

private struct MockTransportError: Error, Sendable {
    let message: String
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) private static var storedHandler: Handler?
    private static let lock = NSLock()

    static func setHandler(_ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        storedHandler = handler
    }

    private static func handler() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return storedHandler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler() else {
            client?.urlProtocol(
                self,
                didFailWithError: MockTransportError(message: "No handler installed")
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(request)
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTime: TimeInterval = 0
    private var recordedSleeps: [TimeInterval] = []

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return currentTime
    }

    func sleep(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        recordedSleeps.append(seconds)
        currentTime += seconds
    }

    func sleeps() -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSleeps
    }
}

// MARK: - Helpers

private func respond(
    to request: URLRequest,
    status: Int = 200,
    headers: [String: String] = [:],
    body: String
) throws -> (HTTPURLResponse, Data) {
    guard let url = request.url,
          let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
          ) else {
        throw MockTransportError(message: "Could not build an HTTP response")
    }
    return (response, Data(body.utf8))
}

private func queryItems(in request: URLRequest) -> [String: String] {
    guard let url = request.url,
          let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
          ) else {
        return [:]
    }
    var result: [String: String] = [:]
    for item in components.queryItems ?? [] {
        result[item.name] = item.value ?? ""
    }
    return result
}

private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeClient(
    accessToken: String? = "test-read-token",
    apiKey: String? = nil,
    defaultLanguage: String = "en-US",
    maxRateLimitRetries: Int = 2,
    rateLimiter: TMDBRateLimiter = TMDBRateLimiter()
) -> TMDBClient {
    let configuration = TMDBConfiguration(
        accessToken: accessToken,
        apiKey: apiKey,
        defaultLanguage: defaultLanguage,
        maxRateLimitRetries: maxRateLimitRetries
    )
    return TMDBClient(
        configuration: configuration,
        session: makeSession(),
        rateLimiter: rateLimiter
    )
}

// MARK: - Fixtures

private let movieJSON = """
{
  "id": 27205,
  "imdb_id": "tt1375666",
  "title": "Inception",
  "original_title": "Inception",
  "original_language": "en",
  "overview": "A thief who steals corporate secrets through dream-sharing.",
  "tagline": "Your mind is the scene of the crime.",
  "status": "Released",
  "release_date": "2010-07-15",
  "runtime": 148,
  "budget": 160000000,
  "revenue": 836800000,
  "homepage": "https://www.warnerbros.com/movies/inception",
  "poster_path": "/poster.jpg",
  "backdrop_path": "/backdrop.jpg",
  "adult": false,
  "popularity": 90.5,
  "vote_average": 8.4,
  "vote_count": 35000,
  "genres": [{"id": 28, "name": "Action"}, {"id": 878, "name": "Science Fiction"}],
  "production_companies": [
    {"id": 923, "name": "Legendary Pictures", "logo_path": "/legendary.png", "origin_country": "US"}
  ],
  "production_countries": [
    {"iso_3166_1": "US", "name": "United States of America"}
  ],
  "spoken_languages": [
    {"iso_639_1": "en", "english_name": "English", "name": "English"}
  ],
  "belongs_to_collection": {
    "id": 1,
    "name": "Inception Collection",
    "poster_path": "/collection-poster.jpg",
    "backdrop_path": "/collection-backdrop.jpg"
  }
}
"""

private let emptyMovieJSON = """
{
  "id": 27205,
  "title": "",
  "overview": ""
}
"""

private let movieSearchJSON = """
{
  "page": 1,
  "results": [
    {
      "id": 27205,
      "title": "Inception",
      "original_title": "Inception",
      "original_language": "en",
      "overview": "A thief who steals corporate secrets through dream-sharing.",
      "release_date": "2010-07-15",
      "poster_path": "/poster.jpg",
      "backdrop_path": "/backdrop.jpg",
      "genre_ids": [28, 878],
      "popularity": 90.5,
      "vote_average": 8.4,
      "vote_count": 35000,
      "adult": false,
      "video": false
    }
  ],
  "total_pages": 1,
  "total_results": 1
}
"""

private let emptySearchJSON = """
{
  "page": 1,
  "results": [],
  "total_pages": 1,
  "total_results": 0
}
"""

private let tvSearchJSON = """
{
  "page": 1,
  "results": [
    {
      "id": 1396,
      "name": "Breaking Bad",
      "original_name": "Breaking Bad",
      "original_language": "en",
      "overview": "A chemistry teacher turns to manufacturing.",
      "first_air_date": "2008-01-20",
      "poster_path": "/bb-poster.jpg",
      "backdrop_path": "/bb-backdrop.jpg",
      "genre_ids": [18, 80],
      "popularity": 100.0,
      "vote_average": 8.9,
      "vote_count": 12000,
      "origin_country": ["US"],
      "adult": false
    }
  ],
  "total_pages": 1,
  "total_results": 1
}
"""

private let tvShowJSON = """
{
  "id": 1396,
  "name": "Breaking Bad",
  "original_name": "Breaking Bad",
  "original_language": "en",
  "overview": "A chemistry teacher turns to manufacturing.",
  "tagline": "All bad things must come to an end.",
  "status": "Ended",
  "type": "Scripted",
  "homepage": "https://www.amc.com/shows/breaking-bad",
  "first_air_date": "2008-01-20",
  "last_air_date": "2013-09-29",
  "in_production": false,
  "number_of_seasons": 5,
  "number_of_episodes": 62,
  "episode_run_time": [47],
  "popularity": 100.0,
  "poster_path": "/bb-poster.jpg",
  "backdrop_path": "/bb-backdrop.jpg",
  "vote_average": 8.9,
  "vote_count": 12000,
  "adult": false,
  "origin_country": ["US"],
  "languages": ["en"],
  "genres": [{"id": 18, "name": "Drama"}, {"id": 80, "name": "Crime"}],
  "networks": [
    {"id": 174, "name": "AMC", "logo_path": "/amc.png", "origin_country": "US"}
  ],
  "production_companies": [
    {"id": 2605, "name": "Sony Pictures Television", "logo_path": null, "origin_country": "US"}
  ],
  "production_countries": [
    {"iso_3166_1": "US", "name": "United States of America"}
  ],
  "spoken_languages": [
    {"iso_639_1": "en", "english_name": "English", "name": "English"}
  ],
  "created_by": [
    {"id": 66633, "name": "Vince Gilligan", "original_name": "Vince Gilligan", "profile_path": "/vg.jpg", "known_for_department": "Writing", "gender": 2, "popularity": 3.0, "adult": false}
  ],
  "seasons": [
    {"id": 3572, "name": "Season 1", "overview": "The first season.", "air_date": "2008-01-20", "episode_count": 7, "poster_path": "/s1.jpg", "season_number": 1}
  ]
}
"""

private let seasonJSON = """
{
  "id": 3572,
  "name": "Season 1",
  "overview": "The first season.",
  "air_date": "2008-01-20",
  "season_number": 1,
  "poster_path": "/s1.jpg",
  "episodes": [
    {
      "id": 62085,
      "name": "Pilot",
      "overview": "Walter White begins his descent.",
      "air_date": "2008-01-20",
      "episode_number": 1,
      "season_number": 1,
      "production_code": "101",
      "still_path": "/pilot.jpg",
      "runtime": 58,
      "vote_average": 8.2,
      "vote_count": 5000,
      "crew": [
        {"id": 66633, "name": "Vince Gilligan", "credit_id": "crew-1", "department": "Writing", "job": "Writer", "profile_path": null, "gender": 2, "popularity": 3.0, "adult": false}
      ],
      "guest_stars": []
    }
  ],
  "networks": [
    {"id": 174, "name": "AMC", "logo_path": null, "origin_country": "US"}
  ]
}
"""

private let creditsJSON = """
{
  "id": 27205,
  "cast": [
    {"id": 6193, "name": "Leonardo DiCaprio", "original_name": "Leonardo DiCaprio", "character": "Cobb", "credit_id": "cast-1", "order": 0, "profile_path": "/leo.jpg", "known_for_department": "Acting", "gender": 2, "popularity": 50.0, "adult": false}
  ],
  "crew": [
    {"id": 525, "name": "Christopher Nolan", "original_name": "Christopher Nolan", "credit_id": "crew-1", "department": "Directing", "job": "Director", "profile_path": null, "gender": 2, "popularity": 20.0, "adult": false}
  ]
}
"""

private let videosJSON = """
{
  "id": 27205,
  "results": [
    {"id": "5c9f8c0e0e0a265f5d000001", "iso_639_1": "en", "iso_3166_1": "US", "name": "Official Trailer", "key": "YoHD9XEInc0", "site": "YouTube", "size": 1080, "type": "Trailer", "official": true, "published_at": "2010-05-10T00:00:00.000Z"}
  ]
}
"""

// MARK: - Client tests

@Suite("TMDBClient Tests", .serialized)
struct TMDBClientTests {
    // MARK: Search

    @Test("Searches movies with bearer auth and decodes results")
    func searchesMovies() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.record(request)
            return try respond(to: request, body: movieSearchJSON)
        }

        let client = makeClient()
        let response = try await client.searchMovies(
            query: "Inception",
            year: 2010
        )

        #expect(response.page == 1)
        #expect(response.totalResults == 1)
        #expect(response.results.count == 1)

        let movie = try #require(response.results.first)
        #expect(movie.id == 27205)
        #expect(movie.title == "Inception")
        #expect(movie.releaseYear == 2010)
        #expect(movie.genreIds == [28, 878])
        #expect(movie.voteAverage == 8.4)

        let request = try #require(recorder.requests.first)
        #expect(request.url?.path == "/3/search/movie")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-read-token")

        let query = queryItems(in: request)
        #expect(query["query"] == "Inception")
        #expect(query["year"] == "2010")
        #expect(query["language"] == "en-US")
        #expect(query["api_key"] == nil)
    }

    @Test("Searches TV shows and decodes results")
    func searchesTV() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.record(request)
            return try respond(to: request, body: tvSearchJSON)
        }

        let client = makeClient()
        let response = try await client.searchTV(
            query: "Breaking Bad",
            firstAirDateYear: 2008
        )

        let show = try #require(response.results.first)
        #expect(show.id == 1396)
        #expect(show.name == "Breaking Bad")
        #expect(show.firstAirYear == 2008)
        #expect(show.originCountry == ["US"])

        let request = try #require(recorder.requests.first)
        #expect(request.url?.path == "/3/search/tv")
        #expect(queryItems(in: request)["first_air_date_year"] == "2008")
    }

    @Test("Search retries with a fallback language when results are empty")
    func searchLanguageFallback() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.record(request)
            let language = queryItems(in: request)["language"]
            return try respond(
                to: request,
                body: language == "fr-FR" ? emptySearchJSON : movieSearchJSON
            )
        }

        let client = makeClient(defaultLanguage: "en-US")
        let response = try await client.searchMovies(
            query: "Inception",
            language: "fr-FR"
        )

        #expect(response.results.first?.title == "Inception")
        let languages = recorder.requests.compactMap {
            queryItems(in: $0)["language"]
        }
        #expect(languages == ["fr-FR", "en-US"])
    }

    // MARK: Details

    @Test("Decodes the full movie detail DTO")
    func decodesMovieDetail() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.record(request)
            return try respond(to: request, body: movieJSON)
        }

        let client = makeClient()
        let movie = try await client.movie(id: 27205, language: "en-US")

        #expect(movie.id == 27205)
        #expect(movie.imdbId == "tt1375666")
        #expect(movie.title == "Inception")
        #expect(movie.releaseYear == 2010)
        #expect(movie.runtime == 148)
        #expect(movie.genres?.map(\.name) == ["Action", "Science Fiction"])
        #expect(movie.productionCompanies?.first?.name == "Legendary Pictures")
        #expect(movie.productionCountries?.first?.iso31661 == "US")
        #expect(movie.spokenLanguages?.first?.iso6391 == "en")
        #expect(movie.belongsToCollection?.name == "Inception Collection")

        let request = try #require(recorder.requests.first)
        #expect(request.url?.path == "/3/movie/27205")
        #expect(request.httpMethod == "GET")
    }

    @Test("Decodes a TV show with seasons and networks")
    func decodesTVShow() async throws {
        MockURLProtocol.setHandler { request in
            try respond(to: request, body: tvShowJSON)
        }

        let client = makeClient()
        let show = try await client.tvShow(id: 1396)

        #expect(show.name == "Breaking Bad")
        #expect(show.firstAirYear == 2008)
        #expect(show.numberOfSeasons == 5)
        #expect(show.episodeRunTime == [47])
        #expect(show.networks?.first?.name == "AMC")
        #expect(show.createdBy?.first?.name == "Vince Gilligan")
        #expect(show.seasons?.first?.episodeCount == 7)
    }

    @Test("Decodes a season and its episodes")
    func decodesSeason() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.record(request)
            return try respond(to: request, body: seasonJSON)
        }

        let client = makeClient()
        let season = try await client.season(tvID: 1396, seasonNumber: 1)

        #expect(season.name == "Season 1")
        #expect(season.seasonNumber == 1)
        #expect(season.episodes?.count == 1)

        let episode = try #require(season.episodes?.first)
        #expect(episode.name == "Pilot")
        #expect(episode.episodeNumber == 1)
        #expect(episode.runtime == 58)
        #expect(episode.crew?.first?.job == "Writer")

        let request = try #require(recorder.requests.first)
        #expect(request.url?.path == "/3/tv/1396/season/1")
    }

    @Test("Localized detail fetches fill empty fields from a fallback language")
    func localizedDetailFallback() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.record(request)
            let language = queryItems(in: request)["language"]
            return try respond(
                to: request,
                body: language == "fr-FR" ? emptyMovieJSON : movieJSON
            )
        }

        let client = makeClient(defaultLanguage: "en-US")
        let movie = try await client.movie(id: 27205, language: "fr-FR")

        #expect(movie.title == "Inception")
        #expect(movie.overview == "A thief who steals corporate secrets through dream-sharing.")
        #expect(movie.tagline == "Your mind is the scene of the crime.")
        #expect(movie.posterPath == "/poster.jpg")

        let languages = recorder.requests.compactMap {
            queryItems(in: $0)["language"]
        }
        #expect(languages == ["fr-FR", "en-US"])
    }

    @Test("Language chains de-duplicate and always end with en-US")
    func languageChain() {
        let client = makeClient(defaultLanguage: "en-US")

        #expect(client.languageChain(preferred: nil) == ["en-US"])
        #expect(client.languageChain(preferred: "en-US") == ["en-US"])
        #expect(
            client.languageChain(preferred: "fr-FR")
                == ["fr-FR", "en-US"]
        )

        let fallbackClient = makeClient(defaultLanguage: "de-DE")
        #expect(
            fallbackClient.languageChain(preferred: "de-de")
                == ["de-de", "en-US"]
        )
    }

    // MARK: Credits & videos

    @Test("Decodes movie credits and videos")
    func decodesCreditsAndVideos() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.record(request)
            if request.url?.path.hasSuffix("/credits") == true {
                return try respond(to: request, body: creditsJSON)
            }
            return try respond(to: request, body: videosJSON)
        }

        let client = makeClient()
        let credits = try await client.movieCredits(id: 27205)
        let videos = try await client.movieVideos(id: 27205)

        #expect(credits.cast.first?.name == "Leonardo DiCaprio")
        #expect(credits.cast.first?.character == "Cobb")
        #expect(credits.crew.first?.job == "Director")

        let trailer = try #require(videos.results.first)
        #expect(trailer.key == "YoHD9XEInc0")
        #expect(trailer.site == "YouTube")
        #expect(trailer.type == "Trailer")
        #expect(trailer.official == true)

        let paths = recorder.requests.compactMap(\.url?.path)
        #expect(paths == ["/3/movie/27205/credits", "/3/movie/27205/videos"])
    }

    // MARK: Authentication

    @Test("Uses api_key when no bearer token is configured")
    func apiKeyAuthentication() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.record(request)
            return try respond(to: request, body: movieSearchJSON)
        }

        let client = makeClient(accessToken: nil, apiKey: "legacy-key")
        _ = try await client.searchMovies(query: "Inception")

        let request = try #require(recorder.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(queryItems(in: request)["api_key"] == "legacy-key")
    }

    @Test("Throws when no credentials are configured")
    func missingCredentials() async {
        let client = makeClient(accessToken: nil, apiKey: nil)

        do {
            _ = try await client.movie(id: 1)
            Issue.record("Expected missingCredentials")
        } catch let error as TMDBError {
            #expect(error == .missingCredentials)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Builds absolute image URLs")
    func imageURLs() {
        let client = makeClient()

        #expect(
            client.imageURL(path: "/poster.jpg", size: "w780")?.absoluteString
                == "https://image.tmdb.org/t/p/w780/poster.jpg"
        )
        #expect(client.imageURL(path: nil, size: "w780") == nil)
        #expect(client.imageURL(path: "", size: "w780") == nil)
    }

    // MARK: Error handling

    @Test("Surfaces HTTP errors with the API message")
    func httpError() async {
        MockURLProtocol.setHandler { request in
            try respond(
                to: request,
                status: 401,
                body: #"{"status_code": 7, "status_message": "Invalid API key", "success": false}"#
            )
        }

        let client = makeClient()

        do {
            _ = try await client.movie(id: 1)
            Issue.record("Expected an HTTP error")
        } catch let error as TMDBError {
            #expect(error == .httpStatus(401, message: "Invalid API key"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Retries a 429 after Retry-After and then succeeds")
    func retriesAfter429() async throws {
        let recorder = RequestRecorder()
        let clock = TestClock()
        let limiter = TMDBRateLimiter(
            configuration: TMDBRateLimiter.Configuration(),
            now: { clock.now() },
            sleep: { clock.sleep($0) }
        )

        MockURLProtocol.setHandler { request in
            recorder.record(request)
            if recorder.count == 1 {
                return try respond(
                    to: request,
                    status: 429,
                    headers: ["Retry-After": "30"],
                    body: "{}"
                )
            }
            return try respond(to: request, body: movieJSON)
        }

        let client = makeClient(rateLimiter: limiter)
        let movie = try await client.movie(id: 27205)

        #expect(movie.title == "Inception")
        #expect(recorder.count == 2)
        let sleeps = clock.sleeps()
        #expect(sleeps.count == 1)
        #expect(abs((sleeps.first ?? 0) - 30) < 0.001)
    }

    @Test("Gives up after the configured number of 429 retries")
    func rateLimitRetriesExhausted() async {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.record(request)
            return try respond(
                to: request,
                status: 429,
                headers: ["Retry-After": "0"],
                body: "{}"
            )
        }

        let client = makeClient(maxRateLimitRetries: 1)

        do {
            _ = try await client.movie(id: 27205)
            Issue.record("Expected a rate-limit error")
        } catch let error as TMDBError {
            #expect(error == .rateLimited(retryAfter: 0))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(recorder.count == 2)
    }
}

// MARK: - Rate limiter tests

@Suite("TMDBRateLimiter Tests")
struct TMDBRateLimiterTests {
    @Test("Delays a request when the token bucket is exhausted")
    func delaysWhenExhausted() async throws {
        let clock = TestClock()
        let limiter = TMDBRateLimiter(
            configuration: TMDBRateLimiter.Configuration(
                capacity: 2,
                tokensPerWindow: 1,
                window: 1
            ),
            now: { clock.now() },
            sleep: { clock.sleep($0) }
        )

        try await limiter.acquire()
        try await limiter.acquire()

        var sleeps = clock.sleeps()
        #expect(sleeps.isEmpty)

        try await limiter.acquire()

        sleeps = clock.sleeps()
        #expect(sleeps.count == 1)
        let total = sleeps.reduce(0, +)
        #expect(abs(total - 1) < 0.001)
    }

    @Test("Refills tokens over time")
    func refillsTokens() async throws {
        let clock = TestClock()
        let limiter = TMDBRateLimiter(
            configuration: TMDBRateLimiter.Configuration(
                capacity: 2,
                tokensPerWindow: 2,
                window: 1
            ),
            now: { clock.now() },
            sleep: { clock.sleep($0) }
        )

        try await limiter.acquire()
        try await limiter.acquire()
        let empty = await limiter.availableTokens()
        #expect(empty == 0)

        clock.sleep(0.5)
        let halfRefilled = await limiter.availableTokens()
        #expect(halfRefilled == 1)

        clock.sleep(1)
        let fullyRefilled = await limiter.availableTokens()
        #expect(fullyRefilled == 2)
    }

    @Test("A 429 cooldown blocks even when tokens are available")
    func rateLimitCooldown() async throws {
        let clock = TestClock()
        let limiter = TMDBRateLimiter(
            configuration: TMDBRateLimiter.Configuration(),
            now: { clock.now() },
            sleep: { clock.sleep($0) }
        )

        await limiter.handleRateLimit(retryAfter: 30)
        let required = await limiter.requiredDelay()
        #expect(abs(required - 30) < 0.001)

        try await limiter.acquire()

        let sleeps = clock.sleeps()
        #expect(sleeps.count == 1)
        #expect(abs((sleeps.first ?? 0) - 30) < 0.001)

        let after = await limiter.requiredDelay()
        #expect(after == 0)
    }

    @Test("Concurrent acquisitions respect the bucket")
    func concurrentAcquisitions() async throws {
        let clock = TestClock()
        let limiter = TMDBRateLimiter(
            configuration: TMDBRateLimiter.Configuration(
                capacity: 5,
                tokensPerWindow: 1,
                window: 1
            ),
            now: { clock.now() },
            sleep: { clock.sleep($0) }
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try? await limiter.acquire()
                }
            }
        }

        let remaining = await limiter.availableTokens()
        #expect(remaining == 0)
    }
}
