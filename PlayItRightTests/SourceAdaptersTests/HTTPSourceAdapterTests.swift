import Foundation
import Testing
@testable import SourceAdapters

// MARK: - Test doubles

private struct HTTPMockError: Error, Sendable {
    let message: String
}

private final class HTTPMockURLProtocol: URLProtocol, @unchecked Sendable {
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
                didFailWithError: HTTPMockError(message: "No handler installed")
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

private final class HTTPRequestRecorder: @unchecked Sendable {
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

private func httpRespond(
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
        throw HTTPMockError(message: "Could not build an HTTP response")
    }
    return (response, data)
}

private func makeHTTPAdapter(
    endpoint: URL = URL(string: "https://media.example.com/movies/Inception.mkv")!,
    configuration: HTTPSourceConfiguration = HTTPSourceConfiguration(
        reconnectBaseDelay: 0
    )
) -> HTTPSourceAdapter {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [HTTPMockURLProtocol.self]
    return HTTPSourceAdapter(
        configuration: configuration,
        sessionConfiguration: sessionConfiguration
    )
}

private let httpPayload = Data((0..<256).map { UInt8($0) })

private func makeHTTPItem(
    sourceID: UUID,
    location: String = "https://media.example.com/movies/Inception.mkv",
    size: Int64? = 256
) -> SourceItem {
    SourceItem(
        id: location,
        sourceID: sourceID,
        kind: .movie,
        name: "Inception.mkv",
        location: location,
        sizeBytes: size,
        container: "mkv"
    )
}

private func collect(
    _ stream: AsyncThrowingStream<Data, Error>
) async throws -> Data {
    var data = Data()
    for try await chunk in stream {
        data.append(chunk)
    }
    return data
}

// MARK: - Adapter tests

@Suite("HTTPSourceAdapter Tests", .serialized)
struct HTTPSourceAdapterTests {
    // MARK: Ranged reads

    @Test("A ranged GET sends Range and parses a 206 response")
    func rangedGetParses206() async throws {
        let recorder = HTTPRequestRecorder()
        HTTPMockURLProtocol.setHandler { request in
            recorder.record(request)
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=10-19")
            return try httpRespond(
                to: request,
                status: 206,
                headers: ["Content-Range": "bytes 10-19/256"],
                data: httpPayload.subdata(in: 10..<20)
            )
        }

        let adapter = makeHTTPAdapter()
        let config = SourceConfig(
            kind: .http,
            name: "HTTP",
            endpoint: URL(string: "https://media.example.com/movies/Inception.mkv")
        )
        let session = try await adapter.connect(config: config)
        let item = makeHTTPItem(sourceID: config.id)

        let range = try ByteRange(start: 10, end: 19)
        let data = try await collect(
            adapter.read(session: session, item: item, range: range)
        )

        #expect(data == httpPayload.subdata(in: 10..<20))
        #expect(recorder.count == 1)
    }

    @Test("An open-ended read requests bytes from the start offset")
    func openEndedRange() async throws {
        let recorder = HTTPRequestRecorder()
        HTTPMockURLProtocol.setHandler { request in
            recorder.record(request)
            #expect(
                request.value(forHTTPHeaderField: "Range") == "bytes=128-"
            )
            return try httpRespond(
                to: request,
                status: 206,
                headers: ["Content-Range": "bytes 128-255/256"],
                data: httpPayload.subdata(in: 128..<256)
            )
        }

        let adapter = makeHTTPAdapter()
        let config = SourceConfig(
            kind: .http,
            name: "HTTP",
            endpoint: URL(string: "https://media.example.com/movies/Inception.mkv")
        )
        let session = try await adapter.connect(config: config)
        let item = makeHTTPItem(sourceID: config.id)

        let range = try ByteRange(start: 128)
        let data = try await collect(
            adapter.read(session: session, item: item, range: range)
        )

        #expect(data == httpPayload.subdata(in: 128..<256))
    }

    @Test("A 200 response that ignores Range is skipped to the offset")
    func ignoresRangeHeader() async throws {
        HTTPMockURLProtocol.setHandler { request in
            try httpRespond(
                to: request,
                status: 200,
                headers: ["Content-Length": "256"],
                data: httpPayload
            )
        }

        let adapter = makeHTTPAdapter()
        let config = SourceConfig(
            kind: .http,
            name: "HTTP",
            endpoint: URL(string: "https://media.example.com/movies/Inception.mkv")
        )
        let session = try await adapter.connect(config: config)
        let item = makeHTTPItem(sourceID: config.id)

        let range = try ByteRange(start: 10, end: 19)
        let data = try await collect(
            adapter.read(session: session, item: item, range: range)
        )

        #expect(data == httpPayload.subdata(in: 10..<20))
    }

    @Test("A truncated stream resumes from the current offset")
    func resumesAfterTruncation() async throws {
        let recorder = HTTPRequestRecorder()
        HTTPMockURLProtocol.setHandler { request in
            recorder.record(request)
            let range = request.value(forHTTPHeaderField: "Range") ?? ""

            if range == "bytes=0-255" {
                return try httpRespond(
                    to: request,
                    status: 206,
                    headers: ["Content-Range": "bytes 0-255/256"],
                    data: httpPayload.subdata(in: 0..<32)
                )
            }

            #expect(range == "bytes=32-255")
            return try httpRespond(
                to: request,
                status: 206,
                headers: ["Content-Range": "bytes 32-255/256"],
                data: httpPayload.subdata(in: 32..<256)
            )
        }

        let adapter = makeHTTPAdapter()
        let config = SourceConfig(
            kind: .http,
            name: "HTTP",
            endpoint: URL(string: "https://media.example.com/movies/Inception.mkv")
        )
        let session = try await adapter.connect(config: config)
        let item = makeHTTPItem(sourceID: config.id)

        let range = try ByteRange(start: 0, end: 255)
        let data = try await collect(
            adapter.read(session: session, item: item, range: range)
        )

        #expect(data == httpPayload)
        #expect(recorder.count == 2)
    }

    @Test("A 416 response reports the total size")
    func unsatisfiableResponse() async throws {
        HTTPMockURLProtocol.setHandler { request in
            try httpRespond(
                to: request,
                status: 416,
                headers: ["Content-Range": "bytes */100"],
                data: Data()
            )
        }

        let adapter = makeHTTPAdapter()
        let config = SourceConfig(
            kind: .http,
            name: "HTTP",
            endpoint: URL(string: "https://media.example.com/movies/Inception.mkv")
        )
        let session = try await adapter.connect(config: config)
        let item = makeHTTPItem(sourceID: config.id, size: nil)

        let range = try ByteRange(start: 200)
        do {
            _ = try await collect(
                adapter.read(session: session, item: item, range: range)
            )
            Issue.record("Expected rangeNotSatisfiable")
        } catch let error as SourceAdapterError {
            #expect(
                error == .rangeNotSatisfiable(range, size: 100)
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A final 3xx response is rejected")
    func rejectsRedirectResponse() async throws {
        HTTPMockURLProtocol.setHandler { request in
            try httpRespond(
                to: request,
                status: 302,
                headers: ["Location": "https://evil.example.com/file.mkv"],
                data: Data()
            )
        }

        let adapter = makeHTTPAdapter()
        let config = SourceConfig(
            kind: .http,
            name: "HTTP",
            endpoint: URL(string: "https://media.example.com/movies/Inception.mkv")
        )
        let session = try await adapter.connect(config: config)
        let item = makeHTTPItem(sourceID: config.id)

        do {
            _ = try await collect(
                adapter.read(session: session, item: item, range: nil)
            )
            Issue.record("Expected protocolViolation")
        } catch let error as SourceAdapterError {
            if case .protocolViolation = error {
                // Expected.
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A file URL is rejected before any request")
    func rejectsFileScheme() async throws {
        let adapter = makeHTTPAdapter()
        let config = SourceConfig(
            kind: .http,
            name: "HTTP",
            endpoint: URL(string: "https://media.example.com/movies/Inception.mkv")
        )
        let session = try await adapter.connect(config: config)
        let item = makeHTTPItem(
            sourceID: config.id,
            location: "file:///etc/passwd",
            size: nil
        )

        do {
            _ = try await collect(
                adapter.read(session: session, item: item, range: nil)
            )
            Issue.record("Expected an invalidConfiguration error")
        } catch let error as SourceAdapterError {
            if case .invalidConfiguration = error {
                // Expected.
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: Enumeration

    @Test("Enumerating a direct file yields one item with HEAD metadata")
    func enumeratesDirectFile() async throws {
        HTTPMockURLProtocol.setHandler { request in
            #expect(request.httpMethod == "HEAD")
            return try httpRespond(
                to: request,
                headers: [
                    "Content-Length": "1024",
                    "ETag": "\"abc123\"",
                    "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"
                ],
                data: Data()
            )
        }

        let adapter = makeHTTPAdapter()
        let config = SourceConfig(
            kind: .http,
            name: "HTTP",
            endpoint: URL(string: "https://media.example.com/movies/Inception.mkv")
        )
        let session = try await adapter.connect(config: config)

        var items: [SourceItem] = []
        for try await item in try await adapter.enumerate(
            session: session,
            scope: LibraryScope()
        ) {
            items.append(item)
        }

        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.name == "Inception.mkv")
        #expect(item.kind == .movie)
        #expect(item.sizeBytes == 1024)
        #expect(item.etag == "\"abc123\"")
        #expect(item.modifiedAt != nil)
        #expect(item.container == "mkv")
        #expect(item.location.hasSuffix("/Inception.mkv"))
    }

    @Test("Enumerating a .strm file resolves its target")
    func enumeratesStrmFile() async throws {
        HTTPMockURLProtocol.setHandler { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix(".strm") {
                #expect(request.httpMethod == "GET")
                return try httpRespond(
                    to: request,
                    data: Data("sub/Real.Movie.mkv\n".utf8)
                )
            }
            #expect(request.httpMethod == "HEAD")
            return try httpRespond(
                to: request,
                headers: ["Content-Length": "2048"],
                data: Data()
            )
        }

        let adapter = makeHTTPAdapter(
            endpoint: URL(string: "https://media.example.com/movies/list.strm")!
        )
        let config = SourceConfig(
            kind: .http,
            name: "STRM",
            endpoint: URL(string: "https://media.example.com/movies/list.strm")
        )
        let session = try await adapter.connect(config: config)

        var items: [SourceItem] = []
        for try await item in try await adapter.enumerate(
            session: session,
            scope: LibraryScope()
        ) {
            items.append(item)
        }

        let item = try #require(items.first)
        #expect(
            item.location
                == "https://media.example.com/movies/sub/Real.Movie.mkv"
        )
        #expect(item.sizeBytes == 2048)
        #expect(item.container == "mkv")
    }

    @Test("Freshness reports the ETag from a HEAD response")
    func freshnessUsesETag() async throws {
        HTTPMockURLProtocol.setHandler { request in
            #expect(request.httpMethod == "HEAD")
            return try httpRespond(
                to: request,
                headers: [
                    "ETag": "\"etag-1\"",
                    "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"
                ],
                data: Data()
            )
        }

        let adapter = makeHTTPAdapter()
        let config = SourceConfig(
            kind: .http,
            name: "HTTP",
            endpoint: URL(string: "https://media.example.com/movies/Inception.mkv")
        )
        let session = try await adapter.connect(config: config)

        let freshness = try await adapter.freshness(session: session)
        #expect(freshness.strategy == .etag)
        #expect(freshness.token == "\"etag-1\"")
        #expect(freshness.lastModified != nil)
    }
}

// MARK: - Security tests

@Suite("StrmParser Tests")
struct StrmParserTests {
    private let parser = StrmParser()

    @Test("Parses the first non-comment line and strips quotes")
    func parsesTarget() throws {
        let text = """
        # Kodi-style stream file
        \u{FEFF}

        "https://cdn.example.com/movies/Inception.mkv"
        https://ignored.example.com/other.mkv
        """

        let url = try parser.parse(text: text)
        #expect(
            url.absoluteString
                == "https://cdn.example.com/movies/Inception.mkv"
        )
    }

    @Test("Resolves relative targets against the .strm location")
    func resolvesRelativeTarget() throws {
        let base = URL(string: "https://media.example.com/movies/list.strm")!
        let url = try parser.parse(
            text: "sub/Real.Movie.mkv",
            relativeTo: base
        )
        #expect(
            url.absoluteString
                == "https://media.example.com/movies/sub/Real.Movie.mkv"
        )
    }

    @Test("Rejects file, data, javascript, and UNC targets")
    func rejectsUnsafeSchemes() {
        let cases = [
            "file:///etc/passwd",
            "data:text/plain;base64,SGVsbG8=",
            "javascript:alert(1)",
            "\\\\nas\\share\\movie.mkv"
        ]

        for value in cases {
            do {
                _ = try parser.parse(text: value)
                Issue.record("Expected \(value) to be rejected")
            } catch is HTTPURLSecurityError {
                // Expected.
            } catch {
                Issue.record("Unexpected error for \(value): \(error)")
            }
        }
    }

    @Test("Rejects path traversal in absolute and relative targets")
    func rejectsPathTraversal() {
        let base = URL(string: "https://media.example.com/movies/list.strm")!

        for value in [
            "https://media.example.com/movies/../../etc/passwd",
            "https://media.example.com/%2e%2e/secret",
            "../secret.mkv"
        ] {
            do {
                _ = try parser.parse(text: value, relativeTo: base)
                Issue.record("Expected \(value) to be rejected")
            } catch HTTPURLSecurityError.pathTraversal {
                // Expected.
            } catch {
                Issue.record("Unexpected error for \(value): \(error)")
            }
        }
    }

    @Test("Rejects an empty .strm file")
    func rejectsEmptyFile() {
        do {
            _ = try parser.parse(text: "# only a comment\n\n")
            Issue.record("Expected emptyStrm")
        } catch HTTPURLSecurityError.emptyStrm {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite("HTTPURLSecurityPolicy Tests")
struct HTTPURLSecurityPolicyTests {
    @Test("Rejects redirects to unsupported schemes")
    func rejectsUnsafeRedirect() {
        let policy = HTTPURLSecurityPolicy()
        do {
            _ = try policy.validateRedirect(
                to: URL(string: "file:///etc/passwd")!,
                hop: 1
            )
            Issue.record("Expected an unsupported scheme")
        } catch HTTPURLSecurityError.unsupportedScheme("file") {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Rejects redirects beyond the hop limit")
    func rejectsRedirectLoop() {
        let policy = HTTPURLSecurityPolicy(maxRedirects: 3)
        let url = URL(string: "https://media.example.com/next")!

        #expect(
            (try? policy.validateRedirect(to: url, hop: 3)) != nil
        )

        do {
            _ = try policy.validateRedirect(to: url, hop: 4)
            Issue.record("Expected redirectLimitExceeded")
        } catch HTTPURLSecurityError.redirectLimitExceeded(max: 3) {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Rejects embedded credentials")
    func rejectsEmbeddedCredentials() {
        let policy = HTTPURLSecurityPolicy()
        let url = URL(string: "https://user:pass@media.example.com/file.mkv")!

        do {
            _ = try policy.validate(url)
            Issue.record("Expected embeddedCredentials")
        } catch HTTPURLSecurityError.embeddedCredentials {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Restricts hosts when an allowlist is configured")
    func restrictsHosts() {
        let policy = HTTPURLSecurityPolicy(
            allowedHosts: ["media.example.com"]
        )

        #expect(
            (try? policy.validate(
                URL(string: "https://media.example.com/file.mkv")!
            )) != nil
        )

        do {
            _ = try policy.validate(
                URL(string: "https://other.example.com/file.mkv")!
            )
            Issue.record("Expected the host to be rejected")
        } catch is HTTPURLSecurityError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
