import Foundation

// MARK: - Features

/// A capability that depends on the Pro tier (BIZ-3, doc 08 §1).
public enum ProFeature: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Free includes one source; adding another needs Pro.
    case additionalSource

    /// Google Drive, Dropbox, OneDrive, and Box.
    case cloudDrive

    /// AV1, VP8/VP9, VVC, MPEG-1/2, VC-1, WMV, DivX, Xvid.
    case extendedVideoCodecs

    /// DTS, DTS-HD Master Audio, Dolby TrueHD, FLAC, ALAC, 24-bit PCM.
    case hdAudio

    /// CloudKit watch-state and library sync.
    case iCloudSync

    /// AirPlay and Google Cast.
    case casting

    /// TMDB trailers.
    case trailers

    public var id: String { rawValue }

    /// The one-line benefit shown on the upsell sheet (BIZ-7).
    public var benefit: String {
        switch self {
        case .additionalSource:
            return "Free includes one source. Pro connects all your servers and shares."
        case .cloudDrive:
            return "Pro streams from Google Drive, Dropbox, OneDrive, and Box."
        case .extendedVideoCodecs:
            return "Pro decodes AV1, VP9, VVC, MPEG-2, VC-1, WMV, DivX, and more."
        case .hdAudio:
            return "Pro plays DTS, DTS-HD Master Audio, Dolby TrueHD, FLAC, and ALAC."
        case .iCloudSync:
            return "Pro syncs watch progress, ratings, and libraries across your Apple TVs."
        case .casting:
            return "Pro sends playback to AirPlay and Google Cast devices."
        case .trailers:
            return "Pro shows trailers for the movies and shows in your library."
        }
    }

    /// A short title for the sheet header.
    public var title: String {
        switch self {
        case .additionalSource:
            return "Add unlimited sources"
        case .cloudDrive:
            return "Connect cloud drives"
        case .extendedVideoCodecs:
            return "Play every video format"
        case .hdAudio:
            return "Unlock lossless audio"
        case .iCloudSync:
            return "Sync across Apple TVs"
        case .casting:
            return "Cast to any screen"
        case .trailers:
            return "Watch trailers"
        }
    }
}

/// The content shown when a Pro gate is hit (BIZ-7).
public struct ProUpsell: Sendable, Equatable {
    public let feature: ProFeature
    public let headline: String
    public let benefit: String
    public let trialMessage: String?

    public init(
        feature: ProFeature,
        headline: String? = nil,
        benefit: String? = nil,
        trialMessage: String? = "Start a 7-day free trial"
    ) {
        self.feature = feature
        self.headline = headline ?? feature.title
        self.benefit = benefit ?? feature.benefit
        self.trialMessage = trialMessage
    }
}

// MARK: - Media profile

/// Video codecs as the gate sees them, independent of PlaybackKit.
public enum ProVideoCodec: String, Codable, Sendable, CaseIterable {
    case h264
    case hevc
    case av1
    case vp8
    case vp9
    case vvc
    case mpeg1
    case mpeg2
    case vc1
    case wmv
    case divx
    case xvid
    case other

    /// H.264 and HEVC play in Free; every other codec is Pro.
    public var isFree: Bool {
        self == .h264 || self == .hevc
    }
}

/// Audio codecs as the gate sees them.
public enum ProAudioCodec: String, Codable, Sendable, CaseIterable {
    case aac
    case ac3
    case eac3
    case atmos
    case pcm
    case mp3
    case opus
    case vorbis
    case dts
    case dtsHD = "dts-hd"
    case trueHD = "truehd"
    case flac
    case alac
    case other

    /// AAC, AC-3, E-AC-3/Atmos, PCM, MP3, Opus, and Vorbis play in Free.
    public var isFree: Bool {
        switch self {
        case .aac, .ac3, .eac3, .atmos, .pcm, .mp3, .opus, .vorbis:
            return true
        case .dts, .dtsHD, .trueHD, .flac, .alac, .other:
            return false
        }
    }
}

/// HDR stays free for everyone (Decision D-1).
public enum ProHDRFormat: String, Codable, Sendable, CaseIterable {
    case sdr
    case hdr10
    case hdr10Plus = "hdr10+"
    case hlg
    case dolbyVision = "dolby-vision"
}

/// The stream attributes relevant to the Pro gate.
///
/// HDR10, HLG, Dolby Vision, and Atmos are deliberately absent from the
/// decision: they always play in Free (D-1).
public struct ProMediaProfile: Sendable, Equatable {
    public var videoCodec: ProVideoCodec?
    public var audioCodec: ProAudioCodec?
    public var hdr: ProHDRFormat
    public var channels: Int
    public var isAtmos: Bool
    public var bitDepth: Int?

    public init(
        videoCodec: ProVideoCodec? = nil,
        audioCodec: ProAudioCodec? = nil,
        hdr: ProHDRFormat = .sdr,
        channels: Int = 2,
        isAtmos: Bool = false,
        bitDepth: Int? = nil
    ) {
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.hdr = hdr
        self.channels = max(1, channels)
        self.isAtmos = isAtmos
        self.bitDepth = bitDepth
    }

    /// The Pro feature this stream needs, or `nil` when Free can play it.
    public var requiredFeature: ProFeature? {
        if let videoCodec, !videoCodec.isFree {
            return .extendedVideoCodecs
        }
        // Atmos rides inside an E-AC-3/TrueHD bitstream; it is always free.
        if isAtmos {
            return nil
        }
        if let audioCodec, !audioCodec.isFree {
            return .hdAudio
        }
        if let bitDepth, bitDepth > 16 {
            return .hdAudio
        }
        return nil
    }
}

// MARK: - Requests and decisions

/// A moment-of-value check (BIZ-7).
public enum ProGateRequest: Sendable, Equatable {
    /// `existingSourceCount` is the number already configured.
    case addSource(existingSourceCount: Int)
    case cloudDrive
    case iCloudSync
    case casting
    case trailers
    case playback(ProMediaProfile)
}

/// The gate's answer.
public enum ProGateDecision: Sendable, Equatable {
    case allowed
    case requiresPro(ProUpsell)

    public var isAllowed: Bool {
        if case .allowed = self {
            return true
        }
        return false
    }

    public var upsell: ProUpsell? {
        guard case .requiresPro(let upsell) = self else {
            return nil
        }
        return upsell
    }

    /// User-facing text for an inline notice, or `nil` when allowed.
    public var explanation: String? {
        upsell?.benefit
    }
}

// MARK: - Entitlement seam

/// The entitlement surface the gate reads.
///
/// ``PurchaseManager`` conforms directly. Tests use a small fake.
@MainActor
public protocol ProEntitlementReading: AnyObject {
    var isProUnlocked: Bool { get }
}

// MARK: - Presentation throttle

/// Persists the BIZ-7 throttle and the per-feature inline-notice flag.
public protocol ProUpsellStateStore: Sendable {
    func lastProactivePresentationDate() -> Date?
    func setLastProactivePresentationDate(_ date: Date?)
    func hasShownInlineNotice(for feature: ProFeature) -> Bool
    func markInlineNoticeShown(for feature: ProFeature)
}

/// UserDefaults-backed throttle state. Times and feature names only.
public final class UserDefaultsProUpsellStateStore: ProUpsellStateStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String

    public init(
        defaults: UserDefaults = .standard,
        prefix: String = "com.playitright.progate"
    ) {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func lastProactivePresentationDate() -> Date? {
        let interval = defaults.double(forKey: "\(prefix).lastProactive")
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    public func setLastProactivePresentationDate(_ date: Date?) {
        guard let date else {
            defaults.removeObject(forKey: "\(prefix).lastProactive")
            return
        }
        defaults.set(date.timeIntervalSince1970, forKey: "\(prefix).lastProactive")
    }

    public func hasShownInlineNotice(for feature: ProFeature) -> Bool {
        defaults.bool(forKey: "\(prefix).inline.\(feature.rawValue)")
    }

    public func markInlineNoticeShown(for feature: ProFeature) {
        defaults.set(true, forKey: "\(prefix).inline.\(feature.rawValue)")
    }
}

/// In-memory throttle state for tests and previews.
public final class InMemoryProUpsellStateStore: ProUpsellStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var lastDate: Date?
    private var inlineNotices: Set<ProFeature> = []

    public init(lastProactivePresentation: Date? = nil) {
        self.lastDate = lastProactivePresentation
    }

    public func lastProactivePresentationDate() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return lastDate
    }

    public func setLastProactivePresentationDate(_ date: Date?) {
        lock.lock()
        defer { lock.unlock() }
        lastDate = date
    }

    public func hasShownInlineNotice(for feature: ProFeature) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inlineNotices.contains(feature)
    }

    public func markInlineNoticeShown(for feature: ProFeature) {
        lock.lock()
        defer { lock.unlock() }
        inlineNotices.insert(feature)
    }
}

// MARK: - Gate

/// Enforces the free/Pro split at the moment a viewer asks for a feature
/// (BIZ-3, BIZ-7).
///
/// The gate never mutates libraries, watch state, preferences, or sources. It
/// only answers whether an action can proceed, so expired subscribers keep
/// their data and simply lose Pro-gated behaviors.
@MainActor
public final class ProGate {
    /// One proactive upsell sheet per day; after that, show a badge only.
    public static let proactiveInterval: TimeInterval = 86_400

    private let entitlement: any ProEntitlementReading
    private let clock: any EntitlementClock
    private let state: any ProUpsellStateStore

    public init(
        entitlement: any ProEntitlementReading,
        clock: any EntitlementClock = SystemEntitlementClock(),
        state: any ProUpsellStateStore = UserDefaultsProUpsellStateStore()
    ) {
        self.entitlement = entitlement
        self.clock = clock
        self.state = state
    }

    public var isProUnlocked: Bool {
        entitlement.isProUnlocked
    }

    /// Evaluates a request without presenting anything.
    public func evaluate(_ request: ProGateRequest) -> ProGateDecision {
        guard !isProUnlocked else {
            return .allowed
        }

        switch request {
        case .addSource(let existingSourceCount):
            // Free includes one source of any kind.
            guard existingSourceCount >= 1 else {
                return .allowed
            }
            return .requiresPro(ProUpsell(feature: .additionalSource))

        case .cloudDrive:
            return .requiresPro(ProUpsell(feature: .cloudDrive))

        case .iCloudSync:
            return .requiresPro(ProUpsell(feature: .iCloudSync))

        case .casting:
            return .requiresPro(ProUpsell(feature: .casting))

        case .trailers:
            return .requiresPro(ProUpsell(feature: .trailers))

        case .playback(let profile):
            guard let feature = profile.requiredFeature else {
                return .allowed
            }
            return .requiresPro(ProUpsell(feature: feature))
        }
    }

    /// Whether the app may open the full upsell sheet now (BIZ-7).
    public func shouldPresentProactiveUpsell() -> Bool {
        guard !isProUnlocked else {
            return false
        }
        guard let last = state.lastProactivePresentationDate() else {
            return true
        }
        let elapsed = clock.now.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= Self.proactiveInterval
    }

    /// Records a proactive presentation so the next one waits a day.
    public func recordProactiveUpsellPresentation() {
        state.setLastProactivePresentationDate(clock.now)
    }

    /// Whether an inline notice still needs to be shown for this feature.
    /// Each feature gets one notice, then only the badge (BIZ-3, BIZ-7).
    public func shouldShowInlineNotice(for feature: ProFeature) -> Bool {
        !isProUnlocked && !state.hasShownInlineNotice(for: feature)
    }

    public func markInlineNoticeShown(for feature: ProFeature) {
        state.markInlineNoticeShown(for: feature)
    }

    /// Clears the throttle and inline-notice history.
    public func resetPresentationHistory() {
        state.setLastProactivePresentationDate(nil)
    }
}
