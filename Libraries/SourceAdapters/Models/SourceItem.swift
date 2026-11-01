import Foundation

/// The kind of thing a source returns.
public enum SourceItemKind: String, Codable, Sendable, CaseIterable, Equatable {
    case movie
    case show
    case season
    case episode
    case folder
    case playlist
    case unknown
}

/// A file or container discovered in a source.
///
/// `id` is the source adapter's stable identity for the item (doc 03 SRC-19).
/// `location` is adapter-specific: a path, URL, or provider id that
/// ``SourceAdapter/read(session:item:range:)`` can resolve.
public struct SourceItem: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var sourceID: UUID
    public var kind: SourceItemKind
    public var name: String
    public var location: String

    /// Parent container id, when the adapter has a hierarchy.
    public var parentID: String?

    /// Size in bytes, when known.
    public var sizeBytes: Int64?

    /// Last modification time, when the source exposes one.
    public var modifiedAt: Date?

    /// ETag or equivalent validator for freshness checks.
    public var etag: String?

    /// Container/extension hint such as `mkv` or `mp4`.
    public var container: String?

    /// Duration in seconds, when server metadata supplies it.
    public var durationSeconds: Double?

    /// Provider ids known from server metadata, for example
    /// `["tmdb": "27205", "imdb": "tt1375666"]`.
    public var providerIDs: [String: String]

    public init(
        id: String,
        sourceID: UUID,
        kind: SourceItemKind,
        name: String,
        location: String,
        parentID: String? = nil,
        sizeBytes: Int64? = nil,
        modifiedAt: Date? = nil,
        etag: String? = nil,
        container: String? = nil,
        durationSeconds: Double? = nil,
        providerIDs: [String: String] = [:]
    ) {
        self.id = id
        self.sourceID = sourceID
        self.kind = kind
        self.name = name
        self.location = location
        self.parentID = parentID
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.etag = etag
        self.container = container
        self.durationSeconds = durationSeconds
        self.providerIDs = providerIDs
    }
}
