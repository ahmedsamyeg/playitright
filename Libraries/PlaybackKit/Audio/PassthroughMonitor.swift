import Foundation

/// Detects a silent passthrough stream and decides when to fall back to
/// decode + downmix (PB-11, doc 04 §6).
///
/// tvOS can accept a passthrough format that the HDMI sink silently ignores.
/// The monitor treats a run of all-zero PCM frames as a passthrough failure
/// once it lasts for `fallbackAfter` seconds.
public final class PassthroughMonitor: @unchecked Sendable {
    /// Amplitude at or below which a sample is considered silent.
    public let silenceThreshold: Float

    /// Continuous silence before the caller should fall back.
    public let fallbackAfter: TimeInterval

    private let lock = NSLock()
    private var silentSince: TimeInterval?
    private var lastActivityAt: TimeInterval?

    public init(
        silenceThreshold: Float = 0.000_1,
        fallbackAfter: TimeInterval = 2
    ) {
        self.silenceThreshold = max(0, silenceThreshold)
        self.fallbackAfter = max(0, fallbackAfter)
    }

    /// Whether the most recent buffer contained no audible samples.
    public var isSilent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return silentSince != nil
    }

    /// When silence began, if the stream is currently silent.
    public var silenceStartedAt: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return silentSince
    }

    /// Records a decoded PCM frame and its timestamp.
    public func record(samples: [Float], at timestamp: TimeInterval) {
        let audible = samples.contains { abs($0) > silenceThreshold }
        lock.lock()
        lastActivityAt = timestamp
        if audible {
            silentSince = nil
        } else if silentSince == nil {
            silentSince = timestamp
        }
        lock.unlock()
    }

    /// Records non-silent activity without a PCM buffer, such as a fresh audio
    /// session or a known-good passthrough frame.
    public func recordActivity(at timestamp: TimeInterval) {
        lock.lock()
        lastActivityAt = timestamp
        silentSince = nil
        lock.unlock()
    }

    /// Whether continuous silence has lasted long enough to trigger fallback.
    public func shouldFallBack(at timestamp: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let silentSince else {
            return false
        }
        return timestamp - silentSince >= fallbackAfter
    }

    /// Continuous silence duration at a timestamp.
    public func silentDuration(at timestamp: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let silentSince else {
            return 0
        }
        return max(0, timestamp - silentSince)
    }

    /// Timestamp of the most recent recorded buffer or activity.
    public var lastActivity: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return lastActivityAt
    }

    /// Clears the silence run, for example after a successful format change.
    public func reset() {
        lock.lock()
        silentSince = nil
        lastActivityAt = nil
        lock.unlock()
    }
}
