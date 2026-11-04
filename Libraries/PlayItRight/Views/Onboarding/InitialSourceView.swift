import PlaybackKit
import SourceAdapters
import SwiftUI

/// Collects the first source's connection details and shows scan progress
/// (UI-1, doc 06 §2.1).
public struct InitialSourceView: View {
    @Bindable private var viewModel: OnboardingViewModel

    public init(viewModel: OnboardingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignGrid.spacing(3)) {
                header
                fields
                connectButton
                progress
            }
            .padding(.horizontal, DesignGrid.contentMargin)
            .padding(.vertical, DesignGrid.spacing(4))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
            Text("Question 3 of 3")
                .font(DesignTypography.caption)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)

            Text("Connect your first source")
                .font(DesignTypography.display)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)

            Text("Your library starts filling in as soon as the first scan begins.")
                .font(DesignTypography.body)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(2)) {
            field(
                title: "Name",
                prompt: "Living Room \(sourceTitle)",
                text: $viewModel.sourceName
            )

            field(
                title: addressTitle,
                prompt: addressPrompt,
                text: $viewModel.sourceAddress
            )

            if viewModel.sourceKind != .local {
                field(
                    title: "Username",
                    prompt: "Optional",
                    text: $viewModel.username
                )

                HStack {
                    Text("Password")
                        .font(DesignTypography.headline)
                        .frame(width: 260, alignment: .leading)
                    SecureField("Stored in the Keychain", text: $viewModel.credential)
                        .textContentType(.password)
                        .font(DesignTypography.body)
                }
            }
        }
        .padding(DesignGrid.spacing(3))
        .background(DesignTokens.palette.surface.color)
        .clipShape(
            RoundedRectangle(
                cornerRadius: DesignTokens.Focus.cornerRadius,
                style: .continuous
            )
        )
    }

    private func field(
        title: String,
        prompt: String,
        text: Binding<String>
    ) -> some View {
        HStack {
            Text(title)
                .font(DesignTypography.headline)
                .frame(width: 260, alignment: .leading)
            TextField(prompt, text: text)
                .font(DesignTypography.body)
                .textContentType(.URL)
        }
    }

    private var connectButton: some View {
        HStack(spacing: DesignGrid.spacing(2)) {
            Button("Back") {
                viewModel.goBack()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(connectButtonTitle) {
                connect()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canConnect || isConnecting)
        }
    }

    @ViewBuilder
    private var progress: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
            if isConnecting {
                ProgressView()
                    .progressViewStyle(.circular)
            }

            Text(viewModel.progressSummary)
                .font(DesignTypography.body)
                .foregroundStyle(
                    viewModel.connectionState.isFailure
                        ? DesignTokens.palette.danger.color
                        : DesignTokens.palette.textSecondary.color
                )

            if viewModel.discoveredItemCount > 0 {
                HStack(spacing: DesignGrid.spacing(3)) {
                    count(
                        value: viewModel.discoveredItemCount,
                        label: "items found"
                    )
                    count(
                        value: viewModel.indexedFileCount,
                        label: "files indexed"
                    )
                }
            }
        }
        .padding(.top, DesignGrid.spacing(1))
    }

    private func count(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(DesignTypography.title2)
                .foregroundStyle(DesignTokens.palette.accent.color)
            Text(label)
                .font(DesignTypography.caption)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)
        }
    }

    private func connect() {
        do {
            try viewModel.connectSource()
        } catch {
            viewModel.failConnection(
                (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            )
        }
    }

    private var isConnecting: Bool {
        viewModel.connectionState == .scanning && viewModel.isCompleted
    }

    private var connectButtonTitle: String {
        viewModel.isCompleted ? "Reconnect" : "Connect and Scan"
    }

    private var sourceTitle: String {
        switch viewModel.sourceKind {
        case .plex:
            return "Plex"
        case .jellyfin:
            return "Jellyfin"
        case .emby:
            return "Emby"
        case .smb:
            return "SMB"
        case .nfs:
            return "NFS"
        case .webdav:
            return "WebDAV"
        case .local:
            return "Folder"
        default:
            return "Source"
        }
    }

    private var addressTitle: String {
        switch viewModel.sourceKind {
        case .plex, .jellyfin, .emby, .webdav:
            return "Server URL"
        case .smb, .nfs:
            return "Host"
        case .local:
            return "Folder Path"
        default:
            return "Address"
        }
    }

    private var addressPrompt: String {
        switch viewModel.sourceKind {
        case .plex, .jellyfin, .emby, .webdav:
            return "https://media.example.com"
        case .smb, .nfs:
            return "192.168.1.20"
        case .local:
            return "/Users/Shared/Movies"
        default:
            return "Address"
        }
    }
}

private extension OnboardingViewModel.ConnectionState {
    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}
