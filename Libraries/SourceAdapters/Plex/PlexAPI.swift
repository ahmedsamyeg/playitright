import Foundation

/// Configuration for the Plex client.
public struct PlexConfiguration: Sendable, Equatable {
    /// Plex's account/linking service.
    public var plexTVBaseURL: URL

    /// Product name sent with account requests.
    public var product: String

    /// Stable per-install identifier required by the PIN flow.
    public var clientIdentifier: String

    /// Client version sent with account requests.
    public var version: String

    /// Per-request timeout.
    public var requestTimeout: TimeInterval

    /// Opt-in for self-signed certificates (NFR-8).
    public var allowsSelfSignedCertificates: Bool

    /// Page size used while enumerating a section.
    public var pageSize: Int

    public init(
        plexTVBaseURL: URL = URL(string: "https://plex.tv")!,
        product: String = "PlayItRight",
        clientIdentifier: String = "PlayItRight-tvOS",
        version: String = "1.0",
        requestTimeout: TimeInterval = 30,
        allowsSelfSignedCertificates: Bool = false,
        pageSize: Int = 200
    ) {
        self.plexTVBaseURL = plexTVBaseURL
        self.product = product
        self.clientIdentifier = clientIdentifier
        self.version = version
        self.requestTimeout = max(1, requestTimeout)
        self.allowsSelfSignedCertificates = allowsSelfSignedCertificates
        self.pageSize = max(1, pageSize)
    }
}

/// Errors raised by ``PlexAPI``.
public enum PlexError: Error, Sendable, Equatable, LocalizedError {
    case missingBaseURL
    case missingToken
    case invalidURL(String)
    case invalidResponse
    case unauthorized
    case notFound(String)
    case pinExpired
    case httpStatus(Int, message: String?)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "A Plex server URL is required."
        case .missingToken:
            return "A Plex token is required."
        case .invalidURL(let value):
            return "Could not build a Plex request URL for '\(value)'."
        case .invalidResponse:
            return "Plex returned a response that was not HTTP."
        case .unauthorized:
            return "Plex rejected the token. Sign in again."
        case .notFound(let value):
            return "Plex did not find '\(value)'."
        case .pinExpired:
            return "The Plex linking code expired before it was approved."
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                return "Plex returned HTTP \(status): \(message)"
            }
            return "Plex returned HTTP \(status)."
        case .decoding(let message):
            return "Could not decode the Plex response: \(message)"
        case .transport(let message):
            return "Plex request failed: \(message)"
        }
    }
}

/// Async client for a Plex Media Server plus the Plex TV linking service.
public struct PlexAPI: Sendable {
    public let baseURL: URL
    public let token: String?
    public let configuration: PlexConfiguration

    private let session: URLSession

    public init(
        baseURL: URL,
        token: String?,
        configuration: PlexConfiguration = PlexConfiguration(),
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.token = token
        self.configuration = configuration
        self.session = session
    }

    // MARK: - PIN linking

    /// Creates a new TV linking PIN.
    public func requestPin() async throws -> PlexPin {
        let url = try plexTVURL(path: "api/v2/pins", query: [
            URLQueryItem(name: "strong", value: "true")
        ])
        let data = try await perform(
            url: url,
            method: "POST",
            accept: "application/json"
        )
        return try decode(data)
    }

    /// Checks whether the user approved a PIN and returns the token.
    public func checkPin(id: Int) async throws -> PlexPin {
        let url = try plexTVURL(path: "api/v2/pins/\(id)")
        let data = try await perform(
            url: url,
            method: "GET",
            accept: "application/json"
        )
        return try decode(data)
    }

    /// Polls until the PIN is linked or ``timeout`` elapses.
    public func waitForPin(
        id: Int,
        timeout: TimeInterval = 120,
        pollInterval: TimeInterval = 1,
        sleep: @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) async throws -> PlexPin {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let pin = try await checkPin(id: id)
            if pin.isLinked {
                return pin
            }
            try await sleep(pollInterval)
        }

        throw PlexError.pinExpired
    }

    // MARK: - Libraries

    /// Fetches every library section.
    public func sections() async throws -> [PlexSection] {
        let url = try serverURL(path: "library/sections")
        let data = try await perform(url: url, accept: "application/xml")
        return try PlexXMLParser().parseSections(data: data)
    }

    /// Fetches one page of items from a section.
    public func items(
        inSection key: String,
        start: Int = 0,
        size: Int? = nil
    ) async throws -> [PlexMediaItem] {
        let pageSize = size ?? configuration.pageSize
        let url = try serverURL(
            path: "library/sections/\(key)/all",
            query: [
                URLQueryItem(
                    name: "X-Plex-Container-Start",
                    value: String(max(0, start))
                ),
                URLQueryItem(
                    name: "X-Plex-Container-Size",
                    value: String(max(1, pageSize))
                )
            ]
        )
        let data = try await perform(url: url, accept: "application/xml")
        return try PlexXMLParser().parseMedia(data: data)
    }

    /// Fetches every item in a section, paging until the server returns a
    /// short page.
    public func allItems(inSection key: String) async throws
        -> [PlexMediaItem] {
        var result: [PlexMediaItem] = []
        var start = 0

        while true {
            let page = try await items(
                inSection: key,
                start: start,
                size: configuration.pageSize
            )
            result.append(contentsOf: page)
            if page.count < configuration.pageSize {
                break
            }
            start += page.count
        }

        return result
    }

    // MARK: - Playback

    /// Builds the URL for an item's original part.
    ///
    /// Pass `includeToken: true` when handing the URL to a player that cannot
    /// set the `X-Plex-Token` header. The token then appears in the query
    /// string and must not be logged or persisted.
    public func streamURL(
        for item: PlexMediaItem,
        includeToken: Bool = false
    ) -> URL? {
        let path: String
        if let partKey = item.partKey {
            path = partKey
        } else if let key = item.key {
            path = key
        } else {
            return nil
        }

        guard var components = URLComponents(
            url: URL(string: path, relativeTo: baseURL)?.absoluteURL
                ?? baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        if includeToken, let token, !token.isEmpty {
            var query = components.queryItems ?? []
            query.append(
                URLQueryItem(name: "X-Plex-Token", value: token)
            )
            components.queryItems = query
        }

        return components.url
    }

    /// Direct-play preference hint consumed by the playback planner (SRC-4).
    ///
    /// Plex items with an original part play directly. Items without a part
    /// can only be reached through the server's metadata endpoints.
    public func playbackPreference(
        for item: PlexMediaItem
    ) -> PlexPlaybackPreference {
        item.partKey == nil ? .transcode : .directPlay
    }

    // MARK: - Watch state

    /// Reports progress or completion to the server.
    public func reportProgress(
        itemID: String,
        state: SourceWatchState
    ) async throws {
        let path: String
        var query: [URLQueryItem]

        if state.isWatched {
            path = "/:/scrobble"
            query = [
                URLQueryItem(name: "key", value: itemID),
                URLQueryItem(
                    name: "identifier",
                    value: "com.plexapp.plugins.library"
                )
            ]
        } else {
            path = "/:/progress"
            query = [
                URLQueryItem(name: "key", value: itemID),
                URLQueryItem(
                    name: "time",
                    value: String(Int64(state.position * 1000))
                ),
                URLQueryItem(
                    name: "state",
                    value: state.position > 0 ? "playing" : "stopped"
                ),
                URLQueryItem(
                    name: "identifier",
                    value: "com.plexapp.plugins.library"
                )
            ]
            if let duration = state.duration {
                query.append(
                    URLQueryItem(
                        name: "duration",
                        value: String(Int64(duration * 1000))
                    )
                )
            }
        }

        let url = try serverURL(path: path, query: query)
        _ = try await perform(url: url, accept: "application/xml")
    }

    // MARK: - HTTP

    private func plexTVURL(
        path: String,
        query: [URLQueryItem] = []
    ) throws -> URL {
        let url = configuration.plexTVBaseURL
            .appendingPathComponent(path)
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw PlexError.invalidURL(url.absoluteString)
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let result = components.url else {
            throw PlexError.invalidURL(url.absoluteString)
        }
        return result
    }

    private func serverURL(
        path: String,
        query: [URLQueryItem] = []
    ) throws -> URL {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(string: path, relativeTo: baseURL)?.absoluteURL
                ?? baseURL.appendingPathComponent(String(path.dropFirst()))
        } else {
            url = baseURL.appendingPathComponent(path)
        }

        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw PlexError.invalidURL(url.absoluteString)
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let result = components.url else {
            throw PlexError.invalidURL(url.absoluteString)
        }
        return result
    }

    private func perform(
        url: URL,
        method: String = "GET",
        accept: String,
        body: Data? = nil
    ) async throws -> Data {
        var request = URLRequest(
            url: url,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = method
        request.httpBody = body
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(
            configuration.product,
            forHTTPHeaderField: "X-Plex-Product"
        )
        request.setValue(
            configuration.version,
            forHTTPHeaderField: "X-Plex-Version"
        )
        request.setValue(
            configuration.clientIdentifier,
            forHTTPHeaderField: "X-Plex-Client-Identifier"
        )
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PlexError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PlexError.invalidResponse
        }

        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw PlexError.unauthorized
        case 404:
            throw PlexError.notFound(url.path)
        default:
            throw PlexError.httpStatus(
                http.statusCode,
                message: String(
                    data: data.prefix(512),
                    encoding: .utf8
                )
            )
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PlexError.decoding(String(describing: error))
        }
    }
}
