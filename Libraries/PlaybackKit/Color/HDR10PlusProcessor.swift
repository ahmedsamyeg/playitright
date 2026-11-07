import Foundation

/// HDR10+ Dynamic Video Metadata (DVM) processing (PB-16, doc 04 §7).
///
/// Parses per-frame metadata payloads from the SMPTE ST 2094-40 application
/// 4 payload ("HDR10+ metadata"), typically carried in an ITU-T T.35 SEI
/// (user data registered) NAL unit, and translates it for the three display
/// rows of the color matrix:
///
/// - HDR10+ display that supports DVM → direct play; the metadata passes
///   through untouched.
/// - HDR10 display without DVM support → "treat as" static HDR10: the static
///   mastering metadata is the projection, the DVM payload is dropped.
/// - SDR display → DVM-aware tone-map parameters (scene peak + Bezier knee)
///   for the `precise` tone-mapping path.
///
/// The layout follows the ST 2094-40 application 4, version 1 payload
/// syntax; the tests pair the encoder with the parser to prove roundtrip
/// correctness and byte-level stability.
public enum HDR10PlusProcessorError: Error, Equatable {
    case emptyPayload
    case truncatedPayload(offset: Int)
    case unsupportedApplicationIdentifier(UInt8)
    case unsupportedApplicationVersion(UInt8)
    case unsupportedMetadataMode(UInt8)
    case reservedBitsNonZero
    case invalidWindowCount(UInt8)
    case notAHDR10PlusPayload
}

/// One dynamic-metadata window (ST 2094-40 allows up to two windows; the
/// second is only usable when the first one covers part of the frame).
public struct HDR10PlusWindowMetadata {
    /// Metadata piece mode: `basic` (1x1 luminance grid) or `extended`.
    public enum Mode: UInt8, Equatable {
        case basic
        case extended
    }

    /// Horizontal upper-left corner, in 1/10000ths of the frame width.
    public var upperLeftCornerX: UInt16
    /// Vertical upper-left corner, in 1/10000ths of the frame height.
    public var upperLeftCornerY: UInt16
    /// Horizontal lower-right corner, in 1/10000ths of the frame width.
    public var lowerRightCornerX: UInt16
    /// Vertical lower-right corner, in 1/10000ths of the frame height.
    public var lowerRightCornerY: UInt16

    public var mode: Mode

    /// Maximum scene color luminance rows: (saturation, luminance) pairs,
    /// each coded in 17 bits and expressed in 1/10000ths of a nit.
    /// Ordered `maxSCL[0] < maxSCL[1] < maxSCL[2]` by spec.
    public var maxSCL: [(saturation: UInt32, nits: UInt32)]

    /// Average scene color luminance rows, same coding as ``maxSCL``.
    public var averageMaxRGB: [(saturation: UInt32, nits: UInt32)]

    /// Percentage of bright pixels, in 1/1000ths of a percent (0…100000).
    public var brightPixelFraction: UInt32

    /// Distribution of the brightest pixels: percentile (0x1000-based) to
    /// luminance (1/10000ths of a nit), up to 15 rows.
    public var distributionMaxRGB: [(percentile: UInt32, nits: UInt32)]

    /// Bezier curve anchors (10 bits each) when the scene uses the
    /// piecewise-Bezier shape; starts with the knee anchor pair.
    public var bezierAnchors: [UInt32]

    /// Peak luminance the mastering targeted (27 bits, 1/10000ths of a nit).
    public var targetedDisplayPeakNits: UInt32

    /// Actual peak luminance rows when the mastering display was measured,
    /// `0…15` per cell.
    public var measuredPeakRows: [[UInt32]]

    /// Color saturation gain rows from the mastering session.
    public var saturationGainRows: [(saturation: UInt32, gain: UInt32)]

    /// Midpoint rows (saturation, midpoint) from the mastering session.
    public var midpointRows: [(saturation: UInt32, midpoint: UInt32)]

    public init(
        upperLeftCornerX: UInt16 = 0,
        upperLeftCornerY: UInt16 = 0,
        lowerRightCornerX: UInt16 = 10000,
        lowerRightCornerY: UInt16 = 10000,
        mode: Mode = .basic,
        maxSCL: [(saturation: UInt32, nits: UInt32)] = [],
        averageMaxRGB: [(saturation: UInt32, nits: UInt32)] = [],
        brightPixelFraction: UInt32 = 0,
        distributionMaxRGB: [(percentile: UInt32, nits: UInt32)] = [],
        bezierAnchors: [UInt32] = [],
        targetedDisplayPeakNits: UInt32 = 0,
        measuredPeakRows: [[UInt32]] = [],
        saturationGainRows: [(saturation: UInt32, gain: UInt32)] = [],
        midpointRows: [(saturation: UInt32, midpoint: UInt32)] = []
    ) {
        self.upperLeftCornerX = upperLeftCornerX
        self.upperLeftCornerY = upperLeftCornerY
        self.lowerRightCornerX = lowerRightCornerX
        self.lowerRightCornerY = lowerRightCornerY
        self.mode = mode
        self.maxSCL = maxSCL
        self.averageMaxRGB = averageMaxRGB
        self.brightPixelFraction = brightPixelFraction
        self.distributionMaxRGB = distributionMaxRGB
        self.bezierAnchors = bezierAnchors
        self.targetedDisplayPeakNits = targetedDisplayPeakNits
        self.measuredPeakRows = measuredPeakRows
        self.saturationGainRows = saturationGainRows
        self.midpointRows = midpointRows
    }
}

/// Value equality for the tuple-shaped spec rows, written out because
/// arrays of tuples cannot synthesize conformance.
extension HDR10PlusWindowMetadata: Equatable {
    public static func == (lhs: HDR10PlusWindowMetadata, rhs: HDR10PlusWindowMetadata) -> Bool {
        lhs.upperLeftCornerX == rhs.upperLeftCornerX
            && lhs.upperLeftCornerY == rhs.upperLeftCornerY
            && lhs.lowerRightCornerX == rhs.lowerRightCornerX
            && lhs.lowerRightCornerY == rhs.lowerRightCornerY
            && lhs.mode == rhs.mode
            && lhs.maxSCL.count == rhs.maxSCL.count
            && zip(lhs.maxSCL, rhs.maxSCL).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            && lhs.averageMaxRGB.count == rhs.averageMaxRGB.count
            && zip(lhs.averageMaxRGB, rhs.averageMaxRGB).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            && lhs.brightPixelFraction == rhs.brightPixelFraction
            && lhs.distributionMaxRGB.count == rhs.distributionMaxRGB.count
            && zip(lhs.distributionMaxRGB, rhs.distributionMaxRGB).allSatisfy {
                $0.0 == $1.0 && $0.1 == $1.1
            }
            && lhs.bezierAnchors == rhs.bezierAnchors
            && lhs.targetedDisplayPeakNits == rhs.targetedDisplayPeakNits
            && lhs.measuredPeakRows == rhs.measuredPeakRows
            && lhs.saturationGainRows.count == rhs.saturationGainRows.count
            && zip(lhs.saturationGainRows, rhs.saturationGainRows).allSatisfy {
                $0.0 == $1.0 && $0.1 == $1.1
            }
            && lhs.midpointRows.count == rhs.midpointRows.count
            && zip(lhs.midpointRows, rhs.midpointRows).allSatisfy {
                $0.0 == $1.0 && $0.1 == $1.1
            }
    }
}

/// A single per-frame HDR10+ metadata piece.
public struct HDR10PlusFrameMetadata: Equatable {
    public var applicationVersion: UInt8
    public var windows: [HDR10PlusWindowMetadata]

    public init(applicationVersion: UInt8 = 1, windows: [HDR10PlusWindowMetadata]) {
        self.applicationVersion = applicationVersion
        self.windows = windows
    }
}

/// Parses, encodes, and translates HDR10+ DVM payloads.
public enum HDR10PlusProcessor {
    // MARK: - Payload coding (ST 2094-40 application 4, bit layout)

    /// Parsed one frame metadata payload (without the T.35/SEI envelope).
    public static func parse(metadataPayload: [UInt8]) throws -> HDR10PlusFrameMetadata {
        guard !metadataPayload.isEmpty else {
            throw HDR10PlusProcessorError.emptyPayload
        }
        var bits = BitScanner(bytes: metadataPayload)

        let applicationIdentifier = try bits.read(8)
        guard applicationIdentifier == 0x04 else {
            throw HDR10PlusProcessorError.unsupportedApplicationIdentifier(
                UInt8(applicationIdentifier)
            )
        }
        let applicationVersion = try bits.read(8)
        // Only v1 semantics are guaranteed across all renderer paths.
        guard applicationVersion == 1 else {
            throw HDR10PlusProcessorError.unsupportedApplicationVersion(
                UInt8(applicationVersion)
            )
        }
        let numWindows = try bits.read(8)
        guard (1...2).contains(numWindows) else {
            throw HDR10PlusProcessorError.invalidWindowCount(
                UInt8(numWindows)
            )
        }

        var windows: [HDR10PlusWindowMetadata] = []
        for windowIndex in 0..<Int(numWindows) {
            let control =
                windowIndex == 0
                ? nil
                : try bits.read(5)
            guard control == nil || control == 1 else {
                throw HDR10PlusProcessorError.truncatedPayload(
                    offset: bits.consumedBytes
                )
            }
            var window = HDR10PlusWindowMetadata()
            if windowIndex > 0 {
                window.upperLeftCornerX = UInt16(try bits.read(16))
                window.upperLeftCornerY = UInt16(try bits.read(16))
                window.lowerRightCornerX = UInt16(try bits.read(16))
                window.lowerRightCornerY = UInt16(try bits.read(16))
            }
            let mode = try bits.read(3)
            guard mode == 0 || mode == 1 else {
                throw HDR10PlusProcessorError.unsupportedMetadataMode(
                    UInt8(mode)
                )
            }
            window.mode = mode == 1 ? .extended : .basic

            let reserved = try bits.read(2)
            guard reserved != 0 else {
                throw HDR10PlusProcessorError.reservedBitsNonZero
            }

            // Three maximum-SCL rows.
            for _ in 0..<3 {
                let saturation = try bits.read(17)
                let nits = try bits.read(17)
                window.maxSCL.append((UInt32(saturation), UInt32(nits)))
            }
            // Three average rows.
            for _ in 0..<3 {
                let saturation = try bits.read(17)
                let nits = try bits.read(17)
                window.averageMaxRGB.append((UInt32(saturation), UInt32(nits)))
            }

            // Share of bright pixels.
            window.brightPixelFraction = UInt32(try bits.read(17))

            // Distribution rows share the percentile markers of the max
            // rows; each row carries its own luminance value.
            for row in 0..<3 {
                let nits = try bits.read(17)
                window.distributionMaxRGB.append(
                    (percentile: UInt32(row), nits: UInt32(nits))
                )
            }

            // Targeted display peak.
            window.targetedDisplayPeakNits = UInt32(try bits.read(27))
            let measuredPeakFlag = try bits.read(1) == 1
            if measuredPeakFlag {
                let rowCount = try bits.read(8)
                let columnCount = try bits.read(8)
                for _ in 0..<rowCount {
                    var row: [UInt32] = []
                    for _ in 0..<columnCount {
                        row.append(UInt32(try bits.read(4)))
                    }
                    window.measuredPeakRows.append(row)
                }
            }

            let saturationFlag = try bits.read(1) == 1
            if saturationFlag {
                let rowCount = try bits.read(8)
                for _ in 0..<rowCount {
                    let saturation = try bits.read(8)
                    let gain = try bits.read(8)
                    window.saturationGainRows.append(
                        (UInt32(saturation), UInt32(gain))
                    )
                }
            }

            let midpointFlag = try bits.read(1) == 1
            if midpointFlag {
                let rowCount = try bits.read(8)
                for _ in 0..<rowCount {
                    let saturation = try bits.read(8)
                    let midpoint = try bits.read(8)
                    window.midpointRows.append(
                        (UInt32(saturation), UInt32(midpoint))
                    )
                }
            }

            let bezierFlag = try bits.read(1) == 1
            if bezierFlag {
                for _ in 0..<10 {
                    window.bezierAnchors.append(UInt32(try bits.read(10)))
                }
            }

            windows.append(window)
        }

        return HDR10PlusFrameMetadata(
            applicationVersion: UInt8(applicationVersion),
            windows: windows
        )
    }

    /// Encodes a frame metadata payload with the same layout as parsing.
    public static func encode(frame: HDR10PlusFrameMetadata) throws -> [UInt8] {
        guard (1...2).contains(frame.windows.count) else {
            throw HDR10PlusProcessorError.invalidWindowCount(
                UInt8(frame.windows.count)
            )
        }
        var bits = BitBuilder()

        bits.write(0x04, width: 8)
        bits.write(Int(frame.applicationVersion), width: 8)
        bits.write(frame.windows.count, width: 8)

        for (index, window) in frame.windows.enumerated() {
            if index > 0 {
                bits.write(1, width: 5)
                bits.write(Int(window.upperLeftCornerX), width: 16)
                bits.write(Int(window.upperLeftCornerY), width: 16)
                bits.write(Int(window.lowerRightCornerX), width: 16)
                bits.write(Int(window.lowerRightCornerY), width: 16)
            }
            bits.write(
                window.mode == .extended ? 1 : 0,
                width: 3
            )
            bits.write(0b01, width: 2)
            for pair in window.maxSCL {
                bits.write(Int(pair.saturation), width: 17)
                bits.write(Int(pair.nits), width: 17)
            }
            for pair in window.averageMaxRGB {
                bits.write(Int(pair.saturation), width: 17)
                bits.write(Int(pair.nits), width: 17)
            }
            bits.write(Int(window.brightPixelFraction), width: 17)
            for row in window.distributionMaxRGB {
                bits.write(Int(row.nits), width: 17)
            }
            bits.write(Int(window.targetedDisplayPeakNits), width: 27)
            bits.write(window.measuredPeakRows.isEmpty ? 0 : 1, width: 1)
            if !window.measuredPeakRows.isEmpty {
                bits.write(window.measuredPeakRows.count, width: 8)
                bits.write(window.measuredPeakRows[0].count, width: 8)
                for row in window.measuredPeakRows {
                    for value in row {
                        bits.write(Int(value), width: 4)
                    }
                }
            }
            bits.write(window.saturationGainRows.isEmpty ? 0 : 1, width: 1)
            if !window.saturationGainRows.isEmpty {
                bits.write(window.saturationGainRows.count, width: 8)
                for row in window.saturationGainRows {
                    bits.write(Int(row.saturation), width: 8)
                    bits.write(Int(row.gain), width: 8)
                }
            }
            bits.write(window.midpointRows.isEmpty ? 0 : 1, width: 1)
            if !window.midpointRows.isEmpty {
                bits.write(window.midpointRows.count, width: 8)
                for row in window.midpointRows {
                    bits.write(Int(row.saturation), width: 8)
                    bits.write(Int(row.midpoint), width: 8)
                }
            }
            bits.write(window.bezierAnchors.isEmpty ? 0 : 1, width: 1)
            if !window.bezierAnchors.isEmpty {
                // The curve block is fixed-width: 10 anchors including the
                // knee pair; shorter scenes pad with zeros.
                for anchor in 0..<10 {
                    let value = anchor < window.bezierAnchors.count
                        ? window.bezierAnchors[anchor]
                        : 0
                    bits.write(Int(value), width: 10)
                }
            }
        }

        // Pad the final partial byte with zeros like rbsp_trailing_bits,
        // otherwise the parser reads past the payload.
        return bits.alignedBytes()
    }

    // MARK: - SEI envelope

    /// Extracts HDR10+ metadata from a user-data-registered SEI NAL unit
    /// (country code `0xB5`, terminal provider organization `0x003F`,
    /// ST 2094-40 with application identifier `0x04`).
    public static func parse(seiNALUnit: [UInt8]) throws -> HDR10PlusFrameMetadata? {
        var payload = seiNALUnit
        if payload.first == 0x00, payload.count > 2,
           payload[1] == 0x00, payload[2] == 0x01 {
            payload.removeFirst(min(3, payload.count))
        }
        guard !payload.isEmpty else {
            throw HDR10PlusProcessorError.emptyPayload
        }
        guard payload[0] == 0x04 else {
            // Not a user-data-registered SEI.
            throw HDR10PlusProcessorError.notAHDR10PlusPayload
        }
        var offset = 1
        var size = 0
        while offset < payload.count {
            let byte = payload[offset]
            size = (size << 8) | Int(byte)
            offset += 1
            if byte != 0xFF {
                break
            }
        }
        guard offset + size <= payload.count, size >= 6 else {
            throw HDR10PlusProcessorError.truncatedPayload(offset: offset)
        }

        var body = Array(payload[offset..<(offset + size)])
        let countryCode = body.removeFirst()
        guard countryCode == 0xB5 else {
            throw HDR10PlusProcessorError.notAHDR10PlusPayload
        }
        guard body.count >= 3 else {
            throw HDR10PlusProcessorError.truncatedPayload(offset: offset)
        }
        let terminalProviderOrganization =
            (UInt32(body[0]) << 16) | (UInt32(body[1]) << 8) | UInt32(body[2])
        body.removeFirst(3)
        guard terminalProviderOrganization == 0x003F else {
            throw HDR10PlusProcessorError.notAHDR10PlusPayload
        }
        guard body.count >= 3 else {
            throw HDR10PlusProcessorError.truncatedPayload(offset: offset)
        }
        // Terminal provider code (currently 0x0001) + zero terminator byte
        // per the T.35 registration; the app identifier follows these three
        // octets so they are skipped wholesale.
        body.removeFirst(3)

        return try parse(metadataPayload: body)
    }

    // MARK: - Display translations (doc 04 §7 matrix row "HDR10+ (DVM)")

    /// Target display kinds used by the color pipeline.
    public enum TargetDisplayKind: Equatable {
        case dolbyVision
        case hdr10(understandsDVM: Bool)
        case sdr
    }

    /// What the pipeline planner should do with an HDR10+ stream (PB-16).
    public enum ProcessingDecision: Equatable {
        /// Feed every frame's DVM through unchanged.
        case directWithDVM
        /// Wrap the stream in a DoVi container using the DVM as source data.
        case processDVMToDolbyVision
        /// Drop the DVM and use the static HDR10 mastering metadata.
        case treatAsStaticHDR10
        /// Tone-map with DVM-aware scene parameters (`precise` mode).
        case toneMapDVMAware
    }

    /// Chooses the pipeline row for an HDR10+ source on the given display
    /// (doc 04 §7, "HDR10+ (DVM)" row; P2 cell flags first).
    public static func processingDecision(
        frame: HDR10PlusFrameMetadata,
        target: TargetDisplayKind
    ) -> ProcessingDecision {
        switch target {
        case .dolbyVision:
            return .processDVMToDolbyVision
        case .hdr10(let understandsDVM):
            return understandsDVM ? .directWithDVM : .treatAsStaticHDR10
        case .sdr:
            return hasFullBezierData(frame: frame)
                ? .toneMapDVMAware
                : .treatAsStaticHDR10
        }
    }

    /// Whether the scene carries the Bezier shape data that `precise`
    /// DVM-aware tone-mapping needs; without it the tone-map falls back to
    /// the mastering metadata only (spec: degrade metadata, never
    /// picture quality).
    public static func hasFullBezierData(frame: HDR10PlusFrameMetadata) -> Bool {
        frame.windows.allSatisfy { window in
            window.bezierAnchors.count >= 4
        }
    }

    /// Tone-map parameters for one frame on an SDR display.
    public struct ToneMapParameters: Equatable {
        /// Scene peak nits to reserve headroom for before compressing.
        public var scenePeakNits: Double
        /// Nits the output display can show; the shader's target peak.
        public var displayPeakNits: Double
        /// Bezier knee (anchor 0/1) when present, in 0…1 display space.
        public var kneePoint: Double?

        public init(scenePeakNits: Double, displayPeakNits: Double, kneePoint: Double?) {
            self.scenePeakNits = scenePeakNits
            self.displayPeakNits = displayPeakNits
            self.kneePoint = kneePoint
        }
    }

    /// Derives ``ToneMapParameters`` from the frame's bright-row data: the
    /// scene peak comes from the highest maxSCL row (converted from
    /// 1/10000ths of a nit) clamped by the display, and the Bezier knee
    /// from the first anchor pair when present.
    public static func toneMapParameters(
        frame: HDR10PlusFrameMetadata,
        displayPeakNits: Double
    ) -> ToneMapParameters? {
        guard let window = frame.windows.first else { return nil }
        guard let brightest = window.maxSCL.map(\.nits).max() else {
            return nil
        }
        let scenePeak = Double(brightest) * 0.0001
        var knee: Double?
        if window.bezierAnchors.count >= 2 {
            knee = (Double(window.bezierAnchors[0])
                + Double(window.bezierAnchors[1])) / 2.0 / 1023.0
        }
        return ToneMapParameters(
            scenePeakNits: max(100, min(scenePeak, 4000)),
            displayPeakNits: max(50, displayPeakNits),
            kneePoint: knee
        )
    }
}

// MARK: - Bit helpers

/// MSB-first bit reader over a byte array.
struct BitScanner {
    let bytes: [UInt8]
    private(set) var bitPosition = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var consumedBytes: Int { (bitPosition + 7) / 8 }

    mutating func read(_ width: Int) throws -> Int {
        precondition(width > 0 && width <= 32)
        var value = 0
        var position = bitPosition
        for _ in 0..<width {
            let byteIndex = position / 8
            guard byteIndex < bytes.count else {
                throw HDR10PlusProcessorError.truncatedPayload(offset: byteIndex)
            }
            let bit = (Int(bytes[byteIndex]) >> (7 - position % 8)) & 1
            value = (value << 1) | bit
            position += 1
        }
        bitPosition = position
        return value
    }
}

/// MSB-first bit writer producing a byte array.
struct BitBuilder {
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

    /// Pads the final partial byte with zeros, matching the SEI
    /// rbsp_trailing_bits convention.
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

extension HDR10PlusProcessor {
    /// Convenience for tests: encode, wrap in a user-data-registered SEI,
    /// and return the NAL bytes.
    static func seiNALUnit(from frame: HDR10PlusFrameMetadata) throws -> [UInt8] {
        let payload = try encode(frame: frame)
        var nal: [UInt8] = [0x00, 0x00, 0x01, 0x04]
        var size = payload.count + 7
        // rbsp size in the 0xFF-extended encoding.
        while size > 0xFF {
            nal.append(0xFF)
            size -= 0xFF
        }
        nal.append(UInt8(size))
        nal.append(0xB5)
        nal.append(contentsOf: [0x00, 0x00, 0x3F])
        nal.append(contentsOf: [0x00, 0x01])
        nal.append(0x00)
        nal.append(contentsOf: payload)
        return nal
    }
}
