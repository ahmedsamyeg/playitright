import Foundation

/// A track to place in a fragmented MP4 initialization segment.
public struct FMP4Track: Codable, Sendable, Equatable {
    /// Codecs the packager can wrap without re-encoding.
    public enum Codec: String, Codable, Sendable, CaseIterable {
        case h264
        case hevc
        case aac
        case ac3
        case eac3
        case mp3
        case pcm
    }

    public var trackID: UInt32
    public var codec: Codec
    public var timescale: UInt32

    /// Codec configuration record: `avcC`, `hvcC`, or AudioSpecificConfig.
    /// The bytes are copied verbatim into the sample entry.
    public var codecConfig: Data?

    public var width: UInt16
    public var height: UInt16
    public var sampleRate: UInt32
    public var channelCount: UInt16

    /// ISO-639-2/T language code, for example `eng`.
    public var language: String?

    public init(
        trackID: UInt32,
        codec: Codec,
        timescale: UInt32,
        codecConfig: Data? = nil,
        width: UInt16 = 0,
        height: UInt16 = 0,
        sampleRate: UInt32 = 0,
        channelCount: UInt16 = 0,
        language: String? = nil
    ) {
        self.trackID = trackID
        self.codec = codec
        self.timescale = timescale
        self.codecConfig = codecConfig
        self.width = width
        self.height = height
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.language = language
    }

    public var isVideo: Bool {
        codec == .h264 || codec == .hevc
    }
}

/// One media sample in a track's timescale. Data is never re-encoded.
public struct FMP4Sample: Sendable, Equatable {
    public var dts: Int64
    public var pts: Int64
    public var duration: Int64
    public var isKeyframe: Bool
    public var data: Data

    public init(
        dts: Int64,
        pts: Int64,
        duration: Int64,
        isKeyframe: Bool,
        data: Data
    ) {
        self.dts = dts
        self.pts = pts
        self.duration = duration
        self.isKeyframe = isKeyframe
        self.data = data
    }
}

public enum FMP4PackagerError: Error, LocalizedError, Equatable {
    case unknownTrack(UInt32)
    case emptyFragment(UInt32)
    case invalidTimescale(UInt32)

    public var errorDescription: String? {
        switch self {
        case .unknownTrack(let trackID):
            return "No track with id \(trackID) is registered in the packager."
        case .emptyFragment(let trackID):
            return "Track \(trackID) has no samples to package."
        case .invalidTimescale(let timescale):
            return "Track timescale \(timescale) is invalid."
        }
    }
}

/// Packages demuxed packets into fragmented MP4 without touching the
/// elementary streams (PB-3, doc 04 §4.2).
///
/// The output is a standard `ftyp` + `moov` initialization segment followed by
/// `moof` + `mdat` fragments. Each fragment carries one track, uses
/// `default-base-is-moof`, and starts with an explicit `tfdt` so the timeline
/// stays continuous across seeks and source restarts.
public struct FMP4Packager: Sendable {
    public var tracks: [FMP4Track]
    public var movieTimescale: UInt32

    /// Removes HEVC Dolby Vision RPU NAL units (type 62) from each sample so
    /// Profile 8/8.1 base layers can be presented as HDR10.
    public var stripDolbyVisionRPU: Bool

    public init(
        tracks: [FMP4Track],
        movieTimescale: UInt32 = 1_000,
        stripDolbyVisionRPU: Bool = false
    ) {
        self.tracks = tracks
        self.movieTimescale = movieTimescale
        self.stripDolbyVisionRPU = stripDolbyVisionRPU
    }

    // MARK: - Initialization segment

    /// Builds the `ftyp` + `moov` boxes.
    public func initializationSegment() -> Data {
        var output = Data()
        output.append(box("ftyp", ftypPayload()))
        output.append(box("moov", moovPayload()))
        return output
    }

    private func ftypPayload() -> Data {
        var data = Data()
        data.appendFourCC("iso6")
        data.appendUInt32(0)
        for brand in ["iso6", "iso5", "mp41", "dash"] {
            data.appendFourCC(brand)
        }
        return data
    }

    private func moovPayload() -> Data {
        var payload = Data()
        payload.append(mvhd())
        for track in tracks {
            payload.append(trak(for: track))
        }
        payload.append(mvex())
        return payload
    }

    private func mvhd() -> Data {
        var payload = Data()
        payload.appendUInt32(0) // creation_time
        payload.appendUInt32(0) // modification_time
        payload.appendUInt32(movieTimescale)
        payload.appendUInt32(0) // duration (fragmented)
        payload.appendUInt32(0x0001_0000) // rate 1.0
        payload.appendUInt16(0x0100) // volume 1.0
        payload.appendUInt16(0)
        payload.append(Data(repeating: 0, count: 8))
        payload.append(identityMatrix())
        payload.append(Data(repeating: 0, count: 24))
        payload.appendUInt32(UInt32(tracks.count + 1))
        return fullBox("mvhd", version: 0, flags: 0, payload)
    }

    private func trak(for track: FMP4Track) -> Data {
        var payload = Data()
        payload.append(tkhd(for: track))
        payload.append(mdia(for: track))
        return box("trak", payload)
    }

    private func tkhd(for track: FMP4Track) -> Data {
        var payload = Data()
        payload.appendUInt32(0)
        payload.appendUInt32(0)
        payload.appendUInt32(track.trackID)
        payload.appendUInt32(0)
        payload.appendUInt32(0) // duration
        payload.append(Data(repeating: 0, count: 8))
        payload.appendUInt16(0) // layer
        payload.appendUInt16(0) // alternate_group
        payload.appendUInt16(track.isVideo ? 0 : 0x0100)
        payload.appendUInt16(0)
        payload.append(identityMatrix())
        let width = track.isVideo ? UInt32(track.width) << 16 : 0
        let height = track.isVideo ? UInt32(track.height) << 16 : 0
        payload.appendUInt32(width)
        payload.appendUInt32(height)
        return fullBox("tkhd", version: 0, flags: 0x7, payload)
    }

    private func mdia(for track: FMP4Track) -> Data {
        var payload = Data()
        payload.append(mdhd(for: track))
        payload.append(hdlr(for: track))
        payload.append(minf(for: track))
        return box("mdia", payload)
    }

    private func mdhd(for track: FMP4Track) -> Data {
        var payload = Data()
        payload.appendUInt32(0)
        payload.appendUInt32(0)
        payload.appendUInt32(max(1, track.timescale))
        payload.appendUInt32(0) // duration (fragmented)
        payload.appendUInt16(Self.packedLanguage(track.language))
        payload.appendUInt16(0)
        return fullBox("mdhd", version: 0, flags: 0, payload)
    }

    private func hdlr(for track: FMP4Track) -> Data {
        var payload = Data()
        payload.appendUInt32(0)
        payload.appendFourCC(track.isVideo ? "vide" : "soun")
        payload.append(Data(repeating: 0, count: 12))
        payload.append(contentsOf: Array((track.isVideo ? "VideoHandler" : "SoundHandler").utf8))
        payload.appendUInt8(0)
        return fullBox("hdlr", version: 0, flags: 0, payload)
    }

    private func minf(for track: FMP4Track) -> Data {
        var payload = Data()
        if track.isVideo {
            var vmhd = Data()
            vmhd.appendUInt16(0)
            vmhd.appendUInt16(0)
            vmhd.appendUInt16(0)
            vmhd.appendUInt16(0)
            payload.append(fullBox("vmhd", version: 0, flags: 1, vmhd))
        } else {
            var smhd = Data()
            smhd.appendUInt16(0)
            smhd.appendUInt16(0)
            payload.append(fullBox("smhd", version: 0, flags: 0, smhd))
        }
        payload.append(dinf())
        payload.append(stbl(for: track))
        return box("minf", payload)
    }

    private func dinf() -> Data {
        var url = Data()
        let selfContained = fullBox("url ", version: 0, flags: 1, Data())
        url.appendUInt32(1)
        url.append(selfContained)
        let dref = fullBox("dref", version: 0, flags: 0, url)
        return box("dinf", dref)
    }

    private func stbl(for track: FMP4Track) -> Data {
        var payload = Data()
        payload.append(stsd(for: track))
        for type in ["stts", "stsc", "stsz", "stco"] {
            var empty = Data()
            empty.appendUInt32(0)
            payload.append(fullBox(type, version: 0, flags: 0, empty))
        }
        return box("stbl", payload)
    }

    private func stsd(for track: FMP4Track) -> Data {
        var payload = Data()
        payload.appendUInt32(1)
        payload.append(sampleEntry(for: track))
        return fullBox("stsd", version: 0, flags: 0, payload)
    }

    private func sampleEntry(for track: FMP4Track) -> Data {
        switch track.codec {
        case .h264:
            return videoSampleEntry(
                type: "avc1",
                track: track,
                configBox: "avcC"
            )
        case .hevc:
            return videoSampleEntry(
                type: "hvc1",
                track: track,
                configBox: "hvcC"
            )
        case .aac, .mp3:
            return audioSampleEntry(
                type: track.codec == .aac ? "mp4a" : ".mp3",
                track: track,
                includeESDS: track.codec == .aac
            )
        case .ac3:
            return audioSampleEntry(
                type: "ac-3",
                track: track,
                includeESDS: false,
                extraBox: track.codecConfig.map {
                    box("dac3", $0)
                }
            )
        case .eac3:
            return audioSampleEntry(
                type: "ec-3",
                track: track,
                includeESDS: false,
                extraBox: track.codecConfig.map {
                    box("dec3", $0)
                }
            )
        case .pcm:
            return audioSampleEntry(
                type: "lpcm",
                track: track,
                includeESDS: false
            )
        }
    }

    private func videoSampleEntry(
        type: String,
        track: FMP4Track,
        configBox: String
    ) -> Data {
        var payload = Data()
        payload.append(Data(repeating: 0, count: 6))
        payload.appendUInt16(1) // data_reference_index
        payload.appendUInt16(0)
        payload.appendUInt16(0)
        payload.append(Data(repeating: 0, count: 12))
        payload.appendUInt16(track.width)
        payload.appendUInt16(track.height)
        payload.appendUInt32(0x0048_0000)
        payload.appendUInt32(0x0048_0000)
        payload.appendUInt32(0)
        payload.appendUInt16(1) // frame_count
        payload.append(Self.compressorName("PlayItRight"))
        payload.appendUInt16(0x0018)
        payload.appendUInt16(0xFFFF)
        payload.append(box(configBox, track.codecConfig ?? Data()))
        return box(type, payload)
    }

    private func audioSampleEntry(
        type: String,
        track: FMP4Track,
        includeESDS: Bool,
        extraBox: Data? = nil
    ) -> Data {
        var payload = Data()
        payload.append(Data(repeating: 0, count: 6))
        payload.appendUInt16(1)
        payload.append(Data(repeating: 0, count: 8))
        payload.appendUInt16(max(1, track.channelCount))
        payload.appendUInt16(16)
        payload.appendUInt16(0)
        payload.appendUInt16(0)
        payload.appendUInt32(max(1, track.sampleRate) << 16)
        if includeESDS {
            payload.append(esds(for: track))
        }
        if let extraBox {
            payload.append(extraBox)
        }
        return box(type, payload)
    }

    private func esds(for track: FMP4Track) -> Data {
        var decoderSpecific = Data()
        if let config = track.codecConfig {
            decoderSpecific = descriptor(tag: 0x05, payload: config)
        }

        var decoderConfig = Data()
        decoderConfig.appendUInt8(0x40) // AAC
        decoderConfig.appendUInt8(0x15) // audio stream
        decoderConfig.append(Data(repeating: 0, count: 3)) // bufferSizeDB
        decoderConfig.appendUInt32(0) // maxBitrate
        decoderConfig.appendUInt32(0) // avgBitrate
        decoderConfig.append(decoderSpecific)

        var es = Data()
        es.appendUInt16(0) // ES_ID
        es.appendUInt8(0) // flags
        es.append(descriptor(tag: 0x04, payload: decoderConfig))
        es.append(descriptor(tag: 0x06, payload: Data([0x02])))

        return fullBox(
            "esds",
            version: 0,
            flags: 0,
            descriptor(tag: 0x03, payload: es)
        )
    }

    private func mvex() -> Data {
        var payload = Data()
        payload.append(fullBox("mehd", version: 0, flags: 0, uint32Data(0)))
        for track in tracks {
            var trex = Data()
            trex.appendUInt32(track.trackID)
            trex.appendUInt32(1)
            trex.appendUInt32(0)
            trex.appendUInt32(0)
            trex.appendUInt32(0)
            payload.append(fullBox("trex", version: 0, flags: 0, trex))
        }
        return box("mvex", payload)
    }

    // MARK: - Fragments

    /// Packages samples for one track into a `moof` + `mdat` fragment.
    public func fragment(
        trackID: UInt32,
        samples: [FMP4Sample],
        sequenceNumber: UInt32
    ) throws -> Data {
        guard let track = tracks.first(where: { $0.trackID == trackID }) else {
            throw FMP4PackagerError.unknownTrack(trackID)
        }
        guard !samples.isEmpty else {
            throw FMP4PackagerError.emptyFragment(trackID)
        }

        var mediaData = Data()
        var sampleData: [Data] = []
        sampleData.reserveCapacity(samples.count)
        for sample in samples {
            let data = stripDolbyVisionRPU
                ? stripRPU(from: sample.data, track: track)
                : sample.data
            sampleData.append(data)
            mediaData.append(data)
        }

        var mfhdPayload = Data()
        mfhdPayload.appendUInt32(sequenceNumber)
        let mfhd = fullBox("mfhd", version: 0, flags: 0, mfhdPayload)

        var tfhdPayload = Data()
        tfhdPayload.appendUInt32(track.trackID)
        tfhdPayload.appendUInt32(1) // default_sample_description_index
        let tfhd = fullBox(
            "tfhd",
            version: 0,
            flags: 0x020002,
            tfhdPayload
        )

        var tfdtPayload = Data()
        tfdtPayload.appendUInt64(UInt64(bitPattern: samples[0].dts))
        let tfdt = fullBox("tfdt", version: 1, flags: 0, tfdtPayload)

        var trunPayload = Data()
        trunPayload.appendUInt32(UInt32(samples.count))
        trunPayload.appendUInt32(0) // patched after the moof size is known
        for (index, sample) in samples.enumerated() {
            let duration = sample.duration > 0
                ? UInt32(clamping: sample.duration)
                : 0
            trunPayload.appendUInt32(duration)
            trunPayload.appendUInt32(UInt32(clamping: sampleData[index].count))
            trunPayload.appendUInt32(
                sample.isKeyframe ? 0x0200_0000 : 0x0101_0000
            )
            let compositionOffset = Int32(
                clamping: sample.pts - sample.dts
            )
            trunPayload.appendUInt32(UInt32(bitPattern: compositionOffset))
        }
        let trun = fullBox(
            "trun",
            version: 1,
            flags: 0x000F01,
            trunPayload
        )

        let traf = box("traf", tfhd + tfdt + trun)
        var moof = box("moof", mfhd + traf)

        // data_offset is relative to the start of the moof and points at the
        // first byte of sample data inside mdat.
        let dataOffset = Int32(moof.count + 8)
        let offsetPosition = 8 // moof header
            + mfhd.count
            + 8 // traf header
            + tfhd.count
            + tfdt.count
            + 8 // trun box header
            + 4 // version and flags
            + 4 // sample_count
        moof.replaceSubrange(
            offsetPosition..<(offsetPosition + 4),
            with: uint32Data(UInt32(bitPattern: dataOffset))
        )

        var output = Data()
        output.append(moof)
        output.append(box("mdat", mediaData))
        return output
    }

    // MARK: - Dolby Vision RPU stripping

    /// Removes HEVC Dolby Vision RPU NAL units (type 62) from a
    /// length-prefixed sample. Non-HEVC tracks are returned unchanged.
    public func stripRPU(from data: Data, track: FMP4Track) -> Data {
        guard track.codec == .hevc else {
            return data
        }
        let lengthSize = Self.nalLengthSize(
            config: track.codecConfig,
            isHEVC: true
        )
        guard let stripped = Self.removeNALUnits(
            from: data,
            lengthSize: lengthSize,
            shouldDrop: { Self.hevcNALType($0) == 62 }
        ) else {
            return data
        }
        return stripped
    }

    static func nalLengthSize(config: Data?, isHEVC: Bool) -> Int {
        guard let config, config.count > (isHEVC ? 21 : 4) else {
            return 4
        }
        let byte = isHEVC ? config[21] : config[4]
        return Int(byte & 0x03) + 1
    }

    static func removeNALUnits(
        from data: Data,
        lengthSize: Int,
        shouldDrop: (Data) -> Bool
    ) -> Data? {
        guard lengthSize >= 1, lengthSize <= 4 else {
            return nil
        }
        var output = Data()
        var cursor = 0
        while cursor + lengthSize <= data.count {
            var length = 0
            for index in 0..<lengthSize {
                length = (length << 8) | Int(data[cursor + index])
            }
            let start = cursor + lengthSize
            guard length >= 0, start + length <= data.count else {
                return nil
            }
            let unit = data.subdata(in: start..<(start + length))
            if !shouldDrop(unit) {
                for shift in stride(
                    from: (lengthSize - 1) * 8,
                    through: 0,
                    by: -8
                ) {
                    output.appendUInt8(UInt8((length >> shift) & 0xFF))
                }
                output.append(unit)
            }
            cursor = start + length
        }
        guard cursor == data.count else {
            return nil
        }
        return output
    }

    static func hevcNALType(_ unit: Data) -> Int {
        guard let first = unit.first else {
            return -1
        }
        return Int((first >> 1) & 0x3F)
    }

    // MARK: - Box helpers

    private func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.appendUInt32(UInt32(8 + payload.count))
        data.appendFourCC(type)
        data.append(payload)
        return data
    }

    private func fullBox(
        _ type: String,
        version: UInt8,
        flags: UInt32,
        _ payload: Data
    ) -> Data {
        var data = Data()
        data.appendUInt8(version)
        data.appendUInt8(UInt8((flags >> 16) & 0xFF))
        data.appendUInt8(UInt8((flags >> 8) & 0xFF))
        data.appendUInt8(UInt8(flags & 0xFF))
        data.append(payload)
        return box(type, data)
    }

    private func uint32Data(_ value: UInt32) -> Data {
        var data = Data()
        data.appendUInt32(value)
        return data
    }

    private func identityMatrix() -> Data {
        var data = Data()
        for value: UInt32 in [
            0x0001_0000, 0, 0,
            0, 0x0001_0000, 0,
            0, 0, 0x4000_0000
        ] {
            data.appendUInt32(value)
        }
        return data
    }

    private func descriptor(tag: UInt8, payload: Data) -> Data {
        var data = Data()
        data.appendUInt8(tag)
        let length = payload.count
        if length < 0x80 {
            data.appendUInt8(UInt8(length))
        } else {
            data.appendUInt8(0x80 | UInt8((length >> 21) & 0x7F))
            data.appendUInt8(0x80 | UInt8((length >> 14) & 0x7F))
            data.appendUInt8(0x80 | UInt8((length >> 7) & 0x7F))
            data.appendUInt8(UInt8(length & 0x7F))
        }
        data.append(payload)
        return data
    }

    private static func compressorName(_ name: String) -> Data {
        let bytes = Array(name.utf8.prefix(31))
        var data = Data()
        data.appendUInt8(UInt8(bytes.count))
        data.append(contentsOf: bytes)
        data.append(Data(repeating: 0, count: 31 - bytes.count))
        return data
    }

    private static func packedLanguage(_ code: String?) -> UInt16 {
        guard let code, code.count == 3 else {
            return 0x55C4 // und
        }
        let scalars = Array(code.lowercased().utf8)
        guard scalars.count == 3 else {
            return 0x55C4
        }
        func value(_ byte: UInt8) -> UInt16 {
            UInt16(byte >= 0x61 ? byte - 0x61 + 1 : 0)
        }
        return (value(scalars[0]) << 10)
            | (value(scalars[1]) << 5)
            | value(scalars[2])
    }
}

// MARK: - Big-endian data helpers

extension Data {
    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt64(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xFF))
        append(UInt8((value >> 48) & 0xFF))
        append(UInt8((value >> 40) & 0xFF))
        append(UInt8((value >> 32) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendFourCC(_ code: String) {
        var written = 0
        for byte in code.utf8.prefix(4) {
            append(byte)
            written += 1
        }
        while written < 4 {
            append(0)
            written += 1
        }
    }
}
