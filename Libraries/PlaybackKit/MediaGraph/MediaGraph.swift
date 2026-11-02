import Foundation
import LibraryCore

/// Everything the playback planner needs to know about a file (doc 04 §4.1).
///
/// A graph is produced by ``StreamProbe``-style probes: AVFoundation for Apple
/// native containers and FFmpeg (`avformat`) for MKV/AVI/WebM. The graph is a
/// value type so it can be cached, logged, and compared deterministically.
public struct MediaGraph: Codable, Sendable, Equatable {
    public var container: ContainerFormat
    public var demuxer: DemuxerKind
    public var duration: TimeInterval?
    public var videoTracks: [VideoTrackInfo]
    public var audioTracks: [AudioTrackInfo]
    public var subtitleTracks: [SubtitleTrackInfo]
    public var chapters: [ChapterInfo]

    public init(
        container: ContainerFormat,
        demuxer: DemuxerKind,
        duration: TimeInterval? = nil,
        videoTracks: [VideoTrackInfo] = [],
        audioTracks: [AudioTrackInfo] = [],
        subtitleTracks: [SubtitleTrackInfo] = [],
        chapters: [ChapterInfo] = []
    ) {
        self.container = container
        self.demuxer = demuxer
        self.duration = duration
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.chapters = chapters
    }

    /// Every stream in probe order.
    public var tracks: [MediaTrackInfo] {
        var result: [MediaTrackInfo] = []
        result.append(contentsOf: videoTracks.map(MediaTrackInfo.video))
        result.append(contentsOf: audioTracks.map(MediaTrackInfo.audio))
        result.append(contentsOf: subtitleTracks.map(MediaTrackInfo.subtitle))
        result.append(contentsOf: chapters.map(MediaTrackInfo.chapter))
        return result.sorted { $0.index < $1.index }
    }

    /// The primary video stream, if the file has one.
    public var primaryVideoTrack: VideoTrackInfo? {
        videoTracks.first
    }

    /// The audio track the player should start with.
    public var defaultAudioTrack: AudioTrackInfo? {
        audioTracks.first(where: \.isDefault) ?? audioTracks.first
    }

    /// The HDR pipeline of the primary video stream.
    public var hdrFormat: HDRFormat {
        primaryVideoTrack?.hdrFormat ?? .sdr
    }

    /// The container probe route used for this file.
    public var isDirectPlayContainer: Bool {
        container.isAVFoundationNative
    }

    /// Builds `TrackRecord` rows for insertion into `LibraryCore`.
    ///
    /// Track indexes come from the demuxer and are stable for a given file.
    /// Chapter marks are stored as `chapter` rows so the player can expose
    /// chapter-aware seeking (PB-3).
    public func trackRecords(fileID: String) -> [TrackRecord] {
        var records: [TrackRecord] = videoTracks.map { track in
            TrackRecord(
                fileId: fileID,
                kind: .video,
                index: track.index,
                isDefault: track.isDefault,
                sampled: true,
                codec: track.codec.rawValue,
                profile: track.profile,
                level: track.level,
                width: track.width,
                height: track.height,
                fpsNum: track.frameRate.numerator,
                fpsDen: track.frameRate.denominator,
                bitDepth: track.bitDepth,
                colorPrimaries: track.colorPrimaries.rawValue,
                colorTrc: track.transferFunction.rawValue,
                colorSpace: track.colorMatrix.rawValue,
                hdrFormat: track.hdrFormat.rawValue,
                sdciPresent: track.hasHDR10PlusMetadata || track.hasDolbyVisionRPU
            )
        }

        records.append(contentsOf: audioTracks.map { track in
            TrackRecord(
                fileId: fileID,
                kind: .audio,
                index: track.index,
                title: track.title,
                lang: track.language,
                isDefault: track.isDefault,
                sampled: true,
                codec: track.codec.rawValue,
                channels: track.channels,
                channelLayout: track.channelLayout,
                sampleRate: track.sampleRate,
                audioBitDepth: track.bitDepth
            )
        })

        records.append(contentsOf: subtitleTracks.map { track in
            TrackRecord(
                fileId: fileID,
                kind: .subtitle,
                index: track.index,
                title: track.title,
                lang: track.language,
                isDefault: track.isDefault,
                isForced: track.isForced,
                sampled: true,
                subtitleFormat: track.format.rawValue
            )
        })

        records.append(contentsOf: chapters.map { chapter in
            TrackRecord(
                fileId: fileID,
                kind: .chapter,
                index: chapter.index,
                title: chapter.title,
                sampled: false
            )
        })

        return records.sorted {
            if $0.kind == $1.kind {
                return $0.index < $1.index
            }
            return Self.kindOrder($0.kind) < Self.kindOrder($1.kind)
        }
    }

    private static func kindOrder(_ kind: TrackKind) -> Int {
        switch kind {
        case .video:
            return 0
        case .audio:
            return 1
        case .subtitle:
            return 2
        case .chapter:
            return 3
        }
    }
}

public enum StreamProbeError: Error, LocalizedError, Equatable {
    case unsupportedContainer(String)
    case ffmpegUnavailable
    case noTracks
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedContainer(let container):
            return "No stream probe is available for \(container) files."
        case .ffmpegUnavailable:
            return "The FFmpeg demuxer is not linked in this build."
        case .noTracks:
            return "The file contains no readable tracks."
        case .readFailed(let message):
            return "Could not read the media file: \(message)"
        }
    }
}
