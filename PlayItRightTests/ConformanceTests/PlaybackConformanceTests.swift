import CapKit
import Foundation
import PlaybackKit
import Testing

/// The Phase 1 alpha playback conformance gate: real mini-assets plus recorded
/// probe results for formats that need licensed encoders (NFR-25, PB-G1/PB-G2,
/// doc 09 §8, doc 10 §Phase 1).
@Suite("PlaybackConformance Tests")
struct PlaybackConformanceTests {
    private static let maximumAssetBytes = 5 * 1_024 * 1_024
    private static let maximumProbeLatency: TimeInterval = 2

    // MARK: - Fixtures

    private func registry() throws -> CapabilityRegistry {
        let matrix = try CapabilityMatrix.bundled()
        let profile = try #require(matrix.profile(forGeneration: 4))
        return CapabilityRegistry(profile: profile)
    }

    private func dolbyVisionSink() -> SinkProfile {
        SinkProfile(
            display: DisplayCapabilities.declared(.dolbyVision),
            audio: AudioCapabilities.declared(.receiverAtmos)
        )
    }

    /// Probes a real fixture, or returns the recorded graph for encoder-locked
    /// formats.
    private func graph(for asset: ConformanceAsset) async throws -> MediaGraph {
        if let recorded = AssetRegistry.graph(for: asset) {
            return recorded
        }
        let url = try #require(
            AssetRegistry.fixtureURL(for: asset),
            "Missing fixture for \(asset.id)"
        )
        return try await MediaGraph.probe(url: url)
    }

    // MARK: - Matrix coverage

    @Test("The matrix covers every required Phase 1 format")
    func matrixCoverage() {
        let ids = Set(AssetRegistry.assets.map(\.id))
        let required: Set<String> = [
            "h264-8bit-aac",
            "hevc-8bit-sdr-aac",
            "hevc-10bit-sdr-ac3",
            "hevc-10bit-hdr10-eac3",
            "hevc-10bit-hlg-eac3",
            "dovi-profile-5",
            "dovi-profile-8",
            "dovi-profile-8-1",
            "eac3-atmos"
        ]
        #expect(required.isSubset(of: ids))

        let hdr = Set(AssetRegistry.assets.map(\.hdrFormat))
        #expect(hdr.contains(.sdr))
        #expect(hdr.contains(.hdr10))
        #expect(hdr.contains(.hlg))
        #expect(hdr.contains(.dolbyVision5))
        #expect(hdr.contains(.dolbyVision8))
        #expect(hdr.contains(.dolbyVision81))

        let audio = Set(AssetRegistry.assets.map(\.audioCodec))
        #expect(audio.contains(.aac))
        #expect(audio.contains(.ac3))
        #expect(audio.contains(.eac3))
        #expect(AssetRegistry.assets.contains { $0.isAtmos })
    }

    @Test("Every bundled fixture exists and stays within the 5 MB budget")
    func bundledAssetsAreSmall() throws {
        for asset in AssetRegistry.realAssets {
            let url = try #require(
                AssetRegistry.fixtureURL(for: asset),
                "Missing fixture for \(asset.id)"
            )
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let size = try #require(values.fileSize)
            #expect(size > 0, "\(asset.id) is empty")
            #expect(
                size <= Self.maximumAssetBytes,
                "\(asset.id) is \(size) bytes, over the 5 MB conformance budget"
            )
        }
    }

    // MARK: - Real asset probing & latency

    @Test("Bundled assets probe within the local 2-second startup budget")
    func probeLatency() async throws {
        // Warm the AVFoundation path once so the measured runs reflect a real
        // startup rather than first-use framework loading.
        let warmup = try #require(AssetRegistry.realAssets.first)
        let warmupURL = try #require(AssetRegistry.fixtureURL(for: warmup))
        _ = try await MediaGraph.probe(url: warmupURL)

        for asset in AssetRegistry.realAssets {
            let url = try #require(AssetRegistry.fixtureURL(for: asset))
            let start = Date()
            let graph = try await MediaGraph.probe(url: url)
            let elapsed = Date().timeIntervalSince(start)

            #expect(
                elapsed <= Self.maximumProbeLatency,
                "\(asset.id) probed in \(elapsed)s, over the 2 s budget"
            )
            #expect(graph.primaryVideoTrack != nil)
        }
    }

    @Test("Real assets expose the expected video and audio tracks")
    func realAssetsProbeAsAuthored() async throws {
        for asset in AssetRegistry.realAssets {
            let graph = try await graph(for: asset)
            let video = try #require(
                graph.primaryVideoTrack,
                "\(asset.id) has no video track"
            )
            let audio = try #require(
                graph.defaultAudioTrack,
                "\(asset.id) has no audio track"
            )

            #expect(video.codec == asset.videoCodec, "\(asset.id) video codec")
            #expect(
                (video.bitDepth ?? 8) == asset.bitDepth,
                "\(asset.id) bit depth"
            )
            #expect(
                video.hdrFormat == asset.probeHDRFormat,
                "\(asset.id) HDR format, got \(video.hdrFormat.rawValue)"
            )
            #expect(audio.codec == asset.audioCodec, "\(asset.id) audio codec")
            #expect(audio.channels >= 1, "\(asset.id) audio channels")
            #expect(graph.container == asset.container, "\(asset.id) container")
        }
    }

    @Test("Dolby Vision and Atmos recordings carry their signaling")
    func recordedAssetsProbeAsAuthored() throws {
        for asset in AssetRegistry.recordedAssets {
            let graph = try #require(AssetRegistry.graph(for: asset))
            let video = try #require(graph.primaryVideoTrack)
            let audio = try #require(graph.defaultAudioTrack)

            #expect(video.codec == asset.videoCodec)
            #expect((video.bitDepth ?? 8) == asset.bitDepth)
            #expect(video.hdrFormat == asset.hdrFormat)
            #expect(video.hasDolbyVisionRPU == asset.hdrFormat.isDolbyVision)
            #expect(audio.codec == asset.audioCodec)
            #expect(audio.isAtmos == asset.isAtmos)
        }
    }

    // MARK: - Planner and badge conformance

    @Test("The planner selects the expected rung for every asset")
    func plannerSelectsExpectedRungs() async throws {
        let planner = PipelinePlanner(capabilities: try registry())
        let sink = dolbyVisionSink()

        for asset in AssetRegistry.assets {
            let mediaGraph = try await graph(for: asset)
            let plan = planner.plan(graph: mediaGraph, sink: sink)

            #expect(plan.isPlayable, "\(asset.id) should be playable")
            #expect(
                plan.rung == asset.expectedRung,
                "\(asset.id): expected \(asset.expectedRung.displayName), got \(plan.rung.displayName)"
            )
            #expect(plan.badge == QualityBadge.forRung(plan.rung))
            #expect(
                plan.video.inputCodec.lowercased()
                    == asset.videoCodec.rawValue.lowercased(),
                "\(asset.id) input codec"
            )
        }
    }

    @Test("The quality badge always matches the plan")
    func qualityBadgeMatchesPlan() async throws {
        let planner = PipelinePlanner(capabilities: try registry())
        let sink = dolbyVisionSink()

        for asset in AssetRegistry.assets {
            let mediaGraph = try await graph(for: asset)
            let plan = planner.plan(graph: mediaGraph, sink: sink)
            let badge = QualityBadgeViewModel(plan: plan)

            #expect(badge.badge == plan.badge, "\(asset.id) badge")
            #expect(badge.label == plan.badge.label, "\(asset.id) label")
            #expect(badge.color == plan.badge.color, "\(asset.id) color")
            #expect(badge.rung == plan.rung, "\(asset.id) rung")
            #expect(
                !badge.summary.isEmpty,
                "\(asset.id) needs a plain-language summary"
            )
        }
    }

    @Test("Server transcode is only chosen when it is offered")
    func serverTranscodeRequiresServer() async throws {
        let planner = PipelinePlanner(capabilities: try registry())
        let sink = dolbyVisionSink()

        for asset in AssetRegistry.assets {
            let mediaGraph = try await graph(for: asset)
            let local = planner.plan(
                graph: mediaGraph,
                sink: sink,
                serverTranscodeAvailable: false
            )
            #expect(!local.isServerTranscode, "\(asset.id) must not claim R5")
            #expect(local.rung != .r5ServerTranscode)
        }
    }
}
