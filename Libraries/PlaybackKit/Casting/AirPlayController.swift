import AVFoundation
import AVKit
import Foundation
import UIKit

/// The currently selected audio/video route, if any.
public struct AirPlayRoute: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case homePod
        case appleTV
        case airPlay
        case headphones
        case builtIn
        case other
    }

    /// System-provided route name, for display and diagnostics.
    public var name: String?

    /// `AVAudioSession.Port` raw value, kept as a string for `Sendable`.
    public var portTypeIdentifier: String

    public init(
        name: String? = nil,
        portType: AVAudioSession.Port? = nil
    ) {
        self.name = name
        self.portTypeIdentifier = portType?.rawValue ?? ""
    }

    /// The route reported by the shared audio session.
    public static func current() -> AirPlayRoute {
        let output = AVAudioSession.sharedInstance().currentRoute.outputs.first
        return AirPlayRoute(
            name: output?.portName,
            portType: output?.portType
        )
    }

    public var portType: AVAudioSession.Port? {
        AVAudioSession.Port(rawValue: portTypeIdentifier)
    }

    /// Route classification used to choose audio processing.
    public var kind: Kind {
        guard let portType else {
            return .other
        }
        switch portType {
        case .airPlay:
            let normalized = (name ?? "").lowercased()
            if normalized.contains("homepod") {
                return .homePod
            }
            if normalized.contains("apple tv")
                || normalized.contains("apple-tv") {
                return .appleTV
            }
            return .airPlay
        case .headphones:
            return .headphones
        case .builtInSpeaker, .builtInReceiver:
            return .builtIn
        default:
            return .other
        }
    }

    /// The audio setup implied by this route (doc 04 §3).
    public var audioSetup: AudioSetup {
        switch kind {
        case .homePod:
            return .homePod
        case .headphones:
            return .headphones
        case .airPlay, .appleTV, .builtIn, .other:
            return .speakers
        }
    }

    public var isAirPlay: Bool {
        portType == .airPlay
    }

    /// Whether this route can carry video to another screen.
    public var isVideoRoute: Bool {
        kind == .appleTV
    }
}

/// Observes AirPlay route changes and feeds them into the sink profile.
///
/// The controller owns the live observation seam that `SinkProfileManager`
/// cannot infer from tvOS: a HomePod route implies stereo Atmos-capable
/// output, while an Apple TV route is video forwarding. Every accepted change
/// recalculates the profile and calls `onReplan` so the pipeline planner can
/// re-evaluate (SYNC-6, PB-6).
@MainActor
public final class AirPlayController {
    public private(set) var currentRoute: AirPlayRoute

    /// Incremented for every route-change notification handled.
    public private(set) var routeChangeCount = 0

    /// Called after the sink profile has been recalculated.
    public var onRouteChange: ((AirPlayRoute) -> Void)?

    /// Called with the fresh profile so playback can re-plan.
    public var onReplan: ((SinkProfile) -> Void)?

    private let sinkManager: SinkProfileManager
    private let notificationCenter: NotificationCenter
    private let routeProvider: () -> AirPlayRoute
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []

    public init(
        sinkManager: SinkProfileManager,
        notificationCenter: NotificationCenter = .default,
        routeProvider: @escaping () -> AirPlayRoute = { AirPlayRoute.current() }
    ) {
        self.sinkManager = sinkManager
        self.notificationCenter = notificationCenter
        self.routeProvider = routeProvider
        self.currentRoute = routeProvider()
        observeRouteChanges()
    }

    deinit {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
    }

    /// Re-reads the route and applies it now. Useful after returning from the
    /// system route picker.
    public func refresh() {
        handleRouteChange()
    }

    /// Applies one route-change notification.
    public func handleRouteChange() {
        routeChangeCount += 1
        let route = routeProvider()
        currentRoute = route

        sinkManager.applyObservedAudio(
            route.audioSetup,
            routeName: route.name
        )

        onRouteChange?(route)
        onReplan?(sinkManager.profile)
    }

    // MARK: - Route picker

    /// Builds the system route picker, preferring video-capable destinations.
    public func makeRoutePickerView() -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        Self.configure(picker)
        return picker
    }

    /// Configures an existing picker for Apple TV video routing.
    public static func configure(_ picker: AVRoutePickerView) {
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
    }

    // MARK: - Observation

    private func observeRouteChanges() {
        let token = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleRouteChange()
            }
        }
        observerTokens.append(token)
    }
}
