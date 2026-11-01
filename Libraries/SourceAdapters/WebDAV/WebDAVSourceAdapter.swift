import Foundation

/// Username/password resolved from the Keychain for a WebDAV source.
public struct WebDAVCredentials: Sendable, Equatable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// `Authorization` value for HTTP basic auth.
    public var basicAuthorization: String {
        let raw = Data("\(username):\(password)".utf8)
        return "Basic \(raw.base64EncodedString())"
    }
}

/// Configuration for ``WebDAVSourceAdapter``.
public struct WebDAVConfiguration: Sendable, Equatable {
    public var requestTimeout: TimeInterval
    public var resourceTimeout: TimeInterval
    public var maxRedirects: Int
    public var maxReconnects: Int
    public var reconnectBaseDelay: TimeInterval
    public var allowsSelfSignedCertificates: Bool
    public var allowedHosts: Set<String>?
    public var maxDepth: Int
    public var maxResponseBytes: Int

    public init(
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 600,
        maxRedirects: Int = 3,
        maxReconnects: Int = 3,
        reconnectBaseDelay: TimeInterval = 0.5,
        allowsSelfSignedCertificates: Bool = false,
        allowedHosts: Set<String>? = nil,
        maxDepth: Int = 16,
        maxResponseBytes: Int = 8 * 1024 * 1024
    ) {
        self.requestTimeout = max(1, requestTimeout)
        self.resourceTimeout = max(1, resourceTimeout)
        self.maxRedirects = max(0, maxRedirects)
        self.maxReconnects = max(0, maxReconnects)
        self.reconnectBaseDelay = max(0, reconnectBaseDelay)
        self.allowsSelfSignedCertificates = allowsSelfSignedCertificates
        self.allowedHosts = allowedHosts
        self.maxDepth = max(0, maxDepth)
        self.maxResponseBytes = max(1, maxResponseBytes)
    }
}

/// WebDAV adapter using `PROPFIND` for enumeration and ranged `GET` for reads.
public final class WebDAVSourceAdapter: SourceAdapter, @unchecked Sendable {
    public let kind: SourceKind = .webdav
    public let configuration: WebDAVConfiguration

    /// Resolves credentials from the Keychain on connect.
    public typealias CredentialProvider = @Sendable (
        SourceConfig
    ) -> WebDAVCredentials?

    private let policy: HTTPURLSecurityPolicy
    private let client: HTTPStreamingClient
    private let credentialProvider: CredentialProvider?

    public init(
        configuration: WebDAVConfiguration = WebDAVConfiguration(),
        sessionConfiguration: URLSessionConfiguration? = nil,
        credentialProvider: CredentialProvider? = nil
    ) {
        self.configuration = configuration
        self.credentialProvider = credentialProvider

        let policy = HTTPURLSecurityPolicy(
            allowedHosts: configuration.allowedHosts,
            maxRedirects: configuration.maxRedirects
        )
        self.policy = policy

        let sessionConfiguration = sessionConfiguration
            ?? URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration
            .requestTimeout
        sessionConfiguration.timeoutIntervalForResource = configuration
            .resourceTimeout
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData

        self.client = HTTPStreamingClient(
            configuration: sessionConfiguration,
            policy: policy,
            allowsSelfSignedCertificates: configuration
                .allowsSelfSignedCertificates
        )
    }

    // MARK: - Connect

    public func connect(config: SourceConfig) async throws -> SourceSession {
        guard let endpoint = config.endpoint else {
            throw SourceAdapterError.invalidConfiguration(
                "A WebDAV source needs an endpoint URL."
            )
        }

        let validated: URL
        do {
            validated = try policy.validate(endpoint)
        } catch {
            throw SourceAdapterError.invalidConfiguration(
                error.localizedDescription
            )
        }

        var metadata = ["endpoint": validated.absoluteString]
        if validated.scheme?.lowercased() == "http" {
            metadata["insecure"] = "true"
        }

        let credentials = credentialProvider?(config)
        if let credentials {
            client.setCredential(
                URLCredential(
                    user: credentials.username,
                    password: credentials.password,
                    persistence: .none
                )
            )
        }

        return SourceSession(
            sourceID: config.id,
            capabilities: [
                .rangeRequests,
                .directPlay,
                .etagFreshness,
                .modificationTimeFreshness,
                .recursiveEnumeration
            ],
            accessToken: credentials?.basicAuthorization,
            metadata: metadata
        )
    }

    // MARK: - Enumerate

    public func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        let start = try startURL(session: session, scope: scope)

        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                await walk(
                    from: start,
                    session: session,
                    scope: scope,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func walk(
        from start: URL,
        session: SourceSession,
        scope: LibraryScope,
        continuation: AsyncThrowingStream<SourceItem, Error>.Continuation
    ) async {
        var queue: [(url: URL, depth: Int)] = [(start, 0)]
        var visited: Set<String> = []

        do {
            while !queue.isEmpty {
                try Task.checkCancellation()

                let (collectionURL, depth) = queue.removeFirst()
                let key = collectionURL.absoluteString
                if visited.contains(key) {
                    continue
                }
                visited.insert(key)

                let resources = try await propfind(
                    collectionURL,
                    depth: 1,
                    session: session
                )

                for resource in resources {
                    guard let itemURL = resolve(
                        resource.href,
                        relativeTo: collectionURL
                    ) else {
                        continue
                    }

                    if isSameResource(itemURL, collectionURL) {
                        continue
                    }

                    if resource.isCollection {
                        if scope.recursive,
                           depth < configuration.maxDepth {
                            queue.append((itemURL, depth + 1))
                        }
                        continue
                    }

                    let item = makeItem(
                        resource,
                        url: itemURL,
                        parent: collectionURL,
                        sourceID: session.sourceID
                    )

                    let path = itemURL.path.removingPercentEncoding
                        ?? itemURL.path
                    guard SourceGlob.allows(
                        name: item.name,
                        path: path,
                        include: scope.includeGlobs,
                        exclude: scope.excludeGlobs
                    ) else {
                        continue
                    }

                    continuation.yield(item)
                }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: SourceAdapterError.cancelled)
        } catch let error as SourceAdapterError {
            continuation.finish(throwing: error)
        } catch {
            continuation.finish(
                throwing: SourceAdapterError.transport(
                    error.localizedDescription
                )
            )
        }
    }

    // MARK: - Read

    public func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                await streamRead(
                    session: session,
                    item: item,
                    requestedRange: range,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func streamRead(
        session: SourceSession,
        item: SourceItem,
        requestedRange: ByteRange?,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        let url: URL
        do {
            guard let parsed = URL(string: item.location) else {
                throw SourceAdapterError.invalidConfiguration(
                    "The item location is not a URL."
                )
            }
            do {
                url = try policy.validate(parsed)
            } catch {
                throw SourceAdapterError.invalidConfiguration(
                    error.localizedDescription
                )
            }

            if let size = item.sizeBytes,
               let requestedRange,
               requestedRange.start >= size {
                throw SourceAdapterError.rangeNotSatisfiable(
                    requestedRange,
                    size: size
                )
            }
        } catch {
            continuation.finish(throwing: error)
            return
        }

        let upperBound = requestedRange?.end
        var offset = requestedRange?.start ?? 0
        var attempts = 0

        while true {
            if Task.isCancelled {
                continuation.finish(throwing: SourceAdapterError.cancelled)
                return
            }

            let requestRange: ByteRange?
            if offset > 0 || upperBound != nil {
                requestRange = try? ByteRange(start: offset, end: upperBound)
            } else {
                requestRange = nil
            }

            var request = URLRequest(
                url: url,
                timeoutInterval: configuration.requestTimeout
            )
            request.httpMethod = "GET"
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let token = session.accessToken {
                request.setValue(token, forHTTPHeaderField: "Authorization")
            }
            if let requestRange, requestRange != .full {
                request.setValue(
                    requestRange.httpHeaderValue,
                    forHTTPHeaderField: "Range"
                )
            }

            do {
                var skip: Int64 = 0
                var totalSize: Int64?

                for try await event in client.stream(request) {
                    switch event {
                    case .response(let response):
                        let requested = requestRange ?? .full
                        let mapping = try mapResponse(
                            response,
                            requested: requested,
                            currentOffset: offset
                        )
                        skip = mapping.skip
                        totalSize = mapping.totalSize

                    case .data(var chunk):
                        if skip > 0 {
                            let discarded = min(skip, Int64(chunk.count))
                            chunk = chunk.dropFirst(Int(discarded))
                            skip -= discarded
                        }
                        guard !chunk.isEmpty else {
                            continue
                        }

                        if let upperBound {
                            let remaining = upperBound - offset + 1
                            if remaining <= 0 {
                                continuation.finish()
                                return
                            }
                            if Int64(chunk.count) > remaining {
                                chunk = chunk.prefix(Int(remaining))
                            }
                        }

                        guard !chunk.isEmpty else {
                            continue
                        }
                        continuation.yield(chunk)
                        offset += Int64(chunk.count)

                        if let upperBound, offset > upperBound {
                            continuation.finish()
                            return
                        }
                        if let totalSize, offset >= totalSize {
                            continuation.finish()
                            return
                        }
                    }
                }

                if let upperBound, offset <= upperBound {
                    throw HTTPStreamError.transport(
                        "The stream ended at byte \(offset) before \(upperBound + 1)."
                    )
                }
                continuation.finish()
                return
            } catch is CancellationError {
                continuation.finish(throwing: SourceAdapterError.cancelled)
                return
            } catch let error as SourceAdapterError {
                continuation.finish(throwing: error)
                return
            } catch let error as HTTPStreamError where error == .cancelled {
                continuation.finish(throwing: SourceAdapterError.cancelled)
                return
            } catch {
                attempts += 1
                guard attempts <= configuration.maxReconnects else {
                    continuation.finish(
                        throwing: SourceAdapterError.transport(
                            error.localizedDescription
                        )
                    )
                    return
                }

                let delay = configuration.reconnectBaseDelay
                    * pow(2, Double(attempts - 1))
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    continuation.finish(throwing: SourceAdapterError.cancelled)
                    return
                }
            }
        }
    }

    // MARK: - Freshness

    public func freshness(session: SourceSession) async throws
        -> FreshnessInfo {
        guard let raw = session.metadata["endpoint"],
              let endpoint = URL(string: raw) else {
            throw SourceAdapterError.invalidConfiguration(
                "The session has no endpoint."
            )
        }

        let resources = try await propfind(
            try policy.validate(endpoint),
            depth: 0,
            session: session
        )
        let selfResource = resources.first {
            resolve($0.href, relativeTo: endpoint).map {
                isSameResource($0, endpoint)
            } ?? false
        }

        if let etag = selfResource?.etag {
            return FreshnessInfo(
                strategy: .etag,
                token: etag,
                lastModified: selfResource?.lastModified
            )
        }
        if let modified = selfResource?.lastModified {
            return FreshnessInfo(
                strategy: .modificationTime,
                lastModified: modified
            )
        }
        return FreshnessInfo(strategy: .none)
    }

    // MARK: - PROPFIND

    private static let propfindBody = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:getcontentlength/>
            <D:getcontenttype/>
            <D:getlastmodified/>
            <D:getetag/>
            <D:resourcetype/>
          </D:prop>
        </D:propfind>
        """.utf8
    )

    private func propfind(
        _ url: URL,
        depth: Int,
        session: SourceSession
    ) async throws -> [WebDAVResource] {
        var request = URLRequest(
            url: url,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "PROPFIND"
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue(
            "application/xml; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        if let token = session.accessToken {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.propfindBody

        let response: HTTPURLResponse
        let data: Data
        do {
            (response, data) = try await client.fetch(
                request,
                byteLimit: configuration.maxResponseBytes
            )
        } catch let error as SourceAdapterError {
            throw error
        } catch let error as HTTPStreamError where error == .cancelled {
            throw SourceAdapterError.cancelled
        } catch {
            throw SourceAdapterError.transport(error.localizedDescription)
        }

        switch response.statusCode {
        case 207, 200:
            break
        case 401, 403:
            throw SourceAdapterError.unauthorized
        case 404:
            throw SourceAdapterError.notFound(url.absoluteString)
        case 405:
            throw SourceAdapterError.unsupported("PROPFIND")
        default:
            throw SourceAdapterError.transport(
                "The WebDAV server returned HTTP \(response.statusCode)."
            )
        }

        do {
            return try WebDAVXMLParser().parse(data: data)
        } catch {
            throw SourceAdapterError.protocolViolation(
                error.localizedDescription
            )
        }
    }

    // MARK: - Helpers

    private func startURL(
        session: SourceSession,
        scope: LibraryScope
    ) throws -> URL {
        guard let raw = session.metadata["endpoint"],
              let endpoint = URL(string: raw) else {
            throw SourceAdapterError.invalidConfiguration(
                "The session has no endpoint."
            )
        }

        if scope.path.isEmpty {
            return endpoint
        }

        do {
            return try policy.resolve(scope.path, relativeTo: endpoint)
        } catch {
            throw SourceAdapterError.invalidConfiguration(
                error.localizedDescription
            )
        }
    }

    private func resolve(_ href: String, relativeTo base: URL) -> URL? {
        guard let url = URL(string: href, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == base.scheme?.lowercased(),
              url.host?.lowercased() == base.host?.lowercased() else {
            return nil
        }
        return url
    }

    private func isSameResource(_ lhs: URL, _ rhs: URL) -> Bool {
        func normalized(_ url: URL) -> String {
            let path = url.path.hasSuffix("/")
                ? String(url.path.dropLast())
                : url.path
            return (url.host ?? "") + path
        }
        return normalized(lhs) == normalized(rhs)
    }

    private func makeItem(
        _ resource: WebDAVResource,
        url: URL,
        parent: URL,
        sourceID: UUID
    ) -> SourceItem {
        let fallbackName = url.lastPathComponent.removingPercentEncoding
            ?? url.lastPathComponent
        let name = resource.displayName ?? fallbackName
        let extensionName = url.pathExtension.lowercased()

        return SourceItem(
            id: url.absoluteString,
            sourceID: sourceID,
            kind: .movie,
            name: name,
            location: url.absoluteString,
            parentID: parent.absoluteString,
            sizeBytes: resource.contentLength,
            modifiedAt: resource.lastModified,
            etag: resource.etag,
            container: extensionName.isEmpty ? nil : extensionName
        )
    }

    private func mapResponse(
        _ response: HTTPURLResponse,
        requested: ByteRange,
        currentOffset: Int64
    ) throws -> (skip: Int64, totalSize: Int64?) {
        switch response.statusCode {
        case 206:
            guard let header = response.value(
                forHTTPHeaderField: "Content-Range"
            ), let contentRange = HTTPContentRange.parse(header) else {
                throw SourceAdapterError.protocolViolation(
                    "A 206 response had no valid Content-Range header."
                )
            }
            guard contentRange.start == currentOffset else {
                throw SourceAdapterError.protocolViolation(
                    "Content-Range starts at \(contentRange.start), expected \(currentOffset)."
                )
            }
            return (0, contentRange.total)

        case 200:
            return (
                requested.start,
                response.value(
                    forHTTPHeaderField: "Content-Length"
                ).flatMap(Int64.init)
            )

        case 416:
            let total = response.value(
                forHTTPHeaderField: "Content-Range"
            ).flatMap(HTTPContentRange.unsatisfiedTotal)
            throw SourceAdapterError.rangeNotSatisfiable(requested, size: total)

        case 401, 403:
            throw SourceAdapterError.unauthorized

        case 404:
            throw SourceAdapterError.notFound(requested.httpHeaderValue)

        case 300..<400:
            throw SourceAdapterError.protocolViolation(
                "The source redirected more than \(configuration.maxRedirects) times."
            )

        default:
            throw SourceAdapterError.transport(
                "The server returned HTTP \(response.statusCode)."
            )
        }
    }
}
