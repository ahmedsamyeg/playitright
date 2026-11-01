import Foundation

/// SMB2/3 file-share source adapter.
///
/// The adapter owns a per-session ``SMBClient``. Files are enumerated with a
/// bounded directory walk and read in ranged chunks, so 4K remuxes never need
/// to be downloaded in full (SRC-2, SRC-9). Credentials come from the Keychain
/// through ``CredentialProvider`` and never enter ``SourceConfig`` (SRC-3).
public final class SMBSourceAdapter: SourceAdapter, @unchecked Sendable {
    /// Creates the wire client for a host.
    public typealias ClientFactory = @Sendable (
        String,
        SMBConfiguration
    ) -> SMBClient

    /// Resolves share credentials from the Keychain.
    public typealias CredentialProvider = @Sendable (
        SourceConfig
    ) -> SMBCredentials?

    public let kind: SourceKind = .smb
    public let configuration: SMBConfiguration

    private let clientFactory: ClientFactory
    private let credentialProvider: CredentialProvider?
    private let registry = SMBClientRegistry()

    public init(
        configuration: SMBConfiguration = SMBConfiguration(),
        credentialProvider: CredentialProvider? = nil,
        clientFactory: ClientFactory? = nil
    ) {
        self.configuration = configuration
        self.credentialProvider = credentialProvider
        self.clientFactory = clientFactory ?? { host, config in
            SMB2Client(host: host, configuration: config)
        }
    }

    // MARK: - Connect

    public func connect(config: SourceConfig) async throws -> SourceSession {
        let target: SMBTarget
        do {
            target = try SMBTarget(config: config, fallback: configuration)
        } catch {
            throw SourceAdapterError.invalidConfiguration(
                error.localizedDescription
            )
        }

        guard let credentials = credentialProvider?(config) else {
            throw SourceAdapterError.reauthenticationRequired
        }

        var effective = configuration
        effective.port = target.port
        effective.share = target.share
        if !credentials.domain.isEmpty {
            effective.domain = credentials.domain
        }

        let client = clientFactory(target.host, effective)
        do {
            try await client.connect()
            try await client.authenticate(credentials: credentials)
            try await client.treeConnect(share: target.share)
        } catch {
            await client.disconnect()
            throw map(error)
        }

        let session = SourceSession(
            sourceID: config.id,
            capabilities: [
                .rangeRequests,
                .modificationTimeFreshness,
                .recursiveEnumeration
            ],
            metadata: [
                "endpoint": target.endpoint,
                "host": target.host,
                "share": target.share,
                "rootPath": target.rootPath
            ]
        )
        registry.set(client, for: session.id)
        return session
    }

    // MARK: - Enumerate

    public func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        guard let client = registry.client(for: session.id) else {
            throw SourceAdapterError.reauthenticationRequired
        }

        let root = scope.path.isEmpty
            ? (session.metadata["rootPath"] ?? "")
            : scope.path
        let includeGlobs = scope.includeGlobs
        let excludeGlobs = scope.excludeGlobs
        let recursive = scope.recursive
        let host = session.metadata["host"] ?? ""
        let share = session.metadata["share"] ?? ""
        let sourceID = session.sourceID

        return AsyncThrowingStream { continuation in
            let task = Task {
                var queue = [root]
                var visited: Set<String> = []

                do {
                    while !queue.isEmpty {
                        try Task.checkCancellation()
                        let directory = queue.removeFirst()
                        if visited.contains(directory) {
                            continue
                        }
                        visited.insert(directory)

                        let entries = try await client.listDirectory(
                            path: directory
                        )

                        for entry in entries {
                            try Task.checkCancellation()
                            let path = Self.join(directory, entry.name)

                            if entry.isDirectory {
                                if recursive {
                                    queue.append(path)
                                }
                                continue
                            }

                            guard SourceGlob.allows(
                                name: entry.name,
                                path: path,
                                include: includeGlobs,
                                exclude: excludeGlobs
                            ) else {
                                continue
                            }

                            let location = Self.location(
                                host: host,
                                share: share,
                                path: path
                            )
                            let extensionName = (entry.name as NSString)
                                .pathExtension
                                .lowercased()

                            continuation.yield(
                                SourceItem(
                                    id: location,
                                    sourceID: sourceID,
                                    kind: .movie,
                                    name: entry.name,
                                    location: location,
                                    parentID: Self.location(
                                        host: host,
                                        share: share,
                                        path: directory
                                    ),
                                    sizeBytes: entry.size,
                                    modifiedAt: entry.modifiedAt,
                                    container: extensionName.isEmpty
                                        ? nil
                                        : extensionName
                                )
                            )
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(
                        throwing: SourceAdapterError.cancelled
                    )
                } catch let error as SourceAdapterError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: self.map(error))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Read

    public func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error> {
        guard let client = registry.client(for: session.id) else {
            let stream = AsyncThrowingStream<Data, Error> {
                $0.finish(
                    throwing: SourceAdapterError.reauthenticationRequired
                )
            }
            return stream
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.streamRead(
                    client: client,
                    item: item,
                    range: range,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func streamRead(
        client: SMBClient,
        item: SourceItem,
        range: ByteRange?,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        let path = Self.path(from: item.location) ?? item.location
        let upperBound = range?.end
        var offset = range?.start ?? 0
        var attempts = 0
        let totalSize = item.sizeBytes
        let chunkSize = 256 * 1024

        if let totalSize, let range, range.start >= totalSize {
            continuation.finish(
                throwing: SourceAdapterError.rangeNotSatisfiable(
                    range,
                    size: totalSize
                )
            )
            return
        }

        while true {
            if Task.isCancelled {
                continuation.finish(throwing: SourceAdapterError.cancelled)
                return
            }

            var length = chunkSize
            if let upperBound {
                let remaining = upperBound - offset + 1
                if remaining <= 0 {
                    continuation.finish()
                    return
                }
                length = min(length, Int(remaining))
            }
            if let totalSize {
                let remaining = totalSize - offset
                if remaining <= 0 {
                    continuation.finish()
                    return
                }
                length = min(length, Int(remaining))
            }

            do {
                var chunk = try await client.read(
                    path: path,
                    offset: offset,
                    length: length
                )
                if chunk.isEmpty {
                    continuation.finish()
                    return
                }

                if let upperBound {
                    let remaining = upperBound - offset + 1
                    if Int64(chunk.count) > remaining {
                        chunk = chunk.prefix(Int(remaining))
                    }
                }

                guard !chunk.isEmpty else {
                    continuation.finish()
                    return
                }

                continuation.yield(chunk)
                offset += Int64(chunk.count)
                attempts = 0

                if let totalSize, offset >= totalSize {
                    continuation.finish()
                    return
                }
                if let upperBound, offset > upperBound {
                    continuation.finish()
                    return
                }
            } catch is CancellationError {
                continuation.finish(throwing: SourceAdapterError.cancelled)
                return
            } catch {
                attempts += 1
                guard attempts <= configuration.maxReconnects else {
                    continuation.finish(
                        throwing: SourceAdapterError.transport(
                            error.localizedDescription
                        )
                    )
                    return
                }

                let delay = configuration.reconnectBaseDelay
                    * pow(2, Double(attempts - 1))
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    continuation.finish(
                        throwing: SourceAdapterError.cancelled
                    )
                    return
                }
            }
        }
    }

    // MARK: - Freshness

    public func freshness(session: SourceSession) async throws
        -> FreshnessInfo {
        guard let client = registry.client(for: session.id) else {
            throw SourceAdapterError.reauthenticationRequired
        }

        let root = session.metadata["rootPath"] ?? ""
        do {
            let info = try await client.stat(path: root)
            guard let modified = info.modifiedAt else {
                return FreshnessInfo(strategy: .none)
            }
            return FreshnessInfo(
                strategy: .modificationTime,
                lastModified: modified
            )
        } catch {
            throw map(error)
        }
    }

    // MARK: - Disconnect

    public func disconnect(session: SourceSession) async {
        guard let client = registry.remove(session.id) else {
            return
        }
        await client.disconnect()
    }

    // MARK: - Locations

    static func join(_ directory: String, _ name: String) -> String {
        let trimmed = directory.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return trimmed.isEmpty ? name : "\(trimmed)/\(name)"
    }

    static func location(host: String, share: String, path: String) -> String {
        let encoded = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { component in
                String(component).addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? String(component)
            }
            .joined(separator: "/")
        if encoded.isEmpty {
            return "smb://\(host)/\(share)"
        }
        return "smb://\(host)/\(share)/\(encoded)"
    }

    static func path(from location: String) -> String? {
        guard let url = URL(string: location),
              url.scheme?.lowercased() == "smb" else {
            return nil
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count > 1 else {
            return ""
        }
        return components.dropFirst().joined(separator: "/")
    }

    // MARK: - Errors

    func map(_ error: Error) -> SourceAdapterError {
        if let error = error as? SourceAdapterError {
            return error
        }
        guard let smbError = error as? SMBError else {
            return .transport(error.localizedDescription)
        }

        switch smbError {
        case .invalidConfiguration(let message):
            return .invalidConfiguration(message)
        case .connectionFailed(let message):
            return .hostUnreachable(message)
        case .authenticationFailed:
            return .unauthorized
        case .accessDenied:
            return .unauthorized
        case .notFound(let path):
            return .notFound(path)
        case .protocolViolation(let message):
            return .protocolViolation(message)
        case .transport(let message):
            return .transport(message)
        case .cancelled:
            return .cancelled
        case .unsupported(let feature):
            return .unsupported(feature)
        }
    }
}

/// Parsed `smb://host/share/path` configuration.
struct SMBTarget: Sendable, Equatable {
    var host: String
    var port: Int
    var share: String
    var rootPath: String

    var endpoint: String {
        "smb://\(host)/\(share)"
    }

    init(config: SourceConfig, fallback: SMBConfiguration) throws {
        let endpointURL = config.endpoint.flatMap { url -> URL? in
            guard url.scheme?.lowercased() == "smb" else {
                return nil
            }
            return url
        }

        guard let host = config.host ?? endpointURL?.host,
              !host.isEmpty else {
            throw SMBError.invalidConfiguration(
                "An SMB source needs a host."
            )
        }

        let pathComponents = endpointURL?.pathComponents.filter {
            $0 != "/"
        } ?? []

        let share = config.options["share"]
            ?? pathComponents.first
            ?? (fallback.share.isEmpty ? nil : fallback.share)
        guard let share, !share.isEmpty else {
            throw SMBError.invalidConfiguration(
                "An SMB source needs a share name."
            )
        }

        let rootPath = pathComponents.dropFirst().joined(separator: "/")

        self.host = host
        self.port = config.port
            ?? endpointURL?.port
            ?? fallback.port
        self.share = share
        self.rootPath = rootPath
    }
}

/// Lock-protected session-to-client map.
final class SMBClientRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [UUID: SMBClient] = [:]

    func set(_ client: SMBClient, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        clients[id] = client
    }

    func client(for id: UUID) -> SMBClient? {
        lock.lock()
        defer { lock.unlock() }
        return clients[id]
    }

    func remove(_ id: UUID) -> SMBClient? {
        lock.lock()
        defer { lock.unlock() }
        return clients.removeValue(forKey: id)
    }
}
