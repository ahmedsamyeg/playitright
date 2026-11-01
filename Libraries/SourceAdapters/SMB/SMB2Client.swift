import Foundation
import Network

/// Small synchronous lock wrapper. Keeping locking inside a synchronous helper
/// makes it safe to call from async contexts under Swift concurrency checking.
final class SMBLock: @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A framed SMB2 transport. Unit tests inject a scripted transport; production
/// uses ``NetworkSMBTransport``.
public protocol SMBTransport: Sendable {
    func open(host: String, port: Int, timeout: TimeInterval) async throws
    func send(_ frame: Data) async throws
    func receiveFrame() async throws -> Data
    func close() async
}

/// TCP transport implementing the NetBIOS session-service length prefix.
public final class NetworkSMBTransport: SMBTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SourceAdapters.SMB.transport")
    private var connection: NWConnection?
    private let stateLock = SMBLock()

    public init() {}

    public func open(
        host: String,
        port: Int,
        timeout: TimeInterval
    ) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw SMBError.invalidConfiguration("Invalid port \(port).")
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .tcp
        )
        self.connection = connection

        let gate = ResumeGate()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume {
                        continuation.resume()
                    }
                case .failed(let error):
                    gate.resume {
                        continuation.resume(
                            throwing: SMBError.connectionFailed(
                                error.localizedDescription
                            )
                        )
                    }
                case .cancelled:
                    gate.resume {
                        continuation.resume(
                            throwing: SMBError.cancelled
                        )
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
                        throwing: SMBError.connectionFailed(
                            "Timed out after \(timeout) seconds."
                        )
                    )
                }
            }
        }
    }

    public func send(_ frame: Data) async throws {
        guard let connection else {
            throw SMBError.transport("The SMB connection is not open.")
        }

        var payload = Data()
        payload.append(UInt8((frame.count >> 24) & 0xFF))
        payload.append(UInt8((frame.count >> 16) & 0xFF))
        payload.append(UInt8((frame.count >> 8) & 0xFF))
        payload.append(UInt8(frame.count & 0xFF))
        payload.append(frame)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: payload,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(
                            throwing: SMBError.transport(
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

    public func receiveFrame() async throws -> Data {
        guard let connection else {
            throw SMBError.transport("The SMB connection is not open.")
        }

        let header = try await receiveExactly(4, on: connection)
        let length = (Int(header[0]) << 24)
            | (Int(header[1]) << 16)
            | (Int(header[2]) << 8)
            | Int(header[3])
        guard length > 0, length <= 64 * 1024 * 1024 else {
            throw SMBError.protocolViolation(
                "Invalid SMB frame length \(length)."
            )
        }
        return try await receiveExactly(length, on: connection)
    }

    public func close() async {
        let connection = stateLock.withLock { () -> NWConnection? in
            let value = self.connection
            self.connection = nil
            return value
        }
        connection?.cancel()
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
    ) {
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
                    throwing: SMBError.transport(error.localizedDescription)
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
                    throwing: SMBError.transport(
                        "The SMB connection closed early."
                    )
                )
                return
            }

            guard let self else {
                continuation.resume(throwing: SMBError.cancelled)
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

private final class ResumeGate: @unchecked Sendable {
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

/// Pure-Swift SMB2/3 client for the adapter's narrow needs.
///
/// It negotiates SMB 2.1 through 3.0.2, authenticates with NTLMv2, connects a
/// tree, enumerates directories, and performs ranged reads. Signing and
/// encryption are intentionally not enabled; servers that require either are
/// rejected rather than silently downgraded.
public final class SMB2Client: SMBClient, @unchecked Sendable {
    private let host: String
    private let configuration: SMBConfiguration
    private let transport: SMBTransport

    private let stateLock = SMBLock()
    private var nextMessageID: UInt64 = 0
    private var sessionID: UInt64 = 0
    private var treeID: UInt32 = 0
    private var userID: UInt32 = 0

    public init(
        host: String,
        configuration: SMBConfiguration = SMBConfiguration(),
        transport: SMBTransport = NetworkSMBTransport()
    ) {
        self.host = host
        self.configuration = configuration
        self.transport = transport
    }

    // MARK: - SMBClient

    public func connect() async throws {
        do {
            try await transport.open(
                host: host,
                port: configuration.port,
                timeout: configuration.timeout
            )
            try await negotiate()
        } catch {
            await transport.close()
            throw error
        }
    }

    public func authenticate(credentials: SMBCredentials) async throws {
        let domain = credentials.domain.isEmpty
            ? configuration.domain
            : credentials.domain

        let type1 = Self.type1Message(
            domain: domain,
            workstation: configuration.workstation
        )
        let first = try await sessionSetup(type1, sessionID: 0)
        guard let type2 = first.securityBuffer else {
            throw SMBError.protocolViolation(
                "The server did not return an NTLM challenge."
            )
        }
        let challenge = try Self.parseType2(type2)

        let response = NTLMv2Response(
            username: credentials.username,
            password: credentials.password,
            domain: domain,
            serverChallenge: challenge.serverChallenge,
            targetInfo: challenge.targetInfo
        )
        let type3 = Self.type3Message(
            username: credentials.username,
            domain: domain,
            workstation: configuration.workstation,
            flags: challenge.flags,
            response: response
        )

        let second = try await sessionSetup(
            type3,
            sessionID: first.sessionID
        )
        stateLock.withLock {
            sessionID = second.sessionID
        }
    }

    public func treeConnect(share: String) async throws {
        let path = "\\\\\(host)\\\(share)"
        let encoded = Data(path.utf16le)

        var body = Data()
        body.appendLE(UInt16(9))
        body.appendLE(UInt16(0))
        body.appendLE(UInt16(64 + 8))
        body.appendLE(UInt16(encoded.count))
        body.append(encoded)

        let response = try await exchange(
            command: 0x0003,
            body: body,
            sessionID: currentSessionID()
        )
        stateLock.withLock {
            treeID = response.treeID
        }
    }

    public func listDirectory(path: String) async throws -> [SMBEntry] {
        let created = try await create(
            path: path,
            isDirectory: true
        )
        let fileID = created.fileID

        do {
            var entries: [SMBEntry] = []
            var restart = true

            while true {
                try Task.checkCancellation()
                let result = try await queryDirectory(
                    fileID: fileID,
                    pattern: "*",
                    restart: restart
                )
                restart = false
                entries.append(contentsOf: result.entries)
                if result.done {
                    break
                }
            }

            try await close(fileID: fileID)
            return entries
        } catch {
            try? await close(fileID: fileID)
            throw error
        }
    }

    public func stat(path: String) async throws -> SMBFileInfo {
        let created = try await create(path: path, isDirectory: false)
        try await close(fileID: created.fileID)
        return SMBFileInfo(
            size: created.size,
            modifiedAt: created.modifiedAt,
            isDirectory: created.isDirectory
        )
    }

    public func read(
        path: String,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        let created = try await create(path: path, isDirectory: false)
        do {
            let data = try await read(
                fileID: created.fileID,
                offset: offset,
                length: length
            )
            try await close(fileID: created.fileID)
            return data
        } catch {
            try? await close(fileID: created.fileID)
            throw error
        }
    }

    public func disconnect() async {
        if currentSessionID() != 0 {
            _ = try? await exchange(
                command: 0x0002,
                body: Data([0x04, 0x00, 0x00, 0x00]),
                sessionID: currentSessionID()
            )
        }
        await transport.close()
    }

    // MARK: - Negotiate

    private func negotiate() async throws {
        var body = Data()
        body.appendLE(UInt16(36))
        body.appendLE(UInt16(3))
        body.appendLE(UInt16(0x0001)) // signing enabled, not required
        body.appendLE(UInt16(0))
        body.appendLE(UInt32(0))
        body.append(Data(repeating: 0, count: 16))
        body.appendLE(UInt64(0))
        body.appendLE(UInt16(0x0210))
        body.appendLE(UInt16(0x0300))
        body.appendLE(UInt16(0x0302))

        let response = try await exchange(command: 0x0000, body: body)
        guard response.body.count >= 6 else {
            throw SMBError.protocolViolation(
                "The negotiate response was truncated."
            )
        }
        let dialect = response.body.uint16LE(at: 4)
        let allowed: Set<UInt16> = [0x0210, 0x0300, 0x0302]
        guard allowed.contains(dialect) else {
            throw SMBError.unsupported(
                "SMB dialect 0x\(String(dialect, radix: 16))"
            )
        }
    }

    // MARK: - Session setup

    private struct SessionSetupResult {
        var sessionID: UInt64
        var securityBuffer: Data?
    }

    private func sessionSetup(
        _ message: Data,
        sessionID: UInt64
    ) async throws -> SessionSetupResult {
        var body = Data()
        body.appendLE(UInt16(25))
        body.append(UInt8(0))
        body.append(UInt8(1))
        body.appendLE(UInt32(0))
        body.appendLE(UInt32(0))
        body.appendLE(UInt16(64 + 24))
        body.appendLE(UInt16(message.count))
        body.appendLE(UInt64(0))
        body.append(message)

        let (header, response, _) = try await exchangeRaw(
            command: 0x0001,
            body: body,
            sessionID: sessionID
        )

        let session = header.sessionID
        guard response.count >= 8 else {
            throw SMBError.protocolViolation(
                "The session setup response was truncated."
            )
        }
        let offset = Int(response.uint16LE(at: 4))
        let length = Int(response.uint16LE(at: 6))
        let security = Data(
            response[
                min(offset, response.count)..<min(
                    offset + length,
                    response.count
                )
            ]
        )

        if header.status != Self.moreProcessingRequired,
           header.status != 0 {
            throw Self.error(for: header.status)
        }

        return SessionSetupResult(
            sessionID: session,
            securityBuffer: security.isEmpty ? nil : security
        )
    }

    // MARK: - Tree / file operations

    private struct CreatedFile {
        var fileID: Data
        var size: Int64?
        var modifiedAt: Date?
        var isDirectory: Bool
    }

    private func create(
        path: String,
        isDirectory: Bool
    ) async throws -> CreatedFile {
        let relative = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "\\")
        let encoded = Data(relative.utf16le)

        var body = Data()
        body.appendLE(UInt16(57))
        body.append(UInt8(0))
        body.append(UInt8(0))
        body.appendLE(UInt32(2))
        body.appendLE(UInt64(0))
        body.appendLE(UInt64(0))
        body.appendLE(UInt32(0x0000_0081))
        body.appendLE(UInt32(0x0000_0080))
        body.appendLE(UInt32(0x0000_0007))
        body.appendLE(UInt32(1))
        body.appendLE(UInt32(isDirectory ? 0x0000_0001 : 0x0000_0040))
        body.appendLE(UInt16(64 + 56))
        body.appendLE(UInt16(encoded.count))
        body.appendLE(UInt32(0))
        body.appendLE(UInt32(0))
        body.append(encoded)

        let response = try await exchange(
            command: 0x0005,
            body: body,
            treeID: currentTreeID(),
            sessionID: currentSessionID()
        )

        guard response.body.count >= 80 else {
            throw SMBError.protocolViolation(
                "The create response was truncated."
            )
        }

        let attributes = response.body.uint32LE(at: 56)
        return CreatedFile(
            fileID: Data(response.body[64..<80]),
            size: response.body.uint64LE(at: 48).map(Int64.init),
            modifiedAt: response.body.uint64LE(at: 24)
                .map(Self.date(fromFileTime:)),
            isDirectory: attributes & 0x0000_0010 != 0
        )
    }

    private func read(
        fileID: Data,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        var body = Data()
        body.appendLE(UInt16(49))
        body.append(UInt8(0))
        body.append(UInt8(0))
        body.appendLE(UInt32(length))
        body.appendLE(UInt64(offset))
        body.append(fileID)
        body.appendLE(UInt32(0))
        body.appendLE(UInt32(0))
        body.appendLE(UInt32(0))
        body.appendLE(UInt16(0))
        body.appendLE(UInt16(0))
        body.append(UInt8(0))

        let response = try await exchange(
            command: 0x0008,
            body: body,
            treeID: currentTreeID(),
            sessionID: currentSessionID()
        )
        guard response.body.count >= 12 else {
            throw SMBError.protocolViolation(
                "The read response was truncated."
            )
        }

        let dataOffset = Int(response.body[2])
        let dataLength = Int(response.body.uint32LE(at: 4))
        let start = dataOffset
        let end = start + dataLength
        guard start <= response.packet.count, end <= response.packet.count else {
            throw SMBError.protocolViolation(
                "The read response pointed outside the packet."
            )
        }
        return Data(response.packet[start..<end])
    }

    private struct DirectoryPage {
        var entries: [SMBEntry]
        var done: Bool
    }

    private func queryDirectory(
        fileID: Data,
        pattern: String,
        restart: Bool
    ) async throws -> DirectoryPage {
        let encoded = Data(pattern.utf16le)

        var body = Data()
        body.appendLE(UInt16(33))
        body.append(UInt8(0x25)) // FileIdBothDirectoryInformation
        body.append(UInt8(restart ? 0x01 : 0x00))
        body.appendLE(UInt32(0))
        body.append(fileID)
        body.appendLE(UInt16(64 + 32))
        body.appendLE(UInt16(encoded.count))
        body.appendLE(UInt32(64 * 1024))
        body.append(encoded)

        do {
            let response = try await exchange(
                command: 0x000E,
                body: body,
                treeID: currentTreeID(),
                sessionID: currentSessionID()
            )
            guard response.body.count >= 8 else {
                throw SMBError.protocolViolation(
                    "The directory response was truncated."
                )
            }

            let offset = Int(response.body.uint16LE(at: 2))
            let length = Int(response.body.uint32LE(at: 4))
            let start = offset
            let end = start + length
            guard start <= response.packet.count, end <= response.packet.count else {
                throw SMBError.protocolViolation(
                    "The directory buffer pointed outside the packet."
                )
            }

            let buffer = response.packet[start..<end]
            return DirectoryPage(
                entries: Self.parseDirectoryBuffer(Data(buffer)),
                done: length == 0
            )
        } catch SMBError.notFound {
            return DirectoryPage(entries: [], done: true)
        }
    }

    private func close(fileID: Data) async throws {
        var body = Data()
        body.appendLE(UInt16(24))
        body.appendLE(UInt16(0))
        body.appendLE(UInt32(0))
        body.append(fileID)
        _ = try await exchange(
            command: 0x0006,
            body: body,
            treeID: currentTreeID(),
            sessionID: currentSessionID()
        )
    }

    // MARK: - Packet exchange

    private struct ExchangeResponse {
        var status: UInt32
        var sessionID: UInt64
        var treeID: UInt32
        var body: Data
        var packet: Data
    }

    private func exchange(
        command: UInt16,
        body: Data,
        treeID: UInt32 = 0,
        sessionID: UInt64 = 0
    ) async throws -> ExchangeResponse {
        let (header, responseBody, packet) = try await exchangeRaw(
            command: command,
            body: body,
            treeID: treeID,
            sessionID: sessionID
        )

        switch header.status {
        case 0, Self.moreProcessingRequired, Self.noMoreFiles:
            return ExchangeResponse(
                status: header.status,
                sessionID: header.sessionID,
                treeID: header.treeID,
                body: responseBody,
                packet: packet
            )
        default:
            throw Self.error(for: header.status)
        }
    }

    private struct ResponseHeader {
        var status: UInt32
        var sessionID: UInt64
        var treeID: UInt32
    }

    private func exchangeRaw(
        command: UInt16,
        body: Data,
        treeID: UInt32 = 0,
        sessionID: UInt64 = 0
    ) async throws -> (ResponseHeader, Data, Data) {
        let messageID = nextMessage()
        let request = Self.request(
            command: command,
            body: body,
            messageID: messageID,
            treeID: treeID,
            sessionID: sessionID
        )
        try await transport.send(request)

        let packet = try await transport.receiveFrame()
        guard packet.count >= 64,
              packet[0] == 0xFE,
              packet[1] == 0x53,
              packet[2] == 0x4D,
              packet[3] == 0x42 else {
            throw SMBError.protocolViolation("Invalid SMB2 packet header.")
        }

        let status = packet.uint32LE(at: 8)
        let responseSession = packet.uint64LE(at: 40) ?? 0
        let responseTree = packet.uint32LE(at: 36)
        let header = ResponseHeader(
            status: status,
            sessionID: responseSession,
            treeID: responseTree
        )
        return (header, Data(packet[64...]), packet)
    }

    private static func request(
        command: UInt16,
        body: Data,
        messageID: UInt64,
        treeID: UInt32,
        sessionID: UInt64
    ) -> Data {
        var packet = Data()
        packet.append(contentsOf: [0xFE, 0x53, 0x4D, 0x42])
        packet.appendLE(UInt16(64))
        packet.appendLE(UInt16(1))
        packet.appendLE(UInt32(0))
        packet.appendLE(command)
        packet.appendLE(UInt16(1))
        packet.appendLE(UInt32(0))
        packet.appendLE(UInt32(0))
        packet.appendLE(messageID)
        packet.appendLE(UInt32(0))
        packet.appendLE(treeID)
        packet.appendLE(sessionID)
        packet.append(Data(repeating: 0, count: 16))
        packet.append(body)
        return packet
    }

    // MARK: - NTLM messages

    private static func type1Message(
        domain: String,
        workstation: String
    ) -> Data {
        var message = Data()
        message.append(Data("NTLMSSP\u{0}".utf8))
        message.appendLE(UInt32(1))
        message.appendLE(UInt32(0xE208_82B7))
        message.appendLE(UInt16(0))
        message.appendLE(UInt16(0))
        message.appendLE(UInt32(40))
        message.appendLE(UInt16(0))
        message.appendLE(UInt16(0))
        message.appendLE(UInt32(40))
        return message
    }

    private struct Type2Message {
        var flags: UInt32
        var serverChallenge: Data
        var targetInfo: Data
    }

    private static func parseType2(_ data: Data) throws -> Type2Message {
        guard data.count >= 48,
              data.starts(with: Data("NTLMSSP\u{0}".utf8)),
              data.uint32LE(at: 8) == 2 else {
            throw SMBError.protocolViolation(
                "The NTLM challenge was malformed."
            )
        }

        let flags = data.uint32LE(at: 20)
        let challenge = Data(data[24..<32])

        let infoLength = Int(data.uint16LE(at: 40))
        let infoOffset = Int(data.uint32LE(at: 44))
        let targetInfo: Data
        if infoLength > 0,
           infoOffset + infoLength <= data.count {
            targetInfo = Data(
                data[infoOffset..<(infoOffset + infoLength)]
            )
        } else {
            targetInfo = Data()
        }

        return Type2Message(
            flags: flags,
            serverChallenge: challenge,
            targetInfo: targetInfo
        )
    }

    private static func type3Message(
        username: String,
        domain: String,
        workstation: String,
        flags: UInt32,
        response: NTLMv2Response
    ) -> Data {
        let domainBytes = Data(domain.utf16le)
        let userBytes = Data(username.utf16le)
        let workstationBytes = Data(workstation.utf16le)
        let sessionKey = Data()

        var payload = Data()
        let lmOffset = 64
        payload.append(response.lmResponse)
        let ntOffset = lmOffset + response.lmResponse.count
        payload.append(response.ntResponse)
        let domainOffset = ntOffset + response.ntResponse.count
        payload.append(domainBytes)
        let userOffset = domainOffset + domainBytes.count
        payload.append(userBytes)
        let workstationOffset = userOffset + userBytes.count
        payload.append(workstationBytes)
        let sessionKeyOffset = workstationOffset + workstationBytes.count
        payload.append(sessionKey)

        var message = Data()
        message.append(Data("NTLMSSP\u{0}".utf8))
        message.appendLE(UInt32(3))
        message.appendLE(UInt16(response.lmResponse.count))
        message.appendLE(UInt16(response.lmResponse.count))
        message.appendLE(UInt32(lmOffset))
        message.appendLE(UInt16(response.ntResponse.count))
        message.appendLE(UInt16(response.ntResponse.count))
        message.appendLE(UInt32(ntOffset))
        message.appendLE(UInt16(domainBytes.count))
        message.appendLE(UInt16(domainBytes.count))
        message.appendLE(UInt32(domainOffset))
        message.appendLE(UInt16(userBytes.count))
        message.appendLE(UInt16(userBytes.count))
        message.appendLE(UInt32(userOffset))
        message.appendLE(UInt16(workstationBytes.count))
        message.appendLE(UInt16(workstationBytes.count))
        message.appendLE(UInt32(workstationOffset))
        message.appendLE(UInt16(sessionKey.count))
        message.appendLE(UInt16(sessionKey.count))
        message.appendLE(UInt32(sessionKeyOffset))
        message.appendLE(flags & ~UInt32(0x0200_0000))
        message.append(payload)
        return message
    }

    // MARK: - Parsing helpers

    private static func parseDirectoryBuffer(_ buffer: Data) -> [SMBEntry] {
        var entries: [SMBEntry] = []
        var offset = 0

        while offset + 104 <= buffer.count {
            let next = Int(buffer.uint32LE(at: offset))
            let attributes = buffer.uint32LE(at: offset + 56)
            let nameLength = Int(buffer.uint32LE(at: offset + 60))
            let endOfFile = buffer.uint64LE(at: offset + 40)
            let lastWrite = buffer.uint64LE(at: offset + 24)

            let nameStart = offset + 104
            let nameEnd = nameStart + nameLength
            guard nameEnd <= buffer.count else {
                break
            }

            let name = buffer[nameStart..<nameEnd].utf16leString()
            if name != ".", name != "..", !name.isEmpty {
                entries.append(
                    SMBEntry(
                        path: name,
                        name: name,
                        isDirectory: attributes & 0x0000_0010 != 0,
                        size: endOfFile.map(Int64.init),
                        modifiedAt: lastWrite.map(date(fromFileTime:))
                    )
                )
            }

            if next <= 0 {
                break
            }
            offset += next
        }

        return entries
    }

    private static func date(fromFileTime ticks: UInt64) -> Date {
        let seconds = Double(ticks) / 10_000_000 - 11_644_473_600
        return Date(timeIntervalSince1970: seconds)
    }

    private static func error(for status: UInt32) -> SMBError {
        switch status {
        case 0:
            return .transport("Unexpected success status.")
        case 0xC000_006D, 0xC000_006E:
            return .authenticationFailed
        case 0xC000_0022:
            return .accessDenied
        case 0xC000_0034, 0xC000_003A:
            return .notFound("the requested path")
        case 0xC000_00CC:
            return .invalidConfiguration("The share does not exist.")
        case 0xC000_0203, 0xC000_035C:
            return .authenticationFailed
        default:
            return .protocolViolation(
                "SMB status 0x\(String(status, radix: 16))."
            )
        }
    }

    // MARK: - State

    private func nextMessage() -> UInt64 {
        stateLock.withLock {
            let value = nextMessageID
            nextMessageID += 1
            return value
        }
    }

    private func currentSessionID() -> UInt64 {
        stateLock.withLock {
            sessionID
        }
    }

    private func currentTreeID() -> UInt32 {
        stateLock.withLock {
            treeID
        }
    }

    private static let moreProcessingRequired: UInt32 = 0xC000_0016
    private static let noMoreFiles: UInt32 = 0x8000_0006
}

// MARK: - Little-endian data helpers

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendLE(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    func uint16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else {
            return 0
        }
        let base = startIndex + offset
        return UInt16(self[base])
            | (UInt16(self[base + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else {
            return 0
        }
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }

    func uint64LE(at offset: Int) -> UInt64? {
        guard offset + 8 <= count else {
            return nil
        }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[startIndex + offset + index])
                << UInt64(index * 8)
        }
        return value
    }

    func utf16leString() -> String {
        var units: [UInt16] = []
        units.reserveCapacity(count / 2)
        var index = startIndex
        while index + 1 < endIndex {
            units.append(
                UInt16(self[index]) | (UInt16(self[index + 1]) << 8)
            )
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}
