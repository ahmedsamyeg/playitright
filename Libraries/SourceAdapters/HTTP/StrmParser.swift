import Foundation

/// Reads the target URL from a Kodi-style `.strm` / `.strmlnk` file.
///
/// The first non-empty, non-comment line wins. Targets are resolved through
/// ``HTTPURLSecurityPolicy``, so `file://` and other non-HTTP schemes are
/// rejected (NFR-9).
public struct StrmParser: Sendable, Equatable {
    public var policy: HTTPURLSecurityPolicy

    public init(policy: HTTPURLSecurityPolicy = HTTPURLSecurityPolicy()) {
        self.policy = policy
    }

    /// Parses `.strm` bytes.
    public func parse(
        data: Data,
        relativeTo baseURL: URL? = nil
    ) throws -> URL {
        guard var text = String(data: data, encoding: .utf8) else {
            throw HTTPURLSecurityError.emptyStrm
        }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return try parse(text: text, relativeTo: baseURL)
    }

    /// Parses `.strm` text.
    public func parse(
        text: String,
        relativeTo baseURL: URL? = nil
    ) throws -> URL {
        for rawLine in text.split(
            whereSeparator: { $0 == "\n" || $0 == "\r" }
        ) {
            var line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines.union(
                    CharacterSet(charactersIn: "\u{FEFF}")
                )
            )
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            // Some tools wrap the target in single or double quotes.
            if line.count >= 2,
               let first = line.first,
               let last = line.last,
               (first == "\"" && last == "\"")
                || (first == "'" && last == "'") {
                line.removeFirst()
                line.removeLast()
            }

            return try policy.resolve(line, relativeTo: baseURL)
        }

        throw HTTPURLSecurityError.emptyStrm
    }

    /// Whether a path is a Kodi stream indirection file.
    public static func isStrmFile(_ url: URL) -> Bool {
        let extensionName = url.pathExtension.lowercased()
        return extensionName == "strm" || extensionName == "strmlnk"
    }
}
