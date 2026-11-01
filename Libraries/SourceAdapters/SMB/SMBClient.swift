import CryptoKit
import Foundation

/// Connection settings for an SMB share.
public struct SMBConfiguration: Sendable, Equatable {
    /// SMB port. Servers default to 445.
    public var port: Int

    /// TCP connect and per-request timeout.
    public var timeout: TimeInterval

    /// NetBIOS/SMB domain for NTLMv2.
    public var domain: String

    /// Client NetBIOS name.
    public var workstation: String

    /// Requested share.
    public var share: String

    /// How many times a failed ranged read is retried.
    public var maxReconnects: Int

    /// Base delay for exponential reconnect backoff.
    public var reconnectBaseDelay: TimeInterval

    public init(
        port: Int = 445,
        timeout: TimeInterval = 30,
        domain: String = "",
        workstation: String = "PLAYITRIGHT",
        share: String = "",
        maxReconnects: Int = 4,
        reconnectBaseDelay: TimeInterval = 0.5
    ) {
        self.port = port
        self.timeout = max(1, timeout)
        self.domain = domain
        self.workstation = workstation
        self.share = share
        self.maxReconnects = max(0, maxReconnects)
        self.reconnectBaseDelay = max(0, reconnectBaseDelay)
    }
}

/// Username and password resolved from the Keychain (SRC-3).
public struct SMBCredentials: Sendable, Equatable {
    public var username: String
    public var password: String
    public var domain: String

    public init(username: String, password: String, domain: String = "") {
        self.username = username
        self.password = password
        self.domain = domain
    }
}

/// One directory entry.
public struct SMBEntry: Sendable, Equatable {
    /// Path relative to the share root, using forward slashes.
    public var path: String

    /// File or directory name.
    public var name: String

    /// Whether this is a directory.
    public var isDirectory: Bool

    /// Size in bytes.
    public var size: Int64?

    /// Last write time.
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

/// Metadata for a single share path.
public struct SMBFileInfo: Sendable, Equatable {
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

/// Failures raised by SMB clients.
public enum SMBError: Error, Sendable, Equatable, LocalizedError {
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
            return "Invalid SMB configuration: \(message)"
        case .connectionFailed(let message):
            return "Could not connect to the SMB share: \(message)"
        case .authenticationFailed:
            return "The SMB server rejected the username or password."
        case .accessDenied:
            return "The SMB share denied access."
        case .notFound(let path):
            return "The SMB path '\(path)' was not found."
        case .protocolViolation(let message):
            return "The SMB server violated the protocol: \(message)"
        case .transport(let message):
            return "SMB transport failed: \(message)"
        case .cancelled:
            return "The SMB request was cancelled."
        case .unsupported(let feature):
            return "This SMB client does not support \(feature)."
        }
    }
}

/// The operations ``SMBSourceAdapter`` needs from an SMB client.
///
/// Keeping this as a protocol lets the adapter use the pure-Swift client in
/// production and a deterministic mock in tests (SRC-1).
public protocol SMBClient: Sendable {
    func connect() async throws
    func authenticate(credentials: SMBCredentials) async throws
    func treeConnect(share: String) async throws
    func listDirectory(path: String) async throws -> [SMBEntry]
    func stat(path: String) async throws -> SMBFileInfo
    func read(path: String, offset: Int64, length: Int) async throws -> Data
    func disconnect() async
}

// MARK: - NTLMv2

/// NTLMv2 response material used by SMB session setup.
///
/// The implementation follows MS-NLMP and is exercised by deterministic unit
/// tests so a regression cannot silently break authentication.
public struct NTLMv2Response: Sendable, Equatable {
    public var lmResponse: Data
    public var ntResponse: Data
    public var sessionBaseKey: Data

    /// Builds the NTLMv2 challenge responses.
    ///
    /// - Parameters:
    ///   - username: Account name.
    ///   - password: Account password.
    ///   - domain: NTLM domain, usually empty or the NetBIOS domain.
    ///   - serverChallenge: The 8-byte challenge from the Type 2 message.
    ///   - clientChallenge: Optional 8-byte client nonce, for tests.
    ///   - timestamp: Windows FILETIME timestamp.
    ///   - targetInfo: Raw target-info bytes from the Type 2 message.
    public init(
        username: String,
        password: String,
        domain: String,
        serverChallenge: Data,
        clientChallenge: Data? = nil,
        timestamp: Date = Date(),
        targetInfo: Data = Data()
    ) {
        let clientChallenge = clientChallenge ?? Self.randomChallenge()
        let ntHash = Self.ntHash(password: password)
        let identity = "\(username.uppercased())\(domain)"
        let responseKey = Self.hmacMD5(
            key: ntHash,
            data: Data(identity.utf16le)
        )

        var blob = Data()
        blob.append(contentsOf: [0x01, 0x01, 0x00, 0x00])
        blob.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        blob.append(Self.fileTime(timestamp))
        blob.append(clientChallenge)
        blob.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        blob.append(targetInfo)
        blob.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        var proofInput = Data()
        proofInput.append(serverChallenge)
        proofInput.append(blob)
        let ntProof = Self.hmacMD5(key: responseKey, data: proofInput)

        self.ntResponse = ntProof + blob

        var lmInput = Data()
        lmInput.append(serverChallenge)
        lmInput.append(clientChallenge)
        self.lmResponse = Self.hmacMD5(key: responseKey, data: lmInput)
            + clientChallenge
        self.sessionBaseKey = Self.hmacMD5(key: responseKey, data: ntProof)
    }

    /// The NT hash: MD4 of the UTF-16LE password.
    public static func ntHash(password: String) -> Data {
        MD4.hash(Data(password.utf16le))
    }

    static func hmacMD5(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        return Data(HMAC<Insecure.MD5>.authenticationCode(
            for: data,
            using: symmetricKey
        ))
    }

    static func fileTime(_ date: Date) -> Data {
        // 100-nanosecond intervals since 1601-01-01.
        let seconds = date.timeIntervalSince1970 + 11_644_473_600
        let ticks = UInt64(max(0, seconds) * 10_000_000)
        var value = ticks.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    static func randomChallenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }
}

/// A compact, dependency-free MD4 implementation for NTLM.
enum MD4 {
    static func hash(_ data: Data) -> Data {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8

        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 0, through: 56, by: 8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var a: UInt32 = 0x6745_2301
        var b: UInt32 = 0xEFCD_AB89
        var c: UInt32 = 0x98BA_DCFE
        var d: UInt32 = 0x1032_5476

        let shifts1: [UInt32] = [3, 7, 11, 19]
        let shifts2: [UInt32] = [3, 5, 9, 13]
        let shifts3: [UInt32] = [3, 9, 11, 15]
        let order2 = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15]
        let order3 = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]

        func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
            (value << amount) | (value >> (32 - amount))
        }

        for chunk in stride(from: 0, to: message.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let base = chunk + index * 4
                x[index] = UInt32(message[base])
                    | (UInt32(message[base + 1]) << 8)
                    | (UInt32(message[base + 2]) << 16)
                    | (UInt32(message[base + 3]) << 24)
            }

            let aa = a
            let bb = b
            let cc = c
            let dd = d

            for index in 0..<16 {
                let shift = shifts1[index % 4]
                switch index % 4 {
                case 0:
                    a = rotate(a &+ F(b, c, d) &+ x[index], shift)
                case 1:
                    d = rotate(d &+ F(a, b, c) &+ x[index], shift)
                case 2:
                    c = rotate(c &+ F(d, a, b) &+ x[index], shift)
                default:
                    b = rotate(b &+ F(c, d, a) &+ x[index], shift)
                }
            }

            for index in 0..<16 {
                let shift = shifts2[index % 4]
                let word = x[order2[index]]
                switch index % 4 {
                case 0:
                    a = rotate(a &+ G(b, c, d) &+ word &+ 0x5A82_7999, shift)
                case 1:
                    d = rotate(d &+ G(a, b, c) &+ word &+ 0x5A82_7999, shift)
                case 2:
                    c = rotate(c &+ G(d, a, b) &+ word &+ 0x5A82_7999, shift)
                default:
                    b = rotate(b &+ G(c, d, a) &+ word &+ 0x5A82_7999, shift)
                }
            }

            for index in 0..<16 {
                let shift = shifts3[index % 4]
                let word = x[order3[index]]
                switch index % 4 {
                case 0:
                    a = rotate(a &+ H(b, c, d) &+ word &+ 0x6ED9_EBA1, shift)
                case 1:
                    d = rotate(d &+ H(a, b, c) &+ word &+ 0x6ED9_EBA1, shift)
                case 2:
                    c = rotate(c &+ H(d, a, b) &+ word &+ 0x6ED9_EBA1, shift)
                default:
                    b = rotate(b &+ H(c, d, a) &+ word &+ 0x6ED9_EBA1, shift)
                }
            }

            a = a &+ aa
            b = b &+ bb
            c = c &+ cc
            d = d &+ dd
        }

        var result = Data()
        for value in [a, b, c, d] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        return result
    }

    private static func F(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        (x & y) | (~x & z)
    }

    private static func G(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        (x & y) | (x & z) | (y & z)
    }

    private static func H(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        x ^ y ^ z
    }
}

extension String {
    var utf16le: [UInt8] {
        Array(utf16).flatMap { character in
            let value = UInt16(character).littleEndian
            return [UInt8(value & 0xFF), UInt8(value >> 8)]
        }
    }
}
