import Darwin
import Foundation

/// A pixel resolution used when querying the registry.
public struct VideoResolution: Codable, Sendable, Equatable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let uhd4K = VideoResolution(width: 3840, height: 2160)
    public static let hd1080p = VideoResolution(width: 1920, height: 1080)
}

/// The decode path the registry would select for a format.
public enum DecodePath: String, Sendable, Equatable {
    case hardware
    case software
    case unsupported
}

/// Raised when the app runs on hardware outside the supported fleet.
public enum UnsupportedHardwareError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedDevice(model: String)

    public var description: String {
        switch self {
        case .unsupportedDevice(let model):
            return "PlayItRight requires an Apple TV 4K (gen 2 or later); detected model '\(model)'."
        }
    }
}

/// The single authority for hardware capability questions (ARCH-1).
///
/// Layer 1 is the bundled `Capabilities.json` profile. Layer 2 is a set of
/// runtime `VideoProbeResult`s which override the static data when they exist
/// (PB-10). A developer override can force the software path for testing.
public final class CapabilityRegistry: @unchecked Sendable {
    public let profile: DeviceCapabilityProfile

    private struct ProbeKey: Hashable {
        let codec: VideoCodec
        let bitDepth: Int
    }

    private let lock = NSLock()
    private let probes: [ProbeKey: VideoProbeResult]
    private var softwareForced: Bool

    public init(
        profile: DeviceCapabilityProfile,
        probeResults: [VideoProbeResult] = [],
        forceSoftwarePath: Bool = false
    ) {
        self.profile = profile
        self.softwareForced = forceSoftwarePath
        self.probes = Dictionary(
            probeResults.compactMap { result in
                guard let codec = Self.videoCodec(for: result.format.codec) else {
                    return nil
                }
                return (ProbeKey(codec: codec, bitDepth: result.format.bitDepth), result)
            },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    /// Whether the developer "force software path" toggle is active.
    public var forceSoftwarePath: Bool {
        lock.lock()
        defer { lock.unlock() }
        return softwareForced
    }

    public func setForceSoftwarePath(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        softwareForced = enabled
    }

    public func videoCapability(for codec: VideoCodec) -> VideoCodecCapability? {
        profile.videoCapability(for: codec)
    }

    /// Returns whether `codec` can be hardware-decoded at the requested
    /// bit depth, resolution, and optional Dolby Vision profile.
    public func canHardwareDecode(
        codec: VideoCodec,
        bitDepth: Int,
        resolution: VideoResolution = .uhd4K,
        dolbyVisionProfile: Double? = nil
    ) -> Bool {
        guard !forceSoftwarePath else {
            return false
        }

        if let capability = profile.videoCapability(for: codec) {
            guard resolution.width <= capability.maxWidth,
                  resolution.height <= capability.maxHeight else {
                return false
            }
            if let dolbyVisionProfile,
               !capability.supportsDolbyVision(profile: dolbyVisionProfile) {
                return false
            }
        }

        if let probe = probe(for: codec, bitDepth: bitDepth) {
            return probe.hardwareDecode
        }

        guard let capability = profile.videoCapability(for: codec),
              capability.supportsHardwareDecode,
              bitDepth <= capability.maxBitDepth else {
            return false
        }
        return true
    }

    /// Returns whether `codec` can be decoded at all on the software path.
    public func canSoftwareDecode(
        codec: VideoCodec,
        bitDepth: Int,
        resolution: VideoResolution = .uhd4K
    ) -> Bool {
        guard let capability = profile.videoCapability(for: codec) else {
            return false
        }
        guard bitDepth <= capability.maxBitDepth else {
            return false
        }
        guard resolution.width <= capability.maxWidth,
              resolution.height <= capability.maxHeight else {
            return false
        }

        if let probe = probe(for: codec, bitDepth: bitDepth) {
            return probe.softwareDecode || capability.decode != .none
        }
        return capability.decode != .none
    }

    /// The preferred decode path for the format, after applying overrides.
    public func decodePath(
        codec: VideoCodec,
        bitDepth: Int,
        resolution: VideoResolution = .uhd4K,
        dolbyVisionProfile: Double? = nil
    ) -> DecodePath {
        if canHardwareDecode(
            codec: codec,
            bitDepth: bitDepth,
            resolution: resolution,
            dolbyVisionProfile: dolbyVisionProfile
        ) {
            return .hardware
        }
        if canSoftwareDecode(codec: codec, bitDepth: bitDepth, resolution: resolution) {
            return .software
        }
        return .unsupported
    }

    /// Returns whether `codec` can be hardware-encoded at `bitDepth`.
    public func canHardwareEncode(codec: VideoCodec, bitDepth: Int) -> Bool {
        guard !forceSoftwarePath else {
            return false
        }

        if let probe = probe(for: codec, bitDepth: bitDepth) {
            return probe.hardwareEncode
        }

        guard let capability = profile.videoCapability(for: codec) else {
            return false
        }
        return capability.hardwareEncode && bitDepth <= capability.maxBitDepth
    }

    /// Returns whether the device can present the given Dolby Vision profile.
    public func supportsDolbyVision(profile dolbyVisionProfile: Double) -> Bool {
        profile.videoCapability(for: .hevc)?
            .supportsDolbyVision(profile: dolbyVisionProfile) ?? false
    }

    // MARK: - Device resolution

    /// Resolves a model identifier to a supported profile.
    ///
    /// Apple TV HD (`AppleTV5,3`/`6,2`) and the 2017 gen 1 box are rejected
    /// with `UnsupportedHardwareError` (NFR-19).
    public static func resolveProfile(
        modelIdentifier: String,
        from matrix: CapabilityMatrix
    ) throws -> DeviceCapabilityProfile {
        let generation: Int?
        switch modelIdentifier {
        case "AppleTV11,1":
            generation = 2
        case "AppleTV14,1":
            generation = 3
        default:
            if modelIdentifier.hasPrefix("AppleTV17,")
                || modelIdentifier.hasPrefix("AppleTV18,")
                || modelIdentifier.hasPrefix("AppleTV19,") {
                generation = 4
            } else {
                generation = nil
            }
        }

        guard let generation,
              let profile = matrix.profile(forGeneration: generation) else {
            throw UnsupportedHardwareError.unsupportedDevice(model: modelIdentifier)
        }
        return profile
    }

    /// Builds a registry for the running device.
    public static func makeDefault(
        modelIdentifier: String = currentModelIdentifier(),
        matrix: CapabilityMatrix? = nil,
        probeResults: [VideoProbeResult] = [],
        forceSoftwarePath: Bool = false
    ) throws -> CapabilityRegistry {
        let resolvedMatrix: CapabilityMatrix
        if let matrix {
            resolvedMatrix = matrix
        } else {
            resolvedMatrix = try CapabilityMatrix.bundled()
        }
        let profile = try resolveProfile(modelIdentifier: modelIdentifier, from: resolvedMatrix)
        return CapabilityRegistry(
            profile: profile,
            probeResults: probeResults,
            forceSoftwarePath: forceSoftwarePath
        )
    }

    /// Reads the hardware model identifier, using the simulator override when
    /// running in a simulator.
    public static func currentModelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }

        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else {
            return "unknown"
        }
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
    }

    // MARK: - Private

    private func probe(for codec: VideoCodec, bitDepth: Int) -> VideoProbeResult? {
        lock.lock()
        defer { lock.unlock() }
        return probes[ProbeKey(codec: codec, bitDepth: bitDepth)]
    }

    private static func videoCodec(for probeCodec: VideoProbeCodec) -> VideoCodec? {
        switch probeCodec {
        case .h264: return .h264
        case .hevc: return .hevc
        case .av1: return .av1
        case .vp9: return .vp9
        case .prores: return nil
        }
    }
}
