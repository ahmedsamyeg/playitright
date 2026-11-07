import CoreVideo
import Foundation
import Testing
@testable import PlaybackKit

// MARK: - Fakes

private final class RecordingSoftwareDecoder: SoftwareVideoDecoding, @unchecked Sendable {
    struct Call: Equatable {
        let codec: VideoCodec
        let width: Int
        let height: Int
        let isKeyframe: Bool
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
        storedCalls.append(
            Call(
                codec: codec,
                width: width,
                height: height,
                isKeyframe: frame.isKeyframe
            )
        )
        lock.unlock()

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            max(1, width),
            max(1, height),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw ExtendedCodecError.notAnExtendedCodec(codec)
        }
        return buffer
    }
}

private func makeFrame(
    isKeyframe: Bool = true,
    presentationTime: TimeInterval = 0
) -> SoftwareVideoFrame {
    SoftwareVideoFrame(
        data: Data(repeating: 0x42, count: 64),
        presentationTime: presentationTime,
        isKeyframe: isKeyframe
    )
}

// MARK: - Tests

@Suite("ExtendedCodecs Tests")
struct ExtendedCodecsTests {
    private let requiredCodecs: [VideoCodec] = [
        .av1,
        .vp8,
        .vp9,
        .vvc,
        .mpeg1,
        .mpeg2,
        .vc1,
        .wmv3,
        .divx
    ]

    @Test("The registry covers every extended codec with an FFmpeg name")
    func registryCoverage() {
        #expect(ExtendedCodecRegistry.codecs == requiredCodecs)

        for codec in requiredCodecs {
            let profile = ExtendedCodecRegistry.profile(for: codec)
            #expect(profile != nil, "\(codec.rawValue) missing from registry")
            #expect(profile?.ffmpegDecoderName.isEmpty == false)
            #expect(profile?.displayName.isEmpty == false)
            #expect(profile?.requiresPro == true)
        }

        #expect(ExtendedCodecRegistry.profile(for: .av1)?.ffmpegDecoderName == "av1")
        #expect(
            ExtendedCodecRegistry.profile(for: .mpeg2)?.ffmpegDecoderName
                == "mpeg2video"
        )
        #expect(
            ExtendedCodecRegistry.profile(for: .divx)?.ffmpegDecoderName
                == "mpeg4"
        )

        // H.264 and HEVC stay on the native hardware path.
        #expect(ExtendedCodecRegistry.profile(for: .h264) == nil)
        #expect(ExtendedCodecRegistry.profile(for: .hevc) == nil)
    }

    @Test("Pro decodes every extended codec through the software decoder")
    func proDecodesEveryCodec() throws {
        let stub = RecordingSoftwareDecoder()
        let decoder = ExtendedCodecsDecoder(
            decoder: stub,
            entitlement: StaticProEntitlement.pro
        )

        for codec in requiredCodecs {
            #expect(decoder.isExtendedCodec(codec))
            #expect(decoder.canDecode(codec))

            let buffer = try decoder.decode(
                makeFrame(isKeyframe: true),
                codec: codec,
                width: 640,
                height: 360
            )
            #expect(CVPixelBufferGetWidth(buffer) == 640)
            #expect(CVPixelBufferGetHeight(buffer) == 360)
        }

        #expect(stub.calls.map(\.codec) == requiredCodecs)
        #expect(stub.calls.allSatisfy { $0.width == 640 && $0.height == 360 })
        #expect(stub.calls.allSatisfy { $0.isKeyframe })
        #expect(decoder.availableCodecs == requiredCodecs)
        #expect(decoder.lockedCodecs.isEmpty)
    }

    @Test("Free tier blocks every extended codec before decoding")
    func freeTierBlocksExtendedCodecs() throws {
        let stub = RecordingSoftwareDecoder()
        let decoder = ExtendedCodecsDecoder(
            decoder: stub,
            entitlement: StaticProEntitlement.free
        )

        for codec in requiredCodecs {
            #expect(decoder.isExtendedCodec(codec))
            #expect(decoder.canDecode(codec) == false)
            #expect(throws: ExtendedCodecError.proRequired(codec)) {
                _ = try decoder.decode(
                    makeFrame(),
                    codec: codec,
                    width: 640,
                    height: 360
                )
            }
        }

        #expect(stub.calls.isEmpty, "Locked codecs must never reach the decoder")
        #expect(decoder.availableCodecs.isEmpty)
        #expect(decoder.lockedCodecs == requiredCodecs)
    }

    @Test("Native codecs are rejected rather than silently sent to FFmpeg")
    func nativeCodecsAreRejected() throws {
        let stub = RecordingSoftwareDecoder()
        let decoder = ExtendedCodecsDecoder(
            decoder: stub,
            entitlement: StaticProEntitlement.pro
        )

        for codec in [VideoCodec.h264, .hevc, .other] {
            #expect(decoder.isExtendedCodec(codec) == false)
            #expect(decoder.canDecode(codec) == false)
            #expect(throws: ExtendedCodecError.notAnExtendedCodec(codec)) {
                _ = try decoder.decode(
                    makeFrame(),
                    codec: codec,
                    width: 1_920,
                    height: 1_080
                )
            }
        }

        #expect(stub.calls.isEmpty)
    }

    @Test("The Pro error explains the upsell in plain language")
    func proErrorCopy() {
        let error = ExtendedCodecError.proRequired(.vp9)
        #expect(error.errorDescription?.contains("VP9") == true)
        #expect(error.errorDescription?.contains("Pro") == true)

        let native = ExtendedCodecError.notAnExtendedCodec(.h264)
        #expect(native.errorDescription?.contains("H264") == true)
    }

    @Test("The gated decoder drops into the R4 software pipeline")
    func integratesWithSoftwareTranscodePipeline() throws {
        let stub = RecordingSoftwareDecoder()
        let gated = ExtendedCodecsDecoder(
            decoder: stub,
            entitlement: StaticProEntitlement.pro
        )
        let pipeline = SoftwareTranscodePipeline(
            configuration: SoftwareTranscodeConfiguration(
                qualityBias: .lowestCPU
            ),
            decoder: gated,
            processorCount: 8
        )

        let result = try pipeline.decode(
            makeFrame(),
            codec: .vp9,
            sourceWidth: 3_840,
            sourceHeight: 2_160
        )

        #expect(result.width == 3_840)
        #expect(result.height == 2_160)
        #expect(result.isThermallyDowngraded == false)
        #expect(result.workerCount == 2)
        #expect(stub.calls.map(\.codec) == [.vp9])
    }

    @Test("A free-tier pipeline still reports the Pro gate")
    func pipelineSurfacesProGate() {
        let pipeline = SoftwareTranscodePipeline(
            decoder: ExtendedCodecsDecoder(
                decoder: RecordingSoftwareDecoder(),
                entitlement: StaticProEntitlement.free
            ),
            processorCount: 8
        )

        #expect(throws: ExtendedCodecError.proRequired(.av1)) {
            _ = try pipeline.decode(
                makeFrame(),
                codec: .av1,
                sourceWidth: 1_920,
                sourceHeight: 1_080
            )
        }
    }
}
