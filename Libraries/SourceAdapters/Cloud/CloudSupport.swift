import Foundation

// MARK: - HTTP seam

/// HTTP seam shared by the cloud drive adapters.
public protocol CloudHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession-backed transport with a dedicated, cache-free configuration.
public struct URLSessionCloudTransport: CloudHTTPTransport, Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public init(configuration: URLSessionConfiguration) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceAdapterError.protocolViolation("The response was not HTTP.")
        }
        return (data, http)
    }
}

/// Resolves the current OAuth token for a cloud source, refreshing when needed.
public typealias CloudTokenProvider = @Sendable () async throws -> OAuthToken?

// MARK: - Normalized entries

/// One file or folder returned by a cloud provider.
public struct CloudEntry: Sendable, Equatable {
    /// Provider-native identifier used for listing children and ranged reads.
    public var id: String
    public var name: String
    public var isDirectory: Bool
    public var sizeBytes: Int64?
    public var modifiedAt: Date?

    public init(
        id: String,
        name: String,
        isDirectory: Bool,
        sizeBytes: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

/// One page of children plus an opaque continuation token.
public struct CloudListPage: Sendable, Equatable {
    public var entries: [CloudEntry]
    public var nextPageToken: String?

    public init(entries: [CloudEntry], nextPageToken: String? = nil) {
        self.entries = entries
        self.nextPageToken = nextPageToken
    }
}

// MARK: - Provider seam

/// The provider-specific half of a cloud drive adapter (SRC-12, SRC-13).
public protocol CloudDriveAPI: Sendable {
    var kind: SourceKind { get }
    var providerName: String { get }
    var defaultRootID: String { get }

    func listChildren(
        folderID: String,
        pageToken: String?,
        token: String,
        transport: any CloudHTTPTransport
    ) async throws -> CloudListPage

    func read(
        fileID: String,
        range: ByteRange,
        token: String,
        transport: any CloudHTTPTransport
    ) async throws -> Data
}

// MARK: - Shared request helpers

public enum CloudRequest {
    public static func authorization(_ token: String) -> String {
        "Bearer \(token)"
    }

    public static func validate(
        response: HTTPURLResponse,
        data: Data
    ) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw SourceAdapterError.unauthorized
        case 404:
            throw SourceAdapterError.notFound(
                response.url?.absoluteString ?? "cloud item"
            )
        case 416:
            throw SourceAdapterError.rangeNotSatisfiable(
                .full,
                size: nil
            )
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SourceAdapterError.transport(
                "HTTP \(response.statusCode): \(body.prefix(300))"
            )
        }
    }

    /// Sends a ranged request, tolerating providers that ignore `Range` and
    /// return the whole object with `200 OK` (SRC-13).
    public static func rangedData(
        _ request: URLRequest,
        range: ByteRange,
        transport: any CloudHTTPTransport
    ) async throws -> Data {
        let (data, response) = try await transport.send(request)
        try validate(response: response, data: data)

        if response.statusCode == 200 {
            let start = Int(min(range.start, Int64(data.count)))
            let end: Int
            if let requestedEnd = range.end {
                end = min(Int(requestedEnd) + 1, data.count)
            } else {
                end = data.count
            }
            guard start <= end else {
                throw SourceAdapterError.rangeNotSatisfiable(
                    range,
                    size: Int64(data.count)
                )
            }
            return data.subdata(in: start..<end)
        }
        return data
    }

    public static func iso8601(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    public static func int64(_ value: String?) -> Int64? {
        value.flatMap(Int64.init)
    }

    public static func container(for name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
}

// MARK: - Shared adapter

/// Provider-agnostic implementation of the cloud drive source adapter.
///
/// Enumeration walks the folder hierarchy with provider pagination, and reads
/// fetch bounded ranges so the player never downloads a whole object
/// (SRC-12, SRC-13, SRC-14).
public struct CloudDriveCore<API: CloudDriveAPI>: SourceAdapter, Sendable {
    public let api: API
    public let transport: any CloudHTTPTransport
    public let tokenProvider: CloudTokenProvider
    public let chunkSize: Int
    public let maximumDepth: Int

    public var kind: SourceKind {
        api.kind
    }

    public init(
        api: API,
        transport: any CloudHTTPTransport = URLSessionCloudTransport(),
        tokenProvider: @escaping CloudTokenProvider,
        chunkSize: Int = 4 * 1024 * 1024,
        maximumDepth: Int = 32
    ) {
        self.api = api
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.chunkSize = max(64 * 1024, chunkSize)
        self.maximumDepth = max(1, maximumDepth)
    }

    // MARK: SourceAdapter

    public func connect(config: SourceConfig) async throws -> SourceSession {
        let token = try await currentToken()
        let root = config.options["root"] ?? api.defaultRootID
        return SourceSession(
            sourceID: config.id,
            capabilities: [
                .rangeRequests,
                .recursiveEnumeration,
                .directPlay
            ],
            accessToken: token,
            metadata: [
                "cloud.provider": api.providerName,
                "cloud.root": root
            ]
        )
    }

    public func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        let token = try await currentToken()
        let root = scope.path.isEmpty
            ? (session.metadata["cloud.root"] ?? api.defaultRootID)
            : scope.path
        let items = try await walk(
            folderID: root,
            parentID: nil,
            token: token,
            scope: scope,
            sourceID: session.sourceID,
            depth: 0,
            visited: []
        )

        return ItemStream { continuation in
            Task {
                for item in items {
                    if Task.isCancelled {
                        break
                    }
                    continuation.yield(item)
                }
                continuation.finish()
            }
        }
    }

    public func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let token = try await self.currentToken()
                    try await self.stream(
                        fileID: item.location,
                        sizeBytes: item.sizeBytes,
                        range: range,
                        token: token,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func freshness(session: SourceSession) async throws -> FreshnessInfo {
        FreshnessInfo(
            strategy: .etag,
            checkedAt: Date()
        )
    }

    // MARK: Enumeration

    private func walk(
        folderID: String,
        parentID: String?,
        token: String,
        scope: LibraryScope,
        sourceID: UUID,
        depth: Int,
        visited: Set<String>
    ) async throws -> [SourceItem] {
        guard depth <= maximumDepth, !visited.contains(folderID) else {
            return []
        }
        var visited = visited
        visited.insert(folderID)

        var items: [SourceItem] = []
        var pageToken: String?
        repeat {
            try Task.checkCancellation()
            let page = try await api.listChildren(
                folderID: folderID,
                pageToken: pageToken,
                token: token,
                transport: transport
            )

            for entry in page.entries {
                let kind: SourceItemKind = entry.isDirectory ? .folder : .movie
                let item = SourceItem(
                    id: "\(sourceID.uuidString)-\(entry.id)",
                    sourceID: sourceID,
                    kind: kind,
                    name: entry.name,
                    location: entry.id,
                    parentID: parentID,
                    sizeBytes: entry.sizeBytes,
                    modifiedAt: entry.modifiedAt,
                    container: entry.isDirectory
                        ? nil
                        : CloudRequest.container(for: entry.name)
                )
                items.append(item)

                if entry.isDirectory,
                   scope.recursive,
                   depth < maximumDepth {
                    let children = try await walk(
                        folderID: entry.id,
                        parentID: item.id,
                        token: token,
                        scope: scope,
                        sourceID: sourceID,
                        depth: depth + 1,
                        visited: visited
                    )
                    items.append(contentsOf: children)
                }
            }
            pageToken = page.nextPageToken
        } while pageToken != nil

        return items
    }

    // MARK: Ranged reads

    private func stream(
        fileID: String,
        sizeBytes: Int64?,
        range: ByteRange?,
        token: String,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        var cursor = range?.start ?? 0
        let endExclusive: Int64? = range?.end.map { $0 + 1 }
            ?? sizeBytes

        while true {
            try Task.checkCancellation()
            if let endExclusive, cursor >= endExclusive {
                return
            }

            let chunkEnd: Int64
            if let endExclusive {
                chunkEnd = min(endExclusive - 1, cursor + Int64(chunkSize) - 1)
            } else {
                chunkEnd = cursor + Int64(chunkSize) - 1
            }

            let requested = try ByteRange(start: cursor, end: chunkEnd)
            let data = try await api.read(
                fileID: fileID,
                range: requested,
                token: token,
                transport: transport
            )
            if data.isEmpty {
                return
            }
            continuation.yield(data)
            cursor += Int64(data.count)

            if data.count < Int(requested.length ?? Int64(data.count)) {
                return
            }
        }
    }

    // MARK: Tokens

    private func currentToken() async throws -> String {
        guard let token = try await tokenProvider()?.accessToken,
              !token.isEmpty else {
            throw SourceAdapterError.unauthorized
        }
        return token
    }
}
