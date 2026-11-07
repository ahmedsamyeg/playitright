import Foundation
@preconcurrency import CloudKit

// MARK: - Queued change

/// One durable change waiting to reach CloudKit.
///
/// The queue stores the serialized CloudKit fields rather than a `CKRecord`, so
/// the payload survives app launches and can be validated before upload.
public struct SyncQueuedChange: Codable, Sendable, Equatable, Identifiable {
    public enum Operation: String, Codable, Sendable, Equatable {
        case save
        case delete
    }

    public var recordType: String
    public var recordName: String
    public var operation: Operation
    public var fields: [String: SyncField]
    public var enqueuedAt: Int64
    public var attempts: Int
    public var lastAttemptAt: Int64?
    public var lastError: String?

    /// Stable identity is the record name: the queue coalesces changes per
    /// CloudKit record and keeps only the latest user intent.
    public var id: String { recordName }

    public init(
        recordType: String,
        recordName: String,
        operation: Operation = .save,
        fields: [String: SyncField] = [:],
        enqueuedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        attempts: Int = 0,
        lastAttemptAt: Int64? = nil,
        lastError: String? = nil
    ) {
        self.recordType = recordType
        self.recordName = recordName
        self.operation = operation
        self.fields = fields
        self.enqueuedAt = enqueuedAt
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
    }

    /// Rebuilds the pending `CKRecord` for upload.
    public func makeCloudRecord(
        in zoneID: CKRecordZone.ID
    ) throws -> CKRecord {
        guard operation == .save else {
            throw SyncBoundaryError.malformedRecord(
                "A delete change has no CloudKit payload."
            )
        }
        let record = CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(
                recordName: recordName,
                zoneID: zoneID
            )
        )
        for (key, field) in fields {
            field.apply(to: record, key: key)
        }
        try SyncBoundary.validate(record: record)
        return record
    }
}

// MARK: - Persistence seam

/// Durable storage for the offline delta queue (SYNC-2).
public protocol DeltaQueueStore: Sendable {
    func load() async throws -> [SyncQueuedChange]
    func save(_ changes: [SyncQueuedChange]) async throws
}

/// JSON-file store used by the app. Writes are atomic so a crash cannot leave a
/// half-written queue.
public struct FileDeltaQueueStore: DeltaQueueStore, Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location in Application Support.
    public init(
        directory: URL? = nil,
        fileName: String = "sync-delta-queue.json"
    ) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.fileURL = base
            .appendingPathComponent("PlayItRight", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    public func load() async throws -> [SyncQueuedChange] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            return []
        }
        return try JSONDecoder().decode([SyncQueuedChange].self, from: data)
    }

    public func save(_ changes: [SyncQueuedChange]) async throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(changes)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// In-memory store for tests and for a local-only session.
public actor InMemoryDeltaQueueStore: DeltaQueueStore {
    private var changes: [SyncQueuedChange]

    public init(_ changes: [SyncQueuedChange] = []) {
        self.changes = changes
    }

    public func load() async throws -> [SyncQueuedChange] {
        changes
    }

    public func save(_ changes: [SyncQueuedChange]) async throws {
        self.changes = changes
    }
}

// MARK: - Queue

/// A persistent, coalescing queue of local changes waiting for CloudKit.
///
/// Queuing never blocks the UI: the local index is already updated by the
/// caller, and the queue only records what still needs to be pushed (SYNC-2).
public actor DeltaQueue {
    private let store: any DeltaQueueStore
    private var changes: [SyncQueuedChange] = []
    private var loaded = false

    public init(store: any DeltaQueueStore = InMemoryDeltaQueueStore()) {
        self.store = store
    }

    /// Loads persisted changes once, on first use.
    public func loadIfNeeded() async throws {
        guard !loaded else {
            return
        }
        changes = try await store.load()
        loaded = true
    }

    /// Number of pending records (coalesced).
    public func pendingCount() async throws -> Int {
        try await loadIfNeeded()
        return changes.count
    }

    /// Snapshot of the queue, oldest first.
    public func allChanges() async throws -> [SyncQueuedChange] {
        try await loadIfNeeded()
        return changes
    }

    /// Returns up to `limit` pending changes without removing them.
    public func pendingChanges(limit: Int = 200) async throws -> [SyncQueuedChange] {
        try await loadIfNeeded()
        guard limit > 0 else {
            return []
        }
        return Array(changes.prefix(limit))
    }

    /// Enqueues a sync record. A newer change for the same record replaces the
    /// older one, so an offline session writes each item at most once.
    public func enqueue<R: SyncCloudRecord>(
        _ record: R,
        now: Date = Date()
    ) async throws {
        try record.validateForSync()
        let fields = try record.syncFields()
        try await enqueue(
            SyncQueuedChange(
                recordType: R.cloudRecordType,
                recordName: record.cloudRecordName,
                operation: .save,
                fields: fields,
                enqueuedAt: Int64(now.timeIntervalSince1970 * 1_000)
            )
        )
    }

    /// Enqueues a deletion. A pending save for the same record is replaced, so
    /// a create-then-delete pair never reaches the cloud.
    public func enqueueDelete(
        recordType: String,
        recordName: String,
        now: Date = Date()
    ) async throws {
        try await enqueue(
            SyncQueuedChange(
                recordType: recordType,
                recordName: recordName,
                operation: .delete,
                enqueuedAt: Int64(now.timeIntervalSince1970 * 1_000)
            )
        )
    }

    /// Merges a change into the queue and persists the result.
    public func enqueue(_ change: SyncQueuedChange) async throws {
        try await loadIfNeeded()
        var incoming = change
        if let index = changes.firstIndex(
            where: { $0.recordName == change.recordName }
        ) {
            // Preserve the original enqueue time, but reset retry state because
            // this is fresh user intent rather than a retry of stale content.
            incoming.enqueuedAt = changes[index].enqueuedAt
            incoming.attempts = 0
            incoming.lastAttemptAt = nil
            incoming.lastError = nil
            changes[index] = incoming
        } else {
            changes.append(incoming)
        }
        try await store.save(changes)
    }

    /// Removes successfully uploaded changes.
    public func remove(recordNames: some Sequence<String>) async throws {
        try await loadIfNeeded()
        let names = Set(recordNames)
        guard !names.isEmpty else {
            return
        }
        changes.removeAll { names.contains($0.recordName) }
        try await store.save(changes)
    }

    /// Records a failed attempt for backoff/observability.
    public func markFailed(
        recordNames: some Sequence<String>,
        error: String,
        at date: Date = Date()
    ) async throws {
        try await loadIfNeeded()
        let names = Set(recordNames)
        guard !names.isEmpty else {
            return
        }
        let timestamp = Int64(date.timeIntervalSince1970 * 1_000)
        for index in changes.indices where names.contains(
            changes[index].recordName
        ) {
            changes[index].attempts += 1
            changes[index].lastAttemptAt = timestamp
            changes[index].lastError = error
        }
        try await store.save(changes)
    }

    /// Removes everything (used by "Delete my data", SYNC-5).
    public func removeAll() async throws {
        try await loadIfNeeded()
        changes.removeAll()
        try await store.save(changes)
    }
}
