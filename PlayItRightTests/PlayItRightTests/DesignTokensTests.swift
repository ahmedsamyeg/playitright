import SwiftUI
import Testing
@testable import PlayItRight

@MainActor
@Suite("DesignTokens Tests")
struct DesignTokensTests {
    // MARK: - Contrast

    @Test("Dark-mode text and accents meet WCAG AA contrast")
    func darkPaletteContrast() {
        let palette = DesignPalette.dark
        let background = palette.background

        let pairs: [(String, DesignColor)] = [
            ("primary text", palette.textPrimary),
            ("secondary text", palette.textSecondary),
            ("tertiary text", palette.textTertiary),
            ("accent", palette.accent),
            ("success", palette.success),
            ("warning", palette.warning),
            ("danger", palette.danger),
            ("focus ring", palette.focusRing)
        ]

        for (name, color) in pairs {
            let ratio = color.contrastRatio(against: background)
            #expect(ratio >= 4.5, "\(name) contrast is \(ratio):1")
        }
    }

    @Test("Text also meets WCAG AA on raised surfaces")
    func surfaceContrast() {
        let palette = DesignPalette.dark
        #expect(palette.textPrimary.contrastRatio(against: palette.surface) >= 4.5)
        #expect(palette.textSecondary.contrastRatio(against: palette.surface) >= 4.5)
        #expect(
            palette.textPrimary.contrastRatio(against: palette.surfaceElevated) >= 4.5
        )
    }

    @Test("High-contrast palette reaches AAA for primary text")
    func highContrastPalette() {
        let palette = DesignPalette.highContrast
        #expect(palette.background == DesignColor(hex: 0x000000))
        #expect(palette.textPrimary.contrastRatio(against: palette.background) >= 7)
        #expect(palette.textSecondary.contrastRatio(against: palette.background) >= 7)
        #expect(palette.accent.contrastRatio(against: palette.background) >= 7)
    }

    @Test("Contrast ratios are symmetric and bounded")
    func contrastRatioMath() {
        let white = DesignColor(hex: 0xFFFFFF)
        let black = DesignColor(hex: 0x000000)
        #expect(abs(white.contrastRatio(against: black) - 21) < 0.01)
        #expect(
            abs(
                white.contrastRatio(against: black)
                    - black.contrastRatio(against: white)
            ) < 0.000_1
        )
        #expect(white.contrastRatio(against: white) == 1)
    }

    @Test("The palette resolver picks the high-contrast variant")
    func paletteResolver() {
        #expect(DesignTokens.palette(highContrast: false) == .dark)
        #expect(DesignTokens.palette(highContrast: true) == .highContrast)
    }

    // MARK: - Grid and type

    @Test("Layout sits on a 12-point grid")
    func gridSpacing() {
        #expect(DesignGrid.unit == 12)
        #expect(DesignGrid.spacing(1) == 12)
        #expect(DesignGrid.spacing(3) == 36)
        #expect(DesignGrid.spacing(-2) == -24)
        #expect(DesignGrid.contentMargin.truncatingRemainder(dividingBy: 12) == 0)
        #expect(DesignGrid.gutter.truncatingRemainder(dividingBy: 12) == 0)
    }

    @Test("Type scale decreases from hero to badge")
    func typeScale() {
        let sizes = [
            DesignTypography.Size.hero,
            DesignTypography.Size.display,
            DesignTypography.Size.title1,
            DesignTypography.Size.title2,
            DesignTypography.Size.headline,
            DesignTypography.Size.body,
            DesignTypography.Size.callout,
            DesignTypography.Size.caption,
            DesignTypography.Size.badge
        ]

        #expect(sizes == sizes.sorted(by: >))
        #expect(DesignTypography.Size.body >= 24)
        #expect(DesignTypography.Size.caption >= 18)
    }

    // MARK: - Focus

    @Test("Focused cards scale to 1.06x with parallax")
    func standardFocusEffect() {
        let effect = FocusEffect.resolve(
            reduceMotion: false,
            isFocused: true
        )

        #expect(effect.scale == 1.06)
        #expect(effect.parallaxOffset == 4)
        #expect(effect.overlayOpacity == 1)
        #expect(!effect.usesCrossfade)
        #expect(effect.animationDuration == DesignTokens.Motion.focusDuration)
    }

    @Test("Unfocused cards rest at 1x with no overlay")
    func restingFocusEffect() {
        let effect = FocusEffect.resolve(
            reduceMotion: false,
            isFocused: false
        )

        #expect(effect.scale == 1)
        #expect(effect.parallaxOffset == 0)
        #expect(effect.overlayOpacity == 0)
    }

    @Test("Reduce Motion keeps focus scaling but swaps parallax for a crossfade")
    func reduceMotionFocusEffect() {
        let effect = FocusEffect.resolve(
            reduceMotion: true,
            isFocused: true
        )

        #expect(effect.scale == 1.06)
        #expect(effect.parallaxOffset == 0)
        #expect(effect.overlayOpacity == 1)
        #expect(effect.usesCrossfade)
        #expect(
            effect.animationDuration == DesignTokens.Motion.reduceMotionDuration
        )
    }

    // MARK: - Accessibility metadata

    @Test("A focus card combines title and subtitle in its accessibility label")
    func cardAccessibilityLabel() {
        let accessibility = FocusableCardAccessibility(
            title: "Blade Runner 2049",
            subtitle: "Movie · 4K HDR"
        )

        #expect(accessibility.label == "Blade Runner 2049, Movie · 4K HDR")
        #expect(accessibility.hint == "Double-click to open Blade Runner 2049.")
        #expect(accessibility.traits.contains(.isButton))
    }

    @Test("A focus card supports custom hints and headers")
    func customCardAccessibility() {
        let accessibility = FocusableCardAccessibility(
            title: "Continue Watching",
            subtitle: nil,
            hint: "Shows items you have started.",
            traits: [.isHeader]
        )

        #expect(accessibility.label == "Continue Watching")
        #expect(accessibility.hint == "Shows items you have started.")
        #expect(accessibility.traits.contains(.isHeader))
        #expect(!accessibility.traits.contains(.isButton))
    }

    @Test("Empty subtitles are omitted and whitespace is trimmed")
    func accessibilityTrimming() {
        let accessibility = FocusableCardAccessibility(
            title: "  The Bear  ",
            subtitle: "   "
        )

        #expect(accessibility.label == "The Bear")
        #expect(accessibility.hint == "Double-click to open The Bear.")
    }

    @Test("SwiftUI traits mirror the card metadata")
    func swiftUITraits() {
        let button = FocusableCardAccessibility(
            title: "Play",
            subtitle: nil,
            traits: [.isButton, .isImage]
        )
        #expect(button.swiftUITraits.contains(.isButton))
        #expect(button.swiftUITraits.contains(.isImage))
        #expect(!button.swiftUITraits.contains(.isHeader))

        let header = FocusableCardAccessibility(
            title: "Recently Added",
            subtitle: nil,
            traits: [.isHeader]
        )
        #expect(header.swiftUITraits.contains(.isHeader))
        #expect(!header.swiftUITraits.contains(.isButton))
    }
}
