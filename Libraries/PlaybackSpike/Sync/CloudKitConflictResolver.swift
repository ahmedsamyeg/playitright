import Foundation

/// Conflict resolver for concurrent multi-device sync operations (SYNC-2, SYNC-4).
public struct CloudKitConflictResolver: Sendable {

    public init() {}

    /// Merges local and remote watch states using deterministic rules.
    public func resolve(local: SyncedWatchState, remote: SyncedWatchState) -> SyncedWatchState {
        // Rule 1: Watched status priority
        if local.isWatched && remote.isWatched {
            let latestWatched = max(local.lastWatchedAt, remote.lastWatchedAt)
            let latestModified = max(local.modifiedAt, remote.modifiedAt)
            return SyncedWatchState(
                entityRef: local.entityRef,
                positionSeconds: max(local.positionSeconds, remote.positionSeconds),
                durationSeconds: max(local.durationSeconds, remote.durationSeconds),
                isWatched: true,
                lastWatchedAt: latestWatched,
                modifiedAt: latestModified
            )
        }

        // Rule 2: Explicit Restart Guard (Recency check)
        // If a device recently reset playback to the beginning (< 30s) and is newer, respect restart
        let localIsNewer = local.modifiedAt > remote.modifiedAt
        let timeDiff = abs(local.modifiedAt.timeIntervalSince(remote.modifiedAt))

        if localIsNewer && local.positionSeconds < 30.0 && timeDiff > 10.0 {
            // Local device explicitly restarted the video
            return local
        } else if !localIsNewer && remote.positionSeconds < 30.0 && timeDiff > 10.0 {
            // Remote device explicitly restarted the video
            return remote
        }

        // Rule 3: Furthest watched position wins across devices (no lost progress)
        let resolvedPosition = max(local.positionSeconds, remote.positionSeconds)
        let resolvedWatched = local.isWatched || remote.isWatched
        let latestWatched = max(local.lastWatchedAt, remote.lastWatchedAt)
        let latestModified = max(local.modifiedAt, remote.modifiedAt)

        return SyncedWatchState(
            entityRef: local.entityRef,
            positionSeconds: resolvedPosition,
            durationSeconds: max(local.durationSeconds, remote.durationSeconds),
            isWatched: resolvedWatched,
            lastWatchedAt: latestWatched,
            modifiedAt: latestModified
        )
    }
}
