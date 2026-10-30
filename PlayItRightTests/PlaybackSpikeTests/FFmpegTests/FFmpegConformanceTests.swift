import Testing
import CoreMedia

@Suite("FFmpegConformance Tests")
struct FFmpegConformanceTests {

    let demuxer = FFmpegDemuxerSim()
    let decoder = FFmpegSoftwareDecoderSim()

    @Test("Demuxer probes multiple container formats accurately")
    func testDemuxerProbing() {
        let mkvStreams = demuxer.probeContainer(format: "mkv")
        #expect(mkvStreams.count == 3)
        #expect(mkvStreams[0].kind == .video && mkvStreams[0].codecId == "av1")
        #expect(mkvStreams[1].kind == .audio && mkvStreams[1].codecId == "dca")
        #expect(mkvStreams[2].kind == .subtitle && mkvStreams[2].codecId == "pgs")

        let aviStreams = demuxer.probeContainer(format: "avi")
        #expect(aviStreams.count == 2)
        #expect(aviStreams[0].codecId == "mpeg2video")

        let webmStreams = demuxer.probeContainer(format: "webm")
        #expect(webmStreams.count == 2)
        #expect(webmStreams[0].codecId == "vp9")

        let tsStreams = demuxer.probeContainer(format: "ts")
        #expect(tsStreams.count == 2)
        #expect(tsStreams[0].codecId == "vc1")
    }

    @Test("Packet reading generates monotonic timestamps and keyframe flags")
    func testPacketReading() {
        let packets = demuxer.readPackets(streamIndex: 0, codecId: "av1", count: 60)
        #expect(packets.count == 60)
        #expect(packets[0].isKeyframe == true)
        #expect(packets[1].isKeyframe == false)
        #expect(packets[30].isKeyframe == true)
        #expect(CMTimeCompare(packets[1].pts, packets[0].pts) > 0)
    }

    @Test("Software decode of AV1 and VP9 produces valid uncompressed video frames")
    func testSoftwareVideoDecode() throws {
        let av1Packet = DemuxedPacket(
            streamIndex: 0,
            codecId: "av1",
            pts: CMTime(value: 0, timescale: 60000),
            dts: CMTime(value: 0, timescale: 60000),
            isKeyframe: true,
            payloadSize: 8192
        )

        let av1Frame = try decoder.decodeVideo(packet: av1Packet, width: 3840, height: 2160)
        #expect(av1Frame.width == 3840)
        #expect(av1Frame.height == 2160)
        #expect(av1Frame.bitDepth == 10)
        #expect(av1Frame.pixelFormat == "yuv420p10le")
        #expect(av1Frame.bufferByteCount == 3840 * 2160 * 3)

        let vp9Packet = DemuxedPacket(
            streamIndex: 0,
            codecId: "vp9",
            pts: CMTime(value: 0, timescale: 60000),
            dts: CMTime(value: 0, timescale: 60000),
            isKeyframe: true,
            payloadSize: 4096
        )

        let vp9Frame = try decoder.decodeVideo(packet: vp9Packet, width: 1920, height: 1080)
        #expect(vp9Frame.width == 1920)
        #expect(vp9Frame.height == 1080)
        #expect(vp9Frame.bitDepth == 8)
        #expect(vp9Frame.pixelFormat == "yuv420p")
    }

    @Test("Software decode of DTS-HD MA 7.1 and TrueHD and BS.775 downmix")
    func testSoftwareAudioDecodeAndDownmix() throws {
        let dtsPacket = DemuxedPacket(
            streamIndex: 1,
            codecId: "dca",
            pts: CMTime(value: 0, timescale: 48000),
            dts: CMTime(value: 0, timescale: 48000),
            isKeyframe: true,
            payloadSize: 2048
        )

        let dtsBuffer = try decoder.decodeAudio(packet: dtsPacket)
        #expect(dtsBuffer.channels == 8)
        #expect(dtsBuffer.channelLayout == "7.1")
        #expect(dtsBuffer.sampleRate == 48000)

        let stereoDownmix = decoder.downmixToStereo(input: dtsBuffer)
        #expect(stereoDownmix.channels == 2)
        #expect(stereoDownmix.channelLayout.contains("BS.775"))

        let truehdPacket = DemuxedPacket(
            streamIndex: 1,
            codecId: "truehd",
            pts: CMTime(value: 0, timescale: 48000),
            dts: CMTime(value: 0, timescale: 48000),
            isKeyframe: true,
            payloadSize: 2048
        )
        let truehdBuffer = try decoder.decodeAudio(packet: truehdPacket)
        #expect(truehdBuffer.channels == 8)
    }

    @Test("Unsupported codec throws descriptive error")
    func testUnsupportedCodec() {
        let badPacket = DemuxedPacket(
            streamIndex: 0,
            codecId: "unsupported_codec_xyz",
            pts: .zero,
            dts: .zero,
            isKeyframe: true,
            payloadSize: 100
        )

        #expect(throws: Error.self) {
            try decoder.decodeVideo(packet: badPacket)
        }
    }
}
