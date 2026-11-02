import Foundation

/// The playback ladder, in preference order (doc 04 §4.2).
public enum PipelineRung: String, Codable, Sendable, CaseIterable, Comparable {
    case r1Direct = "r1"
    case r2Remux = "r2"
    case r3HardwareTranscode = "r3"
    case r4SoftwareTranscode = "r4"
    case r5ServerTranscode = "r5"

    public var rank: Int {
        switch self {
        case .r1Direct:
            return 1
        case .r2Remux:
            return 2
        case .r3HardwareTranscode:
            return 3
        case .r4SoftwareTranscode:
            return 4
        case .r5ServerTranscode:
            return 5
        }
    }

    public var displayName: String {
        switch self {
        case .r1Direct:
            return "Direct Play"
        case .r2Remux:
            return "Remux"
        case .r3HardwareTranscode:
            return "Hardware Transcode"
        case .r4SoftwareTranscode:
            return "Software Transcode"
        case .r5ServerTranscode:
            return "Server Transcode"
        }
    }

    public static func < (lhs: PipelineRung, rhs: PipelineRung) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// How the planner intends to produce video frames.
public enum VideoDecodePath: String, Codable, Sendable, CaseIterable {
    case hardware
    case software
    case none
}

/// What happens to the color pipeline before the display sees a frame.
public enum ColorTransform: String, Codable, Sendable, CaseIterable {
    case none
    case systemToneMap
    case stripDolbyVisionRPU
    case dolbyVisionMetadataConversion
    case explicitToneMap
    case hlgToSDR

    public var displayName: String {
        switch self {
        case .none:
            return "No transform"
        case .systemToneMap:
            return "System tone-map"
        case .stripDolbyVisionRPU:
            return "Strip Dolby Vision RPU (base layer as HDR10)"
        case .dolbyVisionMetadataConversion:
            return "Dolby Vision metadata conversion"
        case .explicitToneMap:
            return "Explicit HDR → SDR tone-map"
        case .hlgToSDR:
            return "HLG → SDR tone-map"
        }
    }
}

/// How the selected audio track reaches the sink.
public enum AudioRoute: String, Codable, Sendable, CaseIterable {
    case passthrough
    case nativeDecode
    case softwareDecode
    case downmixToStereo
    case downmixTo51 = "downmix-to-5.1"

    public var needsSoftwareDecode: Bool {
        self == .softwareDecode
            || self == .downmixToStereo
            || self == .downmixTo51
    }
}

/// The user's quality and color preferences (doc 04 §4.3).
public struct PlaybackPreferences: Codable, Sendable, Equatable {
    public enum QualityBias: String, Codable, Sendable, CaseIterable {
        case bestQuality
        case balanced
        case lowestCPU
    }

    public enum ColorMode: String, Codable, Sendable, CaseIterable {
        case system
        case precise
        case off
    }

    /// Caps the ladder. Never forces a rung below what is feasible.
    public var maximumRung: PipelineRung?
    public var qualityBias: QualityBias
    public var colorMode: ColorMode
    public var preferServerTranscode: Bool
    public var targetPeakNits: Double

    public init(
        maximumRung: PipelineRung? = nil,
        qualityBias: QualityBias = .balanced,
        colorMode: ColorMode = .system,
        preferServerTranscode: Bool = false,
        targetPeakNits: Double = 100
    ) {
        self.maximumRung = maximumRung
        self.qualityBias = qualityBias
        self.colorMode = colorMode
        self.preferServerTranscode = preferServerTranscode
        self.targetPeakNits = targetPeakNits
    }
}

/// The video half of a plan.
public struct VideoPipelinePlan: Codable, Sendable, Equatable {
    public var inputCodec: String
    public var outputCodec: String
    public var inputContainer: ContainerFormat
    public var outputContainer: ContainerFormat
    public var decodePath: VideoDecodePath
    public var colorTransform: ColorTransform
    public var inputHDR: HDRFormat
    public var outputHDR: HDRFormat
    public var bitDepth: Int
    public var width: Int
    public var height: Int

    public init(
        inputCodec: String,
        outputCodec: String,
        inputContainer: ContainerFormat,
        outputContainer: ContainerFormat,
        decodePath: VideoDecodePath,
        colorTransform: ColorTransform,
        inputHDR: HDRFormat,
        outputHDR: HDRFormat,
        bitDepth: Int,
        width: Int,
        height: Int
    ) {
        self.inputCodec = inputCodec
        self.outputCodec = outputCodec
        self.inputContainer = inputContainer
        self.outputContainer = outputContainer
        self.decodePath = decodePath
        self.colorTransform = colorTransform
        self.inputHDR = inputHDR
        self.outputHDR = outputHDR
        self.bitDepth = bitDepth
        self.width = width
        self.height = height
    }
}

/// The audio half of a plan.
public struct AudioPipelinePlan: Codable, Sendable, Equatable {
    public var inputCodec: String
    public var outputCodec: String
    public var route: AudioRoute
    public var channels: Int
    public var outputChannels: Int
    public var isAtmos: Bool
    public var language: String?

    public init(
        inputCodec: String,
        outputCodec: String,
        route: AudioRoute,
        channels: Int,
        outputChannels: Int,
        isAtmos: Bool,
        language: String? = nil
    ) {
        self.inputCodec = inputCodec
        self.outputCodec = outputCodec
        self.route = route
        self.channels = channels
        self.outputChannels = outputChannels
        self.isAtmos = isAtmos
        self.language = language
    }
}

/// A complete, deterministic plan emitted before the first frame (PB-5/PB-7).
public struct PipelinePlan: Codable, Sendable, Equatable {
    public var rung: PipelineRung
    public var badge: QualityBadge
    public var video: VideoPipelinePlan
    public var audio: AudioPipelinePlan?
    public var reasons: [String]
    public var isPlayable: Bool
    public var isServerTranscode: Bool
    public var colorMode: PlaybackPreferences.ColorMode
    public var qualityBias: PlaybackPreferences.QualityBias
    public var rungCapApplied: Bool

    public init(
        rung: PipelineRung,
        badge: QualityBadge,
        video: VideoPipelinePlan,
        audio: AudioPipelinePlan? = nil,
        reasons: [String] = [],
        isPlayable: Bool = true,
        isServerTranscode: Bool = false,
        colorMode: PlaybackPreferences.ColorMode = .system,
        qualityBias: PlaybackPreferences.QualityBias = .balanced,
        rungCapApplied: Bool = false
    ) {
        self.rung = rung
        self.badge = badge
        self.video = video
        self.audio = audio
        self.reasons = reasons
        self.isPlayable = isPlayable
        self.isServerTranscode = isServerTranscode
        self.colorMode = colorMode
        self.qualityBias = qualityBias
        self.rungCapApplied = rungCapApplied
    }
}
