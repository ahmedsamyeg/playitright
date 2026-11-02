import Foundation

/// The user-declared display capability shown in Settings (doc 04 §3).
public enum DisplayOverride: String, Codable, Sendable, CaseIterable {
    case sdr
    case hdr10
    case hlg
    case dolbyVision

    public var displayName: String {
        switch self {
        case .sdr:
            return "SDR"
        case .hdr10:
            return "HDR10"
        case .hlg:
            return "HLG"
        case .dolbyVision:
            return "Dolby Vision"
        }
    }
}

/// The authoritative audio setup. tvOS cannot read HDMI sink capabilities,
/// so this is user-declared with an observed route as the default (PB-4).
public enum AudioSetup: String, Codable, Sendable, CaseIterable {
    case stereo
    case receiverAC3 = "receiver-ac3"
    case receiverAtmos = "receiver-atmos"
    case homePod = "homepod"
    case speakers
    case headphones

    public var displayName: String {
        switch self {
        case .stereo:
            return "Stereo"
        case .receiverAC3:
            return "Receiver (AC3)"
        case .receiverAtmos:
            return "Receiver (Atmos)"
        case .homePod:
            return "HomePod"
        case .speakers:
            return "TV Speakers"
        case .headphones:
            return "Headphones"
        }
    }
}

/// Display capabilities used by the pipeline planner.
public struct DisplayCapabilities: Codable, Sendable, Equatable {
    public var supportsSDR: Bool
    public var supportsHDR10: Bool
    public var supportsHLG: Bool
    public var supportsDolbyVision: Bool
    public var width: Int
    public var height: Int
    public var maxRefreshRate: Double
    public var currentRefreshRate: Double

    public init(
        supportsSDR: Bool = true,
        supportsHDR10: Bool = false,
        supportsHLG: Bool = false,
        supportsDolbyVision: Bool = false,
        width: Int = 1_920,
        height: Int = 1_080,
        maxRefreshRate: Double = 60,
        currentRefreshRate: Double = 60
    ) {
        self.supportsSDR = supportsSDR
        self.supportsHDR10 = supportsHDR10
        self.supportsHLG = supportsHLG
        self.supportsDolbyVision = supportsDolbyVision
        self.width = width
        self.height = height
        self.maxRefreshRate = maxRefreshRate
        self.currentRefreshRate = currentRefreshRate
    }

    public var is4K: Bool {
        width >= 3_840 && height >= 2_160
    }

    public var maxHDRFormat: HDRFormat {
        if supportsDolbyVision {
            return .dolbyVision8
        }
        if supportsHDR10 {
            return .hdr10
        }
        if supportsHLG {
            return .hlg
        }
        return .sdr
    }

    /// The capabilities implied by a user declaration.
    public static func declared(
        _ override: DisplayOverride,
        width: Int = 3_840,
        height: Int = 2_160,
        refreshRate: Double = 60
    ) -> DisplayCapabilities {
        switch override {
        case .sdr:
            return DisplayCapabilities(
                supportsSDR: true,
                width: width,
                height: height,
                maxRefreshRate: refreshRate,
                currentRefreshRate: refreshRate
            )
        case .hdr10:
            return DisplayCapabilities(
                supportsHDR10: true,
                width: width,
                height: height,
                maxRefreshRate: refreshRate,
                currentRefreshRate: refreshRate
            )
        case .hlg:
            return DisplayCapabilities(
                supportsHLG: true,
                width: width,
                height: height,
                maxRefreshRate: refreshRate,
                currentRefreshRate: refreshRate
            )
        case .dolbyVision:
            return DisplayCapabilities(
                supportsHDR10: true,
                supportsHLG: true,
                supportsDolbyVision: true,
                width: width,
                height: height,
                maxRefreshRate: refreshRate,
                currentRefreshRate: refreshRate
            )
        }
    }
}

/// Audio output capabilities used by the pipeline planner.
public struct AudioCapabilities: Codable, Sendable, Equatable {
    public var setup: AudioSetup
    public var maxChannels: Int
    public var supportsAtmos: Bool
    public var passthroughCodecs: Set<AudioCodec>
    public var routeName: String?

    public init(
        setup: AudioSetup,
        maxChannels: Int,
        supportsAtmos: Bool,
        passthroughCodecs: Set<AudioCodec> = [],
        routeName: String? = nil
    ) {
        self.setup = setup
        self.maxChannels = maxChannels
        self.supportsAtmos = supportsAtmos
        self.passthroughCodecs = passthroughCodecs
        self.routeName = routeName
    }

    public func canPassthrough(_ codec: AudioCodec) -> Bool {
        passthroughCodecs.contains(codec)
    }

    public static func declared(
        _ setup: AudioSetup,
        routeName: String? = nil
    ) -> AudioCapabilities {
        switch setup {
        case .stereo, .headphones:
            return AudioCapabilities(
                setup: setup,
                maxChannels: 2,
                supportsAtmos: false,
                routeName: routeName
            )
        case .speakers:
            return AudioCapabilities(
                setup: setup,
                maxChannels: 2,
                supportsAtmos: false,
                routeName: routeName
            )
        case .receiverAC3:
            return AudioCapabilities(
                setup: setup,
                maxChannels: 6,
                supportsAtmos: false,
                passthroughCodecs: [.ac3, .eac3],
                routeName: routeName
            )
        case .receiverAtmos:
            return AudioCapabilities(
                setup: setup,
                maxChannels: 8,
                supportsAtmos: true,
                passthroughCodecs: [.ac3, .eac3],
                routeName: routeName
            )
        case .homePod:
            return AudioCapabilities(
                setup: setup,
                maxChannels: 2,
                supportsAtmos: true,
                passthroughCodecs: [.eac3],
                routeName: routeName
            )
        }
    }
}

/// The effective sink after merging observed system state with user overrides.
public struct SinkProfile: Codable, Sendable, Equatable {
    public var display: DisplayCapabilities
    public var audio: AudioCapabilities
    public var declaredDisplay: DisplayOverride?
    public var declaredAudio: AudioSetup?
    public var updatedAt: Date

    public init(
        display: DisplayCapabilities,
        audio: AudioCapabilities,
        declaredDisplay: DisplayOverride? = nil,
        declaredAudio: AudioSetup? = nil,
        updatedAt: Date = Date()
    ) {
        self.display = display
        self.audio = audio
        self.declaredDisplay = declaredDisplay
        self.declaredAudio = declaredAudio
        self.updatedAt = updatedAt
    }

    public var hasUserOverrides: Bool {
        declaredDisplay != nil || declaredAudio != nil
    }
}

/// User declarations from Settings. `nil` means "use the observed value".
public struct SinkOverrides: Codable, Sendable, Equatable {
    public var display: DisplayOverride?
    public var audio: AudioSetup?

    public init(
        display: DisplayOverride? = nil,
        audio: AudioSetup? = nil
    ) {
        self.display = display
        self.audio = audio
    }
}
