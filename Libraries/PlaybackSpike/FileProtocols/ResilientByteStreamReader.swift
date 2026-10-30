import Foundation

/// Resilient ranged byte stream reader with automatic reconnect and byte-accurate resumption (SRC-10).
/// Implemented as an actor for native Swift 6 concurrency isolation.
public actor ResilientByteStreamReader {
    public typealias TransportReadHandler = @Sendable (ByteRangeRequest) async throws -> Data

    private let transport: TransportReadHandler
    private let maxRetries: Int
    private let initialRetryDelaySeconds: Double
    private var _metrics = ProtocolSessionMetrics()

    public init(
        maxRetries: Int = 3,
        initialRetryDelaySeconds: Double = 0.05,
        transport: @escaping TransportReadHandler
    ) {
        self.maxRetries = maxRetries
        self.initialRetryDelaySeconds = initialRetryDelaySeconds
        self.transport = transport
    }

    public var metrics: ProtocolSessionMetrics {
        _metrics
    }

    /// Reads an exact byte range with automatic retry and reconnection on network drops.
    public func readRange(offset: UInt64, length: UInt64) async throws -> Data {
        let startTime = CFAbsoluteTimeGetCurrent()
        var accumulatedData = Data()
        accumulatedData.reserveCapacity(Int(length))

        var currentOffset = offset
        let targetEndOffset = offset + length
        var retryCount = 0

        while currentOffset < targetEndOffset {
            let remainingBytes = targetEndOffset - currentOffset
            let request = ByteRangeRequest(offset: currentOffset, length: remainingBytes)

            do {
                let chunk = try await transport(request)

                guard !chunk.isEmpty else {
                    // EOF reached before expected length
                    break
                }

                accumulatedData.append(chunk)
                currentOffset += UInt64(chunk.count)

                _metrics.bytesRead += UInt64(chunk.count)
                _metrics.totalRequests += 1

                // Reset retry count on successful chunk read
                retryCount = 0

            } catch {
                retryCount += 1
                _metrics.connectionDrops += 1

                guard retryCount <= maxRetries else {
                    throw ProtocolError.maxRetriesExceeded
                }

                // Exponential backoff
                let delay = initialRetryDelaySeconds * pow(2.0, Double(retryCount - 1))
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000.0))
                }

                _metrics.successfulResumes += 1
                // Loop continues from currentOffset!
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        _metrics.elapsedTimeSeconds += elapsed

        return accumulatedData
    }
}
