import SwiftUI

/// Privacy & Diagnostics: exports a redacted JSON report that can be shared
/// through AirDrop or the Files app (NFR-12, doc 06 §2.5, doc 09 §4).
public struct DiagnosticsExportView: View {
    public let viewModel: DiagnosticsExportViewModel

    public init(viewModel: DiagnosticsExportViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DesignGrid.spacing(4)) {
                header
                reportContents
                exportSection
            }
            .padding(DesignGrid.contentMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.palette.background.color.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
            Text("Diagnostics")
                .font(DesignTypography.display)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)
                .accessibilityAddTraits(.isHeader)

            Text(
                "Everything here is redacted before it leaves this Apple TV. Credentials, private share paths, query parameters, and IP addresses are removed."
            )
            .font(DesignTypography.body)
            .foregroundStyle(DesignTokens.palette.textSecondary.color)
        }
    }

    private var reportContents: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
            Text("What is included")
                .font(DesignTypography.headline)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)
                .accessibilityAddTraits(.isHeader)

            ForEach(includedItems, id: \.self) { item in
                HStack(alignment: .top, spacing: DesignGrid.spacing(1)) {
                    Text("•")
                        .font(DesignTypography.body)
                        .foregroundStyle(DesignTokens.palette.textTertiary.color)

                    Text(item)
                        .font(DesignTypography.body)
                        .foregroundStyle(DesignTokens.palette.textSecondary.color)
                }
            }
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(2)) {
            HStack(spacing: DesignGrid.spacing(2)) {
                Button {
                    export()
                } label: {
                    Label(
                        "Export Diagnostics",
                        systemImage: "square.and.arrow.up"
                    )
                    .font(DesignTypography.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isExporting)
                .accessibilityHint(
                    "Writes a redacted JSON report to the Files app."
                )

                if viewModel.isExporting {
                    ProgressView()
                }
            }

            Text(viewModel.exportStatus)
                .font(DesignTypography.caption)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.danger.color)
            }

            if let url = viewModel.lastExportURL {
                Text(url.path)
                    .font(DesignTypography.badge)
                    .foregroundStyle(DesignTokens.palette.textTertiary.color)
                    .lineLimit(2)
            }
        }
    }

    private func export() {
        do {
            try viewModel.exportReport()
        } catch {
            // `exportReport` already stored a human-readable message.
        }
    }

    private var includedItems: [String] {
        [
            "App and tvOS versions, plus the Apple TV model.",
            "Capability probe results and recent pipeline plans.",
            "Redacted log entries from this session.",
            "No library titles, file names, server addresses, or credentials."
        ]
    }
}
