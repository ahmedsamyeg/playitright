import Foundation
import Testing
@testable import SourceAdapters

// MARK: - Test doubles

private struct WebDAVMockError: Error, Sendable {
    let message: String
}

private final class WebDAVMockURLProtocol: URLProtocol, @unchecked Sendable {
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
                didFailWithError: WebDAVMockError(
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

private final class WebDAVRecorder: @unchecked Sendable {
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

private func webDAVRespond(
    to request: URLRequest,
    status: Int = 207,
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
        throw WebDAVMockError(message: "Could not build an HTTP response")
    }
    return (response, data)
}

private func makeWebDAVAdapter(
    configuration: WebDAVConfiguration = WebDAVConfiguration(
        reconnectBaseDelay: 0
    ),
    credentials: WebDAVCredentials? = WebDAVCredentials(
        username: "samy",
        password: "secret"
    )
) -> WebDAVSourceAdapter {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [WebDAVMockURLProtocol.self]
    return WebDAVSourceAdapter(
        configuration: configuration,
        sessionConfiguration: sessionConfiguration,
        credentialProvider: { _ in credentials }
    )
}

private func makeWebDAVSession(
    _ adapter: WebDAVSourceAdapter,
    endpoint: String = "https://dav.example.com/dav/"
) async throws -> SourceSession {
    let config = SourceConfig(
        kind: .webdav,
        name: "WebDAV",
        endpoint: URL(string: endpoint)
    )
    return try await adapter.connect(config: config)
}

private func collectWebDAVItems(
    _ stream: ItemStream
) async throws -> [SourceItem] {
    var items: [SourceItem] = []
    for try await item in stream {
        items.append(item)
    }
    return items
}

private func collectWebDAVData(
    _ stream: AsyncThrowingStream<Data, Error>
) async throws -> Data {
    var data = Data()
    for try await chunk in stream {
        data.append(chunk)
    }
    return data
}

// MARK: - Fixtures

private let moviesMultistatus = """
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/Movies/</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>Movies</D:displayname>
        <D:resourcetype><D:collection/></D:resourcetype>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/Movies/Inception%20(2010).mkv</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>Inception (2010).mkv</D:displayname>
        <D:getcontentlength>2048</D:getcontentlength>
        <D:getcontenttype>video/x-matroska</D:getcontenttype>
        <D:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</D:getlastmodified>
        <D:getetag>"abc123"</D:getetag>
        <D:resourcetype/>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/Movies/Inception.nfo</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>Inception.nfo</D:displayname>
        <D:getcontentlength>120</D:getcontentlength>
        <D:resourcetype/>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>
"""

private let recursiveRootMultistatus = """
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/root.mkv</D:href>
    <D:propstat><D:prop><D:getcontentlength>10</D:getcontentlength><D:resourcetype/></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/Shows/</D:href>
    <D:propstat><D:prop><D:displayname>Shows</D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
</D:multistatus>
"""

private let showsMultistatus = """
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/Shows/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/Shows/episode1.mkv</D:href>
    <D:propstat><D:prop><D:getcontentlength>20</D:getcontentlength><D:resourcetype/></D:prop></D:propstat>
  </D:response>
</D:multistatus>
"""

// MARK: - Parser tests

@Suite("WebDAVXMLParser Tests")
struct WebDAVXMLParserTests {
    @Test("Parses resources, collections, sizes, dates, and ETags")
    func parsesMultistatus() throws {
        let resources = try WebDAVXMLParser().parse(
            data: Data(moviesMultistatus.utf8)
        )

        #expect(resources.count == 3)

        let collection = try #require(resources.first)
        #expect(collection.href == "/dav/Movies/")
        #expect(collection.displayName == "Movies")
        #expect(collection.isCollection)

        let movie = try #require(resources.dropFirst().first)
        #expect(movie.href == "/dav/Movies/Inception%20(2010).mkv")
        #expect(movie.displayName == "Inception (2010).mkv")
        #expect(movie.contentLength == 2048)
        #expect(movie.contentType == "video/x-matroska")
        #expect(movie.etag == "\"abc123\"")
        #expect(movie.lastModified != nil)
        #expect(!movie.isCollection)
    }

    @Test("Rejects invalid XML and non-multistatus documents")
    func rejectsInvalidDocuments() {
        do {
            _ = try WebDAVXMLParser().parse(data: Data("<not-xml".utf8))
            Issue.record("Expected invalidXML")
        } catch is WebDAVXMLError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try WebDAVXMLParser().parse(
                data: Data("<root><child/></root>".utf8)
            )
            Issue.record("Expected notMultistatus")
        } catch WebDAVXMLError.notMultistatus {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

// MARK: - Adapter tests

@Suite("WebDAVSourceAdapter Tests", .serialized)
struct WebDAVSourceAdapterTests {
    @Test("PROPFIND enumerates files and applies exclusion globs")
    func enumeratesAndFilters() async throws {
        let recorder = WebDAVRecorder()
        WebDAVMockURLProtocol.setHandler { request in
            recorder.record(request)
            #expect(request.httpMethod == "PROPFIND")
            #expect(request.value(forHTTPHeaderField: "Depth") == "1")
            #expect(
                request.value(forHTTPHeaderField: "Authorization")
                    == "Basic c2FteTpzZWNyZXQ="
            )
            return try webDAVRespond(
                to: request,
                data: Data(moviesMultistatus.utf8)
            )
        }

        let adapter = makeWebDAVAdapter()
        let session = try await makeWebDAVSession(adapter)
        let scope = LibraryScope(
            path: "Movies",
            recursive: false,
            excludeGlobs: ["*.nfo", "sample*"]
        )

        let items = try await collectWebDAVItems(
            try await adapter.enumerate(session: session, scope: scope)
        )

        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.name == "Inception (2010).mkv")
        #expect(item.sizeBytes == 2048)
        #expect(item.etag == "\"abc123\"")
        #expect(item.container == "mkv")
        #expect(item.sourceID == session.sourceID)
        #expect(
            item.location
                == "https://dav.example.com/dav/Movies/Inception%20(2010).mkv"
        )
        #expect(recorder.count == 1)
    }

    @Test("Recursive enumeration walks child collections")
    func recursiveEnumeration() async throws {
        WebDAVMockURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.hasPrefix("/dav/Shows") {
                return try webDAVRespond(
                    to: request,
                    data: Data(showsMultistatus.utf8)
                )
            }
            return try webDAVRespond(
                to: request,
                data: Data(recursiveRootMultistatus.utf8)
            )
        }

        let adapter = makeWebDAVAdapter()
        let session = try await makeWebDAVSession(adapter)

        let items = try await collectWebDAVItems(
            try await adapter.enumerate(
                session: session,
                scope: LibraryScope(path: "", recursive: true)
            )
        )

        let names = Set(items.map(\.name))
        #expect(names == ["root.mkv", "episode1.mkv"])
    }

    @Test("Non-recursive enumeration does not walk child collections")
    func nonRecursiveEnumeration() async throws {
        WebDAVMockURLProtocol.setHandler { request in
            try webDAVRespond(
                to: request,
                data: Data(recursiveRootMultistatus.utf8)
            )
        }

        let adapter = makeWebDAVAdapter()
        let session = try await makeWebDAVSession(adapter)

        let items = try await collectWebDAVItems(
            try await adapter.enumerate(
                session: session,
                scope: LibraryScope(path: "", recursive: false)
            )
        )

        #expect(items.map(\.name) == ["root.mkv"])
    }

    @Test("Ranged downloads send Range and parse a 206 response")
    func rangedDownload() async throws {
        let payload = Data((0..<100).map { UInt8($0) })
        let recorder = WebDAVRecorder()

        WebDAVMockURLProtocol.setHandler { request in
            recorder.record(request)
            #expect(request.httpMethod == "GET")
            #expect(
                request.value(forHTTPHeaderField: "Range") == "bytes=0-9"
            )
            #expect(
                request.value(forHTTPHeaderField: "Authorization")
                    == "Basic c2FteTpzZWNyZXQ="
            )
            return try webDAVRespond(
                to: request,
                status: 206,
                headers: ["Content-Range": "bytes 0-9/100"],
                data: payload.subdata(in: 0..<10)
            )
        }

        let adapter = makeWebDAVAdapter()
        let session = try await makeWebDAVSession(adapter)
        let item = SourceItem(
            id: "movie",
            sourceID: session.sourceID,
            kind: .movie,
            name: "Movie.mkv",
            location: "https://dav.example.com/dav/Movies/Movie.mkv",
            sizeBytes: 100
        )

        let range = try ByteRange(start: 0, end: 9)
        let data = try await collectWebDAVData(
            adapter.read(session: session, item: item, range: range)
        )

        #expect(data == payload.subdata(in: 0..<10))
    }

    @Test("Freshness reports the ETag from a depth-0 PROPFIND")
    func freshness() async throws {
        let selfOnly = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/</d:href>
            <d:propstat><d:prop>
              <d:getetag>"fresh-1"</d:getetag>
              <d:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</d:getlastmodified>
              <d:resourcetype><d:collection/></d:resourcetype>
            </d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """

        WebDAVMockURLProtocol.setHandler { request in
            #expect(request.value(forHTTPHeaderField: "Depth") == "0")
            return try webDAVRespond(
                to: request,
                data: Data(selfOnly.utf8)
            )
        }

        let adapter = makeWebDAVAdapter()
        let session = try await makeWebDAVSession(adapter)
        let freshness = try await adapter.freshness(session: session)

        #expect(freshness.strategy == .etag)
        #expect(freshness.token == "\"fresh-1\"")
        #expect(freshness.lastModified != nil)
    }

    @Test("A 401 PROPFIND surfaces an authorization error")
    func unauthorized() async throws {
        WebDAVMockURLProtocol.setHandler { request in
            try webDAVRespond(
                to: request,
                status: 401,
                data: Data()
            )
        }

        let adapter = makeWebDAVAdapter(credentials: nil)
        let session = try await makeWebDAVSession(adapter)

        do {
            _ = try await collectWebDAVItems(
                try await adapter.enumerate(
                    session: session,
                    scope: LibraryScope(path: "", recursive: false)
                )
            )
            Issue.record("Expected unauthorized")
        } catch let error as SourceAdapterError {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Connect requires an endpoint and reports WebDAV capabilities")
    func connectCapabilities() async throws {
        let adapter = makeWebDAVAdapter()
        let session = try await makeWebDAVSession(adapter)

        #expect(session.capabilities.contains(.rangeRequests))
        #expect(session.capabilities.contains(.recursiveEnumeration))
        #expect(session.capabilities.contains(.etagFreshness))
        #expect(session.metadata["endpoint"] == "https://dav.example.com/dav/")
        #expect(session.accessToken?.hasPrefix("Basic ") == true)
    }
}
