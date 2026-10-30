import Foundation

/// Item watch-state mutation to sync back to the server (SRC-20).
public struct WatchStateMutation: Equatable, Sendable {
    public let sourceId: String
    public let itemKey: String
    public let positionSeconds: Double
    public let durationSeconds: Double
    public let isWatched: Bool
    public let timestamp: Date

    public init(
        sourceId: String,
        itemKey: String,
        positionSeconds: Double,
        durationSeconds: Double,
        isWatched: Bool,
        timestamp: Date = Date()
    ) {
        self.sourceId = sourceId
        self.itemKey = itemKey
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.isWatched = isWatched
        self.timestamp = timestamp
    }
}

/// Actor managing offline queueing and coalescing of watch-state mutations (SRC-20, SYNC-3).
public actor OfflineMutationQueue {

    public typealias MutationSender = @Sendable (WatchStateMutation) async throws -> Void

    private var pendingMutations: [String: WatchStateMutation] = [:] // Keyed by itemKey for automatic coalescing
    private var insertionOrder: [String] = []

    public init() {}

    /// Enqueues or coalesces a watch-state mutation.
    public func enqueue(_ mutation: WatchStateMutation) {
        if pendingMutations[mutation.itemKey] == nil {
            insertionOrder.append(mutation.itemKey)
        }
        // Always store latest mutation (coalescing rapid 10s progress updates)
        pendingMutations[mutation.itemKey] = mutation
    }

    /// Number of pending mutations in the queue.
    public var pendingCount: Int {
        pendingMutations.count
    }

    /// Flushes queued mutations using the supplied sender.
    /// Successfully sent mutations are removed from the queue.
    public func flush(using sender: MutationSender) async -> (succeeded: Int, failed: Int) {
        var succeeded = 0
        var failed = 0
        var remainingKeys: [String] = []

        for key in insertionOrder {
            guard let mutation = pendingMutations[key] else { continue }
            do {
                try await sender(mutation)
                pendingMutations.removeValue(forKey: key)
                succeeded += 1
            } catch {
                failed += 1
                remainingKeys.append(key)
            }
        }

        self.insertionOrder = remainingKeys
        return (succeeded, failed)
    }

    /// Clears the queue.
    public func clear() {
        pendingMutations.removeAll()
        insertionOrder.removeAll()
    }
}
