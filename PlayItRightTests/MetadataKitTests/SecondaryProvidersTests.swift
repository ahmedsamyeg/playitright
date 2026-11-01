import Foundation
import Testing
@testable import MetadataKit

// MARK: - Test doubles

private struct SecondaryMockError: Error, Sendable {
    let message: String
}

private final class SecondaryMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) private static var storedHandlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func setHandler(for host: String, _ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        storedHandlers[host] = handler
    }

    private static func handler(for host: String?) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        guard let host else {
            return nil
        }
        return storedHandlers[host]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler(for: request.url?.host) else {
            client?.urlProtocol(
                self,
                didFailWithError: SecondaryMockError(
                    message: "No handler installed for \(request.url?.host ?? "unknown")"
                )
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

private final class SecondaryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    private var loginCount = 0

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(request)
        if request.url?.path.hasSuffix("/login") == true {
            loginCount += 1
        }
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var logins: Int {
        lock.lock()
        defer { lock.unlock() }
        return loginCount
    }
}

private func secondaryRespond(
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
        throw SecondaryMockError(message: "Could not build an HTTP response")
    }
    return (response, Data(body.utf8))
}

private func secondaryQueryItems(in request: URLRequest) -> [String: String] {
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

private func makeSecondarySession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SecondaryMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

// MARK: - OMDb fixtures

private let omdbMovieJSON = """
{
  "Title": "Inception",
  "Year": "2010",
  "Rated": "PG-13",
  "Released": "16 Jul 2010",
  "Runtime": "148 min",
  "Genre": "Action, Adventure, Sci-Fi",
  "Director": "Christopher Nolan",
  "Writer": "Christopher Nolan",
  "Actors": "Leonardo DiCaprio, Joseph Gordon-Levitt, Elliot Page",
  "Plot": "A thief who steals corporate secrets through dream-sharing.",
  "Language": "English, Japanese, French",
  "Country": "United States, United Kingdom",
  "Awards": "Won 4 Oscars.",
  "Poster": "https://m.media-amazon.com/images/inception.jpg",
  "Ratings": [
    {"Source": "Internet Movie Database", "Value": "8.8/10"},
    {"Source": "Rotten Tomatoes", "Value": "87%"}
  ],
  "Metascore": "74",
  "imdbRating": "8.8",
  "imdbVotes": "2,400,000",
  "imdbID": "tt1375666",
  "Type": "movie",
  "DVD": "07 Dec 2010",
  "BoxOffice": "$292,587,330",
  "Production": "N/A",
  "Website": "N/A",
  "Response": "True"
}
"""

private let omdbSearchJSON = """
{
  "Search": [
    {"Title": "Inception", "Year": "2010", "imdbID": "tt1375666", "Type": "movie", "Poster": "https://m.media-amazon.com/images/inception.jpg"},
    {"Title": "Inception: The Cobol Job", "Year": "2010", "imdbID": "tt1890603", "Type": "movie", "Poster": "N/A"}
  ],
  "totalResults": "2",
  "Response": "True"
}
"""

// MARK: - TVDB fixtures

private let tvdbLoginJSON = """
{"status": "success", "data": {"token": "tvdb-token-1"}}
"""

private let tvdbSearchJSON = """
{
  "status": "success",
  "data": [
    {"tvdb_id": "999", "name": "Breaking Bad: Original Minisodes", "primary_type": "series", "first_air_time": "2009-02-17", "country": "usa"},
    {"tvdb_id": "81189", "name": "Breaking Bad", "primary_type": "series", "first_air_time": "2008-01-20", "overview": "A chemistry teacher turns to manufacturing.", "image_url": "https://artworks.thetvdb.com/banners/posters/81189-1.jpg", "country": "usa"}
  ]
}
"""

private let tvdbSeriesJSON = """
{
  "status": "success",
  "data": {
    "id": 81189,
    "name": "Breaking Bad",
    "slug": "breaking-bad",
    "image": "https://artworks.thetvdb.com/banners/posters/81189-1.jpg",
    "firstAired": "2008-01-20",
    "lastAired": "2013-09-29",
    "overview": "A chemistry teacher turns to manufacturing.",
    "status": {"id": 1, "name": "Ended"},
    "averageRuntime": 47,
    "year": "2008"
  }
}
"""

private let tvdbEpisodesJSON = """
{
  "status": "success",
  "data": {
    "series": {"id": 81189, "name": "Breaking Bad"},
    "episodes": [
      {"id": 3, "seriesId": 81189, "name": "Seven Thirty-Seven", "aired": "2009-03-08", "runtime": 47, "number": 1, "seasonNumber": 2, "absoluteNumber": 8, "overview": "Second season opener."},
      {"id": 1, "seriesId": 81189, "name": "Pilot", "aired": "2008-01-20", "runtime": 58, "number": 1, "seasonNumber": 1, "absoluteNumber": 1, "overview": "Walter White begins his descent."},
      {"id": 2, "seriesId": 81189, "name": "Cat's in the Bag...", "aired": "2008-01-27", "runtime": 48, "number": 2, "seasonNumber": 1, "absoluteNumber": 2},
      {"id": 4, "seriesId": 81189, "name": "Special", "aired": "2008-01-01"}
    ]
  }
}
"""

// MARK: - OMDb tests

@Suite("OMDbClient Tests", .serialized)
struct OMDbClientTests {
    private func makeClient(
        apiKey: String? = "test-omdb-key"
    ) -> OMDbClient {
        OMDbClient(
            configuration: OMDbConfiguration(apiKey: apiKey),
            session: makeSecondarySession()
        )
    }

    @Test("Looks up a title by IMDb id and decodes enrichment fields")
    func lookupByIMDbID() async throws {
        let recorder = SecondaryRequestRecorder()
        SecondaryMockURLProtocol.setHandler(for: "www.omdbapi.com") { request in
            recorder.record(request)
            return try secondaryRespond(to: request, body: omdbMovieJSON)
        }

        let client = makeClient()
        let media = try await client.lookup(imdbID: "tt1375666")

        #expect(media.title == "Inception")
        #expect(media.yearStart == 2010)
        #expect(media.runtimeMinutes == 148)
        #expect(media.genreNames == ["Action", "Adventure", "Sci-Fi"])
        #expect(media.directorNames == ["Christopher Nolan"])
        #expect(media.actorNames.count == 3)
        #expect(media.imdbID == "tt1375666")
        #expect(media.imdbRatingValue == 8.8)
        #expect(media.imdbVoteCount == 2_400_000)
        #expect(media.ratingsBySource["Rotten Tomatoes"] == "87%")
        #expect(media.isSuccess)

        let request = try #require(recorder.requests.first)
        let query = secondaryQueryItems(in: request)
        #expect(query["i"] == "tt1375666")
        #expect(query["plot"] == "full")
        #expect(query["apikey"] == "test-omdb-key")
    }

    @Test("Falls back to a title/year lookup when no IMDb id is available")
    func lookupTitleFallback() async throws {
        let recorder = SecondaryRequestRecorder()
        SecondaryMockURLProtocol.setHandler(for: "www.omdbapi.com") { request in
            recorder.record(request)
            return try secondaryRespond(to: request, body: omdbMovieJSON)
        }

        let client = makeClient()
        let media = try await client.lookup(
            title: "Inception",
            year: 2010,
            type: .movie
        )

        #expect(media.title == "Inception")
        #expect(media.yearStart == 2010)

        let request = try #require(recorder.requests.first)
        let query = secondaryQueryItems(in: request)
        #expect(query["t"] == "Inception")
        #expect(query["y"] == "2010")
        #expect(query["type"] == "movie")
    }

    @Test("Decodes search results")
    func searchesTitles() async throws {
        let recorder = SecondaryRequestRecorder()
        SecondaryMockURLProtocol.setHandler(for: "www.omdbapi.com") { request in
            recorder.record(request)
            return try secondaryRespond(to: request, body: omdbSearchJSON)
        }

        let client = makeClient()
        let response = try await client.search(
            title: "Inception",
            year: 2010
        )

        #expect(response.totalResultCount == 2)
        #expect(response.search?.first?.imdbID == "tt1375666")
        #expect(response.search?.first?.yearStart == 2010)
        #expect(response.search?.last?.poster == "N/A")

        let request = try #require(recorder.requests.first)
        #expect(secondaryQueryItems(in: request)["s"] == "Inception")
    }

    @Test("Throws notFound for an OMDb Response=False envelope")
    func titleNotFound() async {
        SecondaryMockURLProtocol.setHandler(for: "www.omdbapi.com") { request in
            try secondaryRespond(
                to: request,
                body: #"{"Response": "False", "Error": "Movie not found!"}"#
            )
        }

        let client = makeClient()

        do {
            _ = try await client.lookup(title: "Not A Real Movie")
            Issue.record("Expected notFound")
        } catch let error as OMDbError {
            #expect(error == .notFound("Movie not found!"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Throws missingAPIKey before making a request")
    func missingAPIKey() async {
        let client = makeClient(apiKey: nil)

        do {
            _ = try await client.lookup(title: "Inception")
            Issue.record("Expected missingAPIKey")
        } catch let error as OMDbError {
            #expect(error == .missingAPIKey)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

// MARK: - TVDB tests

@Suite("TVDBClient Tests", .serialized)
struct TVDBClientTests {
    private func makeClient(
        apiKey: String? = "test-tvdb-key"
    ) -> TVDBClient {
        TVDBClient(
            configuration: TVDBConfiguration(apiKey: apiKey),
            session: makeSecondarySession()
        )
    }

    @Test("Resolves an exact series title and caches the login token")
    func resolvesSeriesIDAndCachesToken() async throws {
        let recorder = SecondaryRequestRecorder()
        SecondaryMockURLProtocol.setHandler(for: "api4.thetvdb.com") { request in
            recorder.record(request)
            let path = request.url?.path ?? ""

            if path.hasSuffix("/login") {
                return try secondaryRespond(to: request, body: tvdbLoginJSON)
            }
            if path.hasSuffix("/search") {
                return try secondaryRespond(to: request, body: tvdbSearchJSON)
            }
            if path.hasSuffix("/series/81189") {
                return try secondaryRespond(to: request, body: tvdbSeriesJSON)
            }
            throw SecondaryMockError(message: "Unexpected path \(path)")
        }

        let client = makeClient()
        let seriesID = try await client.seriesID(forTitle: "Breaking Bad")
        #expect(seriesID == 81189)

        let series = try await client.series(id: 81189)
        #expect(series.name == "Breaking Bad")
        #expect(series.firstAiredYear == 2008)
        #expect(series.status?.name == "Ended")

        #expect(recorder.logins == 1)

        let searchRequest = try #require(
            recorder.requests.first { $0.url?.path.hasSuffix("/search") == true }
        )
        let query = secondaryQueryItems(in: searchRequest)
        #expect(query["query"] == "Breaking Bad")
        #expect(query["type"] == "series")
        #expect(
            searchRequest.value(forHTTPHeaderField: "Authorization")
                == "Bearer tvdb-token-1"
        )
    }

    @Test("Generates sorted season and episode mappings")
    func generatesEpisodeMappings() async throws {
        SecondaryMockURLProtocol.setHandler(for: "api4.thetvdb.com") { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/login") {
                return try secondaryRespond(to: request, body: tvdbLoginJSON)
            }
            if path.hasSuffix("/series/81189/episodes/default") {
                return try secondaryRespond(to: request, body: tvdbEpisodesJSON)
            }
            throw SecondaryMockError(message: "Unexpected path \(path)")
        }

        let client = makeClient()
        let episodes = try await client.episodes(seriesID: 81189)
        #expect(episodes.count == 4)

        let mappings = try await client.episodeMappings(seriesID: 81189)
        #expect(mappings.count == 3)
        #expect(mappings.map(\.seasonNumber) == [1, 1, 2])
        #expect(mappings.map(\.episodeNumber) == [1, 2, 1])
        #expect(mappings.map(\.absoluteNumber) == [1, 2, 8])
        #expect(mappings.first?.name == "Pilot")
    }

    @Test("Re-authenticates once after a 401 and retries the request")
    func reauthenticatesAfter401() async throws {
        let recorder = SecondaryRequestRecorder()
        SecondaryMockURLProtocol.setHandler(for: "api4.thetvdb.com") { request in
            recorder.record(request)
            let path = request.url?.path ?? ""

            if path.hasSuffix("/login") {
                let token = recorder.logins == 1 ? "old-token" : "new-token"
                return try secondaryRespond(
                    to: request,
                    body: #"{"status": "success", "data": {"token": "\#(token)"}}"#
                )
            }

            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token" {
                return try secondaryRespond(
                    to: request,
                    status: 401,
                    body: #"{"message": "Unauthorized"}"#
                )
            }

            return try secondaryRespond(to: request, body: tvdbSeriesJSON)
        }

        let client = makeClient()
        let series = try await client.series(id: 81189)

        #expect(series.id == 81189)
        #expect(recorder.logins == 2)

        let seriesRequests = recorder.requests.filter {
            $0.url?.path.hasSuffix("/series/81189") == true
        }
        #expect(seriesRequests.count == 2)
        #expect(
            seriesRequests.last?.value(forHTTPHeaderField: "Authorization")
                == "Bearer new-token"
        )
    }

    @Test("Throws missingAPIKey before logging in")
    func missingAPIKey() async {
        let client = makeClient(apiKey: nil)

        do {
            _ = try await client.login()
            Issue.record("Expected missingAPIKey")
        } catch let error as TVDBError {
            #expect(error == .missingAPIKey)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
