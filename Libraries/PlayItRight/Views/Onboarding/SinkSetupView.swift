import PlaybackKit
import SourceAdapters
import SwiftUI

/// The three sink questions: display, audio, and source type (UI-1, doc 06 §2.1).
public struct SinkSetupView: View {
    @Bindable private var viewModel: OnboardingViewModel

    public init(viewModel: OnboardingViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignGrid.spacing(4)) {
                header
                question
                navigation
            }
            .padding(.horizontal, DesignGrid.contentMargin)
            .padding(.vertical, DesignGrid.spacing(4))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
            Text("Question \(viewModel.stepNumber) of \(viewModel.totalQuestions)")
                .font(DesignTypography.caption)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)

            Text(viewModel.stepTitle)
                .font(DesignTypography.display)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)
        }
    }

    @ViewBuilder
    private var question: some View {
        switch viewModel.step {
        case .display:
            choiceRow {
                ForEach(OnboardingViewModel.displayChoices, id: \.self) { choice in
                    ChoiceCard(
                        title: choice.displayName,
                        subtitle: subtitle(for: choice),
                        systemImage: symbol(for: choice),
                        isSelected: viewModel.display == choice
                    ) {
                        viewModel.selectDisplay(choice)
                    }
                }
            }
        case .audio:
            choiceRow {
                ForEach(OnboardingViewModel.audioChoices, id: \.self) { choice in
                    ChoiceCard(
                        title: choice.displayName,
                        subtitle: audioSubtitle(for: choice),
                        systemImage: audioSymbol(for: choice),
                        isSelected: viewModel.audio == choice
                    ) {
                        viewModel.selectAudio(choice)
                    }
                }
            }
        case .sourceType:
            choiceRow {
                ForEach(OnboardingViewModel.sourceChoices, id: \.self) { kind in
                    ChoiceCard(
                        title: sourceName(for: kind),
                        subtitle: "Connect over the network",
                        systemImage: sourceSymbol(for: kind),
                        isSelected: viewModel.sourceKind == kind
                    ) {
                        viewModel.selectSourceKind(kind)
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private func choiceRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 300), spacing: DesignGrid.gutter)
            ],
            alignment: .leading,
            spacing: DesignGrid.gutter
        ) {
            content()
        }
        .padding(.top, DesignGrid.spacing(2))
    }

    private var navigation: some View {
        HStack(spacing: DesignGrid.spacing(2)) {
            if viewModel.step != .display {
                Button("Back") {
                    viewModel.goBack()
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button("Continue") {
                _ = viewModel.advance()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canAdvance)
        }
        .padding(.top, DesignGrid.spacing(2))
    }

    private func subtitle(for display: DisplayOverride) -> String {
        switch display {
        case .sdr:
            return "Standard dynamic range"
        case .hdr10:
            return "HDR10 or HDR10+"
        case .hlg:
            return "Broadcast HDR"
        case .dolbyVision:
            return "Dolby Vision with HDR10 fallback"
        }
    }

    private func symbol(for display: DisplayOverride) -> String {
        switch display {
        case .sdr:
            return "sun.max"
        case .hdr10:
            return "hdr"
        case .hlg:
            return "antenna.radiowaves.left.and.right"
        case .dolbyVision:
            return "sparkles.tv"
        }
    }

    private func audioSubtitle(for audio: AudioSetup) -> String {
        switch audio {
        case .stereo:
            return "Two channels, no receiver"
        case .receiverAC3:
            return "5.1 surround through a receiver"
        case .receiverAtmos:
            return "Dolby Atmos through a receiver"
        case .homePod:
            return "HomePod or HomePod mini"
        case .speakers:
            return "Built-in TV speakers"
        case .headphones:
            return "Headphones"
        }
    }

    private func audioSymbol(for audio: AudioSetup) -> String {
        switch audio {
        case .stereo:
            return "speaker.wave.2"
        case .receiverAC3:
            return "hifispeaker.2"
        case .receiverAtmos:
            return "hifispeaker.and.homepod"
        case .homePod:
            return "homepod"
        case .speakers:
            return "tv"
        case .headphones:
            return "headphones"
        }
    }

    private func sourceName(for kind: SourceAdapters.SourceKind) -> String {
        switch kind {
        case .plex:
            return "Plex"
        case .jellyfin:
            return "Jellyfin"
        case .emby:
            return "Emby"
        case .smb:
            return "SMB Share"
        case .nfs:
            return "NFS Share"
        case .webdav:
            return "WebDAV"
        case .local:
            return "Local Folder"
        default:
            return kind.rawValue.capitalized
        }
    }

    private func sourceSymbol(for kind: SourceAdapters.SourceKind) -> String {
        switch kind {
        case .plex, .jellyfin, .emby:
            return "server.rack"
        case .smb, .nfs:
            return "externaldrive.connected.to.line.below"
        case .webdav:
            return "cloud"
        case .local:
            return "folder"
        default:
            return "network"
        }
    }
}

/// A large, focusable answer card.
private struct ChoiceCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        FocusableCard(
            title: title,
            subtitle: subtitle,
            hint: "Selects \(title).",
            action: action
        ) {
            VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.system(size: 44, weight: .semibold))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 30, weight: .semibold))
                    }
                }

                Spacer(minLength: 0)

                Text(title)
                    .font(DesignTypography.title2)
                    .lineLimit(1)

                Text(subtitle)
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
                    .lineLimit(2)
            }
            .padding(DesignGrid.spacing(2))
            .frame(width: 320, height: 190, alignment: .leading)
            .foregroundStyle(DesignTokens.palette.textPrimary.color)
        }
    }
}
