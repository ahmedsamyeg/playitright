import Foundation

/// HTTP client implementing ETag conditional GET and response caching (SRC-5).
public actor ETagCacheClient {

    public struct CachedResponse: Equatable, Sendable {
        public let etag: String
        public let data: Data
        public let timestamp: Date
    }

    public enum FetchResult: Equatable, Sendable {
        case modified(data: Data, etag: String)
        case notModified(cachedData: Data)
    }

    public typealias HTTPRequestHandler = @Sendable (URL, String?) async throws -> (statusCode: Int, data: Data, etag: String?)

    private let httpHandler: HTTPRequestHandler
    private var cache: [URL: CachedResponse] = [:]

    public init(httpHandler: @escaping HTTPRequestHandler) {
        self.httpHandler = httpHandler
    }

    /// Fetches a URL conditionally using `If-None-Match: <etag>`.
    public func fetch(url: URL) async throws -> FetchResult {
        let currentEtag = cache[url]?.etag
        let response = try await httpHandler(url, currentEtag)

        if response.statusCode == 304, let cached = cache[url] {
            return .notModified(cachedData: cached.data)
        }

        if response.statusCode == 200 {
            if let newEtag = response.etag {
                cache[url] = CachedResponse(etag: newEtag, data: response.data, timestamp: Date())
                return .modified(data: response.data, etag: newEtag)
            } else {
                return .modified(data: response.data, etag: "")
            }
        }

        throw NSError(domain: "ETagCacheClient", code: response.statusCode, userInfo: nil)
    }

    public func cachedEntry(for url: URL) -> CachedResponse? {
        return cache[url]
    }
}
