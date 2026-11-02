import CoreMedia
import CoreVideo
import Foundation
import Metal
import Testing
import VideoToolbox
@testable import PlaybackKit

private func makeBGRAPixelBuffer(
    width: Int,
    height: Int,
    value: UInt8
) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
    )
    #expect(status == kCVReturnSuccess)
    let buffer = try #require(pixelBuffer)

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try #require(
        CVPixelBufferGetBaseAddress(buffer)?
            .assumingMemoryBound(to: UInt8.self)
    )
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for row in 0..<height {
        for column in 0..<width {
            let offset = row * bytesPerRow + column * 4
            base[offset] = value
            base[offset + 1] = value
            base[offset + 2] = value
            base[offset + 3] = 255
        }
    }
    return buffer
}

private func firstPixel(_ buffer: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?
        .assumingMemoryBound(to: UInt8.self) else {
        return []
    }
    return [base[0], base[1], base[2], base[3]]
}

@Suite("HardwareTranscodePipeline Tests")
struct HardwareTranscodePipelineTests {
    @Test("The Metal tone mapper compiles and executes on a pixel buffer")
    func metalToneMapper() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            return
        }
        let mapper = try MetalToneMapper()
        let input = try makeBGRAPixelBuffer(
            width: 16,
            height: 16,
            value: 128
        )

        let passthrough = try mapper.toneMap(
            pixelBuffer: input,
            targetNits: 100,
            curve: .passthrough
        )
        #expect(CVPixelBufferGetWidth(passthrough) == 16)
        #expect(CVPixelBufferGetHeight(passthrough) == 16)
        let passthroughPixel = firstPixel(passthrough)
        #expect(passthroughPixel.count == 4)
        for channel in 0..<3 {
            #expect(abs(Int(passthroughPixel[channel]) - 128) <= 1)
        }
        #expect(passthroughPixel[3] == 255)

        let toneMapped = try mapper.toneMap(
            pixelBuffer: input,
            targetNits: 100,
            curve: .pq
        )
        let mappedPixel = firstPixel(toneMapped)
        #expect(mappedPixel.count == 4)
        #expect(mappedPixel[3] == 255)

        let hlg = try mapper.toneMap(
            pixelBuffer: input,
            targetNits: 200,
            curve: .hlg
        )
        #expect(firstPixel(hlg).count == 4)
    }

    @Test("VideoToolbox produces a valid 10-bit HEVC frame")
    func hevcEncode() throws {
        let configuration = HardwareVideoEncoder.Configuration(
            width: 320,
            height: 240,
            codec: kCMVideoCodecType_HEVC,
            bitDepth: 10,
            bitrate: 1_000_000,
            frameRate: 30
        )
        guard HardwareVideoEncoder.isSupported(
            configuration: configuration
        ) else {
            return
        }
        let encoder = try HardwareVideoEncoder(configuration: configuration)
        let pixelBuffer = try makeBGRAPixelBuffer(
            width: 320,
            height: 240,
            value: 96
        )

        var sampleBuffer: CMSampleBuffer?
        for frame in 0..<10 {
            sampleBuffer = try encoder.encode(
                pixelBuffer: pixelBuffer,
                presentationTime: CMTime(
                    value: CMTimeValue(frame),
                    timescale: 30
                ),
                duration: CMTime(value: 1, timescale: 30)
            )
        }
        encoder.completeFrames()

        let output = try #require(sampleBuffer)
        #expect(CMSampleBufferGetNumSamples(output) > 0)
        #expect(CMSampleBufferGetTotalSampleSize(output) > 0)

        if let format = CMSampleBufferGetFormatDescription(output) {
            #expect(
                CMFormatDescriptionGetMediaSubType(format)
                    == kCMVideoCodecType_HEVC
            )
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            #expect(dimensions.width == 320)
            #expect(dimensions.height == 240)
        }
    }

    @Test("The R3 pipeline tone-maps and encodes in one call")
    func pipelineTranscodes() throws {
        let configuration = HardwareTranscodePipeline.Configuration(
            encoder: HardwareVideoEncoder.Configuration(
                width: 160,
                height: 120,
                bitrate: 500_000,
                frameRate: 30
            ),
            targetPeakNits: 150,
            curve: .passthrough
        )
        guard HardwareVideoEncoder.isSupported(
            configuration: configuration.encoder
        ) else {
            return
        }
        let pipeline = try HardwareTranscodePipeline(
            configuration: configuration,
            useMetal: false
        )
        let pixelBuffer = try makeBGRAPixelBuffer(
            width: 160,
            height: 120,
            value: 64
        )
        let sample = try pipeline.transcode(
            pixelBuffer: pixelBuffer,
            presentationTime: .zero,
            duration: CMTime(value: 1, timescale: 30)
        )
        #expect(CMSampleBufferGetTotalSampleSize(sample) > 0)
        pipeline.finish()
    }
}
