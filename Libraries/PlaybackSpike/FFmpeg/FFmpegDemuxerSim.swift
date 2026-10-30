import Foundation
import CoreMedia

/// Packet metadata extracted from a demuxed container stream.
public struct DemuxedPacket: Equatable, Sendable {
    public let streamIndex: Int
    public let codecId: String
    public let pts: CMTime
    public let dts: CMTime
    public let isKeyframe: Bool
    public let payloadSize: Int

    public init(
        streamIndex: Int,
        codecId: String,
        pts: CMTime,
        dts: CMTime,
        isKeyframe: Bool,
        payloadSize: Int
    ) {
        self.streamIndex = streamIndex
        self.codecId = codecId
        self.pts = pts
        self.dts = dts
        self.isKeyframe = isKeyframe
        self.payloadSize = payloadSize
    }
}

/// Simulated demuxer verifying container track extraction (PB-3).
public final class FFmpegDemuxerSim: Sendable {

    public struct ContainerStreamInfo: Equatable, Sendable {
        public let index: Int
        public let kind: FFmpegCodecDescriptor.CodecKind
        public let codecId: String
        public let title: String?
        public let language: String?
    }

    public init() {}

    /// Demuxes simulated container streams based on container format.
    public func probeContainer(format: String) -> [ContainerStreamInfo] {
        switch format.lowercased() {
        case "mkv", "matroska":
            return [
                ContainerStreamInfo(index: 0, kind: .video, codecId: "av1", title: "4K AV1 HDR", language: nil),
                ContainerStreamInfo(index: 1, kind: .audio, codecId: "dca", title: "DTS-HD MA 7.1", language: "eng"),
                ContainerStreamInfo(index: 2, kind: .subtitle, codecId: "pgs", title: "English (SDH)", language: "eng")
            ]
        case "avi":
            return [
                ContainerStreamInfo(index: 0, kind: .video, codecId: "mpeg2video", title: "MPEG-2", language: nil),
                ContainerStreamInfo(index: 1, kind: .audio, codecId: "ac3", title: "Stereo AC3", language: "eng")
            ]
        case "webm":
            return [
                ContainerStreamInfo(index: 0, kind: .video, codecId: "vp9", title: "VP9 1080p", language: nil),
                ContainerStreamInfo(index: 1, kind: .audio, codecId: "opus", title: "Opus 2.0", language: "eng")
            ]
        case "ts", "mpegts":
            return [
                ContainerStreamInfo(index: 0, kind: .video, codecId: "vc1", title: "VC-1 Broadcast", language: nil),
                ContainerStreamInfo(index: 1, kind: .audio, codecId: "eac3", title: "E-AC3 5.1", language: "eng")
            ]
        default:
            return []
        }
    }

    /// Emits demuxed packets for a given stream index.
    public func readPackets(streamIndex: Int, codecId: String, count: Int) -> [DemuxedPacket] {
        return (0..<count).map { i in
            let pts = CMTime(value: CMTimeValue(i * 1000), timescale: 60000)
            return DemuxedPacket(
                streamIndex: streamIndex,
                codecId: codecId,
                pts: pts,
                dts: pts,
                isKeyframe: i % 30 == 0,
                payloadSize: 1024 + (i * 37) % 4096
            )
        }
    }
}
