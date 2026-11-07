import Foundation

// MARK: - Versions

/// One device's copy of a value, tagged with the metadata used to order it.
public struct SyncVersion<Value: Sendable & Equatable>: Sendable, Equatable {
    public var value: Value

    /// CloudKit server modification time. This is the primary ordering key.
    public var serverModifiedAt: Date

    /// Client sequence used as a deterministic tie-breaker.
    public var clientSequence: Int64

    public init(
        _ value: Value,
        serverModifiedAt: Date,
        clientSequence: Int64 = 0
    ) {
        self.value = value
        self.serverModifiedAt = serverModifiedAt
        self.clientSequence = clientSequence
    }
}

extension SyncVersion where Value == SyncWatchStateRecord {
    /// Builds a version from a watch-state record and the server's timestamp.
    public init(
        watchState: SyncWatchStateRecord,
        serverModifiedAt: Date
    ) {
        self.init(
            watchState,
            serverModifiedAt: serverModifiedAt,
            clientSequence: watchState.metadata.clientSequence
        )
    }
}

// MARK: - Conflict reporting

/// Which copy supplied the merged result.
public enum SyncConflictWinner: String, Codable, Sendable, Equatable {
    case local
    case remote
    case merged
}

/// A plain-language note for the "sync notes" list. Conflicts are never silent
/// when they would lose user-visible data (doc 07 §1.2).
public struct SyncConflictNote: Codable, Sendable, Equatable {
    public var recordName: String
    public var winner: SyncConflictWinner
    public var summary: String

    public init(
        recordName: String,
        winner: SyncConflictWinner,
        summary: String
    ) {
        self.recordName = recordName
        self.winner = winner
        self.summary = summary
    }
}

/// The result of a last-writer-wins scalar merge.
public struct ScalarResolution<Value: Sendable & Equatable>: Sendable, Equatable {
    public var value: Value
    public var winner: SyncConflictWinner
    public var didConflict: Bool
    public var note: SyncConflictNote?

    public init(
        value: Value,
        winner: SyncConflictWinner,
        didConflict: Bool,
        note: SyncConflictNote? = nil
    ) {
        self.value = value
        self.winner = winner
        self.didConflict = didConflict
        self.note = note
    }
}

// MARK: - Watch-state merge

/// Where the merged playback position came from.
public enum WatchPositionSource: String, Codable, Sendable, Equatable {
    case local
    case remote
    case resetOnNewer
}

/// Result of merging two watch-state records.
public struct WatchStateResolution: Sendable, Equatable {
    /// The merged record to write to the local index and enqueue for sync.
    public var record: SyncWatchStateRecord

    /// Which device supplied the winning scalar fields.
    public var winner: SyncConflictWinner

    /// True when positions or other user-visible fields differed.
    public var didConflict: Bool

    /// Source of the merged `positionMs`.
    public var positionSource: WatchPositionSource

    /// True when a newer position of zero intentionally reset progress.
    public var resetApplied: Bool

    /// True when progress was advanced by the older copy (max rule).
    public var advancedByOlderCopy: Bool

    /// Note for the sync-notes list, when the copies differed.
    public var note: SyncConflictNote?

    public init(
        record: SyncWatchStateRecord,
        winner: SyncConflictWinner,
        didConflict: Bool,
        positionSource: WatchPositionSource,
        resetApplied: Bool,
        advancedByOlderCopy: Bool,
        note: SyncConflictNote? = nil
    ) {
        self.record = record
        self.winner = winner
        self.didConflict = didConflict
        self.positionSource = positionSource
        self.resetApplied = resetApplied
        self.advancedByOlderCopy = advancedByOlderCopy
        self.note = note
    }

    /// Cross-device resume point in milliseconds.
    public var resumePositionMs: Int64 {
        record.positionMs
    }
}

/// A resume decision that can be applied on a second Apple TV.
public struct CrossDeviceResume: Sendable, Equatable {
    public var positionMs: Int64
    public var durationMs: Int64?
    public var watched: Bool
    public var updatedAt: Int64
    public var winner: SyncConflictWinner
    public var resolution: WatchStateResolution

    public init(resolution: WatchStateResolution) {
        self.positionMs = resolution.record.positionMs
        self.durationMs = resolution.record.durationMs
        self.watched = resolution.record.watched
        self.updatedAt = resolution.record.updatedAt
        self.winner = resolution.winner
        self.resolution = resolution
    }
}

// MARK: - Resolver

/// Deterministic merge rules from doc 07 §1.2.
///
/// Scalars use last-writer-wins by server timestamp, with the client sequence
/// as a tie-breaker. Watch progress normally takes the maximum position, except
/// that a newer record at 0:00 is treated as an intentional reset.
public struct ConflictResolver: Sendable {
    public init() {}

    /// Resolves any scalar value with last-writer-wins semantics.
    public func resolveScalar<Value: Sendable & Equatable>(
        local: SyncVersion<Value>,
        remote: SyncVersion<Value>,
        recordName: String
    ) -> ScalarResolution<Value> {
        let remoteIsNewer = isRemoteNewer(local: local, remote: remote)
        let didConflict = local.value != remote.value

        let winner: SyncConflictWinner
        let value: Value
        if didConflict {
            winner = remoteIsNewer ? .remote : .local
            value = remoteIsNewer ? remote.value : local.value
        } else {
            winner = .local
            value = local.value
        }

        let note = didConflict
            ? SyncConflictNote(
                recordName: recordName,
                winner: winner,
                summary: winner == .remote
                    ? "The other device's newer value was kept."
                    : "This device's newer value was kept."
            )
            : nil

        return ScalarResolution(
            value: value,
            winner: winner,
            didConflict: didConflict,
            note: note
        )
    }

    /// Merges two copies of the same watch-state record.
    public func resolveWatchState(
        local: SyncVersion<SyncWatchStateRecord>,
        remote: SyncVersion<SyncWatchStateRecord>
    ) -> WatchStateResolution {
        let remoteIsNewer = isRemoteNewer(local: local, remote: remote)
        let newer = remoteIsNewer ? remote.value : local.value
        let older = remoteIsNewer ? local.value : remote.value
        let newerSide: SyncConflictWinner = remoteIsNewer ? .remote : .local
        let olderSide: SyncConflictWinner = remoteIsNewer ? .local : .remote

        var merged = newer
        let didConflict = local.value != remote.value

        // Position: the normal rule is max(position). The recency guard lets a
        // newer 0:00 reset beat an older 99% position.
        var resetApplied = false
        var advancedByOlderCopy = false
        var positionSource: WatchPositionSource = remoteIsNewer
            ? .remote
            : .local

        if newer.positionMs == 0 && older.positionMs > 0 {
            merged.positionMs = 0
            merged.resumeAt = 0
            resetApplied = true
            positionSource = .resetOnNewer
        } else if older.positionMs > newer.positionMs {
            merged.positionMs = older.positionMs
            merged.resumeAt = older.resumeAt ?? older.positionMs
            advancedByOlderCopy = true
            positionSource = olderSide == .remote ? .remote : .local
        }

        // Duration and recency metadata are monotonic.
        merged.durationMs = newer.durationMs ?? older.durationMs
        merged.lastWatchedAt = max(
            local.value.lastWatchedAt ?? Int64.min,
            remote.value.lastWatchedAt ?? Int64.min
        )
        if merged.lastWatchedAt == Int64.min {
            merged.lastWatchedAt = nil
        }
        merged.updatedAt = max(local.value.updatedAt, remote.value.updatedAt)

        // Keep the highest client sequence so the merged value can be pushed
        // again without looking stale to another device.
        merged.metadata = SyncRecordMetadata(
            clientModTimestamp: max(
                local.value.metadata.clientModTimestamp,
                remote.value.metadata.clientModTimestamp
            ),
            clientSequence: max(
                local.value.metadata.clientSequence,
                remote.value.metadata.clientSequence
            )
        )

        let winner: SyncConflictWinner
        if !didConflict {
            winner = .local
        } else if advancedByOlderCopy {
            winner = .merged
        } else {
            winner = newerSide
        }

        let note = didConflict
            ? SyncConflictNote(
                recordName: merged.cloudRecordName,
                winner: winner,
                summary: conflictSummary(
                    resetApplied: resetApplied,
                    advancedByOlderCopy: advancedByOlderCopy,
                    newerSide: newerSide
                )
            )
            : nil

        return WatchStateResolution(
            record: merged,
            winner: winner,
            didConflict: didConflict,
            positionSource: positionSource,
            resetApplied: resetApplied,
            advancedByOlderCopy: advancedByOlderCopy,
            note: note
        )
    }

    /// Produces the cross-Apple-TV resume point for two watch-state copies.
    public func crossDeviceResume(
        local: SyncVersion<SyncWatchStateRecord>,
        remote: SyncVersion<SyncWatchStateRecord>
    ) -> CrossDeviceResume {
        CrossDeviceResume(
            resolution: resolveWatchState(local: local, remote: remote)
        )
    }

    // MARK: Ordering

    /// Returns true when the remote copy should win scalar fields.
    ///
    /// Server time is primary. Equal times fall back to the higher client
    /// sequence, and a complete tie keeps the local copy for determinism.
    public func isRemoteNewer<Value: Sendable & Equatable>(
        local: SyncVersion<Value>,
        remote: SyncVersion<Value>
    ) -> Bool {
        if remote.serverModifiedAt != local.serverModifiedAt {
            return remote.serverModifiedAt > local.serverModifiedAt
        }
        return remote.clientSequence > local.clientSequence
    }

    private func conflictSummary(
        resetApplied: Bool,
        advancedByOlderCopy: Bool,
        newerSide: SyncConflictWinner
    ) -> String {
        if resetApplied {
            return "A newer 0:00 reset replaced older progress."
        }
        if advancedByOlderCopy {
            return "Older progress was farther ahead and was kept."
        }
        return newerSide == .remote
            ? "The other device's newer watch state was kept."
            : "This device's newer watch state was kept."
    }
}
