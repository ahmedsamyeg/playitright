import Foundation
import Network

// MARK: - Configuration

/// TLS mode for FTP connections.
public enum FTPSecurityMode: String, Codable, Sendable, CaseIterable {
    /// Plain FTP on port 21.
    case plain
    /// FTP with STARTTLS upgrade on port 21 (FTPES).
    case explicitTLS = "ftps-explicit"
    /// FTP wrapped in TLS from the first byte, usually port 990.
    case implicitTLS = "ftps-implicit"
}

/// FTP/FTPS connection settings.
public struct FTPConfiguration: Sendable, Equatable {
    public var port: Int
    public var security: FTPSecurityMode
    public var timeout: TimeInterval
    public var passive: Bool
    public var chunkSize: Int
    public var maxReconnects: Int
    public var reconnectBaseDelay: TimeInterval

    public init(
        port: Int = 21,
        security: FTPSecurityMode = .plain,
        timeout: TimeInterval = 30,
        passive: Bool = true,
        chunkSize: Int = 256 * 1024,
        maxReconnects: Int = 3,
        reconnectBaseDelay: TimeInterval = 0.5
    ) {
        self.port = port
        self.security = security
        self.timeout = max(1, timeout)
        self.passive = passive
        self.chunkSize = max(1, chunkSize)
        self.maxReconnects = max(0, maxReconnects)
        self.reconnectBaseDelay = max(0, reconnectBaseDelay)
    }

    /// The conventional port for the security mode.
    public var defaultPort: Int {
        security == .implicitTLS ? 990 : 21
    }
}

/// Username and password resolved from the Keychain (SRC-3).
public struct FTPCredentials: Sendable, Equatable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public static let anonymous = FTPCredentials(
        username: "anonymous",
        password: "anonymous"
    )
}

/// One file or directory from a directory listing.
public struct FTPEntry: Sendable, Equatable {
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

/// Metadata for a single FTP path.
public struct FTPFileInfo: Sendable, Equatable {
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

/// Failures raised by FTP and SFTP clients.
public enum FTPError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case connectionFailed(String)
    case authenticationFailed
    case accessDenied
    case notFound(String)
    case protocolViolation(String)
    case transport(String)
    case cancelled
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid FTP configuration: \(message)"
        case .connectionFailed(let message):
            return "Could not connect to the FTP server: \(message)"
        case .authenticationFailed:
            return "The FTP server rejected the username or password."
        case .accessDenied:
            return "The FTP server denied access."
        case .notFound(let path):
            return "The FTP path '\(path)' was not found."
        case .protocolViolation(let message):
            return "The FTP server violated the protocol: \(message)"
        case .transport(let message):
            return "FTP transport failed: \(message)"
        case .cancelled:
            return "The FTP request was cancelled."
        case .unsupported(let feature):
            return "This FTP client does not support \(feature)."
        }
    }
}

/// The operations the FTP and SFTP adapters need from a wire client.
public protocol FTPClient: Sendable {
    func connect() async throws
    func authenticate(credentials: FTPCredentials) async throws
    func listDirectory(path: String) async throws -> [FTPEntry]
    func stat(path: String) async throws -> FTPFileInfo
    func read(path: String, offset: Int64, length: Int) async throws -> Data
    func disconnect() async
}

// MARK: - Listing parser

/// Parses UNIX `LIST`, `MLSD`, and Windows/IIS directory listings.
///
/// FTP servers are inconsistent about listing format, so the adapter accepts
/// all three shapes used by common servers (SRC-2, doc 03 §3).
public enum FTPDirectoryParser {
    public static func parse(
        _ listing: String,
        currentPath: String = ""
    ) -> [FTPEntry] {
        listing
            .components(separatedBy: .newlines)
            .compactMap { parseLine($0, currentPath: currentPath) }
    }

    public static func parseLine(
        _ line: String,
        currentPath: String = ""
    ) -> FTPEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("total ") else {
            return nil
        }

        if let entry = parseMachineListing(trimmed, currentPath: currentPath) {
            return entry
        }
        if let entry = parseWindowsListing(trimmed, currentPath: currentPath) {
            return entry
        }
        return parseUnixListing(trimmed, currentPath: currentPath)
    }

    // MARK: MLSD

    private static func parseMachineListing(
        _ line: String,
        currentPath: String
    ) -> FTPEntry? {
        guard let separator = line.firstIndex(of: " ") else {
            return nil
        }
        let facts = String(line[..<separator])
        guard facts.contains("type=") else {
            return nil
        }
        let name = String(line[line.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else {
            return nil
        }

        var isDirectory = false
        var size: Int64?
        var modifiedAt: Date?

        for fact in facts.split(separator: ";") {
            let parts = fact.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            let key = parts[0].lowercased()
            let value = String(parts[1])
            switch key {
            case "type":
                isDirectory = value.lowercased() == "dir"
                if !isDirectory && value.lowercased() != "file" {
                    return nil
                }
            case "size":
                size = Int64(value)
            case "modify":
                modifiedAt = parseModify(value)
            default:
                continue
            }
        }

        return FTPEntry(
            path: join(currentPath, name),
            name: name,
            isDirectory: isDirectory,
            size: isDirectory ? nil : size,
            modifiedAt: modifiedAt
        )
    }

    // MARK: Windows

    private static func parseWindowsListing(
        _ line: String,
        currentPath: String
    ) -> FTPEntry? {
        let pattern = #"^([0-9]{2})-([0-9]{2})-([0-9]{2,4})\s+([0-9]{1,2}):([0-9]{2})\s*([APap][Mm])?\s+(<DIR>|[0-9]+)\s+(.+)$"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges == 9 else {
            return nil
        }

        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: line) else {
                return nil
            }
            return String(line[range])
        }

        guard let monthText = group(1),
              let dayText = group(2),
              let yearText = group(3),
              let hourText = group(4),
              let minuteText = group(5),
              let sizeText = group(7),
              let name = group(8) else {
            return nil
        }
        guard !name.isEmpty, name != ".", name != ".." else {
            return nil
        }

        var year = Int(yearText) ?? 0
        if year < 100 {
            year += 2000
        }
        var hour = Int(hourText) ?? 0
        let minute = Int(minuteText) ?? 0
        if let meridiem = group(6)?.uppercased() {
            if meridiem == "PM", hour < 12 {
                hour += 12
            } else if meridiem == "AM", hour == 12 {
                hour = 0
            }
        }

        let isDirectory = sizeText.caseInsensitiveCompare("<DIR>") == .orderedSame
        let size = isDirectory ? nil : Int64(sizeText)
        let modifiedAt = date(
            year: year,
            month: Int(monthText) ?? 1,
            day: Int(dayText) ?? 1,
            hour: hour,
            minute: minute
        )
        return FTPEntry(
            path: join(currentPath, name),
            name: name,
            isDirectory: isDirectory,
            size: size,
            modifiedAt: modifiedAt
        )
    }

    // MARK: UNIX

    private static func parseUnixListing(
        _ line: String,
        currentPath: String
    ) -> FTPEntry? {
        let parts = line.split(
            separator: " ",
            maxSplits: 8,
            omittingEmptySubsequences: true
        )
        guard parts.count == 9 else {
            return nil
        }
        let permissions = String(parts[0])
        guard permissions.count >= 10 else {
            return nil
        }
        let type = permissions.first
        guard type == "-" || type == "d" || type == "l" else {
            return nil
        }

        let size = Int64(parts[4])
        let monthText = String(parts[5])
        let day = Int(parts[6]) ?? 1
        let timeOrYear = String(parts[7])
        var name = String(parts[8])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if type == "l", let arrow = name.range(of: " -> ") {
            name = String(name[..<arrow.lowerBound])
        }
        guard !name.isEmpty, name != ".", name != ".." else {
            return nil
        }

        var modifiedAt: Date?
        if let month = monthNumber(monthText) {
            if timeOrYear.contains(":") {
                let time = timeOrYear.split(separator: ":")
                let hour = Int(time.first ?? "0") ?? 0
                let minute = time.count > 1 ? Int(time[1]) ?? 0 : 0
                let year = Calendar(identifier: .gregorian)
                    .component(.year, from: Date())
                modifiedAt = date(
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    minute: minute
                )
            } else if let year = Int(timeOrYear) {
                modifiedAt = date(
                    year: year,
                    month: month,
                    day: day,
                    hour: 0,
                    minute: 0
                )
            }
        }

        return FTPEntry(
            path: join(currentPath, name),
            name: name,
            isDirectory: type == "d",
            size: type == "d" ? nil : size,
            modifiedAt: modifiedAt
        )
    }

    // MARK: Helpers

    static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty || directory == "/" {
            return "/" + name
        }
        if directory.hasSuffix("/") {
            return directory + name
        }
        return directory + "/" + name
    }

    private static func parseModify(_ value: String) -> Date? {
        let digits = value.filter(\.isNumber)
        guard digits.count >= 14,
              let year = Int(digits.prefix(4)),
              let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.dropFirst(6).prefix(2)),
              let hour = Int(digits.dropFirst(8).prefix(2)),
              let minute = Int(digits.dropFirst(10).prefix(2)),
              let second = Int(digits.dropFirst(12).prefix(2)) else {
            return nil
        }
        return date(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
    }

    private static func monthNumber(_ value: String) -> Int? {
        let months = [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4,
            "may": 5, "jun": 6, "jul": 7, "aug": 8,
            "sep": 9, "oct": 10, "nov": 11, "dec": 12
        ]
        return months[String(value.prefix(3)).lowercased()]
    }

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int = 0
    ) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components)
    }
}

// MARK: - Client registry

actor FTPClientRegistry {
    private var clients: [UUID: any FTPClient] = [:]

    func set(_ client: any FTPClient, for sessionID: UUID) {
        clients[sessionID] = client
    }

    func client(for sessionID: UUID) -> (any FTPClient)? {
        clients[sessionID]
    }

    func remove(for sessionID: UUID) {
        clients.removeValue(forKey: sessionID)
    }
}

// MARK: - Adapter

/// FTP/FTPS file-share source adapter.
///
/// Directories are walked with `LIST`/`MLSD`, and files are read in ranged
/// chunks so 4K remuxes stream in place (SRC-2, SRC-9). Credentials come from
/// the Keychain through ``CredentialProvider`` (SRC-3).
public final class FTPSourceAdapter: SourceAdapter, @unchecked Sendable {
    public typealias CredentialProvider = @Sendable (SourceConfig) -> FTPCredentials?
    public typealias ClientFactory = @Sendable (
        String,
        Int,
        FTPConfiguration
    ) -> any FTPClient

    public let kind: SourceKind
    public let configuration: FTPConfiguration

    private let clientFactory: ClientFactory
    private let credentialProvider: CredentialProvider?
    private let registry = FTPClientRegistry()

    public init(
        kind: SourceKind = .ftp,
        configuration: FTPConfiguration = FTPConfiguration(),
        credentialProvider: CredentialProvider? = nil,
        clientFactory: ClientFactory? = nil
    ) {
        self.kind = kind
        self.configuration = configuration
        self.credentialProvider = credentialProvider
        self.clientFactory = clientFactory ?? { host, port, config in
            FTPControlClient(host: host, port: port, configuration: config)
        }
    }

    public func connect(config: SourceConfig) async throws -> SourceSession {
        guard let host = config.host ?? config.endpoint?.host,
              !host.isEmpty else {
            throw SourceAdapterError.invalidConfiguration(
                "FTP sources require a host name."
            )
        }
        let port = config.port
            ?? (configuration.port == 21
                ? configuration.defaultPort
                : configuration.port)
        let credentials = credentialProvider?(config)
            ?? (config.username.map {
                FTPCredentials(username: $0, password: "")
            } ?? FTPCredentials.anonymous)

        let client = clientFactory(host, port, configuration)
        do {
            try await client.connect()
            try await client.authenticate(credentials: credentials)
        } catch {
            await client.disconnect()
            throw map(error)
        }

        let root = config.options["root"] ?? ""
        let session = SourceSession(
            sourceID: config.id,
            capabilities: [
                .rangeRequests,
                .modificationTimeFreshness,
                .recursiveEnumeration
            ],
            metadata: [
                "host": host,
                "port": String(port),
                "rootPath": root
            ]
        )
        await registry.set(client, for: session.id)
        return session
    }

    public func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        guard let client = await registry.client(for: session.id) else {
            throw SourceAdapterError.reauthenticationRequired
        }

        let root = scope.path.isEmpty
            ? (session.metadata["rootPath"] ?? "")
            : scope.path
        let recursive = scope.recursive
        let include = scope.includeGlobs
        let exclude = scope.excludeGlobs
        let sourceID = session.sourceID
        let host = session.metadata["host"] ?? ""

        return AsyncThrowingStream { continuation in
            let task = Task {
                var queue = [root]
                var visited: Set<String> = []

                do {
                    while !queue.isEmpty {
                        try Task.checkCancellation()
                        let directory = queue.removeFirst()
                        guard !visited.contains(directory) else {
                            continue
                        }
                        visited.insert(directory)

                        let entries = try await client.listDirectory(path: directory)
                        for entry in entries {
                            try Task.checkCancellation()
                            if entry.isDirectory {
                                if recursive {
                                    queue.append(entry.path)
                                }
                                continue
                            }
                            guard SourceGlob.allows(
                                name: entry.name,
                                path: entry.path,
                                include: include,
                                exclude: exclude
                            ) else {
                                continue
                            }
                            let container = (entry.name as NSString)
                                .pathExtension
                                .lowercased()
                            continuation.yield(
                                SourceItem(
                                    id: "ftp://\(host)\(entry.path)",
                                    sourceID: sourceID,
                                    kind: .movie,
                                    name: entry.name,
                                    location: entry.path,
                                    parentID: "ftp://\(host)\(directory)",
                                    sizeBytes: entry.size,
                                    modifiedAt: entry.modifiedAt,
                                    container: container.isEmpty ? nil : container
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

    public func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let client = await registry.client(for: session.id) else {
                    continuation.finish(
                        throwing: SourceAdapterError.reauthenticationRequired
                    )
                    return
                }
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

    public func freshness(session: SourceSession) async throws -> FreshnessInfo {
        FreshnessInfo(strategy: .modificationTime, checkedAt: Date())
    }

    public func disconnect(session: SourceSession) async {
        if let client = await registry.client(for: session.id) {
            await client.disconnect()
        }
        await registry.remove(for: session.id)
    }

    private func streamRead(
        client: any FTPClient,
        item: SourceItem,
        range: ByteRange?,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        let totalSize = item.sizeBytes
        if let totalSize, let range, range.start >= totalSize {
            continuation.finish(
                throwing: SourceAdapterError.rangeNotSatisfiable(
                    range,
                    size: totalSize
                )
            )
            return
        }

        var offset = range?.start ?? 0
        let upperBound = range?.end
        let chunkSize = configuration.chunkSize

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
                    path: item.location,
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
                continuation.finish(throwing: self.map(error))
                return
            }
        }
    }

    private func map(_ error: Error) -> SourceAdapterError {
        if let error = error as? SourceAdapterError {
            return error
        }
        if let error = error as? FTPError {
            switch error {
            case .invalidConfiguration(let message):
                return .invalidConfiguration(message)
            case .connectionFailed(let message):
                return .hostUnreachable(message)
            case .authenticationFailed:
                return .reauthenticationRequired
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
        return .transport(error.localizedDescription)
    }
}

// MARK: - Wire client

/// Minimal in-process FTP client for plain FTP and implicit FTPS.
///
/// Explicit TLS (`AUTH TLS`) requires an in-place control-channel upgrade that
/// Network.framework does not expose, so callers that need FTPES must inject a
/// client through ``FTPSourceAdapter/ClientFactory``. Plain FTP and implicit
/// FTPS are handled here with passive-mode data connections.
public actor FTPControlClient: FTPClient {
    private let host: String
    private let port: Int
    private let configuration: FTPConfiguration
    private let queue = DispatchQueue(label: "SourceAdapters.FTP.control")

    private var connection: NWConnection?
    private var buffer = Data()

    public init(
        host: String,
        port: Int,
        configuration: FTPConfiguration
    ) {
        self.host = host
        self.port = port
        self.configuration = configuration
    }

    public func connect() async throws {
        guard configuration.security != .explicitTLS else {
            throw FTPError.unsupported("FTPES STARTTLS upgrades")
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw FTPError.invalidConfiguration("Invalid port \(port).")
        }

        let parameters: NWParameters
        if configuration.security == .implicitTLS {
            parameters = NWParameters(tls: NWProtocolTLS.Options())
        } else {
            parameters = .tcp
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )
        self.connection = connection
        try await waitForReady(connection)
        _ = try await readReply()
    }

    public func authenticate(credentials: FTPCredentials) async throws {
        var reply = try await command("USER \(credentials.username)")
        if reply.code == 331 {
            reply = try await command("PASS \(credentials.password)")
        }
        guard reply.code == 230 || reply.code == 202 else {
            throw FTPError.authenticationFailed
        }
        _ = try await command("TYPE I")
    }

    public func listDirectory(path: String) async throws -> [FTPEntry] {
        let dataConnection = try await openPassiveConnection()
        defer {
            dataConnection.cancel()
        }

        let listingCommand = path.isEmpty ? "LIST" : "LIST \(path)"
        try await sendLine(listingCommand)
        let preliminary = try await readReply()
        if preliminary.code == 550 {
            throw FTPError.notFound(path)
        }

        let listingData = try await receiveAll(from: dataConnection)
        let final = try await readReply()
        guard final.code == 226 || final.code == 250 else {
            throw FTPError.protocolViolation(
                "LIST failed with \(final.code) \(final.text)"
            )
        }
        let listing = String(data: listingData, encoding: .utf8) ?? ""
        return FTPDirectoryParser.parse(listing, currentPath: path)
    }

    public func stat(path: String) async throws -> FTPFileInfo {
        let sizeReply = try await command("SIZE \(path)")
        let modifiedReply = try await command("MDTM \(path)")
        var modifiedAt: Date?
        if modifiedReply.code == 213 {
            modifiedAt = FTPDirectoryParser.parseLine(
                "type=file;modify=\(modifiedReply.text); x",
                currentPath: ""
            )?.modifiedAt
        }
        return FTPFileInfo(
            size: sizeReply.code == 213
                ? Int64(sizeReply.text.trimmingCharacters(in: .whitespaces))
                : nil,
            modifiedAt: modifiedAt,
            isDirectory: sizeReply.code != 213
        )
    }

    public func read(
        path: String,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        let dataConnection = try await openPassiveConnection()
        defer {
            dataConnection.cancel()
        }

        if offset > 0 {
            let restart = try await command("REST \(offset)")
            guard restart.code == 350 else {
                throw FTPError.protocolViolation(
                    "REST failed with \(restart.code) \(restart.text)"
                )
            }
        }

        try await sendLine("RETR \(path)")
        let preliminary = try await readReply()
        if preliminary.code == 550 {
            throw FTPError.notFound(path)
        }
        guard preliminary.code == 150 || preliminary.code == 125 else {
            throw FTPError.protocolViolation(
                "RETR failed with \(preliminary.code) \(preliminary.text)"
            )
        }

        var received = Data()
        var finished = false
        while !finished && received.count < length {
            let remaining = length - received.count
            let (chunk, isComplete) = try await receiveChunk(
                from: dataConnection,
                maximumLength: min(remaining, 64 * 1024)
            )
            if let chunk, !chunk.isEmpty {
                received.append(chunk)
            }
            finished = isComplete || (chunk?.isEmpty ?? true)
        }

        // The server may answer 226, or 426 when the data connection closed
        // early because the requested range was satisfied.
        _ = try? await readReply()
        return received
    }

    public func disconnect() async {
        if connection != nil {
            _ = try? await sendLine("QUIT")
        }
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }

    // MARK: Control channel

    private struct Reply: Sendable {
        let code: Int
        let text: String
    }

    private func command(_ line: String) async throws -> Reply {
        try await sendLine(line)
        return try await readReply()
    }

    private func sendLine(_ line: String) async throws {
        guard let connection else {
            throw FTPError.transport("The FTP control connection is closed.")
        }
        let payload = Data((line + "\r\n").utf8)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: payload,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: FTPError.transport(
                                error.localizedDescription
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func readReply() async throws -> Reply {
        var lines: [String] = []
        var code = 0
        while true {
            let line = try await readLine()
            guard line.count >= 3,
                  let value = Int(line.prefix(3)) else {
                throw FTPError.protocolViolation(
                    "Malformed FTP reply '\(line)'."
                )
            }
            code = value
            lines.append(line)
            let fourth = line.count >= 4 ? line[line.index(line.startIndex, offsetBy: 3)] : " "
            if fourth != "-" {
                break
            }
        }
        return Reply(code: code, text: lines.joined(separator: "\n"))
    }

    private func readLine() async throws -> String {
        guard let connection else {
            throw FTPError.transport("The FTP control connection is closed.")
        }
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            let (chunk, isComplete) = try await receiveChunk(
                from: connection,
                maximumLength: 64 * 1024
            )
            if let chunk, !chunk.isEmpty {
                buffer.append(chunk)
            }
            if isComplete {
                throw FTPError.transport("The FTP server closed the connection.")
            }
        }
    }

    private func receiveChunk(
        from connection: NWConnection,
        maximumLength: Int
    ) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(
                        throwing: FTPError.transport(
                            error.localizedDescription
                        )
                    )
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private func receiveAll(from connection: NWConnection) async throws -> Data {
        var data = Data()
        while true {
            let (chunk, isComplete) = try await receiveChunk(
                from: connection,
                maximumLength: 64 * 1024
            )
            if let chunk, !chunk.isEmpty {
                data.append(chunk)
            }
            if isComplete || (chunk?.isEmpty ?? true) {
                return data
            }
        }
    }

    // MARK: Data channel

    private func openPassiveConnection() async throws -> NWConnection {
        let reply = try await command("PASV")
        guard reply.code == 227,
              let endpoint = Self.passiveEndpoint(from: reply.text) else {
            throw FTPError.protocolViolation(
                "PASV failed with \(reply.code) \(reply.text)"
            )
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            throw FTPError.protocolViolation("Invalid passive port.")
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: nwPort,
            using: .tcp
        )
        try await waitForReady(connection)
        return connection
    }

    static func passiveEndpoint(from text: String) -> (host: String, port: Int)? {
        guard let open = text.firstIndex(of: "("),
              let close = text.firstIndex(of: ")"),
              open < close else {
            return nil
        }
        let numbers = text[text.index(after: open)..<close]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6 else {
            return nil
        }
        let host = numbers[0...3].map(String.init).joined(separator: ".")
        let port = numbers[4] * 256 + numbers[5]
        return (host, port)
    }

    private func waitForReady(_ connection: NWConnection) async throws {
        let gate = FTPResumeGate()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            gate.attach(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume()
                case .failed(let error):
                    gate.fail(
                        FTPError.connectionFailed(error.localizedDescription)
                    )
                case .cancelled:
                    gate.fail(FTPError.cancelled)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}

/// Resumes a continuation at most once from Network.framework callbacks.
private final class FTPResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if finished {
            continuation.resume()
        } else {
            self.continuation = continuation
        }
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            return
        }
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            return
        }
        finished = true
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
