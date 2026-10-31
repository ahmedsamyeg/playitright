import Foundation

/// App-level thermal pressure, decoupled from `ProcessInfo.ThermalState`.
public enum ThermalState: String, Sendable, Equatable, CaseIterable, Comparable {
    case nominal
    case fair
    case serious
    case critical

    /// Numeric severity, useful for comparisons and pipeline downgrades.
    public var severity: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: ThermalState, rhs: ThermalState) -> Bool {
        lhs.severity < rhs.severity
    }

    /// Maps a platform thermal state into the app domain.
    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

/// Observes thermal pressure and publishes debounced transitions.
///
/// Notifications are coalesced to at most one emission per `minimumInterval`
/// (one second by default, matching NFR-2's "no feature may poll > 1 Hz").
/// Consumers can iterate `states()` to downgrade the playback pipeline at
/// `.serious` and pause new transcode sessions at `.critical`.
public final class ThermalMonitor: @unchecked Sendable {
    /// The process-wide monitor.
    public static let shared = ThermalMonitor()

    private let notificationCenter: NotificationCenter
    private let stateProvider: @Sendable () -> ThermalState
    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var current: ThermalState
    private var lastEmissionAt: Date?
    private var continuations: [UUID: AsyncStream<ThermalState>.Continuation] = [:]
    private var observer: NSObjectProtocol?

    /// Creates a thermal monitor and begins observing thermal notifications.
    ///
    /// - Parameters:
    ///   - notificationCenter: Center used for observation, injectable for tests.
    ///   - stateProvider: Reads the current platform thermal state.
    ///   - minimumInterval: Minimum time between emissions, in seconds.
    ///   - now: Clock used for rate limiting, injectable for tests.
    public init(
        notificationCenter: NotificationCenter = .default,
        stateProvider: @escaping @Sendable () -> ThermalState = {
            ThermalState(ProcessInfo.processInfo.thermalState)
        },
        minimumInterval: TimeInterval = 1.0,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.notificationCenter = notificationCenter
        self.stateProvider = stateProvider
        self.minimumInterval = minimumInterval
        self.now = now
        self.current = stateProvider()

        self.observer = notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }

    /// The most recently published state.
    public var currentState: ThermalState {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Creates a stream of thermal states, starting with the current state.
    ///
    /// Each call creates an independent subscription. Terminate the consuming
    /// task to release the subscription.
    public func states(
        bufferingPolicy: AsyncStream<ThermalState>.Continuation.BufferingPolicy = .bufferingNewest(1)
    ) -> AsyncStream<ThermalState> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()

            lock.lock()
            continuations[id] = continuation
            let initial = current
            lock.unlock()

            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    /// Samples the platform state and publishes it if it changed.
    ///
    /// Emissions are throttled to `minimumInterval`; a change inside the
    /// throttle window is dropped. The observer invokes this automatically on
    /// thermal notifications, but it can also be called to force a sample.
    public func refresh() {
        let state = stateProvider()
        let timestamp = now()

        lock.lock()

        guard state != current else {
            lock.unlock()
            return
        }

        if let lastEmissionAt,
           timestamp.timeIntervalSince(lastEmissionAt) < minimumInterval {
            lock.unlock()
            return
        }

        current = state
        lastEmissionAt = timestamp
        let subscribers = Array(continuations.values)
        lock.unlock()

        for continuation in subscribers {
            continuation.yield(state)
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        continuations.removeValue(forKey: id)
    }
}
