import Foundation
import Testing
@testable import SourceAdapters

// MARK: - Test doubles

private struct PlexMockError: Error, Sendable {
    let message: String
}

private final class PlexMockURLProtocol: URLProtocol, @unchecked Sendable {
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
                didFailWithError: PlexMockError(message: "No handler installed")
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

private final class PlexAccountMockURLProtocol: URLProtocol,
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
                didFailWithError: PlexMockError(message: "No handler installed")
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

private final class PlexRecorder: @unchecked Sendable {
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

private final class PlexCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - Helpers

private func plexRespond(
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
        throw PlexMockError(message: "Could not build an HTTP response")
    }
    return (response, data)
}

private func makePlexSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PlexMockURLProtocol.self]
    return configuration
}

private func makePlexURLSession() -> URLSession {
    URLSession(configuration: makePlexSessionConfiguration())
}

private func makePlexAccountURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PlexAccountMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makePlexConfiguration(
    plexTVBaseURL: URL = URL(string: "https://plex.tv")!
) -> PlexConfiguration {
    PlexConfiguration(
        plexTVBaseURL: plexTVBaseURL,
        clientIdentifier: "test-client",
        pageSize: 200
    )
}

// MARK: - Fixtures

private let plexSectionsXML = """
<?xml version="1.0" encoding="UTF-8"?>
<MediaContainer size="3">
  <Directory key="1" type="movie" title="Movies" updatedAt="1700000000"/>
  <Directory key="2" type="show" title="TV Shows" updatedAt="1700000100"/>
  <Directory key="3" type="artist" title="Music"/>
</MediaContainer>
"""

private let plexMoviesXML = """
<?xml version="1.0" encoding="UTF-8"?>
<MediaContainer size="1">
  <Video ratingKey="42" key="/library/metadata/42" type="movie"
         title="Inception" year="2010" duration="8880000"
         updatedAt="1700000100">
    <Guid id="imdb://tt1375666"/>
    <Guid id="tmdb://27205"/>
    <Media videoResolution="4k" videoCodec="hevc" audioCodec="eac3"
           container="mkv">
      <Part key="/library/parts/100/file.mkv" size="123456"
            container="mkv"/>
    </Media>
  </Video>
</MediaContainer>
"""

private let plexShowsXML = """
<?xml version="1.0" encoding="UTF-8"?>
<MediaContainer size="1">
  <Directory ratingKey="7" key="/library/metadata/7" type="show"
             title="Andor" updatedAt="1700000200">
    <Guid id="tvdb://12345"/>
  </Directory>
</MediaContainer>
"""

// MARK: - PIN linking

@Suite("PlexAPI Tests", .serialized)
struct PlexAPITests {
    @Test("Requesting and verifying a PIN returns the auth token")
    func pinFlow() async throws {
        let recorder = PlexRecorder()
        PlexAccountMockURLProtocol.setHandler { request in
            recorder.record(request)
            let path = request.url?.path ?? ""

            if path == "/api/v2/pins" {
                #expect(request.httpMethod == "POST")
                #expect(
                    request.value(forHTTPHeaderField: "X-Plex-Client-Identifier")
                        == "test-client"
                )
                let body = """
                {"id":11,"code":"ABCD","authToken":null,
                 "expiresIn":300,"trusted":false}
                """
                return try plexRespond(
                    to: request,
                    data: Data(body.utf8)
                )
            }

            #expect(path == "/api/v2/pins/11")
            #expect(request.httpMethod == "GET")
            let body = """
            {"id":11,"code":"ABCD","authToken":"token-123",
             "expiresAt":1800000000,"trusted":true}
            """
            return try plexRespond(to: request, data: Data(body.utf8))
        }

        let api = PlexAPI(
            baseURL: URL(string: "https://plex.example.com:32400")!,
            token: nil,
            configuration: makePlexConfiguration(),
            session: makePlexAccountURLSession()
        )

        let pin = try await api.requestPin()
        #expect(pin.id == 11)
        #expect(pin.code == "ABCD")
        #expect(!pin.isLinked)
        #expect(pin.expiresIn == 300)

        let checked = try await api.checkPin(id: pin.id)
        #expect(checked.isLinked)
        #expect(checked.authToken == "token-123")
        #expect(
            checked.expiresAt
                == Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(recorder.count == 2)
    }

    @Test("A PIN expires when it is never approved")
    func pinExpiry() async throws {
        PlexAccountMockURLProtocol.setHandler { request in
            try plexRespond(
                to: request,
                data: Data(
                    #"{"id":12,"code":"WXYZ","authToken":null}"#.utf8
                )
            )
        }

        let api = PlexAPI(
            baseURL: URL(string: "https://plex.example.com:32400")!,
            token: nil,
            configuration: makePlexConfiguration(),
            session: makePlexAccountURLSession()
        )

        do {
            _ = try await api.waitForPin(
                id: 12,
                timeout: 0,
                pollInterval: 0
            )
            Issue.record("Expected pinExpired")
        } catch PlexError.pinExpired {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Section XML maps section types and timestamps")
    func parsesSections() throws {
        let sections = try PlexXMLParser().parseSections(
            data: Data(plexSectionsXML.utf8)
        )

        #expect(sections.count == 3)
        #expect(sections[0].key == "1")
        #expect(sections[0].type == .movie)
        #expect(sections[0].title == "Movies")
        #expect(sections[0].updatedAt != nil)
        #expect(sections[1].type == .show)
        #expect(!sections[2].type.isVideo)
    }

    @Test("Media XML maps parts, provider ids, and duration")
    func parsesMedia() throws {
        let items = try PlexXMLParser().parseMedia(
            data: Data(plexMoviesXML.utf8)
        )

        let item = try #require(items.first)
        #expect(item.ratingKey == "42")
        #expect(item.type == .movie)
        #expect(item.title == "Inception")
        #expect(item.year == 2010)
        #expect(item.durationSeconds == 8880)
        #expect(item.providerIDs["imdb"] == "tt1375666")
        #expect(item.providerIDs["tmdb"] == "27205")
        #expect(item.partKey == "/library/parts/100/file.mkv")
        #expect(item.partSize == 123456)
        #expect(item.container == "mkv")
        #expect(item.videoResolution == "4k")
        #expect(item.videoCodec == "hevc")
    }

    @Test("Direct stream URLs use the part key and optionally the token")
    func directStreamURL() throws {
        let item = try #require(
            PlexXMLParser().parseMedia(data: Data(plexMoviesXML.utf8)).first
        )
        let base = URL(string: "https://plex.example.com:32400")!

        let withoutToken = PlexAPI(
            baseURL: base,
            token: "secret-token",
            configuration: makePlexConfiguration(),
            session: makePlexAccountURLSession()
        )
        let plain = try #require(withoutToken.streamURL(for: item))
        #expect(
            plain.absoluteString
                == "https://plex.example.com:32400/library/parts/100/file.mkv"
        )
        #expect(plain.query == nil)

        let withToken = try #require(
            withoutToken.streamURL(for: item, includeToken: true)
        )
        #expect(withToken.query?.contains("X-Plex-Token=secret-token") == true)

        #expect(
            withoutToken.playbackPreference(for: item) == .directPlay
        )
    }
}

// MARK: - Adapter

@Suite("PlexSourceAdapter Tests", .serialized)
struct PlexSourceAdapterTests {
    @Test("Connect validates the token and enumerates section items")
    func connectAndEnumerate() async throws {
        let recorder = PlexRecorder()
        PlexMockURLProtocol.setHandler { request in
            recorder.record(request)
            #expect(
                request.value(forHTTPHeaderField: "X-Plex-Token")
                    == "token-abc"
            )

            switch request.url?.path {
            case "/library/sections":
                return try plexRespond(
                    to: request,
                    data: Data(plexSectionsXML.utf8)
                )
            case "/library/sections/1/all":
                return try plexRespond(
                    to: request,
                    data: Data(plexMoviesXML.utf8)
                )
            case "/library/sections/2/all":
                return try plexRespond(
                    to: request,
                    data: Data(plexShowsXML.utf8)
                )
            default:
                throw PlexMockError(
                    message: "Unexpected path \(request.url?.path ?? "")"
                )
            }
        }

        let adapter = PlexSourceAdapter(
            configuration: makePlexConfiguration(),
            sessionConfiguration: makePlexSessionConfiguration(),
            tokenProvider: { _ in "token-abc" }
        )

        let config = SourceConfig(
            kind: .plex,
            name: "Living Room Plex",
            endpoint: URL(string: "https://plex.example.com:32400")
        )
        let session = try await adapter.connect(config: config)

        #expect(session.accessToken == "token-abc")
        #expect(session.metadata["endpoint"] == "https://plex.example.com:32400")
        #expect(session.metadata["sectionKeys"] == "1,2")
        #expect(session.capabilities.contains(.rangeRequests))
        #expect(session.capabilities.contains(.watchStatePush))
        #expect(session.capabilities.contains(.directPlay))

        var items: [SourceItem] = []
        for try await item in try await adapter.enumerate(
            session: session,
            scope: LibraryScope(libraryID: "1", recursive: false)
        ) {
            items.append(item)
        }

        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.id == "42")
        #expect(item.kind == .movie)
        #expect(item.name == "Inception")
        #expect(item.sizeBytes == 123456)
        #expect(item.container == "mkv")
        #expect(item.durationSeconds == 8880)
        #expect(item.providerIDs["imdb"] == "tt1375666")
        #expect(
            item.location
                == "https://plex.example.com:32400/library/parts/100/file.mkv"
        )

        // The show section is enumerated with Directory elements.
        var shows: [SourceItem] = []
        for try await show in try await adapter.enumerate(
            session: session,
            scope: LibraryScope(libraryID: "2", recursive: false)
        ) {
            shows.append(show)
        }
        let show = try #require(shows.first)
        #expect(show.kind == .show)
        #expect(show.name == "Andor")
        #expect(show.providerIDs["tvdb"] == "12345")
    }

    @Test("Enumeration applies include and exclude globs")
    func globFiltering() async throws {
        PlexMockURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/library/sections":
                return try plexRespond(
                    to: request,
                    data: Data(plexSectionsXML.utf8)
                )
            case "/library/sections/1/all":
                return try plexRespond(
                    to: request,
                    data: Data(plexMoviesXML.utf8)
                )
            default:
                return try plexRespond(to: request, data: Data())
            }
        }

        let adapter = PlexSourceAdapter(
            configuration: makePlexConfiguration(),
            sessionConfiguration: makePlexSessionConfiguration(),
            tokenProvider: { _ in "token-abc" }
        )
        let config = SourceConfig(
            kind: .plex,
            name: "Plex",
            endpoint: URL(string: "https://plex.example.com:32400")
        )
        let session = try await adapter.connect(config: config)

        var items: [SourceItem] = []
        for try await item in try await adapter.enumerate(
            session: session,
            scope: LibraryScope(
                libraryID: "1",
                recursive: false,
                excludeGlobs: ["Inception*"]
            )
        ) {
            items.append(item)
        }

        #expect(items.isEmpty)
    }

    @Test("Reads send the Plex token header and honor ranges")
    func rangedRead() async throws {
        let payload = Data((0..<64).map { UInt8($0) })
        let recorder = PlexRecorder()

        PlexMockURLProtocol.setHandler { request in
            recorder.record(request)
            if request.url?.path == "/library/sections" {
                return try plexRespond(
                    to: request,
                    data: Data(plexSectionsXML.utf8)
                )
            }
            #expect(request.httpMethod == "GET")
            #expect(
                request.value(forHTTPHeaderField: "X-Plex-Token")
                    == "token-abc"
            )
            #expect(
                request.value(forHTTPHeaderField: "Range") == "bytes=8-15"
            )
            return try plexRespond(
                to: request,
                status: 206,
                headers: ["Content-Range": "bytes 8-15/64"],
                data: payload.subdata(in: 8..<16)
            )
        }

        let adapter = PlexSourceAdapter(
            configuration: makePlexConfiguration(),
            sessionConfiguration: makePlexSessionConfiguration(),
            tokenProvider: { _ in "token-abc" }
        )
        let config = SourceConfig(
            kind: .plex,
            name: "Plex",
            endpoint: URL(string: "https://plex.example.com:32400")
        )
        let session = try await adapter.connect(config: config)
        let item = SourceItem(
            id: "42",
            sourceID: session.sourceID,
            kind: .movie,
            name: "Inception",
            location: "https://plex.example.com:32400/library/parts/100/file.mkv",
            sizeBytes: 64
        )

        let range = try ByteRange(start: 8, end: 15)
        var data = Data()
        for try await chunk in adapter.read(
            session: session,
            item: item,
            range: range
        ) {
            data.append(chunk)
        }

        #expect(data == payload.subdata(in: 8..<16))
        #expect(recorder.count == 2)
    }

    @Test("Freshness reports the newest section update time")
    func freshness() async throws {
        PlexMockURLProtocol.setHandler { request in
            try plexRespond(
                to: request,
                data: Data(plexSectionsXML.utf8)
            )
        }

        let adapter = PlexSourceAdapter(
            configuration: makePlexConfiguration(),
            sessionConfiguration: makePlexSessionConfiguration(),
            tokenProvider: { _ in "token-abc" }
        )
        let config = SourceConfig(
            kind: .plex,
            name: "Plex",
            endpoint: URL(string: "https://plex.example.com:32400")
        )
        let session = try await adapter.connect(config: config)

        let freshness = try await adapter.freshness(session: session)
        #expect(freshness.strategy == .modificationTime)
        #expect(
            freshness.lastModified
                == Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    @Test("Connect without a token requires reauthentication")
    func missingToken() async throws {
        let adapter = PlexSourceAdapter(
            configuration: makePlexConfiguration(),
            sessionConfiguration: makePlexSessionConfiguration(),
            tokenProvider: { _ in nil }
        )
        let config = SourceConfig(
            kind: .plex,
            name: "Plex",
            endpoint: URL(string: "https://plex.example.com:32400")
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

    @Test("Watch-state writes retry after a server failure")
    func watchStateRetry() async throws {
        let attempts = PlexCounter()
        let recorder = PlexRecorder()

        PlexMockURLProtocol.setHandler { request in
            recorder.record(request)
            let attempt = attempts.increment()
            if attempt == 1 {
                return try plexRespond(
                    to: request,
                    status: 500,
                    data: Data("busy".utf8)
                )
            }
            #expect(request.url?.path == "/:/progress")
            return try plexRespond(
                to: request,
                status: 200,
                data: Data("<MediaContainer/>".utf8)
            )
        }

        let queue = PlexWatchStateQueue(
            configuration: makePlexConfiguration(),
            maxAttempts: 3,
            session: makePlexURLSession()
        )

        let pending = await queue.enqueue(
            serverURL: URL(string: "https://plex.example.com:32400")!,
            token: "token-abc",
            itemID: "42",
            state: SourceWatchState(position: 60, duration: 120)
        )
        #expect(pending == 1)

        let remaining = await queue.flush()
        #expect(remaining == 0)

        let requests = recorder.requests
        #expect(requests.count == 2)
        let query = requests.last?.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                .queryItems
        }
        #expect(query?.contains { $0.name == "key" && $0.value == "42" } == true)
        #expect(
            query?.contains {
                $0.name == "time" && $0.value == "60000"
            } == true
        )
    }

    @Test("Watch-state writes stop retrying after the attempt limit")
    func watchStateGivesUp() async throws {
        PlexMockURLProtocol.setHandler { request in
            try plexRespond(
                to: request,
                status: 503,
                data: Data()
            )
        }

        let queue = PlexWatchStateQueue(
            configuration: makePlexConfiguration(),
            maxAttempts: 2,
            session: makePlexURLSession()
        )

        _ = await queue.enqueue(
            serverURL: URL(string: "https://plex.example.com:32400")!,
            token: "token-abc",
            itemID: "42",
            state: SourceWatchState(position: 1, duration: 2)
        )
        let firstCount = await queue.pendingCount
        #expect(firstCount == 1)

        _ = await queue.flush()
        let finalCount = await queue.pendingCount
        #expect(finalCount == 0)
    }
}
