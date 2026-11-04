import LibraryCore
import SwiftUI

/// Manages configured media sources, including removal and adding a new one
/// (UI-3, doc 06 §2.5).
public struct SourceManagementView: View {
    public let viewModel: SettingsViewModel
    public let onAddSource: () -> Void

    @State private var errorMessage: String?

    public init(
        viewModel: SettingsViewModel,
        onAddSource: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onAddSource = onAddSource
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(3)) {
            HStack {
                Text("Sources")
                    .font(DesignTypography.title2)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Button(action: onAddSource) {
                    Label("Add Source", systemImage: "plus")
                        .font(DesignTypography.callout)
                }
                .buttonStyle(.borderedProminent)
            }

            if viewModel.sources.isEmpty {
                Text("No sources connected.")
                    .font(DesignTypography.body)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
            } else {
                VStack(spacing: DesignGrid.spacing(1)) {
                    ForEach(viewModel.sources) { source in
                        sourceRow(source)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.danger.color)
            }
        }
    }

    private func sourceRow(_ source: SourceRecord) -> some View {
        HStack(spacing: DesignGrid.spacing(2)) {
            Image(systemName: iconName(for: source.kind))
                .font(DesignTypography.title2)
                .foregroundStyle(DesignTokens.palette.accent.color)
                .frame(width: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(DesignTypography.headline)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)

                Text("\(source.kind.rawValue.capitalized) · \(statusText(source))")
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
            }

            Spacer()

            Button(role: .destructive) {
                Task { await remove(source) }
            } label: {
                Label("Remove", systemImage: "trash")
                    .font(DesignTypography.callout)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Remove \(source.name)")
        }
        .padding(DesignGrid.spacing(2))
        .background(DesignTokens.palette.surfaceElevated.color)
        .clipShape(
            RoundedRectangle(
                cornerRadius: DesignTokens.Focus.cornerRadius,
                style: .continuous
            )
        )
    }

    private func remove(_ source: SourceRecord) async {
        do {
            try await viewModel.removeSource(source)
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func statusText(_ source: SourceRecord) -> String {
        if let error = source.lastError, !error.isEmpty {
            return "Needs attention"
        }
        switch source.status {
        case .ok:
            return "Ready"
        case .unreachable:
            return "Unreachable"
        case .authFailed:
            return "Sign-in needed"
        case .disabled:
            return "Disabled"
        }
    }

    private func iconName(for kind: SourceKind) -> String {
        switch kind {
        case .local:
            return "externaldrive"
        case .plex:
            return "play.rectangle"
        case .jellyfin, .emby, .upnp:
            return "server.rack"
        case .smb, .nfs, .webdav, .ftp, .ftps, .sftp, .http:
            return "network"
        case .gdrive, .dropbox, .onedrive, .box:
            return "cloud"
        }
    }
}
