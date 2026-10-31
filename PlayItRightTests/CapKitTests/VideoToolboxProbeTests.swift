import Foundation
import Testing
@testable import CapKit

@Suite("VideoToolboxProbe Tests")
struct VideoToolboxProbeTests {
    // MARK: - Test doubles

    private final class MockProber: VideoToolboxProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var decodeCalls = 0
        private var encodeCalls = 0

        var hardwareDecode: Set<VideoProbeFormat> = []
        var softwareDecode: Set<VideoProbeFormat> = []
        var hardwareEncode: Set<VideoProbeFormat> = []

        func canDecode(_ format: VideoProbeFormat, hardwareAccelerated: Bool) -> Bool {
            lock.lock()
            decodeCalls += 1
            lock.unlock()
            return hardwareAccelerated
                ? hardwareDecode.contains(format)
                : softwareDecode.contains(format)
        }

        func canEncode(_ format: VideoProbeFormat, hardwareAccelerated: Bool) -> Bool {
            lock.lock()
            encodeCalls += 1
            lock.unlock()
            return hardwareAccelerated && hardwareEncode.contains(format)
        }

        var totalDecodeCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return decodeCalls
        }

        var totalEncodeCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return encodeCalls
        }
    }

    private final class InMemoryProbeCache: ProbeCache, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ProbeCacheSnapshot?
        private var saveCount = 0
        private var removeCount = 0

        init(snapshot: ProbeCacheSnapshot? = nil) {
            self.stored = snapshot
        }

        func load() throws -> ProbeCacheSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func save(_ snapshot: ProbeCacheSnapshot) throws {
            lock.lock()
            defer { lock.unlock() }
            stored = snapshot
            saveCount += 1
        }

        func remove() throws {
            lock.lock()
            defer { lock.unlock() }
            stored = nil
            removeCount += 1
        }

        func snapshot() -> ProbeCacheSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        var totalSaves: Int {
            lock.lock()
            defer { lock.unlock() }
            return saveCount
        }
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_000)
    private let currentOS = "Version 18.0 (Build 22J1)"

    private func makeProbe(
        prober: MockProber,
        cache: InMemoryProbeCache,
        formats: [VideoProbeFormat] = VideoProbeFormat.defaultFormats,
        osVersion: String? = nil
    ) -> VideoToolboxProbe {
        let version = osVersion ?? currentOS
        return VideoToolboxProbe(
            prober: prober,
            cache: cache,
            formats: formats,
            osVersion: { version },
            now: { fixedDate }
        )
    }

    // MARK: - Probing

    @Test("Probes every default format")
    func probesDefaultFormats() {
        let prober = MockProber()
        let formats = VideoProbeFormat.defaultFormats
        prober.hardwareDecode = Set(formats)
        prober.softwareDecode = Set(formats)
        prober.hardwareEncode = Set(formats)

        let probe = makeProbe(prober: prober, cache: InMemoryProbeCache())
        let results = probe.results()

        #expect(results.count == 6)
        #expect(results.map(\.format) == formats)
        #expect(Set(results.map(\.format.codec)) == [.h264, .hevc, .av1, .vp9, .prores])
    }

    @Test("Records decode and encode capabilities separately")
    func recordsCapabilitiesPerFormat() {
        let h264 = VideoProbeFormat(codec: .h264, bitDepth: 8)
        let av1 = VideoProbeFormat(codec: .av1, bitDepth: 10)

        let prober = MockProber()
        prober.hardwareDecode = [h264]
        prober.softwareDecode = [h264, av1]
        prober.hardwareEncode = [h264]

        let probe = makeProbe(
            prober: prober,
            cache: InMemoryProbeCache(),
            formats: [h264, av1]
        )
        let results = probe.results()

        #expect(results[0].hardwareDecode)
        #expect(results[0].softwareDecode)
        #expect(results[0].hardwareEncode)

        #expect(!results[1].hardwareDecode)
        #expect(results[1].softwareDecode)
        #expect(!results[1].hardwareEncode)
    }

    @Test("No formats yields an empty result set")
    func noFormats() {
        let probe = makeProbe(
            prober: MockProber(),
            cache: InMemoryProbeCache(),
            formats: []
        )

        #expect(probe.results().isEmpty)
    }

    // MARK: - Caching

    @Test("A second call is served from the memory cache")
    func memoryCacheAvoidsReprobe() {
        let prober = MockProber()
        let probe = makeProbe(prober: prober, cache: InMemoryProbeCache())

        _ = probe.results()
        let callsAfterFirstProbe = prober.totalDecodeCalls
        _ = probe.results()

        #expect(prober.totalDecodeCalls == callsAfterFirstProbe)
        #expect(callsAfterFirstProbe == VideoProbeFormat.defaultFormats.count * 2)
    }

    @Test("A later instance reuses the persisted snapshot")
    func diskCacheAvoidsReprobe() {
        let cache = InMemoryProbeCache()
        let formats = VideoProbeFormat.defaultFormats

        let firstProber = MockProber()
        firstProber.hardwareDecode = Set(formats)
        let first = makeProbe(prober: firstProber, cache: cache, formats: formats)
        _ = first.results()

        let secondProber = MockProber()
        let second = makeProbe(prober: secondProber, cache: cache, formats: formats)
        let results = second.results()

        #expect(secondProber.totalDecodeCalls == 0)
        #expect(results.allSatisfy { $0.hardwareDecode })
    }

    @Test("An OS version change evicts the cache and re-probes")
    func osVersionChangeReprobes() {
        let formats = VideoProbeFormat.defaultFormats
        let staleResults = formats.map {
            VideoProbeResult(
                format: $0,
                hardwareDecode: false,
                softwareDecode: true,
                hardwareEncode: false,
                probedAt: fixedDate
            )
        }
        let cache = InMemoryProbeCache(
            snapshot: ProbeCacheSnapshot(
                osVersion: "Version 17.0 (Build 21A1)",
                results: staleResults,
                createdAt: fixedDate
            )
        )

        let prober = MockProber()
        prober.hardwareDecode = Set(formats)
        let probe = makeProbe(prober: prober, cache: cache, formats: formats)

        let results = probe.results()

        #expect(results.allSatisfy { $0.hardwareDecode })
        #expect(cache.snapshot()?.osVersion == currentOS)
        #expect(prober.totalDecodeCalls == formats.count * 2)
    }

    @Test("A changed format list evicts the cache")
    func formatListChangeReprobes() {
        let oldFormat = VideoProbeFormat(codec: .h264, bitDepth: 8)
        let newFormat = VideoProbeFormat(codec: .hevc, bitDepth: 10)
        let cache = InMemoryProbeCache(
            snapshot: ProbeCacheSnapshot(
                osVersion: currentOS,
                results: [
                    VideoProbeResult(
                        format: oldFormat,
                        hardwareDecode: true,
                        softwareDecode: true,
                        hardwareEncode: true,
                        probedAt: fixedDate
                    )
                ],
                createdAt: fixedDate
            )
        )

        let probe = makeProbe(
            prober: MockProber(),
            cache: cache,
            formats: [newFormat]
        )
        let results = probe.results()

        #expect(results.map(\.format) == [newFormat])
    }

    @Test("A forced refresh bypasses both caches")
    func forceRefreshReprobes() {
        let formats = VideoProbeFormat.defaultFormats
        let prober = MockProber()
        let probe = makeProbe(prober: prober, cache: InMemoryProbeCache(), formats: formats)

        _ = probe.results()
        prober.hardwareDecode = Set(formats)
        let refreshed = probe.results(forceRefresh: true)

        #expect(refreshed.allSatisfy { $0.hardwareDecode })
        #expect(prober.totalDecodeCalls == formats.count * 4)
    }

    @Test("invalidate clears memory and disk caches")
    func invalidateClearsCaches() {
        let cache = InMemoryProbeCache()
        let prober = MockProber()
        let probe = makeProbe(prober: prober, cache: cache)

        _ = probe.results()
        probe.invalidate()
        _ = probe.results()

        #expect(cache.snapshot() != nil)
        #expect(prober.totalDecodeCalls == VideoProbeFormat.defaultFormats.count * 4)
    }

    // MARK: - File cache

    @Test("File cache round-trips snapshots and removes them")
    func fileCacheRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapKitTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("probes.json")
        let cache = FileProbeCache(url: url)

        let snapshot = ProbeCacheSnapshot(
            osVersion: currentOS,
            results: VideoProbeFormat.defaultFormats.map {
                VideoProbeResult(
                    format: $0,
                    hardwareDecode: true,
                    softwareDecode: true,
                    hardwareEncode: false,
                    probedAt: fixedDate
                )
            },
            createdAt: fixedDate
        )

        try cache.save(snapshot)
        #expect(try cache.load() == snapshot)

        try cache.remove()
        #expect(try cache.load() == nil)

        try? FileManager.default.removeItem(at: directory)
    }
}
