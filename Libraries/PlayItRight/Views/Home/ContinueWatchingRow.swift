import SwiftUI

/// The circular resume-progress indicator used by Continue Watching cards
/// (MD-9, doc 06 §2.2).
public struct ContinueWatchingProgressRing: View {
    public let progress: ContinueWatchingProgress

    public init(progress: ContinueWatchingProgress) {
        self.progress = progress
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(
                    DesignTokens.palette.textTertiary.color.opacity(0.35),
                    lineWidth: 8
                )

            Circle()
                .trim(from: 0, to: progress.fraction)
                .stroke(
                    DesignTokens.palette.accent.color,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Text(progress.label)
                .font(DesignTypography.badge)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)
                .monospacedDigit()
        }
        .frame(width: 84, height: 84)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(progress.percentage) percent watched"))
    }
}

/// A horizontal Continue Watching row with progress rings (MD-9).
public struct ContinueWatchingRow: View {
    public let items: [HomeShelfItem]
    public let onSelect: (HomeShelfItem) -> Void

    public init(
        items: [HomeShelfItem],
        onSelect: @escaping (HomeShelfItem) -> Void
    ) {
        self.items = items
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: DesignGrid.gutter) {
                ForEach(items) { item in
                    ContinueWatchingCardView(item: item) {
                        onSelect(item)
                    }
                }
            }
            .padding(.horizontal, DesignGrid.contentMargin)
            .padding(.vertical, DesignGrid.spacing(1))
        }
        .scrollClipDisabled()
    }
}

private struct ContinueWatchingCardView: View {
    let item: HomeShelfItem
    let action: () -> Void

    var body: some View {
        FocusableCard(
            title: item.title,
            subtitle: item.subtitle,
            hint: resumeHint,
            action: action
        ) {
            ZStack(alignment: .bottomTrailing) {
                posterPlaceholder

                if let progress = item.progress {
                    ContinueWatchingProgressRing(progress: progress)
                        .padding(DesignGrid.spacing(1))
                }
            }
            .frame(
                width: DesignGrid.posterWidth,
                height: DesignGrid.posterHeight
            )
        }
    }

    private var posterPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    DesignTokens.palette.surfaceElevated.color,
                    DesignTokens.palette.surface.color
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(
                    DesignTokens.palette.textTertiary.color.opacity(0.7)
                )
        }
    }

    private var resumeHint: String {
        guard let progress = item.progress else {
            return "Double-click to open \(item.title)."
        }
        return "Double-click to resume \(item.title) at \(progress.label)."
    }
}
