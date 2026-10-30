import Foundation

/// Defines codec, container, and filter capabilities provided by the bundled FFmpeg LGPL dynamic framework (ARCH-5, ARCH-6, PB-2).
public struct FFmpegCodecDescriptor: Sendable {

    public enum CodecKind: String, Sendable {
        case video
        case audio
        case subtitle
    }

    public struct CodecEntry: Equatable, Sendable {
        public let id: String
        public let name: String
        public let kind: CodecKind
        public let isDecodable: Bool
        public let isEncodable: Bool
        public let license: String

        public init(
            id: String,
            name: String,
            kind: CodecKind,
            isDecodable: Bool = true,
            isEncodable: Bool = false,
            license: String = "LGPL-2.1"
        ) {
            self.id = id
            self.name = name
            self.kind = kind
            self.isDecodable = isDecodable
            self.isEncodable = isEncodable
            self.license = license
        }
    }

    /// List of enabled decoders compiled into the dynamic framework.
    public static let enabledCodecs: [CodecEntry] = [
        // Extended Video (Pro rungs)
        CodecEntry(id: "av1", name: "AOMedia Video 1", kind: .video),
        CodecEntry(id: "vp8", name: "On2 VP8", kind: .video),
        CodecEntry(id: "vp9", name: "Google VP9", kind: .video),
        CodecEntry(id: "vvc", name: "Versatile Video Coding (H.266)", kind: .video),
        CodecEntry(id: "vc1", name: "SMPTE VC-1", kind: .video),
        CodecEntry(id: "wmv3", name: "Windows Media Video 9", kind: .video),
        CodecEntry(id: "mpeg2video", name: "MPEG-2 Video", kind: .video),

        // Extended Audio (Pro rungs)
        CodecEntry(id: "dca", name: "DTS / DTS-HD Master Audio", kind: .audio),
        CodecEntry(id: "truehd", name: "Dolby TrueHD / Atmos", kind: .audio),
        CodecEntry(id: "ac3", name: "Dolby Digital (AC3)", kind: .audio),
        CodecEntry(id: "eac3", name: "Dolby Digital Plus (E-AC3)", kind: .audio),
        CodecEntry(id: "flac", name: "Free Lossless Audio Codec", kind: .audio),
        CodecEntry(id: "alac", name: "Apple Lossless Audio Codec", kind: .audio),

        // Software Encoder (Cisco openh264 - BSD 2-Clause)
        CodecEntry(id: "libopenh264", name: "OpenH264 H.264 / AVC encoder", kind: .video, isDecodable: false, isEncodable: true, license: "BSD-2-Clause")
    ]

    /// Supported container demuxers.
    public static let supportedDemuxers: [String] = [
        "matroska", "mov", "avi", "asf", "flv", "mpegts", "wav", "flac", "ogg"
    ]

    /// Supported color filters.
    public static let supportedFilters: [String] = [
        "tonemap", "zscale"
    ]

    /// Checks if a codec is supported and strictly LGPL/permissively licensed.
    public static func isCodecSupported(_ codecId: String) -> Bool {
        return enabledCodecs.contains { $0.id.lowercased() == codecId.lowercased() }
    }
}
