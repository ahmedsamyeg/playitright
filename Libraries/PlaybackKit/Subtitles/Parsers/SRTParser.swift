import Foundation

/// Parses SubRip (`.srt`) text subtitles.
public struct SRTParser: SubtitleParsing {
    public init() {}

    public func parse(_ data: Data) throws -> SubtitleDocument {
        let lines = SubtitleText.lines(SubtitleText.decode(data))
        var cues: [SubtitleCue] = []
        var index = 0
        var nextID = 1

        while index < lines.count {
            while index < lines.count,
                  lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            guard index < lines.count else {
                break
            }

            var identifier: Int?
            var timingLine = lines[index]
            if !timingLine.contains("-->") {
                identifier = Int(
                    timingLine.trimmingCharacters(in: .whitespaces)
                )
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

            let text = textLines.joined(separator: "\n")
            cues.append(
                SubtitleCue(
                    id: identifier ?? nextID,
                    start: timing.start,
                    end: timing.end,
                    content: .text(text)
                )
            )
            nextID = max(nextID + 1, (identifier ?? nextID) + 1)
        }

        return SubtitleDocument(format: .srt, cues: cues)
    }
}
