import Foundation

/// The media shape inferred from a filename.
public enum MediaKind: String, Codable, Sendable, Equatable {
    case movie
    case episode
}

/// Metadata extracted from a release filename.
///
/// This is deliberately conservative: every field is optional, and
/// `confidence` communicates how strongly the filename should be trusted
/// before an item is sent to a provider lookup (MD-1, MD-2).
public struct ParsedMediaInfo: Codable, Sendable, Equatable {
    /// Whether the filename looks like a movie or an episode.
    public var kind: MediaKind

    /// Cleaned title with release junk removed.
    public var title: String

    /// Release year, when one was present outside the title.
    public var year: Int?

    /// Season number for episodes.
    public var season: Int?

    /// Episode numbers, oldest first. Multi-episode files contain every
    /// episode in the range (for example `S01E02-E04` → `[2, 3, 4]`).
    public var episodes: [Int]

    /// Edition label such as `Director's Cut` or `Extended`.
    public var edition: String?

    /// Normalized resolution label, for example `2160p` or `1080p`.
    public var resolution: String?

    /// Normalized video codec label, for example `hevc`, `h264`, or `av1`.
    public var videoCodec: String?

    /// Normalized audio codec label, for example `atmos` or `dts-hd-ma`.
    public var audioCodec: String?

    /// Normalized HDR labels such as `hdr10`, `hdr10+`, `hlg`, `dolby-vision`.
    public var hdrFormats: [String]

    /// Trailing release group, when one could be identified.
    public var releaseGroup: String?

    /// Parser confidence in the range `0...1`.
    public var confidence: Double

    /// The original filename, preserved for diagnostics and review screens.
    public var sourceFilename: String

    public init(
        kind: MediaKind,
        title: String,
        year: Int? = nil,
        season: Int? = nil,
        episodes: [Int] = [],
        edition: String? = nil,
        resolution: String? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        hdrFormats: [String] = [],
        releaseGroup: String? = nil,
        confidence: Double,
        sourceFilename: String
    ) {
        self.kind = kind
        self.title = title
        self.year = year
        self.season = season
        self.episodes = episodes
        self.edition = edition
        self.resolution = resolution
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.hdrFormats = hdrFormats
        self.releaseGroup = releaseGroup
        self.confidence = confidence
        self.sourceFilename = sourceFilename
    }

    /// Whether this file contains more than one episode.
    public var isMultiEpisode: Bool {
        episodes.count > 1
    }

    /// First episode number, if any.
    public var episodeStart: Int? {
        episodes.first
    }

    /// Last episode number, if any.
    public var episodeEnd: Int? {
        episodes.last
    }

    /// True when the parse is too weak to auto-match safely.
    public var needsReview: Bool {
        confidence < 0.75
    }
}
