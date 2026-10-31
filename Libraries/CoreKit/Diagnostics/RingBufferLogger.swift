import Foundation

/// A severity level for diagnostic log entries.
public enum LogLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case debug
    case info
    case warning
    case error

    /// Numeric rank used for filtering and ordering.
    public var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A single structured diagnostic log entry.
///
/// Messages are redacted before they enter the ring buffer, and again when
/// exported, so credentials cannot leak through a hand-built entry.
public struct LogEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        category: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }

    /// Returns a copy whose user-controlled strings have been redacted.
    public func redacted() -> LogEntry {
        LogEntry(
            id: id,
            timestamp: timestamp,
            level: level,
            category: LogRedactor.redact(category),
            message: LogRedactor.redact(message)
        )
    }
}

/// A bounded, thread-safe in-memory ring buffer for diagnostic logs.
///
/// The logger keeps the most recent `capacity` entries (5,000 by default) and
/// drops the oldest entry once the buffer is full. All messages are passed
/// through `LogRedactor` before being stored.
public final class RingBufferLogger: @unchecked Sendable {
    /// The process-wide logger used by the app and frameworks.
    public static let shared = RingBufferLogger()

    /// The maximum number of retained entries.
    public let capacity: Int

    /// Entries below this level are discarded at write time.
    public let minimumLevel: LogLevel

    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private var storage: [LogEntry?]
    private var writeIndex = 0
    private var entryCount = 0

    /// Creates a ring buffer logger.
    ///
    /// - Parameters:
    ///   - capacity: Maximum retained entries. Must be greater than zero.
    ///   - minimumLevel: Lowest level that will be stored.
    ///   - clock: Timestamp source, injectable for deterministic tests.
    public init(
        capacity: Int = 5_000,
        minimumLevel: LogLevel = .debug,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(capacity > 0, "RingBufferLogger capacity must be greater than zero.")
        self.capacity = capacity
        self.minimumLevel = minimumLevel
        self.clock = clock
        self.storage = Array(repeating: nil, count: capacity)
    }

    /// The number of entries currently retained.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entryCount
    }

    /// Appends a redacted entry, evicting the oldest entry when full.
    public func log(
        _ message: String,
        level: LogLevel = .info,
        category: String = "general"
    ) {
        guard level >= minimumLevel else {
            return
        }

        let entry = LogEntry(
            timestamp: clock(),
            level: level,
            category: LogRedactor.redact(category),
            message: LogRedactor.redact(message)
        )

        lock.lock()
        defer { lock.unlock() }

        storage[writeIndex] = entry
        writeIndex = (writeIndex + 1) % capacity
        entryCount = min(entryCount + 1, capacity)
    }

    public func debug(_ message: String, category: String = "general") {
        log(message, level: .debug, category: category)
    }

    public func info(_ message: String, category: String = "general") {
        log(message, level: .info, category: category)
    }

    public func warning(_ message: String, category: String = "general") {
        log(message, level: .warning, category: category)
    }

    public func error(_ message: String, category: String = "general") {
        log(message, level: .error, category: category)
    }

    /// Returns retained entries from oldest to newest.
    public func snapshot() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    /// Returns retained entries at or above `level`, oldest to newest.
    public func snapshot(atLeast level: LogLevel) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked().filter { $0.level >= level }
    }

    /// Removes every retained entry.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        entryCount = 0
    }

    /// Builds a redacted, exportable diagnostic report from the current buffer.
    public func diagnosticReport(
        appVersion: String = "unknown",
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        deviceModel: String = "Apple TV",
        capabilities: [String: String] = [:],
        pipelinePlans: [String] = [],
        now: Date = Date()
    ) -> DiagnosticReport {
        DiagnosticReport(
            generatedAt: now,
            appVersion: appVersion,
            osVersion: osVersion,
            deviceModel: deviceModel,
            capabilities: capabilities,
            pipelinePlans: pipelinePlans,
            logs: snapshot()
        )
    }

    private func snapshotLocked() -> [LogEntry] {
        guard entryCount > 0 else {
            return []
        }

        let start = (writeIndex - entryCount + capacity) % capacity
        return (0..<entryCount).compactMap { offset in
            storage[(start + offset) % capacity]
        }
    }
}
