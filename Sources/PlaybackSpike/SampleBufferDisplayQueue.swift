import Foundation
import CoreMedia
import AVFoundation

/// Metrics observed during sample buffer queue rendering.
public struct QueueMetrics: Equatable, Sendable {
    public var enqueuedFrames: Int = 0
    public var renderedFrames: Int = 0
    public var droppedFrames: Int = 0
    public var lateFrames: Int = 0
    public var currentDriftMs: Double = 0.0
}

/// Status of the sample buffer rendering queue.
public enum QueueStatus: Equatable, Sendable {
    case idle
    case rendering
    case paused
    case failed(String)
}

/// Protocol abstracting sample buffer rendering sink (allowing unit testing without a live UI window).
public protocol SampleBufferRenderSink: AnyObject, Sendable {
    var isReadyForMoreMediaData: Bool { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush()
    func stopRequestingMediaData()
}

/// Production implementation forwarding to `AVSampleBufferDisplayLayer`.
public final class AVSampleBufferDisplayLayerSink: SampleBufferRenderSink, @unchecked Sendable {
    private let layer: AVSampleBufferDisplayLayer

    public init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    public var isReadyForMoreMediaData: Bool {
        return layer.isReadyForMoreMediaData
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        layer.enqueue(sampleBuffer)
    }

    public func flush() {
        layer.flush()
    }

    public func stopRequestingMediaData() {
        layer.stopRequestingMediaData()
    }
}

/// In-memory mock sink for unit testing.
public final class MockSampleBufferSink: SampleBufferRenderSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _isReady: Bool = true
    private var _enqueuedBuffers: [CMSampleBuffer] = []
    private var _flushCount: Int = 0

    public init(isReady: Bool = true) {
        self._isReady = isReady
    }

    public var isReadyForMoreMediaData: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isReady
    }

    public func setReady(_ ready: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _isReady = ready
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        _enqueuedBuffers.append(sampleBuffer)
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        _enqueuedBuffers.removeAll()
        _flushCount += 1
    }

    public func stopRequestingMediaData() {}

    public var enqueuedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _enqueuedBuffers.count
    }

    public var flushCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _flushCount
    }
}

/// Controller managing sample buffer display queue, clock synchronization, and frame timing (PB-18, PB-19, PB-20).
public final class SampleBufferDisplayQueue: @unchecked Sendable {
    private let sink: SampleBufferRenderSink
    private let lock = NSLock()
    private var _metrics = QueueMetrics()
    private var _status: QueueStatus = .idle
    private var lastPTS: CMTime = .invalid

    public init(sink: SampleBufferRenderSink) {
        self.sink = sink
    }

    public var status: QueueStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    public var metrics: QueueMetrics {
        lock.lock()
        defer { lock.unlock() }
        return _metrics
    }

    /// Enqueues a video frame for presentation.
    /// Returns true if enqueued, false if dropped due to buffer capacity or sink unreadiness.
    @discardableResult
    public func enqueue(sampleBuffer: CMSampleBuffer, masterClockPTS: CMTime? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard sink.isReadyForMoreMediaData else {
            _metrics.droppedFrames += 1
            return false
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if let master = masterClockPTS, pts.isValid, master.isValid {
            let diffSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, master))
            let diffMs = diffSeconds * 1000.0
            _metrics.currentDriftMs = diffMs

            // Drift threshold: if frame arrives > 100 ms after master clock, count as late frame
            if diffMs < -100.0 {
                _metrics.lateFrames += 1
            }
        }

        sink.enqueue(sampleBuffer)
        _metrics.enqueuedFrames += 1
        _status = .rendering
        lastPTS = pts
        return true
    }

    /// Flushes all queued frames (e.g. on seek).
    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        sink.flush()
        _status = .idle
        lastPTS = .invalid
    }

    /// Marks the queue as paused.
    public func pause() {
        lock.lock()
        defer { lock.unlock() }
        if case .rendering = _status {
            _status = .paused
        }
    }

    /// Marks the queue as failed with error description.
    public func fail(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        _status = .failed(reason)
    }

    /// Synthesizes a test sample buffer for verification testing.
    public static func createSyntheticSampleBuffer(
        pts: CMTime,
        duration: CMTime,
        formatDescription: CMVideoFormatDescription
    ) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let buffer = sampleBuffer else {
            throw NSError(domain: "SampleBufferDisplayQueue", code: Int(status), userInfo: nil)
        }
        return buffer
    }
}
