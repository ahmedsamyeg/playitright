import Foundation
import Testing
@testable import PlaybackKit

private func stereoPlan(
    channels: Int = 8,
    isAtmos: Bool = true
) -> AudioPipelinePlan {
    AudioPipelinePlan(
        inputCodec: "truehd",
        outputCodec: "truehd",
        route: .passthrough,
        channels: channels,
        outputChannels: channels,
        isAtmos: isAtmos
    )
}

private func sink(maxChannels: Int) -> AudioCapabilities {
    AudioCapabilities(
        setup: maxChannels <= 2 ? .stereo : .receiverAtmos,
        maxChannels: maxChannels,
        supportsAtmos: maxChannels > 2
    )
}

@Suite("AudioPipeline Tests")
struct AudioPipelineTests {
    @Test("7.1 TrueHD to 2.0 BS.775 keeps dialog balanced")
    func stereoDownmixDialogBalance() {
        let matrix = AudioDownmixMatrix.ituBS775(
            from: .surround71,
            to: .stereo
        )
        #expect(matrix.inputChannelCount == 8)
        #expect(matrix.outputChannelCount == 2)

        // Center-only content must land equally in left and right.
        let centerOnly = matrix.mix([0, 0, 1, 0, 0, 0, 0, 0])
        #expect(centerOnly.count == 2)
        #expect(abs(centerOnly[0] - centerOnly[1]) < 0.000_001)
        #expect(abs(centerOnly[0] - Float(AudioDownmixMatrix.surroundGain)) < 0.000_001)

        let leftGain = matrix.coefficient(output: .left, input: .center)
        let rightGain = matrix.coefficient(output: .right, input: .center)
        #expect(abs(leftGain - rightGain) < 0.000_001)
        #expect(leftGain > 0)
    }

    @Test("Stereo BS.775 folds surrounds, folds backs, and omits LFE")
    func stereoDownmixGains() {
        let matrix = AudioDownmixMatrix.ituBS775(
            from: .surround71,
            to: .stereo,
            dialogEnhancementDB: 3
        )
        let standard = AudioDownmixMatrix.ituBS775(
            from: .surround71,
            to: .stereo
        )

        // Dialog enhancement only raises the center contribution.
        #expect(
            matrix.coefficient(output: .left, input: .center)
                > standard.coefficient(output: .left, input: .center)
        )
        #expect(
            abs(
                matrix.coefficient(output: .left, input: .left)
                    - standard.coefficient(output: .left, input: .left)
            ) < 0.000_001
        )

        #expect(
            abs(
                matrix.coefficient(output: .left, input: .leftSurround)
                    - AudioDownmixMatrix.surroundGain
            ) < 0.000_001
        )
        #expect(
            abs(
                matrix.coefficient(output: .left, input: .leftBack)
                    - AudioDownmixMatrix.surroundGain
                        * AudioDownmixMatrix.backSurroundGain
            ) < 0.000_001
        )
        #expect(matrix.coefficient(output: .left, input: .lfe) == 0)
        #expect(matrix.coefficient(output: .left, input: .right) == 0)

        // A full 7.1 frame produces finite stereo at the expected length.
        let output = matrix.mix([0.5, 0.4, 0.3, 0.2, 0.1, 0.05, 0.02, 0.01])
        #expect(output.count == 2)
        #expect(output[0].isFinite)
        #expect(output[1].isFinite)
    }

    @Test("7.1 to 5.1 keeps the bed and folds back surrounds into the sides")
    func surroundDowmix() {
        let matrix = AudioDownmixMatrix.ituBS775(
            from: .surround71,
            to: .surround51
        )
        #expect(matrix.outputChannelCount == 6)
        #expect(matrix.coefficient(output: .center, input: .center) == 1)
        #expect(matrix.coefficient(output: .lfe, input: .lfe) == 1)
        #expect(matrix.coefficient(output: .leftSurround, input: .leftSurround) == 1)
        #expect(
            abs(
                matrix.coefficient(output: .leftSurround, input: .leftBack)
                    - AudioDownmixMatrix.backSurroundGain
            ) < 0.000_001
        )
        #expect(matrix.coefficient(output: .leftSurround, input: .rightBack) == 0)
    }

    @Test("Silence triggers fallback after two seconds")
    func silenceDetection() {
        let monitor = PassthroughMonitor(fallbackAfter: 2)

        monitor.record(samples: [0, 0], at: 0)
        #expect(monitor.isSilent)
        #expect(!monitor.shouldFallBack(at: 1.9))
        #expect(monitor.silentDuration(at: 1) == 1)
        #expect(monitor.shouldFallBack(at: 2))
        #expect(monitor.lastActivity == 0)
    }

    @Test("Audible audio resets the silence timer")
    func silenceResetsOnAudio() {
        let monitor = PassthroughMonitor(fallbackAfter: 2)
        monitor.record(samples: [0, 0], at: 0)
        #expect(monitor.shouldFallBack(at: 2))

        monitor.record(samples: [0.25, 0], at: 2.1)
        #expect(!monitor.isSilent)
        #expect(!monitor.shouldFallBack(at: 5))

        monitor.record(samples: [0, 0], at: 6)
        #expect(monitor.silenceStartedAt == 6)
        #expect(!monitor.shouldFallBack(at: 7.9))

        monitor.recordActivity(at: 8)
        #expect(!monitor.shouldFallBack(at: 20))
    }

    @Test("Passthrough silence falls back to stereo downmix")
    func passthroughFallback() {
        let plan = stereoPlan(channels: 8)
        let pipeline = AudioPipeline(plan: plan, sink: sink(maxChannels: 2))

        let first = pipeline.process([0, 0, 0, 0, 0, 0, 0, 0], at: 0)
        #expect(first.isPassthrough)
        #expect(first.route == .passthrough)
        #expect(!first.didFallBack)

        let stillPassthrough = pipeline.process(
            [0, 0, 0, 0, 0, 0, 0, 0],
            at: 1.9
        )
        #expect(stillPassthrough.isPassthrough)

        let fallback = pipeline.process(
            [0, 0, 0, 0, 0, 0, 0, 0],
            at: 2.1
        )
        #expect(fallback.didFallBack)
        #expect(fallback.previousRoute == .passthrough)
        #expect(fallback.route == .downmixToStereo)
        #expect(!fallback.isPassthrough)
        #expect(fallback.samples.count == 2)

        #expect(pipeline.plan.route == .downmixToStereo)
        #expect(pipeline.plan.outputCodec == "pcm")
        #expect(pipeline.plan.outputChannels == 2)
        #expect(!pipeline.plan.isAtmos)
        #expect(pipeline.decodeKind == .software)
        #expect(pipeline.matrix?.outputChannelCount == 2)
    }

    @Test("Passthrough failure decodes directly when the sink fits the source")
    func passthroughFallbackWithoutDownmix() {
        let plan = stereoPlan(channels: 6, isAtmos: false)
        let pipeline = AudioPipeline(plan: plan, sink: sink(maxChannels: 8))

        _ = pipeline.process([0, 0, 0, 0, 0, 0], at: 0)
        let fallback = pipeline.process([0, 0, 0, 0, 0, 0], at: 2.0)

        #expect(fallback.didFallBack)
        #expect(fallback.route == .softwareDecode)
        #expect(fallback.samples.count == 6)
        #expect(pipeline.matrix == nil)
        #expect(pipeline.plan.outputChannels == 6)
    }

    @Test("A downmix route applies the matrix to every frame")
    func downmixRouteProcessesFrames() {
        let plan = AudioPipelinePlan(
            inputCodec: "truehd",
            outputCodec: "pcm",
            route: .downmixToStereo,
            channels: 8,
            outputChannels: 2,
            isAtmos: false
        )
        let pipeline = AudioPipeline(plan: plan, sink: sink(maxChannels: 2))
        #expect(pipeline.decodeKind == .software)
        #expect(pipeline.matrix?.outputChannelCount == 2)

        let output = pipeline.process(
            [0, 0, 1, 0, 0, 0, 0, 0],
            at: 0
        )
        #expect(!output.isPassthrough)
        #expect(output.samples.count == 2)
        #expect(abs(output.samples[0] - output.samples[1]) < 0.000_001)
        #expect(output.samples[0] > 0)
    }

    @Test("Native decode and passthrough report the right decode kind")
    func decodeKinds() {
        let native = AudioPipeline(
            plan: AudioPipelinePlan(
                inputCodec: "aac",
                outputCodec: "pcm",
                route: .nativeDecode,
                channels: 2,
                outputChannels: 2,
                isAtmos: false
            ),
            sink: sink(maxChannels: 2)
        )
        #expect(native.decodeKind == .hardware)
        #expect(native.matrix == nil)

        let passthrough = AudioPipeline(
            plan: stereoPlan(channels: 6, isAtmos: false),
            sink: sink(maxChannels: 8)
        )
        #expect(passthrough.decodeKind == .passthrough)
    }
}
