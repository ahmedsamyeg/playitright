import AVFoundation
import Foundation
import UIKit

/// The raw state read from the system before user overrides are applied.
public struct SinkObservation: Sendable, Equatable {
    public var display: DisplayCapabilities
    public var audioSetup: AudioSetup
    public var routeName: String?

    public init(
        display: DisplayCapabilities,
        audioSetup: AudioSetup,
        routeName: String? = nil
    ) {
        self.display = display
        self.audioSetup = audioSetup
        self.routeName = routeName
    }
}

/// Captures display and audio capabilities and merges them with the user's
/// Settings declarations (PB-4, PB-6, doc 04 §3).
///
/// tvOS does not expose the TV's or receiver's capabilities to apps, so the
/// observed profile is intentionally conservative (SDR, stereo/TV speakers)
/// and the user declaration is authoritative. The manager re-reads on display
/// mode/connection changes and `AVAudioSession` route changes.
@MainActor
public final class SinkProfileManager {
    public private(set) var profile: SinkProfile

    /// Incremented every time the profile is recalculated. Useful for tests
    /// and diagnostics.
    public private(set) var refreshCount: Int = 0

    public var overrides: SinkOverrides {
        didSet {
            rebuild()
        }
    }

    private let observation: () -> SinkObservation
    private let now: () -> Date
    private var observedAudio: (setup: AudioSetup, routeName: String?)?
    nonisolated(unsafe) private let notificationCenter: NotificationCenter
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []

    public init(
        overrides: SinkOverrides = SinkOverrides(),
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init,
        observation: @escaping () -> SinkObservation
    ) {
        self.overrides = overrides
        self.notificationCenter = notificationCenter
        self.now = now
        self.observation = observation
        self.profile = Self.makeProfile(
            observation: observation(),
            overrides: overrides,
            now: now()
        )
        observeSystemChanges()
    }

    /// Production initializer that reads `UIScreen` and `AVAudioSession`.
    public convenience init(overrides: SinkOverrides = SinkOverrides()) {
        self.init(
            overrides: overrides,
            observation: { Self.systemObservation() }
        )
    }

    deinit {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
    }

    /// Recalculates the profile and stamps it with the current time.
    public func refresh() {
        refreshCount += 1
        profile = Self.makeProfile(
            observation: effectiveObservation(),
            overrides: overrides,
            now: now()
        )
    }

    /// Applies the audio route observed by `AirPlayController` (SYNC-6).
    ///
    /// The route override is observational, not a user declaration: it updates
    /// the audio setup and route name while leaving display overrides intact.
    public func applyObservedAudio(
        _ setup: AudioSetup,
        routeName: String?
    ) {
        observedAudio = (setup, routeName)
        refresh()
    }

    /// Clears the AirPlay route override and falls back to system observation.
    public func clearObservedAudio() {
        observedAudio = nil
        refresh()
    }

    /// Replaces the user declaration and recalculates.
    public func setOverrides(_ overrides: SinkOverrides) {
        self.overrides = overrides
    }

    /// Removes every user declaration so the observed profile wins again.
    public func clearOverrides() {
        setOverrides(SinkOverrides())
    }

    // MARK: - Merge

    private func rebuild() {
        refreshCount += 1
        profile = Self.makeProfile(
            observation: effectiveObservation(),
            overrides: overrides,
            now: now()
        )
    }

    private func effectiveObservation() -> SinkObservation {
        var observation = observation()
        if let observedAudio {
            observation.audioSetup = observedAudio.setup
            observation.routeName = observedAudio.routeName
        }
        return observation
    }

    private static func makeProfile(
        observation: SinkObservation,
        overrides: SinkOverrides,
        now: Date
    ) -> SinkProfile {
        let display: DisplayCapabilities
        if let declared = overrides.display {
            display = DisplayCapabilities.declared(
                declared,
                width: observation.display.width,
                height: observation.display.height,
                refreshRate: observation.display.maxRefreshRate
            )
        } else {
            display = observation.display
        }

        let audio: AudioCapabilities
        if let declared = overrides.audio {
            audio = AudioCapabilities.declared(
                declared,
                routeName: observation.routeName
            )
        } else {
            audio = AudioCapabilities.declared(
                observation.audioSetup,
                routeName: observation.routeName
            )
        }

        return SinkProfile(
            display: display,
            audio: audio,
            declaredDisplay: overrides.display,
            declaredAudio: overrides.audio,
            updatedAt: now
        )
    }

    // MARK: - System observation

    private func observeSystemChanges() {
        let names: [Notification.Name] = [
            UIScreen.didConnectNotification,
            UIScreen.didDisconnectNotification,
            UIScreen.modeDidChangeNotification,
            AVAudioSession.routeChangeNotification
        ]

        for name in names {
            let token = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
            observerTokens.append(token)
        }
    }

    /// Conservative system defaults; user declarations fill the gaps tvOS
    /// cannot report.
    public static func systemObservation() -> SinkObservation {
        let screen = UIScreen.main
        let scale = screen.scale > 0 ? screen.scale : 1
        let width = Int((screen.bounds.width * scale).rounded())
        let height = Int((screen.bounds.height * scale).rounded())
        let refreshRate = Double(screen.maximumFramesPerSecond)
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.first

        return SinkObservation(
            display: DisplayCapabilities(
                supportsSDR: true,
                width: width > 0 ? width : 1_920,
                height: height > 0 ? height : 1_080,
                maxRefreshRate: refreshRate > 0 ? refreshRate : 60,
                currentRefreshRate: refreshRate > 0 ? refreshRate : 60
            ),
            audioSetup: setup(for: route?.portType),
            routeName: route?.portName
        )
    }

    private static func setup(
        for portType: AVAudioSession.Port?
    ) -> AudioSetup {
        switch portType {
        case .HDMI:
            return .receiverAC3
        case .headphones:
            return .headphones
        case .airPlay:
            return .speakers
        case .builtInSpeaker, .builtInReceiver:
            return .speakers
        default:
            return .speakers
        }
    }
}
