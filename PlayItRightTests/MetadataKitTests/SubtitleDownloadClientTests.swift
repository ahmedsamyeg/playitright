import Foundation
import Testing
@testable import MetadataKit

// MARK: - Test doubles

private struct SubtitleMockError: Error, Sendable {
    let message: String
}

/// Handler-driven transport, mirroring the mock-URLProtocol pattern used by
/// the other MetadataKit client tests.
private final class SubtitleMockTransport: SubtitleHTTPTransport, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) private static var handlers: [(String, Handler)] = []
    private static let lock = NSLock()

    static func install(_ host: String, _ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers.append((host, handler))
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handlers = []
    }

    func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler = try Self.handler(for: request.url?.host)
        let (response, data) = try handler(request)
        return (data, response)
    }

    private static func handler(for host: String?) throws -> Handler {
        lock.lock()
        defer { lock.unlock() }
        if let match = handlers.last(where: { $0.0 == host }) {
            return match.1
        }
        return { _ in throw SubtitleMockError(message: "No handler for \(host ?? "unknown")") }
    }
}

private func subtitleRespond(
    to request: URLRequest,
    status: Int = 200,
    headers: [String: String] = [:],
    bytes: Data
) throws -> (HTTPURLResponse, Data) {
    guard let url = request.url,
          let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
          ) else {
        throw SubtitleMockError(message: "Could not build an HTTP response")
    }
    return (response, bytes)
}

private func subtitleJSON(_ body: String) -> Data {
    Data(body.utf8)
}

private final class SubtitleRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(request)
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private let opensubtitlesSearchJSON = """
{
  "data": [
    {
      "attributes": {
        "release": "Movie.2020.1080p.BluRay",
        "language": "eng",
        "hearing_impaired": true,
        "files": [
          { "file_id": 4242, "file_name": "Movie.2020.en.srt" }
        ]
      }
    },
    {
      "attributes": {
        "release": "Movie.2020.WEBRip",
        "language": "en",
        "hearing_impaired": false,
        "files": [
          { "file_id": 4243, "file_name": null }
        ]
      }
    },
    {
      "attributes": { "release": "No files", "language": "eng", "files": [] }
    }
  ]
}
"""

private let subsceneSearchJSON = """
{
  "subtitles": [
    { "id": "s-77", "name": "Movie 2020 subs", "language": "German",
      "hearing_impaired": false },
    { "id": "s-78", "name": "English web", "language": "English",
      "hearing_impaired": true },
    { "id": null, "name": "broken", "language": "English" }
  ]
}
"""

/// In-app subtitle provider download tests (TASK-4.4, PB-2.3).
@Suite(.serialized)
struct SubtitleDownloadClientTests {
    private var tempDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SubtitleCache-\(UUID().uuidString)", isDirectory: true)
    }

    private func openClient(
        recorder: SubtitleRequestRecorder? = nil,
        baseURL: URL = OpenSubtitlesConfiguration.defaultBaseURL
    ) -> OpenSubtitlesClient {
        let transport = SubtitleMockTransport()
        SubtitleMockTransport.install("api.opensubtitles.com") { request in
            recorder?.record(request)
            if request.url?.path.hasSuffix("/subtitles") == true {
                return try subtitleRespond(to: request, bytes: subtitleJSON(opensubtitlesSearchJSON))
            }
            if request.url?.path.hasSuffix("/download") == true {
                return try subtitleRespond(
                    to: request,
                    bytes: subtitleJSON(#"{"link":"https://dl.opensubtitles.com/s/4242.srt"}"#)
                )
            }
            return try subtitleRespond(to: request, bytes: subtitleJSON("{}"))
        }
        return OpenSubtitlesClient(
            configuration: OpenSubtitlesConfiguration(apiKey: "test-key", baseURL: baseURL),
            transport: transport
        )
    }

    private func subsceneClient(
        recorder: SubtitleRequestRecorder? = nil
    ) -> SubsceneClient {
        let transport = SubtitleMockTransport()
        SubtitleMockTransport.install("subscene.com") { request in
            recorder?.record(request)
            return try subtitleRespond(to: request, bytes: subtitleJSON(subsceneSearchJSON))
        }
        return SubsceneClient(transport: transport)
    }

    // MARK: - Providers decode responses

    @Test
    func decodesOpenSubtitlesSearchResults() throws {
        let results = try OpenSubtitlesClient.decodeSearch(
            data: subtitleJSON(opensubtitlesSearchJSON),
            providerURL: nil
        )
        #expect(results.count == 2)
        #expect(results[0].providerFileID == "4242")
        #expect(results[0].language == "en")
        #expect(results[0].isHearingImpaired == true)
        #expect(results[0].provider == .openSubtitles)
        #expect(results[1].providerFileID == "4243")
    }

    @Test
    func decodesSubsceneSearchResults() throws {
        let results = try SubsceneClient.decodeSearch(data: subtitleJSON(subsceneSearchJSON))
        #expect(results.count == 2)
        // "German" normalizes to the three-letter-friendly "de" form table.
        #expect(results[0].language == "de")
        #expect(results[0].providerFileID == "s-77")
        #expect(results[1].language == "en")
        #expect(results[1].isHearingImpaired == true)
    }

    // MARK: - Search merges and language-filters

    @Test
    func mergesProvidersAndDeduplicates() async throws {
        SubtitleMockTransport.reset()
        _ = openClient()
        _ = subsceneClient()

        let client = SubtitleDownloadClient(
            providers: [
                OpenSubtitlesClient(
                    configuration: OpenSubtitlesConfiguration(apiKey: "k"),
                    transport: SubtitleMockTransport()
                ),
                SubsceneClient(transport: SubtitleMockTransport())
            ],
            transport: SubtitleMockTransport()
        )
        let merged = try await client.search(
            SubtitleSearchQuery(languages: ["en"], title: "Movie 2020")
        )
        // OpenSubtitles rows plus Subscene's English candidate; Subscene's
        // German candidate is filtered out by the language match. Release
        // labels differ so nothing deduplicates away.
        #expect(merged.count == 3)
        #expect(merged.allSatisfy { $0.language == "en" })
    }

    @Test
    func buildsCorrectOpenSubtitlesQuery() async throws {
        SubtitleMockTransport.reset()
        let recorder = SubtitleRequestRecorder()
        _ = openClient(recorder: recorder)
        let client = OpenSubtitlesClient(
            configuration: OpenSubtitlesConfiguration(apiKey: "test-key"),
            transport: SubtitleMockTransport()
        )
        _ = try await client.search(
            SubtitleSearchQuery(
                languages: ["English"],
                title: "Movie 2020",
                seasonNumber: 2,
                episodeNumber: 5,
                imdbID: "tt123"
            )
        )
        let request = try #require(recorder.requests.first)
        let url = try #require(request.url)
        let items = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        let languages = try #require(items.first(name: "languages")?.value)
        #expect(languages == "en")
        #expect(items.first(name: "season_number")?.value == "2")
        #expect(items.first(name: "episode_number")?.value == "5")
        #expect(items.first(name: "imdb_id")?.value == "tt123")
        // User-Agent + Api-Key headers are explicit per App Store policy.
        #expect(request.value(forHTTPHeaderField: "Api-Key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "PlayItRight/1.0")
    }

    // MARK: - Download + sidecar caching

    @Test
    func downloadsSubtitleToSidecarCache() async throws {
        SubtitleMockTransport.reset()
        SubtitleMockTransport.install("dl.opensubtitles.com") { request in
            try subtitleRespond(to: request, bytes: Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8))
        }
        SubtitleMockTransport.install("api.opensubtitles.com") { request in
            try subtitleRespond(
                to: request,
                bytes: subtitleJSON(#"{"link":"https://dl.opensubtitles.com/s/4242.srt"}"#)
            )
        }
        let cache = tempDirectory
        defer { try? FileManager.default.removeItem(at: cache) }

        let client = SubtitleDownloadClient(
            providers: [
                OpenSubtitlesClient(
                    configuration: OpenSubtitlesConfiguration(apiKey: "k"),
                    transport: SubtitleMockTransport()
                )
            ],
            cacheDirectory: cache,
            transport: SubtitleMockTransport()
        )
        let download = try await client.download(
            SubtitleSearchResult(
                language: "en",
                release: "Movie.2020.BluRay",
                providerFileID: "4242",
                provider: .openSubtitles
            ),
            for: SubtitleSearchQuery(
                languages: ["en"],
                title: "Movie 2020",
                mediaFileURL: URL(fileURLWithPath: "/media/Movie.2020.mkv")
            )
        )
        let fileName = download.fileURL.lastPathComponent
        #expect(fileName == "Movie.2020.en.srt")
        let data = try Data(contentsOf: download.fileURL)
        #expect(String(data: data, encoding: .utf8)?.contains("Hi") == true)
    }

    @Test
    func reusesCachedSidecarWhenSkipping() async throws {
        SubtitleMockTransport.reset()
        // No handlers installed: any network call fails. The cached path
        // must short-circuit.
        let cache = tempDirectory
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        try Data("cached".utf8).write(
            to: cache.appendingPathComponent("Movie.2020.en.srt")
        )

        let client = SubtitleDownloadClient(
            providers: [
                OpenSubtitlesClient(
                    configuration: OpenSubtitlesConfiguration(apiKey: "k"),
                    transport: SubtitleMockTransport()
                )
            ],
            cacheDirectory: cache,
            transport: SubtitleMockTransport()
        )
        let query = SubtitleSearchQuery(
            languages: ["en"],
            title: "Movie 2020",
            mediaFileURL: URL(fileURLWithPath: "/media/Movie.2020.mkv")
        )
        let cached = try #require(client.cachedSidecar(for: query))
        #expect(cached.fileURL.lastPathComponent == "Movie.2020.en.srt")

        // en-US normalizes to the same sidecar name, so the cache hits.
        let requestedAgain = try #require(
            client.cachedSidecar(
                for: SubtitleSearchQuery(
                    languages: ["en-US"],
                    title: "Movie 2020",
                    mediaFileURL: URL(fileURLWithPath: "/media/Movie.2020.mkv")
                )
            )
        )
        #expect(requestedAgain.fileURL == cached.fileURL)
    }
}

private extension [URLQueryItem] {
    func first(name: String) -> URLQueryItem? {
        first { $0.name == name }
    }
}
