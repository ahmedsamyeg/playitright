import Foundation
import PlaybackKit

/// One row in the alpha playback conformance matrix (NFR-25, PB-G1/PB-G2).
///
/// Most rows point at a real, tiny MP4 fixture bundled with the test target.
/// Dolby Vision and Atmos cannot be authored by stock FFmpeg, so those rows
/// carry a recorded probe graph that exercises the same planner and badge
/// code paths.
struct ConformanceAsset: Sendable, Identifiable {
    enum Delivery: Sendable, Equatable {
        /// A real fixture in `PlayItRightTests/Fixtures`.
        case bundled(resource: String, fileExtension: String)

        /// A recorded probe result for formats that require licensed encoders.
        case recorded
    }

    let id: String
    let title: String
    let delivery: Delivery
    let container: ContainerFormat
    let videoCodec: VideoCodec
    let bitDepth: Int
    let hdrFormat: HDRFormat
    let audioCodec: AudioCodec
    let isAtmos: Bool

    /// The rung the planner must choose on a Dolby Vision-capable 4K display
    /// with an Atmos receiver, on an Apple TV 4K (gen 4) capability profile.
    let expectedRung: PipelineRung

    /// Populated for `.recorded` rows only.
    let recordedGraph: MediaGraph?

    var isBundled: Bool {
        if case .bundled = delivery {
            return true
        }
        return false
    }

    var resourceName: String? {
        if case .bundled(let resource, _) = delivery {
            return resource
        }
        return nil
    }

    var fileExtension: String? {
        if case .bundled(_, let fileExtension) = delivery {
            return fileExtension
        }
        return nil
    }

    /// What AVFoundation reports for a real fixture. The tvOS simulator drops
    /// static HDR10/HLG metadata from MP4 format descriptions, so those rows
    /// probe as SDR even though the file is authored as HDR. The recorded
    /// Dolby Vision rows still exercise the HDR planner paths.
    var probeHDRFormat: HDRFormat {
        if isBundled, hdrFormat == .hdr10 || hdrFormat == .hlg {
            return .sdr
        }
        return hdrFormat
    }
}

/// Locates bundled media fixtures from the test bundle.
private final class ConformanceBundleToken {}

enum AssetRegistry {
    /// The complete Phase 1 conformance matrix.
    static let assets: [ConformanceAsset] = realAssets + recordedAssets

    static var realAssets: [ConformanceAsset] {
        [
            ConformanceAsset(
                id: "h264-8bit-aac",
                title: "H.264 8-bit SDR + AAC",
                delivery: .bundled(
                    resource: "sample-h264-aac",
                    fileExtension: "mp4"
                ),
                container: .mp4,
                videoCodec: .h264,
                bitDepth: 8,
                hdrFormat: .sdr,
                audioCodec: .aac,
                isAtmos: false,
                expectedRung: .r1Direct,
                recordedGraph: nil
            ),
            ConformanceAsset(
                id: "hevc-8bit-sdr-aac",
                title: "HEVC 8-bit SDR + AAC",
                delivery: .bundled(
                    resource: "hevc8-sdr-aac",
                    fileExtension: "mp4"
                ),
                container: .mp4,
                videoCodec: .hevc,
                bitDepth: 8,
                hdrFormat: .sdr,
                audioCodec: .aac,
                isAtmos: false,
                expectedRung: .r1Direct,
                recordedGraph: nil
            ),
            ConformanceAsset(
                id: "hevc-10bit-sdr-ac3",
                title: "HEVC 10-bit SDR + AC-3",
                delivery: .bundled(
                    resource: "hevc10-sdr-ac3",
                    fileExtension: "mp4"
                ),
                container: .mp4,
                videoCodec: .hevc,
                bitDepth: 10,
                hdrFormat: .sdr,
                audioCodec: .ac3,
                isAtmos: false,
                expectedRung: .r1Direct,
                recordedGraph: nil
            ),
            ConformanceAsset(
                id: "hevc-10bit-hdr10-eac3",
                title: "HEVC 10-bit HDR10 + E-AC-3",
                delivery: .bundled(
                    resource: "hevc10-hdr10-eac3",
                    fileExtension: "mp4"
                ),
                container: .mp4,
                videoCodec: .hevc,
                bitDepth: 10,
                hdrFormat: .hdr10,
                audioCodec: .eac3,
                isAtmos: false,
                expectedRung: .r1Direct,
                recordedGraph: nil
            ),
            ConformanceAsset(
                id: "hevc-10bit-hlg-eac3",
                title: "HEVC 10-bit HLG + E-AC-3",
                delivery: .bundled(
                    resource: "hevc10-hlg-eac3",
                    fileExtension: "mp4"
                ),
                container: .mp4,
                videoCodec: .hevc,
                bitDepth: 10,
                hdrFormat: .hlg,
                audioCodec: .eac3,
                isAtmos: false,
                expectedRung: .r1Direct,
                recordedGraph: nil
            )
        ]
    }

    static var recordedAssets: [ConformanceAsset] {
        [
            dolbyVisionAsset(
                id: "dovi-profile-5",
                title: "Dolby Vision Profile 5",
                hdrFormat: .dolbyVision5,
                expectedRung: .r1Direct
            ),
            dolbyVisionAsset(
                id: "dovi-profile-8",
                title: "Dolby Vision Profile 8",
                hdrFormat: .dolbyVision8,
                // Gen 4 hardware lists profiles 5 and 8.1, so profile 8 falls
                // back to the local software decoder.
                expectedRung: .r4SoftwareTranscode
            ),
            dolbyVisionAsset(
                id: "dovi-profile-8-1",
                title: "Dolby Vision Profile 8.1",
                hdrFormat: .dolbyVision81,
                expectedRung: .r1Direct
            ),
            ConformanceAsset(
                id: "eac3-atmos",
                title: "E-AC-3 with Atmos",
                delivery: .recorded,
                container: .mp4,
                videoCodec: .hevc,
                bitDepth: 10,
                hdrFormat: .sdr,
                audioCodec: .eac3,
                isAtmos: true,
                expectedRung: .r1Direct,
                recordedGraph: makeRecordedGraph(
                    container: .mp4,
                    hdrFormat: .sdr,
                    bitDepth: 10,
                    audioCodec: .eac3,
                    channels: 8,
                    channelLayout: "7.1 Atmos",
                    isAtmos: true
                )
            )
        ]
    }

    /// Resolves a real fixture from the test bundle, preferring the
    /// `Fixtures` subdirectory and falling back to the flattened bundle root.
    static func fixtureURL(for asset: ConformanceAsset) -> URL? {
        guard let resource = asset.resourceName,
              let fileExtension = asset.fileExtension else {
            return nil
        }
        let bundle = Bundle(for: ConformanceBundleToken.self)
        return bundle.url(
            forResource: resource,
            withExtension: fileExtension,
            subdirectory: "Fixtures"
        ) ?? bundle.url(
            forResource: resource,
            withExtension: fileExtension
        )
    }

    /// Builds a deterministic probe result for rows without a real fixture.
    static func graph(for asset: ConformanceAsset) -> MediaGraph? {
        if let recordedGraph = asset.recordedGraph {
            return recordedGraph
        }
        return nil
    }

    // MARK: - Recorded graphs

    private static func dolbyVisionAsset(
        id: String,
        title: String,
        hdrFormat: HDRFormat,
        expectedRung: PipelineRung
    ) -> ConformanceAsset {
        ConformanceAsset(
            id: id,
            title: title,
            delivery: .recorded,
            container: .mp4,
            videoCodec: .hevc,
            bitDepth: 10,
            hdrFormat: hdrFormat,
            audioCodec: .eac3,
            isAtmos: true,
            expectedRung: expectedRung,
            recordedGraph: makeRecordedGraph(
                container: .mp4,
                hdrFormat: hdrFormat,
                bitDepth: 10,
                audioCodec: .eac3,
                channels: 8,
                channelLayout: "7.1 Atmos",
                isAtmos: true
            )
        )
    }

    private static func makeRecordedGraph(
        container: ContainerFormat,
        hdrFormat: HDRFormat,
        bitDepth: Int,
        audioCodec: AudioCodec,
        channels: Int,
        channelLayout: String?,
        isAtmos: Bool
    ) -> MediaGraph {
        MediaGraph(
            container: container,
            demuxer: .ffmpeg,
            duration: 1,
            videoTracks: [
                VideoTrackInfo(
                    index: 0,
                    codec: .hevc,
                    codecID: "hevc",
                    width: 3_840,
                    height: 2_160,
                    frameRate: FrameRate(fps: 24),
                    bitDepth: bitDepth,
                    colorPrimaries: hdrFormat == .sdr ? .bt709 : .bt2020,
                    transferFunction: hdrFormat.transferFunction,
                    colorMatrix: hdrFormat == .sdr
                        ? .bt709
                        : .bt2020NonConstant,
                    hdrFormat: hdrFormat,
                    hasDolbyVisionRPU: hdrFormat.isDolbyVision,
                    isDefault: true
                )
            ],
            audioTracks: [
                AudioTrackInfo(
                    index: 1,
                    codec: audioCodec,
                    codecID: audioCodec.rawValue,
                    channels: channels,
                    channelLayout: channelLayout,
                    sampleRate: 48_000,
                    isAtmos: isAtmos,
                    isDefault: true
                )
            ]
        )
    }
}

private extension HDRFormat {
    var transferFunction: TransferFunction {
        switch self {
        case .hdr10, .hdr10Plus, .dolbyVision5, .dolbyVision8, .dolbyVision81:
            return .pq
        case .hlg:
            return .hlg
        case .sdr:
            return .sdr
        }
    }
}
