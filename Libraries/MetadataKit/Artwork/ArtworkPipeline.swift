import Foundation

/// Settings for ``ArtworkPipeline``.
public struct ArtworkPipelineConfiguration: Sendable, Equatable {
    /// Disk cache settings.
    public var cache: ArtworkCacheConfiguration

    /// Memory-cache cap for decoded artwork bytes. Keeps the grid within the
    /// 100 MB budget from NFR-3.
    public var memoryByteLimit: Int

    /// Per-request URL session timeout.
    public var requestTimeout: TimeInterval

    public init(
        cache: ArtworkCacheConfiguration = ArtworkCacheConfiguration(),
        memoryByteLimit: Int = 100 * 1024 * 1024,
        requestTimeout: TimeInterval = 30
    ) {
        self.cache = cache
        self.memoryByteLimit = max(0, memoryByteLimit)
        self.requestTimeout = max(1, requestTimeout)
    }
}

/// Errors raised while downloading artwork.
public enum ArtworkPipelineError: Error, Sendable, Equatable, LocalizedError {
    /// The server returned a non-HTTP response.
    case invalidResponse

    /// The server returned a non-success status.
    case httpStatus(Int)

    /// The response body was empty.
    case emptyResponse

    /// The transport failed before a response was received.
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The artwork server returned a response that was not HTTP."
        case .httpStatus(let status):
            return "The artwork server returned HTTP \(status)."
        case .emptyResponse:
            return "The artwork server returned an empty body."
        case .transport(let message):
            return "Artwork download failed: \(message)"
        }
    }
}

/// Downloads, caches, and coalesces artwork requests.
///
/// The pipeline keeps a small byte-bounded memory LRU in front of the
/// size-bounded disk LRU. Concurrent requests for the same URL share one
/// download task, so a grid full of the same poster fetches it once.
public actor ArtworkPipeline {
    public let configuration: ArtworkPipelineConfiguration
    public let cache: ArtworkCache

    private let session: URLSession
    private var inFlight: [String: Task<Data, Error>] = [:]

    private var memory: [String: Data] = [:]
    private var memoryOrder: [String] = []
    private var memoryBytes = 0

    public init(
        configuration: ArtworkPipelineConfiguration = ArtworkPipelineConfiguration(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.cache = ArtworkCache(configuration: configuration.cache)
        self.session = session
    }

    /// Returns artwork bytes, reading memory, then disk, then the network.
    public func data(for url: URL) async throws -> Data {
        let key = ArtworkCache.key(for: url)

        if let cached = memory[key] {
            promoteMemory(key)
            return cached
        }

        if let cached = try await cache.data(forKey: key) {
            insertMemory(cached, forKey: key)
            return cached
        }

        if let task = inFlight[key] {
            return try await task.value
        }

        let cache = self.cache
        let session = self.session
        let timeout = configuration.requestTimeout
        let task = Task.detached(priority: nil) {
            let data = try await Self.download(
                url: url,
                session: session,
                timeout: timeout
            )
            try await cache.store(data, forKey: key)
            return data
        }
        inFlight[key] = task

        defer {
            inFlight[key] = nil
        }

        let data = try await task.value
        insertMemory(data, forKey: key)
        return data
    }

    /// Returns artwork without starting a download, checking memory then disk.
    public func cachedData(for url: URL) async -> Data? {
        let key = ArtworkCache.key(for: url)

        if let cached = memory[key] {
            promoteMemory(key)
            return cached
        }

        guard let cached = try? await cache.data(forKey: key) else {
            return nil
        }
        insertMemory(cached, forKey: key)
        return cached
    }

    /// Empties both memory and disk caches and cancels in-flight downloads.
    public func clear() async throws {
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
        memory.removeAll()
        memoryOrder.removeAll()
        memoryBytes = 0
        try await cache.clear()
    }

    /// Bytes currently held by the memory cache.
    public func memoryBytesUsed() -> Int {
        memoryBytes
    }

    /// Bytes currently held by the disk cache.
    public func diskBytesUsed() async throws -> Int64 {
        try await cache.currentSize()
    }

    // MARK: - Memory LRU

    private func insertMemory(_ data: Data, forKey key: String) {
        if let existing = memory[key] {
            memoryBytes -= existing.count
            memoryOrder.removeAll { $0 == key }
        }

        memory[key] = data
        memoryOrder.append(key)
        memoryBytes += data.count

        while memoryBytes > configuration.memoryByteLimit,
              let victim = memoryOrder.first {
            memoryOrder.removeFirst()
            if let removed = memory.removeValue(forKey: victim) {
                memoryBytes -= removed.count
            }
        }
    }

    private func promoteMemory(_ key: String) {
        guard memory[key] != nil else {
            return
        }
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }

    // MARK: - Download

    private nonisolated static func download(
        url: URL,
        session: URLSession,
        timeout: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ArtworkPipelineError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ArtworkPipelineError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ArtworkPipelineError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else {
            throw ArtworkPipelineError.emptyResponse
        }

        return data
    }
}
