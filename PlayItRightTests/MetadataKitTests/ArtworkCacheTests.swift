import Foundation
import Testing
@testable import MetadataKit

// MARK: - Test doubles

private struct ArtworkMockError: Error, Sendable {
    let message: String
}

private final class ArtworkMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) private static var storedHandler: Handler?
    private static let lock = NSLock()

    static func setHandler(_ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        storedHandler = handler
    }

    private static func handler() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return storedHandler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler() else {
            client?.urlProtocol(
                self,
                didFailWithError: ArtworkMockError(
                    message: "No handler installed"
                )
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ArtworkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

// MARK: - Helpers

private func artworkSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ArtworkMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func artworkRespond(
    to request: URLRequest,
    status: Int = 200,
    data: Data
) throws -> (HTTPURLResponse, Data) {
    guard let url = request.url,
          let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/jpeg"]
          ) else {
        throw ArtworkMockError(message: "Could not build an HTTP response")
    }
    return (response, data)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ArtworkCacheTests-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

private let artworkURL = URL(
    string: "https://image.tmdb.org/t/p/w780/poster.jpg"
)!

private let artworkBytes = Data(repeating: 0xAB, count: 256)

// MARK: - Tests

@Suite("ArtworkCache Tests", .serialized)
struct ArtworkCacheTests {
    @Test("Downloads, stores, and reuses cached artwork")
    func downloadsAndCaches() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let counter = ArtworkCounter()
        ArtworkMockURLProtocol.setHandler { request in
            _ = counter.increment()
            return try artworkRespond(to: request, data: artworkBytes)
        }

        let pipeline = ArtworkPipeline(
            configuration: ArtworkPipelineConfiguration(
                cache: ArtworkCacheConfiguration(
                    directory: directory,
                    byteLimit: 1_000_000
                )
            ),
            session: artworkSession()
        )

        let first = try await pipeline.data(for: artworkURL)
        #expect(first == artworkBytes)
        #expect(counter.value == 1)

        let key = ArtworkCache.key(for: artworkURL)
        let exists = await pipeline.cache.contains(key: key)
        #expect(exists)

        let diskBytes = try await pipeline.diskBytesUsed()
        #expect(diskBytes == Int64(artworkBytes.count))

        let second = try await pipeline.data(for: artworkURL)
        #expect(second == artworkBytes)
        #expect(counter.value == 1)

        let cached = await pipeline.cachedData(for: artworkURL)
        #expect(cached == artworkBytes)
    }

    @Test("Memory cache serves artwork after the disk entry is removed")
    func memoryCache() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let counter = ArtworkCounter()
        ArtworkMockURLProtocol.setHandler { request in
            _ = counter.increment()
            return try artworkRespond(to: request, data: artworkBytes)
        }

        let pipeline = ArtworkPipeline(
            configuration: ArtworkPipelineConfiguration(
                cache: ArtworkCacheConfiguration(
                    directory: directory,
                    byteLimit: 1_000_000
                )
            ),
            session: artworkSession()
        )

        _ = try await pipeline.data(for: artworkURL)

        let key = ArtworkCache.key(for: artworkURL)
        try await pipeline.cache.remove(key: key)

        let memoryBytes = await pipeline.memoryBytesUsed()
        #expect(memoryBytes == artworkBytes.count)

        let cached = await pipeline.cachedData(for: artworkURL)
        #expect(cached == artworkBytes)
        #expect(counter.value == 1)
    }

    @Test("Concurrent requests for one URL coalesce into one download")
    func coalescesConcurrentRequests() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let counter = ArtworkCounter()
        ArtworkMockURLProtocol.setHandler { request in
            _ = counter.increment()
            // Keep the first request in flight long enough for the second
            // caller to join it.
            Thread.sleep(forTimeInterval: 0.15)
            return try artworkRespond(to: request, data: artworkBytes)
        }

        let pipeline = ArtworkPipeline(
            configuration: ArtworkPipelineConfiguration(
                cache: ArtworkCacheConfiguration(
                    directory: directory,
                    byteLimit: 1_000_000
                )
            ),
            session: artworkSession()
        )

        async let first = pipeline.data(for: artworkURL)
        async let second = pipeline.data(for: artworkURL)
        let (firstData, secondData) = try await (first, second)

        #expect(firstData == artworkBytes)
        #expect(secondData == artworkBytes)
        #expect(counter.value == 1)
    }

    @Test("Evicts the least-recently-used files when the quota is exceeded")
    func evictsLeastRecentlyUsed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ArtworkCache(
            configuration: ArtworkCacheConfiguration(
                directory: directory,
                byteLimit: 100
            )
        )

        try await cache.store(Data(repeating: 0x41, count: 60), forKey: "a")
        try await Task.sleep(for: .milliseconds(20))
        try await cache.store(Data(repeating: 0x42, count: 60), forKey: "b")

        let aExists = await cache.contains(key: "a")
        let bExists = await cache.contains(key: "b")
        #expect(!aExists)
        #expect(bExists)

        let size = try await cache.currentSize()
        #expect(size == 60)
    }

    @Test("A cache read promotes an entry ahead of older files")
    func readsPromoteEntries() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = ArtworkCache(
            configuration: ArtworkCacheConfiguration(
                directory: directory,
                byteLimit: 120
            )
        )

        try await cache.store(Data(repeating: 0x41, count: 60), forKey: "a")
        try await Task.sleep(for: .milliseconds(20))
        try await cache.store(Data(repeating: 0x42, count: 60), forKey: "b")
        try await Task.sleep(for: .milliseconds(20))

        let read = try await cache.data(forKey: "a")
        #expect(read == Data(repeating: 0x41, count: 60))
        try await Task.sleep(for: .milliseconds(20))

        try await cache.store(Data(repeating: 0x43, count: 60), forKey: "c")

        let aExists = await cache.contains(key: "a")
        let bExists = await cache.contains(key: "b")
        let cExists = await cache.contains(key: "c")
        #expect(aExists)
        #expect(!bExists)
        #expect(cExists)

        let size = try await cache.currentSize()
        #expect(size == 120)
    }

    @Test("Clears disk and memory caches")
    func clearsCaches() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        ArtworkMockURLProtocol.setHandler { request in
            try artworkRespond(to: request, data: artworkBytes)
        }

        let pipeline = ArtworkPipeline(
            configuration: ArtworkPipelineConfiguration(
                cache: ArtworkCacheConfiguration(
                    directory: directory,
                    byteLimit: 1_000_000
                )
            ),
            session: artworkSession()
        )

        _ = try await pipeline.data(for: artworkURL)
        try await pipeline.clear()

        let diskBytes = try await pipeline.diskBytesUsed()
        let memoryBytes = await pipeline.memoryBytesUsed()
        let cached = await pipeline.cachedData(for: artworkURL)

        #expect(diskBytes == 0)
        #expect(memoryBytes == 0)
        #expect(cached == nil)
    }

    @Test("Surfaces HTTP failures without caching")
    func httpFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        ArtworkMockURLProtocol.setHandler { request in
            try artworkRespond(to: request, status: 404, data: Data())
        }

        let pipeline = ArtworkPipeline(
            configuration: ArtworkPipelineConfiguration(
                cache: ArtworkCacheConfiguration(
                    directory: directory,
                    byteLimit: 1_000_000
                )
            ),
            session: artworkSession()
        )

        do {
            _ = try await pipeline.data(for: artworkURL)
            Issue.record("Expected an HTTP error")
        } catch let error as ArtworkPipelineError {
            #expect(error == .httpStatus(404))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let diskBytes = try await pipeline.diskBytesUsed()
        #expect(diskBytes == 0)
    }

    @Test("Cache keys are stable SHA-256 hashes of the URL")
    func cacheKeys() {
        let first = ArtworkCache.key(for: artworkURL)
        let second = ArtworkCache.key(for: artworkURL)
        let different = ArtworkCache.key(
            for: URL(string: "https://image.tmdb.org/t/p/w780/backdrop.jpg")!
        )

        #expect(first == second)
        #expect(first != different)
        #expect(first.count == 64)
        #expect(first.allSatisfy { $0.isHexDigit })
    }

    @Test("Clamps user-selected cache sizes to the supported range")
    func clampsByteLimit() {
        #expect(
            ArtworkCacheConfiguration.clampedByteLimit(1)
                == ArtworkCacheConfiguration.minimumByteLimit
        )
        #expect(
            ArtworkCacheConfiguration.clampedByteLimit(Int64.max)
                == ArtworkCacheConfiguration.maximumByteLimit
        )
        let mid: Int64 = 3 * 1024 * 1024 * 1024
        #expect(ArtworkCacheConfiguration.clampedByteLimit(mid) == mid)
    }
}
