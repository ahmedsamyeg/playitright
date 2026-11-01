import Foundation

// MARK: - Extended models

/// A Plex PIN returned by the TV linking flow.
public struct PlexPin: Codable, Sendable, Equatable {
    public var id: Int
    public var code: String
    public var authToken: String?
    public var expiresIn: Int?
    public var expiresAt: Date?
    public var trusted: Bool?
    public var clientIdentifier: String?

    public init(
        id: Int,
        code: String,
        authToken: String? = nil,
        expiresIn: Int? = nil,
        expiresAt: Date? = nil,
        trusted: Bool? = nil,
        clientIdentifier: String? = nil
    ) {
        self.id = id
        self.code = code
        self.authToken = authToken
        self.expiresIn = expiresIn
        self.expiresAt = expiresAt
        self.trusted = trusted
        self.clientIdentifier = clientIdentifier
    }

    /// Whether the user finished linking and Plex issued a token.
    public var isLinked: Bool {
        guard let authToken else {
            return false
        }
        return !authToken.isEmpty
    }

    /// The URL a user opens on another device to enter ``code``.
    public static let linkingURL = URL(string: "https://plex.tv/link")!

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case authToken
        case expiresIn
        case expiresAt
        case trusted
        case clientIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        code = try container.decode(String.self, forKey: .code)
        authToken = try container.decodeIfPresent(
            String.self,
            forKey: .authToken
        )
        expiresIn = try container.decodeIfPresent(
            Int.self,
            forKey: .expiresIn
        )
        trusted = try container.decodeIfPresent(Bool.self, forKey: .trusted)
        clientIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .clientIdentifier
        )

        if let seconds = try? container.decodeIfPresent(
            TimeInterval.self,
            forKey: .expiresAt
        ) {
            expiresAt = Date(timeIntervalSince1970: seconds)
        } else if let text = try? container.decodeIfPresent(
            String.self,
            forKey: .expiresAt
        ) {
            expiresAt = Self.parseDate(text)
        } else {
            expiresAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(code, forKey: .code)
        try container.encodeIfPresent(authToken, forKey: .authToken)
        try container.encodeIfPresent(expiresIn, forKey: .expiresIn)
        try container.encodeIfPresent(clientIdentifier, forKey: .clientIdentifier)
        try container.encodeIfPresent(trusted, forKey: .trusted)
        try container.encodeIfPresent(
            expiresAt?.timeIntervalSince1970,
            forKey: .expiresAt
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

/// The kind of Plex library section.
public enum PlexSectionType: String, Codable, Sendable, CaseIterable {
    case movie
    case show
    case artist
    case photo
    case unknown

    public init(plexValue: String) {
        self = PlexSectionType(rawValue: plexValue.lowercased()) ?? .unknown
    }

    /// Whether this section contains video that the app can browse.
    public var isVideo: Bool {
        self == .movie || self == .show
    }
}

/// A Plex library section.
public struct PlexSection: Sendable, Equatable, Identifiable {
    public var key: String
    public var type: PlexSectionType
    public var title: String
    public var uuid: String?
    public var updatedAt: Date?

    public var id: String {
        key
    }

    public init(
        key: String,
        type: PlexSectionType,
        title: String,
        uuid: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.key = key
        self.type = type
        self.title = title
        self.uuid = uuid
        self.updatedAt = updatedAt
    }
}

/// A Plex media item type.
public enum PlexMediaType: String, Codable, Sendable, CaseIterable {
    case movie
    case show
    case season
    case episode
    case clip
    case unknown

    public init(plexValue: String) {
        self = PlexMediaType(rawValue: plexValue.lowercased()) ?? .unknown
    }
}

/// A Plex video, show, season, or episode returned by a section query.
public struct PlexMediaItem: Sendable, Equatable, Identifiable {
    public var ratingKey: String
    public var key: String?
    public var type: PlexMediaType
    public var title: String
    public var originalTitle: String?
    public var showTitle: String?
    public var year: Int?
    public var summary: String?
    public var durationMilliseconds: Int64?
    public var index: Int?
    public var parentIndex: Int?
    public var parentRatingKey: String?
    public var grandparentRatingKey: String?
    public var updatedAt: Date?
    public var providerIDs: [String: String]
    public var partKey: String?
    public var partSize: Int64?
    public var container: String?
    public var videoResolution: String?
    public var videoCodec: String?
    public var audioCodec: String?

    public var id: String {
        ratingKey
    }

    /// Duration in seconds, when Plex supplied it.
    public var durationSeconds: Double? {
        durationMilliseconds.map { Double($0) / 1000 }
    }

    public init(
        ratingKey: String,
        key: String? = nil,
        type: PlexMediaType,
        title: String,
        originalTitle: String? = nil,
        showTitle: String? = nil,
        year: Int? = nil,
        summary: String? = nil,
        durationMilliseconds: Int64? = nil,
        index: Int? = nil,
        parentIndex: Int? = nil,
        parentRatingKey: String? = nil,
        grandparentRatingKey: String? = nil,
        updatedAt: Date? = nil,
        providerIDs: [String: String] = [:],
        partKey: String? = nil,
        partSize: Int64? = nil,
        container: String? = nil,
        videoResolution: String? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil
    ) {
        self.ratingKey = ratingKey
        self.key = key
        self.type = type
        self.title = title
        self.originalTitle = originalTitle
        self.showTitle = showTitle
        self.year = year
        self.summary = summary
        self.durationMilliseconds = durationMilliseconds
        self.index = index
        self.parentIndex = parentIndex
        self.parentRatingKey = parentRatingKey
        self.grandparentRatingKey = grandparentRatingKey
        self.updatedAt = updatedAt
        self.providerIDs = providerIDs
        self.partKey = partKey
        self.partSize = partSize
        self.container = container
        self.videoResolution = videoResolution
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
    }
}

/// How the Plex item should be played.
public enum PlexPlaybackPreference: String, Sendable, Equatable {
    /// Play the original part without server transcoding.
    case directPlay

    /// Ask Plex for a direct-stream variant (remux only).
    case directStream

    /// Let the server transcode.
    case transcode
}

// MARK: - XML parsing

/// Errors raised while parsing Plex XML.
public enum PlexXMLError: Error, Equatable, Sendable, LocalizedError {
    case invalidXML(String)
    case notMediaContainer

    public var errorDescription: String? {
        switch self {
        case .invalidXML(let message):
            return "Could not parse the Plex XML response: \(message)"
        case .notMediaContainer:
            return "The Plex response was not a MediaContainer."
        }
    }
}

/// Parses Plex `MediaContainer` XML for sections and media items.
public struct PlexXMLParser: Sendable {
    public init() {}

    /// Parses `/library/sections`.
    public func parseSections(data: Data) throws -> [PlexSection] {
        let root = try parseRoot(data)
        guard root.name == "MediaContainer" else {
            throw PlexXMLError.notMediaContainer
        }

        return root.children
            .filter { $0.name == "Directory" }
            .compactMap { node in
                guard let key = node.attributes["key"],
                      let title = node.attributes["title"] else {
                    return nil
                }
                let type = PlexSectionType(
                    plexValue: node.attributes["type"] ?? ""
                )
                return PlexSection(
                    key: key,
                    type: type,
                    title: title,
                    uuid: node.attributes["uuid"],
                    updatedAt: node.attributes["updatedAt"]
                        .flatMap(Int64.init)
                        .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }
    }

    /// Parses `/library/sections/{key}/all` or `/library/metadata/...`.
    public func parseMedia(data: Data) throws -> [PlexMediaItem] {
        let root = try parseRoot(data)
        guard root.name == "MediaContainer" else {
            throw PlexXMLError.notMediaContainer
        }

        return root.children.compactMap { node in
            switch node.name {
            case "Video":
                return mediaItem(from: node)
            case "Directory" where node.attributes["type"] != nil:
                return mediaItem(from: node)
            default:
                return nil
            }
        }
    }

    private func mediaItem(from node: PlexXMLNode) -> PlexMediaItem? {
        guard let ratingKey = node.attributes["ratingKey"],
              let title = node.attributes["title"] else {
            return nil
        }

        let media = node.children.first { $0.name == "Media" }
        let part = media?.children.first { $0.name == "Part" }

        var providerIDs: [String: String] = [:]
        for guid in node.children where guid.name == "Guid" {
            guard let value = guid.attributes["id"] else {
                continue
            }
            let parts = value.split(
                separator: "://",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2 else {
                continue
            }
            providerIDs[String(parts[0]).lowercased()] = String(parts[1])
        }

        return PlexMediaItem(
            ratingKey: ratingKey,
            key: node.attributes["key"],
            type: PlexMediaType(
                plexValue: node.attributes["type"] ?? ""
            ),
            title: title,
            originalTitle: node.attributes["originalTitle"],
            showTitle: node.attributes["grandparentTitle"],
            year: node.attributes["year"].flatMap(Int.init),
            summary: node.attributes["summary"],
            durationMilliseconds: node.attributes["duration"]
                .flatMap(Int64.init),
            index: node.attributes["index"].flatMap(Int.init),
            parentIndex: node.attributes["parentIndex"].flatMap(Int.init),
            parentRatingKey: node.attributes["parentRatingKey"],
            grandparentRatingKey: node.attributes["grandparentRatingKey"],
            updatedAt: node.attributes["updatedAt"]
                .flatMap(Int64.init)
                .map { Date(timeIntervalSince1970: TimeInterval($0)) },
            providerIDs: providerIDs,
            partKey: part?.attributes["key"],
            partSize: part?.attributes["size"].flatMap(Int64.init),
            container: part?.attributes["container"]
                ?? media?.attributes["container"],
            videoResolution: media?.attributes["videoResolution"],
            videoCodec: media?.attributes["videoCodec"],
            audioCodec: media?.attributes["audioCodec"]
        )
    }

    private func parseRoot(_ data: Data) throws -> PlexXMLNode {
        guard !data.isEmpty else {
            throw PlexXMLError.invalidXML("The response body was empty.")
        }

        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let builder = PlexXMLTreeBuilder()
        parser.delegate = builder

        guard parser.parse(), let root = builder.root else {
            let message = parser.parserError?.localizedDescription
                ?? "unknown XML error"
            throw PlexXMLError.invalidXML(message)
        }
        return root
    }
}

// MARK: - XML tree

private final class PlexXMLNode {
    let name: String
    let attributes: [String: String]
    var children: [PlexXMLNode] = []
    var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
}

private final class PlexXMLTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: PlexXMLNode?
    private var stack: [PlexXMLNode] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = PlexXMLNode(
            name: elementName,
            attributes: attributeDict
        )
        if let parent = stack.last {
            parent.children.append(node)
        } else if root == nil {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !stack.isEmpty {
            stack.removeLast()
        }
    }
}
