import CoreKit
import Foundation
import Observation
import PlaybackKit

/// A recoverable playback failure surfaced to the player error card
/// (NFR-15, doc 06 §2.4).
public struct PlaybackFailure: Sendable, Equatable {
    public let message: String
    public let currentRung: PipelineRung
    public let serverTranscodeAvailable: Bool
    public let fileId: String?
    public let codec: String?

    public init(
        message: String,
        currentRung: PipelineRung,
        serverTranscodeAvailable: Bool = false,
        fileId: String? = nil,
        codec: String? = nil
    ) {
        self.message = message
        self.currentRung = currentRung
        self.serverTranscodeAvailable = serverTranscodeAvailable
        self.fileId = fileId
        self.codec = codec
    }
}

/// One action offered by the playback error recovery card.
public struct PlaybackRecoveryAction: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case retrySoftware
        case retryServer
        case reportDiagnostics
    }

    public let kind: Kind
    public let title: String
    public let detail: String
    public let targetRung: PipelineRung?

    public var id: String { kind.rawValue }

    public init(
        kind: Kind,
        title: String,
        detail: String,
        targetRung: PipelineRung? = nil
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.targetRung = targetRung
    }
}

/// Builds and exports redacted diagnostic reports, and derives graceful
/// playback recovery options (NFR-12, NFR-15, doc 06 §2.4, doc 09 §4).
@MainActor
@Observable
public final class DiagnosticsExportViewModel {
    public private(set) var isExporting = false
    public private(set) var lastExportURL: URL?
    public private(set) var errorMessage: String?

    public let logger: RingBufferLogger
    public let appVersion: String
    public let osVersion: String
    public let deviceModel: String

    /// Capability probe results, e.g. `["video.hevc": "hardware"]`.
    public var capabilities: [String: String]

    /// One-line summaries of recent pipeline plans.
    public var pipelinePlans: [String]

    private let exportDirectory: URL
    private let now: () -> Date
    private let fileManager: FileManager

    public init(
        logger: RingBufferLogger = .shared,
        appVersion: String = "",
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        deviceModel: String = "Apple TV",
        capabilities: [String: String] = [:],
        pipelinePlans: [String] = [],
        exportDirectory: URL? = nil,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.logger = logger
        self.appVersion = appVersion.isEmpty
            ? DiagnosticsExportViewModel.bundleVersion
            : appVersion
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.capabilities = capabilities
        self.pipelinePlans = pipelinePlans
        self.exportDirectory = exportDirectory
            ?? DiagnosticsExportViewModel.defaultExportDirectory
        self.now = now
        self.fileManager = fileManager
    }

    // MARK: - Report

    /// Builds a redacted report from the current log buffer.
    public func makeReport() -> DiagnosticReport {
        logger.diagnosticReport(
            appVersion: appVersion,
            osVersion: osVersion,
            deviceModel: deviceModel,
            capabilities: capabilities,
            pipelinePlans: pipelinePlans,
            now: now()
        )
    }

    /// Writes the redacted report as pretty-printed JSON and returns its URL.
    @discardableResult
    public func exportReport() throws -> URL {
        isExporting = true
        defer { isExporting = false }

        do {
            let report = makeReport()
            let data = try report.jsonData()
            try fileManager.createDirectory(
                at: exportDirectory,
                withIntermediateDirectories: true
            )
            let url = exportDirectory
                .appendingPathComponent(Self.fileName(for: now()))
            try data.write(to: url, options: .atomic)
            lastExportURL = url
            errorMessage = nil
            logger.info(
                "Exported diagnostics report.",
                category: "diagnostics"
            )
            return url
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Human-readable status for the Settings row.
    public var exportStatus: String {
        guard let lastExportURL else {
            return "Redacted logs and playback metadata"
        }
        return "Exported \(lastExportURL.lastPathComponent)"
    }

    // MARK: - Error Recovery

    /// The next rung down the ladder, or `nil` when already at server
    /// transcode. Used to recover automatically on an unrecoverable decode
    /// error (NFR-15).
    public func nextLowerRung(after rung: PipelineRung) -> PipelineRung? {
        PipelineRung.allCases.first { $0.rank == rung.rank + 1 }
    }

    /// The recovery choices shown by the playback error card. "Try software"
    /// and "Try server transcoding" only appear when they are actually lower
    /// (or equal) rungs than the failed plan.
    public func recoveryActions(
        for failure: PlaybackFailure
    ) -> [PlaybackRecoveryAction] {
        var actions: [PlaybackRecoveryAction] = []

        if failure.currentRung < .r4SoftwareTranscode {
            actions.append(
                PlaybackRecoveryAction(
                    kind: .retrySoftware,
                    title: "Try software",
                    detail: "Decode on the CPU instead of the media engine.",
                    targetRung: .r4SoftwareTranscode
                )
            )
        }

        if failure.serverTranscodeAvailable
            && failure.currentRung < .r5ServerTranscode {
            actions.append(
                PlaybackRecoveryAction(
                    kind: .retryServer,
                    title: "Try server transcode",
                    detail: "Ask your server to convert this title.",
                    targetRung: .r5ServerTranscode
                )
            )
        }

        actions.append(
            PlaybackRecoveryAction(
                kind: .reportDiagnostics,
                title: "Report diagnostics",
                detail: "Export a redacted report to share with support."
            )
        )

        return actions
    }
}

// MARK: - Defaults

private extension DiagnosticsExportViewModel {
    static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    static var defaultExportDirectory: URL {
        let base = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(
            "Diagnostics",
            isDirectory: true
        )
    }

    static func fileName(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        return "PlayItRight-Diagnostics-\(stamp).json"
    }
}
