import Foundation

/// Configuration for the shared Jellyfin/Emby client.
public struct JellyfinConfiguration: Sendable, Equatable {
    public var requestTimeout: TimeInterval
    public var pageSize: Int
    public var clientName: String
    public var clientVersion: String
    public var deviceName: String
    public var deviceID: String

    public init(
        requestTimeout: TimeInterval = 30,
        pageSize: Int = 200,
        clientName: String = "PlayItRight",
        clientVersion: String = "1.0",
        deviceName: String = "Apple TV",
        deviceID: String = "PlayItRight-tvOS"
    ) {
        self.requestTimeout = max(1, requestTimeout)
        self.pageSize = max(1, pageSize)
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.deviceName = deviceName
        self.deviceID = deviceID
    }
}

/// REST client shared by Jellyfin and Emby.
///
/// Both products expose the same API surface and use the `X-Emby-Token`
/// header. The client never persists the token; callers resolve it from the
/// Keychain (SRC-3).
public struct JellyfinAPI: Sendable {
    public let baseURL: URL
    public let token: String?
    public let configuration: JellyfinConfiguration

    private let session: URLSession

    public init(
        baseURL: URL,
        token: String?,
        configuration: JellyfinConfiguration = JellyfinConfiguration(),
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.token = token
        self.configuration = configuration
        self.session = session
    }

    // MARK: - Discovery

    /// Fetches `/System/Info/Public` to identify the server product.
    public func systemInfo() async throws -> JellyfinSystemInfo {
        let url = try serverURL(path: "System/Info/Public")
        let (data, _) = try await perform(url: url, accept: "application/json")
        return try decode(data)
    }

    // MARK: - Enumeration

    /// Fetches one page of items.
    ///
    /// Passing the previous `ETag` as `ifNoneMatch` makes the server answer
    /// `304 Not Modified` when nothing changed (SRC-20).
    public func items(
        parentID: String? = nil,
        includeItemTypes: [String] = ["Movie", "Episode"],
        recursive: Bool = true,
        startIndex: Int = 0,
        limit: Int? = nil,
        ifNoneMatch: String? = nil
    ) async throws -> JellyfinItemsResult {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "Recursive", value: recursive ? "true" : "false"),
            URLQueryItem(
                name: "IncludeItemTypes",
                value: includeItemTypes.joined(separator: ",")
            ),
            URLQueryItem(
                name: "Fields",
                value: "ProviderIds,MediaSources,DateCreated,Path"
            ),
            URLQueryItem(
                name: "StartIndex",
                value: String(max(0, startIndex))
            ),
            URLQueryItem(
                name: "Limit",
                value: String(max(1, limit ?? configuration.pageSize))
            )
        ]
        if let parentID, !parentID.isEmpty {
            query.append(URLQueryItem(name: "ParentId", value: parentID))
        }

        let url = try serverURL(path: "Items", query: query)
        let (data, response) = try await perform(
            url: url,
            accept: "application/json",
            ifNoneMatch: ifNoneMatch
        )

        let etag = response.value(forHTTPHeaderField: "ETag")
        let lastModified = response.value(
            forHTTPHeaderField: "Last-Modified"
        ).flatMap(Self.parseHTTPDate)

        if response.statusCode == 304 {
            return JellyfinItemsResult(
                page: JellyfinItemsPage(),
                etag: etag ?? ifNoneMatch,
                notModified: true,
                lastModified: lastModified
            )
        }

        return JellyfinItemsResult(
            page: try decode(data),
            etag: etag,
            notModified: false,
            lastModified: lastModified
        )
    }

    /// Fetches every page for a parent.
    public func allItems(
        parentID: String? = nil,
        includeItemTypes: [String] = ["Movie", "Episode"],
        recursive: Bool = true
    ) async throws -> [JellyfinItem] {
        var result: [JellyfinItem] = []
        var start = 0

        while true {
            let page = try await items(
                parentID: parentID,
                includeItemTypes: includeItemTypes,
                recursive: recursive,
                startIndex: start,
                limit: configuration.pageSize
            )
            result.append(contentsOf: page.page.items)

            if page.page.items.isEmpty
                || page.page.items.count < configuration.pageSize
                || result.count >= page.page.totalRecordCount {
                break
            }
            start += page.page.items.count
        }

        return result
    }

    // MARK: - Playback

    /// Builds a direct static stream URL for an item.
    ///
    /// The URL deliberately omits the token. Reads send `X-Emby-Token` as a
    /// header instead (SRC-3).
    public func streamURL(for item: JellyfinItem) -> URL? {
        guard let url = URL(
            string: "Videos/\(item.id)/stream",
            relativeTo: baseURL
        )?.absoluteURL, var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        var query = [URLQueryItem(name: "static", value: "true")]
        if let mediaSourceID = item.mediaSources.first?.id,
           !mediaSourceID.isEmpty {
            query.append(
                URLQueryItem(name: "MediaSourceId", value: mediaSourceID)
            )
        }
        components.queryItems = query
        return components.url
    }

    // MARK: - Watch state

    /// Posts a progress update to `/Sessions/Playing/Progress`.
    public func reportProgress(
        itemID: String,
        state: SourceWatchState
    ) async throws {
        let report = JellyfinProgressReport(itemID: itemID, state: state)
        let body = try JSONEncoder().encode(report)
        let url = try serverURL(path: "Sessions/Playing/Progress")
        _ = try await perform(
            url: url,
            method: "POST",
            accept: "application/json",
            contentType: "application/json",
            body: body
        )
    }

    /// Marks an item as played.
    public func markPlayed(itemID: String) async throws {
        let url = try serverURL(path: "Items/\(itemID)/Played")
        _ = try await perform(
            url: url,
            method: "POST",
            accept: "application/json"
        )
    }

    // MARK: - HTTP

    private func serverURL(
        path: String,
        query: [URLQueryItem] = []
    ) throws -> URL {
        let trimmed = path.hasPrefix("/")
            ? String(path.dropFirst())
            : path
        let url = baseURL.appendingPathComponent(trimmed)
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw JellyfinError.invalidURL(url.absoluteString)
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let result = components.url else {
            throw JellyfinError.invalidURL(url.absoluteString)
        }
        return result
    }

    private func perform(
        url: URL,
        method: String = "GET",
        accept: String,
        contentType: String? = nil,
        body: Data? = nil,
        ifNoneMatch: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(
            url: url,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = method
        request.httpBody = body
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let ifNoneMatch, !ifNoneMatch.isEmpty {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        request.setValue(
            configuration.clientName,
            forHTTPHeaderField: "X-Emby-Client"
        )
        request.setValue(
            configuration.clientVersion,
            forHTTPHeaderField: "X-Emby-Client-Version"
        )
        request.setValue(
            configuration.deviceName,
            forHTTPHeaderField: "X-Emby-Device-Name"
        )
        request.setValue(
            configuration.deviceID,
            forHTTPHeaderField: "X-Emby-Device-Id"
        )
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            request.setValue(
                "MediaBrowser Token=\"\(token)\"",
                forHTTPHeaderField: "Authorization"
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JellyfinError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }

        switch http.statusCode {
        case 200..<300, 304:
            return (data, http)
        case 401, 403:
            throw JellyfinError.unauthorized
        case 404:
            throw JellyfinError.notFound(url.path)
        default:
            throw JellyfinError.httpStatus(
                http.statusCode,
                message: String(data: data.prefix(512), encoding: .utf8)
            )
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.parseISO8601(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date '\(value)'."
            )
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw JellyfinError.decoding(String(describing: error))
        }
    }

    static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func parseHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
