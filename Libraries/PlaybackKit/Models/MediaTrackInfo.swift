import Foundation
import LibraryCore

/// A container the playback engine can read.
public enum ContainerFormat: String, Codable, Sendable, CaseIterable {
    case mp4
    case mov
    case m4v
    case threeGP = "3gp"
    case mkv
    case webm
    case avi
    case ts
    case m2ts
    case mts
    case flv
    case asf
    case wmv
    case ogg
    case ogv
    case vob
    case mpg
    case other

    public init(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "mp4":
            self = .mp4
        case "mov":
            self = .mov
        case "m4v":
            self = .m4v
        case "3gp", "3gpp":
            self = .threeGP
        case "mkv":
            self = .mkv
        case "webm":
            self = .webm
        case "avi":
            self = .avi
        case "ts":
            self = .ts
        case "m2ts":
            self = .m2ts
        case "mts":
            self = .mts
        case "flv":
            self = .flv
        case "asf":
            self = .asf
        case "wmv":
            self = .wmv
        case "ogg":
            self = .ogg
        case "ogv":
            self = .ogv
        case "vob":
            self = .vob
        case "mpg", "mpeg":
            self = .mpg
        default:
            self = .other
        }
    }

    public init(url: URL) {
        self.init(pathExtension: url.pathExtension)
    }

    /// Containers AVFoundation can demux directly (doc 04 §2.4).
    public var isAVFoundationNative: Bool {
        switch self {
        case .mp4, .mov, .m4v, .threeGP:
            return true
        default:
            return false
        }
    }
}

/// The demuxer that produced a ``MediaGraph``.
public enum DemuxerKind: String, Codable, Sendable, CaseIterable {
    case avFoundation = "avfoundation"
    case ffmpeg
}

public enum MediaTrackKind: String, Codable, Sendable, CaseIterable {
    case video
    case audio
    case subtitle
    case chapter
}

public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case h264
    case hevc
    case av1
    case vp8
    case vp9
    case vvc
    case mpeg1
    case mpeg2
    case vc1
    case wmv3
    case divx
    case other
}

public enum AudioCodec: String, Codable, Sendable, CaseIterable {
    case aac
    case ac3
    case eac3
    case truehd
    case dts
    case dtsHD = "dts-hd"
    case flac
    case alac
    case mp3
    case opus
    case vorbis
    case pcm
    case wma
    case other
}

public enum SubtitleFormat: String, Codable, Sendable, CaseIterable {
    case srt
    case ass
    case ssa
    case webvtt
    case pgs
    case vobsub
    case dvbsub
    case movText = "mov-text"
    case ttml
    case other
}

/// The color/HDR pipeline a display must be able to accept (PB-4, doc 04 §4.1).
public enum HDRFormat: String, Codable, Sendable, CaseIterable {
    case sdr
    case hdr10
    case hdr10Plus = "hdr10plus"
    case hlg
    case dolbyVision5 = "dovi:5"
    case dolbyVision8 = "dovi:8"
    case dolbyVision81 = "dovi:8.1"

    public var isDolbyVision: Bool {
        switch self {
        case .dolbyVision5, .dolbyVision8, .dolbyVision81:
            return true
        default:
            return false
        }
    }

    public var dolbyVisionProfile: Int? {
        switch self {
        case .dolbyVision5:
            return 5
        case .dolbyVision8, .dolbyVision81:
            return 8
        default:
            return nil
        }
    }

    /// Exact profile value, including 8.1 (CapKit keys Dolby Vision by `Double`).
    public var dolbyVisionProfileValue: Double? {
        switch self {
        case .dolbyVision5:
            return 5
        case .dolbyVision8:
            return 8
        case .dolbyVision81:
            return 8.1
        default:
            return nil
        }
    }
}

public enum ColorPrimaries: String, Codable, Sendable, CaseIterable {
    case bt709
    case bt2020
    case displayP3
    case other
}

public enum TransferFunction: String, Codable, Sendable, CaseIterable {
    case sdr
    case pq
    case hlg
    case other
}

public enum ColorMatrix: String, Codable, Sendable, CaseIterable {
    case bt709
    case bt2020NonConstant = "bt2020nc"
    case bt2020Constant = "bt2020c"
    case other
}

/// A rational frame rate, kept exact so `TrackRecord.fpsNum/fpsDen` is lossless.
public struct FrameRate: Codable, Sendable, Equatable, Hashable {
    public var numerator: Int
    public var denominator: Int

    public init(numerator: Int, denominator: Int) {
        if numerator <= 0 || denominator <= 0 {
            self.numerator = 0
            self.denominator = 1
            return
        }
        let divisor = Self.greatestCommonDivisor(numerator, denominator)
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    public init(fps: Double) {
        let known: [(Double, Int, Int)] = [
            (23.976, 24_000, 1_001),
            (29.97, 30_000, 1_001),
            (59.94, 60_000, 1_001),
            (119.88, 120_000, 1_001)
        ]
        if let match = known.first(where: {
            abs($0.0 - fps) < 0.01
        }) {
            self.init(numerator: match.1, denominator: match.2)
            return
        }
        self.init(
            numerator: Int((fps * 1_000).rounded()),
            denominator: 1_000
        )
    }

    public var value: Double {
        guard denominator != 0 else {
            return 0
        }
        return Double(numerator) / Double(denominator)
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return max(1, a)
    }
}

public struct VideoTrackInfo: Codable, Sendable, Equatable {
    public var index: Int
    public var codec: VideoCodec
    public var codecID: String
    public var profile: String?
    public var level: String?
    public var width: Int
    public var height: Int
    public var frameRate: FrameRate
    public var bitDepth: Int?
    public var bitrate: Int?
    public var colorPrimaries: ColorPrimaries
    public var transferFunction: TransferFunction
    public var colorMatrix: ColorMatrix
    public var hdrFormat: HDRFormat
    public var hasDolbyVisionRPU: Bool
    public var hasHDR10PlusMetadata: Bool
    public var isInterlaced: Bool
    public var isDefault: Bool

    public init(
        index: Int,
        codec: VideoCodec,
        codecID: String = "",
        profile: String? = nil,
        level: String? = nil,
        width: Int,
        height: Int,
        frameRate: FrameRate = FrameRate(numerator: 0, denominator: 1),
        bitDepth: Int? = nil,
        bitrate: Int? = nil,
        colorPrimaries: ColorPrimaries = .bt709,
        transferFunction: TransferFunction = .sdr,
        colorMatrix: ColorMatrix = .bt709,
        hdrFormat: HDRFormat = .sdr,
        hasDolbyVisionRPU: Bool = false,
        hasHDR10PlusMetadata: Bool = false,
        isInterlaced: Bool = false,
        isDefault: Bool = true
    ) {
        self.index = index
        self.codec = codec
        self.codecID = codecID
        self.profile = profile
        self.level = level
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitDepth = bitDepth
        self.bitrate = bitrate
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.colorMatrix = colorMatrix
        self.hdrFormat = hdrFormat
        self.hasDolbyVisionRPU = hasDolbyVisionRPU
        self.hasHDR10PlusMetadata = hasHDR10PlusMetadata
        self.isInterlaced = isInterlaced
        self.isDefault = isDefault
    }
}

public struct AudioTrackInfo: Codable, Sendable, Equatable {
    public var index: Int
    public var codec: AudioCodec
    public var codecID: String
    public var channels: Int
    public var channelLayout: String?
    public var sampleRate: Int
    public var bitDepth: Int?
    public var bitrate: Int?
    public var isAtmos: Bool
    public var isDefault: Bool
    public var language: String?
    public var title: String?

    public init(
        index: Int,
        codec: AudioCodec,
        codecID: String = "",
        channels: Int,
        channelLayout: String? = nil,
        sampleRate: Int,
        bitDepth: Int? = nil,
        bitrate: Int? = nil,
        isAtmos: Bool = false,
        isDefault: Bool = false,
        language: String? = nil,
        title: String? = nil
    ) {
        self.index = index
        self.codec = codec
        self.codecID = codecID
        self.channels = channels
        self.channelLayout = channelLayout
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.bitrate = bitrate
        self.isAtmos = isAtmos
        self.isDefault = isDefault
        self.language = language
        self.title = title
    }
}

public struct SubtitleTrackInfo: Codable, Sendable, Equatable {
    public var index: Int
    public var format: SubtitleFormat
    public var formatID: String
    public var language: String?
    public var title: String?
    public var isForced: Bool
    public var isDefault: Bool
    public var isImageBased: Bool

    public init(
        index: Int,
        format: SubtitleFormat,
        formatID: String = "",
        language: String? = nil,
        title: String? = nil,
        isForced: Bool = false,
        isDefault: Bool = false,
        isImageBased: Bool = false
    ) {
        self.index = index
        self.format = format
        self.formatID = formatID
        self.language = language
        self.title = title
        self.isForced = isForced
        self.isDefault = isDefault
        self.isImageBased = isImageBased
    }
}

public struct ChapterInfo: Codable, Sendable, Equatable {
    public var index: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval?
    public var title: String?

    public init(
        index: Int,
        startTime: TimeInterval,
        endTime: TimeInterval? = nil,
        title: String? = nil
    ) {
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
    }
}

/// A type-erased stream from a probe.
public enum MediaTrackInfo: Codable, Sendable, Equatable {
    case video(VideoTrackInfo)
    case audio(AudioTrackInfo)
    case subtitle(SubtitleTrackInfo)
    case chapter(ChapterInfo)

    public var index: Int {
        switch self {
        case .video(let track):
            return track.index
        case .audio(let track):
            return track.index
        case .subtitle(let track):
            return track.index
        case .chapter(let chapter):
            return chapter.index
        }
    }

    public var kind: MediaTrackKind {
        switch self {
        case .video:
            return .video
        case .audio:
            return .audio
        case .subtitle:
            return .subtitle
        case .chapter:
            return .chapter
        }
    }
}
