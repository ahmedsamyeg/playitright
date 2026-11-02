import CoreVideo
import Foundation

/// One compressed video access unit handed to a software decoder.
public struct SoftwareVideoFrame: Sendable, Equatable {
    /// Codec bitstream bytes, without container framing.
    public var data: Data

    /// Presentation time in seconds.
    public var presentationTime: TimeInterval

    /// Whether this frame is a random-access point.
    public var isKeyframe: Bool

    public init(
        data: Data,
        presentationTime: TimeInterval = 0,
        isKeyframe: Bool = false
    ) {
        self.data = data
        self.presentationTime = presentationTime
        self.isKeyframe = isKeyframe
    }
}

/// The software-decoding seam for R4 (ARCH-P6, PB-G2, PB-24).
///
/// FFmpeg supplies the implementation when the XCFramework is linked. Tests
/// and diagnostics can substitute a decoder without the binary, mirroring the
/// `RemuxDemuxing` and `FFmpegDemuxing` seams used elsewhere in PlaybackKit.
public protocol SoftwareVideoDecoding: Sendable {
    /// Decodes one compressed frame into a raw pixel buffer.
    func decode(
        _ frame: SoftwareVideoFrame,
        codec: VideoCodec,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer
}

/// Placeholder used when the FFmpeg XCFramework is not linked.
public struct UnavailableSoftwareVideoDecoder: SoftwareVideoDecoding {
    public init() {}

    public func decode(
        _ frame: SoftwareVideoFrame,
        codec: VideoCodec,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        throw StreamProbeError.ffmpegUnavailable
    }
}
