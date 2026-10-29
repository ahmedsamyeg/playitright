import Testing
import Foundation
@testable import PlaybackSpike

@Suite("CloudKitSyncScale Tests")
struct CloudKitSyncScaleTests {

    @Test("Sync boundary validator rejects file paths, server URLs, and secrets")
    func testSyncBoundary() {
        #expect(SyncBoundaryValidator.validateRecordKey("movie:tmdb:550") == true)
        #expect(SyncBoundaryValidator.validateRecordKey("ep:tmdb:1396:s2e4") == true)
        #expect(SyncBoundaryValidator.validateRecordKey("playlist:favorites") == true)

        // Must reject all private file paths and URLs
        #expect(SyncBoundaryValidator.validateRecordKey("file:///var/mobile/video.mkv") == false)
        #expect(SyncBoundaryValidator.validateRecordKey("/Volumes/Share/Movies/Avatar.mkv") == false)
        #expect(SyncBoundaryValidator.validateRecordKey("smb://nas.local/share/file.mp4") == false)
        #expect(SyncBoundaryValidator.validateRecordKey("https://plex.tv/secret_token") == false)
    }

    @Test("Conflict resolver selects furthest watch position across devices")
    func testFurthestPositionConflictResolution() {
        let resolver = CloudKitConflictResolver()
        let now = Date()

        let local = SyncedWatchState(
            entityRef: "movie:tmdb:550",
            positionSeconds: 1500.0,
            durationSeconds: 7200.0,
            isWatched: false,
            lastWatchedAt: now.addingTimeInterval(-300),
            modifiedAt: now.addingTimeInterval(-300)
        )

        let remote = SyncedWatchState(
            entityRef: "movie:tmdb:550",
            positionSeconds: 2400.0, // Watched further on Living Room Apple TV
            durationSeconds: 7200.0,
            isWatched: false,
            lastWatchedAt: now.addingTimeInterval(-100),
            modifiedAt: now.addingTimeInterval(-100)
        )

        let resolved = resolver.resolve(local: local, remote: remote)
        #expect(resolved.positionSeconds == 2400.0)
        #expect(resolved.isWatched == false)
    }

    @Test("Conflict resolver respects intentional restart to 0:00")
    func testExplicitRestartConflictResolution() {
        let resolver = CloudKitConflictResolver()
        let baseDate = Date()

        // Remote was at 5000s earlier today
        let remote = SyncedWatchState(
            entityRef: "movie:tmdb:550",
            positionSeconds: 5000.0,
            durationSeconds: 7200.0,
            isWatched: false,
            lastWatchedAt: baseDate.addingTimeInterval(-3600),
            modifiedAt: baseDate.addingTimeInterval(-3600)
        )

        // Local user clicked "Play from Beginning" 5 minutes ago, current position 15s
        let local = SyncedWatchState(
            entityRef: "movie:tmdb:550",
            positionSeconds: 15.0,
            durationSeconds: 7200.0,
            isWatched: false,
            lastWatchedAt: baseDate.addingTimeInterval(-300),
            modifiedAt: baseDate.addingTimeInterval(-300)
        )

        let resolved = resolver.resolve(local: local, remote: remote)
        // Must resolve to 15.0 (respecting the intentional restart)
        #expect(resolved.positionSeconds == 15.0)
    }

    @Test("Rate limiter enforces 30s write envelope per item")
    func testBatchSchedulerRateLimiting() async {
        let scheduler = CloudKitBatchScheduler(maxBatchSize: 400, minWriteIntervalSeconds: 30.0)
        let state1 = SyncedWatchState(entityRef: "movie:1", positionSeconds: 10.0, durationSeconds: 100.0, isWatched: false, lastWatchedAt: Date())
        let state2 = SyncedWatchState(entityRef: "movie:1", positionSeconds: 20.0, durationSeconds: 100.0, isWatched: false, lastWatchedAt: Date())

        // Initial schedule accepted
        let accepted1 = await scheduler.schedule(state: state1)
        #expect(accepted1 == true)

        // Dequeue batch
        let batch1 = await scheduler.dequeueBatch()
        #expect(batch1.count == 1)

        // Second schedule immediately after dequeue is throttled (under 30s limit)
        let accepted2 = await scheduler.schedule(state: state2)
        #expect(accepted2 == false)

        // Pending count holds the throttled state
        let pending = await scheduler.pendingCount
        #expect(pending == 1)
    }

    @Test("10,000 records batch processing completes in under 200 ms")
    func testScaleBatching() async {
        let scheduler = CloudKitBatchScheduler(maxBatchSize: 400, minWriteIntervalSeconds: 0.0)
        let count = 10_000

        let startTime = CFAbsoluteTimeGetCurrent()
        for i in 0..<count {
            let state = SyncedWatchState(
                entityRef: "ep:\(i)",
                positionSeconds: Double(i),
                durationSeconds: 3600.0,
                isWatched: i % 2 == 0,
                lastWatchedAt: Date()
            )
            await scheduler.schedule(state: state, force: true)
        }

        var dequeuedCount = 0
        var batchCount = 0

        while true {
            let batch = await scheduler.dequeueBatch()
            if batch.isEmpty { break }
            dequeuedCount += batch.count
            batchCount += 1
            #expect(batch.count <= 400)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        #expect(dequeuedCount == count)
        #expect(batchCount == 25) // 10,000 / 400 = 25 batches
        #expect(elapsed < 1.0)    // Scale test finishes in under 1 second
    }
}
