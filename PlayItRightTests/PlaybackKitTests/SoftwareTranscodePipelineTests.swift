import CoreKit
import CoreVideo
import Foundation
import Testing
@testable import PlaybackKit

private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
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
    return try #require(pixelBuffer)
}

private final class MockSoftwareDecoder: SoftwareVideoDecoding, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let codec: VideoCodec
        let width: Int
        let height: Int
    }

    private let lock = NSLock()
    private var storedCalls: [Call] = []

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    func decode(
        _ frame: SoftwareVideoFrame,
        codec: VideoCodec,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        lock.lock()
        storedCalls.append(Call(codec: codec, width: width, height: height))
        lock.unlock()
        return try makePixelBuffer(width: width, height: height)
    }
}

private func monitor(_ state: ThermalState) -> ThermalMonitor {
    ThermalMonitor(stateProvider: { state })
}

@Suite("SoftwareTranscodePipeline Tests")
struct SoftwareTranscodePipelineTests {
    @Test("Balanced bias bounds workers to 60% of the CPUs")
    func workerBudget() {
        #expect(
            SoftwareTranscodePipeline.workerCount(
                qualityBias: .balanced,
                processorCount: 10
            ) == 6
        )
        #expect(
            SoftwareTranscodePipeline.workerCount(
                qualityBias: .balanced,
                processorCount: 8
            ) == 4
        )
        #expect(
            SoftwareTranscodePipeline.workerCount(
                qualityBias: .lowestCPU,
                processorCount: 8
            ) == 2
        )
        #expect(
            SoftwareTranscodePipeline.workerCount(
                qualityBias: .bestQuality,
                processorCount: 8
            ) == 8
        )
        #expect(
            SoftwareTranscodePipeline.workerCount(
                qualityBias: .balanced,
                processorCount: 1
            ) == 1
        )
    }

    @Test("An explicit worker cap is honored")
    func workerCap() {
        let pipeline = SoftwareTranscodePipeline(
            configuration: SoftwareTranscodeConfiguration(
                qualityBias: .bestQuality,
                maximumWorkerCount: 3
            ),
            decoder: MockSoftwareDecoder(),
            thermalMonitor: monitor(.nominal),
            processorCount: 12
        )
        #expect(pipeline.workerCount == 3)
    }

    @Test("VP9 frames decode into a raw pixel buffer")
    func decodesVP9() throws {
        let decoder = MockSoftwareDecoder()
        let pipeline = SoftwareTranscodePipeline(
            configuration: SoftwareTranscodeConfiguration(
                qualityBias: .balanced
            ),
            decoder: decoder,
            thermalMonitor: monitor(.nominal),
            processorCount: 8
        )
        let frame = SoftwareVideoFrame(
            data: Data([0x82, 0x49, 0x83, 0x42]),
            presentationTime: 1.5,
            isKeyframe: true
        )

        let result = try pipeline.decode(
            frame,
            codec: .vp9,
            sourceWidth: 3_840,
            sourceHeight: 2_160
        )

        #expect(CVPixelBufferGetWidth(result.pixelBuffer) == 3_840)
        #expect(CVPixelBufferGetHeight(result.pixelBuffer) == 2_160)
        #expect(result.width == 3_840)
        #expect(result.height == 2_160)
        #expect(!result.isThermallyDowngraded)
        #expect(result.thermalState == .nominal)
        #expect(result.workerCount == 4)
        #expect(decoder.calls == [
            MockSoftwareDecoder.Call(codec: .vp9, width: 3_840, height: 2_160)
        ])
    }

    @Test("Serious thermal pressure drops 4K decoding to 1080p")
    func thermalDowngrade() throws {
        let decoder = MockSoftwareDecoder()
        let pipeline = SoftwareTranscodePipeline(
            configuration: SoftwareTranscodeConfiguration(),
            decoder: decoder,
            thermalMonitor: monitor(.serious),
            processorCount: 8
        )
        let result = try pipeline.decode(
            SoftwareVideoFrame(data: Data([0x01]), isKeyframe: true),
            codec: .av1,
            sourceWidth: 3_840,
            sourceHeight: 2_160
        )

        #expect(result.isThermallyDowngraded)
        #expect(result.height == 1_080)
        #expect(result.width == 1_920)
        #expect(result.thermalState == .serious)
        #expect(decoder.calls == [
            MockSoftwareDecoder.Call(codec: .av1, width: 1_920, height: 1_080)
        ])
    }

    @Test("Fair heat and non-4K sources keep their resolution")
    func noDowngrade() {
        let configuration = SoftwareTranscodeConfiguration()
        #expect(
            SoftwareTranscodePipeline.targetHeight(
                sourceHeight: 2_160,
                thermalState: .fair,
                configuration: configuration
            ) == 2_160
        )
        #expect(
            SoftwareTranscodePipeline.targetHeight(
                sourceHeight: 2_160,
                thermalState: .serious,
                configuration: configuration
            ) == 1_080
        )
        #expect(
            SoftwareTranscodePipeline.targetHeight(
                sourceHeight: 1_080,
                thermalState: .critical,
                configuration: configuration
            ) == 1_080
        )
    }

    @Test("A missing FFmpeg decoder fails with a clear error")
    func unavailableDecoder() {
        let pipeline = SoftwareTranscodePipeline(
            thermalMonitor: monitor(.nominal),
            processorCount: 4
        )
        var failure: Error?
        do {
            _ = try pipeline.decode(
                SoftwareVideoFrame(data: Data()),
                codec: .vp9,
                sourceWidth: 1_920,
                sourceHeight: 1_080
            )
        } catch {
            failure = error
        }
        #expect(failure as? StreamProbeError == .ffmpegUnavailable)
    }
}
