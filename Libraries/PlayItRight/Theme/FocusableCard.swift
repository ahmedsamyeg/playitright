import SwiftUI

/// Accessibility traits applied to focusable cards.
public struct FocusAccessibilityTraits: OptionSet, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let isButton = FocusAccessibilityTraits(rawValue: 1 << 0)
    public static let isHeader = FocusAccessibilityTraits(rawValue: 1 << 1)
    public static let isImage = FocusAccessibilityTraits(rawValue: 1 << 2)
}

/// The VoiceOver metadata for a focusable card.
///
/// Kept separate from the SwiftUI view so labels and hints can be asserted in
/// unit tests without a hosted view hierarchy.
public struct FocusableCardAccessibility: Sendable, Equatable {
    public var label: String
    public var hint: String
    public var traits: FocusAccessibilityTraits

    public init(
        label: String,
        hint: String,
        traits: FocusAccessibilityTraits = [.isButton]
    ) {
        self.label = label
        self.hint = hint
        self.traits = traits
    }

    /// Builds the label from the card's visible title and subtitle.
    public init(
        title: String,
        subtitle: String? = nil,
        hint: String? = nil,
        traits: FocusAccessibilityTraits = [.isButton]
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSubtitle = subtitle?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.label = trimmedSubtitle.isEmpty
            ? trimmedTitle
            : "\(trimmedTitle), \(trimmedSubtitle)"
        self.hint = hint ?? "Double-click to open \(trimmedTitle)."
        self.traits = traits
    }
}

/// A tvOS focusable card that applies the shared focus scale, parallax,
/// high-contrast ring, and VoiceOver metadata (UI-1, UI-4, UI-7).
///
/// Standard motion grows the card to 1.06× with a subtle parallax drift.
/// Reduce Motion replaces the drift with a highlight crossfade.
public struct FocusableCard<Content: View>: View {
    public let accessibility: FocusableCardAccessibility
    public let action: () -> Void
    public let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var isFocused: Bool

    public init(
        title: String,
        subtitle: String? = nil,
        hint: String? = nil,
        accessibilityTraits: FocusAccessibilityTraits = [.isButton],
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accessibility = FocusableCardAccessibility(
            title: title,
            subtitle: subtitle,
            hint: hint,
            traits: accessibilityTraits
        )
        self.action = action
        self.content = content
    }

    public init(
        accessibility: FocusableCardAccessibility,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accessibility = accessibility
        self.action = action
        self.content = content
    }

    public var body: some View {
        let palette = DesignTokens.palette(highContrast: contrast == .increased)
        let effect = FocusEffect.resolve(
            reduceMotion: reduceMotion,
            isFocused: isFocused
        )
        let borderWidth = contrast == .increased
            ? DesignTokens.Focus.highContrastBorderWidth
            : DesignTokens.Focus.borderWidth

        Button(action: action) {
            content()
                .background(palette.surface.color)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: DesignTokens.Focus.cornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: DesignTokens.Focus.cornerRadius,
                        style: .continuous
                    )
                    .stroke(
                        palette.focusRing.color,
                        lineWidth: borderWidth
                    )
                    .opacity(isFocused ? 1 : 0)
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: DesignTokens.Focus.cornerRadius,
                        style: .continuous
                    )
                    .fill(palette.focusRing.color.opacity(0.08))
                    .opacity(effect.overlayOpacity)
                }
                .scaleEffect(effect.scale)
                .offset(
                    x: effect.parallaxOffset,
                    y: effect.parallaxOffset
                )
                .shadow(
                    color: .black.opacity(isFocused ? 0.55 : 0),
                    radius: DesignTokens.Focus.shadowRadius,
                    y: DesignTokens.Focus.parallaxOffset
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .animation(effect.animation, value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibility.label))
        .accessibilityHint(Text(accessibility.hint))
        .accessibilityAddTraits(accessibility.swiftUITraits)
    }
}

extension FocusableCardAccessibility {
    var swiftUITraits: AccessibilityTraits {
        var result: AccessibilityTraits = []
        if traits.contains(.isButton) {
            result.insert(.isButton)
        }
        if traits.contains(.isHeader) {
            result.insert(.isHeader)
        }
        if traits.contains(.isImage) {
            result.insert(.isImage)
        }
        return result
    }
}
