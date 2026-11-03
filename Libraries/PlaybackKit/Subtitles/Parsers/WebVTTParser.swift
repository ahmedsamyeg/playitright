import Foundation

/// Parses WebVTT (`.vtt`) text subtitles.
public struct WebVTTParser: SubtitleParsing {
    public init() {}

    public func parse(_ data: Data) throws -> SubtitleDocument {
        let lines = SubtitleText.lines(SubtitleText.decode(data))
        var cues: [SubtitleCue] = []
        var index = 0
        var nextID = 1

        // Skip the WEBVTT header and anything before the first blank line.
        if let first = lines.first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }), first.hasPrefix("WEBVTT") {
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
        }

        while index < lines.count {
            while index < lines.count,
                  lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            guard index < lines.count else {
                break
            }

            let firstLine = lines[index]
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("NOTE")
                || trimmed.hasPrefix("STYLE")
                || trimmed.hasPrefix("REGION") {
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                }
                continue
            }

            var identifier: Int?
            var timingLine = firstLine
            if !timingLine.contains("-->") {
                identifier = Int(trimmed)
                index += 1
                guard index < lines.count else {
                    throw SubtitleParseError.malformedCue(line: index)
                }
                timingLine = lines[index]
            }

            guard let timing = SubtitleText.timing(timingLine),
                  timing.end > timing.start else {
                throw SubtitleParseError.invalidTimestamp(
                    timingLine,
                    line: index + 1
                )
            }
            index += 1

            var textLines: [String] = []
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(SubtitleText.stripTags(lines[index]))
                index += 1
            }

            let settings = Self.settings(timing.settings)
            cues.append(
                SubtitleCue(
                    id: identifier ?? nextID,
                    start: timing.start,
                    end: timing.end,
                    content: .text(textLines.joined(separator: "\n")),
                    alignment: settings.alignment,
                    position: settings.position
                )
            )
            nextID = max(nextID + 1, (identifier ?? nextID) + 1)
        }

        return SubtitleDocument(format: .webvtt, cues: cues)
    }

    private static func settings(
        _ value: String
    ) -> (alignment: SubtitleAnchor, position: SubtitlePosition?) {
        var alignment: SubtitleAnchor = .bottomCenter
        var position: SubtitlePosition?
        var x: Double?
        var y: Double?

        for token in value.split(separator: " ") {
            let parts = token.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            let key = parts[0]
            let raw = String(parts[1])
            switch key {
            case "align":
                switch raw {
                case "start", "left":
                    alignment = .bottomLeft
                case "end", "right":
                    alignment = .bottomRight
                case "center", "middle":
                    alignment = .bottomCenter
                default:
                    break
                }
            case "position":
                let percent = raw.replacingOccurrences(of: "%", with: "")
                x = Double(percent).map { $0 / 100 }
            case "line":
                let percent = raw.replacingOccurrences(of: "%", with: "")
                y = Double(percent).map { $0 / 100 }
            default:
                break
            }
        }

        if let x {
            position = SubtitlePosition(x: x, y: y ?? 0.9, anchor: alignment)
        }
        return (alignment, position)
    }
}
