import Foundation
import Testing
@testable import SyncKit

// MARK: - Fixtures

private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func watch(
    positionMs: Int64,
    updatedAt: Int64,
    sequence: Int64,
    watched: Bool = false,
    durationMs: Int64? = 2_700_000,
    lastWatchedAt: Int64? = nil,
    trackChoices: [String: String]? = nil
) -> SyncWatchStateRecord {
    SyncWatchStateRecord(
        entityKind: .episode,
        entityRef: "tmdb:1396:s1e5",
        account: "account-a",
        positionMs: positionMs,
        durationMs: durationMs,
        watched: watched,
        lastWatchedAt: lastWatchedAt,
        resumeAt: positionMs,
        trackChoices: trackChoices,
        updatedAt: updatedAt,
        metadata: SyncRecordMetadata(
            clientModTimestamp: updatedAt,
            clientSequence: sequence
        )
    )
}

private func version(
    _ record: SyncWatchStateRecord,
    at seconds: TimeInterval,
    sequence: Int64? = nil
) -> SyncVersion<SyncWatchStateRecord> {
    SyncVersion(
        record,
        serverModifiedAt: date(seconds),
        clientSequence: sequence ?? record.metadata.clientSequence
    )
}

// MARK: - Tests

@Suite("ConflictResolver Tests")
struct ConflictResolverTests {
    private let resolver = ConflictResolver()

    @Test("Newer remote progress wins")
    func remoteNewerProgressWins() {
        let local = watch(positionMs: 10_000, updatedAt: 1_000, sequence: 1)
        let remote = watch(positionMs: 50_000, updatedAt: 2_000, sequence: 2)

        let result = resolver.resolveWatchState(
            local: version(local, at: 1_000),
            remote: version(remote, at: 2_000)
        )

        #expect(result.record.positionMs == 50_000)
        #expect(result.resumePositionMs == 50_000)
        #expect(result.winner == .remote)
        #expect(result.positionSource == .remote)
        #expect(result.didConflict)
        #expect(!result.resetApplied)
        #expect(!result.advancedByOlderCopy)
        #expect(result.note != nil)
    }

    @Test("Newer local progress wins")
    func localNewerProgressWins() {
        let local = watch(positionMs: 80_000, updatedAt: 5_000, sequence: 9)
        let remote = watch(positionMs: 20_000, updatedAt: 4_000, sequence: 2)

        let result = resolver.resolveWatchState(
            local: version(local, at: 5_000),
            remote: version(remote, at: 4_000)
        )

        #expect(result.record.positionMs == 80_000)
        #expect(result.winner == .local)
        #expect(result.positionSource == .local)
    }

    @Test("A newer remote 0:00 reset beats older 99% progress")
    func newerRemoteResetWins() {
        let local = watch(positionMs: 990_000, updatedAt: 1_000, sequence: 1)
        let remote = watch(positionMs: 0, updatedAt: 2_000, sequence: 2)

        let result = resolver.resolveWatchState(
            local: version(local, at: 1_000),
            remote: version(remote, at: 2_000)
        )

        #expect(result.record.positionMs == 0)
        #expect(result.resumePositionMs == 0)
        #expect(result.resetApplied)
        #expect(result.positionSource == .resetOnNewer)
        #expect(result.winner == .remote)
        #expect(result.note?.summary.contains("0:00") == true)
    }

    @Test("A newer local reset beats older remote progress")
    func newerLocalResetWins() {
        let local = watch(positionMs: 0, updatedAt: 9_000, sequence: 12)
        let remote = watch(positionMs: 990_000, updatedAt: 1_000, sequence: 1)

        let result = resolver.resolveWatchState(
            local: version(local, at: 9_000),
            remote: version(remote, at: 1_000)
        )

        #expect(result.record.positionMs == 0)
        #expect(result.resetApplied)
        #expect(result.positionSource == .resetOnNewer)
        #expect(result.winner == .local)
        #expect(result.record.resumeAt == 0)
    }

    @Test("Maximum position is kept when the older copy is farther ahead")
    func olderMaxPositionWins() {
        let local = watch(positionMs: 100_000, updatedAt: 1_000, sequence: 1)
        let remote = watch(positionMs: 30_000, updatedAt: 2_000, sequence: 2)

        let result = resolver.resolveWatchState(
            local: version(local, at: 1_000),
            remote: version(remote, at: 2_000)
        )

        #expect(result.record.positionMs == 100_000)
        #expect(result.resumePositionMs == 100_000)
        #expect(result.advancedByOlderCopy)
        #expect(result.positionSource == .local)
        #expect(result.winner == .merged)
    }

    @Test("Maximum position from a newer local copy beats older remote")
    func newerLocalMaxPositionWins() {
        let local = watch(positionMs: 30_000, updatedAt: 8_000, sequence: 8)
        let remote = watch(positionMs: 100_000, updatedAt: 2_000, sequence: 2)

        let result = resolver.resolveWatchState(
            local: version(local, at: 8_000),
            remote: version(remote, at: 2_000)
        )

        #expect(result.record.positionMs == 100_000)
        #expect(result.positionSource == .remote)
        #expect(result.winner == .merged)
    }

    @Test("Newer scalar fields win while progress is merged")
    func newerScalarsWinOverMergedProgress() {
        let local = watch(
            positionMs: 200_000,
            updatedAt: 1_000,
            sequence: 1,
            watched: false,
            trackChoices: ["audio": "eng"]
        )
        var remote = watch(
            positionMs: 20_000,
            updatedAt: 2_000,
            sequence: 2,
            watched: true,
            lastWatchedAt: 2_000,
            trackChoices: ["audio": "jpn", "subtitle": "off"]
        )
        remote.durationMs = 2_600_000

        let result = resolver.resolveWatchState(
            local: version(local, at: 1_000),
            remote: version(remote, at: 2_000)
        )

        #expect(result.record.positionMs == 200_000)
        #expect(result.record.watched)
        #expect(result.record.durationMs == 2_600_000)
        #expect(result.record.trackChoices?["audio"] == "jpn")
        #expect(result.record.trackChoices?["subtitle"] == "off")
        #expect(result.record.lastWatchedAt == 2_000)
        #expect(result.winner == .merged)
    }

    @Test("Last-watched recency is monotonic")
    func lastWatchedAtIsMax() {
        let local = watch(
            positionMs: 20_000,
            updatedAt: 5_000,
            sequence: 5,
            lastWatchedAt: 9_000
        )
        let remote = watch(
            positionMs: 30_000,
            updatedAt: 4_000,
            sequence: 4,
            lastWatchedAt: 3_000
        )

        let result = resolver.resolveWatchState(
            local: version(local, at: 5_000),
            remote: version(remote, at: 4_000)
        )

        #expect(result.record.lastWatchedAt == 9_000)
        #expect(result.record.updatedAt == 5_000)
        #expect(result.record.metadata.clientSequence == 5)
    }

    @Test("Identical watch states produce no conflict note")
    func identicalWatchStates() {
        let state = watch(positionMs: 42_000, updatedAt: 1_000, sequence: 1)

        let result = resolver.resolveWatchState(
            local: version(state, at: 1_000),
            remote: version(state, at: 2_000)
        )

        #expect(!result.didConflict)
        #expect(result.winner == .local)
        #expect(result.note == nil)
        #expect(result.record == state)
    }

    @Test("Scalar merges are last-writer-wins by server timestamp")
    func scalarLastWriterWins() {
        let local = SyncVersion(
            "theatrical",
            serverModifiedAt: date(100),
            clientSequence: 1
        )
        let remote = SyncVersion(
            "director's cut",
            serverModifiedAt: date(200),
            clientSequence: 2
        )

        let result = resolver.resolveScalar(
            local: local,
            remote: remote,
            recordName: "matchOverride.movie.550"
        )

        #expect(result.value == "director's cut")
        #expect(result.winner == .remote)
        #expect(result.didConflict)
        #expect(result.note?.winner == .remote)
        #expect(result.note?.recordName == "matchOverride.movie.550")
    }

    @Test("Equal server times break ties by client sequence")
    func scalarTieBreaksBySequence() {
        let local = SyncVersion(
            "local",
            serverModifiedAt: date(100),
            clientSequence: 3
        )
        let remote = SyncVersion(
            "remote",
            serverModifiedAt: date(100),
            clientSequence: 8
        )

        let remoteWins = resolver.resolveScalar(
            local: local,
            remote: remote,
            recordName: "library.1"
        )
        #expect(remoteWins.value == "remote")
        #expect(remoteWins.winner == .remote)

        let localWins = resolver.resolveScalar(
            local: SyncVersion(
                "local",
                serverModifiedAt: date(100),
                clientSequence: 9
            ),
            remote: remote,
            recordName: "library.1"
        )
        #expect(localWins.value == "local")
        #expect(localWins.winner == .local)
    }

    @Test("A complete tie keeps the local copy deterministically")
    func completeTieKeepsLocal() {
        let local = SyncVersion(
            "same",
            serverModifiedAt: date(100),
            clientSequence: 4
        )
        let remote = SyncVersion(
            "same",
            serverModifiedAt: date(100),
            clientSequence: 4
        )

        let result = resolver.resolveScalar(
            local: local,
            remote: remote,
            recordName: "pin.1"
        )

        #expect(result.value == "same")
        #expect(result.winner == .local)
        #expect(!result.didConflict)
        #expect(result.note == nil)
    }

    @Test("Cross-device resume exposes the merged position and duration")
    func crossDeviceResume() {
        let local = watch(positionMs: 10_000, updatedAt: 1_000, sequence: 1)
        let remote = watch(
            positionMs: 123_000,
            updatedAt: 2_000,
            sequence: 2,
            watched: false
        )

        let resume = resolver.crossDeviceResume(
            local: version(local, at: 1_000),
            remote: version(remote, at: 2_000)
        )

        #expect(resume.positionMs == 123_000)
        #expect(resume.durationMs == 2_700_000)
        #expect(!resume.watched)
        #expect(resume.updatedAt == 2_000)
        #expect(resume.winner == .remote)
        #expect(resume.resolution.record.entityRef == "tmdb:1396:s1e5")
    }

    @Test("The merged record keeps the highest sequence for re-sync")
    func mergedMetadataIsMonotonic() {
        let local = watch(positionMs: 100_000, updatedAt: 1_000, sequence: 10)
        let remote = watch(positionMs: 20_000, updatedAt: 2_000, sequence: 4)

        let result = resolver.resolveWatchState(
            local: version(local, at: 1_000),
            remote: version(remote, at: 2_000)
        )

        #expect(result.record.metadata.clientSequence == 10)
        #expect(result.record.metadata.clientModTimestamp == 2_000)
    }
}
