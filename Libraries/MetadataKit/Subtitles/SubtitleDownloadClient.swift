import Foundation

// MARK: - Domain

/// A search the user initiated from the track picker (PB-2.3, doc 04 §2.3).
public struct SubtitleSearchQuery: Sendable, Equatable {
    /// BCP-47 language codes the user wants, e.g. `["en", "de"]`.
    public var languages: [String]

    /// Human-friendly title the user searched for.
    public var title: String

    /// Optional series information.
    public var seasonNumber: Int?
    public var episodeNumber: Int?

    /// Optional IMDb identifier for hash/search based matching.
    public var imdbID: String?

    /// The media file URL, used for sidecar naming and subtitle-hash lookups.
    public var mediaFileURL: URL?

    public init(
        languages: [String],
        title: String,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        imdbID: String? = nil,
        mediaFileURL: URL? = nil
    ) {
        self.languages = languages
        self.title = title
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.imdbID = imdbID
        self.mediaFileURL = mediaFileURL
    }

    /// URL-encoded `languages` parameter, e.g. `en,de`.
    public var languagesParameter: String {
        languages.map { Self.normalizeLanguage($0) }.joined(separator: ",")
    }

    /// Canonical three-letter provider form; spelled-out provider names
    /// ("German", "English") map through the same tables.
    public static func normalizeLanguage(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if let exact = languageCodeTable[lowered] {
            return exact
        }
        if let spelled = languageWordTable[lowered] {
            return spelled
        }
        guard let base = lowered.split(separator: "-").first else {
            return lowered
        }
        if base.count == 2, let pair = languageCodeTable[String(base)] {
            return pair
        }
        let three = String(base.prefix(3))
        if let triple = languageCodeTable[three] {
            return triple
        }
        return lowered
    }

    /// Spelled-out language names both providers return.
    static let languageWordTable: [String: String] = [
        "english": "en",
        "german": "de",
        "french": "fr",
        "spanish": "es",
        "italian": "it",
        "japanese": "ja",
        "korean": "ko",
        "portuguese": "pt",
        "russian": "ru",
        "chinese": "zh",
        "dutch": "nl",
        "turkish": "tr",
        "polish": "pl"
    ]

    /// Two- and three-letter pairs the providers agree on.
    static let languageCodeTable: [String: String] = [
        "en": "en", "eng": "en",
        "de": "de", "ger": "de",
        "fr": "fr", "fre": "fr",
        "es": "es", "spa": "es",
        "it": "it", "ita": "it",
        "ja": "ja", "jpn": "ja",
        "ko": "ko", "kor": "ko",
        "pt": "pt", "por": "pt",
        "ru": "ru", "rus": "ru",
        "zh": "zh", "chi": "zh",
        "nl": "nl", "dut": "nl",
        "tr": "tr", "tur": "tr",
        "pl": "pl", "pol": "pl"
    ]
}

/// One candidate from a provider.
public struct SubtitleSearchResult: Sendable, Equatable {
    /// Deliverable subtitle language (three-letter provider code).
    public var language: String

    /// Candidate display name, usually the release label the subtitle was
    /// synced against.
    public var release: String

    /// Numeric provider identifier needed to request a download URL.
    public var providerFileID: String

    /// Provider the result came from.
    public var provider: SubtitleProviderKind

    /// Optional quality hint from the provider (hearing impaired, forced).
    public var isHearingImpaired: Bool

    public init(
        language: String,
        release: String,
        providerFileID: String,
        provider: SubtitleProviderKind,
        isHearingImpaired: Bool = false
    ) {
        self.language = language
        self.release = release
        self.providerFileID = providerFileID
        self.provider = provider
        self.isHearingImpaired = isHearingImpaired
    }
}

/// Which backend produced a result.
public enum SubtitleProviderKind: String, Sendable, CaseIterable, Equatable {
    case openSubtitles
    case subscene
}

/// A fetched subtitle sidecar.
public struct SubtitleDownload: Sendable, Equatable {
    /// Location of the downloaded file (SRT, in the sidecar cache).
    public var fileURL: URL

    /// Language the file was requested in.
    public var language: String

    public init(fileURL: URL, language: String) {
        self.fileURL = fileURL
        self.language = language
    }
}

// MARK: - Errors

public enum SubtitleDownloadError: Error, Sendable, Equatable, LocalizedError {
    case notFound(String)
    case httpStatus(Int, message: String?)
    case invalidResponse
    case decoding(String)
    case transport(String)
    case unsupportedArchive(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let message):
            return message
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                return "The subtitle provider returned HTTP \(status): \(message)"
            }
            return "The subtitle provider returned HTTP \(status)."
        case .invalidResponse:
            return "The subtitle provider returned a non-HTTP response."
        case .decoding(let message):
            return "Could not decode the subtitle provider response: \(message)"
        case .transport(let message):
            return "Subtitle download failed: \(message)"
        case .unsupportedArchive(let extensionName):
            return "Subtitle archive format '\(extensionName)' is not supported."
        }
    }
}

// MARK: - Provider transport

/// The subset of HTTP both providers need, testable with mocked sessions.
public protocol SubtitleHTTPTransport: Sendable {
    func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct DefaultSubtitleHTTPTransport: SubtitleHTTPTransport {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SubtitleDownloadError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SubtitleDownloadError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SubtitleDownloadError.httpStatus(
                http.statusCode,
                message: http.allHeaderFields["X-Error-Message"] as? String
            )
        }
        return (data, http)
    }
}

// MARK: - Provider protocol

/// One subtitle backend (OpenSubtitles- or Subscene-shaped).
public protocol SubtitleProviding: Sendable {
    var kind: SubtitleProviderKind { get }
    func search(_ query: SubtitleSearchQuery) async throws -> [SubtitleSearchResult]
    func downloadURL(for result: SubtitleSearchResult) async throws -> URL
}

// MARK: - OpenSubtitles

public struct OpenSubtitlesConfiguration: Sendable, Equatable {
    public static let defaultBaseURL = URL(string: "https://api.opensubtitles.com/api/v1/")!

    public var baseURL: URL

    /// OpenSubtitles REST API key ("Api-Key" header).
    public var apiKey: String?

    public init(
        apiKey: String? = nil,
        baseURL: URL = OpenSubtitlesConfiguration.defaultBaseURL
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

/// OpenSubtitles REST backend (`api.opensubtitles.com/api/v1`).
public struct OpenSubtitlesClient: SubtitleProviding {
    public let kind: SubtitleProviderKind = .openSubtitles

    var configuration: OpenSubtitlesConfiguration
    var transport: SubtitleHTTPTransport

    public init(
        configuration: OpenSubtitlesConfiguration = OpenSubtitlesConfiguration(),
        transport: SubtitleHTTPTransport = DefaultSubtitleHTTPTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func search(_ query: SubtitleSearchQuery) async throws -> [SubtitleSearchResult] {
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("subtitles"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "query", value: query.title),
            URLQueryItem(name: "languages", value: query.languagesParameter)
        ]
        if let season = query.seasonNumber {
            items.append(URLQueryItem(name: "season_number", value: String(season)))
        }
        if let episode = query.episodeNumber {
            items.append(URLQueryItem(name: "episode_number", value: String(episode)))
        }
        if let imdb = query.imdbID {
            items.append(URLQueryItem(name: "imdb_id", value: imdb))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue(
            configuration.apiKey,
            forHTTPHeaderField: "Api-Key"
        )
        request.setValue("PlayItRight/1.0", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await transport.run(request)
        do {
            return try Self.decodeSearch(data: data, providerURL: nil)
        } catch {
            throw SubtitleDownloadError.decoding(
                String(data: data.prefix(200), encoding: .utf8) ?? "binary"
            )
        }
    }

    /// Decodes the OpenSubtitles search response shape:
    /// `{ "data": [ { "attributes": { "files": [ { "file_id": 1, "file_name": … } ],
    /// "release": …, "language": …, "hearing_impaired": … } ] } }`.
    static func decodeSearch(data: Data, providerURL: URL?) throws -> [SubtitleSearchResult] {
        struct Response: Decodable {
            struct Entry: Decodable {
                struct Attributes: Decodable {
                    struct File: Decodable {
                        let file_id: Int?
                        let file_name: String?
                    }
                    let release: String?
                    let language: String?
                    let hearing_impaired: Bool?
                    let files: [File]?
                }
                let attributes: Attributes?
            }
            let data: [Entry]?
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SubtitleDownloadError.decoding(error.localizedDescription)
        }
        return (decoded.data ?? []).compactMap { entry in
            guard let attributes = entry.attributes,
                  let file = attributes.files?.first,
                  let fileID = file.file_id,
                  let language = attributes.language else {
                return nil
            }
            return SubtitleSearchResult(
                language: SubtitleSearchQuery.normalizeLanguage(language),
                release: attributes.release ?? file.file_name ?? "",
                providerFileID: String(fileID),
                provider: .openSubtitles,
                isHearingImpaired: attributes.hearing_impaired ?? false
            )
        }
    }

    public func downloadURL(for result: SubtitleSearchResult) async throws -> URL {
        struct RequestDTO: Encodable {
            let file_id: String
        }
        struct ResponseDTO: Decodable {
            let link: String?
        }
        var request = URLRequest(
            url: configuration.baseURL.appendingPathComponent("download")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("PlayItRight/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(RequestDTO(file_id: result.providerFileID))

        let (data, _) = try await transport.run(request)
        guard let decoded = try? JSONDecoder().decode(ResponseDTO.self, from: data),
              let link = decoded.link,
              let url = URL(string: link) else {
            throw SubtitleDownloadError.decoding(
                String(data: data.prefix(200), encoding: .utf8) ?? "binary"
            )
        }
        return url
    }
}

// MARK: - Subscene

public struct SubsceneConfiguration: Sendable, Equatable {
    public static let defaultBaseURL = URL(string: "https://subscene.com")!

    public var baseURL: URL

    public init(baseURL: URL = SubsceneConfiguration.defaultBaseURL) {
        self.baseURL = baseURL
    }
}

/// Subscene backend. The public API is a JSON search endpoint with a
/// direct download URL per candidate; both are wrapped defensively.
public struct SubsceneClient: SubtitleProviding {
    public let kind: SubtitleProviderKind = .subscene

    var configuration: SubsceneConfiguration
    var transport: SubtitleHTTPTransport

    public init(
        configuration: SubsceneConfiguration = SubsceneConfiguration(),
        transport: SubtitleHTTPTransport = DefaultSubtitleHTTPTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func search(_ query: SubtitleSearchQuery) async throws -> [SubtitleSearchResult] {
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("api/subtitles"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "query", value: query.title),
            URLQueryItem(name: "languages", value: query.languagesParameter)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("PlayItRight/1.0", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await transport.run(request)
        do {
            return try Self.decodeSearch(data: data)
        } catch {
            throw SubtitleDownloadError.decoding(
                String(data: data.prefix(200), encoding: .utf8) ?? "binary"
            )
        }
    }

    /// Decodes the simplified Subscene search envelope:
    /// `{ "subtitles": [ { "id": "…", "name": "…", "language": "…",
    /// "hearing_impaired": … } ] }`; download URLs are built from ids.
    static func decodeSearch(data: Data) throws -> [SubtitleSearchResult] {
        struct ResponseDTO: Decodable {
            struct Entry: Decodable {
                let id: String?
                let name: String?
                let language: String?
                let hearing_impaired: Bool?
            }
            let subtitles: [Entry]?
        }
        let decoded: ResponseDTO
        do {
            decoded = try JSONDecoder().decode(ResponseDTO.self, from: data)
        } catch {
            throw SubtitleDownloadError.decoding(error.localizedDescription)
        }
        return (decoded.subtitles ?? []).compactMap { entry in
            guard let id = entry.id, let language = entry.language else {
                return nil
            }
            return SubtitleSearchResult(
                language: SubtitleSearchQuery.normalizeLanguage(language),
                release: entry.name ?? "",
                providerFileID: id,
                provider: .subscene,
                isHearingImpaired: entry.hearing_impaired ?? false
            )
        }
    }

    public func downloadURL(for result: SubtitleSearchResult) async throws -> URL {
        configuration.baseURL.appendingPathComponent("subtitles/\(result.providerFileID).srt")
    }
}

// MARK: - Client

/// User-initiated subtitle search and download over OpenSubtitles and
/// Subscene with language matching and sidecar caching (PB-2.3, doc 04
/// §2.3; App Store policy requires the user initiate every transfer, so
/// there is no background prefetch path here).
public struct SubtitleDownloadClient: Sendable {
    public let providers: [SubtitleProviding]

    /// Directory sidecars are cached under.
    public let cacheDirectory: URL

    /// Transport used for the direct subtitle file download (the provider
    /// backends carry their own).
    public let transport: SubtitleHTTPTransport

    public init(
        providers: [SubtitleProviding],
        cacheDirectory: URL? = nil,
        transport: SubtitleHTTPTransport = DefaultSubtitleHTTPTransport()
    ) {
        self.providers = providers
        self.cacheDirectory = cacheDirectory
            ?? URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0])
                .appendingPathComponent("Subtitles", isDirectory: true)
        self.transport = transport
    }

    /// Runs the search across every provider, deduplicated per
    /// (language, release) pair, preserving the first hit.
    public func search(_ query: SubtitleSearchQuery) async throws -> [SubtitleSearchResult] {
        var merged: [SubtitleSearchResult] = []
        var seen = Set<String>()
        for provider in providers {
            let results = try await provider.search(query)
            for result in results {
                let key = "\(result.language)|\(result.release.lowercased())"
                if seen.insert(key).inserted {
                    merged.append(result)
                }
            }
        }
        return merged.filter { result in
            query.languages.contains { language in
                SubtitleSearchQuery.normalizeLanguage(language) == result.language
            }
        }
    }

    /// Downloads one result and caches it as a sidecar named after the
    /// media file (when the originating query carries one):
    /// `<base>.<lang>.srt`. Pass `skipIfCached: true` to reuse an existing
    /// sidecar instead of refetching.
    public func download(
        _ result: SubtitleSearchResult,
        for query: SubtitleSearchQuery? = nil,
        skipIfCached: Bool = false
    ) async throws -> SubtitleDownload {
        guard let provider = providers.first(where: { $0.kind == result.provider }) else {
            throw SubtitleDownloadError.notFound(
                "Provider '\(result.provider)' is not configured."
            )
        }
        if skipIfCached, let query,
           let cached = cachedSidecar(for: query) {
            return cached
        }
        let url = try await provider.downloadURL(for: result)
        return try await downloadFile(
            url: url,
            provider: result.provider,
            language: result.language,
            mediaFileURL: query?.mediaFileURL
        )
    }

    private func downloadFile(
        url: URL,
        provider: SubtitleProviderKind,
        language: String,
        mediaFileURL: URL? = nil
    ) async throws -> SubtitleDownload {
        var request = URLRequest(url: url)
        request.setValue("PlayItRight/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await transport.run(request)

        let name = sidecarName(
            mediaFileURL: mediaFileURL,
            language: language,
            provider: provider
        )
        let destination = cacheDirectory
            .appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return SubtitleDownload(fileURL: destination, language: language)
    }

    /// Sidecar caching name: the media file's base name plus the language,
    /// e.g. `movie.2020.mkv` media file becomes `movie.2020.en.srt`. When
    /// no media file is associated the provider's own name stands in.
    public func sidecarName(
        mediaFileURL: URL?,
        language: String,
        provider: SubtitleProviderKind
    ) -> String {
        let base: String
        if let lastComponent = mediaFileURL?.lastPathComponent,
           !lastComponent.isEmpty {
            let withoutExtension = (lastComponent as NSString).deletingPathExtension
            base = withoutExtension
        } else {
            base = provider.rawValue
        }
        return "\(base).\(language).srt"
    }

    /// replays never refetch: a sidecar for this media file + language is
    /// reused when it already exists in the cache.
    public func cachedSidecar(
        for query: SubtitleSearchQuery
    ) -> SubtitleDownload? {
        guard let media = query.mediaFileURL else { return nil }
        for language in query.languages {
            let normalized = SubtitleSearchQuery.normalizeLanguage(language)
            let name = sidecarName(
                mediaFileURL: media,
                language: normalized,
                provider: .openSubtitles
            )
            let fileURL = cacheDirectory.appendingPathComponent(name, isDirectory: false)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return SubtitleDownload(fileURL: fileURL, language: normalized)
            }
        }
        return nil
    }
}
