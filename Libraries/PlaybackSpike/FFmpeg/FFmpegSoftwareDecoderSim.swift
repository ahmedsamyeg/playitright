import Foundation
import CoreMedia

/// Uncompressed decoded video frame representation.
public struct DecodedVideoFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bitDepth: Int
    public let pts: CMTime
    public let pixelFormat: String
    public let bufferByteCount: Int

    public init(
        width: Int,
        height: Int,
        bitDepth: Int,
        pts: CMTime,
        pixelFormat: String = "yuv420p"
    ) {
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.pts = pts
        self.pixelFormat = pixelFormat
        // YUV 4:2:0 takes 1.5 bytes per pixel in 8-bit, 3 bytes per pixel in 10-bit
        let bytesPerPixel = bitDepth > 8 ? 3.0 : 1.5
        self.bufferByteCount = Int(Double(width * height) * bytesPerPixel)
    }
}

/// Uncompressed decoded audio buffer representation.
public struct DecodedAudioBuffer: Equatable, Sendable {
    public let channels: Int
    public let sampleRate: Int
    public let sampleCount: Int
    public let pts: CMTime
    public let channelLayout: String

    public init(
        channels: Int,
        sampleRate: Int = 48000,
        sampleCount: Int = 1024,
        pts: CMTime,
        channelLayout: String
    ) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.sampleCount = sampleCount
        self.pts = pts
        self.channelLayout = channelLayout
    }
}

/// Simulated software decoder executing software decode paths (R4 rung, PB-2, PB-12).
public final class FFmpegSoftwareDecoderSim: Sendable {

    public init() {}

    /// Decodes a compressed video packet into an uncompressed video frame.
    public func decodeVideo(packet: DemuxedPacket, width: Int = 3840, height: Int = 2160) throws -> DecodedVideoFrame {
        guard FFmpegCodecDescriptor.isCodecSupported(packet.codecId) else {
            throw NSError(domain: "FFmpegDecoder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported codec: \(packet.codecId)"])
        }

        let bitDepth = (packet.codecId == "av1" || packet.codecId == "vvc") ? 10 : 8
        return DecodedVideoFrame(
            width: width,
            height: height,
            bitDepth: bitDepth,
            pts: packet.pts,
            pixelFormat: bitDepth > 8 ? "yuv420p10le" : "yuv420p"
        )
    }

    /// Decodes a compressed audio packet into multi-channel audio buffer.
    public func decodeAudio(packet: DemuxedPacket) throws -> DecodedAudioBuffer {
        guard FFmpegCodecDescriptor.isCodecSupported(packet.codecId) else {
            throw NSError(domain: "FFmpegDecoder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported codec: \(packet.codecId)"])
        }

        let channels: Int
        let layout: String
        switch packet.codecId {
        case "dca": // DTS-HD MA 7.1
            channels = 8
            layout = "7.1"
        case "truehd": // Dolby TrueHD 7.1
            channels = 8
            layout = "7.1"
        case "eac3": // 5.1
            channels = 6
            layout = "5.1"
        default:
            channels = 2
            layout = "stereo"
        }

        return DecodedAudioBuffer(
            channels: channels,
            sampleRate: 48000,
            sampleCount: 1024,
            pts: packet.pts,
            channelLayout: layout
        )
    }

    /// Downmixes a 7.1 or 5.1 audio buffer to stereo 2.0 per ITU-R BS.775 (PB-14).
    public func downmixToStereo(input: DecodedAudioBuffer) -> DecodedAudioBuffer {
        return DecodedAudioBuffer(
            channels: 2,
            sampleRate: input.sampleRate,
            sampleCount: input.sampleCount,
            pts: input.pts,
            channelLayout: "stereo (BS.775 downmix)"
        )
    }
}
