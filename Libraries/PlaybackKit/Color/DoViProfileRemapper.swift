import Foundation

/// Dolby Vision profile remapping (doc 04 §7, Phase 4).
///
/// The Apple TV 4K gen 4 decoder accepts Profile 5 and Profile 8.1 only.
/// Sources mastered as Profile 7 (dual-track UHD Blu-ray) or Profile 8
/// (single-layer Blu-ray with NLQ) therefore need their RPUs rewritten in
/// real time, the picture itself is untouched: an RPU edits metadata, the
/// HEVC base layer plays back the same (PB-16: "degrade metadata, never
/// picture quality").
///
/// The RPU layout implemented here follows the RP 2077 `dovi_rpu` header
/// fields the conversion cares about (profile, level, NLQ presence, target
/// transfer). The tests pair an encoder with the parser and assert the
/// conversion rules; byte-level conformance against the Dolby reference
/// parser remains an item for the device-lab phase of doc 04 §7.
public enum DoViProfileRemapperError: Error, Equatable {
    case tooShort
    case magicMismatch
    case unsupportedRPUType(Int)
    case fragmentedRPUUnsupported
    case profileNotRemappable(vdrProfile: Int)
    case truncated(BitwiseCounter)
}

/// Bitwise counter used in error contexts so tests can attribute truncation
/// precisely without leaking a raw bit position type.
public struct BitwiseCounter: Equatable {
    public var bytes: Int
    public var bits: Int

    init(bytes: Int, bits: Int) {
        self.bytes = bytes
        self.bits = bits
    }
}

/// One parsed Dolby Vision RPU.
///
/// Only the fields the profile conversion reads or rewrites are modeled;
/// anything else rides along as an opaque bit tail.
public struct DoViRPU: Equatable {
    /// `rpu_type` from the header; 2 is the only supported value.
    public var rpuType: Int = 2

    public var vuiParametersPresent: Bool
    public var elSpatialResamplingFilterPresent: Bool
    public var disableResidual: Bool

    /// `vdr_rpu_profile`: 0 = dual layer (Profile 7), 1 = single layer
    /// (Profile 8 family).
    public var vdrRPUProfile: Int

    /// `vdr_rpu_level`.
    public var vdrRPULevel: Int

    /// `vdr_rpu_id`.
    public var vdrRPUID: Int

    /// `color_transform_flag`: true when the RPU carries the conversion
    /// shape (Profile 8 family), false for Profile 5 style passthrough.
    public var colorTransform: Bool

    /// Target display index carried in the header.
    public var targetDisplayIndex: Int

    /// Target transfer characteristics (`2` = PQ for HDR targets, `4` = HLG).
    public var targetTransferCharacteristics: Int

    /// Non-linear quantization payload; Profile 7 and plain Profile 8.0
    /// carry one, conversion strips it.
    public var nlq: DoViNLQ?

    /// Opaque remainder of the unit, preserved bit-for-bit across the
    /// rewrite so master metadata survives untouched.
    public var trailerBits: [UInt8]

    public init(
        vuiParametersPresent: Bool = false,
        elSpatialResamplingFilterPresent: Bool = false,
        disableResidual: Bool = true,
        vdrRPUProfile: Int = 1,
        vdrRPULevel: Int = 1,
        vdrRPUID: Int = 0,
        colorTransform: Bool = true,
        targetDisplayIndex: Int = 0,
        targetTransferCharacteristics: Int = 2,
        nlq: DoViNLQ? = nil,
        trailerBits: [UInt8] = []
    ) {
        self.vuiParametersPresent = vuiParametersPresent
        self.elSpatialResamplingFilterPresent = elSpatialResamplingFilterPresent
        self.disableResidual = disableResidual
        self.vdrRPUProfile = vdrRPUProfile
        self.vdrRPULevel = vdrRPULevel
        self.vdrRPUID = vdrRPUID
        self.colorTransform = colorTransform
        self.targetDisplayIndex = targetDisplayIndex
        self.targetTransferCharacteristics = targetTransferCharacteristics
        self.nlq = nlq
        self.trailerBits = trailerBits
    }

    /// The effective profile label implied by the parsed fields.
    public var inferredProfile: InferredProfile {
        if vdrRPUProfile == 0 {
            return .profile7
        }
        if nlq == nil {
            return .profile81
        }
        return colorTransform ? .profile8 : .profile7
    }

    public enum InferredProfile: Equatable {
        case profile7
        case profile8
        case profile81
    }
}

/// Non-linear quantization parameters carried by Profile 7 / Profile 8.0
/// RPUs and removed by conversion to 8.1.
public struct DoViNLQ: Equatable {
    public var methodID: Int
    public var regressorID: Int

    public init(methodID: Int = 1, regressorID: Int = 0) {
        self.methodID = methodID
        self.regressorID = regressorID
    }
}

/// Rewrites Dolby Vision RPUs so every supported model can decode them.
public enum DoViProfileRemapper {
    /// Magic bit prefix that opens every RPU payload (`0x56 0x34 0x12 0x78`).
    public static let rpuMagic: [UInt8] = [0x56, 0x34, 0x12, 0x78]

    // MARK: - Scanning

    /// Finds RPU payload ranges inside an Annex B elementary stream by
    /// locating the RPU magic prefix; the range stops at the next start
    /// code (or end of stream).

    /// Finds RPU payload regions inside an Annex B elementary stream by
    /// scanning for the magic prefix (`<start code> NAL… 0x25 0x56 0x34 …`;
    /// see ``rpuMagic``): returns payload ranges without NAL header or
    /// emulation-prevention handling, which stays in the remux layer.
    public static func findRPUPayloads(in stream: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        guard stream.count >= rpuMagic.count else { return ranges }
        var index = 0
        while index + rpuMagic.count <= stream.count {
            var match = true
            for (offset, byte) in rpuMagic.enumerated() {
                if stream[index + offset] != byte {
                    match = false
                    break
                }
            }
            if match {
                // The range includes the magic prefix so the payload can be
                // parsed (and rewritten) as-is.
                var end = stream.count
                if let stop = nextStartCodePosition(stream, from: index + rpuMagic.count) {
                    end = stop
                }
                if end > index {
                    ranges.append(index..<end)
                }
                index += rpuMagic.count
            } else {
                index += 1
            }
        }
        return ranges
    }

    private static func nextStartCodePosition(
        _ stream: [UInt8],
        from index: Int
    ) -> Int? {
        var i = index
        while i + 2 < stream.count {
            if stream[i] == 0x00, stream[i + 1] == 0x00, stream[i + 2] == 0x01 {
                return i
            }
            i += 1
        }
        return nil
    }

    // MARK: - RPU bit coding

    /// Parses an RPU payload: the magic prefix, the header bits, and the
    /// opaque trailer.
    public static func parse(payload: [UInt8]) throws -> DoViRPU {
        guard payload.count >= 2 else {
            throw DoViProfileRemapperError.tooShort
        }
        guard Array(payload[0..<rpuMagic.count]) == rpuMagic else {
            throw DoViProfileRemapperError.magicMismatch
        }
        var reader = BitwiseReader(bytes: Array(payload[rpuMagic.count...]))
        let prefix = try reader.read(8)
        guard prefix == 0x25 else {
            throw DoViProfileRemapperError.magicMismatch
        }
        let rpuType = try reader.read(2)
        guard rpuType == 2 else {
            throw DoViProfileRemapperError.unsupportedRPUType(rpuType)
        }
        var rpu = DoViRPU()
        rpu.rpuType = rpuType
        rpu.vuiParametersPresent = try reader.bit() == 1
        rpu.elSpatialResamplingFilterPresent = try reader.bit() == 1
        rpu.disableResidual = try reader.bit() == 1
        rpu.vdrRPUProfile = try reader.read(4)
        rpu.vdrRPULevel = try reader.read(8)
        rpu.vdrRPUID = try reader.read(4)
        rpu.colorTransform = try reader.bit() == 1
        if !rpu.colorTransform {
            let fragmented = try reader.bit() == 1
            if fragmented {
                throw DoViProfileRemapperError.fragmentedRPUUnsupported
            }
        }
        rpu.targetDisplayIndex = try reader.read(4)
        rpu.targetTransferCharacteristics = try reader.read(4)

        if rpu.colorTransform {
            let nlqMethod = try reader.read(3)
            if nlqMethod != 0 {
                let regressor = try reader.read(2)
                rpu.nlq = DoViNLQ(
                    methodID: nlqMethod,
                    regressorID: regressor
                )
            }
        }

        let trailerBytes = reader.remaining()
        rpu.trailerBits = trailerBytes
        return rpu
    }

    /// Encodes an RPU payload with the layout ``parse`` accepts.
    public static func encode(rpu: DoViRPU) throws -> [UInt8] {
        var writer = BitwiseWriter()
        writer.writeBytes(rpuMagic)
        // rpu_nal_prefix marker.
        writer.write(0x25, width: 8)
        writer.write(rpu.rpuType, width: 2)
        writer.write(rpu.vuiParametersPresent ? 1 : 0, width: 1)
        writer.write(rpu.elSpatialResamplingFilterPresent ? 1 : 0, width: 1)
        writer.write(rpu.disableResidual ? 1 : 0, width: 1)
        writer.write(rpu.vdrRPUProfile, width: 4)
        writer.write(rpu.vdrRPULevel, width: 8)
        writer.write(rpu.vdrRPUID, width: 4)
        writer.write(rpu.colorTransform ? 1 : 0, width: 1)
        if !rpu.colorTransform {
            writer.write(0, width: 1)
        }
        writer.write(rpu.targetDisplayIndex, width: 4)
        writer.write(rpu.targetTransferCharacteristics, width: 4)

        if rpu.colorTransform {
            if let nlq = rpu.nlq {
                writer.write(nlq.methodID, width: 3)
                writer.write(nlq.regressorID, width: 2)
            } else {
                writer.write(0, width: 3)
                // No regressor bits follow a zero method id.
            }
        }

        writer.writeBytes(rpu.trailerBits)
        // Pad the last partial byte so the payload always ends on a byte
        // boundary, matching how the remux layer feeds VideoToolbox.
        return writer.alignedBytes()
    }

    // MARK: - Profile conversions

    /// Rewrites a single RPU to Profile 8.1: collapses dual-layer
    /// (`vdr_rpu_profile == 0`) sources to single layer, strips any NLQ
    /// block, and normalizes the target to PQ. The HEVC base layer byte
    /// stream is never modified.
    public static func remapToProfile81(rpu: DoViRPU) throws -> [UInt8] {
        var converted = rpu
        guard converted.vdrRPUProfile == 0 || converted.colorTransform else {
            throw DoViProfileRemapperError.profileNotRemappable(
                vdrProfile: converted.vdrRPUProfile
            )
        }
        // Profile 5 (non-8-family) passthrough is not a "conversion": the
        // header required before rewriting is that the base layer already
        // signals the 8.x path.
        if converted.vdrRPUProfile == 0 {
            converted.vdrRPUProfile = 1
        }
        converted.colorTransform = true
        converted.nlq = nil
        converted.vdrRPUID = 0
        converted.targetTransferCharacteristics = 2
        converted.disableResidual = true
        return try encode(rpu: converted)
    }

    /// Convenience: parse, rewrite, and encode in one step.
    public static func remapToProfile81(payload: [UInt8]) throws -> [UInt8] {
        try remapToProfile81(rpu: try parse(payload: payload))
    }

    /// Scans an elementary stream, rewrites every RPU to Profile 8.1, and
    /// returns the stream with the re-encoded payloads spliced back in.
    /// Byte counts may differ from the input; the picture data outside the
    /// RPU regions is copied verbatim.
    public static func remapStreamToProfile81(_ stream: [UInt8]) throws -> [UInt8] {
        let ranges = findRPUPayloads(in: stream)
        var rewrittenChunks: [[UInt8]] = []
        for range in ranges {
            let original = Array(stream[range])
            do {
                rewrittenChunks.append(try remapToProfile81(payload: original))
            } catch {
                // Unreadable RPUs (fragmented or exotic) pass through
                // untouched; the treat-as-HDR10 fallback is the planner's
                // decision, not the remapper's.
                rewrittenChunks.append(original)
            }
        }

        var output: [UInt8] = []
        var cursor = 0
        for (range, rewritten) in zip(ranges, rewrittenChunks) {
            output.append(contentsOf: stream[cursor..<range.lowerBound])
            output.append(contentsOf: rewritten)
            cursor = range.upperBound
        }
        output.append(contentsOf: stream[cursor...])
        return output
    }
}

// MARK: - Bit helpers

/// MSB-first reader over a byte slice that remembers how many bits remain.
struct BitwiseReader {
    let bytes: [UInt8]
    var bitPosition = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func bit() throws -> Int {
        try read(1)
    }

    mutating func read(_ width: Int) throws -> Int {
        precondition(width > 0 && width <= 32)
        var value = 0
        var position = bitPosition
        for _ in 0..<width {
            let byteIndex = position / 8
            guard byteIndex < bytes.count else {
                throw DoViProfileRemapperError.truncated(
                    BitwiseCounter(bytes: bytes.count, bits: bitPosition)
                )
            }
            let bit = (Int(bytes[byteIndex]) >> (7 - position % 8)) & 1
            value = (value << 1) | bit
            position += 1
        }
        bitPosition = position
        return value
    }

    /// Remaining trailer bytes, re-aligned to a byte boundary from the
    /// current bit position.
    func remaining() -> [UInt8] {
        guard bitPosition < bytes.count * 8 else { return [] }
        var writer = [UInt8]()
        var acc = 0
        var fill = 0
        var position = bitPosition
        while position < bytes.count * 8 {
            let bit = (Int(bytes[position / 8]) >> (7 - position % 8)) & 1
            acc = (acc << 1) | bit
            fill += 1
            if fill == 8 {
                writer.append(UInt8(acc))
                acc = 0
                fill = 0
            }
            position += 1
        }
        if fill > 0 {
            writer.append(UInt8(acc << (8 - fill)))
        }
        // Drop zero-only padding bytes so parse→encode round trips (and
        // repeated remaps) stay stable; real trailers are non-zero tails.
        while writer.last == 0 {
            writer.removeLast()
        }
        return writer
    }
}

/// MSB-first writer over an arbitrary byte array.
struct BitwiseWriter {
    private(set) var bytes: [UInt8] = []
    private var currentByte = 0
    private var fill = 0

    mutating func write(_ value: Int, width: Int) {
        precondition(width > 0 && width <= 32)
        for shift in stride(from: width - 1, through: 0, by: -1) {
            let bit = (value >> shift) & 1
            currentByte = (currentByte << 1) | bit
            fill += 1
            if fill == 8 {
                bytes.append(UInt8(currentByte))
                currentByte = 0
                fill = 0
            }
        }
    }

    mutating func writeBytes(_ values: [UInt8]) {
        for value in values {
            write(Int(value), width: 8)
        }
    }

    mutating func alignedBytes() -> [UInt8] {
        var copy = self
        if copy.fill > 0 {
            copy.currentByte <<= (8 - copy.fill)
            copy.bytes.append(UInt8(copy.currentByte))
            copy.currentByte = 0
            copy.fill = 0
        }
        return copy.bytes
    }
}
