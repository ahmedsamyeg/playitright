import Foundation
import Testing
@testable import CoreKit

@Suite("ThermalMonitor Tests")
struct ThermalMonitorTests {
    private final class StateSource: @unchecked Sendable {
        private let lock = NSLock()
        private var state: ThermalState

        init(_ state: ThermalState) {
            self.state = state
        }

        func set(_ state: ThermalState) {
            lock.lock()
            defer { lock.unlock() }
            self.state = state
        }

        func get() -> ThermalState {
            lock.lock()
            defer { lock.unlock() }
            return state
        }
    }

    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000)

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
    }

    private func collect(
        _ stream: AsyncStream<ThermalState>,
        count: Int
    ) async -> [ThermalState] {
        var seen: [ThermalState] = []
        for await state in stream {
            seen.append(state)
            if seen.count >= count {
                break
            }
        }
        return seen
    }

    private func postThermalChange(to center: NotificationCenter) {
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    @Test("Platform states map to the app domain")
    func mapsPlatformStates() {
        #expect(ThermalState(ProcessInfo.ThermalState.nominal) == .nominal)
        #expect(ThermalState(ProcessInfo.ThermalState.fair) == .fair)
        #expect(ThermalState(ProcessInfo.ThermalState.serious) == .serious)
        #expect(ThermalState(ProcessInfo.ThermalState.critical) == .critical)
    }

    @Test("Severity ordering reflects increasing thermal pressure")
    func severityOrdering() {
        #expect(ThermalState.nominal < .fair)
        #expect(ThermalState.fair < .serious)
        #expect(ThermalState.serious < .critical)
    }

    @Test("A new stream begins with the current state")
    func streamStartsWithCurrentState() async {
        let center = NotificationCenter()
        let source = StateSource(.fair)
        let monitor = ThermalMonitor(
            notificationCenter: center,
            stateProvider: { source.get() },
            minimumInterval: 0
        )

        let stream = monitor.states(bufferingPolicy: .unbounded)
        let seen = await collect(stream, count: 1)

        #expect(seen == [.fair])
    }

    @Test("Thermal notifications publish state transitions")
    func transitionsPublishToStream() async {
        let center = NotificationCenter()
        let source = StateSource(.nominal)
        let clock = ManualClock()
        let monitor = ThermalMonitor(
            notificationCenter: center,
            stateProvider: { source.get() },
            minimumInterval: 0,
            now: { clock.now() }
        )

        let stream = monitor.states(bufferingPolicy: .unbounded)

        source.set(.serious)
        postThermalChange(to: center)

        source.set(.critical)
        postThermalChange(to: center)

        let seen = await collect(stream, count: 3)

        #expect(seen == [.nominal, .serious, .critical])
        #expect(monitor.currentState == .critical)
    }

    @Test("All subscribers receive transitions")
    func fansOutToMultipleSubscribers() async {
        let center = NotificationCenter()
        let source = StateSource(.nominal)
        let monitor = ThermalMonitor(
            notificationCenter: center,
            stateProvider: { source.get() },
            minimumInterval: 0
        )

        let first = monitor.states(bufferingPolicy: .unbounded)
        let second = monitor.states(bufferingPolicy: .unbounded)

        source.set(.serious)
        postThermalChange(to: center)

        let firstSeen = await collect(first, count: 2)
        let secondSeen = await collect(second, count: 2)

        #expect(firstSeen == [.nominal, .serious])
        #expect(secondSeen == [.nominal, .serious])
    }

    @Test("Rapid notifications are throttled to at most 1 Hz")
    func rateLimitsNotifications() async {
        let center = NotificationCenter()
        let source = StateSource(.nominal)
        let clock = ManualClock()
        let monitor = ThermalMonitor(
            notificationCenter: center,
            stateProvider: { source.get() },
            minimumInterval: 1.0,
            now: { clock.now() }
        )

        let stream = monitor.states(bufferingPolicy: .unbounded)

        // First transition is inside the window and is emitted.
        source.set(.fair)
        postThermalChange(to: center)

        // The next two changes occur within one second and must be dropped.
        clock.advance(0.1)
        source.set(.serious)
        postThermalChange(to: center)

        clock.advance(0.1)
        source.set(.critical)
        postThermalChange(to: center)

        // Once the window has elapsed, the latest state is published.
        clock.advance(1.0)
        source.set(.nominal)
        postThermalChange(to: center)

        let seen = await collect(stream, count: 3)

        #expect(seen == [.nominal, .fair, .nominal])
    }

    @Test("A repeated state does not emit again")
    func unchangedStateDoesNotEmit() async {
        let center = NotificationCenter()
        let source = StateSource(.nominal)
        let monitor = ThermalMonitor(
            notificationCenter: center,
            stateProvider: { source.get() },
            minimumInterval: 0
        )

        let stream = monitor.states(bufferingPolicy: .unbounded)

        postThermalChange(to: center)
        postThermalChange(to: center)

        // Only the initial state is buffered; drain one entry.
        let seen = await collect(stream, count: 1)
        #expect(seen == [.nominal])
        #expect(monitor.currentState == .nominal)
    }
}
