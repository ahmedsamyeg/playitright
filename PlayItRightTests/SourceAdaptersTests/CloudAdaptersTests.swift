import Foundation
import Testing
@testable import SourceAdapters

// MARK: - Test doubles

private actor CloudMockTransport: CloudHTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private let handler: Handler
    private var recorded: [URLRequest] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.append(request)
        let (status, data) = try handler(request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            throw SourceAdapterError.protocolViolation("No response URL.")
        }
        return (data, response)
    }

    func requests() -> [URLRequest] {
        recorded
    }
}

private let payload = Data("0123456789ABCDEFGHIJ".utf8)
private let rootJSONDate = "2024-01-02T03:04:05Z"

private func ranged(
    _ request: URLRequest,
    payload: Data = payload
) -> (Int, Data)? {
    guard let header = request.value(forHTTPHeaderField: "Range"),
          let range = ByteRange(httpHeaderValue: header),
          let clamped = range.clamped(to: Int64(payload.count)) else {
        return nil
    }
    let end = Int(clamped.end ?? (Int64(payload.count) - 1))
    return (206, payload.subdata(in: Int(clamped.start)..<(end + 1)))
}

private func collect<T: Sendable>(
    _ stream: AsyncThrowingStream<T, Error>
) async throws -> [T] {
    var values: [T] = []
    for try await value in stream {
        values.append(value)
    }
    return values
}

private func collectData(
    _ stream: AsyncThrowingStream<Data, Error>
) async throws -> Data {
    try await collect(stream).reduce(into: Data()) { $0.append($1) }
}

private func tokenProvider() -> CloudTokenProvider {
    { OAuthToken(accessToken: "token-123") }
}

private func bodyText(_ request: URLRequest) -> String {
    guard let data = request.httpBody else {
        return ""
    }
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - Tests

@Suite("CloudAdapters Tests")
struct CloudAdaptersTests {
    @Test("Google Drive enumerates folders and streams ranges")
    func googleDrive() async throws {
        let transport = CloudMockTransport { request in
            if let ranged = ranged(request) {
                return ranged
            }
            let url = request.url?.absoluteString ?? ""
            if url.contains("folder1") {
                return (
                    200,
                    Data("""
                    {"files":[{"id":"f2","name":"movie.mkv",
                    "mimeType":"video/x-matroska","size":"20",
                    "modifiedTime":"\(rootJSONDate)"}]}
                    """.utf8)
                )
            }
            return (
                200,
                Data("""
                {"files":[
                {"id":"folder1","name":"Movies",
                "mimeType":"application/vnd.google-apps.folder"},
                {"id":"f1","name":"trailer.mp4","mimeType":"video/mp4",
                "size":"10","modifiedTime":"\(rootJSONDate)"}]}
                """.utf8)
            )
        }

        let adapter = GoogleDriveAdapter(
            api: GoogleDriveAPI(),
            transport: transport,
            tokenProvider: tokenProvider(),
            chunkSize: 64 * 1024
        )
        let session = try await adapter.connect(
            config: SourceConfig(
                kind: .googleDrive,
                name: "Drive"
            )
        )
        #expect(adapter.kind == .googleDrive)
        #expect(session.metadata["cloud.root"] == "root")
        #expect(session.accessToken == "token-123")

        let items = try await collect(
            adapter.enumerate(session: session, scope: LibraryScope())
        )
        #expect(items.count == 3)
        #expect(items[0].name == "Movies")
        #expect(items[0].kind == .folder)
        let trailer = try #require(items.first { $0.name == "trailer.mp4" })
        #expect(trailer.container == "mp4")
        let movie = try #require(items.first { $0.name == "movie.mkv" })
        #expect(movie.sizeBytes == 20)
        #expect(movie.parentID == items[0].id)
        let range = try ByteRange(start: 5, end: 9)
        let data = try await collectData(
            adapter.read(session: session, item: movie, range: range)
        )
        #expect(data == Data("56789".utf8))

        let requests = await transport.requests()
        let last = try #require(requests.last)
        #expect(last.value(forHTTPHeaderField: "Range") == "bytes=5-9")
        #expect(
            last.value(forHTTPHeaderField: "Authorization")
                == "Bearer token-123"
        )

        let shallow = try await collect(
            adapter.enumerate(
                session: session,
                scope: LibraryScope(recursive: false)
            )
        )
        #expect(shallow.count == 2)
    }

    @Test("Dropbox enumerates paths and streams ranged downloads")
    func dropbox() async throws {
        let transport = CloudMockTransport { request in
            if let ranged = ranged(request) {
                return ranged
            }
            let body = bodyText(request)
            if body.contains("/movies") {
                return (
                    200,
                    Data("""
                    {"entries":[{".tag":"file","name":"movie.mkv",
                    "path_lower":"/movies/movie.mkv","size":20,
                    "server_modified":"\(rootJSONDate)"}],
                    "cursor":"c2","has_more":false}
                    """.utf8)
                )
            }
            return (
                200,
                Data("""
                {"entries":[
                {".tag":"folder","name":"Movies",
                "path_lower":"/movies","id":"id:folder1"},
                {".tag":"file","name":"trailer.mp4",
                "path_lower":"/trailer.mp4","size":10,
                "server_modified":"\(rootJSONDate)"}],
                "cursor":"c1","has_more":false}
                """.utf8)
            )
        }

        let adapter = DropboxAdapter(
            api: DropboxAPI(),
            transport: transport,
            tokenProvider: tokenProvider(),
            chunkSize: 64 * 1024
        )
        let session = try await adapter.connect(
            config: SourceConfig(kind: .dropbox, name: "Dropbox")
        )
        let items = try await collect(
            adapter.enumerate(session: session, scope: LibraryScope())
        )
        #expect(items.count == 3)
        #expect(items[0].name == "Movies")
        #expect(items[0].location == "/movies")
        let movie = try #require(items.first { $0.name == "movie.mkv" })
        #expect(movie.location == "/movies/movie.mkv")

        let range = try ByteRange(start: 0, end: 3)
        let data = try await collectData(
            adapter.read(session: session, item: movie, range: range)
        )
        #expect(data == Data("0123".utf8))

        let requests = await transport.requests()
        let download = try #require(
            requests.first {
                $0.value(forHTTPHeaderField: "Dropbox-API-Arg") != nil
            }
        )
        let argument = try #require(
            download.value(forHTTPHeaderField: "Dropbox-API-Arg")
        )
        let argumentObject = try JSONSerialization.jsonObject(
            with: Data(argument.utf8)
        ) as? [String: Any]
        #expect(argumentObject?["path"] as? String == "/movies/movie.mkv")
        #expect(download.value(forHTTPHeaderField: "Range") == "bytes=0-3")
    }

    @Test("OneDrive enumerates Graph children and streams ranges")
    func oneDrive() async throws {
        let transport = CloudMockTransport { request in
            if let ranged = ranged(request) {
                return ranged
            }
            let url = request.url?.absoluteString ?? ""
            if url.contains("folder1") {
                return (
                    200,
                    Data("""
                    {"value":[{"id":"f2","name":"movie.mkv","size":20,
                    "lastModifiedDateTime":"\(rootJSONDate)",
                    "file":{}}]}
                    """.utf8)
                )
            }
            return (
                200,
                Data("""
                {"value":[
                {"id":"folder1","name":"Movies","folder":{}},
                {"id":"f1","name":"trailer.mp4","size":10,
                "lastModifiedDateTime":"\(rootJSONDate)","file":{}}]}
                """.utf8)
            )
        }

        let adapter = OneDriveAdapter(
            api: OneDriveAPI(),
            transport: transport,
            tokenProvider: tokenProvider(),
            chunkSize: 64 * 1024
        )
        let session = try await adapter.connect(
            config: SourceConfig(kind: .oneDrive, name: "OneDrive")
        )
        let items = try await collect(
            adapter.enumerate(session: session, scope: LibraryScope())
        )
        #expect(items.count == 3)
        #expect(items[0].name == "Movies")
        #expect(items[0].kind == .folder)
        let movie = try #require(items.first { $0.name == "movie.mkv" })

        let range = try ByteRange(start: 2, end: 6)
        let data = try await collectData(
            adapter.read(session: session, item: movie, range: range)
        )
        #expect(data == Data("23456".utf8))

        let requests = await transport.requests()
        #expect(
            requests.contains {
                $0.url?.absoluteString.contains("/content") == true
                    && $0.value(forHTTPHeaderField: "Range") == "bytes=2-6"
            }
        )
    }

    @Test("Box enumerates folder items and streams ranges")
    func box() async throws {
        let transport = CloudMockTransport { request in
            if let ranged = ranged(request) {
                return ranged
            }
            let url = request.url?.absoluteString ?? ""
            if url.contains("folders/folder1/items") {
                return (
                    200,
                    Data("""
                    {"total_count":1,"offset":0,"limit":1000,
                    "entries":[{"id":"f2","type":"file","name":"movie.mkv",
                    "size":20,"modified_at":"\(rootJSONDate)"}]}
                    """.utf8)
                )
            }
            return (
                200,
                Data("""
                {"total_count":2,"offset":0,"limit":1000,
                "entries":[
                {"id":"folder1","type":"folder","name":"Movies"},
                {"id":"f1","type":"file","name":"trailer.mp4","size":10,
                "modified_at":"\(rootJSONDate)"}]}
                """.utf8)
            )
        }

        let adapter = BoxAdapter(
            api: BoxAPI(),
            transport: transport,
            tokenProvider: tokenProvider(),
            chunkSize: 64 * 1024
        )
        let session = try await adapter.connect(
            config: SourceConfig(kind: .box, name: "Box")
        )
        let items = try await collect(
            adapter.enumerate(session: session, scope: LibraryScope())
        )
        #expect(items.count == 3)
        #expect(items[0].name == "Movies")
        #expect(items[0].kind == .folder)
        let movie = try #require(items.first { $0.name == "movie.mkv" })

        let range = try ByteRange(start: 9, end: nil)
        let data = try await collectData(
            adapter.read(session: session, item: movie, range: range)
        )
        #expect(data == Data("9ABCDEFGHIJ".utf8))

        let requests = await transport.requests()
        let last = try #require(requests.last)
        #expect(last.value(forHTTPHeaderField: "Range") == "bytes=9-19")
    }

    @Test("A missing cloud token surfaces as unauthorized")
    func missingToken() async {
        let adapter = GoogleDriveAdapter(
            api: GoogleDriveAPI(),
            transport: CloudMockTransport { _ in (200, Data()) },
            tokenProvider: { nil }
        )
        await #expect(throws: SourceAdapterError.unauthorized) {
            _ = try await adapter.connect(
                config: SourceConfig(kind: .googleDrive, name: "Drive")
            )
        }
    }

    @Test("Cloud request helpers map status codes and range fallbacks")
    func requestHelpers() async throws {
        let request = URLRequest(
            url: URL(string: "https://example.com/file")!
        )
        let range = try ByteRange(start: 4, end: 7)

        let ignoringRange = CloudMockTransport { _ in (200, payload) }
        let sliced = try await CloudRequest.rangedData(
            request,
            range: range,
            transport: ignoringRange
        )
        #expect(sliced == Data("4567".utf8))

        let tooLarge = CloudMockTransport { _ in (416, Data()) }
        await #expect(throws: SourceAdapterError.self) {
            _ = try await CloudRequest.rangedData(
                request,
                range: range,
                transport: tooLarge
            )
        }
    }
}
