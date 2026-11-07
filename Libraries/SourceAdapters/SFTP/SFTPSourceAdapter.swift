import Foundation

/// SFTP connection settings.
public struct SFTPConfiguration: Sendable, Equatable {
    public var port: Int
    public var timeout: TimeInterval
    public var chunkSize: Int
    public var maxReconnects: Int
    public var reconnectBaseDelay: TimeInterval

    public init(
        port: Int = 22,
        timeout: TimeInterval = 30,
        chunkSize: Int = 256 * 1024,
        maxReconnects: Int = 3,
        reconnectBaseDelay: TimeInterval = 0.5
    ) {
        self.port = port
        self.timeout = max(1, timeout)
        self.chunkSize = max(1, chunkSize)
        self.maxReconnects = max(0, maxReconnects)
        self.reconnectBaseDelay = max(0, reconnectBaseDelay)
    }
}

/// SSH credentials resolved from the Keychain (SRC-3).
public struct SFTPCredentials: Sendable, Equatable {
    public var username: String
    public var password: String?
    /// Keychain reference for an SSH private key, when the server uses keys.
    public var privateKeyReference: String?

    public init(
        username: String,
        password: String? = nil,
        privateKeyReference: String? = nil
    ) {
        self.username = username
        self.password = password
        self.privateKeyReference = privateKeyReference
    }
}

/// One file or directory returned by an SFTP listing.
public struct SFTPEntry: Sendable, Equatable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64?
    public var modifiedAt: Date?

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        size: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// Metadata for one SFTP path.
public struct SFTPFileInfo: Sendable, Equatable {
    public var size: Int64?
    public var modifiedAt: Date?
    public var isDirectory: Bool

    public init(
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        isDirectory: Bool = false
    ) {
        self.size = size
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
    }
}

/// The operations ``SFTPSourceAdapter`` needs from an SSH-2 client.
///
/// Citadel / swift-nio-ssh supplies the production implementation (see the
/// file-protocol spike). The protocol keeps the adapter free of the transport
/// and lets tests use a deterministic in-memory client.
public protocol SFTPClient: Sendable {
    func connect() async throws
    func authenticate(credentials: SFTPCredentials) async throws
    func listDirectory(path: String) async throws -> [SFTPEntry]
    func stat(path: String) async throws -> SFTPFileInfo
    func read(path: String, offset: Int64, length: Int) async throws -> Data
    func disconnect() async
}

/// Placeholder used until the Citadel-backed SSH client is linked.
public struct UnavailableSFTPClient: SFTPClient {
    public init() {}

    public func connect() async throws {
        throw FTPError.unsupported("SFTP transport (link the SSH client)")
    }

    public func authenticate(credentials: SFTPCredentials) async throws {
        throw FTPError.unsupported("SFTP transport (link the SSH client)")
    }

    public func listDirectory(path: String) async throws -> [SFTPEntry] {
        throw FTPError.unsupported("SFTP transport (link the SSH client)")
    }

    public func stat(path: String) async throws -> SFTPFileInfo {
        throw FTPError.unsupported("SFTP transport (link the SSH client)")
    }

    public func read(path: String, offset: Int64, length: Int) async throws -> Data {
        throw FTPError.unsupported("SFTP transport (link the SSH client)")
    }

    public func disconnect() async {}
}

/// SSH-2 / SFTP file-share source adapter.
///
/// The adapter reuses the FTP directory-walk and ranged-read core, mapping an
/// injected ``SFTPClient`` onto the shared remote-file contract. That keeps
/// enumeration, glob filtering, and byte-range semantics identical across the
/// two protocols (SRC-2, SRC-9).
public final class SFTPSourceAdapter: SourceAdapter, @unchecked Sendable {
    public typealias CredentialProvider = @Sendable (SourceConfig) -> SFTPCredentials?
    public typealias ClientFactory = @Sendable (
        String,
        Int,
        SFTPConfiguration
    ) -> any SFTPClient

    public let kind: SourceKind = .sftp
    public let configuration: SFTPConfiguration

    private let core: FTPSourceAdapter

    public init(
        configuration: SFTPConfiguration = SFTPConfiguration(),
        credentialProvider: CredentialProvider? = nil,
        clientFactory: ClientFactory? = nil
    ) {
        self.configuration = configuration
        let factory = clientFactory ?? { _, _, _ in UnavailableSFTPClient() }
        self.core = FTPSourceAdapter(
            kind: .sftp,
            configuration: FTPConfiguration(
                port: configuration.port,
                security: .plain,
                timeout: configuration.timeout,
                chunkSize: configuration.chunkSize,
                maxReconnects: configuration.maxReconnects,
                reconnectBaseDelay: configuration.reconnectBaseDelay
            ),
            credentialProvider: { config in
                credentialProvider?(config).map {
                    FTPCredentials(
                        username: $0.username,
                        password: $0.password ?? ""
                    )
                }
            },
            clientFactory: { host, port, _ in
                SFTPClientBridge(
                    client: factory(host, configuration.port, configuration)
                )
            }
        )
    }

    public func connect(config: SourceConfig) async throws -> SourceSession {
        let session = try await core.connect(config: config)
        return SourceSession(
            id: session.id,
            sourceID: session.sourceID,
            connectedAt: session.connectedAt,
            capabilities: session.capabilities,
            accessToken: session.accessToken,
            metadata: session.metadata
        )
    }

    public func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        try await core.enumerate(session: session, scope: scope)
    }

    public func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error> {
        core.read(session: session, item: item, range: range)
    }

    public func freshness(session: SourceSession) async throws -> FreshnessInfo {
        try await core.freshness(session: session)
    }

    public func disconnect(session: SourceSession) async {
        await core.disconnect(session: session)
    }
}

/// Maps an SSH/SFTP client onto the shared FTP-shaped adapter core.
private struct SFTPClientBridge: FTPClient {
    let client: any SFTPClient

    func connect() async throws {
        try await client.connect()
    }

    func authenticate(credentials: FTPCredentials) async throws {
        try await client.authenticate(
            credentials: SFTPCredentials(
                username: credentials.username,
                password: credentials.password
            )
        )
    }

    func listDirectory(path: String) async throws -> [FTPEntry] {
        try await client.listDirectory(path: path).map {
            FTPEntry(
                path: $0.path,
                name: $0.name,
                isDirectory: $0.isDirectory,
                size: $0.size,
                modifiedAt: $0.modifiedAt
            )
        }
    }

    func stat(path: String) async throws -> FTPFileInfo {
        let info = try await client.stat(path: path)
        return FTPFileInfo(
            size: info.size,
            modifiedAt: info.modifiedAt,
            isDirectory: info.isDirectory
        )
    }

    func read(path: String, offset: Int64, length: Int) async throws -> Data {
        try await client.read(path: path, offset: offset, length: length)
    }

    func disconnect() async {
        await client.disconnect()
    }
}
