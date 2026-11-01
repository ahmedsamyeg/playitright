import Foundation

/// An inclusive byte range used for ranged reads.
///
/// Both bounds are byte offsets and `end` is inclusive, matching HTTP `Range`
/// semantics. Use `nil` for `end` to request every byte from `start` to the
/// end of the item.
public struct ByteRange: Codable, Hashable, Sendable {
    /// First byte to read (inclusive).
    public let start: Int64

    /// Last byte to read (inclusive), or `nil` for an open-ended range.
    public let end: Int64?

    public init(start: Int64, end: Int64? = nil) throws {
        guard start >= 0 else {
            throw ByteRangeError.invalidRange(start: start, end: end)
        }
        if let end, end < start {
            throw ByteRangeError.invalidRange(start: start, end: end)
        }
        self.start = start
        self.end = end
    }

    private init(uncheckedStart start: Int64, end: Int64?) {
        self.start = start
        self.end = end
    }

    /// Number of bytes covered, or `nil` for an open-ended range.
    public var length: Int64? {
        guard let end else {
            return nil
        }
        return end - start + 1
    }

    /// HTTP `Range` header value, for example `bytes=0-1023` or `bytes=1024-`.
    public var httpHeaderValue: String {
        "bytes=\(start)-\(end.map { String($0) } ?? "")"
    }

    /// Whether a byte offset falls inside this range.
    public func contains(_ offset: Int64) -> Bool {
        guard offset >= start else {
            return false
        }
        guard let end else {
            return true
        }
        return offset <= end
    }

    /// Clamps this range to a known item size.
    ///
    /// Returns `nil` when the range starts at or past the end of the item.
    public func clamped(to size: Int64) -> ByteRange? {
        guard size > 0, start < size else {
            return nil
        }
        let clampedEnd = min(end ?? (size - 1), size - 1)
        return ByteRange(uncheckedStart: start, end: clampedEnd)
    }

    /// Parses a standard single-range `Range` header (`bytes=start-end` or
    /// `bytes=start-`). Suffix and multipart ranges are not supported.
    public init?(httpHeaderValue: String) {
        let trimmed = httpHeaderValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.lowercased().hasPrefix("bytes=") else {
            return nil
        }

        let value = trimmed.dropFirst("bytes=".count)
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
              start >= 0 else {
            return nil
        }

        let endText = parts[1].trimmingCharacters(in: .whitespaces)
        if endText.isEmpty {
            self.init(uncheckedStart: start, end: nil)
            return
        }
        guard let end = Int64(endText), end >= start else {
            return nil
        }
        self.init(uncheckedStart: start, end: end)
    }

    /// The whole item (`bytes=0-`).
    public static let full = ByteRange(uncheckedStart: 0, end: nil)
}

/// Errors raised while constructing or applying a ``ByteRange``.
public enum ByteRangeError: Error, Equatable, Sendable, LocalizedError {
    /// The range was negative or ended before it started.
    case invalidRange(start: Int64, end: Int64?)

    /// The requested range is outside the item.
    case notSatisfiable(requested: ByteRange, size: Int64?)

    public var errorDescription: String? {
        switch self {
        case .invalidRange(let start, let end):
            return "Invalid byte range \(start)-\(end.map { String($0) } ?? "")."
        case .notSatisfiable(let range, let size):
            let sizeDescription = size.map { "\($0) bytes" } ?? "an unknown size"
            return "Byte range \(range.httpHeaderValue) is outside \(sizeDescription)."
        }
    }
}
