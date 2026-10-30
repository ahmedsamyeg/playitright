import Foundation

/// Schedules and batches sync records adhering to CloudKit request quotas and rate limits (SYNC-2).
public actor CloudKitBatchScheduler {

    public let maxBatchSize: Int
    public let minWriteIntervalSeconds: Double

    private var pendingItems: [String: SyncedWatchState] = [:]
    private var lastWriteTimestamps: [String: Date] = [:]

    public init(
        maxBatchSize: Int = 400,
        minWriteIntervalSeconds: Double = 30.0
    ) {
        self.maxBatchSize = maxBatchSize
        self.minWriteIntervalSeconds = minWriteIntervalSeconds
    }

    /// Enqueues a watch state update, respecting the 30-second rate-limiting envelope during playback.
    /// Returns true if accepted for immediate/next batch, false if throttled.
    @discardableResult
    public func schedule(state: SyncedWatchState, force: Bool = false) -> Bool {
        let now = Date()
        if !force, let lastWrite = lastWriteTimestamps[state.entityRef] {
            if now.timeIntervalSince(lastWrite) < minWriteIntervalSeconds {
                // Rate limited: update the pending state so the latest position is ready when interval expires
                pendingItems[state.entityRef] = state
                return false
            }
        }

        pendingItems[state.entityRef] = state
        return true
    }

    /// Prepares the next batch of records up to `maxBatchSize`.
    public func dequeueBatch() -> [SyncedWatchState] {
        let batchKeys = Array(pendingItems.keys.prefix(maxBatchSize))
        var batch: [SyncedWatchState] = []
        let now = Date()

        for key in batchKeys {
            if let item = pendingItems.removeValue(forKey: key) {
                batch.append(item)
                lastWriteTimestamps[key] = now
            }
        }
        return batch
    }

    /// Number of items awaiting sync.
    public var pendingCount: Int {
        pendingItems.count
    }
}
