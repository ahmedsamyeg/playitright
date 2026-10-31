import CoreMedia
import Foundation
import VideoToolbox

/// Video codecs exercised by the runtime probe.
public enum VideoProbeCodec: String, Codable, Sendable, CaseIterable {
    case h264
    case hevc
    case av1
    case vp9
    case prores
}

/// A minimal codec/bit-depth combination to probe.
public struct VideoProbeFormat: Codable, Sendable, Hashable {
    public let codec: VideoProbeCodec
    public let bitDepth: Int
    public let width: Int
    public let height: Int

    public init(
        codec: VideoProbeCodec,
        bitDepth: Int,
        width: Int = 1920,
        height: Int = 1080
    ) {
        self.codec = codec
        self.bitDepth = bitDepth
        self.width = width
        self.height = height
    }

    public var label: String {
        "\(codec.rawValue)-\(bitDepth)bit"
    }

    /// Formats probed on every launch, matching PB-8 and doc 04 §5.1.
    public static let defaultFormats: [VideoProbeFormat] = [
        VideoProbeFormat(codec: .h264, bitDepth: 8),
        VideoProbeFormat(codec: .hevc, bitDepth: 8),
        VideoProbeFormat(codec: .hevc, bitDepth: 10),
        VideoProbeFormat(codec: .av1, bitDepth: 10),
        VideoProbeFormat(codec: .vp9, bitDepth: 10),
        VideoProbeFormat(codec: .prores, bitDepth: 10)
    ]
}

/// The outcome of probing one format.
public struct VideoProbeResult: Codable, Sendable, Equatable {
    public let format: VideoProbeFormat
    public let hardwareDecode: Bool
    public let softwareDecode: Bool
    public let hardwareEncode: Bool
    public let probedAt: Date

    public init(
        format: VideoProbeFormat,
        hardwareDecode: Bool,
        softwareDecode: Bool,
        hardwareEncode: Bool,
        probedAt: Date
    ) {
        self.format = format
        self.hardwareDecode = hardwareDecode
        self.softwareDecode = softwareDecode
        self.hardwareEncode = hardwareEncode
        self.probedAt = probedAt
    }
}

/// Abstraction over VideoToolbox session creation so probes can be tested.
public protocol VideoToolboxProbing: Sendable {
    func canDecode(_ format: VideoProbeFormat, hardwareAccelerated: Bool) -> Bool
    func canEncode(_ format: VideoProbeFormat, hardwareAccelerated: Bool) -> Bool
}

/// Real VideoToolbox probe that attempts to create decode/encode sessions.
public struct VideoToolboxSystemProbe: VideoToolboxProbing {
    public init() {}

    public func canDecode(_ format: VideoProbeFormat, hardwareAccelerated: Bool) -> Bool {
        guard let description = makeFormatDescription(for: format) else {
            return false
        }

        let specification: [String: Any] = hardwareAccelerated
            ? [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true
            ]
            : [:]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        return status == noErr
    }

    public func canEncode(_ format: VideoProbeFormat, hardwareAccelerated: Bool) -> Bool {
        guard let codecType = codecType(for: format.codec) else {
            return false
        }

        let specification: [String: Any] = hardwareAccelerated
            ? [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
            ]
            : [:]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(format.width),
            height: Int32(format.height),
            codecType: codecType,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        if let session {
            VTCompressionSessionInvalidate(session)
        }
        return status == noErr
    }

    private func makeFormatDescription(for format: VideoProbeFormat) -> CMFormatDescription? {
        guard let codecType = codecType(for: format.codec) else {
            return nil
        }

        let depth = format.bitDepth >= 10 ? 30 : 24
        let extensions: [String: Any] = [
            kCMFormatDescriptionExtension_Depth as String: depth
        ]

        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(format.width),
            height: Int32(format.height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    private func codecType(for codec: VideoProbeCodec) -> CMVideoCodecType? {
        switch codec {
        case .h264:
            return kCMVideoCodecType_H264
        case .hevc:
            return kCMVideoCodecType_HEVC
        case .av1:
            return CMVideoCodecType(0x61763031) // 'av01'
        case .vp9:
            return CMVideoCodecType(0x76703039) // 'vp09'
        case .prores:
            return kCMVideoCodecType_AppleProRes422
        }
    }
}

// MARK: - Cache

/// Persisted probe results, keyed by OS version.
public struct ProbeCacheSnapshot: Codable, Sendable, Equatable {
    public let osVersion: String
    public let results: [VideoProbeResult]
    public let createdAt: Date

    public init(osVersion: String, results: [VideoProbeResult], createdAt: Date) {
        self.osVersion = osVersion
        self.results = results
        self.createdAt = createdAt
    }
}

/// Storage for probe results.
public protocol ProbeCache: Sendable {
    func load() throws -> ProbeCacheSnapshot?
    func save(_ snapshot: ProbeCacheSnapshot) throws
    func remove() throws
}

/// JSON-file cache in the app's caches directory.
public final class FileProbeCache: ProbeCache, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL = FileProbeCache.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("CapKit", isDirectory: true)
            .appendingPathComponent("video-probes.json", isDirectory: false)
    }

    public func load() throws -> ProbeCacheSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ProbeCacheSnapshot.self, from: data)
    }

    public func save(_ snapshot: ProbeCacheSnapshot) throws {
        lock.lock()
        defer { lock.unlock() }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public func remove() throws {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}

// MARK: - Probe runner

/// Runs VideoToolbox probes on launch and caches the results.
///
/// Subsequent launches normally complete in a few milliseconds because the
/// persisted snapshot is reused; the cache is discarded when the OS version
/// changes or the requested format list changes (PB-8, PB-10).
public final class VideoToolboxProbe: @unchecked Sendable {
    private let prober: any VideoToolboxProbing
    private let cache: any ProbeCache
    private let formats: [VideoProbeFormat]
    private let osVersion: @Sendable () -> String
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var memoryResults: [VideoProbeResult]?
    private var memoryOSVersion: String?

    public init(
        prober: any VideoToolboxProbing = VideoToolboxSystemProbe(),
        cache: any ProbeCache = FileProbeCache(),
        formats: [VideoProbeFormat] = VideoProbeFormat.defaultFormats,
        osVersion: @escaping @Sendable () -> String = {
            ProcessInfo.processInfo.operatingSystemVersionString
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.prober = prober
        self.cache = cache
        self.formats = formats
        self.osVersion = osVersion
        self.now = now
    }

    /// Returns probe results, using the memory cache, disk cache, or a fresh
    /// probe in that order.
    ///
    /// - Parameter forceRefresh: Ignore both caches and probe every format.
    public func results(forceRefresh: Bool = false) -> [VideoProbeResult] {
        let currentOS = osVersion()

        lock.lock()
        defer { lock.unlock() }

        if !forceRefresh,
           let memoryResults,
           memoryOSVersion == currentOS {
            return memoryResults
        }

        if !forceRefresh,
           let snapshot = try? cache.load(),
           snapshot.osVersion == currentOS,
           Set(snapshot.results.map(\.format)) == Set(formats) {
            memoryResults = snapshot.results
            memoryOSVersion = currentOS
            return snapshot.results
        }

        // Stale or missing cache: clear it before writing fresh results.
        try? cache.remove()

        let results = formats.map { format in
            VideoProbeResult(
                format: format,
                hardwareDecode: prober.canDecode(format, hardwareAccelerated: true),
                softwareDecode: prober.canDecode(format, hardwareAccelerated: false),
                hardwareEncode: prober.canEncode(format, hardwareAccelerated: true),
                probedAt: now()
            )
        }

        memoryResults = results
        memoryOSVersion = currentOS
        try? cache.save(
            ProbeCacheSnapshot(osVersion: currentOS, results: results, createdAt: now())
        )
        return results
    }

    /// Removes cached results so the next `results()` call re-probes.
    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        memoryResults = nil
        memoryOSVersion = nil
        try? cache.remove()
    }
}
