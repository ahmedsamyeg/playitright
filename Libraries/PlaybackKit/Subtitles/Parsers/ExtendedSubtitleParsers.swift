import Foundation

// MARK: - Style presets

/// Built-in subtitle looks, including presets that mirror common ASS styles
/// (PB-2, doc 04 §2.3).
public enum SubtitleStylePreset: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Balanced default: white text with a thin black outline.
    case standard

    /// Warm, slightly smaller text intended for letterboxed films.
    case cinema

    /// Maximum legibility: large yellow text on a heavy outline.
    case highContrast

    /// Larger white text for viewers who prefer bigger subtitles.
    case largePrint

    /// Clean text without an outline, useful for bright scenes.
    case minimal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard:
            return "Standard"
        case .cinema:
            return "Cinema"
        case .highContrast:
            return "High Contrast"
        case .largePrint:
            return "Large Print"
        case .minimal:
            return "Minimal"
        }
    }

    /// The appearance applied when this preset is selected.
    public var appearance: SubtitleAppearance {
        switch self {
        case .standard:
            return SubtitleAppearance()
        case .cinema:
            return SubtitleAppearance(
                fontName: "Georgia",
                fontSize: 44,
                fontScale: 1,
                opacity: 0.96,
                color: SubtitleColor(red: 0.98, green: 0.95, blue: 0.88),
                outlineColor: .black,
                outlineWidth: 3,
                positionOffset: 0.02
            )
        case .highContrast:
            return SubtitleAppearance(
                fontName: "Helvetica",
                fontSize: 54,
                fontScale: 1.1,
                opacity: 1,
                color: SubtitleColor(red: 1, green: 0.92, blue: 0),
                outlineColor: .black,
                outlineWidth: 5,
                positionOffset: 0
            )
        case .largePrint:
            return SubtitleAppearance(
                fontName: "Helvetica",
                fontSize: 64,
                fontScale: 1.15,
                opacity: 1,
                color: .white,
                outlineColor: .black,
                outlineWidth: 4,
                positionOffset: 0.03
            )
        case .minimal:
            return SubtitleAppearance(
                fontName: "Helvetica",
                fontSize: 40,
                fontScale: 1,
                opacity: 0.9,
                color: .white,
                outlineColor: .black,
                outlineWidth: 0,
                positionOffset: -0.02
            )
        }
    }
}

extension SubtitleAppearance {
    /// Builds an appearance from a built-in preset.
    public init(preset: SubtitleStylePreset) {
        self = preset.appearance
    }
}

// MARK: - MicroDVD

/// Parses MicroDVD (`.sub`) text subtitles.
///
/// Cues are expressed in frames: `{start}{end}text`. The optional
/// `{1}{1}25.000` header declares the frame rate; otherwise the parser's
/// configured rate (23.976 by default) is used.
public struct MicroDVDParser: SubtitleParsing {
    public var framesPerSecond: Double

    public init(framesPerSecond: Double = 23.976) {
        self.framesPerSecond = framesPerSecond > 0 ? framesPerSecond : 23.976
    }

    public func parse(_ data: Data) throws -> SubtitleDocument {
        let lines = SubtitleText.lines(SubtitleText.decode(data))
        var fps = framesPerSecond
        var cues: [SubtitleCue] = []
        var nextID = 1

        for (lineIndex, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                continue
            }

            guard line.hasPrefix("{"),
                  let firstClose = line.firstIndex(of: "}") else {
                throw SubtitleParseError.malformedCue(line: lineIndex + 1)
            }
            let startText = line[
                line.index(after: line.startIndex)..<firstClose
            ]
            guard let startFrame = Int(startText) else {
                throw SubtitleParseError.malformedCue(line: lineIndex + 1)
            }

            let afterStart = line[line.index(after: firstClose)...]
            guard afterStart.hasPrefix("{"),
                  let secondClose = afterStart.firstIndex(of: "}") else {
                throw SubtitleParseError.malformedCue(line: lineIndex + 1)
            }
            let endText = afterStart[
                afterStart.index(after: afterStart.startIndex)..<secondClose
            ]
            guard let endFrame = Int(endText) else {
                throw SubtitleParseError.malformedCue(line: lineIndex + 1)
            }

            var text = String(
                afterStart[afterStart.index(after: secondClose)...]
            )

            // A frame-rate header uses equal frame numbers and a numeric body.
            if startFrame == endFrame,
               let declared = Double(
                   text.trimmingCharacters(in: .whitespaces)
               ),
               declared > 1 {
                fps = declared
                continue
            }

            let isItalic = text.contains("{y:i}") || text.contains("{Y:i}")
            let isBold = text.contains("{y:b}") || text.contains("{Y:b}")
            text = Self.cleanText(text)

            guard !text.isEmpty, endFrame > startFrame else {
                continue
            }

            cues.append(
                SubtitleCue(
                    id: nextID,
                    start: Double(startFrame) / fps,
                    end: Double(endFrame) / fps,
                    content: .text(text),
                    isBold: isBold,
                    isItalic: isItalic
                )
            )
            nextID += 1
        }

        return SubtitleDocument(format: .microDVD, cues: cues)
    }

    /// Removes `{...}` markup and expands the `|` line separator.
    private static func cleanText(_ text: String) -> String {
        var result = ""
        var insideTag = false
        for character in text {
            if character == "{" {
                insideTag = true
            } else if character == "}" {
                insideTag = false
            } else if !insideTag {
                result.append(character)
            }
        }
        return result
            .replacingOccurrences(of: "|", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - MPL2

/// Parses MPL2 text subtitles: `[start][end]text`, with times in tenths of a
/// second. `|` separates lines and a leading `/` marks a line italic.
public struct MPL2Parser: SubtitleParsing {
    public init() {}

    public func parse(_ data: Data) throws -> SubtitleDocument {
        let lines = SubtitleText.lines(SubtitleText.decode(data))
        var cues: [SubtitleCue] = []
        var nextID = 1

        for (lineIndex, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                continue
            }

            guard line.hasPrefix("["),
                  let firstClose = line.firstIndex(of: "]") else {
                throw SubtitleParseError.malformedCue(line: lineIndex + 1)
            }
            let startText = line[
                line.index(after: line.startIndex)..<firstClose
            ]
            guard let startTenths = Int(startText) else {
                throw SubtitleParseError.malformedCue(line: lineIndex + 1)
            }

            let afterStart = line[line.index(after: firstClose)...]
            guard afterStart.hasPrefix("["),
                  let secondClose = afterStart.firstIndex(of: "]") else {
                throw SubtitleParseError.malformedCue(line: lineIndex + 1)
            }
            let endText = afterStart[
                afterStart.index(after: afterStart.startIndex)..<secondClose
            ]
            guard let endTenths = Int(endText) else {
                throw SubtitleParseError.malformedCue(line: lineIndex + 1)
            }

            let rawText = String(
                afterStart[afterStart.index(after: secondClose)...]
            )
            let parsed = Self.parseText(rawText)

            guard !parsed.text.isEmpty, endTenths > startTenths else {
                continue
            }

            cues.append(
                SubtitleCue(
                    id: nextID,
                    start: Double(startTenths) / 10,
                    end: Double(endTenths) / 10,
                    content: .text(parsed.text),
                    isItalic: parsed.isItalic
                )
            )
            nextID += 1
        }

        return SubtitleDocument(format: .mpl2, cues: cues)
    }

    private static func parseText(
        _ raw: String
    ) -> (text: String, isItalic: Bool) {
        var italic = false
        let lines = raw.components(separatedBy: "|").map { line -> String in
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("/") {
                italic = true
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            return line
        }
        return (lines.joined(separator: "\n"), italic)
    }
}

// MARK: - TMP / TMPlayer / plain text

/// Parses TMP subtitles: `HH:MM:SS:text`. Each cue runs until the next cue
/// starts, and the final cue lasts three seconds.
public struct TMPParser: SubtitleParsing {
    public init() {}

    public func parse(_ data: Data) throws -> SubtitleDocument {
        try TimedLineParser.parse(data, format: .tmp)
    }
}

/// Parses TMPlayer/plain `.txt` subtitles such as `HH:MM:SS=text`.
public struct TMPlayerParser: SubtitleParsing {
    public init() {}

    public func parse(_ data: Data) throws -> SubtitleDocument {
        try TimedLineParser.parse(data, format: .txt)
    }
}

/// Shared `HH:MM:SS<separator>text` parser used by TMP and TXT.
enum TimedLineParser {
    static func parse(
        _ data: Data,
        format: SubtitleFormat,
        finalDuration: TimeInterval = 3
    ) throws -> SubtitleDocument {
        let lines = SubtitleText.lines(SubtitleText.decode(data))
        var starts: [(time: TimeInterval, text: String, line: Int)] = []

        for (lineIndex, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                continue
            }
            guard let entry = parseLine(line) else {
                // Plain text files may contain a title or blank preamble.
                continue
            }
            guard entry.time >= 0 else {
                throw SubtitleParseError.invalidTimestamp(
                    line,
                    line: lineIndex + 1
                )
            }
            starts.append((entry.time, entry.text, lineIndex + 1))
        }

        var cues: [SubtitleCue] = []
        for (index, entry) in starts.enumerated() {
            let end: TimeInterval
            if index + 1 < starts.count {
                end = starts[index + 1].time
            } else {
                end = entry.time + finalDuration
            }
            guard end > entry.time, !entry.text.isEmpty else {
                continue
            }
            cues.append(
                SubtitleCue(
                    id: index + 1,
                    start: entry.time,
                    end: end,
                    content: .text(entry.text)
                )
            )
        }

        return SubtitleDocument(format: format, cues: cues)
    }

    private static func parseLine(
        _ line: String
    ) -> (time: TimeInterval, text: String)? {
        guard line.count > 9 else {
            return nil
        }

        // Find the separator after the HH:MM:SS timestamp. It may be `:`, `=`,
        // or `,`; scanning also accepts millisecond timestamps.
        var separatorIndex: String.Index?
        var index = line.index(line.startIndex, offsetBy: 8)
        while index < line.endIndex {
            let character = line[index]
            if character == ":" || character == "=" || character == "," {
                separatorIndex = index
                break
            }
            // Stop if this is clearly not a timestamp line.
            if character.isLetter {
                return nil
            }
            index = line.index(after: index)
        }

        guard let separatorIndex else {
            return nil
        }
        let timestamp = String(line[..<separatorIndex])
        guard let time = SubtitleText.timestamp(timestamp) else {
            return nil
        }
        let text = String(line[line.index(after: separatorIndex)...])
            .replacingOccurrences(of: "|", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (time, text)
    }
}

// MARK: - Timed Text / TTML

/// Parses TTML / Timed Text (`<p begin="1.5s" end="3s">…</p>`).
public struct TimedTextParser: SubtitleParsing {
    public init() {}

    public func parse(_ data: Data) throws -> SubtitleDocument {
        let delegate = TTMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SubtitleParseError.malformedCue(
                line: Int(parser.lineNumber)
            )
        }

        var cues: [SubtitleCue] = []
        for (index, raw) in delegate.cues.enumerated() {
            guard let start = TTMLTime.parse(raw.begin) else {
                continue
            }
            let end: TimeInterval
            if let rawEnd = raw.end, let parsedEnd = TTMLTime.parse(rawEnd) {
                end = parsedEnd
            } else if let rawDuration = raw.duration,
                      let duration = TTMLTime.parse(rawDuration) {
                end = start + duration
            } else {
                end = start + 2
            }
            let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, end > start else {
                continue
            }
            cues.append(
                SubtitleCue(
                    id: index + 1,
                    start: start,
                    end: end,
                    content: .text(text),
                    isBold: raw.isBold,
                    isItalic: raw.isItalic
                )
            )
        }

        return SubtitleDocument(format: .ttml, cues: cues)
    }
}

private struct TTMLRawCue {
    var begin: String
    var end: String?
    var duration: String?
    var text: String
    var isItalic: Bool
    var isBold: Bool
}

private final class TTMLDelegate: NSObject, XMLParserDelegate {
    var cues: [TTMLRawCue] = []

    private var current: TTMLRawCue?
    private var text = ""
    private var italicDepth = 0
    private var boldDepth = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let name = Self.localName(elementName)
        if name == "p" {
            current = TTMLRawCue(
                begin: Self.attribute("begin", in: attributeDict) ?? "0s",
                end: Self.attribute("end", in: attributeDict),
                duration: Self.attribute("dur", in: attributeDict),
                text: "",
                isItalic: false,
                isBold: false
            )
            text = ""
            italicDepth = 0
            boldDepth = 0
            return
        }

        guard current != nil else {
            return
        }
        if name == "br" {
            text.append("\n")
        } else if name == "span" {
            let style = Self.attribute("style", in: attributeDict) ?? ""
            let classes = Self.attribute("class", in: attributeDict) ?? ""
            let descriptor = (style + " " + classes).lowercased()
            if descriptor.contains("italic") {
                italicDepth += 1
                current?.isItalic = true
            }
            if descriptor.contains("bold") || descriptor.contains("weight") {
                boldDepth += 1
                current?.isBold = true
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard current != nil else {
            return
        }
        text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = Self.localName(elementName)
        guard current != nil else {
            return
        }
        if name == "br" {
            return
        }
        if name == "span" {
            italicDepth = max(0, italicDepth - 1)
            boldDepth = max(0, boldDepth - 1)
            return
        }
        if name == "p" {
            current?.text = text
            if let current {
                cues.append(current)
            }
            current = nil
            text = ""
        }
    }

    private static func localName(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name))
    }

    private static func attribute(
        _ name: String,
        in attributes: [String: String]
    ) -> String? {
        attributes[name]
            ?? attributes.first {
                localName($0.key).caseInsensitiveCompare(name) == .orderedSame
            }?.value
    }
}

/// TTML clock and offset expressions.
private enum TTMLTime {
    static func parse(_ raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }

        let lower = value.lowercased()
        if lower.hasSuffix("ms") {
            return Double(lower.dropLast(2)).map { $0 / 1_000 }
        }
        if lower.hasSuffix("s") {
            return Double(lower.dropLast())
        }
        if lower.hasSuffix("f") || lower.hasSuffix("t") {
            return Double(lower.dropLast()).map { $0 / 30 }
        }

        let parts = lower.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        if parts.count == 4,
           let hours = Double(parts[0]),
           let minutes = Double(parts[1]),
           let seconds = Double(parts[2]),
           let frames = Double(parts[3]) {
            return hours * 3_600
                + minutes * 60
                + seconds
                + frames / 30
        }
        return SubtitleText.timestamp(value)
    }
}

// MARK: - MPEG PES scanning

/// One private-stream packet from a VobSub or DVB subtitle file.
private struct SubtitlePESPacket {
    var pts: TimeInterval?
    var payload: Data
}

private enum SubtitlePES {
    /// Scans MPEG program-stream packets and decodes their PTS.
    static func packets(in data: Data) -> [SubtitlePESPacket] {
        var packets: [SubtitlePESPacket] = []
        var cursor = 0

        while cursor + 9 <= data.count {
            guard data[cursor] == 0x00,
                  data[cursor + 1] == 0x00,
                  data[cursor + 2] == 0x01 else {
                cursor += 1
                continue
            }

            let streamID = data[cursor + 3]
            let packetLength = Int(data[cursor + 4]) << 8
                | Int(data[cursor + 5])
            let payloadStart = cursor + 6
            let packetEnd = packetLength > 0
                ? min(data.count, payloadStart + packetLength)
                : data.count
            guard payloadStart + 3 <= packetEnd else {
                cursor += 4
                continue
            }

            let flags = data[payloadStart + 1]
            let ptsPresent = (flags & 0x80) != 0
            let headerDataLength = Int(data[payloadStart + 2])
            var pts: TimeInterval?
            if ptsPresent, payloadStart + 8 <= packetEnd {
                pts = decodePTS(data, at: payloadStart + 3)
            }
            let streamStart = min(
                packetEnd,
                payloadStart + 3 + headerDataLength
            )

            if streamID == 0xBD, streamStart < packetEnd {
                packets.append(
                    SubtitlePESPacket(
                        pts: pts,
                        payload: data.subdata(in: streamStart..<packetEnd)
                    )
                )
            }

            cursor = max(cursor + 4, packetEnd)
        }

        return packets
    }

    private static func decodePTS(_ data: Data, at index: Int) -> TimeInterval? {
        guard index + 5 <= data.count else {
            return nil
        }
        let b0 = UInt64(data[index])
        let b1 = UInt64(data[index + 1])
        let b2 = UInt64(data[index + 2])
        let b3 = UInt64(data[index + 3])
        let b4 = UInt64(data[index + 4])
        let ticks = ((b0 & 0x0E) << 29)
            | (b1 << 22)
            | ((b2 & 0xFE) << 14)
            | (b3 << 7)
            | (b4 >> 1)
        return Double(ticks) / 90_000
    }
}

private func readBigEndian16(_ data: Data, at index: Int) -> Int? {
    guard index + 2 <= data.count else {
        return nil
    }
    return Int(data[index]) << 8 | Int(data[index + 1])
}

// MARK: - VobSub / DVDSub

/// Parses DVD/VobSub `.sub` files.
///
/// Timing and placement come from each SPU control sequence. The bitmap is
/// represented as a transparent placeholder at the correct pixel region;
/// pixel decoding is delegated to the FFmpeg image-subtitle bridge when it is
/// linked, so long-tail files still expose accurate cues to the engine.
public struct VobSubParser: SubtitleParsing {
    public init() {}

    public func parse(_ data: Data) throws -> SubtitleDocument {
        let packets = SubtitlePES.packets(in: data)
        var raws: [(start: TimeInterval, region: Region)] = []

        for packet in packets {
            guard let pts = packet.pts else {
                continue
            }
            let payload = packet.payload
            guard payload.count >= 5 else {
                continue
            }

            let substreamOffset = (payload[0] >= 0x20 && payload[0] <= 0x3F)
                ? 1
                : 0
            guard let controlOffset = readBigEndian16(
                payload,
                at: substreamOffset + 2
            ) else {
                continue
            }
            let controlStart = substreamOffset + controlOffset
            guard controlStart + 4 <= payload.count else {
                continue
            }

            var cursor = controlStart + 4
            var region = Region()
            while cursor < payload.count {
                let command = payload[cursor]
                cursor += 1
                switch command {
                case 0x00, 0x01, 0x02:
                    cursor += 2
                case 0x03, 0x04:
                    cursor += 2
                case 0x05:
                    guard cursor + 8 <= payload.count,
                          let x1 = readBigEndian16(payload, at: cursor),
                          let x2 = readBigEndian16(payload, at: cursor + 2),
                          let y1 = readBigEndian16(payload, at: cursor + 4),
                          let y2 = readBigEndian16(payload, at: cursor + 6) else {
                        cursor = payload.count
                        break
                    }
                    region = Region(
                        x: x1,
                        y: y1,
                        width: max(0, x2 - x1 + 1),
                        height: max(0, y2 - y1 + 1)
                    )
                    cursor += 8
                case 0x06:
                    cursor += 4
                case 0x07...0x7F:
                    cursor += 1
                default:
                    cursor = payload.count
                }
            }

            raws.append((pts, region))
        }

        return makeDocument(from: raws, format: .vobsub)
    }
}

// MARK: - DVB

/// Parses DVB subtitle streams.
///
/// Each PES packet becomes one cue. Page composition carries the on-screen
/// duration and position, and region composition carries the bitmap size. As
/// with VobSub, the bitmap is a transparent placeholder until the FFmpeg image
/// bridge decodes the object segments.
public struct DVBSubtitleParser: SubtitleParsing {
    public init() {}

    public func parse(_ data: Data) throws -> SubtitleDocument {
        let packets = SubtitlePES.packets(in: data)
        var raws: [(start: TimeInterval, end: TimeInterval?, region: Region)] = []

        for packet in packets {
            guard let pts = packet.pts else {
                continue
            }
            let payload = packet.payload
            guard let identifier = payload.first,
                  identifier == 0x20 || identifier == 0x21 else {
                continue
            }

            var duration: TimeInterval?
            var region = Region()
            var pagePosition = (x: 0, y: 0)
            var cursor = 1

            while cursor + 6 <= payload.count {
                guard payload[cursor] == 0x0F else {
                    cursor += 1
                    continue
                }
                let type = payload[cursor + 1]
                guard let length = readBigEndian16(payload, at: cursor + 4) else {
                    break
                }
                let bodyStart = cursor + 6
                guard bodyStart + length <= payload.count else {
                    break
                }
                let body = payload.subdata(
                    in: bodyStart..<(bodyStart + length)
                )

                switch type {
                case 0x10:
                    if let timeout = body.first, timeout > 0 {
                        duration = TimeInterval(timeout)
                    }
                    if body.count >= 10 {
                        let x = Int(body[6]) << 8 | Int(body[7])
                        let y = Int(body[8]) << 8 | Int(body[9])
                        pagePosition = (x, y)
                    }
                case 0x11:
                    if body.count >= 7,
                       let width = readBigEndian16(body, at: 3),
                       let height = readBigEndian16(body, at: 5) {
                        region.width = width
                        region.height = height
                    }
                default:
                    break
                }

                cursor = bodyStart + length
            }

            region.x = pagePosition.x
            region.y = pagePosition.y
            raws.append(
                (
                    pts,
                    duration.map { pts + $0 },
                    region
                )
            )
        }

        var cues: [SubtitleCue] = []
        for (index, raw) in raws.enumerated() {
            var end = raw.end
            if end == nil || end! <= raw.start {
                if index + 1 < raws.count, raws[index + 1].start > raw.start {
                    end = raws[index + 1].start
                } else {
                    end = raw.start + 5
                }
            }
            guard let end, end > raw.start else {
                continue
            }
            cues.append(
                SubtitleCue(
                    id: index + 1,
                    start: raw.start,
                    end: end,
                    content: .image(raw.region.image())
                )
            )
        }

        return SubtitleDocument(format: .dvbsub, cues: cues)
    }
}

// MARK: - XSUB

/// Parses DivX XSUB subtitle chunks.
///
/// XSUB entries store a millisecond timestamp followed by the compressed
/// bitmap. Timing is decoded here; bitmap decoding is delegated to FFmpeg.
public struct XSubParser: SubtitleParsing {
    public init() {}

    public func parse(_ data: Data) throws -> SubtitleDocument {
        var cursor = 0
        if let marker = data.range(of: Data("XSUB".utf8)) {
            cursor = marker.upperBound
        }

        var starts: [TimeInterval] = []
        while cursor + 6 <= data.count {
            let milliseconds = UInt32(data[cursor])
                | UInt32(data[cursor + 1]) << 8
                | UInt32(data[cursor + 2]) << 16
                | UInt32(data[cursor + 3]) << 24
            let length = Int(data[cursor + 4])
                | Int(data[cursor + 5]) << 8
            guard length > 0, cursor + 6 + length <= data.count else {
                break
            }
            starts.append(TimeInterval(milliseconds) / 1_000)
            cursor += 6 + length
        }

        var cues: [SubtitleCue] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count
                ? starts[index + 1]
                : start + 3
            guard end > start else {
                continue
            }
            cues.append(
                SubtitleCue(
                    id: index + 1,
                    start: start,
                    end: end,
                    content: .image(Region().image())
                )
            )
        }

        return SubtitleDocument(format: .xsub, cues: cues)
    }
}

// MARK: - Shared image region

private struct Region {
    var x: Int = 0
    var y: Int = 0
    var width: Int = 1
    var height: Int = 1

    func image() -> SubtitleImage {
        let width = min(max(1, self.width), 3_840)
        let height = min(max(1, self.height), 2_160)
        return SubtitleImage(
            width: width,
            height: height,
            pixels: Data(count: width * height * 4),
            x: max(0, x),
            y: max(0, y)
        )
    }
}

private func makeDocument(
    from raws: [(start: TimeInterval, region: Region)],
    format: SubtitleFormat
) -> SubtitleDocument {
    var cues: [SubtitleCue] = []
    for (index, raw) in raws.enumerated() {
        let end = index + 1 < raws.count
            ? raws[index + 1].start
            : raw.start + 5
        guard end > raw.start else {
            continue
        }
        cues.append(
            SubtitleCue(
                id: index + 1,
                start: raw.start,
                end: end,
                content: .image(raw.region.image())
            )
        )
    }
    return SubtitleDocument(format: format, cues: cues)
}
