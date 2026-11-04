import PlaybackKit
import SourceAdapters
import SwiftUI

/// The first-launch flow: three setup questions, the first source connection,
/// and a progress-backed handoff to the library (UI-1, doc 06 §2.1).
public struct OnboardingView: View {
    @State private var viewModel: OnboardingViewModel
    private let onFinished: (SourceConfig?) -> Void

    public init(
        viewModel: OnboardingViewModel,
        onFinished: @escaping (SourceConfig?) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onFinished = onFinished
    }

    public var body: some View {
        ZStack {
            DesignTokens.palette.background.color
                .ignoresSafeArea()

            switch viewModel.step {
            case .display, .audio, .sourceType:
                SinkSetupView(viewModel: viewModel)
                    .transition(.opacity)

            case .sourceSetup:
                InitialSourceView(viewModel: viewModel)
                    .transition(.opacity)

            case .complete:
                completion
                    .transition(.opacity)
            }
        }
        .animation(
            .easeInOut(duration: DesignTokens.Motion.overlayDuration),
            value: viewModel.step
        )
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(3)) {
            Text("You're ready to watch")
                .font(DesignTypography.hero)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)

            Text(viewModel.progressSummary)
                .font(DesignTypography.title2)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)

            if let source = viewModel.savedSourceConfig {
                HStack(spacing: DesignGrid.spacing(3)) {
                    summary(
                        title: source.name,
                        detail: source.kind.rawValue.capitalized
                    )
                    summary(
                        title: "\(viewModel.discoveredItemCount)",
                        detail: "items found"
                    )
                    summary(
                        title: "\(viewModel.indexedFileCount)",
                        detail: "files indexed"
                    )
                }
            }

            Spacer()

            Button("Start Watching") {
                onFinished(viewModel.savedSourceConfig)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.connectionState.isFailure)
            .accessibilityHint("Opens your library with the first items found.")
        }
        .padding(.horizontal, DesignGrid.contentMargin)
        .padding(.vertical, DesignGrid.spacing(4))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DesignTypography.title2)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)
                .lineLimit(1)
            Text(detail)
                .font(DesignTypography.caption)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)
        }
        .padding(DesignGrid.spacing(2))
        .frame(minWidth: 260, alignment: .leading)
        .background(DesignTokens.palette.surface.color)
        .clipShape(
            RoundedRectangle(
                cornerRadius: DesignTokens.Focus.cornerRadius,
                style: .continuous
            )
        )
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
