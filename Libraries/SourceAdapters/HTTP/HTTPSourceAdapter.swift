import Foundation

/// Configuration for ``HTTPSourceAdapter``.
public struct HTTPSourceConfiguration: Sendable, Equatable {
    /// Per-request timeout.
    public var requestTimeout: TimeInterval

    /// Overall resource timeout for a single ranged request.
    public var resourceTimeout: TimeInterval

    /// Maximum redirect hops (NFR-9 defaults to 3).
    public var maxRedirects: Int

    /// How many times a dropped stream is resumed from its current offset.
    public var maxReconnects: Int

    /// Base delay for exponential reconnect backoff.
    public var reconnectBaseDelay: TimeInterval

    /// Opt-in for self-signed certificates, with a UI warning (NFR-8).
    public var allowsSelfSignedCertificates: Bool

    /// Optional host allowlist. `.strm` targets are unrestricted by default.
    public var allowedHosts: Set<String>?

    /// Maximum size of a `.strm` indirection file.
    public var maxStrmBytes: Int

    public init(
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 600,
        maxRedirects: Int = 3,
        maxReconnects: Int = 3,
        reconnectBaseDelay: TimeInterval = 0.5,
        allowsSelfSignedCertificates: Bool = false,
        allowedHosts: Set<String>? = nil,
        maxStrmBytes: Int = 256 * 1024
    ) {
        self.requestTimeout = max(1, requestTimeout)
        self.resourceTimeout = max(1, resourceTimeout)
        self.maxRedirects = max(0, maxRedirects)
        self.maxReconnects = max(0, maxReconnects)
        self.reconnectBaseDelay = max(0, reconnectBaseDelay)
        self.allowsSelfSignedCertificates = allowsSelfSignedCertificates
        self.allowedHosts = allowedHosts
        self.maxStrmBytes = max(1, maxStrmBytes)
    }
}

/// Parsed `Content-Range` header.
struct HTTPContentRange: Sendable, Equatable {
    var start: Int64
    var end: Int64
    var total: Int64?

    /// Parses `bytes 0-99/1234` or `bytes 0-99/*`.
    static func parse(_ value: String) -> HTTPContentRange? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else {
            return nil
        }
        let rest = trimmed.dropFirst("bytes ".count)
        let parts = rest.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else {
            return nil
        }
        let rangeParts = parts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeParts.count == 2,
              let start = Int64(rangeParts[0]),
              let end = Int64(rangeParts[1]),
              start >= 0,
              end >= start else {
            return nil
        }
        let total: Int64? = parts[1] == "*" ? nil : Int64(parts[1])
        return HTTPContentRange(start: start, end: end, total: total)
    }

    /// Parses the total from `bytes */1234` on a 416 response.
    static func unsatisfiedTotal(_ value: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes */") else {
            return nil
        }
        return Int64(trimmed.dropFirst("bytes */".count))
    }
}

/// How the body of a response maps onto the requested byte range.
private struct ResponseMapping {
    /// File offset of the first body byte.
    var streamStart: Int64

    /// Bytes to discard before the requested start.
    var skip: Int64

    /// Known total item size.
    var totalSize: Int64?
}

/// HTTP/HTTPS source adapter for direct file URLs and `.strm` indirection.
///
/// The adapter performs ranged `GET` requests with the standard HTTP `Range`
/// header, validates `206 Partial Content` responses, and resumes a dropped
/// stream from its current offset (SRC-2, SRC-10). `.strm` targets are resolved
/// through ``StrmParser`` with the NFR-9 security policy.
public final class HTTPSourceAdapter: SourceAdapter, @unchecked Sendable {
    public let kind: SourceKind = .http
    public let configuration: HTTPSourceConfiguration

    private let policy: HTTPURLSecurityPolicy
    private let client: HTTPStreamingClient
    private let strmParser: StrmParser

    public init(
        configuration: HTTPSourceConfiguration = HTTPSourceConfiguration(),
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.configuration = configuration

        let policy = HTTPURLSecurityPolicy(
            allowedHosts: configuration.allowedHosts,
            maxRedirects: configuration.maxRedirects
        )
        self.policy = policy
        self.strmParser = StrmParser(policy: policy)

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
                "An HTTP source needs an endpoint URL."
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

        return SourceSession(
            sourceID: config.id,
            capabilities: [
                .rangeRequests,
                .directPlay,
                .etagFreshness,
                .modificationTimeFreshness,
                .recursiveEnumeration
            ],
            metadata: metadata
        )
    }

    // MARK: - Enumerate

    public func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        let baseURL = session.metadata["endpoint"].flatMap(URL.init(string:))
        let rawLocation = scope.path.isEmpty
            ? session.metadata["endpoint"]
            : scope.path

        guard let rawLocation else {
            throw SourceAdapterError.invalidConfiguration(
                "The session has no endpoint and the scope has no path."
            )
        }

        let startURL: URL
        do {
            startURL = try policy.resolve(rawLocation, relativeTo: baseURL)
        } catch {
            throw SourceAdapterError.invalidConfiguration(
                error.localizedDescription
            )
        }

        let target = try await resolveTarget(startURL)
        let info = try await headInfo(target)

        let extensionName = target.pathExtension.lowercased()
        let name = target.lastPathComponent.removingPercentEncoding
            ?? target.lastPathComponent

        let item = SourceItem(
            id: target.absoluteString,
            sourceID: session.sourceID,
            kind: .movie,
            name: name,
            location: target.absoluteString,
            sizeBytes: info.size,
            modifiedAt: info.modifiedAt,
            etag: info.etag,
            container: extensionName.isEmpty ? nil : extensionName
        )

        return AsyncThrowingStream { continuation in
            continuation.yield(item)
            continuation.finish()
        }
    }

    // MARK: - Read

    public func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let accessToken = session.accessToken
            let authHeaderName = session.metadata["authHeaderName"]
                ?? "Authorization"
            let task = Task { [self] in
                await streamRead(
                    item: item,
                    requestedRange: range,
                    accessToken: accessToken,
                    authHeaderName: authHeaderName,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
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

        let info = try await headInfo(try policy.validate(endpoint))
        if let etag = info.etag {
            return FreshnessInfo(
                strategy: .etag,
                token: etag,
                lastModified: info.modifiedAt
            )
        }
        if let modifiedAt = info.modifiedAt {
            return FreshnessInfo(
                strategy: .modificationTime,
                lastModified: modifiedAt
            )
        }
        return FreshnessInfo(strategy: .none)
    }

    // MARK: - Streaming

    private func streamRead(
        item: SourceItem,
        requestedRange: ByteRange?,
        accessToken: String?,
        authHeaderName: String,
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
        var responseReceived = false

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
            if let token = accessToken {
                request.setValue(token, forHTTPHeaderField: authHeaderName)
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
                        responseReceived = true
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

                // A clean end is only complete for an open-ended read. A known
                // upper bound that was not reached means the connection closed
                // early, so reconnect from the current offset (SRC-10).
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
                guard responseReceived || attempts < configuration.maxReconnects
                else {
                    continuation.finish(
                        throwing: SourceAdapterError.transport(
                            error.localizedDescription
                        )
                    )
                    return
                }

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

    private func mapResponse(
        _ response: HTTPURLResponse,
        requested: ByteRange,
        currentOffset: Int64
    ) throws -> ResponseMapping {
        let status = response.statusCode

        switch status {
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
            return ResponseMapping(
                streamStart: contentRange.start,
                skip: 0,
                totalSize: contentRange.total
            )

        case 200:
            // The server ignored the Range header. Skip forward to the
            // requested offset rather than failing the read.
            return ResponseMapping(
                streamStart: 0,
                skip: requested.start,
                totalSize: response.value(
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
                "The server returned HTTP \(status)."
            )
        }
    }

    // MARK: - Metadata

    private struct HeadInfo {
        var size: Int64?
        var modifiedAt: Date?
        var etag: String?
    }

    private func headInfo(_ url: URL) async throws -> HeadInfo {
        var request = URLRequest(
            url: url,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "HEAD"

        let response: HTTPURLResponse
        do {
            response = try await client.response(for: request)
        } catch let error as HTTPStreamError where error == .cancelled {
            throw SourceAdapterError.cancelled
        } catch {
            throw SourceAdapterError.transport(error.localizedDescription)
        }

        switch response.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw SourceAdapterError.unauthorized
        case 404:
            throw SourceAdapterError.notFound(url.absoluteString)
        case 405, 501:
            // Some servers do not implement HEAD; enumeration still works
            // without size or validators.
            return HeadInfo()
        default:
            throw SourceAdapterError.transport(
                "The server returned HTTP \(response.statusCode)."
            )
        }

        let size = response.value(forHTTPHeaderField: "Content-Length")
            .flatMap(Int64.init)
        let modifiedAt = response.value(
            forHTTPHeaderField: "Last-Modified"
        ).flatMap(Self.parseHTTPDate)
        let etag = response.value(forHTTPHeaderField: "ETag")

        return HeadInfo(size: size, modifiedAt: modifiedAt, etag: etag)
    }

    private func resolveTarget(_ url: URL) async throws -> URL {
        guard StrmParser.isStrmFile(url) else {
            return url
        }

        var request = URLRequest(
            url: url,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "GET"

        let response: HTTPURLResponse
        let data: Data
        do {
            (response, data) = try await client.fetch(
                request,
                byteLimit: configuration.maxStrmBytes
            )
        } catch let error as SourceAdapterError {
            throw error
        } catch let error as HTTPStreamError where error == .cancelled {
            throw SourceAdapterError.cancelled
        } catch {
            throw SourceAdapterError.transport(error.localizedDescription)
        }

        switch response.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw SourceAdapterError.unauthorized
        case 404:
            throw SourceAdapterError.notFound(url.absoluteString)
        default:
            throw SourceAdapterError.transport(
                "The .strm file returned HTTP \(response.statusCode)."
            )
        }

        do {
            return try strmParser.parse(data: data, relativeTo: url)
        } catch {
            throw SourceAdapterError.invalidConfiguration(
                error.localizedDescription
            )
        }
    }

    private static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
