import Foundation

/// Shared Jellyfin/Emby source adapter.
///
/// Jellyfin and Emby expose the same REST API, so the adapters differ only in
/// the product they expect and the `SourceKind` they report. Reads delegate to
/// ``HTTPSourceAdapter`` with an `X-Emby-Token` header so the ranged streaming
/// and reconnect logic is shared (SRC-1, SRC-2).
public class JellyfinSourceAdapter: SourceAdapter, @unchecked Sendable {
    /// Resolves the server token from the Keychain (SRC-3).
    public typealias TokenProvider = @Sendable (SourceConfig) -> String?

    public let brand: MediaServerBrand
    public let configuration: JellyfinConfiguration

    public var kind: SourceKind {
        brand == .emby ? .emby : .jellyfin
    }

    private let urlSession: URLSession
    private let tokenProvider: TokenProvider?
    private let httpAdapter: HTTPSourceAdapter

    public init(
        brand: MediaServerBrand,
        configuration: JellyfinConfiguration = JellyfinConfiguration(),
        sessionConfiguration: URLSessionConfiguration? = nil,
        tokenProvider: TokenProvider? = nil,
        httpConfiguration: HTTPSourceConfiguration? = nil
    ) {
        self.brand = brand
        self.configuration = configuration
        self.tokenProvider = tokenProvider

        let sessionConfiguration = sessionConfiguration
            ?? URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration
            .requestTimeout
        sessionConfiguration.urlCache = nil

        self.urlSession = URLSession(configuration: sessionConfiguration)
        self.httpAdapter = HTTPSourceAdapter(
            configuration: httpConfiguration ?? HTTPSourceConfiguration(),
            sessionConfiguration: sessionConfiguration
        )
    }

    // MARK: - Connect

    public func connect(config: SourceConfig) async throws -> SourceSession {
        guard let endpoint = config.endpoint else {
            throw SourceAdapterError.invalidConfiguration(
                "A media server source needs a server URL."
            )
        }

        guard let token = tokenProvider?(config), !token.isEmpty else {
            throw SourceAdapterError.reauthenticationRequired
        }

        let api = makeAPI(endpoint: endpoint, token: token)
        do {
            let info = try await api.systemInfo()
            let detected = MediaServerBrand.detect(
                productName: info.productName,
                serverName: info.serverName
            )

            var metadata = [
                "endpoint": endpoint.absoluteString,
                "detectedBrand": detected.rawValue
            ]
            if let value = info.serverName {
                metadata["serverName"] = value
            }
            if let value = info.version {
                metadata["serverVersion"] = value
            }
            if let value = info.id {
                metadata["serverID"] = value
            }

            return SourceSession(
                sourceID: config.id,
                capabilities: [
                    .rangeRequests,
                    .watchStatePush,
                    .changePush,
                    .etagFreshness,
                    .modificationTimeFreshness,
                    .recursiveEnumeration,
                    .directPlay
                ],
                accessToken: token,
                metadata: metadata
            )
        } catch {
            throw map(error)
        }
    }

    // MARK: - Enumerate

    public func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        let endpoint = try serverURL(for: session)
        let api = makeAPI(
            endpoint: endpoint,
            token: session.accessToken
        )

        let parentID: String?
        if let libraryID = scope.libraryID, !libraryID.isEmpty {
            parentID = libraryID
        } else if !scope.path.isEmpty {
            parentID = scope.path
        } else {
            parentID = session.metadata["libraryID"]
        }

        let includeTypes = scope.recursive
            ? ["Movie", "Episode"]
            : ["Movie", "Series"]
        let includeGlobs = scope.includeGlobs
        let excludeGlobs = scope.excludeGlobs
        let sourceID = session.sourceID

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let items = try await api.allItems(
                        parentID: parentID,
                        includeItemTypes: includeTypes,
                        recursive: scope.recursive
                    )

                    for entry in items {
                        try Task.checkCancellation()
                        let item = self.makeItem(
                            entry,
                            api: api,
                            sourceID: sourceID
                        )

                        let path = URL(string: item.location)?.path
                            ?? item.location
                        guard SourceGlob.allows(
                            name: item.name,
                            path: path,
                            include: includeGlobs,
                            exclude: excludeGlobs
                        ) else {
                            continue
                        }
                        continuation.yield(item)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(
                        throwing: SourceAdapterError.cancelled
                    )
                } catch let error as SourceAdapterError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: self.map(error))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Read

    public func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error> {
        var streamSession = session
        streamSession.metadata["authHeaderName"] = "X-Emby-Token"
        return httpAdapter.read(
            session: streamSession,
            item: item,
            range: range
        )
    }

    // MARK: - Watch state

    public func pushWatchState(
        session: SourceSession,
        item: SourceItem,
        state: SourceWatchState
    ) async throws {
        let endpoint = try serverURL(for: session)
        let api = makeAPI(
            endpoint: endpoint,
            token: session.accessToken
        )

        do {
            if state.isWatched {
                try await api.markPlayed(itemID: item.id)
            } else {
                try await api.reportProgress(
                    itemID: item.id,
                    state: state
                )
            }
        } catch {
            throw map(error)
        }
    }

    // MARK: - Freshness

    public func freshness(session: SourceSession) async throws
        -> FreshnessInfo {
        let endpoint = try serverURL(for: session)
        let api = makeAPI(
            endpoint: endpoint,
            token: session.accessToken
        )
        let previousETag = session.metadata["etag"]

        do {
            let result = try await api.items(
                parentID: session.metadata["libraryID"],
                includeItemTypes: ["Movie", "Episode"],
                recursive: true,
                startIndex: 0,
                limit: 1,
                ifNoneMatch: previousETag
            )

            if result.notModified {
                return FreshnessInfo(
                    strategy: .etag,
                    token: result.etag ?? previousETag,
                    lastModified: result.lastModified,
                    hasChanges: false
                )
            }

            if let etag = result.etag {
                return FreshnessInfo(
                    strategy: .etag,
                    token: etag,
                    lastModified: result.lastModified,
                    hasChanges: true
                )
            }
            if let lastModified = result.lastModified {
                return FreshnessInfo(
                    strategy: .modificationTime,
                    lastModified: lastModified,
                    hasChanges: true
                )
            }
            return FreshnessInfo(strategy: .none, hasChanges: true)
        } catch {
            throw map(error)
        }
    }

    // MARK: - Helpers

    private func makeAPI(
        endpoint: URL,
        token: String?
    ) -> JellyfinAPI {
        JellyfinAPI(
            baseURL: endpoint,
            token: token,
            configuration: configuration,
            session: urlSession
        )
    }

    private func serverURL(for session: SourceSession) throws -> URL {
        guard let raw = session.metadata["endpoint"],
              let url = URL(string: raw) else {
            throw SourceAdapterError.invalidConfiguration(
                "The media server session has no server URL."
            )
        }
        return url
    }

    private func makeItem(
        _ entry: JellyfinItem,
        api: JellyfinAPI,
        sourceID: UUID
    ) -> SourceItem {
        let itemKind = sourceItemKind(entry.type)
        let location: String
        if itemKind == .movie || itemKind == .episode,
           let stream = api.streamURL(for: entry) {
            location = stream.absoluteString
        } else {
            location = api.baseURL
                .appendingPathComponent("Items/\(entry.id)")
                .absoluteString
        }

        let mediaSource = entry.mediaSources.first
        let providerIDs = Dictionary(
            uniqueKeysWithValues: entry.providerIDs.map {
                ($0.key.lowercased(), $0.value)
            }
        )

        return SourceItem(
            id: entry.id,
            sourceID: sourceID,
            kind: itemKind,
            name: entry.name,
            location: location,
            parentID: entry.parentID,
            sizeBytes: mediaSource?.size,
            modifiedAt: entry.dateCreated,
            etag: entry.etag,
            container: entry.container ?? mediaSource?.container,
            durationSeconds: entry.durationSeconds,
            providerIDs: providerIDs
        )
    }

    private func sourceItemKind(_ type: String) -> SourceItemKind {
        switch type.lowercased() {
        case "movie":
            return .movie
        case "series":
            return .show
        case "season":
            return .season
        case "episode":
            return .episode
        case "folder", "collectionfolder":
            return .folder
        default:
            return .unknown
        }
    }

    /// Maps media-server failures onto shared adapter errors.
    func map(_ error: Error) -> SourceAdapterError {
        if let error = error as? SourceAdapterError {
            return error
        }
        guard let serverError = error as? JellyfinError else {
            return .transport(error.localizedDescription)
        }

        switch serverError {
        case .invalidURL(let value):
            return .invalidConfiguration(value)
        case .invalidResponse:
            return .protocolViolation(
                "The media server returned a non-HTTP response."
            )
        case .unauthorized:
            return .unauthorized
        case .notFound(let value):
            return .notFound(value)
        case .httpStatus(let status, let message):
            if status == 401 || status == 403 {
                return .unauthorized
            }
            let detail = message.map { ": \($0)" } ?? ""
            return .transport(
                "The media server returned HTTP \(status)\(detail)"
            )
        case .decoding(let message):
            return .protocolViolation(message)
        case .transport(let message):
            return .transport(message)
        }
    }
}
