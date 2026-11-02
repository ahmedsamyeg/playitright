import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit
import SourceAdapters

// MARK: - Fakes

private final class MockResourceRequest: PlaybackResourceLoadingRequest, @unchecked Sendable {
    let requestedOffset: Int64
    let requestedLength: Int
    let requestsAllDataToEndOfResource: Bool
    let hasContentInformationRequest: Bool

    private let lock = NSLock()
    private var storedData = Data()
    private var storedFinished = false
    private var storedError: Error?
    private var storedContentType: String?
    private var storedContentLength: Int64?
    private var storedByteRangeAccessSupported = false

    init(
        requestedOffset: Int64,
        requestedLength: Int,
        requestsAllDataToEndOfResource: Bool = false,
        hasContentInformationRequest: Bool = false
    ) {
        self.requestedOffset = requestedOffset
        self.requestedLength = requestedLength
        self.requestsAllDataToEndOfResource = requestsAllDataToEndOfResource
        self.hasContentInformationRequest = hasContentInformationRequest
    }

    var currentOffset: Int64 {
        requestedOffset + Int64(data.count)
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedError is CancellationError
    }

    var requestIdentity: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedFinished
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    var contentInformation: (
        contentType: String?,
        contentLength: Int64?,
        byteRangeAccessSupported: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            storedContentType,
            storedContentLength,
            storedByteRangeAccessSupported
        )
    }

    func setContentInformation(
        contentType: String?,
        contentLength: Int64,
        byteRangeAccessSupported: Bool
    ) {
        lock.lock()
        storedContentType = contentType
        storedContentLength = contentLength
        storedByteRangeAccessSupported = byteRangeAccessSupported
        lock.unlock()
    }

    func respond(data: Data) {
        lock.lock()
        storedData.append(data)
        lock.unlock()
    }

    func finishLoading() {
        lock.lock()
        storedFinished = true
        lock.unlock()
    }

    func finishLoading(with error: Error) {
        lock.lock()
        storedError = error
        storedFinished = true
        lock.unlock()
    }
}

private final class MockSourceAdapter: SourceAdapter, @unchecked Sendable {
    let kind: SourceKind = .smb

    private let lock = NSLock()
    private var storedRequests: [ByteRange?] = []
    private var storedTerminations: [String] = []

    private let handler: @Sendable (ByteRange?) -> AsyncThrowingStream<Data, Error>

    init(
        handler: @escaping @Sendable (
            ByteRange?
        ) -> AsyncThrowingStream<Data, Error>
    ) {
        self.handler = handler
    }

    var requestedRanges: [ByteRange?] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    var terminations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedTerminations
    }

    func connect(config: SourceConfig) async throws -> SourceSession {
        throw SourceAdapterError.unsupported("connect")
    }

    func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        storedRequests.append(range)
        lock.unlock()

        let handler = handler
        return AsyncThrowingStream { continuation in
            let inner = handler(range)
            let task = Task {
                do {
                    for try await chunk in inner {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                task.cancel()
                self.record(termination: termination)
            }
        }
    }

    private func record(termination: AsyncThrowingStream<Data, Error>.Continuation.Termination) {
        let label: String
        switch termination {
        case .cancelled:
            label = "cancelled"
        case .finished:
            label = "finished"
        @unknown default:
            label = "unknown"
        }
        lock.lock()
        storedTerminations.append(label)
        lock.unlock()
    }
}

private func makeSession() -> SourceSession {
    SourceSession(
        sourceID: UUID(),
        capabilities: []
    )
}

private func makeItem(size: Int64) -> SourceItem {
    SourceItem(
        id: "item-1",
        sourceID: UUID(),
        kind: .movie,
        name: "Movie.mp4",
        location: "/Movies/Movie.mp4",
        sizeBytes: size,
        container: "mp4"
    )
}

private func wait(
    timeout: TimeInterval = 2,
    until condition: @escaping @Sendable () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Tests

@Suite("DirectPlayPipeline Tests")
struct DirectPlayPipelineTests {
    @Test("The loader answers a data request with the source's byte range")
    func rangedRead() async throws {
        let adapter = MockSourceAdapter { range in
            AsyncThrowingStream { continuation in
                if let range {
                    let count = Int(range.length ?? 0)
                    let bytes = (0..<count).map { UInt8($0 % 251) }
                    continuation.yield(Data(bytes))
                }
                continuation.finish()
            }
        }
        let request = MockResourceRequest(
            requestedOffset: 10,
            requestedLength: 5,
            hasContentInformationRequest: true
        )
        let delegate = CustomResourceLoaderDelegate(
            adapter: adapter,
            session: makeSession(),
            item: makeItem(size: 1_000),
            contentType: "public.mpeg-4"
        )

        delegate.handle(request)
        try await wait { request.isFinished }

        #expect(request.error == nil)
        #expect(request.data.count == 5)
        #expect(request.data == Data((0..<5).map { UInt8($0) }))

        let information = request.contentInformation
        #expect(information.contentType == "public.mpeg-4")
        #expect(information.contentLength == 1_000)
        #expect(information.byteRangeAccessSupported)

        let range = try #require(adapter.requestedRanges.first ?? nil)
        #expect(range.start == 10)
        #expect(range.end == 14)
        #expect(range.length == 5)
    }

    @Test("A seek cancels the previous stream and reads from the new offset")
    func seekCancelsPreviousRead() async throws {
        let adapter = MockSourceAdapter { range in
            guard let start = range?.start, start > 0 else {
                // First request: deliver one byte, then stay open forever so
                // it can only end when the loader cancels it.
                return AsyncThrowingStream { continuation in
                    continuation.yield(Data([0x01]))
                }
            }
            // Seeked request: answer immediately.
            return AsyncThrowingStream { continuation in
                continuation.yield(Data([0xAB, 0xCD]))
                continuation.finish()
            }
        }
        let first = MockResourceRequest(
            requestedOffset: 0,
            requestedLength: 4
        )
        let second = MockResourceRequest(
            requestedOffset: 5_000,
            requestedLength: 2
        )
        let delegate = CustomResourceLoaderDelegate(
            adapter: adapter,
            session: makeSession(),
            item: makeItem(size: 8_000)
        )

        delegate.handle(first)
        try await wait { !first.data.isEmpty }
        #expect(delegate.activeRequestCount == 1)

        // AVFoundation calls `didCancel` for the superseded request.
        delegate.cancel(first)
        #expect(delegate.wasCancelled(first))

        delegate.handle(second)
        try await wait { second.isFinished }

        #expect(second.data == Data([0xAB, 0xCD]))
        #expect(second.error == nil)

        try await wait { first.isFinished }
        #expect(first.error is CancellationError)
        #expect(first.data.count == 1)
        #expect(adapter.terminations.contains("cancelled"))

        let starts = adapter.requestedRanges.compactMap { $0?.start }
        #expect(starts.contains(0))
        #expect(starts.contains(5_000))

        let seekRange = try #require(
            adapter.requestedRanges.compactMap { $0 }.last
        )
        #expect(seekRange.start == 5_000)
        #expect(seekRange.end == 5_001)
    }

    @Test("The asset URL uses the custom scheme and item path")
    func customSchemeAsset() {
        let adapter = MockSourceAdapter { _ in
            AsyncThrowingStream { $0.finish() }
        }
        let delegate = CustomResourceLoaderDelegate(
            adapter: adapter,
            session: makeSession(),
            item: makeItem(size: 1_000)
        )
        let url = delegate.assetURL()
        #expect(url.scheme == CustomResourceLoaderDelegate.scheme)
        #expect(url.path == "/Movie.mp4")
        #expect(delegate.assetURL().absoluteString.contains("Movie.mp4"))
        #expect(delegate.contentLength == 1_000)
        #expect(CustomResourceLoaderDelegate.contentType(for: makeItem(size: 1)) == "public.mpeg-4")
    }

    @Test("Direct play tracks timing and stays ready before playback starts")
    @MainActor
    func pipelineTracksMetrics() {
        let adapter = MockSourceAdapter { _ in
            AsyncThrowingStream { $0.finish() }
        }
        let pipeline = DirectPlayPipeline(
            adapter: adapter,
            session: makeSession(),
            item: makeItem(size: 1_000)
        )

        #expect(pipeline.asset.url.scheme == CustomResourceLoaderDelegate.scheme)
        #expect(pipeline.player.currentItem === pipeline.playerItem)
        #expect(pipeline.metrics.stallCount == 0)
        #expect(pipeline.metrics.lastStallAt == nil)
        #expect(pipeline.metrics.status == .ready)

        pipeline.seek(to: 12)
        #expect(pipeline.metrics.currentTime >= 0)

        pipeline.pause()
        #expect(pipeline.player.rate == 0)
    }
}
