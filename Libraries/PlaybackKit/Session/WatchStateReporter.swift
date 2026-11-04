import Foundation
import LibraryCore
import SourceAdapters

/// The database surface the watch-state reporter needs.
///
/// `MediaDatabaseWriter` already implements this shape, so the reporting
/// layer can be exercised with an in-memory database or a lightweight fake.
public protocol WatchStatePersistence: Sendable {
    func updateWatchProgress(
        account: String,
        entityKind: EntityKind,
        entityRef: String,
        positionMs: Int64,
        durationMs: Int64?,
        watched: Bool
    ) throws
}

extension MediaDatabaseWriter: WatchStatePersistence {}

/// The progress snapshot that is kept in memory and eventually persisted.
public struct PlaybackWatchState: Sendable, Equatable {
    /// Playback position in seconds.
    public var position: TimeInterval

    /// Item duration in seconds, when known.
    public var duration: TimeInterval?

    /// Whether the item crossed the watched threshold.
    public var isWatched: Bool

    /// When the state was captured.
    public var updatedAt: Date

    /// Selected audio track id or language.
    public var audioTrack: String?

    /// Selected subtitle track id or language, `"off"`, or `nil`.
    public var subtitleTrack: String?

    public init(
        position: TimeInterval,
        duration: TimeInterval? = nil,
        isWatched: Bool = false,
        updatedAt: Date = Date(),
        audioTrack: String? = nil,
        subtitleTrack: String? = nil
    ) {
        self.position = max(0, position)
        self.duration = duration
        self.isWatched = isWatched
        self.updatedAt = updatedAt
        self.audioTrack = audioTrack
        self.subtitleTrack = subtitleTrack
    }

    /// Fraction of the item played, clamped to 0–1.
    public var fraction: Double {
        guard let duration, duration > 0 else {
            return 0
        }
        return min(1, max(0, position / duration))
    }

    /// The equivalent source-adapter payload (SRC-6).
    public var sourceState: SourceWatchState {
        SourceWatchState(
            position: position,
            duration: duration,
            isWatched: isWatched,
            lastWatchedAt: updatedAt,
            audioTrack: audioTrack,
            subtitleTrack: subtitleTrack
        )
    }
}

/// Persists playback progress and pushes it to the owning source.
///
/// Position updates are cheap and in-memory; ``flush()`` performs the database
/// write (NFR-16) and the best-effort source push (SRC-6). Unsupported source
/// pushes are ignored because watch-state writes are explicitly best effort.
public final class WatchStateReporter: @unchecked Sendable {
    public let account: String
    public let entityKind: EntityKind
    public let entityRef: String

    private let persistence: (any WatchStatePersistence)?
    private let adapter: (any SourceAdapter)?
    private let session: SourceSession?
    private let item: SourceItem?

    private let lock = NSLock()
    private var storedState: PlaybackWatchState?
    private var storedFlushCount = 0
    private var storedLastFlushedAt: Date?
    private var storedLastError: (any Error)?

    public init(
        account: String,
        entityKind: EntityKind,
        entityRef: String,
        persistence: (any WatchStatePersistence)? = nil,
        adapter: (any SourceAdapter)? = nil,
        session: SourceSession? = nil,
        item: SourceItem? = nil
    ) {
        self.account = account
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.persistence = persistence
        self.adapter = adapter
        self.session = session
        self.item = item
    }

    /// The latest in-memory state.
    public var state: PlaybackWatchState? {
        lock.lock()
        defer { lock.unlock() }
        return storedState
    }

    /// Number of successful database flushes.
    public var flushCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFlushCount
    }

    public var lastFlushedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastFlushedAt
    }

    public var lastError: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastError
    }

    /// Updates the in-memory snapshot without touching the database.
    public func record(_ state: PlaybackWatchState) {
        lock.lock()
        storedState = state
        lock.unlock()
    }

    /// Writes the latest snapshot and returns what was written.
    ///
    /// Returns `nil` when nothing has been recorded yet. Database errors are
    /// captured in ``lastError`` and do not stop playback.
    @discardableResult
    public func flush(at date: Date = Date()) -> PlaybackWatchState? {
        lock.lock()
        guard let state = storedState else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard let persistence else {
            lock.lock()
            storedLastFlushedAt = date
            lock.unlock()
            return state
        }

        do {
            try persistence.updateWatchProgress(
                account: account,
                entityKind: entityKind,
                entityRef: entityRef,
                positionMs: Int64((state.position * 1_000).rounded()),
                durationMs: state.duration.map {
                    Int64(($0 * 1_000).rounded())
                },
                watched: state.isWatched
            )
            lock.lock()
            storedFlushCount += 1
            storedLastFlushedAt = date
            storedLastError = nil
            lock.unlock()
        } catch {
            lock.lock()
            storedLastError = error
            lock.unlock()
        }
        return state
    }

    /// Sends the latest snapshot to the source adapter, if one is attached.
    ///
    /// Failures are intentionally swallowed apart from being recorded in
    /// ``lastError``; a source outage must never interrupt local playback.
    public func pushToSource() async {
        guard let adapter, let session, let item else {
            return
        }
        let state = withLock { storedState?.sourceState }
        guard let state else {
            return
        }

        do {
            try await adapter.pushWatchState(
                session: session,
                item: item,
                state: state
            )
            withLock { storedLastError = nil }
        } catch SourceAdapterError.unsupported {
            // Watch-state writes are optional for many source types.
        } catch {
            withLock { storedLastError = error }
        }
    }

    /// Runs `body` under the lock from synchronous or asynchronous contexts.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
