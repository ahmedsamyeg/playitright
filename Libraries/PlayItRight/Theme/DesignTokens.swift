import Foundation
import SwiftUI

/// A concrete sRGB color used by the design system.
///
/// Tokens stay as numeric components so contrast can be verified in unit tests
/// without a running view hierarchy.
public struct DesignColor: Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double = 1
    ) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
        self.alpha = min(1, max(0, alpha))
    }

    /// Creates a color from a `0xRRGGBB` literal.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public var color: Color {
        Color(
            .sRGB,
            red: red,
            green: green,
            blue: blue,
            opacity: alpha
        )
    }

    /// WCAG relative luminance (sRGB, gamma-corrected).
    public var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.040_45
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red)
            + 0.7152 * linear(green)
            + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio against another color, from 1:1 to 21:1.
    public func contrastRatio(against other: DesignColor) -> Double {
        let first = relativeLuminance
        let second = other.relativeLuminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// Semantic surface and text colors for the 10-foot UI.
///
/// The default palette is dark-first and HDR-safe: surfaces stay near-black so
/// bright HDR highlights are never surrounded by glare, while text stays below
/// reference white to avoid clipping on OLED panels.
public struct DesignPalette: Sendable, Equatable {
    public var background: DesignColor
    public var surface: DesignColor
    public var surfaceElevated: DesignColor
    public var textPrimary: DesignColor
    public var textSecondary: DesignColor
    public var textTertiary: DesignColor
    public var accent: DesignColor
    public var focusRing: DesignColor
    public var success: DesignColor
    public var warning: DesignColor
    public var danger: DesignColor

    public init(
        background: DesignColor,
        surface: DesignColor,
        surfaceElevated: DesignColor,
        textPrimary: DesignColor,
        textSecondary: DesignColor,
        textTertiary: DesignColor,
        accent: DesignColor,
        focusRing: DesignColor,
        success: DesignColor,
        warning: DesignColor,
        danger: DesignColor
    ) {
        self.background = background
        self.surface = surface
        self.surfaceElevated = surfaceElevated
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.accent = accent
        self.focusRing = focusRing
        self.success = success
        self.warning = warning
        self.danger = danger
    }

    /// The default dark-first, HDR-safe palette.
    public static let dark = DesignPalette(
        background: DesignColor(hex: 0x0B0B0F),
        surface: DesignColor(hex: 0x16161C),
        surfaceElevated: DesignColor(hex: 0x1F1F28),
        textPrimary: DesignColor(hex: 0xF5F5F7),
        textSecondary: DesignColor(hex: 0xB8B8C2),
        textTertiary: DesignColor(hex: 0x8E8E99),
        accent: DesignColor(hex: 0x5AC8FA),
        focusRing: DesignColor(hex: 0xFFFFFF),
        success: DesignColor(hex: 0x30D158),
        warning: DesignColor(hex: 0xFFD60A),
        danger: DesignColor(hex: 0xFF6961)
    )

    /// A high-contrast variant with pure black surfaces and stronger accents.
    public static let highContrast = DesignPalette(
        background: DesignColor(hex: 0x000000),
        surface: DesignColor(hex: 0x101014),
        surfaceElevated: DesignColor(hex: 0x1C1C22),
        textPrimary: DesignColor(hex: 0xFFFFFF),
        textSecondary: DesignColor(hex: 0xE2E2E8),
        textTertiary: DesignColor(hex: 0xC8C8D0),
        accent: DesignColor(hex: 0x7FDBFF),
        focusRing: DesignColor(hex: 0xFFFFFF),
        success: DesignColor(hex: 0x4DFF7A),
        warning: DesignColor(hex: 0xFFE45C),
        danger: DesignColor(hex: 0xFF8A82)
    )
}

/// Type scale for a 10-foot viewing distance.
public enum DesignTypography {
    public enum Size {
        public static let hero: CGFloat = 96
        public static let display: CGFloat = 76
        public static let title1: CGFloat = 56
        public static let title2: CGFloat = 44
        public static let headline: CGFloat = 34
        public static let body: CGFloat = 28
        public static let callout: CGFloat = 24
        public static let caption: CGFloat = 20
        public static let badge: CGFloat = 18
    }

    public static var hero: Font {
        .system(size: Size.hero, weight: .bold, design: .default)
    }

    public static var display: Font {
        .system(size: Size.display, weight: .bold, design: .default)
    }

    public static var title1: Font {
        .system(size: Size.title1, weight: .semibold, design: .default)
    }

    public static var title2: Font {
        .system(size: Size.title2, weight: .semibold, design: .default)
    }

    public static var headline: Font {
        .system(size: Size.headline, weight: .semibold, design: .default)
    }

    public static var body: Font {
        .system(size: Size.body, weight: .regular, design: .default)
    }

    public static var callout: Font {
        .system(size: Size.callout, weight: .regular, design: .default)
    }

    public static var caption: Font {
        .system(size: Size.caption, weight: .regular, design: .default)
    }

    public static var badge: Font {
        .system(size: Size.badge, weight: .bold, design: .rounded)
    }
}

/// A 12-point grid shared by every 10-foot layout.
public enum DesignGrid {
    /// Base grid unit, in points.
    public static let unit: CGFloat = 12

    /// Safe horizontal content margin for TV overscan.
    public static let contentMargin: CGFloat = 60

    /// Standard shelf gutter.
    public static let gutter: CGFloat = 36

    /// Poster-card width and height.
    public static let posterWidth: CGFloat = 240
    public static let posterHeight: CGFloat = 360

    /// Returns a spacing value on the 12-point grid.
    public static func spacing(_ steps: Int) -> CGFloat {
        CGFloat(steps) * unit
    }
}

/// Resolved motion values for a focused card.
public struct FocusEffect: Sendable, Equatable {
    public var scale: CGFloat
    public var parallaxOffset: CGFloat
    public var overlayOpacity: Double
    public var animationDuration: Double
    public var usesCrossfade: Bool

    public var animation: Animation {
        .easeInOut(duration: animationDuration)
    }

    public static func resolve(
        reduceMotion: Bool,
        isFocused: Bool
    ) -> FocusEffect {
        // Focus scaling stays for spatial orientation; reduce-motion swaps the
        // parallax drift for a highlight crossfade.
        let scale: CGFloat = isFocused ? DesignTokens.Focus.scale : 1
        let duration = reduceMotion
            ? DesignTokens.Motion.reduceMotionDuration
            : DesignTokens.Motion.focusDuration
        return FocusEffect(
            scale: scale,
            parallaxOffset: (isFocused && !reduceMotion)
                ? DesignTokens.Focus.parallaxOffset
                : 0,
            overlayOpacity: isFocused ? 1 : 0,
            animationDuration: duration,
            usesCrossfade: reduceMotion
        )
    }
}

/// The root token namespace.
public enum DesignTokens {
    public enum Focus {
        /// Focused cards grow to 1.06× their resting size.
        public static let scale: CGFloat = 1.06

        /// Content drift used for the standard parallax effect.
        public static let parallaxOffset: CGFloat = 4

        public static let cornerRadius: CGFloat = 20
        public static let focusedCornerRadius: CGFloat = 24
        public static let borderWidth: CGFloat = 3
        public static let highContrastBorderWidth: CGFloat = 5
        public static let shadowRadius: CGFloat = 28
    }

    public enum Motion {
        public static let focusDuration: Double = 0.18
        public static let reduceMotionDuration: Double = 0.12
        public static let overlayDuration: Double = 0.9
    }

    public static var palette: DesignPalette {
        .dark
    }

    public static func palette(
        highContrast: Bool
    ) -> DesignPalette {
        highContrast ? .highContrast : .dark
    }
}
