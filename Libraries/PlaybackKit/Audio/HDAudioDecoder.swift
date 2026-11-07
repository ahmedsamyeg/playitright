import Foundation

/// One compressed HD audio access unit handed to the software decoder.
public struct HDAudioPacket: Sendable, Equatable {
    /// Codec bitstream bytes, without container framing.
    public var data: Data

    /// Presentation time in seconds.
    public var presentationTime: TimeInterval

    /// Source sample rate in Hz.
    public var sampleRate: Int

    /// Source channel order, using the same order as the bitstream.
    public var layout: AudioChannelLayout

    /// Whether the packet carries an Atmos object layer above its bed.
    public var isAtmos: Bool

    public init(
        data: Data,
        presentationTime: TimeInterval = 0,
        sampleRate: Int = 48_000,
        layout: AudioChannelLayout = .surround71,
        isAtmos: Bool = false
    ) {
        self.data = data
        self.presentationTime = presentationTime
        self.sampleRate = max(1, sampleRate)
        self.layout = layout
        self.isAtmos = isAtmos
    }
}

/// Raw, interleaved float PCM produced by an HD audio decoder.
public struct HDAudioPCMBuffer: Sendable, Equatable {
    /// Interleaved samples in source channel order.
    public var samples: [Float]

    /// Sample rate in Hz.
    public var sampleRate: Int

    /// Source channel order.
    public var layout: AudioChannelLayout

    /// Whether the decoder extracted an Atmos bed (the object layer is
    /// discarded, as required for TrueHD on tvOS).
    public var isAtmosBed: Bool

    public init(
        samples: [Float],
        sampleRate: Int,
        layout: AudioChannelLayout,
        isAtmosBed: Bool = false
    ) {
        self.samples = samples
        self.sampleRate = max(1, sampleRate)
        self.layout = layout
        self.isAtmosBed = isAtmosBed
    }

    /// Number of interleaved frames in the buffer.
    public var frameCount: Int {
        guard layout.channelCount > 0 else {
            return 0
        }
        return samples.count / layout.channelCount
    }
}

/// The software-decoding seam for DTS, DTS-HD MA, and Dolby TrueHD.
///
/// FFmpeg supplies the implementation when the XCFramework is linked. Tests
/// substitute a decoder without the binary, mirroring the other PlaybackKit
/// seams.
public protocol HDAudioDecoding: Sendable {
    func decode(
        _ packet: HDAudioPacket,
        codec: AudioCodec
    ) throws -> HDAudioPCMBuffer
}

/// Placeholder used when the FFmpeg XCFramework is not linked.
public struct UnavailableHDAudioDecoder: HDAudioDecoding {
    public init() {}

    public func decode(
        _ packet: HDAudioPacket,
        codec: AudioCodec
    ) throws -> HDAudioPCMBuffer {
        throw StreamProbeError.ffmpegUnavailable
    }
}

/// The result of decoding and downmixing one HD audio packet.
public struct HDAudioDecodeResult: Sendable, Equatable {
    /// Interleaved LPCM in ``outputLayout`` channel order.
    public var samples: [Float]

    /// Sample rate in Hz.
    public var sampleRate: Int

    /// Source channel order.
    public var inputLayout: AudioChannelLayout

    /// Delivered channel order.
    public var outputLayout: AudioChannelLayout

    /// Whether the decoder extracted an Atmos bed.
    public var isAtmosBed: Bool

    /// Whether channel folding was applied.
    public var wasDownmixed: Bool

    public init(
        samples: [Float],
        sampleRate: Int,
        inputLayout: AudioChannelLayout,
        outputLayout: AudioChannelLayout,
        isAtmosBed: Bool,
        wasDownmixed: Bool
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.inputLayout = inputLayout
        self.outputLayout = outputLayout
        self.isAtmosBed = isAtmosBed
        self.wasDownmixed = wasDownmixed
    }

    public var outputChannels: Int {
        outputLayout.channelCount
    }

    public var frameCount: Int {
        guard outputLayout.channelCount > 0 else {
            return 0
        }
        return samples.count / outputLayout.channelCount
    }
}

/// Errors surfaced by ``HDAudioDecoder``.
public enum HDAudioError: Error, Sendable, Equatable, LocalizedError {
    /// The codec is not an HD audio codec.
    case notAnHDAudioCodec(AudioCodec)

    /// The codec needs Pro but the account is on the free tier.
    case proRequired(AudioCodec)

    public var errorDescription: String? {
        switch self {
        case .notAnHDAudioCodec(let codec):
            return "\(codec.rawValue.uppercased()) is not an HD audio codec."
        case .proRequired(let codec):
            return "\(HDAudioDecoder.displayName(for: codec)) playback requires PlayItRight Pro."
        }
    }
}

/// Decodes DTS, DTS-HD MA, and Dolby TrueHD through FFmpeg and folds the
/// result to the sink's channel limit using ITU-R BS.775 (PB-12, doc 04 §2.2,
/// doc 08 §1).
///
/// TrueHD Atmos is delivered as its channel bed: the object layer cannot be
/// rendered by tvOS, so it is discarded and the bed is downmixed normally.
public struct HDAudioDecoder: Sendable {
    /// Codecs handled by the FFmpeg software decoder.
    public static let supportedCodecs: [AudioCodec] = [.dts, .dtsHD, .truehd]

    public let decoder: any HDAudioDecoding
    public let entitlement: any ProEntitlementProviding

    public init(
        decoder: any HDAudioDecoding = UnavailableHDAudioDecoder(),
        entitlement: any ProEntitlementProviding = StaticProEntitlement.free
    ) {
        self.decoder = decoder
        self.entitlement = entitlement
    }

    /// Plain-language name for a codec.
    public static func displayName(for codec: AudioCodec) -> String {
        switch codec {
        case .dts:
            return "DTS"
        case .dtsHD:
            return "DTS-HD Master Audio"
        case .truehd:
            return "Dolby TrueHD"
        default:
            return codec.rawValue.uppercased()
        }
    }

    public func isHDAudioCodec(_ codec: AudioCodec) -> Bool {
        Self.supportedCodecs.contains(codec)
    }

    /// Whether the codec can be decoded right now.
    public func canDecode(_ codec: AudioCodec) -> Bool {
        isHDAudioCodec(codec) && entitlement.isProUnlocked
    }

    /// Decodes one packet and folds it to at most `targetChannels` channels.
    ///
    /// A target of 2 produces stereo, 3...6 produces 5.1, and 7 or more keeps
    /// the decoded layout (including a 7.1 Atmos bed).
    public func decode(
        _ packet: HDAudioPacket,
        codec: AudioCodec,
        targetChannels: Int
    ) throws -> HDAudioDecodeResult {
        guard isHDAudioCodec(codec) else {
            throw HDAudioError.notAnHDAudioCodec(codec)
        }
        guard entitlement.isProUnlocked else {
            throw HDAudioError.proRequired(codec)
        }

        let decoded = try decoder.decode(packet, codec: codec)
        let outputLayout = Self.outputLayout(
            for: targetChannels,
            inputLayout: decoded.layout
        )
        let wasDownmixed = outputLayout != decoded.layout

        guard wasDownmixed else {
            return HDAudioDecodeResult(
                samples: decoded.samples,
                sampleRate: decoded.sampleRate,
                inputLayout: decoded.layout,
                outputLayout: decoded.layout,
                isAtmosBed: decoded.isAtmosBed,
                wasDownmixed: false
            )
        }

        let matrix = AudioDownmixMatrix.ituBS775(
            from: decoded.layout,
            to: outputLayout
        )
        let inputChannels = decoded.layout.channelCount
        let frames = inputChannels > 0
            ? decoded.samples.count / inputChannels
            : 0
        var output: [Float] = []
        output.reserveCapacity(frames * matrix.outputChannelCount)

        if inputChannels > 0 {
            for frameIndex in 0..<frames {
                let start = frameIndex * inputChannels
                let frame = Array(
                    decoded.samples[start..<(start + inputChannels)]
                )
                output.append(contentsOf: matrix.mix(frame))
            }
        }

        return HDAudioDecodeResult(
            samples: output,
            sampleRate: decoded.sampleRate,
            inputLayout: decoded.layout,
            outputLayout: outputLayout,
            isAtmosBed: decoded.isAtmosBed,
            wasDownmixed: true
        )
    }

    /// The delivery layout for a sink channel limit.
    public static func outputLayout(
        for targetChannels: Int,
        inputLayout: AudioChannelLayout
    ) -> AudioChannelLayout {
        switch targetChannels {
        case ..<3:
            return .stereo
        case 3...6:
            return .surround51
        default:
            return inputLayout
        }
    }
}
