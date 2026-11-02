import AVFoundation
import CoreMedia
import Foundation

/// A probe that turns one file into a ``MediaGraph``.
public protocol MediaStreamProbing: Sendable {
    func probe(url: URL, container: ContainerFormat) async throws -> MediaGraph
}

// MARK: - MediaGraph entry point

extension MediaGraph {
    /// Probes a file, choosing AVFoundation for Apple-native containers and
    /// FFmpeg for everything else (PB-3, doc 04 §2.4).
    public static func probe(
        url: URL,
        ffmpeg: any FFmpegDemuxing = UnavailableFFmpegDemuxer()
    ) async throws -> MediaGraph {
        let container = ContainerFormat(url: url)
        if container.isAVFoundationNative {
            do {
                return try await AVFoundationStreamProbe().probe(
                    url: url,
                    container: container
                )
            } catch {
                // Some MP4-family files still need FFmpeg (e.g. exotic edit
                // lists or a codec AVFoundation refuses). Only fall through
                // when a real demuxer is available.
                guard !(ffmpeg is UnavailableFFmpegDemuxer) else {
                    throw error
                }
            }
        }
        return try await FFmpegStreamProbe(demuxer: ffmpeg).probe(
            url: url,
            container: container
        )
    }
}

// MARK: - AVFoundation

/// Probes MP4/MOV/M4V/3GP using `AVAsset` (Apple-native demux).
public struct AVFoundationStreamProbe: MediaStreamProbing {
    public init() {}

    public func probe(
        url: URL,
        container: ContainerFormat
    ) async throws -> MediaGraph {
        guard container.isAVFoundationNative else {
            throw StreamProbeError.unsupportedContainer(container.rawValue)
        }

        let asset = AVURLAsset(url: url)
        let duration: TimeInterval?
        if let loaded = try? await asset.load(.duration),
           loaded.isValid,
           !loaded.isIndefinite {
            duration = loaded.seconds
        } else {
            duration = nil
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let subtitleTracks = try await asset.loadTracks(withMediaType: .subtitle)
        let textTracks = try await asset.loadTracks(withMediaType: .text)
        let captionTracks = subtitleTracks + textTracks

        var videos: [VideoTrackInfo] = []
        for (position, track) in videoTracks.enumerated() {
            if let description = try await firstFormatDescription(of: track) {
                videos.append(
                    await Self.videoInfo(
                        description: description,
                        track: track,
                        index: position,
                        isDefault: position == 0
                    )
                )
            }
        }

        var audios: [AudioTrackInfo] = []
        for (position, track) in audioTracks.enumerated() {
            if let description = try await firstFormatDescription(of: track) {
                audios.append(
                    await Self.audioInfo(
                        description: description,
                        track: track,
                        index: videos.count + position,
                        isDefault: position == 0
                    )
                )
            }
        }

        var subtitles: [SubtitleTrackInfo] = []
        for (position, track) in captionTracks.enumerated() {
            subtitles.append(
                await Self.subtitleInfo(
                    track: track,
                    index: videos.count + audios.count + position,
                    isDefault: position == 0
                )
            )
        }

        let chapters = await Self.chapters(from: asset)

        guard !videos.isEmpty || !audios.isEmpty || !subtitles.isEmpty else {
            throw StreamProbeError.noTracks
        }

        return MediaGraph(
            container: container,
            demuxer: .avFoundation,
            duration: duration,
            videoTracks: videos,
            audioTracks: audios,
            subtitleTracks: subtitles,
            chapters: chapters
        )
    }

    private func firstFormatDescription(
        of track: AVAssetTrack
    ) async throws -> CMFormatDescription? {
        let descriptions = try await track.load(.formatDescriptions)
        return descriptions.first
    }

    // MARK: Video

    private static func videoInfo(
        description: CMFormatDescription,
        track: AVAssetTrack,
        index: Int,
        isDefault: Bool
    ) async -> VideoTrackInfo {
        let codecID = fourCC(
            CMFormatDescriptionGetMediaSubType(description)
        )
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let nominalFrameRate = (try? await track.load(.nominalFrameRate)) ?? 0
        let estimatedDataRate = (try? await track.load(.estimatedDataRate)) ?? 0
        let frameRate = FrameRate(fps: Double(nominalFrameRate))
        let transfer = transferFunction(from: description)
        let dolbyVisionProfile = extensionString(
            description,
            keys: ["DolbyVisionProfile", "Dolby Vision Profile"]
        ).flatMap(Int.init)
        let hdrFormat = Self.hdrFormat(
            transfer: transfer,
            dolbyVisionProfile: dolbyVisionProfile,
            description: description
        )

        return VideoTrackInfo(
            index: index,
            codec: Self.videoCodec(codecID: codecID),
            codecID: codecID,
            profile: extensionString(
                description,
                keys: ["ProfileName", "ProfileLevel"]
            ),
            level: extensionString(description, keys: ["Level"]),
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            frameRate: frameRate,
            bitDepth: extensionInt(
                description,
                keys: ["BitsPerComponent", "Depth"]
            ),
            bitrate: Int(estimatedDataRate),
            colorPrimaries: colorPrimaries(from: description),
            transferFunction: transfer,
            colorMatrix: colorMatrix(from: description),
            hdrFormat: hdrFormat,
            hasDolbyVisionRPU: dolbyVisionProfile != nil
                || extensionBool(
                    description,
                    keys: ["DolbyVisionRPU", "ContainsDolbyVisionRPU"]
                ),
            hasHDR10PlusMetadata: extensionBool(
                description,
                keys: ["HDR10Plus", "HDR10+", "SMPTE2094-40"]
            ),
            isInterlaced: (extensionInt(
                description,
                keys: ["FieldCount"]
            ) ?? 1) > 1,
            isDefault: isDefault
        )
    }

    // MARK: Audio

    private static func audioInfo(
        description: CMFormatDescription,
        track: AVAssetTrack,
        index: Int,
        isDefault: Bool
    ) async -> AudioTrackInfo {
        let codecID = fourCC(
            CMFormatDescriptionGetMediaSubType(description)
        )
        let estimatedDataRate = (try? await track.load(.estimatedDataRate)) ?? 0
        let basic = CMAudioFormatDescriptionGetStreamBasicDescription(
            description
        )?.pointee
        let channels = Int(basic?.mChannelsPerFrame ?? 0)
        let sampleRate = Int(basic?.mSampleRate ?? 0)
        let bits = basic.map { Int($0.mBitsPerChannel) }
        let codec = Self.audioCodec(codecID: codecID)

        return AudioTrackInfo(
            index: index,
            codec: codec,
            codecID: codecID,
            channels: channels,
            channelLayout: Self.channelLayout(
                channels: channels,
                description: description
            ),
            sampleRate: sampleRate,
            bitDepth: bits == 0 ? extensionInt(
                description,
                keys: ["BitsPerComponent", "Depth"]
            ) : bits,
            bitrate: Int(estimatedDataRate),
            isAtmos: Self.isAtmos(
                codec: codec,
                channels: channels,
                description: description
            ),
            isDefault: isDefault,
            language: await language(of: track),
            title: nil
        )
    }

    // MARK: Subtitles

    private static func subtitleInfo(
        track: AVAssetTrack,
        index: Int,
        isDefault: Bool
    ) async -> SubtitleTrackInfo {
        let formatID = (try? await track.load(.formatDescriptions))?
            .first
            .map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
        let format = Self.subtitleFormat(formatID: formatID)
        return SubtitleTrackInfo(
            index: index,
            format: format,
            formatID: formatID,
            language: await language(of: track),
            title: nil,
            isForced: false,
            isDefault: isDefault,
            isImageBased: format == .pgs || format == .vobsub
                || format == .dvbsub
        )
    }

    // MARK: Chapters

    private static func chapters(
        from asset: AVURLAsset
    ) async -> [ChapterInfo] {
        let groups: [AVTimedMetadataGroup]
        do {
            groups = try await asset.loadChapterMetadataGroups(
                withTitleLocale: Locale(identifier: "en"),
                containingItemsWithCommonKeys: [.commonKeyTitle]
            )
        } catch {
            return []
        }

        var chapters: [ChapterInfo] = []
        for (index, group) in groups.enumerated() {
            var title: String?
            for item in group.items {
                if let value = try? await item.load(.stringValue),
                   !value.isEmpty {
                    title = value
                    break
                }
            }
            let range = group.timeRange
            chapters.append(
                ChapterInfo(
                    index: index,
                    startTime: range.start.seconds,
                    endTime: range.duration.isNumeric
                        ? (range.start + range.duration).seconds
                        : nil,
                    title: title
                )
            )
        }
        return chapters
    }

    // MARK: Codec mapping

    private static func videoCodec(codecID: String) -> VideoCodec {
        switch codecID.lowercased().trimmingCharacters(in: .whitespaces) {
        case "avc1", "avc3":
            return .h264
        case "hvc1", "hev1":
            return .hevc
        case "av01":
            return .av1
        case "vp08":
            return .vp8
        case "vp09":
            return .vp9
        case "vvc1", "vvi1":
            return .vvc
        case "mp1v", "mpeg":
            return .mpeg1
        case "mp2v", "m2v1":
            return .mpeg2
        case "vc-1", "vc1":
            return .vc1
        case "wmv3":
            return .wmv3
        case "divx", "dx50", "mp4v":
            return .divx
        default:
            return .other
        }
    }

    private static func audioCodec(codecID: String) -> AudioCodec {
        switch codecID.lowercased().trimmingCharacters(in: .whitespaces) {
        case "mp4a", "aac":
            return .aac
        case "ac-3", "ac3":
            return .ac3
        case "ec-3", "eac3":
            return .eac3
        case "mlpa", "truehd":
            return .truehd
        case "dtsc", "dts", "dtsh", "dtse":
            return .dts
        case "flac":
            return .flac
        case "alac":
            return .alac
        case ".mp3", "mp3":
            return .mp3
        case "opus":
            return .opus
        case "vorb":
            return .vorbis
        case "lpcm", "sowt", "twos", "in24", "in32":
            return .pcm
        case "wma2", "wmap":
            return .wma
        default:
            return .other
        }
    }

    private static func subtitleFormat(formatID: String) -> SubtitleFormat {
        switch formatID.lowercased().trimmingCharacters(in: .whitespaces) {
        case "tx3g":
            return .movText
        case "wvtt":
            return .webvtt
        case "stpp":
            return .ttml
        case "text":
            return .other
        default:
            return .other
        }
    }

    // MARK: Color metadata

    private static func colorPrimaries(
        from description: CMFormatDescription
    ) -> ColorPrimaries {
        let value = extensionString(
            description,
            keys: ["ColorPrimaries", "Primaries"]
        )?.uppercased() ?? ""
        if value.contains("2020") {
            return .bt2020
        }
        if value.contains("P3") {
            return .displayP3
        }
        if value.contains("709") || value.contains("601") {
            return .bt709
        }
        return .bt709
    }

    private static func transferFunction(
        from description: CMFormatDescription
    ) -> TransferFunction {
        let value = extensionString(
            description,
            keys: ["TransferFunction", "Transfer"]
        )?.uppercased() ?? ""
        if value.contains("2084") || value.contains("PQ") {
            return .pq
        }
        if value.contains("HLG") || value.contains("2100") {
            return .hlg
        }
        return .sdr
    }

    private static func colorMatrix(
        from description: CMFormatDescription
    ) -> ColorMatrix {
        let value = extensionString(
            description,
            keys: ["YCbCrMatrix", "MatrixCoefficients", "Colorspace"]
        )?.uppercased() ?? ""
        if value.contains("2020") && value.contains("NCL") {
            return .bt2020NonConstant
        }
        if value.contains("2020") {
            return .bt2020NonConstant
        }
        if value.contains("709") || value.contains("601") {
            return .bt709
        }
        return .bt709
    }

    private static func hdrFormat(
        transfer: TransferFunction,
        dolbyVisionProfile: Int?,
        description: CMFormatDescription
    ) -> HDRFormat {
        if let profile = dolbyVisionProfile {
            switch profile {
            case 5:
                return .dolbyVision5
            case 8:
                let is81 = extensionBool(
                    description,
                    keys: ["DolbyVisionProfile81", "DolbyVision8.1"]
                )
                return is81 ? .dolbyVision81 : .dolbyVision8
            default:
                return .hdr10
            }
        }
        if extensionBool(description, keys: ["HDR10Plus", "SMPTE2094-40"]) {
            return .hdr10Plus
        }
        switch transfer {
        case .pq:
            return .hdr10
        case .hlg:
            return .hlg
        default:
            return .sdr
        }
    }

    private static func isAtmos(
        codec: AudioCodec,
        channels: Int,
        description: CMFormatDescription
    ) -> Bool {
        if extensionBool(
            description,
            keys: ["Atmos", "DolbyAtmos", "Dolby Atmos"]
        ) {
            return true
        }
        let label = extensionString(
            description,
            keys: ["ChannelLayout", "ChannelLayoutName"]
        )?.lowercased() ?? ""
        return label.contains("atmos")
            || (codec == .eac3 && channels > 6)
    }

    private static func channelLayout(
        channels: Int,
        description: CMFormatDescription
    ) -> String? {
        if let label = extensionString(
            description,
            keys: ["ChannelLayout", "ChannelLayoutName"]
        ), !label.isEmpty {
            return label
        }
        switch channels {
        case 1:
            return "mono"
        case 2:
            return "stereo"
        case 6:
            return "5.1"
        case 8:
            return "7.1"
        default:
            return channels > 0 ? "\(channels)ch" : nil
        }
    }

    private static func language(of track: AVAssetTrack) async -> String? {
        if let tag = try? await track.load(.languageCode),
           !tag.isEmpty {
            return tag
        }
        return nil
    }

    // MARK: Format description helpers

    private static func extensionValue(
        _ description: CMFormatDescription,
        _ key: String
    ) -> Any? {
        CMFormatDescriptionGetExtension(
            description,
            extensionKey: key as CFString
        )
    }

    private static func extensionString(
        _ description: CMFormatDescription,
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = extensionValue(description, key) as? String {
                return value
            }
            if let value = extensionValue(description, key) as? NSString {
                return value as String
            }
        }
        return nil
    }

    private static func extensionInt(
        _ description: CMFormatDescription,
        keys: [String]
    ) -> Int? {
        for key in keys {
            if let value = extensionValue(description, key) as? NSNumber {
                return value.intValue
            }
        }
        return nil
    }

    private static func extensionBool(
        _ description: CMFormatDescription,
        keys: [String]
    ) -> Bool {
        for key in keys {
            if let value = extensionValue(description, key) as? NSNumber {
                return value.boolValue
            }
            if let value = extensionValue(description, key) as? Bool {
                return value
            }
        }
        return false
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

// MARK: - FFmpeg bridge

/// One stream as reported by FFmpeg's `avformat` probe.
public struct FFmpegStreamDescription: Sendable, Equatable {
    public var index: Int
    public var kind: MediaTrackKind
    public var codecID: String
    public var codecName: String?
    public var profile: String?
    public var level: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: FrameRate
    public var bitDepth: Int?
    public var bitrate: Int?
    public var colorPrimaries: String?
    public var transferFunction: String?
    public var colorMatrix: String?
    public var hdrFormat: HDRFormat?
    public var dolbyVisionProfile: Int?
    public var hasDolbyVisionRPU: Bool
    public var hasHDR10PlusMetadata: Bool
    public var channels: Int?
    public var channelLayout: String?
    public var sampleRate: Int?
    public var audioBitDepth: Int?
    public var isAtmos: Bool
    public var isDefault: Bool
    public var isForced: Bool
    public var language: String?
    public var title: String?

    public init(
        index: Int,
        kind: MediaTrackKind,
        codecID: String,
        codecName: String? = nil,
        profile: String? = nil,
        level: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        frameRate: FrameRate = FrameRate(numerator: 0, denominator: 1),
        bitDepth: Int? = nil,
        bitrate: Int? = nil,
        colorPrimaries: String? = nil,
        transferFunction: String? = nil,
        colorMatrix: String? = nil,
        hdrFormat: HDRFormat? = nil,
        dolbyVisionProfile: Int? = nil,
        hasDolbyVisionRPU: Bool = false,
        hasHDR10PlusMetadata: Bool = false,
        channels: Int? = nil,
        channelLayout: String? = nil,
        sampleRate: Int? = nil,
        audioBitDepth: Int? = nil,
        isAtmos: Bool = false,
        isDefault: Bool = false,
        isForced: Bool = false,
        language: String? = nil,
        title: String? = nil
    ) {
        self.index = index
        self.kind = kind
        self.codecID = codecID
        self.codecName = codecName
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
        self.dolbyVisionProfile = dolbyVisionProfile
        self.hasDolbyVisionRPU = hasDolbyVisionRPU
        self.hasHDR10PlusMetadata = hasHDR10PlusMetadata
        self.channels = channels
        self.channelLayout = channelLayout
        self.sampleRate = sampleRate
        self.audioBitDepth = audioBitDepth
        self.isAtmos = isAtmos
        self.isDefault = isDefault
        self.isForced = isForced
        self.language = language
        self.title = title
    }
}

public struct FFmpegChapterDescription: Sendable, Equatable {
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

public struct FFmpegProbeResult: Sendable, Equatable {
    public var container: ContainerFormat
    public var duration: TimeInterval?
    public var streams: [FFmpegStreamDescription]
    public var chapters: [FFmpegChapterDescription]

    public init(
        container: ContainerFormat,
        duration: TimeInterval? = nil,
        streams: [FFmpegStreamDescription] = [],
        chapters: [FFmpegChapterDescription] = []
    ) {
        self.container = container
        self.duration = duration
        self.streams = streams
        self.chapters = chapters
    }
}

/// The narrow seam between PlaybackKit and the LGPL `FFmpeg.xcframework`.
///
/// Keeping the bridge protocol-based means the planner can be exercised in
/// unit tests without linking the binary and the LGPL build stays isolated.
public protocol FFmpegDemuxing: Sendable {
    func probe(
        url: URL,
        container: ContainerFormat
    ) async throws -> FFmpegProbeResult
}

/// Placeholder used when `FFmpeg.xcframework` is not linked into the build.
public struct UnavailableFFmpegDemuxer: FFmpegDemuxing {
    public init() {}

    public func probe(
        url: URL,
        container: ContainerFormat
    ) async throws -> FFmpegProbeResult {
        throw StreamProbeError.ffmpegUnavailable
    }
}

/// Probes MKV/WebM/AVI/TS/... through the FFmpeg demuxer bridge.
public struct FFmpegStreamProbe: MediaStreamProbing {
    public var demuxer: any FFmpegDemuxing

    public init(demuxer: any FFmpegDemuxing) {
        self.demuxer = demuxer
    }

    public func probe(
        url: URL,
        container: ContainerFormat
    ) async throws -> MediaGraph {
        let result = try await demuxer.probe(
            url: url,
            container: container
        )
        return Self.mediaGraph(result)
    }

    /// Maps the raw FFmpeg description into the normalized graph. Kept public
    /// so recorded probe results can be replayed in tests and diagnostics.
    public static func mediaGraph(
        _ result: FFmpegProbeResult
    ) -> MediaGraph {
        var videos: [VideoTrackInfo] = []
        var audios: [AudioTrackInfo] = []
        var subtitles: [SubtitleTrackInfo] = []

        for stream in result.streams.sorted(by: { $0.index < $1.index }) {
            switch stream.kind {
            case .video:
                videos.append(
                    VideoTrackInfo(
                        index: stream.index,
                        codec: videoCodec(codecID: stream.codecID),
                        codecID: stream.codecID,
                        profile: stream.profile,
                        level: stream.level,
                        width: stream.width ?? 0,
                        height: stream.height ?? 0,
                        frameRate: stream.frameRate,
                        bitDepth: stream.bitDepth,
                        bitrate: stream.bitrate,
                        colorPrimaries: colorPrimaries(
                            stream.colorPrimaries
                        ),
                        transferFunction: transferFunction(
                            stream.transferFunction,
                            hdrFormat: stream.hdrFormat
                        ),
                        colorMatrix: colorMatrix(stream.colorMatrix),
                        hdrFormat: normalizedHDR(
                            stream.hdrFormat,
                            dolbyVisionProfile: stream.dolbyVisionProfile,
                            transferFunction: stream.transferFunction
                        ),
                        hasDolbyVisionRPU: stream.hasDolbyVisionRPU
                            || stream.dolbyVisionProfile != nil,
                        hasHDR10PlusMetadata: stream.hasHDR10PlusMetadata,
                        isDefault: stream.isDefault
                    )
                )
            case .audio:
                audios.append(
                    AudioTrackInfo(
                        index: stream.index,
                        codec: audioCodec(codecID: stream.codecID),
                        codecID: stream.codecID,
                        channels: stream.channels ?? 0,
                        channelLayout: stream.channelLayout,
                        sampleRate: stream.sampleRate ?? 0,
                        bitDepth: stream.audioBitDepth,
                        bitrate: stream.bitrate,
                        isAtmos: stream.isAtmos,
                        isDefault: stream.isDefault,
                        language: stream.language,
                        title: stream.title
                    )
                )
            case .subtitle:
                let format = subtitleFormat(codecID: stream.codecID)
                subtitles.append(
                    SubtitleTrackInfo(
                        index: stream.index,
                        format: format,
                        formatID: stream.codecID,
                        language: stream.language,
                        title: stream.title,
                        isForced: stream.isForced,
                        isDefault: stream.isDefault,
                        isImageBased: format == .pgs || format == .vobsub
                            || format == .dvbsub
                    )
                )
            case .chapter:
                continue
            }
        }

        let chapters = result.chapters.map {
            ChapterInfo(
                index: $0.index,
                startTime: $0.startTime,
                endTime: $0.endTime,
                title: $0.title
            )
        }

        return MediaGraph(
            container: result.container,
            demuxer: .ffmpeg,
            duration: result.duration,
            videoTracks: videos,
            audioTracks: audios,
            subtitleTracks: subtitles,
            chapters: chapters
        )
    }

    // MARK: Mapping helpers

    private static func videoCodec(codecID: String) -> VideoCodec {
        switch codecID.lowercased().trimmingCharacters(in: .whitespaces) {
        case "h264", "avc1", "avc3":
            return .h264
        case "hevc", "h265", "hvc1", "hev1":
            return .hevc
        case "av1", "av01":
            return .av1
        case "vp8", "vp08":
            return .vp8
        case "vp9", "vp09":
            return .vp9
        case "vvc", "h266", "vvc1":
            return .vvc
        case "mpeg1video", "mpeg1":
            return .mpeg1
        case "mpeg2video", "mpeg2":
            return .mpeg2
        case "vc1", "vc-1":
            return .vc1
        case "wmv3", "wmv":
            return .wmv3
        case "msmpeg4v3", "divx", "dx50":
            return .divx
        default:
            return .other
        }
    }

    private static func audioCodec(codecID: String) -> AudioCodec {
        switch codecID.lowercased().trimmingCharacters(in: .whitespaces) {
        case "aac", "mp4a":
            return .aac
        case "ac3", "ac-3":
            return .ac3
        case "eac3", "ec-3":
            return .eac3
        case "truehd", "mlp":
            return .truehd
        case "dca", "dts":
            return .dts
        case "dtshd", "dts-hd":
            return .dtsHD
        case "flac":
            return .flac
        case "alac":
            return .alac
        case "mp3":
            return .mp3
        case "opus":
            return .opus
        case "vorbis", "vorb":
            return .vorbis
        case "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm":
            return .pcm
        case "wmav2", "wma":
            return .wma
        default:
            return .other
        }
    }

    private static func subtitleFormat(codecID: String) -> SubtitleFormat {
        switch codecID.lowercased().trimmingCharacters(in: .whitespaces) {
        case "subrip", "srt":
            return .srt
        case "ass":
            return .ass
        case "ssa":
            return .ssa
        case "webvtt", "vtt":
            return .webvtt
        case "hdmv_pgs_subtitle", "pgs":
            return .pgs
        case "dvd_subtitle", "dvdsub", "vobsub":
            return .vobsub
        case "dvb_subtitle", "dvbsub":
            return .dvbsub
        case "mov_text":
            return .movText
        case "ttml":
            return .ttml
        default:
            return .other
        }
    }

    private static func colorPrimaries(_ value: String?) -> ColorPrimaries {
        let value = value?.uppercased() ?? ""
        if value.contains("2020") {
            return .bt2020
        }
        if value.contains("P3") {
            return .displayP3
        }
        return value.isEmpty ? .bt709 : .bt709
    }

    private static func transferFunction(
        _ value: String?,
        hdrFormat: HDRFormat?
    ) -> TransferFunction {
        let value = value?.uppercased() ?? ""
        if value.contains("2084") || value.contains("PQ") {
            return .pq
        }
        if value.contains("HLG") || value.contains("2100") {
            return .hlg
        }
        switch hdrFormat {
        case .hlg:
            return .hlg
        case .hdr10, .hdr10Plus:
            return .pq
        default:
            return .sdr
        }
    }

    private static func colorMatrix(_ value: String?) -> ColorMatrix {
        let value = value?.uppercased() ?? ""
        if value.contains("2020") {
            return .bt2020NonConstant
        }
        return value.isEmpty || value.contains("709") ? .bt709 : .other
    }

    private static func normalizedHDR(
        _ hdr: HDRFormat?,
        dolbyVisionProfile: Int?,
        transferFunction: String?
    ) -> HDRFormat {
        if let hdr, hdr.isDolbyVision {
            return hdr
        }
        if let profile = dolbyVisionProfile {
            return profile == 5 ? .dolbyVision5 : .dolbyVision8
        }
        if let hdr {
            return hdr
        }
        let value = transferFunction?.uppercased() ?? ""
        if value.contains("2084") || value.contains("PQ") {
            return .hdr10
        }
        if value.contains("HLG") {
            return .hlg
        }
        return .sdr
    }
}
