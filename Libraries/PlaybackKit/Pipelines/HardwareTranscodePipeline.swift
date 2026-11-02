import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum HardwareTranscodeError: Error, LocalizedError, Equatable {
    case encoderUnavailable(OSStatus)
    case sessionCreationFailed(OSStatus)
    case propertyFailed(String, OSStatus)
    case encodeFailed(OSStatus)
    case noEncodedFrame
    case unsupportedPixelBuffer

    public var errorDescription: String? {
        switch self {
        case .encoderUnavailable(let status):
            return "No VideoToolbox encoder is available (status \(status))."
        case .sessionCreationFailed(let status):
            return "VideoToolbox could not create a compression session (status \(status))."
        case .propertyFailed(let key, let status):
            return "VideoToolbox rejected '\(key)' (status \(status))."
        case .encodeFailed(let status):
            return "VideoToolbox failed to encode a frame (status \(status))."
        case .noEncodedFrame:
            return "VideoToolbox did not return an encoded frame."
        case .unsupportedPixelBuffer:
            return "The pixel buffer format is not supported for hardware transcode."
        }
    }
}

/// A thin, synchronous wrapper over `VTCompressionSession` for HEVC/H.264
/// hardware encoding (PB-16, doc 04 §4.2).
public final class HardwareVideoEncoder: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var codec: CMVideoCodecType
        public var bitDepth: Int
        public var bitrate: Int
        public var frameRate: Double

        public init(
            width: Int,
            height: Int,
            codec: CMVideoCodecType = kCMVideoCodecType_HEVC,
            bitDepth: Int = 10,
            bitrate: Int = 8_000_000,
            frameRate: Double = 30
        ) {
            self.width = max(2, width)
            self.height = max(2, height)
            self.codec = codec
            self.bitDepth = bitDepth
            self.bitrate = max(1, bitrate)
            self.frameRate = max(1, frameRate)
        }
    }

    private final class EncodeBox: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var status: OSStatus = noErr
        var sampleBuffer: CMSampleBuffer?
    }

    public let configuration: Configuration
    private let session: VTCompressionSession

    public init(configuration: Configuration) throws {
        self.configuration = configuration

        var session: VTCompressionSession?
        let specification: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder
                as String: true
        ]
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: configuration.width,
            kCVPixelBufferHeightKey as String: configuration.height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: configuration.codec,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw HardwareTranscodeError.sessionCreationFailed(status)
        }
        self.session = session

        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        try set(
            kVTCompressionPropertyKey_AllowFrameReordering,
            kCFBooleanFalse
        )
        try set(
            kVTCompressionPropertyKey_ExpectedFrameRate,
            NSNumber(value: configuration.frameRate)
        )
        try set(
            kVTCompressionPropertyKey_AverageBitRate,
            NSNumber(value: configuration.bitrate)
        )
        try set(
            kVTCompressionPropertyKey_MaxKeyFrameInterval,
            NSNumber(value: max(1, Int(configuration.frameRate)))
        )
        if configuration.codec == kCMVideoCodecType_HEVC {
            try set(
                kVTCompressionPropertyKey_ProfileLevel,
                configuration.bitDepth >= 10
                    ? kVTProfileLevel_HEVC_Main10_AutoLevel
                    : kVTProfileLevel_HEVC_Main_AutoLevel
            )
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// Whether this machine can create a session for the configuration.
    public static func isSupported(
        configuration: Configuration
    ) -> Bool {
        (try? HardwareVideoEncoder(configuration: configuration)) != nil
    }

    /// Encodes one pixel buffer and waits for the compressed sample.
    public func encode(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime
    ) throws -> CMSampleBuffer {
        let box = EncodeBox()
        let pointer = Unmanaged.passRetained(box).toOpaque()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: pointer,
            infoFlagsOut: nil
        )
        guard status == noErr else {
            Unmanaged<EncodeBox>.fromOpaque(pointer).release()
            throw HardwareTranscodeError.encodeFailed(status)
        }

        box.semaphore.wait()
        guard box.status == noErr, let sampleBuffer = box.sampleBuffer else {
            throw HardwareTranscodeError.encodeFailed(box.status)
        }
        return sampleBuffer
    }

    /// Flushes delayed frames.
    public func completeFrames() {
        VTCompressionSessionCompleteFrames(
            session,
            untilPresentationTimeStamp: .invalid
        )
    }

    private func set(_ key: CFString, _ value: Any) throws {
        let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        guard status == noErr else {
            throw HardwareTranscodeError.propertyFailed(
                key as String,
                status
            )
        }
    }

    private static let outputCallback: VTCompressionOutputCallback = {
        refcon,
        sourceFrameRefcon,
        status,
        _,
        sampleBuffer in
        guard let sourceFrameRefcon else {
            return
        }
        let box = Unmanaged<EncodeBox>
            .fromOpaque(sourceFrameRefcon)
            .takeRetainedValue()
        box.status = status
        box.sampleBuffer = sampleBuffer
        box.semaphore.signal()
        _ = refcon
    }
}

/// R3 hardware transcode pipeline: optional Metal tone-map, VideoToolbox
/// encode, and direct rendering into `AVSampleBufferDisplayLayer`
/// (ARCH-P6, PB-16, PB-17).
public final class HardwareTranscodePipeline: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var encoder: HardwareVideoEncoder.Configuration
        public var targetPeakNits: Double
        public var curve: MetalToneMapper.Curve

        public init(
            encoder: HardwareVideoEncoder.Configuration,
            targetPeakNits: Double = 100,
            curve: MetalToneMapper.Curve = .pq
        ) {
            self.encoder = encoder
            self.targetPeakNits = max(1, targetPeakNits)
            self.curve = curve
        }
    }

    public let configuration: Configuration
    public let encoder: HardwareVideoEncoder
    public let toneMapper: MetalToneMapper?
    nonisolated(unsafe) public let displayLayer: AVSampleBufferDisplayLayer?

    public init(
        configuration: Configuration,
        useMetal: Bool = true,
        makeDisplayLayer: Bool = false
    ) throws {
        self.configuration = configuration
        self.encoder = try HardwareVideoEncoder(
            configuration: configuration.encoder
        )
        self.toneMapper = useMetal
            ? try? MetalToneMapper()
            : nil
        self.displayLayer = makeDisplayLayer
            ? AVSampleBufferDisplayLayer()
            : nil
    }

    /// Tone-maps (when requested) and hardware-encodes one decoded frame.
    public func transcode(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime
    ) throws -> CMSampleBuffer {
        var input = pixelBuffer
        if configuration.curve != .passthrough,
           let toneMapper {
            input = try toneMapper.toneMap(
                pixelBuffer: pixelBuffer,
                targetNits: configuration.targetPeakNits,
                curve: configuration.curve
            )
        }
        return try encoder.encode(
            pixelBuffer: input,
            presentationTime: presentationTime,
            duration: duration
        )
    }

    /// Sends an encoded sample to the display layer, if one was configured.
    @MainActor
    public func render(_ sampleBuffer: sending CMSampleBuffer) {
        guard let displayLayer else {
            return
        }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    public func finish() {
        encoder.completeFrames()
    }
}
