import SwiftUI

/// The auto-hiding tvOS playback overlay with transport, chapter navigation,
/// track menus, and Siri Remote/keyboard bindings (UI-1, UI-2, doc 06 §2.4).
public struct PlayerOverlayView: View {
    public let viewModel: PlayerOverlayViewModel
    public let title: String
    public let qualityBadgeText: String?

    public init(
        viewModel: PlayerOverlayViewModel,
        title: String,
        qualityBadgeText: String? = nil
    ) {
        self.viewModel = viewModel
        self.title = title
        self.qualityBadgeText = qualityBadgeText
    }

    public var body: some View {
        ZStack {
            if viewModel.isVisible {
                overlay
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isVisible)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                viewModel.tick()
                viewModel.flushSeekIfNeeded()
            }
        }
        .onPlayPauseCommand {
            viewModel.togglePlayback()
        }
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            transportControls
            Spacer(minLength: 0)
            bottomBar
        }
        .padding(DesignGrid.contentMargin)
        .background(
            LinearGradient(
                colors: [
                    .black.opacity(0.8),
                    .clear,
                    .clear,
                    .black.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.interact()
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(DesignTypography.title1)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
                    .lineLimit(1)

                if let chapter = viewModel.currentChapter {
                    Text(chapter.title)
                        .font(DesignTypography.caption)
                        .foregroundStyle(DesignTokens.palette.textSecondary.color)
                }
            }

            Spacer()

            if let qualityBadgeText {
                Text(qualityBadgeText)
                    .font(DesignTypography.badge)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(DesignTokens.palette.surfaceElevated.color.opacity(0.8))
                    .clipShape(Capsule())
            }
        }
    }

    private var transportControls: some View {
        HStack(spacing: DesignGrid.spacing(4)) {
            controlButton(
                systemImage: "backward.end.fill",
                label: "Previous Chapter"
            ) {
                viewModel.previousChapter()
            }

            controlButton(
                systemImage: "gobackward.10",
                label: "Skip Back 10 Seconds"
            ) {
                viewModel.skip(by: -10)
            }

            Button {
                viewModel.togglePlayback()
            } label: {
                Image(
                    systemName: viewModel.isPlaying
                        ? "pause.circle.fill"
                        : "play.circle.fill"
                )
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(DesignTokens.palette.textPrimary.color)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            controlButton(
                systemImage: "goforward.10",
                label: "Skip Forward 10 Seconds"
            ) {
                viewModel.skip(by: 10)
            }

            controlButton(
                systemImage: "forward.end.fill",
                label: "Next Chapter"
            ) {
                viewModel.nextChapter()
            }
        }
    }

    private func controlButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(DesignTokens.palette.textPrimary.color)
                .frame(width: 88, height: 88)
                .background(DesignTokens.palette.surfaceElevated.color.opacity(0.6))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var bottomBar: some View {
        VStack(spacing: DesignGrid.spacing(2)) {
            CustomScrubberBar(viewModel: viewModel)

            HStack {
                AudioSubtitleMenu(viewModel: viewModel)

                Spacer()

                Text(viewModel.isPlaying ? "Playing" : "Paused")
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
            }
        }
    }
}
