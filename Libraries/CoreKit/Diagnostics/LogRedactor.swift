import Foundation

/// Sanitizes strings before they enter logs or diagnostic reports.
///
/// Redaction is intentionally conservative: credentials, query parameters,
/// private-share paths, and IP addresses are removed even when that makes a
/// message less useful. Logs are never a place for secrets.
public enum LogRedactor {
    /// Returns a copy of `text` with sensitive substrings replaced.
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else {
            return text
        }

        var result = text

        // Authorization headers: `Bearer abc123`, `Basic dXNlcjpwYXNz`.
        result = replace(
            #"(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]+"#,
            in: result,
            with: "$1 [REDACTED]"
        )

        // Key/value secrets: `password=hunter2`, `"api_key": "..."`.
        result = replace(
            #"(?i)\b(password|passwd|pwd|token|secret|api[_-]?key|authorization)(\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;]+)"#,
            in: result,
            with: "$1$2[REDACTED]"
        )

        // URL userinfo: `smb://user:pass@host/share`.
        result = replace(
            #"\b([a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s@]+@"#,
            in: result,
            with: "$1[REDACTED]@"
        )

        // Private network-share paths keep the scheme and host only.
        result = replace(
            #"(?i)\b(smb|nfs|afp)://([^/\s"']+)/([^\s"']*)"#,
            in: result,
            with: "$1://$2/[REDACTED]"
        )

        // `file://` URLs reveal the local filesystem layout.
        result = replace(
            #"(?i)\bfile://[^\s"']+"#,
            in: result,
            with: "file://[REDACTED]"
        )

        // Query parameters frequently carry signed tokens.
        result = replace(
            #"\?[^\s"'#]+"#,
            in: result,
            with: "?[REDACTED]"
        )

        // IPv4 addresses identify private machines on the LAN.
        result = replace(
            #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
            in: result,
            with: "[REDACTED]"
        )

        return result
    }

    /// Redacts every value in a header dictionary while preserving key names.
    public static func redact(headers: [String: String]) -> [String: String] {
        var redacted: [String: String] = [:]
        for (name, value) in headers {
            let sensitive = ["authorization", "cookie", "set-cookie", "x-api-key", "token", "secret"]
                .contains(name.lowercased())
            redacted[name] = sensitive ? "[REDACTED]" : redact(value)
        }
        return redacted
    }

    private static func replace(
        _ pattern: String,
        in text: String,
        with template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
