import Foundation
import Testing
@testable import PlaybackKit

// MARK: - Fakes

private final class StubHDAudioDecoder: HDAudioDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: HDAudioPCMBuffer
    private var storedCalls: [AudioCodec] = []

    init(_ buffer: HDAudioPCMBuffer) {
        self.buffer = buffer
    }

    var calls: [AudioCodec] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    func decode(
        _ packet: HDAudioPacket,
        codec: AudioCodec
    ) throws -> HDAudioPCMBuffer {
        lock.lock()
        storedCalls.append(codec)
        lock.unlock()
        return buffer
    }
}

private func makeBuffer(
    layout: AudioChannelLayout = .surround71,
    frames: [[Float]],
    sampleRate: Int = 48_000,
    isAtmosBed: Bool = false
) -> HDAudioPCMBuffer {
    HDAudioPCMBuffer(
        samples: frames.flatMap { $0 },
        sampleRate: sampleRate,
        layout: layout,
        isAtmosBed: isAtmosBed
    )
}

private func makePacket(
    isAtmos: Bool = false,
    layout: AudioChannelLayout = .surround71
) -> HDAudioPacket {
    HDAudioPacket(
        data: Data(repeating: 0x11, count: 128),
        sampleRate: 48_000,
        layout: layout,
        isAtmos: isAtmos
    )
}

// MARK: - Tests

@Suite("HDAudioDecoder Tests")
struct HDAudioDecoderTests {
    private let hdCodecs: [AudioCodec] = [.dts, .dtsHD, .truehd]

    @Test("The decoder advertises DTS, DTS-HD MA, and TrueHD only")
    func supportedCodecs() {
        #expect(HDAudioDecoder.supportedCodecs == hdCodecs)
        #expect(HDAudioDecoder.displayName(for: .dtsHD) == "DTS-HD Master Audio")
        #expect(HDAudioDecoder.displayName(for: .truehd) == "Dolby TrueHD")

        let decoder = HDAudioDecoder()
        for codec in hdCodecs {
            #expect(decoder.isHDAudioCodec(codec))
        }
        for codec in [AudioCodec.aac, .ac3, .eac3, .flac, .pcm] {
            #expect(decoder.isHDAudioCodec(codec) == false)
        }
    }

    @Test("DTS-HD MA decodes to a 5.1 float buffer")
    func dtsHDDecodesToSurround() throws {
        let buffer = makeBuffer(
            layout: .surround71,
            frames: [
                [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
                [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
            ]
        )
        let stub = StubHDAudioDecoder(buffer)
        let decoder = HDAudioDecoder(
            decoder: stub,
            entitlement: StaticProEntitlement.pro
        )

        let result = try decoder.decode(
            makePacket(layout: .surround71),
            codec: .dtsHD,
            targetChannels: 6
        )

        #expect(stub.calls == [.dtsHD])
        #expect(result.outputChannels == 6)
        #expect(result.outputLayout == .surround51)
        #expect(result.wasDownmixed)
        #expect(result.frameCount == 2)
        #expect(result.samples.count == 12)
        #expect(result.isAtmosBed == false)
        #expect(result.sampleRate == 48_000)
    }

    @Test("DTS stereo downmix keeps dialog centered and drops LFE")
    func dtsStereoDownmix() throws {
        // Center-only content in a 7.1 bed.
        let buffer = makeBuffer(
            layout: .surround71,
            frames: [[0, 0, 0.5, 0.9, 0, 0, 0, 0]]
        )
        let decoder = HDAudioDecoder(
            decoder: StubHDAudioDecoder(buffer),
            entitlement: StaticProEntitlement.pro
        )

        let result = try decoder.decode(
            makePacket(),
            codec: .dts,
            targetChannels: 2
        )

        #expect(result.outputChannels == 2)
        #expect(result.wasDownmixed)
        let left = result.samples[0]
        let right = result.samples[1]
        #expect(abs(left - right) < 0.000_001)
        #expect(left > 0)
        // LFE never reaches a stereo output.
        #expect(abs(left - 0.9) > 0.1)
    }

    @Test("TrueHD Atmos extracts the 7.1 bed")
    func trueHDAtmosBedExtraction() throws {
        let bedFrame: [Float] = [
            0.1, 0.1, 0.2, 0.3,
            0.4, 0.4, 0.5, 0.5
        ]
        let buffer = makeBuffer(
            layout: .surround71,
            frames: [bedFrame],
            isAtmosBed: true
        )
        let stub = StubHDAudioDecoder(buffer)
        let decoder = HDAudioDecoder(
            decoder: stub,
            entitlement: StaticProEntitlement.pro
        )

        let result = try decoder.decode(
            makePacket(isAtmos: true),
            codec: .truehd,
            targetChannels: 8
        )

        #expect(stub.calls == [.truehd])
        #expect(result.isAtmosBed)
        #expect(result.outputLayout == .surround71)
        #expect(result.wasDownmixed == false)
        #expect(result.samples == bedFrame)
        #expect(result.frameCount == 1)
    }

    @Test("TrueHD Atmos folds the bed to 5.1 without the object layer")
    func trueHDAtmosTo51() throws {
        let buffer = makeBuffer(
            layout: .surround71,
            frames: [
                [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
            ],
            isAtmosBed: true
        )
        let decoder = HDAudioDecoder(
            decoder: StubHDAudioDecoder(buffer),
            entitlement: StaticProEntitlement.pro
        )

        let result = try decoder.decode(
            makePacket(isAtmos: true),
            codec: .truehd,
            targetChannels: 6
        )

        #expect(result.isAtmosBed)
        #expect(result.outputChannels == 6)
        #expect(result.wasDownmixed)
        #expect(result.frameCount == 1)
        // Back surrounds fold into the side surrounds.
        let leftSurround = result.samples[4]
        let rightSurround = result.samples[5]
        #expect(leftSurround > Float(0.5))
        #expect(rightSurround > Float(0.6))
    }

    @Test("Free tier blocks every HD audio codec before decoding")
    func freeTierBlocksHDAudio() {
        let stub = StubHDAudioDecoder(
            makeBuffer(frames: [[0, 0, 0, 0, 0, 0, 0, 0]])
        )
        let decoder = HDAudioDecoder(
            decoder: stub,
            entitlement: StaticProEntitlement.free
        )

        for codec in hdCodecs {
            #expect(decoder.canDecode(codec) == false)
            #expect(throws: HDAudioError.proRequired(codec)) {
                _ = try decoder.decode(
                    makePacket(),
                    codec: codec,
                    targetChannels: 6
                )
            }
        }

        #expect(stub.calls.isEmpty)
    }

    @Test("Native audio codecs are rejected rather than sent to FFmpeg")
    func nativeCodecsAreRejected() {
        let stub = StubHDAudioDecoder(makeBuffer(frames: [[0, 0]]))
        let decoder = HDAudioDecoder(
            decoder: stub,
            entitlement: StaticProEntitlement.pro
        )

        for codec in [AudioCodec.aac, .eac3, .pcm] {
            #expect(decoder.canDecode(codec) == false)
            #expect(throws: HDAudioError.notAnHDAudioCodec(codec)) {
                _ = try decoder.decode(
                    makePacket(),
                    codec: codec,
                    targetChannels: 2
                )
            }
        }

        #expect(stub.calls.isEmpty)
    }

    @Test("The Pro error names the audio format")
    func proErrorCopy() {
        let error = HDAudioError.proRequired(.dtsHD)
        #expect(
            error.errorDescription?.contains("DTS-HD Master Audio") == true
        )
        #expect(error.errorDescription?.contains("Pro") == true)

        let native = HDAudioError.notAnHDAudioCodec(.aac)
        #expect(native.errorDescription?.contains("AAC") == true)
    }

    @Test("Sink limits choose stereo, 5.1, or the source layout")
    func outputLayoutForSink() {
        #expect(
            HDAudioDecoder.outputLayout(
                for: 2,
                inputLayout: .surround71
            ) == .stereo
        )
        #expect(
            HDAudioDecoder.outputLayout(
                for: 6,
                inputLayout: .surround71
            ) == .surround51
        )
        #expect(
            HDAudioDecoder.outputLayout(
                for: 8,
                inputLayout: .surround71
            ) == .surround71
        )
    }
}
