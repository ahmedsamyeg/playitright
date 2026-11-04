import PlaybackKit
import SwiftUI

/// The subtle, dimmable quality badge shown in the top-right corner of the
/// player. Focusing it reveals a hint; selecting it opens the pipeline sheet
/// (PRD-D1, PB-5, UI-3, doc 06 §2.4).
public struct QualityBadgeView: View {
    public let viewModel: PipelineDetailSheetViewModel
    public let isDimmed: Bool

    @FocusState private var isFocused: Bool

    public init(
        viewModel: PipelineDetailSheetViewModel,
        isDimmed: Bool = false
    ) {
        self.viewModel = viewModel
        self.isDimmed = isDimmed
    }

    public var body: some View {
        Button {
            viewModel.presentSheet()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 12, height: 12)

                Text(viewModel.label)
                    .font(DesignTypography.badge)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
                    .monospacedDigit()

                if isFocused {
                    Image(systemName: "info.circle")
                        .font(DesignTypography.caption)
                        .foregroundStyle(DesignTokens.palette.textSecondary.color)
                }
            }
            .padding(.horizontal, DesignGrid.spacing(1))
            .padding(.vertical, 8)
            .background(
                DesignTokens.palette.surfaceElevated.color
                    .opacity(isFocused ? 0.95 : 0.7)
            )
            .overlay(
                Capsule()
                    .stroke(
                        isFocused
                            ? DesignTokens.palette.focusRing.color
                            : .clear,
                        lineWidth: DesignTokens.Focus.borderWidth
                    )
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? DesignTokens.Focus.scale : 1)
        .animation(
            .easeInOut(duration: DesignTokens.Motion.focusDuration),
            value: isFocused
        )
        .opacity(isDimmed && !isFocused ? 0.55 : 1)
        .accessibilityLabel("Playback quality: \(viewModel.label)")
        .accessibilityHint("Opens the pipeline explanation and path lock.")
        .sheet(isPresented: Binding(
            get: { viewModel.isSheetPresented },
            set: { viewModel.isSheetPresented = $0 }
        )) {
            PipelineDetailSheet(viewModel: viewModel)
        }
    }

    private var dotColor: Color {
        switch viewModel.color {
        case .green:
            return DesignTokens.palette.success.color
        case .blue:
            return DesignTokens.palette.accent.color
        case .amber:
            return DesignTokens.palette.warning.color
        case .orange:
            return DesignTokens.palette.danger.color
        case .gray:
            return DesignTokens.palette.textTertiary.color
        }
    }
}
