import Foundation

/// A bounded, user-exportable diagnostics snapshot.
///
/// Reports intentionally include only coarse device information, capability
/// probe results, pipeline plans, and redacted log entries. They never include
/// library content metadata, private share paths, or credentials (NFR-12).
public struct DiagnosticReport: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let appVersion: String
    public let osVersion: String
    public let deviceModel: String
    public let capabilities: [String: String]
    public let pipelinePlans: [String]
    public let logs: [LogEntry]

    public init(
        generatedAt: Date,
        appVersion: String,
        osVersion: String,
        deviceModel: String,
        capabilities: [String: String] = [:],
        pipelinePlans: [String] = [],
        logs: [LogEntry] = []
    ) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.capabilities = capabilities.mapValues { LogRedactor.redact($0) }
        self.pipelinePlans = pipelinePlans.map { LogRedactor.redact($0) }
        self.logs = logs.map { $0.redacted() }
    }

    /// Encodes the report as JSON.
    ///
    /// - Parameter prettyPrinted: Whether to emit human-readable JSON.
    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Encodes the report as a UTF-8 JSON string.
    public func jsonString(prettyPrinted: Bool = true) throws -> String {
        let data = try jsonData(prettyPrinted: prettyPrinted)
        return String(decoding: data, as: UTF8.self)
    }
}
