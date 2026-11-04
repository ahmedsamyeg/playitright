import PlaybackKit
import SwiftUI

/// The playback error recovery card. On an unrecoverable decode failure it
/// offers the next lower rung ("Try software", "Try server transcode") and a
/// redacted diagnostics export (NFR-15, doc 06 §2.4).
public struct PlaybackErrorCard: View {
    public let viewModel: DiagnosticsExportViewModel
    public let failure: PlaybackFailure
    public let onSelectRung: (PipelineRung) -> Void
    public let onDismiss: () -> Void

    @State private var exportError: String?

    public init(
        viewModel: DiagnosticsExportViewModel,
        failure: PlaybackFailure,
        onSelectRung: @escaping (PipelineRung) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.failure = failure
        self.onSelectRung = onSelectRung
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(3)) {
            header
            actions

            if let exportError {
                Text(exportError)
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.danger.color)
            }

            if let url = viewModel.lastExportURL {
                Text("Saved \(url.lastPathComponent)")
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
            }
        }
        .padding(DesignGrid.spacing(4))
        .frame(maxWidth: 900, alignment: .leading)
        .background(DesignTokens.palette.surfaceElevated.color)
        .clipShape(
            RoundedRectangle(
                cornerRadius: DesignTokens.Focus.cornerRadius,
                style: .continuous
            )
        )
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignGrid.spacing(2)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(DesignTokens.palette.warning.color)

            VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
                Text("Playback stopped")
                    .font(DesignTypography.title2)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)

                Text(failure.message)
                    .font(DesignTypography.body)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)

                Text("Failed on \(failure.currentRung.displayName).")
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textTertiary.color)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
            ForEach(viewModel.recoveryActions(for: failure)) { action in
                Button {
                    perform(action)
                } label: {
                    HStack(spacing: DesignGrid.spacing(2)) {
                        Image(systemName: iconName(for: action.kind))
                            .font(DesignTypography.headline)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title)
                                .font(DesignTypography.headline)

                            Text(action.detail)
                                .font(DesignTypography.caption)
                                .foregroundStyle(DesignTokens.palette.textSecondary.color)
                        }

                        Spacer()
                    }
                    .padding(DesignGrid.spacing(2))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.palette.surface.color)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: DesignTokens.Focus.cornerRadius,
                            style: .continuous
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(action.title). \(action.detail)")
            }
        }
    }

    private func perform(_ action: PlaybackRecoveryAction) {
        switch action.kind {
        case .retrySoftware, .retryServer:
            if let rung = action.targetRung {
                onSelectRung(rung)
            }
        case .reportDiagnostics:
            do {
                try viewModel.exportReport()
                exportError = nil
            } catch {
                exportError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func iconName(for kind: PlaybackRecoveryAction.Kind) -> String {
        switch kind {
        case .retrySoftware:
            return "cpu"
        case .retryServer:
            return "server.rack"
        case .reportDiagnostics:
            return "square.and.arrow.up"
        }
    }
}
