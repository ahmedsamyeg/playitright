import Testing
import Foundation

@Suite("ResilientByteStreamReader Tests")
struct ResilientByteStreamReaderTests {

    @Test("Seamless continuous ranged read without connection drops")
    func testContinuousRead() async throws {
        // Create 100KB dummy test payload
        let testPayload = Data((0..<100_000).map { UInt8($0 % 256) })

        let reader = ResilientByteStreamReader(maxRetries: 3) { request in
            let start = Int(request.offset)
            guard start < testPayload.count else { return Data() }
            let len = min(Int(request.length ?? 65536), testPayload.count - start)
            return testPayload.subdata(in: start..<(start + len))
        }

        let result = try await reader.readRange(offset: 10_000, length: 50_000)
        #expect(result.count == 50_000)
        #expect(result == testPayload.subdata(in: 10_000..<60_000))
        let metrics = await reader.metrics
        #expect(metrics.bytesRead == 50_000)
        #expect(metrics.connectionDrops == 0)
        #expect(metrics.successfulResumes == 0)
    }

    @Test("Mid-stream connection drop triggers automatic resume at exact offset")
    func testMidStreamConnectionDropAndResume() async throws {
        let testPayload = Data((0..<100_000).map { UInt8($0 % 256) })

        final class StateBox: @unchecked Sendable {
            var dropInjected = false
        }
        let state = StateBox()

        let reader = ResilientByteStreamReader(
            maxRetries: 3,
            initialRetryDelaySeconds: 0.001
        ) { request in
            // Simulate connection drop after 20,000 bytes have been read
            if request.offset >= 30_000 && !state.dropInjected {
                state.dropInjected = true
                throw ProtocolError.connectionDropped
            }

            let start = Int(request.offset)
            guard start < testPayload.count else { return Data() }
            // Deliver in 10KB chunks
            let maxChunk = 10_000
            let len = min(Int(request.length ?? UInt64(maxChunk)), maxChunk, testPayload.count - start)
            return testPayload.subdata(in: start..<(start + len))
        }

        let result = try await reader.readRange(offset: 10_000, length: 40_000)
        #expect(result.count == 40_000)
        #expect(result == testPayload.subdata(in: 10_000..<50_000))

        let metrics = await reader.metrics
        #expect(metrics.bytesRead == 40_000)
        #expect(metrics.connectionDrops == 1)
        #expect(metrics.successfulResumes == 1)
        #expect(state.dropInjected == true)
    }

    @Test("Exceeding maximum retries aborts with maxRetriesExceeded error")
    func testMaxRetriesExceeded() async {
        let reader = ResilientByteStreamReader(
            maxRetries: 2,
            initialRetryDelaySeconds: 0.001
        ) { _ in
            throw ProtocolError.connectionDropped
        }

        do {
            _ = try await reader.readRange(offset: 0, length: 1000)
            Issue.record("Expected maxRetriesExceeded error")
        } catch let error as ProtocolError {
            #expect(error == .maxRetriesExceeded)
            let metrics = await reader.metrics
            #expect(metrics.connectionDrops == 3) // Initial attempt + 2 retries
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
