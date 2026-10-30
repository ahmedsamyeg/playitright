import Testing
import CoreMedia

@Suite("SampleBufferDisplayQueue Tests")
@MainActor
struct SampleBufferDisplayQueueTests {

    @Test("Queue state transitions and readiness behavior")
    func testQueueReadiness() throws {
        let mockSink = MockSampleBufferSink(isReady: true)
        let queue = SampleBufferDisplayQueue(sink: mockSink)

        #expect(queue.status == .idle)
        #expect(queue.metrics.enqueuedFrames == 0)
        #expect(queue.metrics.droppedFrames == 0)

        let desc = try FormatDescriptionInspector.createSyntheticFormat()
        let sample = try SampleBufferDisplayQueue.createSyntheticSampleBuffer(
            pts: CMTime(value: 0, timescale: 60000),
            duration: CMTime(value: 1000, timescale: 60000),
            formatDescription: desc
        )

        let enqueued = queue.enqueue(sampleBuffer: sample)
        #expect(enqueued == true)
        #expect(queue.status == .rendering)
        #expect(queue.metrics.enqueuedFrames == 1)
        #expect(mockSink.enqueuedCount == 1)

        // Test dropping frame when sink is unready (buffer backpressure)
        mockSink.setReady(false)
        let sample2 = try SampleBufferDisplayQueue.createSyntheticSampleBuffer(
            pts: CMTime(value: 1000, timescale: 60000),
            duration: CMTime(value: 1000, timescale: 60000),
            formatDescription: desc
        )
        let enqueued2 = queue.enqueue(sampleBuffer: sample2)
        #expect(enqueued2 == false)
        #expect(queue.metrics.droppedFrames == 1)
        #expect(mockSink.enqueuedCount == 1)
    }

    @Test("Queue flush resets state on seek")
    func testQueueFlush() throws {
        let mockSink = MockSampleBufferSink(isReady: true)
        let queue = SampleBufferDisplayQueue(sink: mockSink)
        let desc = try FormatDescriptionInspector.createSyntheticFormat()
        let sample = try SampleBufferDisplayQueue.createSyntheticSampleBuffer(
            pts: CMTime(value: 0, timescale: 60000),
            duration: CMTime(value: 1000, timescale: 60000),
            formatDescription: desc
        )
        queue.enqueue(sampleBuffer: sample)
        #expect(queue.status == .rendering)

        queue.flush()
        #expect(queue.status == .idle)
        #expect(mockSink.enqueuedCount == 0)
        #expect(mockSink.flushCount == 1)
    }

    @Test("Clock drift measurement and late frame detection")
    func testClockDrift() throws {
        let mockSink = MockSampleBufferSink(isReady: true)
        let queue = SampleBufferDisplayQueue(sink: mockSink)
        let desc = try FormatDescriptionInspector.createSyntheticFormat()

        // Frame PTS is at 1.0s, master clock is at 0.98s -> +20ms lead (good)
        let sample1 = try SampleBufferDisplayQueue.createSyntheticSampleBuffer(
            pts: CMTime(seconds: 1.0, preferredTimescale: 60000),
            duration: CMTime(seconds: 1.0/60.0, preferredTimescale: 60000),
            formatDescription: desc
        )
        queue.enqueue(sampleBuffer: sample1, masterClockPTS: CMTime(seconds: 0.98, preferredTimescale: 60000))
        #expect(abs(queue.metrics.currentDriftMs - 20.0) < 0.1)
        #expect(queue.metrics.lateFrames == 0)

        // Frame PTS is at 1.0s, master clock is at 1.15s -> -150ms behind (late frame!)
        let sample2 = try SampleBufferDisplayQueue.createSyntheticSampleBuffer(
            pts: CMTime(seconds: 1.0, preferredTimescale: 60000),
            duration: CMTime(seconds: 1.0/60.0, preferredTimescale: 60000),
            formatDescription: desc
        )
        queue.enqueue(sampleBuffer: sample2, masterClockPTS: CMTime(seconds: 1.15, preferredTimescale: 60000))
        #expect(queue.metrics.lateFrames == 1)
    }
}
