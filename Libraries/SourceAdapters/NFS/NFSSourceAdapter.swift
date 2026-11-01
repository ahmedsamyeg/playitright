import Foundation

/// NFSv3 file-share source adapter.
///
/// The adapter owns a per-session ``NFSClient``. Directories are walked with
/// READDIRPLUS, so every child file handle arrives with the listing, and reads
/// are issued as bounded ranged READ calls that resume after a transport drop
/// (SRC-2, SRC-9). NFS has no password; identity is the AUTH_UNIX uid/gid in
/// ``NFSConfiguration`` (SRC-3).
public final class NFSSourceAdapter: SourceAdapter, @unchecked Sendable {
    /// Creates the wire client for a host.
    public typealias ClientFactory = @Sendable (
        String,
        NFSConfiguration
    ) -> NFSClient

    public let kind: SourceKind = .nfs
    public let configuration: NFSConfiguration

    private let clientFactory: ClientFactory
    private let registry = NFSClientRegistry()

    public init(
        configuration: NFSConfiguration = NFSConfiguration(),
        clientFactory: ClientFactory? = nil
    ) {
        self.configuration = configuration
        self.clientFactory = clientFactory ?? { host, config in
            NFSv3Client(host: host, configuration: config)
        }
    }

    // MARK: - Connect

    public func connect(config: SourceConfig) async throws -> SourceSession {
        let target: NFSTarget
        do {
            target = try NFSTarget(config: config)
        } catch {
            throw SourceAdapterError.invalidConfiguration(
                error.localizedDescription
            )
        }

        let client = clientFactory(target.host, configuration)
        let rootHandle: Data
        do {
            try await client.connect()
            rootHandle = try await client.mount(export: target.export)
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
                "export": target.export,
                "rootPath": target.rootPath
            ]
        )
        registry.set(
            NFSSessionState(
                client: client,
                rootHandle: rootHandle,
                export: target.export,
                rootPath: target.rootPath,
                host: target.host
            ),
            for: session.id
        )
        return session
    }

    // MARK: - Enumerate

    public func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        guard let state = registry.state(for: session.id) else {
            throw SourceAdapterError.reauthenticationRequired
        }

        let requestedRoot = scope.path.isEmpty
            ? state.rootPath
            : scope.path

        let start: (path: String, handle: Data)
        do {
            if requestedRoot == state.rootPath {
                start = (requestedRoot, state.rootHandle)
            } else {
                let lookup = try await state.client.lookup(path: requestedRoot)
                guard lookup.info.isDirectory else {
                    throw SourceAdapterError.notFound(requestedRoot)
                }
                start = (requestedRoot, lookup.fileHandle)
            }
        } catch {
            throw map(error)
        }

        let includeGlobs = scope.includeGlobs
        let excludeGlobs = scope.excludeGlobs
        let recursive = scope.recursive
        let host = state.host
        let export = state.export
        let sourceID = session.sourceID
        let client = state.client

        return AsyncThrowingStream { continuation in
            let task = Task {
                var queue: [(path: String, handle: Data)] = [start]
                var visited: Set<Data> = []

                do {
                    while !queue.isEmpty {
                        try Task.checkCancellation()
                        let directory = queue.removeFirst()
                        if visited.contains(directory.handle) {
                            continue
                        }
                        visited.insert(directory.handle)

                        let entries = try await client.listDirectory(
                            handle: directory.handle
                        )

                        for entry in entries {
                            try Task.checkCancellation()
                            let path = Self.join(
                                directory.path,
                                entry.name
                            )

                            if entry.isDirectory {
                                if recursive {
                                    queue.append(
                                        (path, entry.fileHandle)
                                    )
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
                                export: export,
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
                                        export: export,
                                        path: directory.path
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
        guard let state = registry.state(for: session.id) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: SourceAdapterError.reauthenticationRequired
                )
            }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.streamRead(
                    state: state,
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
        state: NFSSessionState,
        item: SourceItem,
        range: ByteRange?,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        let relativePath = Self.path(
            from: item.location,
            export: state.export
        ) ?? item.location
        let client = state.client

        var handle: Data
        do {
            handle = try await client.lookup(path: relativePath).fileHandle
        } catch {
            continuation.finish(throwing: map(error))
            return
        }

        let upperBound = range?.end
        var offset = range?.start ?? 0
        var attempts = 0
        let totalSize = item.sizeBytes
        let chunkSize = configuration.maxReadSize

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
                    handle: handle,
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

                // A stale handle survives a reconnect, so re-resolve the path.
                if let nfsError = error as? NFSError,
                   case .staleHandle = nfsError,
                   let refreshed = try? await client.lookup(
                       path: relativePath
                   ) {
                    handle = refreshed.fileHandle
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
        guard let state = registry.state(for: session.id) else {
            throw SourceAdapterError.reauthenticationRequired
        }

        do {
            let lookup = try await state.client.lookup(
                path: state.rootPath
            )
            guard let modified = lookup.info.modifiedAt else {
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
        guard let state = registry.remove(session.id) else {
            return
        }
        await state.client.disconnect()
    }

    // MARK: - Locations

    static func join(_ directory: String, _ name: String) -> String {
        let trimmed = directory.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return trimmed.isEmpty ? name : "\(trimmed)/\(name)"
    }

    static func location(
        host: String,
        export: String,
        path: String
    ) -> String {
        let encoded = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { component in
                String(component).addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) ?? String(component)
            }
            .joined(separator: "/")
        let trimmedExport = export.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        if encoded.isEmpty {
            return "nfs://\(host)/\(trimmedExport)"
        }
        return "nfs://\(host)/\(trimmedExport)/\(encoded)"
    }

    static func path(from location: String, export: String) -> String? {
        guard let url = URL(string: location),
              url.scheme?.lowercased() == "nfs" else {
            return nil
        }

        let components = url.pathComponents
            .filter { $0 != "/" }
            .compactMap { $0.removingPercentEncoding ?? $0 }
        let exportComponents = export
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= exportComponents.count else {
            return nil
        }
        return components.dropFirst(exportComponents.count)
            .joined(separator: "/")
    }

    // MARK: - Errors

    func map(_ error: Error) -> SourceAdapterError {
        if let error = error as? SourceAdapterError {
            return error
        }
        guard let nfsError = error as? NFSError else {
            return .transport(error.localizedDescription)
        }

        switch nfsError {
        case .invalidConfiguration(let message):
            return .invalidConfiguration(message)
        case .connectionFailed(let message):
            return .hostUnreachable(message)
        case .mountFailed(let status):
            return .transport("The NFS export could not be mounted (status \(status)).")
        case .rpcDenied:
            return .unauthorized
        case .accessDenied:
            return .unauthorized
        case .staleHandle:
            return .notFound("the NFS file handle")
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

/// Parsed `nfs://host/export/path` configuration.
struct NFSTarget: Sendable, Equatable {
    var host: String
    var export: String
    var rootPath: String

    var endpoint: String {
        "nfs://\(host)/\(export)"
    }

    init(config: SourceConfig) throws {
        let endpointURL = config.endpoint.flatMap { url -> URL? in
            guard url.scheme?.lowercased() == "nfs" else {
                return nil
            }
            return url
        }

        guard let host = config.host ?? endpointURL?.host,
              !host.isEmpty else {
            throw NFSError.invalidConfiguration(
                "An NFS source needs a host."
            )
        }

        let components = endpointURL?.pathComponents
            .filter { $0 != "/" }
            .compactMap { $0.removingPercentEncoding ?? $0 }
            ?? []

        let configuredExport = config.options["export"]?
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        let export = configuredExport.flatMap {
            $0.isEmpty ? nil : $0
        } ?? components.first
        guard let export, !export.isEmpty else {
            throw NFSError.invalidConfiguration(
                "An NFS source needs an export path."
            )
        }

        let configuredRoot = config.options["path"]?
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        let rootFromEndpoint = configuredExport == nil
            ? components.dropFirst().joined(separator: "/")
            : ""

        self.host = host
        self.export = export
        let root = configuredRoot?.isEmpty == false
            ? configuredRoot
            : nil
        self.rootPath = (root ?? rootFromEndpoint)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// Per-session client plus its mounted root handle.
struct NFSSessionState: @unchecked Sendable {
    var client: NFSClient
    var rootHandle: Data
    var export: String
    var rootPath: String
    var host: String
}

/// Session-to-state map. All access is synchronous, so the lock is never held
/// across an `await`.
final class NFSClientRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [UUID: NFSSessionState] = [:]

    func set(_ state: NFSSessionState, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        states[id] = state
    }

    func state(for id: UUID) -> NFSSessionState? {
        lock.lock()
        defer { lock.unlock() }
        return states[id]
    }

    func remove(_ id: UUID) -> NFSSessionState? {
        lock.lock()
        defer { lock.unlock() }
        return states.removeValue(forKey: id)
    }
}
