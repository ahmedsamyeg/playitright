import CapKit
import LibraryCore
import PlaybackKit
import SwiftUI

/// The tvOS Settings screen: sources, playback preferences, library cache,
/// privacy/diagnostics, and the hardware capability sheet
/// (UI-3, doc 06 §2.5).
public struct SettingsView: View {
    public let viewModel: SettingsViewModel
    public let onAddSource: () -> Void
    public let onExportDiagnostics: () -> Void
    public let diagnosticsViewModel: DiagnosticsExportViewModel?

    @State private var isShowingCapabilities = false
    @State private var isShowingDiagnostics = false
    @State private var errorMessage: String?

    public init(
        viewModel: SettingsViewModel,
        diagnosticsViewModel: DiagnosticsExportViewModel? = nil,
        onAddSource: @escaping () -> Void = {},
        onExportDiagnostics: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.diagnosticsViewModel = diagnosticsViewModel
        self.onAddSource = onAddSource
        self.onExportDiagnostics = onExportDiagnostics
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DesignGrid.spacing(4)) {
                Text("Settings")
                    .font(DesignTypography.display)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
                    .accessibilityAddTraits(.isHeader)

                SourceManagementView(
                    viewModel: viewModel,
                    onAddSource: onAddSource
                )

                playbackSection
                librarySection
                privacySection
                aboutSection

                if let errorMessage {
                    Text(errorMessage)
                        .font(DesignTypography.caption)
                        .foregroundStyle(DesignTokens.palette.danger.color)
                }
            }
            .padding(DesignGrid.contentMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.palette.background.color.ignoresSafeArea())
        .task {
            if viewModel.state == .idle {
                await viewModel.load()
            }
        }
        .sheet(isPresented: $isShowingCapabilities) {
            CapabilitySheetView(viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            if let diagnosticsViewModel {
                DiagnosticsExportView(viewModel: diagnosticsViewModel)
            }
        }
    }

    private var playbackSection: some View {
        settingsSection("Playback") {
            settingsRow(
                title: "Display profile",
                detail: viewModel.displayProfileName
            ) {
                Menu {
                    Button("Automatic") {
                        viewModel.displayOverride = nil
                    }
                    ForEach(DisplayOverride.allCases, id: \.self) { option in
                        Button(option.displayName) {
                            viewModel.displayOverride = option
                        }
                    }
                } label: {
                    Text("Change")
                        .font(DesignTypography.callout)
                }
            }

            settingsRow(
                title: "Audio setup",
                detail: viewModel.audioSetupName
            ) {
                Menu {
                    Button("Automatic") {
                        viewModel.audioSetup = nil
                    }
                    ForEach(AudioSetup.allCases, id: \.self) { option in
                        Button(option.displayName) {
                            viewModel.audioSetup = option
                        }
                    }
                } label: {
                    Text("Change")
                        .font(DesignTypography.callout)
                }
            }

            settingsRow(
                title: "Quality bias",
                detail: qualityBiasName
            ) {
                Menu {
                    ForEach(
                        PlaybackPreferences.QualityBias.allCases,
                        id: \.self
                    ) { bias in
                        Button(qualityBiasName(bias)) {
                            viewModel.qualityBias = bias
                        }
                    }
                } label: {
                    Text("Change")
                        .font(DesignTypography.callout)
                }
            }

            settingsRow(
                title: "Color handling",
                detail: colorModeName
            ) {
                Menu {
                    ForEach(
                        PlaybackPreferences.ColorMode.allCases,
                        id: \.self
                    ) { mode in
                        Button(colorModeName(mode)) {
                            viewModel.colorMode = mode
                        }
                    }
                } label: {
                    Text("Change")
                        .font(DesignTypography.callout)
                }
            }
        }
    }

    private var librarySection: some View {
        settingsSection("Library") {
            settingsRow(
                title: "Artwork cache",
                detail: viewModel.cacheUsageLabel
            ) {
                VStack(spacing: DesignGrid.spacing(1)) {
                    Menu {
                        ForEach(cacheLimitChoices, id: \.bytes) { choice in
                            Button(choice.label) {
                                Task {
                                    await viewModel.setArtworkCacheLimit(choice.bytes)
                                }
                            }
                        }
                    } label: {
                        Text("Limit")
                            .font(DesignTypography.callout)
                    }

                    Button("Clear Cache") {
                        Task {
                            do {
                                try await viewModel.clearArtworkCache()
                            } catch {
                                errorMessage = (error as? LocalizedError)?.errorDescription
                                    ?? error.localizedDescription
                            }
                        }
                    }
                    .font(DesignTypography.callout)
                    .disabled(viewModel.isClearingCache)
                    .accessibilityHint("Removes every cached poster and backdrop.")
                }
            }

            settingsRow(
                title: "Rescan library",
                detail: viewModel.lastRescanAt == nil
                    ? "Not run from Settings"
                    : "Started just now"
            ) {
                Button("Rescan") {
                    viewModel.rescanLibrary()
                }
                .font(DesignTypography.callout)
            }
        }
    }

    private var privacySection: some View {
        settingsSection("Privacy & Diagnostics") {
            settingsRow(
                title: "Diagnostics",
                detail: "Redacted logs and playback metadata"
            ) {
                Button("Export") {
                    if diagnosticsViewModel != nil {
                        isShowingDiagnostics = true
                    } else {
                        onExportDiagnostics()
                    }
                }
                .font(DesignTypography.callout)
            }

            settingsRow(
                title: "Analytics",
                detail: "Off — no playback data leaves this Apple TV"
            ) { EmptyView() }

            settingsRow(
                title: "Network",
                detail: "Credentials stay in the Keychain"
            ) { EmptyView() }
        }
    }

    private var aboutSection: some View {
        settingsSection("About") {
            settingsRow(
                title: "About This Apple TV",
                detail: viewModel.capabilityRegistry.profile.displayName
            ) {
                Button("View Capabilities") {
                    isShowingCapabilities = true
                }
                .font(DesignTypography.callout)
            }
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
            Text(title)
                .font(DesignTypography.title2)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                content()
            }
            .background(DesignTokens.palette.surfaceElevated.color.opacity(0.7))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DesignTokens.Focus.cornerRadius,
                    style: .continuous
                )
            )
        }
    }

    private func settingsRow<Accessory: View>(
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: DesignGrid.spacing(2)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(DesignTypography.headline)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)

                Text(detail)
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
            }

            Spacer()

            accessory()
        }
        .padding(DesignGrid.spacing(2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.3)
        }
    }

    private var qualityBiasName: String {
        qualityBiasName(viewModel.qualityBias)
    }

    private func qualityBiasName(
        _ bias: PlaybackPreferences.QualityBias
    ) -> String {
        switch bias {
        case .bestQuality:
            return "Best quality"
        case .balanced:
            return "Balanced"
        case .lowestCPU:
            return "Lowest CPU"
        }
    }

    private var colorModeName: String {
        colorModeName(viewModel.colorMode)
    }

    private func colorModeName(
        _ mode: PlaybackPreferences.ColorMode
    ) -> String {
        switch mode {
        case .system:
            return "System-managed"
        case .precise:
            return "Precise tone-mapping"
        case .off:
            return "Off"
        }
    }

    private var cacheLimitChoices: [(bytes: Int64, label: String)] {
        let gigabyte: Int64 = 1_024 * 1_024 * 1_024
        return [
            (gigabyte / 2, "0.5 GB"),
            (gigabyte, "1 GB"),
            (2 * gigabyte, "2 GB"),
            (5 * gigabyte, "5 GB"),
            (10 * gigabyte, "10 GB")
        ]
    }
}
