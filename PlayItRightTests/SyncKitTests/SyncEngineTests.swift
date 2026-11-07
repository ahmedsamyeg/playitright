import Foundation
import Synchronization
import Testing
@testable import SyncKit
@preconcurrency import CloudKit

// MARK: - Fakes

private enum MockCloudError: Error, Equatable {
    case unavailable
}

/// Reachability fake with a controllable online flag and update stream.
private final class MockReachability: SyncReachability, @unchecked Sendable {
    private struct State {
        var online: Bool
        var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(online: Bool) {
        self.state = Mutex(State(online: online))
    }

    var isOnline: Bool {
        state.withLock { $0.online }
    }

    func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            let current = state.withLock { state -> Bool in
                state.continuations[id] = continuation
                return state.online
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    func setOnline(_ online: Bool) {
        let continuations = state.withLock {
            state -> [AsyncStream<Bool>.Continuation] in
            state.online = online
            return Array(state.continuations.values)
        }
        for continuation in continuations {
            continuation.yield(online)
        }
    }

    private func remove(_ id: UUID) {
        _ = state.withLock { $0.continuations.removeValue(forKey: id) }
    }
}

/// In-memory CloudKit database with an optional number of injected failures.
private final class RecordingCloudKitDatabase: CloudKitDatabase, @unchecked Sendable {
    private struct State {
        var zones: [CKRecordZone.ID: CKRecordZone] = [:]
        var records: [CKRecord.ID: CKRecord] = [:]
        var deletedRecordNames: [String] = []
        var saveAttempts = 0
        var failuresRemaining = 0
    }

    private let state: Mutex<State>

    init(failures: Int = 0) {
        self.state = Mutex(State(failuresRemaining: failures))
    }

    func save(zone: CKRecordZone) async throws -> CKRecordZone {
        state.withLock { state in
            state.zones[zone.zoneID] = zone
            return zone
        }
    }

    func save(record: CKRecord) async throws -> CKRecord {
        try state.withLock { state in
            state.saveAttempts += 1
            if state.failuresRemaining > 0 {
                state.failuresRemaining -= 1
                throw MockCloudError.unavailable
            }
            state.records[record.recordID] = record
            return record
        }
    }

    func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        state.withLock { $0.records[id] }
    }

    func fetchRecords(
        zoneID: CKRecordZone.ID,
        recordType: String
    ) async throws -> [CKRecord] {
        state.withLock { state in
            state.records.values
                .filter {
                    $0.recordID.zoneID == zoneID
                        && $0.recordType == recordType
                }
                .sorted { $0.recordID.recordName < $1.recordID.recordName }
        }
    }

    func deleteRecord(id: CKRecord.ID) async throws {
        state.withLock { state in
            state.records.removeValue(forKey: id)
            state.deletedRecordNames.append(id.recordName)
        }
    }

    var recordCount: Int {
        state.withLock { $0.records.count }
    }

    var saveAttempts: Int {
        state.withLock { $0.saveAttempts }
    }

    var deletedRecordNames: [String] {
        state.withLock { $0.deletedRecordNames }
    }

    func record(named name: String) -> CKRecord? {
        state.withLock { state in
            state.records.values.first { $0.recordID.recordName == name }
        }
    }
}

/// Mutable clock for deterministic batching tests.
private final class MutableClock: @unchecked Sendable {
    private let date: Mutex<Date>

    init(_ value: Date) {
        self.date = Mutex(value)
    }

    func now() -> Date {
        date.withLock { $0 }
    }

    func advance(_ seconds: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Records retry delays instead of sleeping.
private final class SleepRecorder: @unchecked Sendable {
    private let delays = Mutex<[TimeInterval]>([])

    func sleep(_ seconds: TimeInterval) async throws {
        delays.withLock { $0.append(seconds) }
    }

    var recorded: [TimeInterval] {
        delays.withLock { $0 }
    }
}

// MARK: - Fixtures

private func watchState(
    ref: String = "tmdb:1396:s1e5",
    positionMs: Int64 = 60_000
) -> SyncWatchStateRecord {
    SyncWatchStateRecord(
        entityKind: .episode,
        entityRef: ref,
        account: "account-a",
        positionMs: positionMs,
        durationMs: 2_700_000,
        lastWatchedAt: 1_700_000_000_000,
        updatedAt: 1_700_000_000_000,
        metadata: SyncRecordMetadata(
            clientModTimestamp: 1_700_000_000_000,
            clientSequence: 1
        )
    )
}

private func collection() -> SyncCollectionRecord {
    SyncCollectionRecord(
        id: "collection-1",
        name: "Watchlist",
        order: 1,
        members: [
            SyncMediaReference(canonicalID: "tmdb:1396"),
            SyncMediaReference(
                sourceHandle: SyncSourceHandle(kind: .plex, id: "source-1"),
                fileStableID: "file-42"
            )
        ],
        updatedAt: 1_700_000_000_000,
        metadata: SyncRecordMetadata(
            clientModTimestamp: 1_700_000_000_000,
            clientSequence: 2
        )
    )
}

private struct EngineHarness {
    let engine: SyncEngine
    let database: RecordingCloudKitDatabase
    let reachability: MockReachability
    let clock: MutableClock
}

private func makeHarness(
    online: Bool,
    failures: Int = 0,
    configuration: SyncEngineConfiguration = SyncEngineConfiguration(
        autoFlushOnEnqueue: false
    ),
    store: any DeltaQueueStore = InMemoryDeltaQueueStore(),
    sleeper: SleepRecorder? = nil,
    start: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> EngineHarness {
    let database = RecordingCloudKitDatabase(failures: failures)
    let reachability = MockReachability(online: online)
    let clock = MutableClock(start)
    let queue = DeltaQueue(store: store)
    let manager = CloudKitZoneManager(database: database)

    let sleep: @Sendable (TimeInterval) async throws -> Void
    if let sleeper {
        sleep = { seconds in try await sleeper.sleep(seconds) }
    } else {
        sleep = { seconds in
            try await Task.sleep(
                nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
            )
        }
    }

    let engine = SyncEngine(
        zoneManager: manager,
        queue: queue,
        reachability: reachability,
        configuration: configuration,
        now: { clock.now() },
        sleep: sleep,
        randomUnit: { 0 }
    )
    return EngineHarness(
        engine: engine,
        database: database,
        reachability: reachability,
        clock: clock
    )
}

// MARK: - Tests

@Suite("SyncEngine Tests")
struct SyncEngineTests {
    @Test("Offline writes accumulate and flush when the network returns")
    func offlineWritesFlushOnReconnect() async throws {
        let harness = makeHarness(online: false)
        let first = watchState()
        var second = watchState(ref: "tmdb:1396:s1e6", positionMs: 0)
        second.metadata.clientSequence = 2
        let list = collection()

        try await harness.engine.enqueue(first)
        try await harness.engine.enqueue(second)
        try await harness.engine.enqueue(list)

        let queued = try await harness.engine.pendingCount()
        #expect(queued == 3)
        #expect(harness.database.recordCount == 0)

        let offline = try await harness.engine.flush()
        #expect(offline.isOffline)
        #expect(offline.pending == 3)
        #expect(harness.database.recordCount == 0)

        harness.reachability.setOnline(true)
        let online = try await harness.engine.flush()

        #expect(online.uploaded == 3)
        #expect(online.deleted == 0)
        #expect(online.pending == 0)
        #expect(harness.database.recordCount == 3)
        #expect(
            harness.database.record(named: first.cloudRecordName) != nil
        )
        #expect(
            harness.database.record(named: list.cloudRecordName) != nil
        )

        let remaining = try await harness.engine.pendingCount()
        #expect(remaining == 0)
    }

    @Test("Watch-state writes respect the one-write-per-30s envelope")
    func watchStateBatchingEnvelope() async throws {
        let harness = makeHarness(
            online: true,
            configuration: SyncEngineConfiguration(
                minimumWatchStateWriteInterval: 30,
                autoFlushOnEnqueue: false
            )
        )

        var state = watchState(positionMs: 10_000)
        try await harness.engine.enqueue(state)
        let first = try await harness.engine.flush()
        #expect(first.uploaded == 1)
        #expect(first.pending == 0)

        state.positionMs = 20_000
        try await harness.engine.enqueue(state)
        let immediate = try await harness.engine.flush()
        #expect(immediate.uploaded == 0)
        #expect(immediate.pending == 1)

        harness.clock.advance(29)
        let tooSoon = try await harness.engine.flush()
        #expect(tooSoon.uploaded == 0)
        #expect(tooSoon.pending == 1)

        harness.clock.advance(2)
        let released = try await harness.engine.flush()
        #expect(released.uploaded == 1)
        #expect(released.pending == 0)

        let stored = try #require(
            harness.database.record(named: state.cloudRecordName)
        )
        #expect((stored["positionMs"] as? NSNumber)?.int64Value == 20_000)
    }

    @Test("Non-watch-state records are not throttled")
    func otherRecordTypesAreNotThrottled() async throws {
        let harness = makeHarness(
            online: true,
            configuration: SyncEngineConfiguration(
                minimumWatchStateWriteInterval: 30,
                autoFlushOnEnqueue: false
            )
        )

        try await harness.engine.enqueue(watchState())
        _ = try await harness.engine.flush()

        let list = collection()
        try await harness.engine.enqueue(list)
        try await harness.engine.enqueue(list)
        let result = try await harness.engine.flush()
        #expect(result.uploaded == 1)
        #expect(result.pending == 0)
    }

    @Test("The queue coalesces repeated edits to one item")
    func queueCoalescesChanges() async throws {
        let harness = makeHarness(online: false)

        var state = watchState(positionMs: 1_000)
        try await harness.engine.enqueue(state)
        state.positionMs = 2_000
        try await harness.engine.enqueue(state)

        let pending = try await harness.engine.pendingCount()
        #expect(pending == 1)

        let changes = try await harness.engine.queue.allChanges()
        let change = try #require(changes.first)
        #expect(change.recordName == state.cloudRecordName)
        #expect(change.fields["positionMs"] == .int(2_000))
        #expect(change.attempts == 0)
    }

    @Test("A create followed by a delete never uploads the record")
    func createThenDeleteCoalesces() async throws {
        let harness = makeHarness(online: false)
        let state = watchState()

        try await harness.engine.enqueue(state)
        try await harness.engine.enqueueDelete(
            recordType: SyncWatchStateRecord.cloudRecordType,
            recordName: state.cloudRecordName
        )

        let changes = try await harness.engine.queue.allChanges()
        #expect(changes.count == 1)
        #expect(changes.first?.operation == .delete)
    }

    @Test("Deletes drain through the queue")
    func deleteFlushes() async throws {
        let harness = makeHarness(online: true)
        let recordName = "pin.some-record"

        try await harness.engine.enqueueDelete(
            recordType: "pin",
            recordName: recordName
        )
        let result = try await harness.engine.flush()

        #expect(result.deleted == 1)
        #expect(result.pending == 0)
        #expect(harness.database.deletedRecordNames == [recordName])
    }

    @Test("Pending changes survive a relaunch")
    func persistenceSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("queue.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let firstStore = FileDeltaQueueStore(fileURL: fileURL)
        let first = makeHarness(online: false, store: firstStore)
        try await first.engine.enqueue(watchState(positionMs: 5_000))
        let firstPending = try await first.engine.pendingCount()
        #expect(firstPending == 1)

        let secondStore = FileDeltaQueueStore(fileURL: fileURL)
        let second = makeHarness(online: true, store: secondStore)
        let restored = try await second.engine.pendingCount()
        #expect(restored == 1)

        let result = try await second.engine.flush()
        #expect(result.uploaded == 1)
        #expect(second.database.recordCount == 1)
    }

    @Test("Failures retry with exponential backoff")
    func exponentialBackoff() async throws {
        let sleeper = SleepRecorder()
        let harness = makeHarness(
            online: true,
            failures: 3,
            configuration: SyncEngineConfiguration(
                maxAttempts: 5,
                baseRetryDelay: 1,
                maxRetryDelay: 300,
                jitterFraction: 0,
                autoFlushOnEnqueue: false
            ),
            sleeper: sleeper
        )

        try await harness.engine.enqueue(watchState())
        let result = await harness.engine.flushWithRetry()

        #expect(result.uploaded == 1)
        #expect(result.pending == 0)
        #expect(sleeper.recorded == [1, 2, 4])
        #expect(harness.database.saveAttempts == 4)
        #expect(harness.database.recordCount == 1)
    }

    @Test("Exhausted retries leave the change queued")
    func exhaustedRetriesKeepQueue() async throws {
        let sleeper = SleepRecorder()
        let harness = makeHarness(
            online: true,
            failures: 10,
            configuration: SyncEngineConfiguration(
                maxAttempts: 3,
                baseRetryDelay: 0.5,
                maxRetryDelay: 60,
                jitterFraction: 0,
                autoFlushOnEnqueue: false
            ),
            sleeper: sleeper
        )

        try await harness.engine.enqueue(watchState())
        let result = await harness.engine.flushWithRetry()

        #expect(result.uploaded == 0)
        #expect(result.pending == 1)
        #expect(sleeper.recorded == [0.5, 1])
        #expect(harness.database.saveAttempts == 3)

        let changes = try await harness.engine.queue.allChanges()
        #expect(changes.first?.attempts == 3)
        #expect(changes.first?.lastError != nil)

        let status = try await harness.engine.status()
        #expect(status.pendingCount == 1)
        #expect(status.isOnline)
        #expect(status.lastError != nil)
    }

    @Test("Reconnect listener drains automatically")
    func reconnectListenerDrains() async throws {
        let harness = makeHarness(online: false)
        await harness.engine.start()
        try await harness.engine.enqueue(watchState())

        harness.reachability.setOnline(true)

        var uploaded = false
        for _ in 0..<500 {
            if harness.database.recordCount == 1 {
                uploaded = true
                break
            }
            await Task.yield()
        }

        #expect(uploaded)
        let pending = try await harness.engine.pendingCount()
        #expect(pending == 0)
        await harness.engine.stop()
    }
}
