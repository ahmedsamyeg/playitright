import Foundation

/// Shared helpers for the text subtitle parsers.
enum SubtitleText {
    /// Decodes UTF-8 or BOM-marked UTF-16 subtitle payloads.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian) ?? ""
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian) ?? ""
        }
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data.removeFirst(3)
        }
        return String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// Splits text into lines while tolerating CRLF, CR, and LF endings.
    static func lines(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Parses `h:mm:ss.cc`, `hh:mm:ss,mmm`, and `mm:ss.mmm` timestamps.
    static func timestamp(_ value: String) -> TimeInterval? {
        var text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            return nil
        }
        text = text.replacingOccurrences(of: ",", with: ".")
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else {
            return nil
        }

        let secondsPart = String(parts[parts.count - 1])
        let minutesPart = String(parts[parts.count - 2])
        let hoursPart = parts.count == 3 ? String(parts[0]) : "0"

        guard let hours = Double(hoursPart),
              let minutes = Double(minutesPart),
              let seconds = Double(secondsPart),
              hours >= 0,
              minutes >= 0,
              minutes < 60,
              seconds >= 0,
              seconds < 60 else {
            return nil
        }
        return hours * 3_600 + minutes * 60 + seconds
    }

    /// Splits an SRT/WebVTT timing line into start and end timestamps.
    static func timing(
        _ line: String
    ) -> (start: TimeInterval, end: TimeInterval, settings: String)? {
        let pieces = line.components(separatedBy: "-->")
        guard pieces.count == 2 else {
            return nil
        }
        let startText = pieces[0].trimmingCharacters(in: .whitespaces)
        let right = pieces[1].trimmingCharacters(in: .whitespaces)
        let endText = right.split(separator: " ", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let settings = right.split(separator: " ", maxSplits: 1)
            .dropFirst()
            .first
            .map(String.init) ?? ""
        guard let start = timestamp(startText),
              let end = timestamp(endText) else {
            return nil
        }
        return (start, end, settings)
    }

    /// Removes simple HTML/WebVTT tags while preserving their text content.
    static func stripTags(_ text: String) -> String {
        var result = ""
        var insideTag = false
        for character in text {
            if character == "<" {
                insideTag = true
            } else if character == ">" {
                insideTag = false
            } else if !insideTag {
                result.append(character)
            }
        }
        return result
    }

    /// Removes ASS override blocks such as `{\an8}`.
    static func stripASSOverrides(_ text: String) -> String {
        var result = ""
        var insideOverride = false
        for character in text {
            if character == "{" {
                insideOverride = true
            } else if character == "}" {
                insideOverride = false
            } else if !insideOverride {
                result.append(character)
            }
        }
        return result
    }

    /// Extracts `\anN`, `\pos(x,y)`, `\b1`, `\i1`, and font size overrides.
    static func assOverrides(
        _ text: String
    ) -> (alignment: Int?, position: (Double, Double)?, bold: Bool?, italic: Bool?) {
        var alignment: Int?
        var position: (Double, Double)?
        var bold: Bool?
        var italic: Bool?
        var buffer = ""
        var inside = false
        for character in text {
            if character == "{" {
                inside = true
                buffer = ""
            } else if character == "}" {
                inside = false
                parseOverride(
                    buffer,
                    alignment: &alignment,
                    position: &position,
                    bold: &bold,
                    italic: &italic
                )
            } else if inside {
                buffer.append(character)
            }
        }
        return (alignment, position, bold, italic)
    }

    private static func parseOverride(
        _ override: String,
        alignment: inout Int?,
        position: inout (Double, Double)?,
        bold: inout Bool?,
        italic: inout Bool?
    ) {
        let tokens = override.split(separator: "\\")
        for token in tokens {
            let token = String(token)
            if token.hasPrefix("an"), let value = Int(token.dropFirst(2)) {
                alignment = value
            } else if token.hasPrefix("pos("), token.hasSuffix(")") {
                let inside = token.dropFirst(4).dropLast()
                let parts = inside.split(separator: ",")
                if parts.count == 2,
                   let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                   let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                    position = (x, y)
                }
            } else if token == "b1" || token == "b700" {
                bold = true
            } else if token == "b0" {
                bold = false
            } else if token == "i1" {
                italic = true
            } else if token == "i0" {
                italic = false
            }
        }
    }

    /// Replaces ASS newline and hard-space escapes.
    static func assText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
    }
}
