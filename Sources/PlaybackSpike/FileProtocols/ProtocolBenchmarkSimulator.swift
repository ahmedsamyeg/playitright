import Foundation

/// Benchmarking harness for file protocol buffer sizes and throughput simulation (SRC-2, SRC-3).
public final class ProtocolBenchmarkSimulator: Sendable {

    public struct BenchmarkResult: Equatable, Sendable {
        public let protocolType: FileProtocolType
        public let chunkSize: Int
        public let totalBytes: UInt64
        public let durationSeconds: Double
        public let throughputMBPerSec: Double

        public init(
            protocolType: FileProtocolType,
            chunkSize: Int,
            totalBytes: UInt64,
            durationSeconds: Double
        ) {
            self.protocolType = protocolType
            self.chunkSize = chunkSize
            self.totalBytes = totalBytes
            self.durationSeconds = durationSeconds
            let mb = Double(totalBytes) / (1024.0 * 1024.0)
            self.throughputMBPerSec = durationSeconds > 0 ? (mb / durationSeconds) : 0.0
        }
    }

    public init() {}

    /// Runs a simulation of transferring `totalBytes` in chunks of `chunkSize` with simulated network latency.
    public func runSimulation(
        protocolType: FileProtocolType,
        totalBytes: UInt64,
        chunkSize: Int,
        simulatedLatencyMs: Double = 0.0
    ) async -> BenchmarkResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        var transferred: UInt64 = 0

        // Allocate a reusable chunk buffer
        let buffer = Data(repeating: 0x5A, count: min(chunkSize, Int(totalBytes)))

        while transferred < totalBytes {
            let nextBytes = min(UInt64(chunkSize), totalBytes - transferred)
            if simulatedLatencyMs > 0 {
                let delayNs = UInt64(simulatedLatencyMs * 1_000_000.0)
                try? await Task.sleep(nanoseconds: delayNs)
            }
            transferred += nextBytes
            _ = buffer.prefix(Int(nextBytes))
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        return BenchmarkResult(
            protocolType: protocolType,
            chunkSize: chunkSize,
            totalBytes: totalBytes,
            durationSeconds: max(0.0001, duration)
        )
    }
}
