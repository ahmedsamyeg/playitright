import Foundation

/// A queued watch-state write for a Plex server.
///
/// Entries live in memory only. They are never persisted because they contain
/// an access token, and Plex progress reports are best-effort (SRC-6).
public struct PlexWatchStateEntry: Sendable, Equatable {
    public var serverURL: URL
    public var token: String?
    public var itemID: String
    public var state: SourceWatchState

    /// How many attempts have failed so far.
    public var attempts: Int

    public init(
        serverURL: URL,
        token: String?,
        itemID: String,
        state: SourceWatchState,
        attempts: Int = 0
    ) {
        self.serverURL = serverURL
        self.token = token
        self.itemID = itemID
        self.state = state
        self.attempts = attempts
    }
}

/// In-memory retry queue for Plex watch-state reports.
///
/// Each ``flush()`` makes one attempt per pending entry, so callers stay
/// responsive while offline. Failed entries are retried on a later flush and
/// dropped after ``maxAttempts`` failures.
public actor PlexWatchStateQueue {
    private var entries: [PlexWatchStateEntry] = []
    private let maxAttempts: Int
    private let configuration: PlexConfiguration
    private let session: URLSession
    private let apiFactory: (@Sendable (URL, String?) -> PlexAPI)?

    public init(
        configuration: PlexConfiguration = PlexConfiguration(),
        maxAttempts: Int = 4,
        session: URLSession = .shared
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.configuration = configuration
        self.session = session
        self.apiFactory = nil
    }

    /// Creates a queue with a custom client factory, used by tests.
    public init(
        maxAttempts: Int = 4,
        apiFactory: @escaping @Sendable (URL, String?) -> PlexAPI
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.configuration = PlexConfiguration()
        self.session = .shared
        self.apiFactory = apiFactory
    }

    /// Number of writes still waiting to be delivered.
    public var pendingCount: Int {
        entries.count
    }

    /// Pending writes in insertion order.
    public var pending: [PlexWatchStateEntry] {
        entries
    }

    /// Adds a write to the queue and attempts one delivery.
    @discardableResult
    public func enqueue(
        serverURL: URL,
        token: String?,
        itemID: String,
        state: SourceWatchState
    ) async -> Int {
        entries.append(
            PlexWatchStateEntry(
                serverURL: serverURL,
                token: token,
                itemID: itemID,
                state: state
            )
        )
        await flush()
        return entries.count
    }

    /// Attempts every pending write once.
    @discardableResult
    public func flush() async -> Int {
        guard !entries.isEmpty else {
            return 0
        }

        let current = entries
        entries.removeAll(keepingCapacity: true)
        var remaining: [PlexWatchStateEntry] = []

        for var entry in current {
            if Task.isCancelled {
                remaining.append(entry)
                continue
            }

            do {
                let api = apiFactory?(entry.serverURL, entry.token)
                    ?? PlexAPI(
                        baseURL: entry.serverURL,
                        token: entry.token,
                        configuration: configuration,
                        session: session
                    )
                try await api.reportProgress(
                    itemID: entry.itemID,
                    state: entry.state
                )
            } catch {
                entry.attempts += 1
                if entry.attempts < maxAttempts {
                    remaining.append(entry)
                }
            }
        }

        entries.append(contentsOf: remaining)
        return entries.count
    }

    /// Drops every pending write.
    public func removeAll() {
        entries.removeAll()
    }
}

/// Plex Media Server source adapter.
///
/// Authentication uses the Plex TV PIN flow. The resulting token is resolved
/// from the Keychain through ``TokenProvider`` and kept in the in-memory
/// ``SourceSession`` only. Enumeration uses the server's library sections, and
/// reads delegate to ``HTTPSourceAdapter`` with the `X-Plex-Token` header
/// (SRC-1, SRC-2, SRC-3).
public final class PlexSourceAdapter: SourceAdapter, @unchecked Sendable {
    /// Resolves the Plex token for a configured source. Tokens belong in the
    /// Keychain and never in ``SourceConfig`` (SRC-3).
    public typealias TokenProvider = @Sendable (SourceConfig) -> String?

    public let kind: SourceKind = .plex
    public let configuration: PlexConfiguration

    /// Queue shared by the adapter and available to the app for retries.
    public let watchStateQueue: PlexWatchStateQueue

    private let sessionConfiguration: URLSessionConfiguration
    private let urlSession: URLSession
    private let tokenProvider: TokenProvider?
    private let httpAdapter: HTTPSourceAdapter

    public init(
        configuration: PlexConfiguration = PlexConfiguration(),
        sessionConfiguration: URLSessionConfiguration? = nil,
        tokenProvider: TokenProvider? = nil,
        watchStateQueue: PlexWatchStateQueue? = nil,
        httpConfiguration: HTTPSourceConfiguration? = nil
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider

        let sessionConfiguration = sessionConfiguration
            ?? URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = configuration
            .requestTimeout
        sessionConfiguration.urlCache = nil

        self.sessionConfiguration = sessionConfiguration
        self.urlSession = URLSession(configuration: sessionConfiguration)

        var httpConfiguration = httpConfiguration ?? HTTPSourceConfiguration()
        httpConfiguration.allowsSelfSignedCertificates = configuration
            .allowsSelfSignedCertificates
        self.httpAdapter = HTTPSourceAdapter(
            configuration: httpConfiguration,
            sessionConfiguration: sessionConfiguration
        )

        self.watchStateQueue = watchStateQueue ?? PlexWatchStateQueue(
            configuration: configuration,
            session: urlSession
        )
    }

    // MARK: - Connect

    public func connect(config: SourceConfig) async throws -> SourceSession {
        guard let endpoint = config.endpoint else {
            throw SourceAdapterError.invalidConfiguration(
                "A Plex source needs a server URL."
            )
        }

        guard let token = tokenProvider?(config), !token.isEmpty else {
            throw SourceAdapterError.reauthenticationRequired
        }

        let api = makeAPI(endpoint: endpoint, token: token, config: config)
        do {
            let sections = try await api.sections()
            let videoSections = sections.filter { $0.type.isVideo }

            var metadata = [
                "endpoint": endpoint.absoluteString,
                "server": endpoint.host ?? endpoint.absoluteString,
                "sectionKeys": videoSections.map(\.key).joined(separator: ",")
            ]
            if let version = config.options["serverVersion"] {
                metadata["serverVersion"] = version
            }

            return SourceSession(
                sourceID: config.id,
                capabilities: [
                    .rangeRequests,
                    .watchStatePush,
                    .changePush,
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

        let sectionKeys: [String]
        if let libraryID = scope.libraryID, !libraryID.isEmpty {
            sectionKeys = [libraryID]
        } else if !scope.path.isEmpty {
            sectionKeys = [scope.path]
        } else if let stored = session.metadata["sectionKeys"], !stored.isEmpty {
            sectionKeys = stored.split(separator: ",").map(String.init)
        } else {
            do {
                sectionKeys = try await api.sections()
                    .filter { $0.type.isVideo }
                    .map(\.key)
            } catch {
                throw map(error)
            }
        }

        let includeGlobs = scope.includeGlobs
        let excludeGlobs = scope.excludeGlobs
        let sourceID = session.sourceID

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for key in sectionKeys {
                        try Task.checkCancellation()
                        let media = try await api.allItems(inSection: key)

                        for entry in media {
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
        streamSession.metadata["authHeaderName"] = "X-Plex-Token"
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
        guard let endpoint = URL(
            string: session.metadata["endpoint"] ?? ""
        ) else {
            throw SourceAdapterError.invalidConfiguration(
                "The Plex session has no server URL."
            )
        }

        await watchStateQueue.enqueue(
            serverURL: endpoint,
            token: session.accessToken,
            itemID: item.id,
            state: state
        )
    }

    /// Retries any watch-state writes that failed earlier.
    @discardableResult
    public func flushWatchState() async -> Int {
        await watchStateQueue.flush()
    }

    // MARK: - Freshness

    public func freshness(session: SourceSession) async throws
        -> FreshnessInfo {
        let endpoint: URL
        do {
            endpoint = try serverURL(for: session)
        } catch {
            throw error
        }

        let api = makeAPI(
            endpoint: endpoint,
            token: session.accessToken
        )

        do {
            let sections = try await api.sections()
            let latest = sections.compactMap(\.updatedAt).max()
            return FreshnessInfo(
                strategy: latest == nil ? .none : .modificationTime,
                lastModified: latest,
                nextCheckAfter: 300
            )
        } catch {
            throw map(error)
        }
    }

    // MARK: - Direct play

    /// The direct-play preference for a Plex item, used by the playback
    /// planner (SRC-4).
    public func playbackPreference(
        for item: PlexMediaItem
    ) -> PlexPlaybackPreference {
        item.partKey == nil ? .transcode : .directPlay
    }

    // MARK: - Helpers

    private func makeAPI(
        endpoint: URL,
        token: String?,
        config: SourceConfig? = nil
    ) -> PlexAPI {
        var configuration = self.configuration
        if let clientIdentifier = config?.options["clientIdentifier"],
           !clientIdentifier.isEmpty {
            configuration.clientIdentifier = clientIdentifier
        }
        return PlexAPI(
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
                "The Plex session has no server URL."
            )
        }
        return url
    }

    private func makeItem(
        _ media: PlexMediaItem,
        api: PlexAPI,
        sourceID: UUID
    ) -> SourceItem {
        let location = api.streamURL(for: media)?.absoluteString
            ?? media.key
            ?? "/library/metadata/\(media.ratingKey)"

        return SourceItem(
            id: media.ratingKey,
            sourceID: sourceID,
            kind: sourceItemKind(media.type),
            name: media.title,
            location: location,
            parentID: media.parentRatingKey,
            sizeBytes: media.partSize,
            modifiedAt: media.updatedAt,
            etag: media.updatedAt.map {
                String(Int64($0.timeIntervalSince1970))
            },
            container: media.container,
            durationSeconds: media.durationSeconds,
            providerIDs: media.providerIDs
        )
    }

    private func sourceItemKind(
        _ type: PlexMediaType
    ) -> SourceItemKind {
        switch type {
        case .movie:
            return .movie
        case .show:
            return .show
        case .season:
            return .season
        case .episode:
            return .episode
        case .clip:
            return .movie
        case .unknown:
            return .unknown
        }
    }

    /// Maps Plex failures onto the shared adapter errors.
    func map(_ error: Error) -> SourceAdapterError {
        if let error = error as? SourceAdapterError {
            return error
        }
        guard let plexError = error as? PlexError else {
            return .transport(error.localizedDescription)
        }

        switch plexError {
        case .missingBaseURL:
            return .invalidConfiguration("A Plex server URL is required.")
        case .missingToken:
            return .reauthenticationRequired
        case .invalidURL(let value):
            return .invalidConfiguration(value)
        case .invalidResponse:
            return .protocolViolation("Plex returned a non-HTTP response.")
        case .unauthorized:
            return .unauthorized
        case .notFound(let value):
            return .notFound(value)
        case .pinExpired:
            return .reauthenticationRequired
        case .httpStatus(let status, let message):
            if status == 401 || status == 403 {
                return .unauthorized
            }
            let detail = message.map { ": \($0)" } ?? ""
            return .transport("Plex returned HTTP \(status)\(detail)")
        case .decoding(let message):
            return .protocolViolation(message)
        case .transport(let message):
            return .transport(message)
        }
    }
}
