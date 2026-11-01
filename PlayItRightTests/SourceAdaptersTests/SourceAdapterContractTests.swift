import Foundation
import Testing
@testable import SourceAdapters

// MARK: - Mock adapter

private struct MockSourceAdapter: SourceAdapter {
    let kind: SourceKind = .http
    let payload: Data
    let items: [SourceItem]

    init(payload: Data, items: [SourceItem]) {
        self.payload = payload
        self.items = items
    }

    func connect(config: SourceConfig) async throws -> SourceSession {
        SourceSession(
            sourceID: config.id,
            capabilities: [
                .rangeRequests,
                .recursiveEnumeration,
                .directPlay
            ],
            metadata: ["server": "mock"]
        )
    }

    func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        let items = self.items
        return AsyncThrowingStream { continuation in
            for item in items {
                continuation.yield(item)
            }
            continuation.finish()
        }
    }

    func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error> {
        let payload = self.payload
        return AsyncThrowingStream { continuation in
            let requested = range ?? .full
            let size = Int64(payload.count)

            guard let clamped = requested.clamped(to: size) else {
                continuation.finish(
                    throwing: SourceAdapterError.rangeNotSatisfiable(
                        requested,
                        size: size
                    )
                )
                return
            }

            let start = Int(clamped.start)
            let end = Int(clamped.end ?? (size - 1))
            continuation.yield(payload.subdata(in: start..<(end + 1)))
            continuation.finish()
        }
    }
}

// MARK: - Fixtures

private let samplePayload = Data((0..<256).map { UInt8($0 % 256) })

private func makeItem(sourceID: UUID) -> SourceItem {
    SourceItem(
        id: "item-1",
        sourceID: sourceID,
        kind: .movie,
        name: "Inception.mkv",
        location: "/Movies/Inception.mkv",
        sizeBytes: Int64(samplePayload.count),
        container: "mkv",
        providerIDs: ["tmdb": "27205"]
    )
}

// MARK: - Tests

@Suite("SourceAdapterContractTests")
struct SourceAdapterContractTests {
    @Test("A mock adapter fulfills connect, enumerate, and read")
    func fulfillsContract() async throws {
        let config = SourceConfig(
            kind: .http,
            name: "Test HTTP",
            endpoint: URL(string: "https://example.com/media")
        )
        let item = makeItem(sourceID: config.id)
        let adapter = MockSourceAdapter(
            payload: samplePayload,
            items: [item]
        )

        let session = try await adapter.connect(config: config)
        #expect(session.sourceID == config.id)
        #expect(session.capabilities.contains(.rangeRequests))
        #expect(session.capabilities.contains(.directPlay))
        #expect(session.capabilities.contains(.recursiveEnumeration))
        #expect(session.metadata["server"] == "mock")

        var enumerated: [SourceItem] = []
        for try await enumeratedItem in try await adapter.enumerate(
            session: session,
            scope: LibraryScope(path: "/Movies")
        ) {
            enumerated.append(enumeratedItem)
        }
        #expect(enumerated == [item])

        var fullData = Data()
        for try await chunk in adapter.read(
            session: session,
            item: item,
            range: nil
        ) {
            fullData.append(chunk)
        }
        #expect(fullData == samplePayload)
    }

    @Test("Ranged reads return the requested slice")
    func rangedRead() async throws {
        let config = SourceConfig(kind: .http, name: "Test")
        let item = makeItem(sourceID: config.id)
        let adapter = MockSourceAdapter(
            payload: samplePayload,
            items: [item]
        )
        let session = try await adapter.connect(config: config)

        let range = try ByteRange(start: 10, end: 19)
        var data = Data()
        for try await chunk in adapter.read(
            session: session,
            item: item,
            range: range
        ) {
            data.append(chunk)
        }

        #expect(data == samplePayload.subdata(in: 10..<20))
        #expect(data.count == 10)
    }

    @Test("An open-ended range reads to the end of the item")
    func openEndedRead() async throws {
        let config = SourceConfig(kind: .http, name: "Test")
        let item = makeItem(sourceID: config.id)
        let adapter = MockSourceAdapter(
            payload: samplePayload,
            items: [item]
        )
        let session = try await adapter.connect(config: config)

        let range = try ByteRange(start: 250)
        var data = Data()
        for try await chunk in adapter.read(
            session: session,
            item: item,
            range: range
        ) {
            data.append(chunk)
        }

        #expect(data == samplePayload.subdata(in: 250..<256))
    }

    @Test("A mid-stream seek reads from an arbitrary offset")
    func midStreamSeek() async throws {
        let config = SourceConfig(kind: .http, name: "Test")
        let item = makeItem(sourceID: config.id)
        let adapter = MockSourceAdapter(
            payload: samplePayload,
            items: [item]
        )
        let session = try await adapter.connect(config: config)

        let range = try ByteRange(start: 100, end: 149)
        var data = Data()
        for try await chunk in adapter.read(
            session: session,
            item: item,
            range: range
        ) {
            data.append(chunk)
        }

        #expect(data == samplePayload.subdata(in: 100..<150))
    }

    @Test("A range past the end is rejected as unsatisfiable")
    func unsatisfiableRange() async throws {
        let config = SourceConfig(kind: .http, name: "Test")
        let item = makeItem(sourceID: config.id)
        let adapter = MockSourceAdapter(
            payload: samplePayload,
            items: [item]
        )
        let session = try await adapter.connect(config: config)

        let range = try ByteRange(start: 300)
        let expected = SourceAdapterError.rangeNotSatisfiable(
            range,
            size: Int64(samplePayload.count)
        )

        do {
            for try await _ in adapter.read(
                session: session,
                item: item,
                range: range
            ) {}
            Issue.record("Expected rangeNotSatisfiable")
        } catch let error as SourceAdapterError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Default adapter hooks are safe no-ops or structured errors")
    func defaultHooks() async throws {
        let config = SourceConfig(kind: .http, name: "Test")
        let item = makeItem(sourceID: config.id)
        let adapter = MockSourceAdapter(
            payload: samplePayload,
            items: [item]
        )
        let session = try await adapter.connect(config: config)

        let freshness = try await adapter.freshness(session: session)
        #expect(freshness.strategy == .none)
        #expect(freshness.hasChanges == false)

        await adapter.disconnect(session: session)

        do {
            try await adapter.pushWatchState(
                session: session,
                item: item,
                state: SourceWatchState(position: 12)
            )
            Issue.record("Expected unsupported")
        } catch let error as SourceAdapterError {
            #expect(error == .unsupported("watch-state writes"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: ByteRange

    @Test("ByteRange rejects negative and inverted values")
    func byteRangeValidation() {
        do {
            _ = try ByteRange(start: -1)
            Issue.record("Expected invalidRange for a negative start")
        } catch let error as ByteRangeError {
            #expect(error == .invalidRange(start: -1, end: nil))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            _ = try ByteRange(start: 10, end: 9)
            Issue.record("Expected invalidRange for an inverted range")
        } catch let error as ByteRangeError {
            #expect(error == .invalidRange(start: 10, end: 9))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("ByteRange calculates length, headers, and containment")
    func byteRangeMath() throws {
        let range = try ByteRange(start: 10, end: 19)
        #expect(range.length == 10)
        #expect(range.httpHeaderValue == "bytes=10-19")
        #expect(range.contains(10))
        #expect(range.contains(19))
        #expect(!range.contains(9))
        #expect(!range.contains(20))

        #expect(ByteRange.full.length == nil)
        #expect(ByteRange.full.httpHeaderValue == "bytes=0-")
        #expect(ByteRange.full.contains(1_000_000))
    }

    @Test("ByteRange clamps to a known item size")
    func byteRangeClamping() throws {
        let range = try ByteRange(start: 90, end: 200)
        let clamped = try #require(range.clamped(to: 100))
        #expect(clamped.start == 90)
        #expect(clamped.end == 99)
        #expect(clamped.length == 10)

        let openEnded = try ByteRange(start: 250)
        let clampedOpen = try #require(openEnded.clamped(to: 256))
        #expect(clampedOpen.start == 250)
        #expect(clampedOpen.end == 255)

        let beyondEnd = try ByteRange(start: 100)
        let emptyItem = try ByteRange(start: 0)
        #expect(beyondEnd.clamped(to: 100) == nil)
        #expect(emptyItem.clamped(to: 0) == nil)
    }

    @Test("ByteRange parses standard Range headers")
    func byteRangeParsing() throws {
        let closed = try #require(ByteRange(httpHeaderValue: "bytes=0-1023"))
        #expect(closed.start == 0)
        #expect(closed.end == 1023)

        let open = try #require(ByteRange(httpHeaderValue: "bytes=1024-"))
        #expect(open.start == 1024)
        #expect(open.end == nil)

        #expect(ByteRange(httpHeaderValue: "bytes=9-1") == nil)
        #expect(ByteRange(httpHeaderValue: "items=0-1") == nil)
        #expect(ByteRange(httpHeaderValue: "bytes=-500") == nil)
    }

    @Test("SourceConfig keeps secrets out and SourceWatchState clamps position")
    func configurationAndWatchState() {
        let config = SourceConfig(
            kind: .smb,
            name: "NAS",
            host: "nas.local",
            port: 445,
            username: "samy",
            credentialReference: "source:nas:password",
            excludeGlobs: ["*.nfo", "sample*"]
        )

        #expect(config.host == "nas.local")
        #expect(config.credentialReference == "source:nas:password")
        #expect(config.excludeGlobs == ["*.nfo", "sample*"])

        let state = SourceWatchState(position: -5, duration: 120, isWatched: false)
        #expect(state.position == 0)
        #expect(state.duration == 120)
    }
}
