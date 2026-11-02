import CapKit
import Foundation
import Testing
@testable import PlaybackKit

private func registry(generation: Int) throws -> CapabilityRegistry {
    let matrix = try CapabilityMatrix.bundled()
    let profile = try #require(
        matrix.profile(forGeneration: generation)
    )
    return CapabilityRegistry(profile: profile)
}

private func sdrSink(
    audio: AudioSetup = .stereo
) -> SinkProfile {
    SinkProfile(
        display: DisplayCapabilities(
            width: 3_840,
            height: 2_160,
            maxRefreshRate: 60
        ),
        audio: AudioCapabilities.declared(audio)
    )
}

private func hdrSink(
    dolbyVision: Bool = false,
    audio: AudioSetup = .receiverAtmos
) -> SinkProfile {
    SinkProfile(
        display: DisplayCapabilities.declared(
            dolbyVision ? .dolbyVision : .hdr10,
            width: 3_840,
            height: 2_160
        ),
        audio: AudioCapabilities.declared(audio)
    )
}

private func makeGraph(
    container: ContainerFormat,
    videoCodec: PlaybackKit.VideoCodec,
    width: Int = 3_840,
    height: Int = 2_160,
    bitDepth: Int = 8,
    hdr: PlaybackKit.HDRFormat = .sdr,
    audioCodec: PlaybackKit.AudioCodec = .aac,
    audioChannels: Int = 2,
    audioAtmos: Bool = false
) -> MediaGraph {
    MediaGraph(
        container: container,
        demuxer: container.isAVFoundationNative ? .avFoundation : .ffmpeg,
        duration: 7_200,
        videoTracks: [
            VideoTrackInfo(
                index: 0,
                codec: videoCodec,
                width: width,
                height: height,
                frameRate: FrameRate(fps: 23.976),
                bitDepth: bitDepth,
                hdrFormat: hdr,
                hasDolbyVisionRPU: hdr.isDolbyVision
            )
        ],
        audioTracks: [
            AudioTrackInfo(
                index: 1,
                codec: audioCodec,
                channels: audioChannels,
                sampleRate: 48_000,
                isAtmos: audioAtmos,
                isDefault: true,
                language: "eng"
            )
        ]
    )
}

@Suite("PipelinePlanner Tests")
struct PipelinePlannerTests {
    @Test("MP4 H.264 SDR on an SDR TV selects R1 direct play")
    func directPlayMP4() throws {
        let planner = PipelinePlanner(
            capabilities: try registry(generation: 3)
        )
        let graph = makeGraph(
            container: .mp4,
            videoCodec: .h264,
            bitDepth: 8
        )
        let plan = planner.plan(graph: graph, sink: sdrSink())

        #expect(plan.rung == .r1Direct)
        #expect(plan.badge == .direct)
        #expect(plan.badge.color == .green)
        #expect(plan.isPlayable)
        #expect(plan.video.decodePath == .hardware)
        #expect(plan.video.colorTransform == .none)
        #expect(plan.video.outputContainer == .mp4)
        #expect(plan.video.outputHDR == .sdr)
        #expect(plan.audio?.route == .nativeDecode)
        #expect(plan.audio?.outputChannels == 2)
        #expect(plan.isServerTranscode == false)
    }

    @Test("MKV HEVC HDR10 on an HDR TV selects R2 remux")
    func remuxMKVHDR() throws {
        let planner = PipelinePlanner(
            capabilities: try registry(generation: 3)
        )
        let graph = makeGraph(
            container: .mkv,
            videoCodec: .hevc,
            bitDepth: 10,
            hdr: .hdr10,
            audioCodec: .eac3,
            audioChannels: 6
        )
        let plan = planner.plan(graph: graph, sink: hdrSink())

        #expect(plan.rung == .r2Remux)
        #expect(plan.badge == .remuxed)
        #expect(plan.badge.color == .blue)
        #expect(plan.isPlayable)
        #expect(plan.video.decodePath == .hardware)
        #expect(plan.video.colorTransform == .none)
        #expect(plan.video.outputContainer == .mp4)
        #expect(plan.video.inputHDR == .hdr10)
        #expect(plan.video.outputHDR == .hdr10)
        #expect(plan.audio?.route == .passthrough)
        #expect(plan.audio?.outputCodec == "eac3")
    }

    @Test("4K DoVi Profile 8.1 MKV on an SDR TV selects system tone-map R2")
    func dolbyVisionToSDR() throws {
        let planner = PipelinePlanner(
            capabilities: try registry(generation: 4)
        )
        let graph = makeGraph(
            container: .mkv,
            videoCodec: .hevc,
            bitDepth: 10,
            hdr: .dolbyVision81,
            audioCodec: .eac3,
            audioChannels: 8,
            audioAtmos: true
        )
        let plan = planner.plan(graph: graph, sink: sdrSink(audio: .stereo))

        #expect(plan.rung == .r2Remux)
        #expect(plan.isPlayable)
        #expect(plan.video.inputHDR == .dolbyVision81)
        #expect(plan.video.colorTransform == .systemToneMap)
        #expect(plan.video.outputHDR == .sdr)
        #expect(plan.audio?.route == .downmixToStereo)
    }

    @Test("Gen 3 AV1 selects R4 software transcode")
    func av1SoftwareOnGen3() throws {
        let planner = PipelinePlanner(
            capabilities: try registry(generation: 3)
        )
        let graph = makeGraph(
            container: .mkv,
            videoCodec: .av1,
            bitDepth: 10,
            hdr: .hdr10
        )
        let plan = planner.plan(graph: graph, sink: hdrSink())

        #expect(plan.rung == .r4SoftwareTranscode)
        #expect(plan.badge == .transcodedSW)
        #expect(plan.badge.color == .orange)
        #expect(plan.video.decodePath == .software)
        #expect(plan.video.outputCodec == "h264")
    }

    @Test("Gen 4 AV1 uses the hardware decoder and remuxes")
    func av1HardwareOnGen4() throws {
        let planner = PipelinePlanner(
            capabilities: try registry(generation: 4)
        )
        let graph = makeGraph(
            container: .mkv,
            videoCodec: .av1,
            bitDepth: 10,
            hdr: .hdr10
        )
        let plan = planner.plan(graph: graph, sink: hdrSink())

        #expect(plan.rung == .r2Remux)
        #expect(plan.video.decodePath == .hardware)
        #expect(plan.badge == .remuxed)
    }

    @Test("A user quality lock caps the ladder only when feasible")
    func qualityLockCapsRung() throws {
        let planner = PipelinePlanner(
            capabilities: try registry(generation: 3)
        )
        let graph = makeGraph(
            container: .mkv,
            videoCodec: .hevc,
            bitDepth: 10,
            hdr: .hdr10
        )
        let precise = PlaybackPreferences(colorMode: .precise)
        let unconstrained = planner.plan(
            graph: graph,
            sink: sdrSink(),
            preferences: precise
        )
        #expect(unconstrained.rung == .r3HardwareTranscode)
        #expect(unconstrained.video.colorTransform == .explicitToneMap)

        let capped = planner.plan(
            graph: graph,
            sink: sdrSink(),
            preferences: PlaybackPreferences(
                maximumRung: .r2Remux,
                colorMode: .precise
            )
        )
        #expect(capped.rung == .r2Remux)
        #expect(capped.rungCapApplied)
        #expect(capped.badge == .remuxed)
        #expect(capped.video.colorTransform == .systemToneMap)
        #expect(capped.isPlayable)

        // A cap that would make the file unplayable is ignored.
        let av1 = makeGraph(
            container: .mkv,
            videoCodec: .av1,
            bitDepth: 10
        )
        let impossibleCap = planner.plan(
            graph: av1,
            sink: sdrSink(),
            preferences: PlaybackPreferences(maximumRung: .r2Remux)
        )
        #expect(impossibleCap.rung == .r4SoftwareTranscode)
        #expect(impossibleCap.rungCapApplied == false)
    }

    @Test("DTS on a stereo sink software-decodes and downmixes")
    func dtsDownmix() throws {
        let planner = PipelinePlanner(
            capabilities: try registry(generation: 3)
        )
        let graph = makeGraph(
            container: .mkv,
            videoCodec: .hevc,
            bitDepth: 10,
            hdr: .hdr10,
            audioCodec: .dts,
            audioChannels: 8
        )
        let plan = planner.plan(graph: graph, sink: sdrSink())

        #expect(plan.audio?.route == .downmixToStereo)
        #expect(plan.audio?.outputChannels == 2)
        #expect(plan.audio?.route.needsSoftwareDecode == true)
        #expect(plan.reasons.contains { $0.contains("decoded and downmixed") })
    }

    @Test("Server transcode is offered only when local playback needs software decode")
    func serverTranscodePreference() throws {
        let planner = PipelinePlanner(
            capabilities: try registry(generation: 3)
        )
        let preferences = PlaybackPreferences(preferServerTranscode: true)

        let direct = makeGraph(
            container: .mp4,
            videoCodec: .h264
        )
        let directPlan = planner.plan(
            graph: direct,
            sink: sdrSink(),
            preferences: preferences,
            serverTranscodeAvailable: true
        )
        #expect(directPlan.rung == .r1Direct)

        let av1 = makeGraph(
            container: .mkv,
            videoCodec: .av1,
            bitDepth: 10
        )
        let serverPlan = planner.plan(
            graph: av1,
            sink: sdrSink(),
            preferences: preferences,
            serverTranscodeAvailable: true
        )
        #expect(serverPlan.rung == .r5ServerTranscode)
        #expect(serverPlan.badge == .server)
        #expect(serverPlan.badge.color == .gray)
        #expect(serverPlan.isServerTranscode)
    }

    @Test("Planning is deterministic for identical inputs")
    func deterministicPlan() throws {
        let planner = PipelinePlanner(
            capabilities: try registry(generation: 3)
        )
        let graph = makeGraph(
            container: .mkv,
            videoCodec: .hevc,
            bitDepth: 10,
            hdr: .hdr10,
            audioCodec: .eac3,
            audioChannels: 6
        )
        let first = planner.plan(graph: graph, sink: hdrSink())
        let second = planner.plan(graph: graph, sink: hdrSink())
        #expect(first == second)
    }

    @Test("Every rung has the documented badge and color")
    func badgeMapping() {
        #expect(QualityBadge.forRung(.r1Direct) == .direct)
        #expect(QualityBadge.forRung(.r2Remux) == .remuxed)
        #expect(QualityBadge.forRung(.r3HardwareTranscode) == .transcodedHW)
        #expect(QualityBadge.forRung(.r4SoftwareTranscode) == .transcodedSW)
        #expect(QualityBadge.forRung(.r5ServerTranscode) == .server)

        #expect(QualityBadge.direct.color == .green)
        #expect(QualityBadge.remuxed.color == .blue)
        #expect(QualityBadge.transcodedHW.color == .amber)
        #expect(QualityBadge.transcodedSW.color == .orange)
        #expect(QualityBadge.server.color == .gray)
    }
}
