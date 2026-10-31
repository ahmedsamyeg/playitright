import Foundation

/// Video codecs tracked by the capability matrix.
public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case h264
    case hevc
    case av1
    case vp9
    case vvc
    case mpeg2
    case vc1
    case wmv
    case divx
}

/// How a codec can be decoded on a device.
public enum DecodeSupport: String, Codable, Sendable, CaseIterable {
    /// Dedicated hardware decoder.
    case hw

    /// Software decoder (FFmpeg or equivalent).
    case sw

    /// Not supported at all.
    case none

    public var isHardware: Bool { self == .hw }
    public var isSoftware: Bool { self == .sw }
}

/// HDR transports understood by the matrix.
public enum HDRFormat: String, Codable, Sendable, CaseIterable {
    case hdr10
    case hdr10Plus = "hdr10_plus"
    case hlg
}

/// Decode, output, and encoding capabilities for one video codec.
public struct VideoCodecCapability: Codable, Sendable, Equatable {
    public let codec: VideoCodec
    public let decode: DecodeSupport
    public let maxWidth: Int
    public let maxHeight: Int
    public let maxBitDepth: Int
    public let hdrFormats: [HDRFormat]
    /// Supported Dolby Vision profiles, e.g. `[5, 8]` or `[5, 8.1]`.
    public let dolbyVisionProfiles: [Double]
    public let hardwareEncode: Bool

    public init(
        codec: VideoCodec,
        decode: DecodeSupport,
        maxWidth: Int,
        maxHeight: Int,
        maxBitDepth: Int,
        hdrFormats: [HDRFormat] = [],
        dolbyVisionProfiles: [Double] = [],
        hardwareEncode: Bool = false
    ) {
        self.codec = codec
        self.decode = decode
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxBitDepth = maxBitDepth
        self.hdrFormats = hdrFormats
        self.dolbyVisionProfiles = dolbyVisionProfiles
        self.hardwareEncode = hardwareEncode
    }

    public var supportsHardwareDecode: Bool { decode.isHardware }

    public func supportsDolbyVision(profile: Double) -> Bool {
        dolbyVisionProfiles.contains(profile)
    }
}
