import AVFoundation
import Foundation
import SourceAdapters

/// R1 direct-play pipeline: a source-backed `AVPlayer` that reads byte ranges
/// straight from a ``SourceAdapter`` (PB-G2, doc 04 §4.2).
///
/// Direct play performs no transcoding. The pipeline owns the player item and
/// tracks playback timing, buffer health, and stalls so the session layer can
/// warn before a starved buffer becomes visible.
@MainActor
public final class DirectPlayPipeline {
    /// High-level playback state.
    public enum PlaybackStatus: String, Codable, Sendable, Equatable {
        case idle
        case ready
        case playing
        case paused
        case stalled
        case ended
        case failed
    }

    /// A point-in-time snapshot of playback health.
    public struct Metrics: Sendable, Equatable {
        public var status: PlaybackStatus
        public var currentTime: TimeInterval
        public var duration: TimeInterval
        public var bufferedAhead: TimeInterval
        public var isPlaybackLikelyToKeepUp: Bool
        public var stallCount: Int
        public var lastStallAt: Date?
        public var errorDescription: String?

        public init(
            status: PlaybackStatus = .idle,
            currentTime: TimeInterval = 0,
            duration: TimeInterval = 0,
            bufferedAhead: TimeInterval = 0,
            isPlaybackLikelyToKeepUp: Bool = false,
            stallCount: Int = 0,
            lastStallAt: Date? = nil,
            errorDescription: String? = nil
        ) {
            self.status = status
            self.currentTime = currentTime
            self.duration = duration
            self.bufferedAhead = bufferedAhead
            self.isPlaybackLikelyToKeepUp = isPlaybackLikelyToKeepUp
            self.stallCount = stallCount
            self.lastStallAt = lastStallAt
            self.errorDescription = errorDescription
        }
    }

    nonisolated(unsafe) public let player: AVPlayer
    nonisolated(unsafe) public let playerItem: AVPlayerItem
    nonisolated(unsafe) public let asset: AVURLAsset
    public let resourceLoader: CustomResourceLoaderDelegate

    public private(set) var metrics: Metrics
    public var onMetricsChanged: (@MainActor (Metrics) -> Void)?

    private let now: () -> Date
    private let notificationCenter: NotificationCenter
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []

    public init(
        adapter: any SourceAdapter,
        session: SourceSession,
        item: SourceItem,
        contentType: String? = nil,
        notificationCenter: NotificationCenter = .default,
        timeObserverInterval: TimeInterval = 0.5,
        now: @escaping () -> Date = Date.init
    ) {
        self.now = now
        self.notificationCenter = notificationCenter
        self.resourceLoader = CustomResourceLoaderDelegate(
            adapter: adapter,
            session: session,
            item: item,
            contentType: contentType
        )
        self.asset = resourceLoader.makeAsset()
        self.playerItem = AVPlayerItem(asset: asset)
        self.player = AVPlayer(playerItem: playerItem)
        self.metrics = Metrics(status: .ready)
        observePlayback(timeObserverInterval: timeObserverInterval)
        refreshMetrics()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
    }

    // MARK: - Transport

    public func play() {
        player.play()
        metrics.status = .playing
        refreshMetrics()
    }

    public func pause() {
        player.pause()
        metrics.status = .paused
        refreshMetrics()
    }

    public func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else {
            return
        }
        let target = max(0, seconds)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        refreshMetrics()
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        metrics.status = .idle
        publish()
    }

    /// Recomputes timing and buffer health from AVFoundation.
    public func refreshMetrics() {
        let current = player.currentTime().seconds
        let duration = playerItem.duration.seconds
        let buffered = bufferedAhead(from: playerItem, at: current)
        let likely = playerItem.isPlaybackLikelyToKeepUp
        let rate = player.rate

        metrics.currentTime = current.isFinite ? current : 0
        metrics.duration = duration.isFinite ? duration : 0
        metrics.bufferedAhead = max(0, buffered)
        metrics.isPlaybackLikelyToKeepUp = likely

        if metrics.status != .failed && metrics.status != .idle {
            if playerItem.isPlaybackBufferEmpty,
               rate == 0,
               player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                metrics.status = .stalled
            } else if rate > 0 {
                metrics.status = .playing
            } else if metrics.status == .playing
                || metrics.status == .stalled {
                metrics.status = .paused
            }
        }
        publish()
    }

    // MARK: - Observation

    private func observePlayback(timeObserverInterval: TimeInterval) {
        let timescale: CMTimeScale = 600
        let interval = CMTime(
            seconds: max(0.05, timeObserverInterval),
            preferredTimescale: timescale
        )
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMetrics()
            }
        }

        observe(name: .AVPlayerItemPlaybackStalled) { pipeline in
            pipeline.metrics.status = .stalled
            pipeline.metrics.stallCount += 1
            pipeline.metrics.lastStallAt = pipeline.now()
        }

        observeFailure()

        observe(name: .AVPlayerItemDidPlayToEndTime) { pipeline in
            pipeline.metrics.status = .ended
            pipeline.refreshMetrics()
        }
    }

    private func observe(
        name: Notification.Name,
        handler: @escaping @MainActor (DirectPlayPipeline) -> Void
    ) {
        let token = notificationCenter.addObserver(
            forName: name,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                handler(self)
                self.publish()
            }
        }
        observerTokens.append(token)
    }

    private func observeFailure() {
        let token = notificationCenter.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            let description = (
                notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                    as? Error
            )?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.metrics.status = .failed
                self.metrics.errorDescription = description
                self.publish()
            }
        }
        observerTokens.append(token)
    }

    private func bufferedAhead(
        from item: AVPlayerItem,
        at currentTime: TimeInterval
    ) -> TimeInterval {
        var furthestEnd = currentTime
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            guard start.isFinite, end.isFinite else {
                continue
            }
            if end >= currentTime - 0.001 {
                furthestEnd = max(furthestEnd, end)
            }
        }
        return furthestEnd - currentTime
    }

    private func publish() {
        onMetricsChanged?(metrics)
    }
}
