import Foundation
import Testing
import LibraryCore
@testable import PlaybackKit

private final class FixtureBundleToken {}

private struct MockFFmpegDemuxer: FFmpegDemuxing {
    var result: FFmpegProbeResult

    func probe(
        url: URL,
        container: ContainerFormat
    ) async throws -> FFmpegProbeResult {
        result
    }
}

private func fixtureURL(
    named name: String,
    extension fileExtension: String
) throws -> URL {
    let bundle = Bundle(for: FixtureBundleToken.self)
    if let url = bundle.url(
        forResource: name,
        withExtension: fileExtension,
        subdirectory: "Fixtures"
    ) {
        return url
    }
    if let url = bundle.url(
        forResource: name,
        withExtension: fileExtension
    ) {
        return url
    }
    throw StreamProbeError.readFailed(
        "missing test fixture \(name).\(fileExtension)"
    )
}

private func dolbyVisionMKVResult() -> FFmpegProbeResult {
    FFmpegProbeResult(
        container: .mkv,
        duration: 7_200,
        streams: [
            FFmpegStreamDescription(
                index: 0,
                kind: .video,
                codecID: "hevc",
                codecName: "HEVC",
                profile: "Main 10",
                level: "5.1",
                width: 3_840,
                height: 2_160,
                frameRate: FrameRate(fps: 23.976),
                bitDepth: 10,
                bitrate: 65_000_000,
                colorPrimaries: "bt2020",
                transferFunction: "smpte2084",
                colorMatrix: "bt2020nc",
                hdrFormat: .dolbyVision81,
                dolbyVisionProfile: 8,
                hasDolbyVisionRPU: true,
                isDefault: true
            ),
            FFmpegStreamDescription(
                index: 1,
                kind: .audio,
                codecID: "eac3",
                codecName: "E-AC-3",
                profile: "Dolby Digital Plus + Atmos",
                bitrate: 768_000,
                channels: 8,
                channelLayout: "7.1 Atmos",
                sampleRate: 48_000,
                isAtmos: true,
                isDefault: true,
                language: "eng",
                title: "English Atmos"
            ),
            FFmpegStreamDescription(
                index: 2,
                kind: .subtitle,
                codecID: "hdmv_pgs_subtitle",
                codecName: "PGS",
                isDefault: false,
                isForced: false,
                language: "eng",
                title: "English (SDH)"
            )
        ],
        chapters: [
            FFmpegChapterDescription(
                index: 0,
                startTime: 0,
                endTime: 120,
                title: "Intro"
            )
        ]
    )
}

@Suite("MediaGraph Tests")
struct MediaGraphTests {
    @Test("Probing an MP4 asset uses AVFoundation and exposes video and audio")
    func probeNativeMP4() async throws {
        let url = try fixtureURL(
            named: "sample-h264-aac",
            extension: "mp4"
        )
        let graph = try await MediaGraph.probe(url: url)

        #expect(graph.container == .mp4)
        #expect(graph.demuxer == .avFoundation)
        #expect(graph.isDirectPlayContainer)
        #expect((graph.duration ?? 0) > 0.5)

        let video = try #require(graph.primaryVideoTrack)
        #expect(video.codec == .h264)
        #expect(video.width == 320)
        #expect(video.height == 240)
        #expect(video.frameRate.value > 23.5)
        #expect(video.frameRate.value < 24.5)

        let audio = try #require(graph.defaultAudioTrack)
        #expect(audio.codec == .aac)
        #expect(audio.sampleRate == 48_000)
        #expect(audio.channels >= 1)
    }

    @Test("Probing an MKV with DoVi 8.1 and Atmos uses the FFmpeg bridge")
    func probeMKVDolbyVisionAtmos() async throws {
        let url = URL(fileURLWithPath: "/tmp/movie.mkv")
        let demuxer = MockFFmpegDemuxer(result: dolbyVisionMKVResult())
        let graph = try await MediaGraph.probe(
            url: url,
            ffmpeg: demuxer
        )

        #expect(graph.container == .mkv)
        #expect(graph.demuxer == .ffmpeg)
        #expect(graph.isDirectPlayContainer == false)

        let video = try #require(graph.primaryVideoTrack)
        #expect(video.codec == .hevc)
        #expect(video.width == 3_840)
        #expect(video.height == 2_160)
        #expect(video.bitDepth == 10)
        #expect(video.hdrFormat == .dolbyVision81)
        #expect(video.hdrFormat.isDolbyVision)
        #expect(video.hasDolbyVisionRPU)
        #expect(video.colorPrimaries == .bt2020)
        #expect(video.transferFunction == .pq)
        #expect(video.frameRate.numerator == 24_000)
        #expect(video.frameRate.denominator == 1_001)

        let audio = try #require(graph.defaultAudioTrack)
        #expect(audio.codec == .eac3)
        #expect(audio.channels == 8)
        #expect(audio.channelLayout == "7.1 Atmos")
        #expect(audio.isAtmos)
        #expect(audio.sampleRate == 48_000)

        let subtitle = try #require(graph.subtitleTracks.first)
        #expect(subtitle.format == .pgs)
        #expect(subtitle.isImageBased)
        #expect(subtitle.language == "eng")

        #expect(graph.chapters.count == 1)
        #expect(graph.chapters.first?.title == "Intro")
    }

    @Test("A probe result populates TrackRecord rows for LibraryCore")
    func trackRecordsForLibraryCore() async throws {
        let url = URL(fileURLWithPath: "/tmp/movie.mkv")
        let demuxer = MockFFmpegDemuxer(result: dolbyVisionMKVResult())
        let graph = try await MediaGraph.probe(
            url: url,
            ffmpeg: demuxer
        )

        let records = graph.trackRecords(fileID: "file-42")
        #expect(records.count == 4)
        #expect(records.allSatisfy { $0.fileId == "file-42" })

        let video = try #require(
            records.first { $0.kind == .video }
        )
        #expect(video.codec == "hevc")
        #expect(video.profile == "Main 10")
        #expect(video.level == "5.1")
        #expect(video.width == 3_840)
        #expect(video.height == 2_160)
        #expect(video.fpsNum == 24_000)
        #expect(video.fpsDen == 1_001)
        #expect(video.bitDepth == 10)
        #expect(video.colorPrimaries == "bt2020")
        #expect(video.colorTrc == "pq")
        #expect(video.colorSpace == "bt2020nc")
        #expect(video.hdrFormat == "dovi:8.1")
        #expect(video.sdciPresent == true)

        let audio = try #require(
            records.first { $0.kind == .audio }
        )
        #expect(audio.codec == "eac3")
        #expect(audio.channels == 8)
        #expect(audio.channelLayout == "7.1 Atmos")
        #expect(audio.sampleRate == 48_000)
        #expect(audio.lang == "eng")
        #expect(audio.isDefault)

        let subtitle = try #require(
            records.first { $0.kind == .subtitle }
        )
        #expect(subtitle.subtitleFormat == "pgs")
        #expect(subtitle.isForced == false)

        let chapter = try #require(
            records.first { $0.kind == .chapter }
        )
        #expect(chapter.title == "Intro")
        #expect(chapter.sampled == false)
    }

    @Test("MKV probing fails clearly when the FFmpeg demuxer is unavailable")
    func missingFFmpegDemuxerFails() async throws {
        let url = URL(fileURLWithPath: "/tmp/movie.mkv")
        await #expect(throws: StreamProbeError.ffmpegUnavailable) {
            try await MediaGraph.probe(url: url)
        }
    }

    @Test("Container detection separates native and FFmpeg containers")
    func containerDetection() {
        #expect(ContainerFormat(pathExtension: "MKV") == .mkv)
        #expect(ContainerFormat(pathExtension: "m2ts") == .m2ts)
        #expect(ContainerFormat(pathExtension: "mp4").isAVFoundationNative)
        #expect(ContainerFormat(pathExtension: "mov").isAVFoundationNative)
        #expect(ContainerFormat(pathExtension: "mkv").isAVFoundationNative == false)
        #expect(ContainerFormat(pathExtension: "weird") == .other)
        #expect(HDRFormat.dolbyVision81.rawValue == "dovi:8.1")
        #expect(HDRFormat.hdr10Plus.rawValue == "hdr10plus")
    }
}
