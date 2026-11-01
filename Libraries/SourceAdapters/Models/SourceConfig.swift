import Foundation

/// The protocol family a source adapter speaks.
public enum SourceKind: String, Codable, Sendable, CaseIterable, Equatable {
    case plex
    case jellyfin
    case emby
    case smb
    case nfs
    case webdav
    case http
    case ftp
    case sftp
    case upnp
    case local
    case dropbox
    case googleDrive = "google-drive"
    case oneDrive = "onedrive"
    case box
}

/// A user-configured media source.
///
/// Passwords and tokens are intentionally absent: `credentialReference` points
/// at a Keychain item, which keeps secrets out of the database and diagnostics
/// (SRC-3).
public struct SourceConfig: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: SourceKind
    public var name: String

    /// Base URL for HTTP, WebDAV, and media-server sources.
    public var endpoint: URL?

    /// Host name or IP address for share-based sources.
    public var host: String?

    /// Optional port for share-based sources.
    public var port: Int?

    /// Username for basic/digest auth. Secrets belong in the Keychain.
    public var username: String?

    /// Keychain account key for this source's credentials.
    public var credentialReference: String?

    /// Whether TLS is required for this source.
    public var requiresTLS: Bool

    /// Whether to accept a self-signed certificate (with an explicit warning in
    /// the UI).
    public var allowsSelfSignedCertificate: Bool

    /// Per-source glob filters. Patterns are matched case-insensitively.
    public var includeGlobs: [String]
    public var excludeGlobs: [String]

    /// Adapter-specific options that do not contain secrets.
    public var options: [String: String]

    public init(
        id: UUID = UUID(),
        kind: SourceKind,
        name: String,
        endpoint: URL? = nil,
        host: String? = nil,
        port: Int? = nil,
        username: String? = nil,
        credentialReference: String? = nil,
        requiresTLS: Bool = true,
        allowsSelfSignedCertificate: Bool = false,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = [],
        options: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.endpoint = endpoint
        self.host = host
        self.port = port
        self.username = username
        self.credentialReference = credentialReference
        self.requiresTLS = requiresTLS
        self.allowsSelfSignedCertificate = allowsSelfSignedCertificate
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.options = options
    }
}

/// A subset of a source to enumerate.
public struct LibraryScope: Codable, Sendable, Equatable {
    /// Source-native library or section id.
    public var libraryID: String?

    /// Root path or server-side container path.
    public var path: String

    /// Whether child containers should be walked.
    public var recursive: Bool

    /// Optional case-insensitive include filters.
    public var includeGlobs: [String]

    /// Optional case-insensitive exclude filters.
    public var excludeGlobs: [String]

    public init(
        libraryID: String? = nil,
        path: String = "",
        recursive: Bool = true,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = []
    ) {
        self.libraryID = libraryID
        self.path = path
        self.recursive = recursive
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
    }
}

/// Features an adapter reports after connecting.
public struct SourceCapabilities: OptionSet, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Supports ranged reads and seeks (SRC-2).
    public static let rangeRequests = SourceCapabilities(rawValue: 1 << 0)

    /// Can accept best-effort watch-state writes (SRC-6).
    public static let watchStatePush = SourceCapabilities(rawValue: 1 << 1)

    /// Pushes change notifications through webhooks or a socket (SRC-20).
    public static let changePush = SourceCapabilities(rawValue: 1 << 2)

    /// Exposes ETags or similar validators for freshness checks.
    public static let etagFreshness = SourceCapabilities(rawValue: 1 << 3)

    /// Exposes file modification times for freshness checks.
    public static let modificationTimeFreshness = SourceCapabilities(rawValue: 1 << 4)

    /// Can enumerate child containers recursively.
    public static let recursiveEnumeration = SourceCapabilities(rawValue: 1 << 5)

    /// Prefers sending the original stream without server transcoding
    /// (SRC-4, SRC-8).
    public static let directPlay = SourceCapabilities(rawValue: 1 << 6)
}

/// A live connection returned by ``SourceAdapter/connect(config:)``.
///
/// Sessions are in-memory only. Any access token lives in `accessToken` and is
/// never persisted by the library layer.
public struct SourceSession: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var sourceID: UUID
    public var connectedAt: Date
    public var capabilities: SourceCapabilities

    /// In-memory bearer/session token. Do not persist or log.
    public var accessToken: String?

    /// Non-secret adapter state such as server version or root ids.
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        sourceID: UUID,
        connectedAt: Date = Date(),
        capabilities: SourceCapabilities = [],
        accessToken: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sourceID = sourceID
        self.connectedAt = connectedAt
        self.capabilities = capabilities
        self.accessToken = accessToken
        self.metadata = metadata
    }
}
