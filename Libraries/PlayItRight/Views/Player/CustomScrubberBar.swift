import SwiftUI

/// Focusable scrub bar with chapter markers and a 0.25 s seek debounce
/// (UI-2, doc 06 §2.4).
public struct CustomScrubberBar: View {
    public let viewModel: PlayerOverlayViewModel

    public init(viewModel: PlayerOverlayViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignTokens.palette.textTertiary.color.opacity(0.35))
                        .frame(height: 10)

                    Capsule()
                        .fill(DesignTokens.palette.accent.color)
                        .frame(
                            width: max(0, width * viewModel.progressFraction),
                            height: 10
                        )

                    ForEach(viewModel.chapters) { chapter in
                        let fraction = viewModel.duration > 0
                            ? chapter.time / viewModel.duration
                            : 0
                        Rectangle()
                            .fill(DesignTokens.palette.textPrimary.color)
                            .frame(width: 3, height: 20)
                            .offset(x: max(0, width * fraction - 1.5))
                            .accessibilityLabel(chapter.title)
                    }

                    Circle()
                        .fill(DesignTokens.palette.textPrimary.color)
                        .frame(width: 24, height: 24)
                        .offset(
                            x: max(0, width * viewModel.progressFraction - 12)
                        )
                }
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .frame(height: 24)

            HStack {
                Text(timeLabel(viewModel.position))
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
                    .monospacedDigit()

                Spacer()

                if let chapter = viewModel.currentChapter {
                    Text(chapter.title)
                        .font(DesignTypography.caption)
                        .foregroundStyle(DesignTokens.palette.textSecondary.color)
                }

                Spacer()

                Text(timeLabel(viewModel.duration))
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
                    .monospacedDigit()
            }
        }
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left:
                viewModel.skip(by: -10)
            case .right:
                viewModel.skip(by: 10)
            default:
                break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(timeLabel(viewModel.position))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                viewModel.skip(by: 10)
            case .decrement:
                viewModel.skip(by: -10)
            @unknown default:
                break
            }
        }
    }

    private func timeLabel(_ time: TimeInterval) -> String {
        let total = max(0, Int(time.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
