import Foundation

/// Case-insensitive glob matching used by source include/exclude filters.
enum SourceGlob {
    /// Whether a pattern matches an item, checking the file name or path.
    static func matches(
        pattern: String,
        name: String,
        path: String
    ) -> Bool {
        let candidate = pattern.contains("/") ? path : name
        guard let regex = regex(for: pattern) else {
            return false
        }
        let range = NSRange(
            candidate.startIndex..<candidate.endIndex,
            in: candidate
        )
        return regex.firstMatch(in: candidate, range: range) != nil
    }

    /// Applies include/exclude lists. An empty include list matches
    /// everything.
    static func allows(
        name: String,
        path: String,
        include: [String],
        exclude: [String]
    ) -> Bool {
        if !include.isEmpty {
            let included = include.contains {
                matches(pattern: $0, name: name, path: path)
            }
            guard included else {
                return false
            }
        }

        for pattern in exclude where matches(
            pattern: pattern,
            name: name,
            path: path
        ) {
            return false
        }
        return true
    }

    private static func regex(for pattern: String) -> NSRegularExpression? {
        var expression = "^"
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let character = pattern[index]
            switch character {
            case "*":
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    expression += ".*"
                    index = pattern.index(after: next)
                    continue
                }
                expression += ".*"
            case "?":
                expression += "."
            default:
                expression += NSRegularExpression.escapedPattern(
                    for: String(character)
                )
            }
            index = pattern.index(after: index)
        }

        expression += "$"
        return try? NSRegularExpression(
            pattern: expression,
            options: [.caseInsensitive]
        )
    }
}
