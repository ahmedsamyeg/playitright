import Foundation

// MARK: - Devices

/// A Cast receiver the app can send playback to (SYNC-7).
public struct GoogleCastDevice: Sendable, Equatable, Identifiable {
    /// The receiver family, used to pick conservative default capabilities.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case chromecast
        case chromecastUltra
        case chromecastAudio
        case googleTV
        case other

        /// Capabilities assumed before the receiver reports its own.
        public var defaultCapabilities: GoogleCastCapabilities {
            switch self {
            case .chromecast:
                return .chromecast
            case .chromecastUltra:
                return .chromecastUltra
            case .chromecastAudio:
                return .chromecastAudio
            case .googleTV:
                return .googleTV
            case .other:
                return .chromecast
            }
        }
    }

    /// Stable receiver id reported by discovery.
    public var id: String

    /// Friendly name shown in the destination picker.
    public var name: String

    public var kind: Kind

    /// Media capabilities reported by the receiver.
    public var capabilities: GoogleCastCapabilities

    /// Whether the receiver is currently answering on the network.
    public var isReachable: Bool

    public init(
        id: String,
        name: String,
        kind: Kind = .other,
        capabilities: GoogleCastCapabilities? = nil,
        isReachable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.capabilities = capabilities ?? kind.defaultCapabilities
        self.isReachable = isReachable
    }
}

/// What a Cast receiver can decode. Receivers differ widely, so negotiation is
/// explicit rather than assuming Chromecast Ultra behavior everywhere.
public struct GoogleCastCapabilities: Sendable, Equatable {
    public var containers: Set<ContainerFormat>
    public var videoCodecs: Set<VideoCodec>
    public var audioCodecs: Set<AudioCodec>
    public var maxAudioChannels: Int
    public var supportsHDR10: Bool
    public var supportsDolbyVision: Bool

    /// Audio-only receivers (Chromecast Audio, speaker groups) reject video.
    public var supportsAudioOnly: Bool

    public init(
        containers: Set<ContainerFormat>,
        videoCodecs: Set<VideoCodec>,
        audioCodecs: Set<AudioCodec>,
        maxAudioChannels: Int = 2,
        supportsHDR10: Bool = false,
        supportsDolbyVision: Bool = false,
        supportsAudioOnly: Bool = true
    ) {
        self.containers = containers
        self.videoCodecs = videoCodecs
        self.audioCodecs = audioCodecs
        self.maxAudioChannels = max(1, maxAudioChannels)
        self.supportsHDR10 = supportsHDR10
        self.supportsDolbyVision = supportsDolbyVision
        self.supportsAudioOnly = supportsAudioOnly
    }

    /// First-generation and 1080p Chromecast receivers.
    public static let chromecast = GoogleCastCapabilities(
        containers: [.mp4, .webm],
        videoCodecs: [.h264, .vp8, .vp9],
        audioCodecs: [.aac, .mp3, .opus, .vorbis],
        maxAudioChannels: 2,
        supportsHDR10: false,
        supportsDolbyVision: false,
        supportsAudioOnly: false
    )

    /// Chromecast Ultra and newer 4K receivers.
    public static let chromecastUltra = GoogleCastCapabilities(
        containers: [.mp4, .webm],
        videoCodecs: [.h264, .hevc, .vp8, .vp9, .av1],
        audioCodecs: [.aac, .mp3, .opus, .vorbis, .ac3, .eac3, .flac],
        maxAudioChannels: 6,
        supportsHDR10: true,
        supportsDolbyVision: true,
        supportsAudioOnly: false
    )

    /// Google TV / Chromecast with Google TV.
    public static let googleTV = GoogleCastCapabilities(
        containers: [.mp4, .webm],
        videoCodecs: [.h264, .hevc, .vp8, .vp9, .av1],
        audioCodecs: [.aac, .mp3, .opus, .vorbis, .ac3, .eac3, .flac],
        maxAudioChannels: 6,
        supportsHDR10: true,
        supportsDolbyVision: true,
        supportsAudioOnly: false
    )

    /// Audio-only Chromecast Audio and speaker groups.
    public static let chromecastAudio = GoogleCastCapabilities(
        containers: [.mp4, .ogg, .webm],
        videoCodecs: [],
        audioCodecs: [.aac, .mp3, .opus, .vorbis, .flac, .pcm],
        maxAudioChannels: 2,
        supportsHDR10: false,
        supportsDolbyVision: false,
        supportsAudioOnly: true
    )
}

// MARK: - Source reachability

/// Whether a Cast receiver can actually fetch the media itself.
///
/// The receiver loads the URL directly, so files on a private share that only
/// this Apple TV can reach must be declined rather than silently failing
/// (SYNC-7).
public enum GoogleCastSourceAccess: Sendable, Equatable {
    /// An HTTP(S) URL the receiver can fetch on its own.
    case publiclyReachable(URL)

    /// A private SMB/NFS/WebDAV share that the receiver cannot reach.
    case privateShare(name: String)

    /// The source cannot expose a Cast-compatible URL for another reason.
    case unavailable(reason: String)
}

// MARK: - Media and requests

/// A Cast-compatible media description.
public struct GoogleCastMedia: Sendable, Equatable {
    public var url: URL
    public var contentType: String
    public var title: String
    public var subtitle: String?
    public var duration: TimeInterval?
    public var startPosition: TimeInterval
    public var isAudioOnly: Bool

    public init(
        url: URL,
        contentType: String,
        title: String,
        subtitle: String? = nil,
        duration: TimeInterval? = nil,
        startPosition: TimeInterval = 0,
        isAudioOnly: Bool = false
    ) {
        self.url = url
        self.contentType = contentType
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
        self.startPosition = max(0, startPosition)
        self.isAudioOnly = isAudioOnly
    }
}

/// One `load` request sent to a receiver.
public struct GoogleCastLoadRequest: Sendable, Equatable {
    public var deviceID: String
    public var media: GoogleCastMedia

    public init(deviceID: String, media: GoogleCastMedia) {
        self.deviceID = deviceID
        self.media = media
    }
}

// MARK: - Errors

/// Plain-language failures. Every refusal says what happened and what the
/// viewer can do next, never a silent failure (SYNC-7).
public enum GoogleCastError: Error, Sendable, Equatable, LocalizedError {
    /// Casting is a Pro feature.
    case proRequired

    /// No receiver is currently selected or available.
    case noDeviceSelected

    /// The selected receiver stopped answering.
    case deviceUnreachable(String)

    /// The receiver cannot demux this container.
    case unsupportedContainer(ContainerFormat, device: String)

    /// The receiver has no decoder for this video codec.
    case unsupportedVideoCodec(VideoCodec, device: String)

    /// The receiver has no decoder for this audio codec.
    case unsupportedAudioCodec(AudioCodec, device: String)

    /// The receiver cannot display this HDR format.
    case unsupportedHDR(HDRFormat, device: String)

    /// The receiver cannot accept this channel count.
    case unsupportedChannelCount(Int, maximum: Int, device: String)

    /// The receiver cannot play audio-only media.
    case audioOnlyUnsupported(String)

    /// The media has no video or audio track to cast.
    case noPlayableStream

    /// The file lives on a share the receiver cannot reach.
    case privateShareUnreachable(String)

    /// The source cannot provide a URL the receiver can fetch.
    case sourceUnavailable(String)

    /// The Cast transport failed for another reason.
    case transport(String)

    public var errorDescription: String? {
        explanation
    }

    /// A short, user-facing explanation suitable for a toast or detail row.
    public var explanation: String {
        switch self {
        case .proRequired:
            return "Casting to Chromecast and Google TV is part of PlayItRight Pro."
        case .noDeviceSelected:
            return "Choose a Chromecast or Google TV device to cast to."
        case .deviceUnreachable(let name):
            return "\(name) isn't responding. Make sure it's on the same network and try again."
        case .unsupportedContainer(let container, let device):
            return "\(device) can't play \(container.rawValue.uppercased()) files. Try a compatible stream or play locally."
        case .unsupportedVideoCodec(let codec, let device):
            return "\(device) can't decode \(Self.codecName(codec)). Play it on this Apple TV instead."
        case .unsupportedAudioCodec(let codec, let device):
            return "\(device) can't decode the \(Self.codecName(codec)) audio track. Choose another track or play locally."
        case .unsupportedHDR(let format, let device):
            return "\(device) can't display \(Self.hdrName(format)). Casting would look wrong, so playback stays on this Apple TV."
        case .unsupportedChannelCount(let channels, let maximum, let device):
            return "\(device) supports up to \(maximum) audio channels, but this track has \(channels). Choose a stereo track or play locally."
        case .audioOnlyUnsupported(let device):
            return "\(device) can't play audio-only items. Choose a video-capable Cast device for this media."
        case .noPlayableStream:
            return "This item has no video or audio track that can be cast."
        case .privateShareUnreachable(let share):
            return "The file is on the private share “\(share)”, which Cast devices can't reach. Casting needs a network source the receiver can open."
        case .sourceUnavailable(let reason):
            return "This item can't be cast: \(reason)"
        case .transport(let message):
            return "The Cast device couldn't be reached: \(message)"
        }
    }

    private static func codecName(_ codec: VideoCodec) -> String {
        codec.rawValue.uppercased()
    }

    private static func codecName(_ codec: AudioCodec) -> String {
        switch codec {
        case .truehd:
            return "Dolby TrueHD"
        case .dtsHD:
            return "DTS-HD"
        case .eac3:
            return "Dolby Digital Plus"
        case .ac3:
            return "Dolby Digital"
        default:
            return codec.rawValue.uppercased()
        }
    }

    private static func hdrName(_ format: HDRFormat) -> String {
        switch format {
        case .sdr:
            return "SDR"
        case .hdr10:
            return "HDR10"
        case .hdr10Plus:
            return "HDR10+"
        case .hlg:
            return "HLG"
        case .dolbyVision5, .dolbyVision8, .dolbyVision81:
            return "Dolby Vision"
        }
    }
}

// MARK: - Decision

/// The result of negotiating a cast. Either a request ready to send, or a
/// refusal that carries a plain-language explanation.
public enum GoogleCastDecision: Sendable, Equatable {
    case load(GoogleCastLoadRequest)
    case declined(GoogleCastError)

    /// The request to send, when casting is possible.
    public var request: GoogleCastLoadRequest? {
        guard case .load(let request) = self else {
            return nil
        }
        return request
    }

    /// The refusal, when casting is not possible.
    public var refusal: GoogleCastError? {
        guard case .declined(let error) = self else {
            return nil
        }
        return error
    }

    public var isDeclined: Bool {
        refusal != nil
    }

    /// User-facing text for the decision. Empty when the cast can proceed.
    public var explanation: String? {
        refusal?.explanation
    }
}

// MARK: - Transport

/// The Cast protocol seam. The live sender plugs in the Google Cast SDK (or a
/// Cast message channel); tests use an in-memory transport.
public protocol GoogleCastTransport: Sendable {
    /// Returns receivers visible on the local network.
    func discoverDevices() async throws -> [GoogleCastDevice]

    /// Sends a media load request to a receiver.
    func load(_ request: GoogleCastLoadRequest, on device: GoogleCastDevice) async throws

    /// Stops playback on a receiver.
    func stop(on device: GoogleCastDevice) async throws
}

/// Default transport used until the Cast SDK is linked.
///
/// Discovery is empty rather than throwing so the picker can show a friendly
/// "No Cast devices found" state; an attempted load explains the missing SDK.
public struct UnavailableGoogleCastTransport: GoogleCastTransport {
    public init() {}

    public func discoverDevices() async throws -> [GoogleCastDevice] {
        []
    }

    public func load(
        _ request: GoogleCastLoadRequest,
        on device: GoogleCastDevice
    ) async throws {
        throw GoogleCastError.transport(
            "Google Cast support isn't available in this build."
        )
    }

    public func stop(on device: GoogleCastDevice) async throws {}
}

// MARK: - Controller

/// Negotiates and sends Google Cast playback (SYNC-7, SYNC-8).
///
/// The receiver fetches the media directly, so this controller only sends a URL
/// after checking that the receiver can reach it and can decode the stream.
/// Private shares are declined with a plain explanation instead of failing on
/// the receiver. Casting requires the Pro entitlement.
@MainActor
public final class GoogleCastController {
    public private(set) var devices: [GoogleCastDevice] = []
    public private(set) var activeDevice: GoogleCastDevice?

    /// The most recent negotiation, useful for diagnostics and the UI.
    public private(set) var lastDecision: GoogleCastDecision?

    private let entitlement: any ProEntitlementProviding
    private let transport: any GoogleCastTransport

    public init(
        entitlement: any ProEntitlementProviding = StaticProEntitlement.free,
        transport: any GoogleCastTransport = UnavailableGoogleCastTransport()
    ) {
        self.entitlement = entitlement
        self.transport = transport
    }

    public var isProUnlocked: Bool {
        entitlement.isProUnlocked
    }

    public var isCasting: Bool {
        activeDevice != nil
    }

    /// Discover receivers and cache them in a stable, name-sorted order.
    @discardableResult
    public func discoverDevices() async throws -> [GoogleCastDevice] {
        let discovered = try await transport.discoverDevices()
        devices = discovered.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder == .orderedSame {
                return lhs.id < rhs.id
            }
            return nameOrder == .orderedAscending
        }
        return devices
    }

    /// Negotiates whether an item can be cast, without contacting the receiver.
    ///
    /// Checks the Pro entitlement first, then source reachability, then the
    /// receiver's container, video, audio, HDR, and channel capabilities.
    public func decide(
        graph: MediaGraph,
        access: GoogleCastSourceAccess,
        device: GoogleCastDevice,
        title: String,
        subtitle: String? = nil,
        startPosition: TimeInterval = 0
    ) -> GoogleCastDecision {
        let decision = negotiate(
            graph: graph,
            access: access,
            device: device,
            title: title,
            subtitle: subtitle,
            startPosition: startPosition
        )
        lastDecision = decision
        return decision
    }

    /// Negotiates and, when possible, sends the load request.
    ///
    /// Returns the decision for both successful casts and refusals. Transport
    /// errors are thrown so callers can distinguish a clear capability refusal
    /// from a receiver that disappeared mid-request.
    @discardableResult
    public func cast(
        graph: MediaGraph,
        access: GoogleCastSourceAccess,
        device: GoogleCastDevice,
        title: String,
        subtitle: String? = nil,
        startPosition: TimeInterval = 0
    ) async throws -> GoogleCastDecision {
        let decision = decide(
            graph: graph,
            access: access,
            device: device,
            title: title,
            subtitle: subtitle,
            startPosition: startPosition
        )
        guard case .load(let request) = decision else {
            return decision
        }
        try await transport.load(request, on: device)
        activeDevice = device
        return decision
    }

    /// Stops the active receiver and clears the active destination.
    public func stopCasting() async throws {
        guard let activeDevice else {
            return
        }
        try await transport.stop(on: activeDevice)
        self.activeDevice = nil
    }

    // MARK: - Negotiation

    private func negotiate(
        graph: MediaGraph,
        access: GoogleCastSourceAccess,
        device: GoogleCastDevice,
        title: String,
        subtitle: String?,
        startPosition: TimeInterval
    ) -> GoogleCastDecision {
        guard entitlement.isProUnlocked else {
            return .declined(.proRequired)
        }
        guard device.isReachable else {
            return .declined(.deviceUnreachable(device.name))
        }

        let url: URL
        switch access {
        case .publiclyReachable(let sourceURL):
            url = sourceURL
        case .privateShare(let name):
            return .declined(.privateShareUnreachable(name))
        case .unavailable(let reason):
            return .declined(.sourceUnavailable(reason))
        }

        let isAudioOnly = graph.videoTracks.isEmpty
        guard !graph.videoTracks.isEmpty || !graph.audioTracks.isEmpty else {
            return .declined(.noPlayableStream)
        }

        if isAudioOnly && !device.capabilities.supportsAudioOnly {
            return .declined(.audioOnlyUnsupported(device.name))
        }

        if !isAudioOnly {
            guard let video = graph.primaryVideoTrack else {
                return .declined(.noPlayableStream)
            }
            guard device.capabilities.containers.contains(graph.container) else {
                return .declined(
                    .unsupportedContainer(graph.container, device: device.name)
                )
            }
            guard device.capabilities.videoCodecs.contains(video.codec) else {
                return .declined(
                    .unsupportedVideoCodec(video.codec, device: device.name)
                )
            }

            let hdr = graph.hdrFormat
            if hdr.isDolbyVision && !device.capabilities.supportsDolbyVision {
                return .declined(
                    .unsupportedHDR(hdr, device: device.name)
                )
            }
            if hdr != .sdr
                && !hdr.isDolbyVision
                && !device.capabilities.supportsHDR10 {
                return .declined(
                    .unsupportedHDR(hdr, device: device.name)
                )
            }
        }

        if let audio = graph.defaultAudioTrack {
            guard device.capabilities.audioCodecs.contains(audio.codec) else {
                return .declined(
                    .unsupportedAudioCodec(audio.codec, device: device.name)
                )
            }
            guard audio.channels <= device.capabilities.maxAudioChannels else {
                return .declined(
                    .unsupportedChannelCount(
                        audio.channels,
                        maximum: device.capabilities.maxAudioChannels,
                        device: device.name
                    )
                )
            }
        } else if isAudioOnly {
            return .declined(.noPlayableStream)
        }

        let media = GoogleCastMedia(
            url: url,
            contentType: Self.contentType(
                for: graph.container,
                isAudioOnly: isAudioOnly
            ),
            title: title,
            subtitle: subtitle,
            duration: graph.duration,
            startPosition: startPosition,
            isAudioOnly: isAudioOnly
        )

        return .load(
            GoogleCastLoadRequest(deviceID: device.id, media: media)
        )
    }

    /// Cast media type for the receiver's load request.
    private static func contentType(
        for container: ContainerFormat,
        isAudioOnly: Bool
    ) -> String {
        if isAudioOnly {
            switch container {
            case .ogg:
                return "audio/ogg"
            case .webm:
                return "audio/webm"
            case .mp4, .mov, .m4v, .threeGP:
                return "audio/mp4"
            default:
                return "audio/mp4"
            }
        }

        switch container {
        case .mp4, .mov, .m4v, .threeGP:
            return "video/mp4"
        case .webm:
            return "video/webm"
        case .ogg, .ogv:
            return "video/ogg"
        case .ts, .m2ts, .mts:
            return "video/mp2t"
        case .mpg:
            return "video/mpeg"
        case .flv:
            return "video/x-flv"
        case .mkv:
            return "video/x-matroska"
        default:
            return "video/mp4"
        }
    }
}
