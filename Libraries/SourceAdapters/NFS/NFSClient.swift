import Foundation
import Network

/// NFS identity sent with AUTH_UNIX credentials.
public struct NFSIdentity: Sendable, Equatable {
    public var uid: UInt32
    public var gid: UInt32
    public var gids: [UInt32]
    public var machine: String

    public init(
        uid: UInt32 = 501,
        gid: UInt32 = 20,
        gids: [UInt32] = [],
        machine: String = "PlayItRight"
    ) {
        self.uid = uid
        self.gid = gid
        self.gids = gids
        self.machine = machine
    }
}

/// NFSv3 connection settings.
public struct NFSConfiguration: Sendable, Equatable {
    public var portmapperPort: Int
    public var timeout: TimeInterval
    public var identity: NFSIdentity
    public var maxReconnects: Int
    public var reconnectBaseDelay: TimeInterval
    public var maxReadSize: Int

    public init(
        portmapperPort: Int = 111,
        timeout: TimeInterval = 30,
        identity: NFSIdentity = NFSIdentity(),
        maxReconnects: Int = 4,
        reconnectBaseDelay: TimeInterval = 0.5,
        maxReadSize: Int = 256 * 1024
    ) {
        self.portmapperPort = portmapperPort
        self.timeout = max(1, timeout)
        self.identity = identity
        self.maxReconnects = max(0, maxReconnects)
        self.reconnectBaseDelay = max(0, reconnectBaseDelay)
        self.maxReadSize = max(1, maxReadSize)
    }
}

/// One directory entry returned by READDIRPLUS.
public struct NFSEntry: Sendable, Equatable {
    public var name: String
    public var fileHandle: Data
    public var isDirectory: Bool
    public var size: Int64?
    public var modifiedAt: Date?

    public init(
        name: String,
        fileHandle: Data,
        isDirectory: Bool,
        size: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.name = name
        self.fileHandle = fileHandle
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// Metadata for an NFS file handle.
public struct NFSFileInfo: Sendable, Equatable {
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

/// A resolved path: file handle plus attributes.
public struct NFSLookup: Sendable, Equatable {
    public var fileHandle: Data
    public var info: NFSFileInfo

    public init(fileHandle: Data, info: NFSFileInfo) {
        self.fileHandle = fileHandle
        self.info = info
    }
}

/// Errors raised by NFS clients.
public enum NFSError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case connectionFailed(String)
    case mountFailed(UInt32)
    case rpcDenied
    case accessDenied
    case staleHandle
    case notFound(String)
    case protocolViolation(String)
    case transport(String)
    case cancelled
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid NFS configuration: \(message)"
        case .connectionFailed(let message):
            return "Could not connect to the NFS server: \(message)"
        case .mountFailed(let status):
            return "The NFS export could not be mounted (status \(status))."
        case .rpcDenied:
            return "The NFS server denied the RPC request."
        case .accessDenied:
            return "The NFS export denied access."
        case .staleHandle:
            return "The NFS file handle is stale."
        case .notFound(let path):
            return "The NFS path '\(path)' was not found."
        case .protocolViolation(let message):
            return "The NFS server violated the protocol: \(message)"
        case .transport(let message):
            return "NFS transport failed: \(message)"
        case .cancelled:
            return "The NFS request was cancelled."
        case .unsupported(let feature):
            return "This NFS client does not support \(feature)."
        }
    }
}

/// Operations the NFS adapter needs.
public protocol NFSClient: Sendable {
    func connect() async throws
    func mount(export: String) async throws -> Data
    func listDirectory(handle: Data) async throws -> [NFSEntry]
    func stat(handle: Data) async throws -> NFSFileInfo
    func lookup(path: String) async throws -> NFSLookup
    func read(handle: Data, offset: Int64, length: Int) async throws -> Data
    func disconnect() async
}

// MARK: - XDR

/// Minimal XDR encoder for ONC RPC calls.
struct XDRWriter: Sendable {
    private(set) var data = Data()

    mutating func u32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    mutating func i32(_ value: Int32) {
        u32(UInt32(bitPattern: value))
    }

    mutating func u64(_ value: UInt64) {
        u32(UInt32((value >> 32) & 0xFFFF_FFFF))
        u32(UInt32(value & 0xFFFF_FFFF))
    }

    mutating func bool(_ value: Bool) {
        u32(value ? 1 : 0)
    }

    mutating func opaque(_ bytes: Data) {
        u32(UInt32(bytes.count))
        data.append(bytes)
        let padding = (4 - (bytes.count % 4)) % 4
        if padding > 0 {
            data.append(Data(repeating: 0, count: padding))
        }
    }

    mutating func fixedOpaque(_ bytes: Data) {
        data.append(bytes)
        let padding = (4 - (bytes.count % 4)) % 4
        if padding > 0 {
            data.append(Data(repeating: 0, count: padding))
        }
    }

    mutating func string(_ value: String) {
        opaque(Data(value.utf8))
    }
}

/// Minimal XDR decoder with bounds checking.
struct XDRReader: Sendable {
    let data: Data
    private(set) var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    var remaining: Int {
        data.count - offset
    }

    mutating func u32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw NFSError.protocolViolation("XDR value was truncated.")
        }
        let value = (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
        offset += 4
        return value
    }

    mutating func i32() throws -> Int32 {
        Int32(bitPattern: try u32())
    }

    mutating func u64() throws -> UInt64 {
        let high = try u32()
        let low = try u32()
        return (UInt64(high) << 32) | UInt64(low)
    }

    mutating func bool() throws -> Bool {
        try u32() != 0
    }

    mutating func fixedOpaque(_ count: Int) throws -> Data {
        let padded = (count + 3) & ~3
        guard offset + padded <= data.count else {
            throw NFSError.protocolViolation("XDR opaque value was truncated.")
        }
        let value = Data(data[offset..<(offset + count)])
        offset += padded
        return value
    }

    mutating func opaque() throws -> Data {
        let count = Int(try u32())
        guard count >= 0, count <= 64 * 1024 * 1024 else {
            throw NFSError.protocolViolation("Invalid XDR opaque length.")
        }
        return try fixedOpaque(count)
    }

    mutating func string() throws -> String {
        let bytes = try opaque()
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw NFSError.protocolViolation("XDR string was not UTF-8.")
        }
        return value
    }

    mutating func skip(_ count: Int) throws {
        guard offset + count <= data.count else {
            throw NFSError.protocolViolation("XDR skip exceeded the buffer.")
        }
        offset += count
    }
}

// MARK: - RPC connection

/// One serialized ONC RPC connection over TCP with record marking.
actor RPCConnection {
    private let queue = DispatchQueue(label: "SourceAdapters.NFS.rpc")
    private var connection: NWConnection?
    private var nextXID: UInt32 = 1

    func open(host: String, port: Int, timeout: TimeInterval) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NFSError.invalidConfiguration("Invalid port \(port).")
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )
        self.connection = connection

        let gate = RPCResumeGate()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume { continuation.resume() }
                case .failed(let error):
                    gate.resume {
                        continuation.resume(
                            throwing: NFSError.connectionFailed(
                                error.localizedDescription
                            )
                        )
                    }
                case .cancelled:
                    gate.resume {
                        continuation.resume(throwing: NFSError.cancelled)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                gate.resume {
                    connection.cancel()
                    continuation.resume(
                        throwing: NFSError.connectionFailed(
                            "Timed out after \(timeout) seconds."
                        )
                    )
                }
            }
        }
    }

    func call(
        program: UInt32,
        version: UInt32,
        procedure: UInt32,
        arguments: XDRWriter,
        identity: NFSIdentity
    ) async throws -> XDRReader {
        guard let connection else {
            throw NFSError.transport("The RPC connection is not open.")
        }

        let xid = nextXID
        nextXID &+= 1

        var request = XDRWriter()
        request.u32(xid)
        request.u32(0) // CALL
        request.u32(2) // RPC version
        request.u32(program)
        request.u32(version)
        request.u32(procedure)

        var credentials = XDRWriter()
        credentials.u32(0) // stamp
        credentials.string(identity.machine)
        credentials.u32(identity.uid)
        credentials.u32(identity.gid)
        credentials.u32(UInt32(identity.gids.count))
        for gid in identity.gids {
            credentials.u32(gid)
        }

        request.u32(1) // AUTH_UNIX
        request.opaque(credentials.data)
        request.u32(0) // AUTH_NONE verifier
        request.u32(0)

        var packet = Data()
        let length = UInt32(request.data.count) | 0x8000_0000
        packet.append(UInt8((length >> 24) & 0xFF))
        packet.append(UInt8((length >> 16) & 0xFF))
        packet.append(UInt8((length >> 8) & 0xFF))
        packet.append(UInt8(length & 0xFF))
        packet.append(request.data)

        try await send(packet, on: connection)
        let response = try await receiveRecord(on: connection)

        var reader = XDRReader(data: response)
        let responseXID = try reader.u32()
        guard responseXID == xid else {
            throw NFSError.protocolViolation("The RPC XID did not match.")
        }
        let messageType = try reader.u32()
        guard messageType == 1 else {
            throw NFSError.protocolViolation("The RPC reply was not a REPLY.")
        }
        let replyStatus = try reader.u32()
        guard replyStatus == 0 else {
            throw NFSError.rpcDenied
        }
        _ = try reader.u32() // verifier flavor
        let verifierLength = Int(try reader.u32())
        try reader.skip((verifierLength + 3) & ~3)
        let acceptStatus = try reader.u32()
        guard acceptStatus == 0 else {
            throw NFSError.rpcDenied
        }
        return reader
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: NFSError.transport(
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

    private func receiveRecord(on connection: NWConnection) async throws -> Data {
        var record = Data()
        var more = true

        while more {
            let header = try await receiveExactly(4, on: connection)
            let marker = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            more = marker & 0x8000_0000 == 0
            let length = Int(marker & 0x7FFF_FFFF)
            guard length > 0, length <= 64 * 1024 * 1024 else {
                throw NFSError.protocolViolation(
                    "Invalid RPC record length \(length)."
                )
            }
            record.append(try await receiveExactly(length, on: connection))
        }

        return record
    }

    private func receiveExactly(
        _ count: Int,
        on connection: NWConnection
    ) async throws -> Data {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            receiveExactly(
                count,
                accumulated: Data(),
                on: connection,
                continuation: continuation
            )
        }
    }

    private func receiveExactly(
        _ count: Int,
        accumulated: Data,
        on connection: NWConnection,
        continuation: CheckedContinuation<Data, Error>
    ){
        let remaining = count - accumulated.count
        guard remaining > 0 else {
            continuation.resume(returning: accumulated)
            return
        }

        connection.receive(
            minimumIncompleteLength: remaining,
            maximumLength: remaining
        ) { [weak self] content, _, isComplete, error in
            if let error {
                continuation.resume(
                    throwing: NFSError.transport(error.localizedDescription)
                )
                return
            }

            var data = accumulated
            if let content {
                data.append(content)
            }
            if data.count >= count {
                continuation.resume(returning: data)
                return
            }
            if isComplete {
                continuation.resume(
                    throwing: NFSError.transport(
                        "The RPC connection closed early."
                    )
                )
                return
            }
            guard let self else {
                continuation.resume(throwing: NFSError.cancelled)
                return
            }
            self.receiveExactly(
                count,
                accumulated: data,
                on: connection,
                continuation: continuation
            )
        }
    }
}

private final class RPCResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ action: () -> Void) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        action()
    }
}

// MARK: - NFSv3 client

/// Pure-Swift NFSv3 client.
///
/// It resolves mountd and NFS ports with the portmapper, mounts an export with
/// MOUNT v3, walks directories with READDIRPLUS, and reads with ranged READ
/// calls (SRC-2). RPC calls use AUTH_UNIX.
public final class NFSv3Client: NFSClient, @unchecked Sendable {
    private let host: String
    private let configuration: NFSConfiguration

    private let portmapper = RPCConnection()
    private let mounter = RPCConnection()
    private let nfs = RPCConnection()

    private let stateLock = SMBLock()
    private var mountPort: Int?
    private var nfsPort: Int?
    private var rootHandle: Data?

    public init(
        host: String,
        configuration: NFSConfiguration = NFSConfiguration()
    ) {
        self.host = host
        self.configuration = configuration
    }

    public func connect() async throws {
        do {
            try await portmapper.open(
                host: host,
                port: configuration.portmapperPort,
                timeout: configuration.timeout
            )
            let mount = try await getPort(
                program: 100_005,
                version: 3
            )
            let nfsPort = try await getPort(
                program: 100_003,
                version: 3
            )
            await portmapper.close()

            stateLock.withLock {
                self.mountPort = mount
                self.nfsPort = nfsPort
            }
        } catch {
            await portmapper.close()
            throw error
        }
    }

    public func mount(export: String) async throws -> Data {
        let ports = stateLock.withLock {
            (mountPort, nfsPort)
        }
        guard let mountPort = ports.0, let nfsPort = ports.1 else {
            throw NFSError.invalidConfiguration(
                "The NFS client has not resolved server ports."
            )
        }

        try await mounter.open(
            host: host,
            port: mountPort,
            timeout: configuration.timeout
        )

        var arguments = XDRWriter()
        arguments.string(export)

        let reply: XDRReader
        do {
            reply = try await mounter.call(
                program: 100_005,
                version: 3,
                procedure: 1,
                arguments: arguments,
                identity: configuration.identity
            )
        } catch {
            await mounter.close()
            throw error
        }
        await mounter.close()

        var reader = reply
        let status = try reader.u32()
        guard status == 0 else {
            throw NFSError.mountFailed(status)
        }
        let handle = try reader.opaque()

        try await nfs.open(
            host: host,
            port: nfsPort,
            timeout: configuration.timeout
        )
        stateLock.withLock {
            rootHandle = handle
        }
        return handle
    }

    public func listDirectory(handle: Data) async throws -> [NFSEntry] {
        var entries: [NFSEntry] = []
        var cookie: UInt64 = 0
        var cookieVerifier = Data(repeating: 0, count: 8)

        while true {
            try Task.checkCancellation()

            var arguments = XDRWriter()
            arguments.opaque(handle)
            arguments.u64(cookie)
            arguments.fixedOpaque(cookieVerifier)
            arguments.u32(8192)
            arguments.u32(65536)

            let reply = try await nfs.call(
                program: 100_003,
                version: 3,
                procedure: 17,
                arguments: arguments,
                identity: configuration.identity
            )
            var reader = reply
            let status = try reader.u32()
            guard status == 0 else {
                throw Self.error(forNFSStatus: status)
            }

            try Self.skipPostOpAttributes(&reader)
            cookieVerifier = try reader.fixedOpaque(8)
            let eof = try reader.bool()

            while true {
                let hasEntry = try reader.bool()
                if !hasEntry {
                    break
                }

                _ = try reader.u64() // fileid
                let name = try reader.string()
                cookie = try reader.u64()
                let info = try Self.readPostOpAttributes(&reader)
                let fileHandle = try Self.readPostOpFileHandle(&reader)

                if name != ".", name != "..", !name.isEmpty,
                   let fileHandle {
                    entries.append(
                        NFSEntry(
                            name: name,
                            fileHandle: fileHandle,
                            isDirectory: info?.isDirectory ?? false,
                            size: info?.size,
                            modifiedAt: info?.modifiedAt
                        )
                    )
                }
            }

            if eof {
                break
            }
        }

        return entries
    }

    public func stat(handle: Data) async throws -> NFSFileInfo {
        var arguments = XDRWriter()
        arguments.opaque(handle)

        let reply = try await nfs.call(
            program: 100_003,
            version: 3,
            procedure: 1,
            arguments: arguments,
            identity: configuration.identity
        )
        var reader = reply
        let status = try reader.u32()
        guard status == 0 else {
            throw Self.error(forNFSStatus: status)
        }
        return try Self.readAttributes(&reader)
    }

    public func lookup(path: String) async throws -> NFSLookup {
        let root = stateLock.withLock { rootHandle }
        guard var handle = root else {
            throw NFSError.invalidConfiguration(
                "The NFS export has not been mounted."
            )
        }

        var info = try await stat(handle: handle)
        for component in path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ) {
            var arguments = XDRWriter()
            arguments.opaque(handle)
            arguments.string(String(component))

            let reply = try await nfs.call(
                program: 100_003,
                version: 3,
                procedure: 3,
                arguments: arguments,
                identity: configuration.identity
            )
            var reader = reply
            let status = try reader.u32()
            guard status == 0 else {
                throw Self.error(forNFSStatus: status)
            }
            handle = try reader.opaque()
            info = try Self.readPostOpAttributes(&reader)
                ?? NFSFileInfo()
        }

        return NFSLookup(fileHandle: handle, info: info)
    }

    public func read(
        handle: Data,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        var arguments = XDRWriter()
        arguments.opaque(handle)
        arguments.u64(UInt64(max(0, offset)))
        arguments.u32(UInt32(max(1, length)))

        let reply = try await nfs.call(
            program: 100_003,
            version: 3,
            procedure: 6,
            arguments: arguments,
            identity: configuration.identity
        )
        var reader = reply
        let status = try reader.u32()
        guard status == 0 else {
            throw Self.error(forNFSStatus: status)
        }

        try Self.skipPostOpAttributes(&reader)
        let count = Int(try reader.u32())
        _ = try reader.bool() // eof
        let data = try reader.opaque()
        guard data.count >= count else {
            throw NFSError.protocolViolation(
                "The NFS read returned fewer bytes than declared."
            )
        }
        return Data(data.prefix(count))
    }

    public func disconnect() async {
        await nfs.close()
        await mounter.close()
        await portmapper.close()
    }

    // MARK: - Portmapper

    private func getPort(
        program: UInt32,
        version: UInt32
    ) async throws -> Int {
        var arguments = XDRWriter()
        arguments.u32(program)
        arguments.u32(version)
        arguments.u32(6) // IPPROTO_TCP
        arguments.u32(0)

        let reply = try await portmapper.call(
            program: 100_000,
            version: 2,
            procedure: 3,
            arguments: arguments,
            identity: configuration.identity
        )
        var reader = reply
        let port = try reader.u32()
        guard port > 0, port <= 65_535 else {
            throw NFSError.connectionFailed(
                "The portmapper did not return a port for program \(program)."
            )
        }
        return Int(port)
    }

    // MARK: - Attribute helpers

    private static func skipPostOpAttributes(
        _ reader: inout XDRReader
    ) throws {
        let present = try reader.bool()
        if present {
            _ = try readAttributes(&reader)
        }
    }

    private static func readPostOpAttributes(
        _ reader: inout XDRReader
    ) throws -> NFSFileInfo? {
        let present = try reader.bool()
        guard present else {
            return nil
        }
        return try readAttributes(&reader)
    }

    private static func readPostOpFileHandle(
        _ reader: inout XDRReader
    ) throws -> Data? {
        let present = try reader.bool()
        guard present else {
            return nil
        }
        return try reader.opaque()
    }

    private static func readAttributes(
        _ reader: inout XDRReader
    ) throws -> NFSFileInfo {
        let type = try reader.u32()
        _ = try reader.u32() // mode
        _ = try reader.u32() // nlink
        _ = try reader.u32() // uid
        _ = try reader.u32() // gid
        let size = try reader.u64()
        _ = try reader.u64() // used
        _ = try reader.u64() // rdev
        _ = try reader.u64() // fsid
        _ = try reader.u64() // fileid
        _ = try reader.u32() // atime seconds
        _ = try reader.u32() // atime nanoseconds
        let mtimeSeconds = try reader.u32()
        _ = try reader.u32() // mtime nanoseconds
        _ = try reader.u32() // ctime seconds
        _ = try reader.u32() // ctime nanoseconds

        return NFSFileInfo(
            size: Int64(size),
            modifiedAt: Date(
                timeIntervalSince1970: TimeInterval(mtimeSeconds)
            ),
            isDirectory: type == 2
        )
    }

    private static func error(forNFSStatus status: UInt32) -> NFSError {
        switch status {
        case 1:
            return .accessDenied
        case 2:
            return .notFound("the requested path")
        case 70:
            return .staleHandle
        default:
            return .protocolViolation("NFS status \(status).")
        }
    }
}
