import SwiftUI

/// "About This Apple TV": a visual, plain-language hardware capability sheet
/// backed by the active `CapabilityRegistry` (UI-3, doc 06 §2.5).
public struct CapabilitySheetView: View {
    public let viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DesignGrid.spacing(3)) {
                header

                VStack(spacing: DesignGrid.spacing(1)) {
                    ForEach(viewModel.capabilityFacts) { fact in
                        factRow(fact)
                    }
                }
            }
            .padding(DesignGrid.contentMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.palette.background.color)
    }

    private var header: some View {
        HStack(spacing: DesignGrid.spacing(2)) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(DesignTokens.palette.accent.color)

            VStack(alignment: .leading, spacing: 4) {
                Text("About This Apple TV")
                    .font(DesignTypography.title1)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)

                Text("What this device can play, and why.")
                    .font(DesignTypography.body)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func factRow(_ fact: CapabilityFact) -> some View {
        HStack(alignment: .top, spacing: DesignGrid.spacing(2)) {
            Text(fact.title)
                .font(DesignTypography.headline)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)
                .frame(width: 320, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(fact.value)
                    .font(DesignTypography.headline)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)

                Text(fact.explanation)
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textTertiary.color)
            }

            Spacer(minLength: 0)
        }
        .padding(DesignGrid.spacing(2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.palette.surfaceElevated.color.opacity(0.7))
        .clipShape(
            RoundedRectangle(
                cornerRadius: DesignTokens.Focus.cornerRadius,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fact.title): \(fact.value). \(fact.explanation)")
    }
}
