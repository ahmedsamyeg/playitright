import Foundation
import Observation

/// A chapter marker on the player scrub bar.
public struct PlaybackChapter: Sendable, Equatable, Identifiable {
    public let index: Int
    public let title: String
    public let time: TimeInterval

    public var id: Int { index }

    public init(index: Int, title: String, time: TimeInterval) {
        self.index = index
        self.title = title
        self.time = max(0, time)
    }
}

/// One selectable audio or subtitle track.
public struct PlayerTrackOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let language: String?

    public init(id: String, name: String, language: String? = nil) {
        self.id = id
        self.name = name
        self.language = language
    }

    public var displayName: String {
        if let language, !language.isEmpty {
            return "\(name) · \(language)"
        }
        return name
    }
}

/// Drives the tvOS player overlay: auto-hide, transport, chapter navigation,
/// track selection, and debounced scrubbing (UI-1, UI-2, doc 06 §2.4).
@MainActor
@Observable
public final class PlayerOverlayViewModel {
    public let duration: TimeInterval
    public let chapters: [PlaybackChapter]
    public let audioTracks: [PlayerTrackOption]
    public let subtitleTracks: [PlayerTrackOption]

    public var autoHideDelay: TimeInterval
    public var seekDebounceInterval: TimeInterval

    public private(set) var isVisible = true
    public private(set) var isPlaying = false
    public private(set) var isScrubbing = false
    public private(set) var position: TimeInterval = 0
    public private(set) var selectedAudioID: String?
    public private(set) var selectedSubtitleID: String?

    public var onPlayPause: ((Bool) -> Void)?
    public var onSeek: ((TimeInterval) -> Void)?
    public var onAudioChanged: ((PlayerTrackOption?) -> Void)?
    public var onSubtitleChanged: ((PlayerTrackOption?) -> Void)?

    private let now: @Sendable () -> Date
    private var lastInteractionAt: Date
    private var pendingSeek: TimeInterval?
    private var pendingSeekAt: Date?

    public init(
        duration: TimeInterval,
        chapters: [PlaybackChapter] = [],
        audioTracks: [PlayerTrackOption] = [],
        subtitleTracks: [PlayerTrackOption] = [],
        autoHideDelay: TimeInterval = 3,
        seekDebounceInterval: TimeInterval = 0.25,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.duration = max(0, duration)
        self.chapters = chapters.sorted { $0.time < $1.time }
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.autoHideDelay = max(0, autoHideDelay)
        self.seekDebounceInterval = max(0, seekDebounceInterval)
        self.now = now
        self.lastInteractionAt = now()
        self.selectedAudioID = audioTracks.first?.id
        self.selectedSubtitleID = subtitleTracks.first?.id
    }

    public var progressFraction: Double {
        guard duration > 0 else {
            return 0
        }
        return min(1, max(0, position / duration))
    }

    public var currentChapter: PlaybackChapter? {
        chapters.last { $0.time <= position + 0.001 }
    }

    /// Any user interaction shows the overlay and restarts the hide timer.
    public func interact(at date: Date? = nil) {
        isVisible = true
        lastInteractionAt = date ?? now()
    }

    /// Called on a display-link/timer tick. Hides the overlay after inactivity.
    public func tick(at date: Date? = nil) {
        let date = date ?? now()
        guard isVisible, !isScrubbing else {
            return
        }
        if date.timeIntervalSince(lastInteractionAt) >= autoHideDelay {
            isVisible = false
        }
    }

    public func togglePlayback(at date: Date? = nil) {
        interact(at: date)
        isPlaying.toggle()
        onPlayPause?(isPlaying)
    }

    public func setPlaying(_ playing: Bool, at date: Date? = nil) {
        interact(at: date)
        isPlaying = playing
        onPlayPause?(isPlaying)
    }

    /// Skips by a signed number of seconds, clamped to the media bounds.
    public func skip(by delta: TimeInterval, at date: Date? = nil) {
        seek(to: position + delta, at: date, immediate: true)
    }

    public func beginScrubbing(at date: Date? = nil) {
        interact(at: date)
        isScrubbing = true
    }

    public func updateScrub(to time: TimeInterval, at date: Date? = nil) {
        position = clamp(time)
        interact(at: date)
        requestSeek(to: position, at: date)
    }

    public func endScrubbing(at date: Date? = nil) {
        isScrubbing = false
        interact(at: date)
        if let pendingSeek {
            position = pendingSeek
            onSeek?(pendingSeek)
            self.pendingSeek = nil
            pendingSeekAt = nil
        }
    }

    /// Records a seek target and lets the debounce interval coalesce updates.
    public func requestSeek(to time: TimeInterval, at date: Date? = nil) {
        let time = clamp(time)
        position = time
        pendingSeek = time
        pendingSeekAt = date ?? now()
        interact(at: date)
    }

    /// Commits the pending seek once the debounce interval has elapsed.
    @discardableResult
    public func flushSeekIfNeeded(at date: Date? = nil) -> Bool {
        let date = date ?? now()
        guard let pendingSeek, let pendingSeekAt else {
            return false
        }
        guard date.timeIntervalSince(pendingSeekAt) >= seekDebounceInterval else {
            return false
        }
        performSeek(pendingSeek)
        return true
    }

    /// Commits the pending seek immediately (used when scrubbing ends).
    @discardableResult
    public func flushSeek(at date: Date? = nil) -> Bool {
        guard let pendingSeek else {
            return false
        }
        _ = date
        performSeek(pendingSeek)
        return true
    }

    public func seek(
        to time: TimeInterval,
        at date: Date? = nil,
        immediate: Bool = false
    ) {
        requestSeek(to: time, at: date)
        if immediate || seekDebounceInterval == 0 {
            flushSeek(at: date)
        }
    }

    public func nextChapter(at date: Date? = nil) {
        let target = chapters.first { $0.time > position + 0.001 }
        seek(to: target?.time ?? duration, at: date, immediate: true)
    }

    public func previousChapter(at date: Date? = nil) {
        let target = chapters
            .last { $0.time < position - 1 }?
            .time ?? 0
        seek(to: target, at: date, immediate: true)
    }

    public func selectAudio(_ option: PlayerTrackOption?, at date: Date? = nil) {
        interact(at: date)
        selectedAudioID = option?.id
        onAudioChanged?(option)
    }

    public func selectSubtitle(_ option: PlayerTrackOption?, at date: Date? = nil) {
        interact(at: date)
        selectedSubtitleID = option?.id
        onSubtitleChanged?(option)
    }

    public var selectedAudio: PlayerTrackOption? {
        audioTracks.first { $0.id == selectedAudioID }
    }

    public var selectedSubtitle: PlayerTrackOption? {
        subtitleTracks.first { $0.id == selectedSubtitleID }
    }

    private func performSeek(_ time: TimeInterval) {
        position = time
        pendingSeek = nil
        pendingSeekAt = nil
        onSeek?(time)
    }

    private func clamp(_ time: TimeInterval) -> TimeInterval {
        min(duration, max(0, time))
    }
}
