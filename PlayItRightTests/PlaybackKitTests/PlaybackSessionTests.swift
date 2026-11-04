import Foundation
import GRDB
import LibraryCore
import SourceAdapters
import Testing
@testable import PlaybackKit

// MARK: - Fakes

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000)) {
        self.current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private struct PersistenceWrite: Sendable, Equatable {
    var account: String
    var entityKind: EntityKind
    var entityRef: String
    var positionMs: Int64
    var durationMs: Int64?
    var watched: Bool
}

private final class RecordingPersistence: WatchStatePersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var storedWrites: [PersistenceWrite] = []

    var writes: [PersistenceWrite] {
        lock.lock()
        defer { lock.unlock() }
        return storedWrites
    }

    func updateWatchProgress(
        account: String,
        entityKind: EntityKind,
        entityRef: String,
        positionMs: Int64,
        durationMs: Int64?,
        watched: Bool
    ) throws {
        lock.lock()
        storedWrites.append(
            PersistenceWrite(
                account: account,
                entityKind: entityKind,
                entityRef: entityRef,
                positionMs: positionMs,
                durationMs: durationMs,
                watched: watched
            )
        )
        lock.unlock()
    }
}

private final class WatchStateAdapter: SourceAdapter, @unchecked Sendable {
    let kind: SourceAdapters.SourceKind = .plex

    private let lock = NSLock()
    private var storedPushes: [SourceWatchState] = []

    var pushes: [SourceWatchState] {
        withLock { storedPushes }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func connect(config: SourceConfig) async throws -> SourceSession {
        SourceSession(sourceID: config.id)
    }

    func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        ItemStream { continuation in
            continuation.finish()
        }
    }

    func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func pushWatchState(
        session: SourceSession,
        item: SourceItem,
        state: SourceWatchState
    ) async throws {
        withLock { storedPushes.append(state) }
    }
}

private func makeConfiguration(
    duration: TimeInterval? = 100,
    autoFlush: Bool = false
) -> PlaybackSessionConfiguration {
    PlaybackSessionConfiguration(
        account: "account",
        entityKind: .movie,
        entityRef: "movie-1",
        duration: duration,
        autoFlush: autoFlush
    )
}

// MARK: - Tests

@MainActor
@Suite("PlaybackSession Tests")
struct PlaybackSessionTests {
    @Test("Watching 90% marks the item watched")
    func watchedAtNinetyPercent() {
        let persistence = RecordingPersistence()
        let session = PlaybackSession(
            configuration: makeConfiguration(),
            persistence: persistence
        )

        session.play()
        session.updateProgress(90)
        #expect(session.progress.isWatched)
        #expect(abs(session.progress.fraction - 0.9) < 0.000_1)

        session.flush()
        let write = persistence.writes.last
        #expect(write?.watched == true)
        #expect(write?.positionMs == 90_000)
        #expect(write?.durationMs == 100_000)
    }

    @Test("Watching 4% keeps the item unwatched")
    func unwatchedAtFourPercent() {
        let persistence = RecordingPersistence()
        let session = PlaybackSession(
            configuration: makeConfiguration(),
            persistence: persistence
        )

        session.play()
        session.updateProgress(4)
        #expect(!session.progress.isWatched)
        #expect(abs(session.progress.fraction - 0.04) < 0.000_1)

        session.flush()
        #expect(persistence.writes.last?.watched == false)
        #expect(persistence.writes.last?.positionMs == 4_000)
    }

    @Test("Finishing marks the item watched at full duration")
    func finishingMarksWatched() {
        let persistence = RecordingPersistence()
        let session = PlaybackSession(
            configuration: makeConfiguration(),
            persistence: persistence
        )

        session.play()
        session.updateProgress(12)
        session.finish()

        #expect(session.state == .ended)
        #expect(session.progress.position == 100)
        #expect(session.progress.isWatched)
        #expect(persistence.writes.last?.watched == true)
    }

    @Test("Progress flushes to the database every ten seconds")
    func tenSecondFlushSchedule() {
        let clock = TestClock()
        let persistence = RecordingPersistence()
        let session = PlaybackSession(
            configuration: makeConfiguration(autoFlush: false),
            persistence: persistence,
            now: { clock.now }
        )

        session.play()
        session.updateProgress(10)
        #expect(persistence.writes.isEmpty)

        clock.advance(9)
        session.updateProgress(19)
        #expect(persistence.writes.isEmpty)

        clock.advance(1.5)
        session.updateProgress(20.5)
        #expect(persistence.writes.count == 1)
        #expect(persistence.writes.first?.positionMs == 20_500)

        clock.advance(4)
        session.updateProgress(24.5)
        #expect(persistence.writes.count == 1)

        clock.advance(6)
        session.updateProgress(30.5)
        #expect(persistence.writes.count == 2)
    }

    @Test("Suspending flushes the latest progress immediately")
    func suspensionFlushes() {
        let clock = TestClock()
        let persistence = RecordingPersistence()
        let session = PlaybackSession(
            configuration: makeConfiguration(autoFlush: false),
            persistence: persistence,
            now: { clock.now }
        )

        session.play()
        clock.advance(3)
        session.updateProgress(3.25)
        #expect(persistence.writes.isEmpty)

        session.suspend()
        #expect(persistence.writes.count == 1)
        #expect(persistence.writes.first?.positionMs == 3_250)
    }

    @Test("The ten-second flush writes a watch_state row")
    func databaseFlush() throws {
        let database = try MediaDatabase.inMemory()
        let writer = MediaDatabaseWriter(database: database)
        try database.write { db in
            try AccountRecord(accountId: "account", displayName: "User").insert(db)
        }
        let clock = TestClock()
        let session = PlaybackSession(
            configuration: makeConfiguration(autoFlush: false),
            persistence: writer,
            now: { clock.now }
        )

        session.play()
        session.updateProgress(42)
        clock.advance(10)
        session.updateProgress(43)

        let record = try database.read { db in
            try WatchStateRecord
                .filter(WatchStateRecord.Columns.entityRef == "movie-1")
                .fetchOne(db)
        }
        let unwrapped = try #require(record)
        #expect(unwrapped.entityKind == .movie)
        #expect(unwrapped.positionMs == 43_000)
        #expect(unwrapped.durationMs == 100_000)
        #expect(!unwrapped.watched)
    }

    @Test("Drift inside the deadband leaves the audio rate untouched")
    func driftDeadband() {
        var corrector = AVDriftCorrector()
        let sample = corrector.sample(videoTime: 10, audioTime: 10.003)

        #expect(!sample.requiresResync)
        #expect(sample.audioStretchRate == 1)
        #expect(abs(sample.drift - 0.003) < 0.000_1)
    }

    @Test("Audio ahead is slowed and audio behind is sped up gently")
    func gentleDriftCorrection() {
        var corrector = AVDriftCorrector()

        let ahead = corrector.sample(videoTime: 10, audioTime: 10.030)
        #expect(ahead.requiresResync == false)
        #expect(ahead.audioStretchRate < 1)
        #expect(ahead.audioStretchRate >= 0.98)
        #expect(abs(ahead.residualDrift) < abs(ahead.drift))
        #expect(abs(ahead.residualDrift) <= 0.04)

        let behind = corrector.sample(videoTime: 10, audioTime: 9.970)
        #expect(behind.audioStretchRate > 1)
        #expect(behind.audioStretchRate <= 1.02)
        #expect(abs(behind.residualDrift) < abs(behind.drift))
    }

    @Test("A large jump is capped and requests a resync")
    func largeDriftRequiresResync() {
        var corrector = AVDriftCorrector()
        let sample = corrector.sample(videoTime: 10, audioTime: 10.500)

        #expect(sample.requiresResync)
        #expect(abs(sample.audioStretchRate - 1) <= 0.02 + 1e-9)
        #expect(sample.absoluteDrift == 0.5)
    }

    @Test("The session exposes the current drift correction")
    func sessionDrift() {
        let session = PlaybackSession(
            configuration: makeConfiguration(autoFlush: false)
        )

        let inSync = session.measureDrift(videoTime: 1, audioTime: 1)
        #expect(inSync.audioStretchRate == 1)
        #expect(session.audioStretchRate == 1)

        let ahead = session.measureDrift(videoTime: 1, audioTime: 1.030)
        #expect(ahead.drift > 0)
        #expect(session.audioStretchRate < 1)
        #expect(session.lastDrift == ahead)
    }

    @Test("Progress is pushed to the source adapter")
    func sourcePush() async {
        let adapter = WatchStateAdapter()
        let sourceID = UUID()
        let sourceSession = SourceSession(sourceID: sourceID)
        let item = SourceItem(
            id: "item-1",
            sourceID: sourceID,
            kind: .movie,
            name: "Movie",
            location: "/movies/movie.mkv"
        )
        let session = PlaybackSession(
            configuration: makeConfiguration(autoFlush: false),
            adapter: adapter,
            session: sourceSession,
            item: item
        )

        session.play()
        session.updateProgress(55)
        await session.pushToSource()

        let pushed = adapter.pushes.first
        #expect(adapter.pushes.count == 1)
        #expect(pushed?.position == 55)
        #expect(pushed?.duration == 100)
        #expect(pushed?.isWatched == false)
    }

    @Test("Watch state is available in memory before any flush")
    func inMemoryState() {
        let persistence = RecordingPersistence()
        let session = PlaybackSession(
            configuration: makeConfiguration(autoFlush: false),
            persistence: persistence
        )

        session.updateProgress(12.5)
        #expect(session.reporter.state?.position == 12.5)
        #expect(persistence.writes.isEmpty)
    }
}
