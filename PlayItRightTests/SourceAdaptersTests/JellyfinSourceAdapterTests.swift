import Foundation
import Testing
@testable import SourceAdapters

// MARK: - Test doubles

private struct JellyfinMockError: Error, Sendable {
    let message: String
}

private final class JellyfinMockURLProtocol: URLProtocol,
    @unchecked Sendable {
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
                didFailWithError: JellyfinMockError(
                    message: "No handler installed"
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
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class JellyfinRecorder: @unchecked Sendable {
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

// MARK: - Helpers

private func jellyfinRespond(
    to request: URLRequest,
    status: Int = 200,
    headers: [String: String] = [:],
    data: Data
) throws -> (HTTPURLResponse, Data) {
    guard let url = request.url,
          let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
          ) else {
        throw JellyfinMockError(message: "Could not build an HTTP response")
    }
    return (response, data)
}

private func makeJellyfinSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [JellyfinMockURLProtocol.self]
    return configuration
}

private func makeJellyfinAdapter(
    brand: MediaServerBrand = .jellyfin
) -> JellyfinSourceAdapter {
    switch brand {
    case .jellyfin:
        return JellyfinSourceAdapter(
            brand: .jellyfin,
            sessionConfiguration: makeJellyfinSessionConfiguration(),
            tokenProvider: { _ in "jellyfin-token" }
        )
    case .emby:
        return EmbySourceAdapter(
            sessionConfiguration: makeJellyfinSessionConfiguration(),
            tokenProvider: { _ in "emby-token" }
        )
    }
}

private func makeJellyfinSession(
    _ adapter: JellyfinSourceAdapter
) async throws -> SourceSession {
    let config = SourceConfig(
        kind: adapter.kind,
        name: "Media Server",
        endpoint: URL(string: "https://jellyfin.example.com")!
    )
    return try await adapter.connect(config: config)
}

private func collectJellyfinItems(
    _ stream: ItemStream
) async throws -> [SourceItem] {
    var items: [SourceItem] = []
    for try await item in stream {
        items.append(item)
    }
    return items
}

private func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: bufferSize)
        if read <= 0 {
            break
        }
        data.append(buffer, count: read)
    }
    return data
}

// MARK: - Fixtures

private let jellyfinSystemInfo = """
{"ServerName":"Living Room","Version":"10.9.0",
 "ProductName":"Jellyfin Server","Id":"server-1",
 "OperatingSystem":"Linux"}
"""

private let embySystemInfo = """
{"ServerName":"Living Room Emby","Version":"4.8.0",
 "ProductName":"Emby Server","Id":"server-2",
 "OperatingSystem":"Linux"}
"""

private let jellyfinItemsJSON = """
{
  "Items": [
    {
      "Id": "series1",
      "Name": "Andor",
      "Type": "Series",
      "Etag": "series-etag"
    },
    {
      "Id": "season1",
      "Name": "Season 1",
      "Type": "Season",
      "ParentId": "series1",
      "SeriesId": "series1",
      "IndexNumber": 1
    },
    {
      "Id": "ep1",
      "Name": "Episode One",
      "Type": "Episode",
      "ParentId": "season1",
      "SeriesId": "series1",
      "SeasonId": "season1",
      "IndexNumber": 1,
      "ParentIndexNumber": 1,
      "RunTimeTicks": 36000000000,
      "DateCreated": "2022-09-21T00:00:00.000Z",
      "ProviderIds": {"Tvdb": "12345"},
      "MediaSources": [
        {
          "Id": "ms1",
          "Path": "/media/shows/ep1.mkv",
          "Container": "mkv",
          "Size": 987654
        }
      ]
    },
    {
      "Id": "movie1",
      "Name": "Inception",
      "Type": "Movie",
      "RunTimeTicks": 88800000000,
      "ProviderIds": {"Tmdb": "27205", "Imdb": "tt1375666"},
      "MediaSources": [
        {
          "Id": "ms2",
          "Path": "/media/movies/inception.mkv",
          "Container": "mkv",
          "Size": 123456
        }
      ]
    }
  ],
  "TotalRecordCount": 4,
  "StartIndex": 0
}
"""

// MARK: - Tests

@Suite("JellyfinSourceAdapter Tests", .serialized)
struct JellyfinSourceAdapterTests {
    @Test("Connect detects Jellyfin and reports required capabilities")
    func connectDetectsJellyfin() async throws {
        let recorder = JellyfinRecorder()
        JellyfinMockURLProtocol.setHandler { request in
            recorder.record(request)
            #expect(request.url?.path == "/System/Info/Public")
            #expect(
                request.value(forHTTPHeaderField: "X-Emby-Token")
                    == "jellyfin-token"
            )
            return try jellyfinRespond(
                to: request,
                data: Data(jellyfinSystemInfo.utf8)
            )
        }

        let adapter = makeJellyfinAdapter()
        let session = try await makeJellyfinSession(adapter)

        #expect(adapter.kind == .jellyfin)
        #expect(session.accessToken == "jellyfin-token")
        #expect(session.metadata["detectedBrand"] == "jellyfin")
        #expect(session.metadata["serverName"] == "Living Room")
        #expect(session.metadata["serverVersion"] == "10.9.0")
        #expect(session.capabilities.contains(.rangeRequests))
        #expect(session.capabilities.contains(.watchStatePush))
        #expect(session.capabilities.contains(.etagFreshness))
        #expect(session.capabilities.contains(.directPlay))
        #expect(recorder.count == 1)
    }

    @Test("Emby is detected through /System/Info/Public")
    func connectDetectsEmby() async throws {
        JellyfinMockURLProtocol.setHandler { request in
            try jellyfinRespond(
                to: request,
                data: Data(embySystemInfo.utf8)
            )
        }

        let adapter = makeJellyfinAdapter(brand: .emby)
        let session = try await makeJellyfinSession(adapter)

        #expect(adapter.kind == .emby)
        #expect(session.metadata["detectedBrand"] == "emby")
        #expect(session.metadata["serverVersion"] == "4.8.0")
        #expect(session.accessToken == "emby-token")
    }

    @Test("Items map into shows, seasons, episodes, and movies")
    func itemTreeParsing() async throws {
        let recorder = JellyfinRecorder()
        JellyfinMockURLProtocol.setHandler { request in
            recorder.record(request)
            switch request.url?.path {
            case "/System/Info/Public":
                return try jellyfinRespond(
                    to: request,
                    data: Data(jellyfinSystemInfo.utf8)
                )
            case "/Items":
                let query = request.url.flatMap {
                    URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                        .queryItems
                } ?? []
                #expect(
                    query.contains {
                        $0.name == "Recursive" && $0.value == "true"
                    }
                )
                #expect(
                    query.contains {
                        $0.name == "IncludeItemTypes"
                            && $0.value == "Movie,Episode"
                    }
                )
                return try jellyfinRespond(
                    to: request,
                    data: Data(jellyfinItemsJSON.utf8)
                )
            default:
                throw JellyfinMockError(
                    message: "Unexpected path \(request.url?.path ?? "")"
                )
            }
        }

        let adapter = makeJellyfinAdapter()
        let session = try await makeJellyfinSession(adapter)

        let items = try await collectJellyfinItems(
            try await adapter.enumerate(
                session: session,
                scope: LibraryScope()
            )
        )

        #expect(items.count == 4)
        let byID = Dictionary(
            uniqueKeysWithValues: items.map { ($0.id, $0) }
        )

        let series = try #require(byID["series1"])
        #expect(series.kind == .show)
        #expect(series.name == "Andor")

        let season = try #require(byID["season1"])
        #expect(season.kind == .season)
        #expect(season.parentID == "series1")

        let episode = try #require(byID["ep1"])
        #expect(episode.kind == .episode)
        #expect(episode.parentID == "season1")
        #expect(episode.durationSeconds == 3600)
        #expect(episode.sizeBytes == 987654)
        #expect(episode.container == "mkv")
        #expect(episode.providerIDs["tvdb"] == "12345")
        #expect(episode.modifiedAt != nil)
        #expect(
            episode.location
                == "https://jellyfin.example.com/Videos/ep1/stream?static=true&MediaSourceId=ms1"
        )

        let movie = try #require(byID["movie1"])
        #expect(movie.kind == .movie)
        #expect(movie.providerIDs["tmdb"] == "27205")
        #expect(movie.providerIDs["imdb"] == "tt1375666")
        #expect(movie.durationSeconds == 8880)
        #expect(movie.sizeBytes == 123456)
        #expect(
            movie.location
                == "https://jellyfin.example.com/Videos/movie1/stream?static=true&MediaSourceId=ms2"
        )
    }

    @Test("ETag freshness returns not-modified for a 304 response")
    func etagFreshness() async throws {
        let recorder = JellyfinRecorder()
        JellyfinMockURLProtocol.setHandler { request in
            recorder.record(request)
            if request.url?.path == "/System/Info/Public" {
                return try jellyfinRespond(
                    to: request,
                    data: Data(jellyfinSystemInfo.utf8)
                )
            }

            #expect(
                request.value(forHTTPHeaderField: "If-None-Match")
                    == "\"etag-1\""
            )
            return try jellyfinRespond(
                to: request,
                status: 304,
                headers: ["ETag": "\"etag-1\""],
                data: Data()
            )
        }

        let adapter = makeJellyfinAdapter()
        var session = try await makeJellyfinSession(adapter)
        session.metadata["etag"] = "\"etag-1\""

        let freshness = try await adapter.freshness(session: session)
        #expect(freshness.strategy == .etag)
        #expect(freshness.token == "\"etag-1\"")
        #expect(freshness.hasChanges == false)
    }

    @Test("ETag freshness reports changes with a new token")
    func etagChanged() async throws {
        JellyfinMockURLProtocol.setHandler { request in
            if request.url?.path == "/System/Info/Public" {
                return try jellyfinRespond(
                    to: request,
                    data: Data(jellyfinSystemInfo.utf8)
                )
            }
            return try jellyfinRespond(
                to: request,
                headers: ["ETag": "\"etag-2\""],
                data: Data(jellyfinItemsJSON.utf8)
            )
        }

        let adapter = makeJellyfinAdapter()
        var session = try await makeJellyfinSession(adapter)
        session.metadata["etag"] = "\"etag-1\""

        let freshness = try await adapter.freshness(session: session)
        #expect(freshness.strategy == .etag)
        #expect(freshness.token == "\"etag-2\"")
        #expect(freshness.hasChanges == true)
    }

    @Test("Watch progress serializes Jellyfin ticks and play method")
    func watchProgressSerialization() async throws {
        let recorder = JellyfinRecorder()
        JellyfinMockURLProtocol.setHandler { request in
            recorder.record(request)
            if request.url?.path == "/System/Info/Public" {
                return try jellyfinRespond(
                    to: request,
                    data: Data(jellyfinSystemInfo.utf8)
                )
            }
            #expect(
                request.url?.path == "/Sessions/Playing/Progress"
            )
            #expect(request.httpMethod == "POST")
            #expect(
                request.value(forHTTPHeaderField: "Content-Type")
                    == "application/json"
            )
            return try jellyfinRespond(to: request, data: Data())
        }

        let adapter = makeJellyfinAdapter()
        let session = try await makeJellyfinSession(adapter)
        let item = SourceItem(
            id: "movie1",
            sourceID: session.sourceID,
            kind: .movie,
            name: "Inception",
            location: "https://jellyfin.example.com/Videos/movie1/stream"
        )

        try await adapter.pushWatchState(
            session: session,
            item: item,
            state: SourceWatchState(position: 12.5, duration: 120)
        )

        let request = try #require(recorder.requests.last)
        let body = try #require(bodyData(from: request))
        let report = try JSONDecoder().decode(
            JellyfinProgressReport.self,
            from: body
        )

        #expect(report.itemID == "movie1")
        #expect(report.positionTicks == 125_000_000)
        #expect(report.isPaused == false)
        #expect(report.canSeek == true)
        #expect(report.playMethod == "DirectStream")
    }

    @Test("Watched items are marked played")
    func watchedItemMarksPlayed() async throws {
        let recorder = JellyfinRecorder()
        JellyfinMockURLProtocol.setHandler { request in
            recorder.record(request)
            if request.url?.path == "/System/Info/Public" {
                return try jellyfinRespond(
                    to: request,
                    data: Data(jellyfinSystemInfo.utf8)
                )
            }
            #expect(request.url?.path == "/Items/movie1/Played")
            #expect(request.httpMethod == "POST")
            return try jellyfinRespond(to: request, data: Data())
        }

        let adapter = makeJellyfinAdapter()
        let session = try await makeJellyfinSession(adapter)
        let item = SourceItem(
            id: "movie1",
            sourceID: session.sourceID,
            kind: .movie,
            name: "Inception",
            location: "https://jellyfin.example.com/Videos/movie1/stream"
        )

        try await adapter.pushWatchState(
            session: session,
            item: item,
            state: SourceWatchState(position: 120, isWatched: true)
        )
    }

    @Test("Reads send X-Emby-Token and honor ranges")
    func rangedRead() async throws {
        let payload = Data((0..<64).map { UInt8($0) })
        let recorder = JellyfinRecorder()

        JellyfinMockURLProtocol.setHandler { request in
            recorder.record(request)
            if request.url?.path == "/System/Info/Public" {
                return try jellyfinRespond(
                    to: request,
                    data: Data(jellyfinSystemInfo.utf8)
                )
            }

            #expect(request.httpMethod == "GET")
            #expect(
                request.value(forHTTPHeaderField: "X-Emby-Token")
                    == "jellyfin-token"
            )
            #expect(
                request.value(forHTTPHeaderField: "Range") == "bytes=16-23"
            )
            return try jellyfinRespond(
                to: request,
                status: 206,
                headers: ["Content-Range": "bytes 16-23/64"],
                data: payload.subdata(in: 16..<24)
            )
        }

        let adapter = makeJellyfinAdapter()
        let session = try await makeJellyfinSession(adapter)
        let item = SourceItem(
            id: "movie1",
            sourceID: session.sourceID,
            kind: .movie,
            name: "Inception",
            location: "https://jellyfin.example.com/Videos/movie1/stream?static=true",
            sizeBytes: 64
        )

        let range = try ByteRange(start: 16, end: 23)
        var data = Data()
        for try await chunk in adapter.read(
            session: session,
            item: item,
            range: range
        ) {
            data.append(chunk)
        }

        #expect(data == payload.subdata(in: 16..<24))
    }

    @Test("A missing token requires reauthentication")
    func missingToken() async throws {
        let adapter = JellyfinSourceAdapter(
            brand: .jellyfin,
            sessionConfiguration: makeJellyfinSessionConfiguration(),
            tokenProvider: { _ in nil }
        )
        let config = SourceConfig(
            kind: .jellyfin,
            name: "Jellyfin",
            endpoint: URL(string: "https://jellyfin.example.com")!
        )

        do {
            _ = try await adapter.connect(config: config)
            Issue.record("Expected reauthenticationRequired")
        } catch let error as SourceAdapterError {
            #expect(error == .reauthenticationRequired)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
