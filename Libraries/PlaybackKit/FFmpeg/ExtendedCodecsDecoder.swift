import CoreVideo
import Foundation

/// The Pro entitlement seam used by extended codec decoding.
///
/// StoreKit (TASK-2.5.1/2.5.2) supplies the real implementation. Keeping this
/// protocol in PlaybackKit lets the decoder be exercised without a StoreKit
/// transaction, and lets free-tier builds compile the same code.
public protocol ProEntitlementProviding: Sendable {
    /// Whether the current account has unlocked Pro features.
    var isProUnlocked: Bool { get }
}

/// A fixed-value entitlement, useful for tests and previews.
public struct StaticProEntitlement: ProEntitlementProviding, Sendable, Equatable {
    public let isProUnlocked: Bool

    public init(isProUnlocked: Bool) {
        self.isProUnlocked = isProUnlocked
    }

    /// The default free-tier entitlement.
    public static let free = StaticProEntitlement(isProUnlocked: false)

    /// A fully unlocked entitlement.
    public static let pro = StaticProEntitlement(isProUnlocked: true)
}

/// Metadata for one extended codec decoded by FFmpeg.
public struct ExtendedCodecProfile: Sendable, Equatable, Identifiable {
    public var id: String { codec.rawValue }

    /// The normalized codec exposed by ``MediaGraph``.
    public let codec: VideoCodec

    /// Plain-language name shown in the Pro upsell and diagnostics.
    public let displayName: String

    /// The FFmpeg decoder name passed to the XCFramework bridge.
    public let ffmpegDecoderName: String

    /// Whether decoding this codec requires the Pro entitlement.
    public let requiresPro: Bool

    /// Whether the Apple TV media engine can decode this codec natively.
    /// Software decoding is only selected when this is `false` (or when the
    /// hardware decoder rejects the file).
    public let hardwareDecodable: Bool

    public init(
        codec: VideoCodec,
        displayName: String,
        ffmpegDecoderName: String,
        requiresPro: Bool = true,
        hardwareDecodable: Bool = false
    ) {
        self.codec = codec
        self.displayName = displayName
        self.ffmpegDecoderName = ffmpegDecoderName
        self.requiresPro = requiresPro
        self.hardwareDecodable = hardwareDecodable
    }
}

/// Errors surfaced by ``ExtendedCodecsDecoder``.
public enum ExtendedCodecError: Error, Sendable, Equatable, LocalizedError {
    /// The codec is not part of the extended codec set (e.g. H.264/HEVC).
    case notAnExtendedCodec(VideoCodec)

    /// The codec needs Pro but the current account is on the free tier.
    case proRequired(VideoCodec)

    public var errorDescription: String? {
        switch self {
        case .notAnExtendedCodec(let codec):
            return "\(codec.rawValue.uppercased()) is not an extended codec."
        case .proRequired(let codec):
            let name = ExtendedCodecRegistry.profile(for: codec)?.displayName
                ?? codec.rawValue.uppercased()
            return "\(name) playback requires PlayItRight Pro."
        }
    }
}

/// The fixed table of codecs that use the FFmpeg software decoder
/// (PB-G2, doc 04 §2.1, doc 08 §1).
public enum ExtendedCodecRegistry {
    /// Every extended codec, in ladder order.
    public static let profiles: [ExtendedCodecProfile] = [
        ExtendedCodecProfile(
            codec: .av1,
            displayName: "AV1",
            ffmpegDecoderName: "av1",
            // Gen 4 decodes AV1 in hardware; gen 2/3 use the software path.
            hardwareDecodable: true
        ),
        ExtendedCodecProfile(
            codec: .vp8,
            displayName: "VP8",
            ffmpegDecoderName: "vp8"
        ),
        ExtendedCodecProfile(
            codec: .vp9,
            displayName: "VP9",
            ffmpegDecoderName: "vp9"
        ),
        ExtendedCodecProfile(
            codec: .vvc,
            displayName: "VVC / H.266",
            ffmpegDecoderName: "vvc"
        ),
        ExtendedCodecProfile(
            codec: .mpeg1,
            displayName: "MPEG-1",
            ffmpegDecoderName: "mpeg1video"
        ),
        ExtendedCodecProfile(
            codec: .mpeg2,
            displayName: "MPEG-2",
            ffmpegDecoderName: "mpeg2video"
        ),
        ExtendedCodecProfile(
            codec: .vc1,
            displayName: "VC-1",
            ffmpegDecoderName: "vc1"
        ),
        ExtendedCodecProfile(
            codec: .wmv3,
            displayName: "WMV / VC-1 (WMV3)",
            ffmpegDecoderName: "wmv3"
        ),
        ExtendedCodecProfile(
            codec: .divx,
            displayName: "DivX / Xvid",
            ffmpegDecoderName: "mpeg4"
        )
    ]

    /// Look up a codec's profile.
    public static func profile(for codec: VideoCodec) -> ExtendedCodecProfile? {
        profiles.first { $0.codec == codec }
    }

    /// Every codec requiring the extended software path.
    public static var codecs: [VideoCodec] {
        profiles.map(\.codec)
    }
}

/// Routes extended codecs through the FFmpeg software decoder and enforces the
/// Pro entitlement (PB-G2, doc 04 §2.1, doc 08 §1).
///
/// The decoder is a `SoftwareVideoDecoding` so it can be dropped into
/// ``SoftwareTranscodePipeline`` unchanged. H.264 and HEVC are deliberately
/// rejected here: they stay on the hardware/native path.
public struct ExtendedCodecsDecoder: SoftwareVideoDecoding {
    public let decoder: any SoftwareVideoDecoding
    public let entitlement: any ProEntitlementProviding

    public init(
        decoder: any SoftwareVideoDecoding = UnavailableSoftwareVideoDecoder(),
        entitlement: any ProEntitlementProviding = StaticProEntitlement.free
    ) {
        self.decoder = decoder
        self.entitlement = entitlement
    }

    /// Codecs this decoder accepts, after applying the entitlement.
    public var availableCodecs: [VideoCodec] {
        ExtendedCodecRegistry.profiles
            .filter { !$0.requiresPro || entitlement.isProUnlocked }
            .map(\.codec)
    }

    /// Codecs that are supported by the binary but locked on the free tier.
    public var lockedCodecs: [VideoCodec] {
        guard !entitlement.isProUnlocked else {
            return []
        }
        return ExtendedCodecRegistry.profiles
            .filter(\.requiresPro)
            .map(\.codec)
    }

    /// Returns whether the codec is an extended codec at all.
    public func isExtendedCodec(_ codec: VideoCodec) -> Bool {
        ExtendedCodecRegistry.profile(for: codec) != nil
    }

    /// Returns whether the codec can be decoded right now.
    public func canDecode(_ codec: VideoCodec) -> Bool {
        guard let profile = ExtendedCodecRegistry.profile(for: codec) else {
            return false
        }
        return !profile.requiresPro || entitlement.isProUnlocked
    }

    public func decode(
        _ frame: SoftwareVideoFrame,
        codec: VideoCodec,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        guard let profile = ExtendedCodecRegistry.profile(for: codec) else {
            throw ExtendedCodecError.notAnExtendedCodec(codec)
        }
        guard !profile.requiresPro || entitlement.isProUnlocked else {
            throw ExtendedCodecError.proRequired(codec)
        }
        return try decoder.decode(
            frame,
            codec: codec,
            width: width,
            height: height
        )
    }
}
