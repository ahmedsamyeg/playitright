import Testing
import Foundation

@Suite("MediaServerSpike Tests")
struct MediaServerSpikeTests {

    @Test("Plex PIN authorization flow and polling state machine")
    func testPlexPinFlow() async throws {
        final class PlexMockState: @unchecked Sendable {
            var pollCount = 0
        }
        let mockState = PlexMockState()

        let authEngine = PlexPinAuthEngine(
            requestPin: {
                return PlexPinAuthEngine.PinResponse(id: 42, code: "K9XZ", expiresIn: 300, authToken: nil)
            },
            pollPin: { id in
                mockState.pollCount += 1
                if mockState.pollCount >= 2 {
                    return PlexPinAuthEngine.PinResponse(id: id, code: "K9XZ", expiresIn: 250, authToken: "tok_secret_987")
                } else {
                    return PlexPinAuthEngine.PinResponse(id: id, code: "K9XZ", expiresIn: 280, authToken: nil)
                }
            }
        )

        let pinCode = try await authEngine.startLinking()
        #expect(pinCode == "K9XZ")
        let initialState = await authEngine.state
        #expect(initialState == .waitingForUser(pinCode: "K9XZ", expiresInSeconds: 300))

        // Poll 1: still waiting
        let poll1 = try await authEngine.pollStatus()
        #expect(poll1 == .waitingForUser(pinCode: "K9XZ", expiresInSeconds: 300))

        // Poll 2: authorized!
        let poll2 = try await authEngine.pollStatus()
        #expect(poll2 == .authorized(authToken: "tok_secret_987"))
    }

    @Test("ETag conditional GET returns cached data on HTTP 304 Not Modified")
    func testETagCaching() async throws {
        final class MockServerState: @unchecked Sendable {
            var etag = "\"etag-v1\""
            var payload = Data("Item List V1".utf8)
            var requestCount = 0
        }
        let server = MockServerState()

        let client = ETagCacheClient { url, ifNoneMatch in
            server.requestCount += 1
            if ifNoneMatch == server.etag {
                return (statusCode: 304, data: Data(), etag: server.etag)
            } else {
                return (statusCode: 200, data: server.payload, etag: server.etag)
            }
        }

        let testURL = URL(string: "https://jellyfin.local/Items")!

        // Initial fetch: 200 OK
        let fetch1 = try await client.fetch(url: testURL)
        #expect(fetch1 == .modified(data: Data("Item List V1".utf8), etag: "\"etag-v1\""))
        #expect(server.requestCount == 1)

        // Second fetch with same ETag: 304 Not Modified, returns cached data
        let fetch2 = try await client.fetch(url: testURL)
        #expect(fetch2 == .notModified(cachedData: Data("Item List V1".utf8)))
        #expect(server.requestCount == 2)

        // Server updates content & ETag
        server.etag = "\"etag-v2\""
        server.payload = Data("Item List V2".utf8)

        // Third fetch: 200 OK with new data
        let fetch3 = try await client.fetch(url: testURL)
        #expect(fetch3 == .modified(data: Data("Item List V2".utf8), etag: "\"etag-v2\""))
        #expect(server.requestCount == 3)
    }

    @Test("Offline mutation queue coalescing and reconnect flush")
    func testOfflineMutationQueue() async {
        let queue = OfflineMutationQueue()

        // Enqueue progress for item 101: 10s, then 20s, then 30s
        await queue.enqueue(WatchStateMutation(sourceId: "plex1", itemKey: "101", positionSeconds: 10.0, durationSeconds: 100.0, isWatched: false))
        await queue.enqueue(WatchStateMutation(sourceId: "plex1", itemKey: "101", positionSeconds: 20.0, durationSeconds: 100.0, isWatched: false))
        await queue.enqueue(WatchStateMutation(sourceId: "plex1", itemKey: "101", positionSeconds: 30.0, durationSeconds: 100.0, isWatched: false))

        // Enqueue progress for item 102
        await queue.enqueue(WatchStateMutation(sourceId: "plex1", itemKey: "102", positionSeconds: 50.0, durationSeconds: 100.0, isWatched: false))

        // Total pending items should be 2 (coalesced 101, plus 102)
        let pending = await queue.pendingCount
        #expect(pending == 2)

        // Attempt flush while network is failing
        let failResult = await queue.flush { _ in
            throw NSError(domain: "NetworkError", code: -1009, userInfo: nil)
        }
        #expect(failResult.succeeded == 0)
        #expect(failResult.failed == 2)
        let remainingAfterFail = await queue.pendingCount
        #expect(remainingAfterFail == 2)

        // Attempt flush when network is restored
        final class ResultBox: @unchecked Sendable {
            var syncedItems: [String] = []
        }
        let box = ResultBox()
        let successResult = await queue.flush { mutation in
            box.syncedItems.append(mutation.itemKey)
            if mutation.itemKey == "101" {
                #expect(mutation.positionSeconds == 30.0) // Must be the coalesced latest position!
            }
        }
        #expect(successResult.succeeded == 2)
        #expect(successResult.failed == 0)
        let remainingAfterSuccess = await queue.pendingCount
        #expect(remainingAfterSuccess == 0)
        #expect(box.syncedItems == ["101", "102"])
    }
}
