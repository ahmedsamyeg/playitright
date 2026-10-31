import Foundation

/// Audio codecs tracked by the capability matrix.
public enum AudioCodec: String, Codable, Sendable, CaseIterable {
    case ac3
    case eac3
    case aac
    case alac
    case flac
    case pcm
    case mp3
    case dts
    case truehd
    case opus
    case vorbis
}

/// Decode and output paths for one audio codec.
public struct AudioCodecCapability: Codable, Sendable, Equatable {
    public let codec: AudioCodec
    public let hardwareDecode: Bool
    public let softwareDecode: Bool
    /// Whether the codec can be passed through to an HDMI sink.
    public let passthrough: Bool

    public init(
        codec: AudioCodec,
        hardwareDecode: Bool,
        softwareDecode: Bool,
        passthrough: Bool
    ) {
        self.codec = codec
        self.hardwareDecode = hardwareDecode
        self.softwareDecode = softwareDecode
        self.passthrough = passthrough
    }

    /// Whether the codec can be played at all.
    public var isSupported: Bool {
        hardwareDecode || softwareDecode
    }
}

/// A complete capability profile for one Apple TV model.
public struct DeviceCapabilityProfile: Codable, Sendable, Equatable, Identifiable {
    /// Stable identifier, e.g. `apple-tv-4k-gen4`.
    public let id: String
    public let displayName: String
    public let generation: Int
    public let chip: String
    /// Minimum supported tvOS version, e.g. `18.0`.
    public let tvOSMinimum: String
    public let maxVideoOutput: String
    public let maxHDRVideoOutput: String
    public let videoCodecs: [VideoCodecCapability]
    public let audioCodecs: [AudioCodecCapability]

    public init(
        id: String,
        displayName: String,
        generation: Int,
        chip: String,
        tvOSMinimum: String,
        maxVideoOutput: String,
        maxHDRVideoOutput: String,
        videoCodecs: [VideoCodecCapability],
        audioCodecs: [AudioCodecCapability]
    ) {
        self.id = id
        self.displayName = displayName
        self.generation = generation
        self.chip = chip
        self.tvOSMinimum = tvOSMinimum
        self.maxVideoOutput = maxVideoOutput
        self.maxHDRVideoOutput = maxHDRVideoOutput
        self.videoCodecs = videoCodecs
        self.audioCodecs = audioCodecs
    }

    public func videoCapability(for codec: VideoCodec) -> VideoCodecCapability? {
        videoCodecs.first { $0.codec == codec }
    }

    public func audioCapability(for codec: AudioCodec) -> AudioCodecCapability? {
        audioCodecs.first { $0.codec == codec }
    }

    /// The highest bit depth at which `codec` can be hardware-decoded, if any.
    public func hardwareDecodeBitDepth(for codec: VideoCodec) -> Int? {
        guard let capability = videoCapability(for: codec),
              capability.supportsHardwareDecode else {
            return nil
        }
        return capability.maxBitDepth
    }
}
