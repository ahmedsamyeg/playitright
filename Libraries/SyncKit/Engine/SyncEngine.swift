import Foundation
import Network
import Synchronization
@preconcurrency import CloudKit

// MARK: - Reachability

/// Reachability seam so offline behavior is testable without a live network.
public protocol SyncReachability: Sendable {
    /// Whether the device currently has a usable network path.
    var isOnline: Bool { get }

    /// Emits the current state immediately, then every change.
    func updates() -> AsyncStream<Bool>
}

/// `NWPathMonitor`-backed reachability listener.
public final class NetworkReachabilityMonitor: SyncReachability, @unchecked Sendable {
    private struct State {
        var online = false
        var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let state = Mutex(State())
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "SyncKit.Reachability")

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(isOnline: path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    public var isOnline: Bool {
        state.withLock { $0.online }
    }

    public func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            let current = state.withLock { state -> Bool in
                state.continuations[id] = continuation
                return state.online
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    private func update(isOnline: Bool) {
        let continuations = state.withLock {
            state -> [AsyncStream<Bool>.Continuation] in
            state.online = isOnline
            return Array(state.continuations.values)
        }
        for continuation in continuations {
            continuation.yield(isOnline)
        }
    }

    private func removeContinuation(_ id: UUID) {
        _ = state.withLock { state in
            state.continuations.removeValue(forKey: id)
        }
    }
}

// MARK: - Configuration & results

/// Tunables for the sync engine.
public struct SyncEngineConfiguration: Sendable, Equatable {
    /// Maximum records pushed in one pass.
    public var batchSize: Int

    /// At most one watch-state write per item in this window (doc 07 §1.2).
    public var minimumWatchStateWriteInterval: TimeInterval

    /// Number of attempts in one retry loop.
    public var maxAttempts: Int

    /// First retry delay in seconds.
    public var baseRetryDelay: TimeInterval

    /// Cap for exponential backoff.
    public var maxRetryDelay: TimeInterval

    /// Fractional jitter applied to each delay, in `0...1`.
    public var jitterFraction: Double

    /// Schedules a background flush after a local enqueue when online.
    public var autoFlushOnEnqueue: Bool

    public init(
        batchSize: Int = 200,
        minimumWatchStateWriteInterval: TimeInterval = 30,
        maxAttempts: Int = 5,
        baseRetryDelay: TimeInterval = 1,
        maxRetryDelay: TimeInterval = 300,
        jitterFraction: Double = 0.2,
        autoFlushOnEnqueue: Bool = true
    ) {
        self.batchSize = max(1, batchSize)
        self.minimumWatchStateWriteInterval = max(
            0,
            minimumWatchStateWriteInterval
        )
        self.maxAttempts = max(1, maxAttempts)
        self.baseRetryDelay = max(0, baseRetryDelay)
        self.maxRetryDelay = max(self.baseRetryDelay, maxRetryDelay)
        self.jitterFraction = min(1, max(0, jitterFraction))
        self.autoFlushOnEnqueue = autoFlushOnEnqueue
    }
}

/// Outcome of one drain pass.
public struct SyncFlushResult: Sendable, Equatable {
    public var uploaded: Int
    public var deleted: Int
    public var pending: Int
    public var isOffline: Bool

    public init(
        uploaded: Int = 0,
        deleted: Int = 0,
        pending: Int = 0,
        isOffline: Bool = false
    ) {
        self.uploaded = uploaded
        self.deleted = deleted
        self.pending = pending
        self.isOffline = isOffline
    }
}

/// Plain-language state for the "sync pending (N)" pill (SYNC-2).
public struct SyncStatus: Sendable, Equatable {
    public var pendingCount: Int
    public var isOnline: Bool
    public var lastFlushAt: Date?
    public var lastError: String?

    public init(
        pendingCount: Int,
        isOnline: Bool,
        lastFlushAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.pendingCount = pendingCount
        self.isOnline = isOnline
        self.lastFlushAt = lastFlushAt
        self.lastError = lastError
    }
}

// MARK: - Engine

/// Drains the local delta queue to CloudKit.
///
/// Local writes enqueue immediately and never wait for the network. The engine
/// watches reachability, pushes coalesced changes in batches, and retries with
/// exponential backoff plus jitter (SYNC-2).
public actor SyncEngine {
    public let configuration: SyncEngineConfiguration
    public let zoneManager: CloudKitZoneManager
    public let queue: DeltaQueue

    private let reachability: any SyncReachability
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let randomUnit: @Sendable () -> Double

    private var lastWatchStateWriteAt: [String: Date] = [:]
    private var lastFlushAt: Date?
    private var lastError: String?
    private var listenerTask: Task<Void, Never>?
    private var backgroundFlushTask: Task<Void, Never>?

    public init(
        zoneManager: CloudKitZoneManager,
        queue: DeltaQueue,
        reachability: any SyncReachability = NetworkReachabilityMonitor(),
        configuration: SyncEngineConfiguration = SyncEngineConfiguration(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(
                nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
            )
        },
        randomUnit: @escaping @Sendable () -> Double = {
            Double.random(in: 0...1)
        }
    ) {
        self.zoneManager = zoneManager
        self.queue = queue
        self.reachability = reachability
        self.configuration = configuration
        self.now = now
        self.sleep = sleep
        self.randomUnit = randomUnit
    }

    // MARK: Lifecycle

    /// Starts listening for reachability changes and draining on reconnect.
    public func start() {
        guard listenerTask == nil else {
            return
        }
        let updates = reachability.updates()
        listenerTask = Task { [weak self] in
            for await isOnline in updates {
                guard let self else {
                    return
                }
                if isOnline {
                    _ = await self.flushWithRetry()
                }
            }
        }
    }

    /// Stops reachability observation and any background flush.
    public func stop() {
        listenerTask?.cancel()
        listenerTask = nil
        backgroundFlushTask?.cancel()
        backgroundFlushTask = nil
    }

    // MARK: Local writes

    /// Queues a record for upload. The local index is updated by the caller
    /// before this returns; this method only persists the pending delta.
    public func enqueue<R: SyncCloudRecord>(_ record: R) async throws {
        try await queue.enqueue(record, now: now())
        if configuration.autoFlushOnEnqueue && reachability.isOnline {
            scheduleBackgroundFlush()
        }
    }

    /// Queues a deletion for upload.
    public func enqueueDelete(
        recordType: String,
        recordName: String
    ) async throws {
        try await queue.enqueueDelete(
            recordType: recordType,
            recordName: recordName,
            now: now()
        )
        if configuration.autoFlushOnEnqueue && reachability.isOnline {
            scheduleBackgroundFlush()
        }
    }

    /// Number of records still waiting for CloudKit.
    public func pendingCount() async throws -> Int {
        try await queue.pendingCount()
    }

    /// Current state for the sync-pending pill.
    public func status() async throws -> SyncStatus {
        SyncStatus(
            pendingCount: try await queue.pendingCount(),
            isOnline: reachability.isOnline,
            lastFlushAt: lastFlushAt,
            lastError: lastError
        )
    }

    // MARK: Draining

    /// Performs one drain pass. Throws if CloudKit rejects a write so a caller
    /// can apply its own retry policy; `flushWithRetry()` does that by default.
    @discardableResult
    public func flush() async throws -> SyncFlushResult {
        try await queue.loadIfNeeded()

        guard reachability.isOnline else {
            return SyncFlushResult(
                pending: try await queue.pendingCount(),
                isOffline: true
            )
        }

        var uploaded = 0
        var deleted = 0

        while true {
            let currentTime = now()
            let batch = try await queue.pendingChanges(
                limit: configuration.batchSize
            )
            if batch.isEmpty {
                break
            }

            let eligible = batch.filter {
                isEligible($0, at: currentTime)
            }
            if eligible.isEmpty {
                break
            }

            for change in eligible {
                do {
                    switch change.operation {
                    case .save:
                        let record = try change.makeCloudRecord(
                            in: zoneManager.zoneID
                        )
                        _ = try await zoneManager.save(cloudRecord: record)
                        uploaded += 1
                        if change.recordType
                            == SyncWatchStateRecord.cloudRecordType {
                            lastWatchStateWriteAt[change.recordName] =
                                currentTime
                        }
                    case .delete:
                        try await zoneManager.delete(
                            recordName: change.recordName
                        )
                        deleted += 1
                    }
                    try await queue.remove(recordNames: [change.recordName])
                } catch {
                    let message = String(describing: error)
                    lastError = message
                    try await queue.markFailed(
                        recordNames: [change.recordName],
                        error: message,
                        at: currentTime
                    )
                    throw error
                }
            }

            lastError = nil
            lastFlushAt = currentTime

            // Deferred watch-state writes stay queued for a later pass.
            if eligible.count < batch.count {
                break
            }
            if batch.count < configuration.batchSize {
                break
            }
        }

        lastFlushAt = lastFlushAt ?? now()
        return SyncFlushResult(
            uploaded: uploaded,
            deleted: deleted,
            pending: try await queue.pendingCount()
        )
    }

    /// Drains with exponential backoff and jitter. Returns the last result even
    /// when all attempts fail, so the caller can show the pending pill.
    @discardableResult
    public func flushWithRetry() async -> SyncFlushResult {
        for attempt in 0..<configuration.maxAttempts {
            do {
                return try await flush()
            } catch {
                lastError = String(describing: error)
                guard attempt < configuration.maxAttempts - 1 else {
                    break
                }
                let delay = retryDelay(attempt: attempt)
                do {
                    try await sleep(delay)
                } catch {
                    break
                }
            }
        }

        return SyncFlushResult(
            pending: (try? await queue.pendingCount()) ?? 0
        )
    }

    /// Exponential backoff with jitter. `attempt` is zero-based.
    public func retryDelay(attempt: Int) -> TimeInterval {
        let exponent = Double(max(0, attempt))
        let base = min(
            configuration.maxRetryDelay,
            configuration.baseRetryDelay * pow(2, exponent)
        )
        let jitter = configuration.jitterFraction * randomUnit()
        return min(
            configuration.maxRetryDelay,
            base * (1 + jitter)
        )
    }

    // MARK: Internals

    private func isEligible(
        _ change: SyncQueuedChange,
        at date: Date
    ) -> Bool {
        guard change.operation == .save,
              change.recordType == SyncWatchStateRecord.cloudRecordType,
              let last = lastWatchStateWriteAt[change.recordName] else {
            return true
        }
        return date.timeIntervalSince(last)
            >= configuration.minimumWatchStateWriteInterval
    }

    private func scheduleBackgroundFlush() {
        guard backgroundFlushTask == nil else {
            return
        }
        backgroundFlushTask = Task { [weak self] in
            guard let self else {
                return
            }
            _ = await self.flushWithRetry()
            await self.clearBackgroundFlush()
        }
    }

    private func clearBackgroundFlush() {
        backgroundFlushTask = nil
    }
}
