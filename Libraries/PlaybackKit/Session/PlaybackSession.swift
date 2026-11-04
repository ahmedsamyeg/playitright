import Foundation
import LibraryCore
import SourceAdapters

/// High-level transport state for a playback session.
public enum PlaybackSessionState: String, Codable, Sendable, Equatable {
    case idle
    case preparing
    case playing
    case paused
    case ended
    case failed
}

/// Configuration for a ``PlaybackSession``.
public struct PlaybackSessionConfiguration: Sendable, Equatable {
    public var account: String
    public var entityKind: EntityKind
    public var entityRef: String
    public var duration: TimeInterval?

    /// Fraction of the item that marks it watched (MD-6).
    public var watchedThreshold: Double

    /// In-memory progress cadence (PB-21).
    public var progressCacheInterval: TimeInterval

    /// Database flush cadence (NFR-16).
    public var databaseFlushInterval: TimeInterval

    /// Whether the session runs its own flush timer.
    public var autoFlush: Bool

    public var audioTrack: String?
    public var subtitleTrack: String?

    public init(
        account: String,
        entityKind: EntityKind,
        entityRef: String,
        duration: TimeInterval? = nil,
        watchedThreshold: Double = 0.9,
        progressCacheInterval: TimeInterval = 1,
        databaseFlushInterval: TimeInterval = 10,
        autoFlush: Bool = true,
        audioTrack: String? = nil,
        subtitleTrack: String? = nil
    ) {
        self.account = account
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.duration = duration
        self.watchedThreshold = min(1, max(0, watchedThreshold))
        self.progressCacheInterval = max(0.1, progressCacheInterval)
        self.databaseFlushInterval = max(0.1, databaseFlushInterval)
        self.autoFlush = autoFlush
        self.audioTrack = audioTrack
        self.subtitleTrack = subtitleTrack
    }
}

/// One audio/video drift measurement and the gentle correction that follows.
public struct AVDriftSample: Sendable, Equatable {
    /// Video clock in seconds.
    public var videoTime: TimeInterval

    /// Audio clock in seconds.
    public var audioTime: TimeInterval

    /// `audioTime - videoTime`; positive means audio is ahead.
    public var drift: TimeInterval

    /// Drift remaining after the correction is applied.
    public var residualDrift: TimeInterval

    /// Audio clock rate used to close the gap; `1` means no stretch.
    public var audioStretchRate: Double

    /// Whether the gap is too large to stretch and the session should resync.
    public var requiresResync: Bool

    public init(
        videoTime: TimeInterval,
        audioTime: TimeInterval,
        drift: TimeInterval,
        residualDrift: TimeInterval,
        audioStretchRate: Double,
        requiresResync: Bool
    ) {
        self.videoTime = videoTime
        self.audioTime = audioTime
        self.drift = drift
        self.residualDrift = residualDrift
        self.audioStretchRate = audioStretchRate
        self.requiresResync = requiresResync
    }

    public var absoluteDrift: TimeInterval {
        abs(drift)
    }
}

/// Measures audio/video clock drift and derives a small audio-rate correction.
///
/// Corrections are capped at ``maximumDrift`` (40 ms by default) and the audio
/// clock is stretched by at most ``maximumRateAdjustment`` (2%) so pitch stays
/// natural (PB-20).
public struct AVDriftCorrector: Sendable, Equatable {
    /// Gaps at or below this are treated as in sync.
    public var deadband: TimeInterval

    /// Largest drift a single gentle correction will target.
    public var maximumDrift: TimeInterval

    /// Largest fractional audio-rate change.
    public var maximumRateAdjustment: Double

    /// Fraction of the drift a single correction closes.
    public var gain: Double

    public private(set) var audioStretchRate: Double

    public init(
        deadband: TimeInterval = 0.005,
        maximumDrift: TimeInterval = 0.04,
        maximumRateAdjustment: Double = 0.02,
        gain: Double = 0.5
    ) {
        self.deadband = max(0, deadband)
        self.maximumDrift = max(0.001, maximumDrift)
        self.maximumRateAdjustment = min(0.1, max(0, maximumRateAdjustment))
        self.gain = min(1, max(0, gain))
        self.audioStretchRate = 1
    }

    /// Samples the clocks and returns the correction for the next audio frame.
    @discardableResult
    public mutating func sample(
        videoTime: TimeInterval,
        audioTime: TimeInterval
    ) -> AVDriftSample {
        let drift = audioTime - videoTime
        let magnitude = abs(drift)
        let requiresResync = magnitude > maximumDrift

        if magnitude <= deadband {
            audioStretchRate = 1
            return AVDriftSample(
                videoTime: videoTime,
                audioTime: audioTime,
                drift: drift,
                residualDrift: drift,
                audioStretchRate: 1,
                requiresResync: false
            )
        }

        let targeted = min(magnitude, maximumDrift)
        let correction = targeted * gain
        // Audio ahead (positive drift) must slow down, so the rate goes below 1.
        let direction = drift > 0 ? -1.0 : 1.0
        let rate = 1 + direction
            * (targeted / maximumDrift)
            * maximumRateAdjustment
        audioStretchRate = min(
            1 + maximumRateAdjustment,
            max(1 - maximumRateAdjustment, rate)
        )

        return AVDriftSample(
            videoTime: videoTime,
            audioTime: audioTime,
            drift: drift,
            residualDrift: drift + direction * correction,
            audioStretchRate: audioStretchRate,
            requiresResync: requiresResync
        )
    }

    /// Clears any stretch after a seek or resync.
    public mutating func reset() {
        audioStretchRate = 1
    }
}

/// Coordinates playback transport, drift correction, and watch-state flushing
/// (PB-18–PB-22, MD-6, NFR-16, doc 04 §8).
///
/// Position updates are kept in memory at the player's cadence and flushed to
/// the database every ``PlaybackSessionConfiguration/databaseFlushInterval``
/// seconds and whenever the app is suspended or playback stops. Items that
/// cross 90% of their duration are marked watched automatically.
@MainActor
public final class PlaybackSession {
    public let configuration: PlaybackSessionConfiguration
    public let reporter: WatchStateReporter

    public private(set) var state: PlaybackSessionState
    public private(set) var progress: PlaybackWatchState
    public private(set) var lastDrift: AVDriftSample?

    public var onProgressChanged: ((PlaybackWatchState) -> Void)?
    public var onWatched: ((PlaybackWatchState) -> Void)?

    private var driftCorrector: AVDriftCorrector
    private var lastFlushCheck: Date
    private var hasAnnouncedWatched = false
    nonisolated(unsafe) private var autoFlushTask: Task<Void, Never>?
    private let now: @Sendable () -> Date

    public init(
        configuration: PlaybackSessionConfiguration,
        persistence: (any WatchStatePersistence)? = nil,
        adapter: (any SourceAdapter)? = nil,
        session: SourceSession? = nil,
        item: SourceItem? = nil,
        driftCorrector: AVDriftCorrector = AVDriftCorrector(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.now = now
        self.driftCorrector = driftCorrector
        self.state = .idle
        self.progress = PlaybackWatchState(
            position: 0,
            duration: configuration.duration,
            isWatched: false,
            updatedAt: now(),
            audioTrack: configuration.audioTrack,
            subtitleTrack: configuration.subtitleTrack
        )
        self.lastFlushCheck = now()
        self.reporter = WatchStateReporter(
            account: configuration.account,
            entityKind: configuration.entityKind,
            entityRef: configuration.entityRef,
            persistence: persistence,
            adapter: adapter,
            session: session,
            item: item
        )
        self.reporter.record(progress)

        if configuration.autoFlush {
            startAutoFlush()
        }
    }

    deinit {
        autoFlushTask?.cancel()
    }

    // MARK: - Transport

    public func prepare(duration: TimeInterval? = nil) {
        if let duration {
            applyDuration(duration)
        }
        state = .preparing
    }

    public func play() {
        guard state != .ended else {
            return
        }
        state = .playing
    }

    public func pause(at position: TimeInterval? = nil) {
        if let position {
            updateProgress(position)
        }
        if state == .playing || state == .preparing {
            state = .paused
        }
        flush()
    }

    public func seek(to position: TimeInterval) {
        updateProgress(position)
        driftCorrector.reset()
        lastDrift = nil
        flush()
    }

    public func finish() {
        state = .ended
        let duration = progress.duration ?? progress.position
        setProgress(
            PlaybackWatchState(
                position: duration,
                duration: progress.duration,
                isWatched: true,
                updatedAt: now(),
                audioTrack: progress.audioTrack,
                subtitleTrack: progress.subtitleTrack
            )
        )
        flush()
    }

    public func fail() {
        state = .failed
        flush()
    }

    /// Called when the app moves to the background (NFR-16).
    public func suspend() {
        flush()
        autoFlushTask?.cancel()
        autoFlushTask = nil
    }

    // MARK: - Progress

    /// Updates the in-memory snapshot. Call at the player cadence (about 1 s).
    public func updateProgress(
        _ position: TimeInterval,
        duration: TimeInterval? = nil
    ) {
        if let duration {
            applyDuration(duration)
        }
        let resolvedDuration = duration ?? progress.duration
        let clamped = resolvedDuration.map {
            min(max(0, position), $0)
        } ?? max(0, position)
        let watched = isWatched(position: clamped, duration: resolvedDuration)

        var next = progress
        next.position = clamped
        next.duration = resolvedDuration
        next.isWatched = watched
        next.updatedAt = now()
        if let audioTrack = configuration.audioTrack {
            next.audioTrack = audioTrack
        }
        if let subtitleTrack = configuration.subtitleTrack {
            next.subtitleTrack = subtitleTrack
        }
        setProgress(next)

        if watched, !hasAnnouncedWatched {
            hasAnnouncedWatched = true
            onWatched?(next)
        }

        flushIfDue()
    }

    /// Flushes when the database cadence has elapsed.
    @discardableResult
    public func flushIfDue() -> Bool {
        let date = now()
        guard date.timeIntervalSince(lastFlushCheck) >= configuration.databaseFlushInterval else {
            return false
        }
        lastFlushCheck = date
        flush()
        return true
    }

    /// Writes the current progress to the database immediately.
    @discardableResult
    public func flush() -> PlaybackWatchState? {
        reporter.record(progress)
        let flushed = reporter.flush(at: now())
        lastFlushCheck = now()
        return flushed
    }

    /// Pushes the latest progress to the source adapter.
    public func pushToSource() async {
        reporter.record(progress)
        await reporter.pushToSource()
    }

    // MARK: - A/V sync

    /// Measures drift and applies a gentle audio-stretch correction (PB-20).
    @discardableResult
    public func measureDrift(
        videoTime: TimeInterval,
        audioTime: TimeInterval
    ) -> AVDriftSample {
        let sample = driftCorrector.sample(
            videoTime: videoTime,
            audioTime: audioTime
        )
        lastDrift = sample
        return sample
    }

    /// The audio rate currently requested by the drift corrector.
    public var audioStretchRate: Double {
        driftCorrector.audioStretchRate
    }

    // MARK: - Internals

    /// Applies a duration discovered by the probe after the session was built.
    private func applyDuration(_ duration: TimeInterval) {
        var next = progress
        next.duration = duration
        next.position = min(next.position, max(0, duration))
        progress = next
        reporter.record(next)
    }

    private func setProgress(_ next: PlaybackWatchState) {
        progress = next
        reporter.record(next)
        onProgressChanged?(next)
    }

    private func isWatched(
        position: TimeInterval,
        duration: TimeInterval?
    ) -> Bool {
        guard let duration, duration > 0 else {
            return false
        }
        return position / duration >= configuration.watchedThreshold
    }

    private func startAutoFlush() {
        autoFlushTask?.cancel()
        autoFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.configuration.databaseFlushInterval ?? 10
                try? await Task.sleep(
                    nanoseconds: UInt64(max(0.1, interval) * 1_000_000_000)
                )
                guard !Task.isCancelled, let self else {
                    return
                }
                self.flush()
            }
        }
    }
}
