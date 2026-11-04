import PlaybackKit
import SwiftUI

/// Modal explanation of the actual playback pipeline: decoding, color,
/// audio, thermal state, planner reasons, and the path lock action
/// (PRD-D1, PB-5, UI-3, doc 01 §2, doc 06 §2.4).
public struct PipelineDetailSheet: View {
    public let viewModel: PipelineDetailSheetViewModel

    public init(viewModel: PipelineDetailSheetViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DesignGrid.spacing(4)) {
                header
                thermalWarning
                sections
                reasons
                lockAction
            }
            .padding(DesignGrid.contentMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.palette.background.color)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
            HStack(spacing: DesignGrid.spacing(1)) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 16, height: 16)

                Text(viewModel.label)
                    .font(DesignTypography.title2)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
            }

            Text(viewModel.summary)
                .font(DesignTypography.body)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)

            if !viewModel.badge.technicalSummary.isEmpty {
                Text(viewModel.badge.technicalSummary)
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textTertiary.color)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var thermalWarning: some View {
        if let warning = viewModel.thermalWarning {
            HStack(alignment: .top, spacing: DesignGrid.spacing(1)) {
                Image(systemName: "thermometer.high")
                    .font(DesignTypography.headline)
                    .foregroundStyle(DesignTokens.palette.warning.color)

                Text(warning)
                    .font(DesignTypography.body)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
            }
            .padding(DesignGrid.spacing(2))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.palette.surfaceElevated.color)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DesignTokens.Focus.cornerRadius,
                    style: .continuous
                )
            )
            .accessibilityElement(children: .combine)
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(3)) {
            ForEach(viewModel.sections) { section in
                VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
                    Text(section.title)
                        .font(DesignTypography.headline)
                        .foregroundStyle(DesignTokens.palette.textPrimary.color)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                }
            }
        }
    }

    private func rowView(_ row: PipelineDetailRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(DesignTypography.callout)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
                    .frame(width: 240, alignment: .leading)

                Text(row.value)
                    .font(DesignTypography.callout)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
            }

            if let explanation = row.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textTertiary.color)
                    .padding(.leading, DesignGrid.spacing(1))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var reasons: some View {
        if !viewModel.reasons.isEmpty {
            VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
                Text("Why this path")
                    .font(DesignTypography.headline)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
                    .accessibilityAddTraits(.isHeader)

                ForEach(Array(viewModel.reasons.enumerated()), id: \.offset) { _, reason in
                    HStack(alignment: .top, spacing: DesignGrid.spacing(1)) {
                        Text("•")
                            .font(DesignTypography.body)
                            .foregroundStyle(DesignTokens.palette.textTertiary.color)

                        Text(reason)
                            .font(DesignTypography.body)
                            .foregroundStyle(DesignTokens.palette.textSecondary.color)
                    }
                }
            }
        }
    }

    private var lockAction: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
            if let sourceId = viewModel.sourceId {
                Text("Scope: source \(sourceId)\(viewModel.codec.map { " · \($0.uppercased())" } ?? "")")
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textTertiary.color)
            }

            Button {
                if viewModel.isPathLocked {
                    viewModel.unlockPath()
                } else {
                    viewModel.lockPath()
                }
            } label: {
                Label(
                    viewModel.lockActionTitle,
                    systemImage: viewModel.isPathLocked ? "lock.fill" : "lock.open"
                )
                .font(DesignTypography.headline)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(
                viewModel.isPathLocked
                    ? "Allows the planner to pick a higher-quality path again."
                    : "Caps future playback for this source and codec at this path."
            )
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
