import Foundation

/// Supported LAN and remote file sharing protocols (SRC-2, SRC-3, SRC-9).
public enum FileProtocolType: String, CaseIterable, Sendable {
    case smb2
    case smb3
    case nfsv3
    case sftp
    case webdav
}

/// Normalized credential representation for file servers.
public struct ServerCredentials: Equatable, Sendable {
    public let host: String
    public let port: Int?
    public let username: String?
    public let domain: String?
    public let anonymous: Bool

    public init(
        host: String,
        port: Int? = nil,
        username: String? = nil,
        domain: String? = nil,
        anonymous: Bool = false
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.anonymous = anonymous
    }
}

/// Request for a specific byte range within a remote file.
public struct ByteRangeRequest: Equatable, Sendable {
    public let offset: UInt64
    public let length: UInt64?

    public init(offset: UInt64, length: UInt64? = nil) {
        self.offset = offset
        self.length = length
    }
}

/// Metrics gathered during protocol operations (SRC-10).
public struct ProtocolSessionMetrics: Equatable, Sendable {
    public var bytesRead: UInt64 = 0
    public var totalRequests: Int = 0
    public var connectionDrops: Int = 0
    public var successfulResumes: Int = 0
    public var elapsedTimeSeconds: Double = 0.0

    public var throughputMBPerSecond: Double {
        guard elapsedTimeSeconds > 0 else { return 0.0 }
        let mb = Double(bytesRead) / (1024.0 * 1024.0)
        return mb / elapsedTimeSeconds
    }
}

/// Protocol error types.
public enum ProtocolError: Error, Equatable, Sendable {
    case connectionFailed(String)
    case connectionDropped
    case authenticationFailed
    case fileNotFound(String)
    case readOutOfRange(offset: UInt64, fileSize: UInt64)
    case maxRetriesExceeded
}
