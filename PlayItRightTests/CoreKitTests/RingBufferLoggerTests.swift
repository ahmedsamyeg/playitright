import Foundation
import Testing
@testable import CoreKit

@Suite("RingBufferLogger Tests")
struct RingBufferLoggerTests {
    private final class FixedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000_000)

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            defer { current.addTimeInterval(1) }
            return current
        }
    }

    // MARK: - Ring buffer behaviour

    @Test("Buffer retains only the newest entries once capacity is reached")
    func capacityOverwritesOldestEntries() {
        let clock = FixedClock()
        let logger = RingBufferLogger(capacity: 3, clock: { clock.now() })

        for message in ["one", "two", "three", "four", "five"] {
            logger.info(message)
        }

        #expect(logger.count == 3)
        #expect(logger.snapshot().map(\.message) == ["three", "four", "five"])
    }

    @Test("Entries are returned oldest to newest")
    func entriesAreOrderedOldestFirst() {
        let clock = FixedClock()
        let logger = RingBufferLogger(capacity: 10, clock: { clock.now() })

        logger.info("first")
        logger.warning("second")
        logger.error("third")

        #expect(logger.snapshot().map(\.message) == ["first", "second", "third"])
        #expect(logger.snapshot().map(\.level) == [.info, .warning, .error])
    }

    @Test("Entries below the minimum level are discarded")
    func minimumLevelFiltersWrites() {
        let logger = RingBufferLogger(capacity: 10, minimumLevel: .warning)

        logger.debug("debug")
        logger.info("info")
        logger.warning("warning")
        logger.error("error")

        #expect(logger.snapshot().map(\.message) == ["warning", "error"])
    }

    @Test("Filtered snapshots return only qualifying levels")
    func filteredSnapshot() {
        let logger = RingBufferLogger(capacity: 10)

        logger.debug("debug")
        logger.info("info")
        logger.warning("warning")
        logger.error("error")

        #expect(logger.snapshot(atLeast: .warning).map(\.message) == ["warning", "error"])
    }

    @Test("clear removes every retained entry")
    func clearRemovesEntries() {
        let logger = RingBufferLogger(capacity: 5)
        logger.info("one")
        logger.info("two")

        logger.clear()

        #expect(logger.count == 0)
        #expect(logger.snapshot().isEmpty)

        logger.info("after")
        #expect(logger.snapshot().map(\.message) == ["after"])
    }

    @Test("Concurrent writers never exceed capacity")
    func concurrentWritesRespectCapacity() async {
        let logger = RingBufferLogger(capacity: 100)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<1_000 {
                group.addTask {
                    logger.info("message \(index)")
                }
            }
        }

        #expect(logger.count == 100)
        #expect(logger.snapshot().count == 100)
    }

    // MARK: - Redaction

    @Test("Share URLs lose credentials, paths, and LAN addresses")
    func redactsShareURL() {
        let redacted = LogRedactor.redact("smb://user:pass@192.168.1.100/share/private.mkv")

        #expect(redacted.contains("smb://[REDACTED]@"))
        #expect(!redacted.contains("user"))
        #expect(!redacted.contains("pass"))
        #expect(!redacted.contains("192.168.1.100"))
        #expect(!redacted.contains("private.mkv"))
    }

    @Test("Authorization headers and query parameters are redacted")
    func redactsAuthHeadersAndQueries() {
        let input = #"Authorization: Bearer eyJhbGciOiJIUzI1NiJ9 token=abc123 url=https://api.example.com/v1?api_key=secret&q=1"#
        let redacted = LogRedactor.redact(input)

        #expect(!redacted.contains("eyJhbGciOiJIUzI1NiJ9"))
        #expect(!redacted.contains("abc123"))
        #expect(!redacted.contains("secret"))
        #expect(redacted.contains("[REDACTED]"))
    }

    @Test("Key/value secrets are redacted regardless of casing")
    func redactsKeyValueSecrets() {
        let redacted = LogRedactor.redact(#"Password="hunter2" api_key: sk-12345 secret=topsecret"#)

        #expect(!redacted.contains("hunter2"))
        #expect(!redacted.contains("sk-12345"))
        #expect(!redacted.contains("topsecret"))
    }

    @Test("file URLs are redacted")
    func redactsFileURLs() {
        let redacted = LogRedactor.redact("opened file:///Users/alex/Movies/secret.mkv")

        #expect(!redacted.contains("alex"))
        #expect(!redacted.contains("secret.mkv"))
        #expect(redacted.contains("file://[REDACTED]"))
    }

    @Test("Header dictionaries redact sensitive names and values")
    func redactsHeaderDictionary() {
        let redacted = LogRedactor.redact(headers: [
            "Authorization": "Bearer abc",
            "X-Api-Key": "key",
            "Accept": "application/json"
        ])

        #expect(redacted["Authorization"] == "[REDACTED]")
        #expect(redacted["X-Api-Key"] == "[REDACTED]")
        #expect(redacted["Accept"] == "application/json")
    }

    @Test("Logger redacts messages before storing them")
    func loggerRedactsAtWriteTime() {
        let logger = RingBufferLogger(capacity: 5)
        logger.info("connecting to smb://alex:secret@10.0.0.5/media")

        let stored = logger.snapshot().first?.message ?? ""

        #expect(!stored.contains("alex"))
        #expect(!stored.contains("secret"))
        #expect(!stored.contains("10.0.0.5"))
    }

    // MARK: - Diagnostic reports

    @Test("JSON report omits credentials from logs")
    func reportJSONOmitsSecrets() throws {
        let logger = RingBufferLogger(capacity: 10)
        logger.info("token=abc123 connecting to smb://user:pass@192.168.1.5/share")

        let report = logger.diagnosticReport(
            appVersion: "1.0",
            osVersion: "tvOS 18.0",
            deviceModel: "Apple TV 4K",
            capabilities: ["av1": "true"],
            pipelinePlans: ["plan: smb://user:pass@192.168.1.5/share"]
        )

        let json = try report.jsonString()

        #expect(!json.contains("abc123"))
        #expect(!json.contains("user:pass"))
        #expect(!json.contains("192.168.1.5"))
        #expect(json.contains("Apple TV 4K"))
    }

    @Test("Report round-trips through JSON")
    func reportRoundTrips() throws {
        let logger = RingBufferLogger(capacity: 10, clock: { Date(timeIntervalSince1970: 500) })
        logger.warning("hello", category: "test")

        let report = logger.diagnosticReport(
            appVersion: "2.0",
            osVersion: "tvOS 18.1",
            deviceModel: "Apple TV 4K",
            now: Date(timeIntervalSince1970: 500)
        )

        let data = try report.jsonData()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticReport.self, from: data)

        #expect(decoded == report)
    }

    @Test("Hand-built report entries are redacted as defence in depth")
    func reportRedactsInjectedEntries() {
        let entry = LogEntry(
            timestamp: Date(timeIntervalSince1970: 0),
            level: .error,
            category: "network",
            message: "Authorization: Bearer leaked-token"
        )

        let report = DiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: "1.0",
            osVersion: "tvOS",
            deviceModel: "Apple TV",
            logs: [entry]
        )

        #expect(!(report.logs.first?.message.contains("leaked-token") ?? true))
    }
}
