import Testing

@Suite("ProtocolBenchmarkSimulator Tests")
struct ProtocolBenchmarkSimulatorTests {

    @Test("Benchmark simulation computes transfer throughput accurately")
    func testBenchmarkThroughput() async {
        let simulator = ProtocolBenchmarkSimulator()
        // Simulate 10 MB transfer with 1 MB chunks
        let totalBytes: UInt64 = 10 * 1024 * 1024
        let result = await simulator.runSimulation(
            protocolType: .smb2,
            totalBytes: totalBytes,
            chunkSize: 1024 * 1024
        )

        #expect(result.protocolType == .smb2)
        #expect(result.totalBytes == totalBytes)
        #expect(result.chunkSize == 1024 * 1024)
        #expect(result.durationSeconds > 0)
        #expect(result.throughputMBPerSec > 0)
    }

    @Test("Metrics throughput calculation handles zero duration safely")
    func testMetricsThroughputZeroDuration() {
        var metrics = ProtocolSessionMetrics()
        metrics.bytesRead = 1024 * 1024
        metrics.elapsedTimeSeconds = 0.0

        #expect(metrics.throughputMBPerSecond == 0.0)

        metrics.elapsedTimeSeconds = 1.0
        #expect(abs(metrics.throughputMBPerSecond - 1.0) < 0.001)
    }
}
