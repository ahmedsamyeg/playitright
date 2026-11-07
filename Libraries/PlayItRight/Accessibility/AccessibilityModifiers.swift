import PlaybackKit
import SwiftUI

// MARK: - Labels

/// Shared VoiceOver label builders. Keeping them as values lets the audit test
/// assert wording without a hosted view hierarchy (UI-4, UI-6, NFR-23).
public enum AccessibilityLabelBuilder {
    /// Combines a media title, subtitle, badges, and progress into one label.
    public static func mediaCard(
        title: String,
        subtitle: String? = nil,
        badges: [String] = [],
        isWatched: Bool = false,
        isInProgress: Bool = false
    ) -> String {
        var parts = [title]
        if let subtitle, !subtitle.isEmpty {
            parts.append(subtitle)
        }
        parts.append(contentsOf: badges)
        if isWatched {
            parts.append("Watched")
        } else if isInProgress {
            parts.append("In progress")
        }
        return parts.joined(separator: ", ")
    }

    /// Reads technology badges as words, not raw abbreviations.
    public static func techBadges(_ labels: [String]) -> String {
        let cleaned = labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            return "No quality badges"
        }
        return "Quality: " + cleaned.joined(separator: ", ")
    }

    /// A spoken transport position, e.g. "12 minutes 5 seconds of 1 hour 42 minutes".
    public static func playbackPosition(
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> String {
        let clampedElapsed = min(max(0, elapsed), max(0, duration))
        return "\(spokenTime(clampedElapsed)) of \(spokenTime(duration))"
    }

    private static func spokenTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remaining = total % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append("\(hours) \(hours == 1 ? "hour" : "hours")")
        }
        if minutes > 0 {
            parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")")
        }
        if remaining > 0 || parts.isEmpty {
            parts.append("\(remaining) \(remaining == 1 ? "second" : "seconds")")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Closed captions

/// Viewer overrides for closed captions (UI-5).
///
/// Values are clamped in `init`, so the renderer never receives an invalid
/// scale, opacity, or offset. The preset supplies the base look; the fields
/// here let the viewer adjust it without rebuilding the subtitle document.
public struct ClosedCaptionCustomization: Sendable, Equatable {
    public var preset: SubtitleStylePreset
    public var fontScale: Double
    public var opacity: Double
    public var positionOffset: Double
    public var textColor: SubtitleColor
    public var backgroundColor: SubtitleColor
    public var backgroundOpacity: Double
    public var isForcedOnly: Bool

    public init(
        preset: SubtitleStylePreset = .standard,
        fontScale: Double = 1,
        opacity: Double = 1,
        positionOffset: Double = 0,
        textColor: SubtitleColor? = nil,
        backgroundColor: SubtitleColor = .black,
        backgroundOpacity: Double = 0,
        isForcedOnly: Bool = false
    ) {
        let base = preset.appearance
        self.preset = preset
        self.fontScale = min(2, max(0.5, fontScale))
        self.opacity = min(1, max(0, opacity))
        self.positionOffset = min(0.5, max(-0.5, positionOffset))
        self.textColor = textColor ?? base.color
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = min(1, max(0, backgroundOpacity))
        self.isForcedOnly = isForcedOnly
    }

    /// The appearance handed to the subtitle renderer.
    public var appearance: SubtitleAppearance {
        appearance(base: preset.appearance)
    }

    /// Applies the viewer overrides on top of a preset look.
    public func appearance(base: SubtitleAppearance) -> SubtitleAppearance {
        SubtitleAppearance(
            fontName: base.fontName,
            fontSize: base.fontSize,
            fontScale: fontScale,
            opacity: opacity,
            color: textColor,
            outlineColor: base.outlineColor,
            outlineWidth: base.outlineWidth,
            positionOffset: positionOffset
        )
    }

    /// The large-print preset with full opacity and a stronger outline.
    public static let accessibilityLargePrint = ClosedCaptionCustomization(
        preset: .largePrint,
        fontScale: 1.2,
        opacity: 1,
        backgroundOpacity: 0.35,
        isForcedOnly: false
    )
}

// MARK: - Focus policy

/// Resolves the focus ring, border, and palette for the current contrast
/// setting (UI-4, NFR-23).
public struct AccessibilityVisualPolicy: Sendable, Equatable {
    public var borderWidth: CGFloat
    public var focusRing: DesignColor
    public var palette: DesignPalette

    public init(
        borderWidth: CGFloat,
        focusRing: DesignColor,
        palette: DesignPalette
    ) {
        self.borderWidth = borderWidth
        self.focusRing = focusRing
        self.palette = palette
    }

    public static func resolve(highContrast: Bool) -> AccessibilityVisualPolicy {
        let palette = DesignTokens.palette(highContrast: highContrast)
        return AccessibilityVisualPolicy(
            borderWidth: highContrast
                ? DesignTokens.Focus.highContrastBorderWidth
                : DesignTokens.Focus.borderWidth,
            focusRing: palette.focusRing,
            palette: palette
        )
    }

    public var focusRingContrast: Double {
        focusRing.contrastRatio(against: palette.background)
    }
}

// MARK: - Screen contract

/// Every screen the accessibility audit covers.
public enum AccessibilityScreen: String, CaseIterable, Sendable, Identifiable {
    case home
    case library
    case detail
    case player
    case settings
    case search
    case onboarding
    case paywall

    public var id: String { rawValue }
}

/// One spoken control or region on a screen.
public struct AccessibilityControl: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case header
        case button
        case adjustable
        case textField
        case secureField
        case image
    }

    public var id: String
    public var label: String
    public var hint: String?
    public var value: String?
    public var kind: Kind

    public init(
        id: String,
        label: String,
        hint: String? = nil,
        value: String? = nil,
        kind: Kind
    ) {
        self.id = id
        self.label = label
        self.hint = hint
        self.value = value
        self.kind = kind
    }

    public var traits: FocusAccessibilityTraits {
        switch kind {
        case .header:
            return [.isHeader]
        case .image:
            return [.isImage]
        case .button, .adjustable:
            return [.isButton]
        case .textField, .secureField:
            return []
        }
    }

    public var requiresHint: Bool {
        kind == .button || kind == .adjustable
    }
}

/// The accessibility contract for one screen.
public struct AccessibilityScreenDescriptor: Sendable, Equatable, Identifiable {
    public var screen: AccessibilityScreen
    public var title: String
    public var controls: [AccessibilityControl]

    public var id: String { screen.rawValue }

    public init(
        screen: AccessibilityScreen,
        title: String,
        controls: [AccessibilityControl]
    ) {
        self.screen = screen
        self.title = title
        self.controls = controls
    }
}

/// The expected VoiceOver contract across the app.
///
/// The audit test checks every screen has a spoken title, a header, complete
/// control labels, and hints for interactive controls.
public enum AccessibilityCatalog {
    public static var screens: [AccessibilityScreenDescriptor] {
        [
            AccessibilityScreenDescriptor(
                screen: .home,
                title: "Home",
                controls: [
                    .init(id: "home.title", label: "Home", kind: .header),
                    .init(
                        id: "home.continue",
                        label: "Continue Watching",
                        hint: "Shows items you have started.",
                        kind: .button
                    ),
                    .init(
                        id: "home.recent",
                        label: "Recently Added",
                        hint: "Shows the newest items in your library.",
                        kind: .button
                    )
                ]
            ),
            AccessibilityScreenDescriptor(
                screen: .library,
                title: "Library",
                controls: [
                    .init(id: "library.title", label: "Library", kind: .header),
                    .init(
                        id: "library.sort",
                        label: "Sort: Title",
                        hint: "Changes the order of library items.",
                        kind: .button
                    ),
                    .init(
                        id: "library.density",
                        label: "Switch to list view",
                        hint: "Changes between grid and list layouts.",
                        kind: .button
                    ),
                    .init(
                        id: "library.card",
                        label: "Blade Runner 2049, Movie, 4K, Dolby Vision",
                        hint: "Double-click to open Blade Runner 2049.",
                        kind: .button
                    )
                ]
            ),
            AccessibilityScreenDescriptor(
                screen: .detail,
                title: "Movie or show details",
                controls: [
                    .init(id: "detail.title", label: "Movie title", kind: .header),
                    .init(
                        id: "detail.play",
                        label: "Play",
                        hint: "Starts playback from where you left off.",
                        kind: .button
                    ),
                    .init(
                        id: "detail.quality",
                        label: "Playback quality: 4K Dolby Vision",
                        hint: "Opens the pipeline explanation.",
                        kind: .button
                    ),
                    .init(
                        id: "detail.season",
                        label: "Season",
                        hint: "Changes the season.",
                        value: "Season 1",
                        kind: .adjustable
                    )
                ]
            ),
            AccessibilityScreenDescriptor(
                screen: .player,
                title: "Player",
                controls: [
                    .init(
                        id: "player.title",
                        label: "Now Playing",
                        kind: .header
                    ),
                    .init(
                        id: "player.playPause",
                        label: "Play",
                        hint: "Starts or pauses playback.",
                        kind: .button
                    ),
                    .init(
                        id: "player.scrubber",
                        label: "Playback position",
                        hint: "Swipe up or down to seek.",
                        value: "12 minutes 5 seconds of 1 hour 42 minutes",
                        kind: .adjustable
                    ),
                    .init(
                        id: "player.tracks",
                        label: "Audio and Subtitles",
                        hint: "Choose an audio track or subtitle.",
                        kind: .button
                    )
                ]
            ),
            AccessibilityScreenDescriptor(
                screen: .settings,
                title: "Settings",
                controls: [
                    .init(id: "settings.title", label: "Settings", kind: .header),
                    .init(
                        id: "settings.addSource",
                        label: "Add Source",
                        hint: "Connects another media server or share.",
                        kind: .button
                    ),
                    .init(
                        id: "settings.clearCache",
                        label: "Clear Cache",
                        hint: "Removes every cached poster and backdrop.",
                        kind: .button
                    ),
                    .init(
                        id: "settings.about",
                        label: "About This Apple TV",
                        hint: "Shows what this device can play.",
                        kind: .button
                    )
                ]
            ),
            AccessibilityScreenDescriptor(
                screen: .search,
                title: "Search",
                controls: [
                    .init(id: "search.title", label: "Search", kind: .header),
                    .init(
                        id: "search.field",
                        label: "Search your library",
                        value: "No query",
                        kind: .textField
                    ),
                    .init(
                        id: "search.fix",
                        label: "Fix Matching",
                        hint: "Resolve unmatched or low-confidence files.",
                        kind: .button
                    )
                ]
            ),
            AccessibilityScreenDescriptor(
                screen: .onboarding,
                title: "Connect your first source",
                controls: [
                    .init(
                        id: "onboarding.title",
                        label: "Connect your first source",
                        kind: .header
                    ),
                    .init(
                        id: "onboarding.name",
                        label: "Name",
                        value: "Living Room",
                        kind: .textField
                    ),
                    .init(
                        id: "onboarding.password",
                        label: "Password",
                        value: "Stored in the Keychain",
                        kind: .secureField
                    ),
                    .init(
                        id: "onboarding.connect",
                        label: "Connect",
                        hint: "Starts the first scan.",
                        kind: .button
                    )
                ]
            ),
            AccessibilityScreenDescriptor(
                screen: .paywall,
                title: "PlayItRight Pro",
                controls: [
                    .init(
                        id: "paywall.title",
                        label: "PlayItRight Pro",
                        kind: .header
                    ),
                    .init(
                        id: "paywall.trial",
                        label: "Start Free Trial",
                        hint: "Starts the monthly plan with a 7-day free trial.",
                        kind: .button
                    ),
                    .init(
                        id: "paywall.restore",
                        label: "Restore Purchases",
                        hint: "Checks the App Store for an existing Pro purchase.",
                        kind: .button
                    ),
                    .init(
                        id: "paywall.dismiss",
                        label: "Not Now",
                        hint: "Closes the Pro sheet.",
                        kind: .button
                    )
                ]
            )
        ]
    }

    /// Returns every contract violation found in the catalog.
    public static func issues(
        in descriptors: [AccessibilityScreenDescriptor] = screens
    ) -> [String] {
        var issues: [String] = []
        let covered = Set(descriptors.map(\.screen))
        for screen in AccessibilityScreen.allCases where !covered.contains(screen) {
            issues.append("\(screen.rawValue): no accessibility contract")
        }

        for descriptor in descriptors {
            if descriptor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(descriptor.screen.rawValue): empty screen title")
            }
            if !descriptor.controls.contains(where: { $0.kind == .header }) {
                issues.append("\(descriptor.screen.rawValue): missing header")
            }
            for control in descriptor.controls {
                if control.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append("\(control.id): empty label")
                }
                if control.requiresHint,
                   control.hint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    issues.append("\(control.id): missing hint")
                }
            }
            if Set(descriptor.controls.map(\.id)).count != descriptor.controls.count {
                issues.append("\(descriptor.screen.rawValue): duplicate control ids")
            }
        }
        return issues
    }
}

// MARK: - View modifiers

public extension View {
    /// Marks a region as a VoiceOver heading.
    func accessibleHeading() -> some View {
        accessibilityAddTraits(.isHeader)
    }

    /// Applies a spoken label and optional hint to a control.
    func accessibleControl(
        label: String,
        hint: String? = nil,
        value: String? = nil
    ) -> some View {
        self
            .accessibilityLabel(Text(label))
            .accessibilityHint(Text(hint ?? ""))
            .accessibilityValue(Text(value ?? ""))
    }

    /// Combines a media card's title, subtitle, badges, and progress for
    /// VoiceOver.
    func accessibleMediaCard(
        title: String,
        subtitle: String? = nil,
        badges: [String] = [],
        isWatched: Bool = false,
        isInProgress: Bool = false,
        hint: String? = nil
    ) -> some View {
        let label = AccessibilityLabelBuilder.mediaCard(
            title: title,
            subtitle: subtitle,
            badges: badges,
            isWatched: isWatched,
            isInProgress: isInProgress
        )
        return self
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityHint(Text(hint ?? "Double-click to open \(title)."))
            .accessibilityAddTraits(.isButton)
    }

    /// Applies the high-contrast focus ring width and color.
    func highContrastFocusRing(
        isFocused: Bool,
        contrast: ColorSchemeContrast
    ) -> some View {
        let policy = AccessibilityVisualPolicy.resolve(
            highContrast: contrast == .increased
        )
        return overlay {
            RoundedRectangle(
                cornerRadius: DesignTokens.Focus.cornerRadius,
                style: .continuous
            )
            .stroke(policy.focusRing.color, lineWidth: policy.borderWidth)
            .opacity(isFocused ? 1 : 0)
        }
    }
}
