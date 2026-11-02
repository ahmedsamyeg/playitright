import Foundation
import Testing
@testable import PlaybackKit

// MARK: - Box parser

private struct Box {
    let type: String
    let range: Range<Int>
    let payload: Range<Int>
}

private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    (UInt32(data[offset]) << 24)
        | (UInt32(data[offset + 1]) << 16)
        | (UInt32(data[offset + 2]) << 8)
        | UInt32(data[offset + 3])
}

private func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<8 {
        value = (value << 8) | UInt64(data[offset + index])
    }
    return value
}

private func parseBoxes(
    _ data: Data,
    in range: Range<Int>? = nil
) -> [Box] {
    let range = range ?? 0..<data.count
    var boxes: [Box] = []
    var cursor = range.lowerBound
    while cursor + 8 <= range.upperBound {
        let size = Int(readUInt32(data, cursor))
        guard size >= 8, cursor + size <= range.upperBound else {
            break
        }
        let type = String(
            decoding: data[(cursor + 4)..<(cursor + 8)],
            as: UTF8.self
        )
        boxes.append(
            Box(
                type: type,
                range: cursor..<(cursor + size),
                payload: (cursor + 8)..<(cursor + size)
            )
        )
        cursor += size
    }
    return boxes
}

private func children(_ data: Data, of box: Box) -> [Box] {
    parseBoxes(data, in: box.payload)
}

private func find(_ type: String, in boxes: [Box]) -> Box? {
    boxes.first { $0.type == type }
}

private func firstSampleEntry(
    _ data: Data,
    stsd: Box,
    video: Bool
) -> Box? {
    let entryStart = stsd.payload.lowerBound + 8
    let boxes = parseBoxes(data, in: entryStart..<stsd.payload.upperBound)
    guard let entry = boxes.first else {
        return nil
    }
    let configStart = entry.payload.lowerBound + (video ? 78 : 28)
    let configs = parseBoxes(
        data,
        in: configStart..<entry.payload.upperBound
    )
    guard let config = configs.first else {
        return nil
    }
    return Box(
        type: entry.type,
        range: entry.range,
        payload: config.payload
    )
}

// MARK: - Helpers

private func avcConfig() -> Data {
    Data([0x01, 0x64, 0x00, 0x28, 0xFF, 0xE1, 0x00, 0x04, 0x67, 0x64])
}

private func hevcConfig(lengthSize: Int = 4) -> Data {
    var config = Data(repeating: 0, count: 23)
    config[0] = 0x01
    config[21] = UInt8(lengthSize - 1)
    return config
}

private func lengthPrefixed(_ units: [Data], lengthSize: Int = 4) -> Data {
    var data = Data()
    for unit in units {
        var length = unit.count
        for shift in stride(
            from: (lengthSize - 1) * 8,
            through: 0,
            by: -8
        ) {
            data.append(UInt8((length >> shift) & 0xFF))
        }
        data.append(unit)
    }
    return data
}

private func hevcNAL(type: Int, payload: [UInt8] = [0x01]) -> Data {
    Data([UInt8(type << 1)] + payload)
}

private func h264Track() -> FMP4Track {
    FMP4Track(
        trackID: 1,
        codec: .h264,
        timescale: 90_000,
        codecConfig: avcConfig(),
        width: 1_920,
        height: 1_080
    )
}

private func hevcTrack() -> FMP4Track {
    FMP4Track(
        trackID: 2,
        codec: .hevc,
        timescale: 90_000,
        codecConfig: hevcConfig(),
        width: 3_840,
        height: 2_160
    )
}

private func aacTrack() -> FMP4Track {
    FMP4Track(
        trackID: 3,
        codec: .aac,
        timescale: 48_000,
        codecConfig: Data([0x11, 0x90]),
        sampleRate: 48_000,
        channelCount: 2,
        language: "eng"
    )
}

private struct MockRemuxDemuxer: RemuxDemuxing {
    var trackList: [FMP4Track]
    var packetList: [RemuxPacket]

    func tracks(
        url: URL,
        container: ContainerFormat
    ) async throws -> [FMP4Track] {
        trackList
    }

    func packets(
        url: URL,
        container: ContainerFormat
    ) -> AsyncThrowingStream<RemuxPacket, Error> {
        AsyncThrowingStream { continuation in
            for packet in packetList {
                continuation.yield(packet)
            }
            continuation.finish()
        }
    }
}

// MARK: - Tests

@Suite("RemuxPipeline Tests")
struct RemuxPipelineTests {
    @Test("The initialization segment wraps H.264 and AAC in valid atoms")
    func initializationSegment() throws {
        let packager = FMP4Packager(tracks: [h264Track(), aacTrack()])
        let data = packager.initializationSegment()
        let top = parseBoxes(data)

        #expect(top.map(\.type) == ["ftyp", "moov"])
        let moov = try #require(find("moov", in: top))
        let moovChildren = children(data, of: moov)
        #expect(find("mvhd", in: moovChildren) != nil)
        #expect(moovChildren.filter { $0.type == "trak" }.count == 2)
        #expect(find("mvex", in: moovChildren) != nil)

        let mvex = try #require(find("mvex", in: moovChildren))
        #expect(children(data, of: mvex).filter { $0.type == "trex" }.count == 2)

        let videoTrak = try #require(
            moovChildren.first { $0.type == "trak" }
        )
        let videoChildren = children(data, of: videoTrak)
        let mdia = try #require(find("mdia", in: videoChildren))
        let minf = try #require(
            find("minf", in: children(data, of: mdia))
        )
        let stbl = try #require(
            find("stbl", in: children(data, of: minf))
        )
        let stsd = try #require(
            find("stsd", in: children(data, of: stbl))
        )
        let entry = try #require(
            firstSampleEntry(data, stsd: stsd, video: true)
        )
        #expect(entry.type == "avc1")
        #expect(entry.payload.count == avcConfig().count)
    }

    @Test("HEVC is packaged as hvc1 with the hvcC configuration")
    func hevcSampleEntry() throws {
        let packager = FMP4Packager(tracks: [hevcTrack()])
        let data = packager.initializationSegment()
        let moov = try #require(find("moov", in: parseBoxes(data)))
        let trak = try #require(
            children(data, of: moov).first { $0.type == "trak" }
        )
        let mdia = try #require(
            find("mdia", in: children(data, of: trak))
        )
        let minf = try #require(
            find("minf", in: children(data, of: mdia))
        )
        let stbl = try #require(
            find("stbl", in: children(data, of: minf))
        )
        let stsd = try #require(
            find("stsd", in: children(data, of: stbl))
        )
        let entry = try #require(
            firstSampleEntry(data, stsd: stsd, video: true)
        )
        #expect(entry.type == "hvc1")
    }

    @Test("A fragment writes moof/mdat with a valid data offset")
    func fragmentLayout() throws {
        let packager = FMP4Packager(tracks: [h264Track()])
        let samples = [
            FMP4Sample(
                dts: 0,
                pts: 0,
                duration: 3_000,
                isKeyframe: true,
                data: Data([0xAA, 0xBB])
            ),
            FMP4Sample(
                dts: 3_000,
                pts: 6_000,
                duration: 3_000,
                isKeyframe: false,
                data: Data([0xCC])
            )
        ]
        let fragment = try packager.fragment(
            trackID: 1,
            samples: samples,
            sequenceNumber: 1
        )
        let top = parseBoxes(fragment)
        #expect(top.map(\.type) == ["moof", "mdat"])
        let moof = try #require(find("moof", in: top))
        let mdat = try #require(find("mdat", in: top))

        let traf = try #require(
            find("traf", in: children(fragment, of: moof))
        )
        let trun = try #require(
            find("trun", in: children(fragment, of: traf))
        )

        let sampleCount = readUInt32(fragment, trun.payload.lowerBound + 4)
        let dataOffset = Int(
            Int32(bitPattern: readUInt32(
                fragment,
                trun.payload.lowerBound + 8
            ))
        )
        #expect(sampleCount == 2)
        #expect(dataOffset == moof.range.count + 8)
        #expect(mdat.range.lowerBound == moof.range.upperBound)
        #expect(
            fragment.subdata(in: mdat.payload)
                == Data([0xAA, 0xBB, 0xCC])
        )

        // Sample durations, sizes, and composition offsets.
        var cursor = trun.payload.lowerBound + 12
        #expect(readUInt32(fragment, cursor) == 3_000) // duration
        cursor += 4
        #expect(readUInt32(fragment, cursor) == 2) // size
        cursor += 4 + 4 // size + flags
        #expect(readUInt32(fragment, cursor) == 0) // cto
        cursor += 4
        #expect(readUInt32(fragment, cursor) == 3_000)
        cursor += 4
        #expect(readUInt32(fragment, cursor) == 1)
        cursor += 4 + 4
        #expect(readUInt32(fragment, cursor) == 3_000) // pts - dts
    }

    @Test("Fragment timeline is continuous across sequence numbers")
    func timelineContinuity() throws {
        let packager = FMP4Packager(tracks: [h264Track()])
        let first = try packager.fragment(
            trackID: 1,
            samples: [
                FMP4Sample(
                    dts: 0,
                    pts: 0,
                    duration: 3_000,
                    isKeyframe: true,
                    data: Data([0x01])
                )
            ],
            sequenceNumber: 1
        )
        let second = try packager.fragment(
            trackID: 1,
            samples: [
                FMP4Sample(
                    dts: 3_000,
                    pts: 3_000,
                    duration: 3_000,
                    isKeyframe: false,
                    data: Data([0x02])
                )
            ],
            sequenceNumber: 2
        )

        func decodeTime(_ fragment: Data) throws -> (UInt64, UInt32) {
            let moof = try #require(find("moof", in: parseBoxes(fragment)))
            let mfhd = try #require(
                find("mfhd", in: children(fragment, of: moof))
            )
            let sequence = readUInt32(
                fragment,
                mfhd.payload.lowerBound + 4
            )
            let traf = try #require(
                find("traf", in: children(fragment, of: moof))
            )
            let tfdt = try #require(
                find("tfdt", in: children(fragment, of: traf))
            )
            return (readUInt64(fragment, tfdt.payload.lowerBound + 4), sequence)
        }

        let (firstTime, firstSequence) = try decodeTime(first)
        let (secondTime, secondSequence) = try decodeTime(second)
        #expect(firstSequence == 1)
        #expect(secondSequence == 2)
        #expect(firstTime == 0)
        #expect(secondTime == 3_000)
    }

    @Test("Dolby Vision RPU NAL units are stripped for HDR10 output")
    func stripDolbyVisionRPU() throws {
        let base = hevcNAL(type: 32, payload: [0x0A])
        let rpu = hevcNAL(type: 62, payload: [0x0B, 0x0C])
        let sample = lengthPrefixed([base, rpu])
        let packager = FMP4Packager(
            tracks: [hevcTrack()],
            stripDolbyVisionRPU: true
        )
        let stripped = packager.stripRPU(from: sample, track: hevcTrack())
        #expect(stripped == lengthPrefixed([base]))
        #expect(stripped.count < sample.count)

        let untouched = FMP4Packager(
            tracks: [hevcTrack()],
            stripDolbyVisionRPU: false
        )
        let fragment = try untouched.fragment(
            trackID: 2,
            samples: [
                FMP4Sample(
                    dts: 0,
                    pts: 0,
                    duration: 1,
                    isKeyframe: true,
                    data: sample
                )
            ],
            sequenceNumber: 1
        )
        let mdat = try #require(find("mdat", in: parseBoxes(fragment)))
        #expect(fragment.subdata(in: mdat.payload) == sample)
    }

    @Test("The pipeline emits initialization then fragments without re-encoding")
    func pipelineStreamsFragments() async throws {
        var packets: [RemuxPacket] = []
        for index in 0..<4 {
            let timestamp = Int64(index) * 3_000
            let sample = FMP4Sample(
                dts: timestamp,
                pts: timestamp,
                duration: 3_000,
                isKeyframe: index == 0,
                data: Data([UInt8(index), UInt8(index + 1)])
            )
            packets.append(RemuxPacket(trackID: 1, sample: sample))
        }
        let demuxer = MockRemuxDemuxer(
            trackList: [h264Track()],
            packetList: packets
        )
        let pipeline = RemuxPipeline(
            demuxer: demuxer,
            maxSamplesPerFragment: 2
        )
        var outputs: [RemuxOutput] = []
        for try await output in pipeline.remux(
            url: URL(fileURLWithPath: "/tmp/movie.mkv"),
            container: .mkv
        ) {
            outputs.append(output)
        }

        #expect(outputs.count == 3)
        #expect(outputs[0].kind == .initialization)
        #expect(outputs[1].kind == .fragment)
        #expect(outputs[1].trackID == 1)
        #expect(outputs[1].sequenceNumber == 1)
        #expect(outputs[2].sequenceNumber == 2)

        var media = Data()
        for output in outputs where output.kind == .fragment {
            let moof = try #require(find("moof", in: parseBoxes(output.data)))
            let mdat = try #require(find("mdat", in: parseBoxes(output.data)))
            #expect(mdat.range.lowerBound == moof.range.upperBound)
            media.append(output.data.subdata(in: mdat.payload))
        }
        let original = packets.reduce(into: Data()) { result, packet in
            result.append(packet.sample.data)
        }
        #expect(media == original)
    }

    @Test("An unavailable FFmpeg demuxer fails with a clear error")
    func unavailableDemuxer() async {
        let pipeline = RemuxPipeline()
        var failure: Error?
        do {
            for try await _ in pipeline.remux(
                url: URL(fileURLWithPath: "/tmp/movie.mkv"),
                container: .mkv
            ) {}
        } catch {
            failure = error
        }
        #expect(failure as? StreamProbeError == .ffmpegUnavailable)
    }
}
