import Foundation

/// Which media-server product an adapter is talking to.
public enum MediaServerBrand: String, Codable, Sendable, CaseIterable {
    case jellyfin
    case emby

    /// Guesses the brand from `/System/Info/Public` product metadata.
    public static func detect(productName: String?, serverName: String?) -> MediaServerBrand {
        let combined = "\(productName ?? "") \(serverName ?? "")".lowercased()
        return combined.contains("emby") ? .emby : .jellyfin
    }
}

/// Public server identity returned by `/System/Info/Public`.
public struct JellyfinSystemInfo: Codable, Sendable, Equatable {
    public var serverName: String?
    public var version: String?
    public var productName: String?
    public var id: String?
    public var operatingSystem: String?

    public init(
        serverName: String? = nil,
        version: String? = nil,
        productName: String? = nil,
        id: String? = nil,
        operatingSystem: String? = nil
    ) {
        self.serverName = serverName
        self.version = version
        self.productName = productName
        self.id = id
        self.operatingSystem = operatingSystem
    }

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case productName = "ProductName"
        case id = "Id"
        case operatingSystem = "OperatingSystem"
    }
}

/// One media source (file) attached to a Jellyfin/Emby item.
public struct JellyfinMediaSource: Codable, Sendable, Equatable {
    public var id: String?
    public var path: String?
    public var container: String?
    public var size: Int64?
    public var name: String?

    public init(
        id: String? = nil,
        path: String? = nil,
        container: String? = nil,
        size: Int64? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.path = path
        self.container = container
        self.size = size
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case path = "Path"
        case container = "Container"
        case size = "Size"
        case name = "Name"
    }
}

/// An item returned by `/Items`.
public struct JellyfinItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var type: String
    public var parentID: String?
    public var seriesID: String?
    public var seasonID: String?
    public var indexNumber: Int?
    public var parentIndexNumber: Int?
    public var runTimeTicks: Int64?
    public var dateCreated: Date?
    public var premiereDate: Date?
    public var etag: String?
    public var providerIDs: [String: String]
    public var mediaSources: [JellyfinMediaSource]
    public var container: String?

    /// Duration in seconds from Jellyfin's 100-nanosecond ticks.
    public var durationSeconds: Double? {
        runTimeTicks.map { Double($0) / 10_000_000 }
    }

    public init(
        id: String,
        name: String,
        type: String,
        parentID: String? = nil,
        seriesID: String? = nil,
        seasonID: String? = nil,
        indexNumber: Int? = nil,
        parentIndexNumber: Int? = nil,
        runTimeTicks: Int64? = nil,
        dateCreated: Date? = nil,
        premiereDate: Date? = nil,
        etag: String? = nil,
        providerIDs: [String: String] = [:],
        mediaSources: [JellyfinMediaSource] = [],
        container: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.parentID = parentID
        self.seriesID = seriesID
        self.seasonID = seasonID
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.runTimeTicks = runTimeTicks
        self.dateCreated = dateCreated
        self.premiereDate = premiereDate
        self.etag = etag
        self.providerIDs = providerIDs
        self.mediaSources = mediaSources
        self.container = container
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case parentID = "ParentId"
        case seriesID = "SeriesId"
        case seasonID = "SeasonId"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case runTimeTicks = "RunTimeTicks"
        case dateCreated = "DateCreated"
        case premiereDate = "PremiereDate"
        case etag = "Etag"
        case providerIDs = "ProviderIds"
        case mediaSources = "MediaSources"
        case container = "Container"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(
            String.self,
            forKey: .name
        ) ?? ""
        type = try values.decodeIfPresent(
            String.self,
            forKey: .type
        ) ?? ""
        parentID = try values.decodeIfPresent(
            String.self,
            forKey: .parentID
        )
        seriesID = try values.decodeIfPresent(
            String.self,
            forKey: .seriesID
        )
        seasonID = try values.decodeIfPresent(
            String.self,
            forKey: .seasonID
        )
        indexNumber = try values.decodeIfPresent(
            Int.self,
            forKey: .indexNumber
        )
        parentIndexNumber = try values.decodeIfPresent(
            Int.self,
            forKey: .parentIndexNumber
        )
        runTimeTicks = try values.decodeIfPresent(
            Int64.self,
            forKey: .runTimeTicks
        )
        dateCreated = try values.decodeIfPresent(
            Date.self,
            forKey: .dateCreated
        )
        premiereDate = try values.decodeIfPresent(
            Date.self,
            forKey: .premiereDate
        )
        etag = try values.decodeIfPresent(
            String.self,
            forKey: .etag
        )
        providerIDs = try values.decodeIfPresent(
            [String: String].self,
            forKey: .providerIDs
        ) ?? [:]
        mediaSources = try values.decodeIfPresent(
            [JellyfinMediaSource].self,
            forKey: .mediaSources
        ) ?? []
        container = try values.decodeIfPresent(
            String.self,
            forKey: .container
        )
    }
}

/// A page from `/Items`.
public struct JellyfinItemsPage: Codable, Sendable, Equatable {
    public var items: [JellyfinItem]
    public var totalRecordCount: Int
    public var startIndex: Int

    public init(
        items: [JellyfinItem] = [],
        totalRecordCount: Int = 0,
        startIndex: Int = 0
    ) {
        self.items = items
        self.totalRecordCount = totalRecordCount
        self.startIndex = startIndex
    }

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
        case startIndex = "StartIndex"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent(
            [JellyfinItem].self,
            forKey: .items
        ) ?? []
        totalRecordCount = try container.decodeIfPresent(
            Int.self,
            forKey: .totalRecordCount
        ) ?? items.count
        startIndex = try container.decodeIfPresent(
            Int.self,
            forKey: .startIndex
        ) ?? 0
    }
}

/// A decoded `/Items` response including its HTTP validators.
public struct JellyfinItemsResult: Sendable, Equatable {
    public var page: JellyfinItemsPage
    public var etag: String?
    public var notModified: Bool
    public var lastModified: Date?

    public init(
        page: JellyfinItemsPage,
        etag: String? = nil,
        notModified: Bool = false,
        lastModified: Date? = nil
    ) {
        self.page = page
        self.etag = etag
        self.notModified = notModified
        self.lastModified = lastModified
    }
}

/// The JSON body posted to `/Sessions/Playing/Progress`.
public struct JellyfinProgressReport: Codable, Sendable, Equatable {
    public var itemID: String
    public var positionTicks: Int64
    public var isPaused: Bool
    public var isMuted: Bool
    public var canSeek: Bool
    public var playMethod: String
    public var repeatMode: String?
    public var volumeLevel: Int?

    public init(
        itemID: String,
        positionTicks: Int64,
        isPaused: Bool = false,
        isMuted: Bool = false,
        canSeek: Bool = true,
        playMethod: String = "DirectStream",
        repeatMode: String? = nil,
        volumeLevel: Int? = nil
    ) {
        self.itemID = itemID
        self.positionTicks = positionTicks
        self.isPaused = isPaused
        self.isMuted = isMuted
        self.canSeek = canSeek
        self.playMethod = playMethod
        self.repeatMode = repeatMode
        self.volumeLevel = volumeLevel
    }

    /// Builds a report from a shared watch-state update.
    public init(itemID: String, state: SourceWatchState) {
        self.init(
            itemID: itemID,
            positionTicks: Int64(state.position * 10_000_000)
        )
    }

    /// Ticks from seconds.
    public static func ticks(fromSeconds seconds: Double) -> Int64 {
        Int64(max(0, seconds) * 10_000_000)
    }

    enum CodingKeys: String, CodingKey {
        case itemID = "ItemId"
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case isMuted = "IsMuted"
        case canSeek = "CanSeek"
        case playMethod = "PlayMethod"
        case repeatMode = "RepeatMode"
        case volumeLevel = "VolumeLevel"
    }
}

/// Errors raised by the Jellyfin/Emby client.
public enum JellyfinError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case unauthorized
    case notFound(String)
    case httpStatus(Int, message: String?)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "Could not build a Jellyfin request URL for '\(value)'."
        case .invalidResponse:
            return "The media server returned a non-HTTP response."
        case .unauthorized:
            return "The media server rejected the token. Sign in again."
        case .notFound(let value):
            return "The media server did not find '\(value)'."
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                return "The media server returned HTTP \(status): \(message)"
            }
            return "The media server returned HTTP \(status)."
        case .decoding(let message):
            return "Could not decode the media server response: \(message)"
        case .transport(let message):
            return "Media server request failed: \(message)"
        }
    }
}
