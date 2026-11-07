import PlaybackKit
import SwiftUI
import Testing
@testable import PlayItRight

@MainActor
@Suite("AccessibilityAudit Tests")
struct AccessibilityAuditTests {
    // MARK: - Screen contract

    @Test("Every screen has a complete VoiceOver contract")
    func catalogCoverage() {
        let screens = AccessibilityCatalog.screens
        #expect(screens.count == AccessibilityScreen.allCases.count)
        #expect(Set(screens.map(\.screen)) == Set(AccessibilityScreen.allCases))
        #expect(AccessibilityCatalog.issues().isEmpty)
    }

    @Test("Every screen exposes a spoken header and non-empty labels")
    func headersAndLabels() {
        for descriptor in AccessibilityCatalog.screens {
            #expect(!descriptor.title.isEmpty)
            #expect(descriptor.controls.contains { $0.kind == .header })
            for control in descriptor.controls {
                #expect(!control.label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @Test("Buttons and adjustable controls always explain what they do")
    func interactiveControlsHaveHints() {
        for descriptor in AccessibilityCatalog.screens {
            for control in descriptor.controls where control.requiresHint {
                #expect(control.hint?.isEmpty == false, "\(control.id) has no hint")
            }
        }
    }

    @Test("Header, button, image, and adjustable controls map to traits")
    func traitMapping() {
        let header = AccessibilityControl(
            id: "x",
            label: "Title",
            kind: .header
        )
        let button = AccessibilityControl(
            id: "y",
            label: "Play",
            hint: "Starts playback.",
            kind: .button
        )
        let image = AccessibilityControl(
            id: "z",
            label: "Poster",
            kind: .image
        )

        #expect(header.traits.contains(.isHeader))
        #expect(button.traits.contains(.isButton))
        #expect(image.traits.contains(.isImage))
        #expect(!button.traits.contains(.isHeader))
    }

    // MARK: - Contrast and focus

    @Test("High contrast thickens the focus ring and raises contrast")
    func highContrastFocusRing() {
        let standard = AccessibilityVisualPolicy.resolve(highContrast: false)
        let increased = AccessibilityVisualPolicy.resolve(highContrast: true)

        #expect(standard.borderWidth == DesignTokens.Focus.borderWidth)
        #expect(
            increased.borderWidth == DesignTokens.Focus.highContrastBorderWidth
        )
        #expect(increased.borderWidth > standard.borderWidth)
        #expect(standard.focusRingContrast >= 4.5)
        #expect(increased.focusRingContrast >= 7)
        #expect(increased.palette == .highContrast)
    }

    @Test("High-contrast text meets AAA on every surface")
    func highContrastText() {
        let palette = AccessibilityVisualPolicy
            .resolve(highContrast: true)
            .palette
        for surface in [palette.background, palette.surface, palette.surfaceElevated] {
            #expect(palette.textPrimary.contrastRatio(against: surface) >= 7)
            #expect(palette.textSecondary.contrastRatio(against: surface) >= 7)
        }
    }

    // MARK: - Labels

    @Test("Media card labels include badges and progress")
    func mediaCardLabels() {
        let label = AccessibilityLabelBuilder.mediaCard(
            title: "Blade Runner 2049",
            subtitle: "2017 · 8.0",
            badges: ["4K", "Dolby Vision", "Dolby Atmos"],
            isInProgress: true
        )
        #expect(label.contains("Blade Runner 2049"))
        #expect(label.contains("Dolby Vision"))
        #expect(label.contains("Dolby Atmos"))
        #expect(label.contains("In progress"))
    }

    @Test("Technology badges use words rather than raw abbreviations")
    func badgeLabels() {
        #expect(MediaBadge.fourK.accessibilityLabel == "4K")
        #expect(MediaBadge.dolbyVision.accessibilityLabel == "Dolby Vision")
        #expect(MediaBadge.atmos.accessibilityLabel == "Dolby Atmos")

        let spoken = AccessibilityLabelBuilder.techBadges(
            ["4K", "Dolby Vision", "Dolby Atmos"]
        )
        #expect(spoken == "Quality: 4K, Dolby Vision, Dolby Atmos")
    }

    @Test("Playback position is spoken in hours, minutes, and seconds")
    func playbackPosition() {
        #expect(
            AccessibilityLabelBuilder.playbackPosition(
                elapsed: 725,
                duration: 6_120
            ) == "12 minutes 5 seconds of 1 hour 42 minutes"
        )
        #expect(
            AccessibilityLabelBuilder.playbackPosition(
                elapsed: -10,
                duration: 30
            ) == "0 seconds of 30 seconds"
        )
    }

    // MARK: - Closed captions

    @Test("Caption customization clamps scale, opacity, and offset")
    func captionClamping() {
        let customization = ClosedCaptionCustomization(
            fontScale: 9,
            opacity: -1,
            positionOffset: 4,
            backgroundOpacity: 3
        )

        #expect(customization.fontScale == 2)
        #expect(customization.opacity == 0)
        #expect(customization.positionOffset == 0.5)
        #expect(customization.backgroundOpacity == 1)
        #expect(!customization.isForcedOnly)
    }

    @Test("Caption presets feed the renderer with the right look")
    func captionPresets() {
        let standard = ClosedCaptionCustomization()
        #expect(standard.preset == .standard)
        #expect(standard.appearance.fontScale == 1)
        #expect(standard.appearance.color == SubtitleColor.white)

        let large = ClosedCaptionCustomization(preset: .largePrint)
        #expect(large.appearance.fontSize > standard.appearance.fontSize)
        #expect(large.appearance.color == SubtitleColor.white)

        let highContrast = ClosedCaptionCustomization(preset: .highContrast)
        #expect(highContrast.appearance.outlineWidth >= 4)
        #expect(highContrast.appearance.color.red == 1)

        let accessible = ClosedCaptionCustomization.accessibilityLargePrint
        #expect(accessible.fontScale > 1)
        #expect(accessible.opacity == 1)
        #expect(accessible.backgroundOpacity > 0)
    }

    @Test("Caption overrides apply on top of any preset")
    func captionOverrides() {
        let customization = ClosedCaptionCustomization(
            preset: .cinema,
            fontScale: 1.3,
            opacity: 0.8,
            positionOffset: 0.1,
            textColor: SubtitleColor(red: 1, green: 1, blue: 0)
        )
        let appearance = customization.appearance

        #expect(appearance.fontName == "Georgia")
        #expect(appearance.fontScale == 1.3)
        #expect(appearance.opacity == 0.8)
        #expect(appearance.positionOffset == 0.1)
        #expect(appearance.color.blue == 0)
    }

    @Test("Forced-only captions filter the subtitle engine")
    func forcedOnlyCaptions() {
        let document = SubtitleDocument(
            format: .srt,
            cues: [
                SubtitleCue(
                    id: 1,
                    start: 0,
                    end: 1,
                    content: .text("Dialogue")
                ),
                SubtitleCue(
                    id: 2,
                    start: 0,
                    end: 1,
                    content: .text("Sign"),
                    isForced: true
                )
            ]
        )
        let customization = ClosedCaptionCustomization(isForcedOnly: true)
        let engine = SubtitleEngine(
            document: document,
            appearance: customization.appearance,
            isForcedOnly: customization.isForcedOnly
        )

        #expect(engine.cues(at: 0.5).map(\.text) == ["Sign"])
        #expect(engine.appearance == customization.appearance)
    }
}
