import Foundation

/// Parses Advanced SubStation Alpha (`.ass`/`.ssa`) subtitles.
public struct ASSParser: SubtitleParsing {
    private struct Style {
        var fontName: String?
        var fontSize: Double?
        var alignment: Int?
        var bold: Bool
        var italic: Bool
        var forced: Bool
    }

    private var styles: [String: Style] = [:]
    private var playResX = 1_920
    private var playResY = 1_080

    public init() {}

    public func parse(_ data: Data) throws -> SubtitleDocument {
        var parser = self
        return try parser.parsePayload(data)
    }

    private mutating func parsePayload(_ data: Data) throws -> SubtitleDocument {
        let lines = SubtitleText.lines(SubtitleText.decode(data))
        var section = ""
        var eventFormat: [String] = []
        var styleFormat: [String] = []
        var cues: [SubtitleCue] = []
        var nextID = 1

        for (lineIndex, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";") else {
                continue
            }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.lowercased()
                continue
            }

            if section == "[script info]" {
                if let value = Self.value(after: "PlayResX:", in: line) {
                    playResX = Int(value) ?? playResX
                } else if let value = Self.value(after: "PlayResY:", in: line) {
                    playResY = Int(value) ?? playResY
                }
                continue
            }

            if section == "[v4+ styles]" || section == "[v4 styles]" {
                if line.lowercased().hasPrefix("format:") {
                    styleFormat = Self.fields(
                        String(line.dropFirst("Format:".count))
                    )
                } else if line.lowercased().hasPrefix("style:") {
                    let values = Self.values(
                        String(line.dropFirst("Style:".count)),
                        count: styleFormat.count
                    )
                    if let name = Self.field("Name", in: values, format: styleFormat) {
                        let style = Style(
                            fontName: Self.field(
                                "Fontname",
                                in: values,
                                format: styleFormat
                            ),
                            fontSize: Self.field(
                                "Fontsize",
                                in: values,
                                format: styleFormat
                            ).flatMap(Double.init),
                            alignment: Self.field(
                                "Alignment",
                                in: values,
                                format: styleFormat
                            ).flatMap(Int.init),
                            bold: Self.field(
                                "Bold",
                                in: values,
                                format: styleFormat
                            ) == "1",
                            italic: Self.field(
                                "Italic",
                                in: values,
                                format: styleFormat
                            ) == "1",
                            forced: name.lowercased().contains("forced")
                        )
                        styles[name] = style
                    }
                }
                continue
            }

            guard section == "[events]" else {
                continue
            }

            if line.lowercased().hasPrefix("format:") {
                eventFormat = Self.fields(
                    String(line.dropFirst("Format:".count))
                )
                continue
            }

            guard line.lowercased().hasPrefix("dialogue:") else {
                continue
            }

            let values = Self.values(
                String(line.dropFirst("Dialogue:".count)),
                count: eventFormat.count
            )
            let format = eventFormat.isEmpty
                ? ["Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"]
                : eventFormat

            guard let startText = Self.field("Start", in: values, format: format),
                  let endText = Self.field("End", in: values, format: format),
                  let start = SubtitleText.timestamp(startText),
                  let end = SubtitleText.timestamp(endText),
                  end > start else {
                throw SubtitleParseError.invalidTimestamp(
                    line,
                    line: lineIndex + 1
                )
            }

            let styleName = Self.field("Style", in: values, format: format)
            let actor = Self.field("Name", in: values, format: format)
            let rawText = Self.field("Text", in: values, format: format) ?? ""
            let style = styleName.flatMap { styles[$0] }

            let overrides = SubtitleText.assOverrides(rawText)
            let text = SubtitleText.stripASSOverrides(
                SubtitleText.assText(rawText)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            let alignmentValue = overrides.alignment
                ?? style?.alignment
                ?? 2
            let alignment = SubtitleAnchor(assAlignment: alignmentValue)
                ?? .bottomCenter

            let position: SubtitlePosition?
            if let (x, y) = overrides.position {
                position = SubtitlePosition(
                    x: x / Double(max(1, playResX)),
                    y: y / Double(max(1, playResY)),
                    anchor: alignment
                )
            } else {
                position = nil
            }

            let forced = style?.forced == true
                || (styleName?.lowercased().contains("forced") ?? false)
                || actor?.lowercased().contains("forced") == true

            cues.append(
                SubtitleCue(
                    id: nextID,
                    start: start,
                    end: end,
                    content: .text(text),
                    isForced: forced,
                    alignment: alignment,
                    position: position,
                    styleName: styleName,
                    isBold: overrides.bold ?? style?.bold ?? false,
                    isItalic: overrides.italic ?? style?.italic ?? false
                )
            )
            nextID += 1
        }

        return SubtitleDocument(
            format: .ass,
            cues: cues,
            playResX: playResX,
            playResY: playResY
        )
    }

    private static func fields(_ value: String) -> [String] {
        value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func values(_ value: String, count: Int) -> [String] {
        let splitCount = max(0, count - 1)
        return value.split(
            separator: ",",
            maxSplits: splitCount,
            omittingEmptySubsequences: false
        ).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func field(
        _ name: String,
        in values: [String],
        format: [String]
    ) -> String? {
        guard let index = format.firstIndex(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }), index < values.count else {
            return nil
        }
        return values[index]
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard line.lowercased().hasPrefix(prefix.lowercased()) else {
            return nil
        }
        return line.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespaces)
    }
}
