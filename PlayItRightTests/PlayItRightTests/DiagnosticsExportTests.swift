import CoreKit
import Foundation
import PlaybackKit
import Testing
@testable import PlayItRight

// MARK: - Fixtures

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
private func makeViewModel(
    logger: RingBufferLogger,
    directory: URL
) -> DiagnosticsExportViewModel {
    DiagnosticsExportViewModel(
        logger: logger,
        appVersion: "1.4 (42)",
        osVersion: "tvOS 18.1 (22J558)",
        deviceModel: "Apple TV 4K (3rd generation)",
        capabilities: [
            "video.hevc": "hardware",
            "server.url": "smb://admin:hunter2@192.168.1.10/Media"
        ],
        pipelinePlans: [
            "R1 Direct · HEVC · smb://admin:hunter2@192.168.1.10/Media"
        ],
        exportDirectory: directory,
        now: { fixedDate }
    )
}

@MainActor
private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func makeLogger() -> RingBufferLogger {
    RingBufferLogger(capacity: 50, clock: { fixedDate })
}

// MARK: - Tests

@MainActor
@Suite("DiagnosticsExport Tests")
struct DiagnosticsExportTests {
    @Test("The report contains coarse device facts and redacted logs")
    func reportIsRedacted() throws {
        let logger = makeLogger()
        logger.info("Opened smb://admin:hunter2@192.168.1.10/Media", category: "library")
        logger.error(
            "Authorization: Bearer abc.def.ghi failed for user password=hunter2",
            category: "auth"
        )

        let viewModel = makeViewModel(
            logger: logger,
            directory: try makeTempDirectory()
        )
        let report = viewModel.makeReport()

        #expect(report.generatedAt == fixedDate)
        #expect(report.appVersion == "1.4 (42)")
        #expect(report.osVersion == "tvOS 18.1 (22J558)")
        #expect(report.deviceModel == "Apple TV 4K (3rd generation)")
        #expect(report.logs.count == 2)
        #expect(report.capabilities["video.hevc"] == "hardware")

        let serialized = try report.jsonString()
        #expect(!serialized.contains("hunter2"))
        #expect(!serialized.contains("abc.def.ghi"))
        #expect(!serialized.contains("192.168.1.10"))
        #expect(serialized.contains("[REDACTED]"))
    }

    @Test("Export writes a valid redacted JSON file")
    func exportWritesValidJSON() throws {
        let logger = makeLogger()
        logger.warning(
            "GET https://user:hunter2@example.com/api?token=secret HTTP/1.1",
            category: "network"
        )

        let directory = try makeTempDirectory()
        let viewModel = makeViewModel(logger: logger, directory: directory)

        let url = try viewModel.exportReport()

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "json")
        #expect(url.lastPathComponent.hasPrefix("PlayItRight-Diagnostics-"))
        #expect(viewModel.lastExportURL == url)
        #expect(viewModel.errorMessage == nil)

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticReport.self, from: data)

        #expect(decoded.appVersion == "1.4 (42)")
        #expect(decoded.logs.count == 1)
        #expect(decoded.logs.first?.category == "network")
        #expect(decoded.logs.first?.message.contains("hunter2") == false)
        #expect(decoded.logs.first?.message.contains("secret") == false)

        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("secret"))
        #expect(text.contains("R1 Direct"))
    }

    @Test("Exporting an empty buffer still produces a valid report")
    func exportEmptyBuffer() throws {
        let directory = try makeTempDirectory()
        let viewModel = makeViewModel(
            logger: makeLogger(),
            directory: directory
        )

        let url = try viewModel.exportReport()
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticReport.self, from: data)

        #expect(decoded.logs.isEmpty)
        #expect(decoded.capabilities["video.hevc"] == "hardware")
        #expect(viewModel.exportStatus.contains(url.lastPathComponent))
    }

    @Test("The next lower rung walks the ladder and then stops")
    func nextLowerRung() throws {
        let viewModel = makeViewModel(
            logger: makeLogger(),
            directory: try makeTempDirectory()
        )

        #expect(viewModel.nextLowerRung(after: .r1Direct) == .r2Remux)
        #expect(viewModel.nextLowerRung(after: .r2Remux) == .r3HardwareTranscode)
        #expect(
            viewModel.nextLowerRung(after: .r3HardwareTranscode)
                == .r4SoftwareTranscode
        )
        #expect(
            viewModel.nextLowerRung(after: .r4SoftwareTranscode)
                == .r5ServerTranscode
        )
        #expect(viewModel.nextLowerRung(after: .r5ServerTranscode) == nil)
    }

    @Test("The error card offers software, server, and diagnostics actions")
    func recoveryActions() throws {
        let viewModel = makeViewModel(
            logger: makeLogger(),
            directory: try makeTempDirectory()
        )

        let hardwareFailure = PlaybackFailure(
            message: "The video decoder stopped.",
            currentRung: .r1Direct,
            serverTranscodeAvailable: true
        )
        let hardwareActions = viewModel.recoveryActions(for: hardwareFailure)
        #expect(hardwareActions.map(\.kind) == [
            .retrySoftware,
            .retryServer,
            .reportDiagnostics
        ])
        #expect(
            hardwareActions.first { $0.kind == .retrySoftware }?.targetRung
                == .r4SoftwareTranscode
        )
        #expect(
            hardwareActions.first { $0.kind == .retryServer }?.targetRung
                == .r5ServerTranscode
        )

        let softwareFailure = PlaybackFailure(
            message: "The software decoder stopped.",
            currentRung: .r4SoftwareTranscode,
            serverTranscodeAvailable: true
        )
        #expect(viewModel.recoveryActions(for: softwareFailure).map(\.kind) == [
            .retryServer,
            .reportDiagnostics
        ])

        let serverFailure = PlaybackFailure(
            message: "The server could not transcode.",
            currentRung: .r5ServerTranscode,
            serverTranscodeAvailable: true
        )
        #expect(viewModel.recoveryActions(for: serverFailure).map(\.kind) == [
            .reportDiagnostics
        ])

        let noServer = PlaybackFailure(
            message: "The decoder stopped.",
            currentRung: .r2Remux,
            serverTranscodeAvailable: false
        )
        #expect(viewModel.recoveryActions(for: noServer).map(\.kind) == [
            .retrySoftware,
            .reportDiagnostics
        ])
    }

    @Test("Recovery actions use plain-language copy")
    func recoveryCopy() throws {
        let viewModel = makeViewModel(
            logger: makeLogger(),
            directory: try makeTempDirectory()
        )
        let actions = viewModel.recoveryActions(
            for: PlaybackFailure(
                message: "Stopped.",
                currentRung: .r1Direct,
                serverTranscodeAvailable: true
            )
        )

        #expect(actions.first { $0.kind == .retrySoftware }?.title == "Try software")
        #expect(
            actions.first { $0.kind == .retryServer }?.title
                == "Try server transcode"
        )
        #expect(
            actions.first { $0.kind == .reportDiagnostics }?.title
                == "Report diagnostics"
        )
        #expect(
            actions.first { $0.kind == .reportDiagnostics }?.detail
                .contains("redacted") == true
        )
    }
}
