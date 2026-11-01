import Foundation

/// A stream of items produced by ``SourceAdapter/enumerate(session:scope:)``.
public typealias ItemStream = AsyncThrowingStream<SourceItem, Error>

/// A watch-state update sent to a source.
public struct SourceWatchState: Codable, Sendable, Equatable {
    /// Playback position in seconds.
    public var position: Double

    /// Item duration in seconds, when known.
    public var duration: Double?

    /// Whether the user has finished the item.
    public var isWatched: Bool

    /// When watch state last changed.
    public var lastWatchedAt: Date

    /// Preferred audio track id/language, when the user chose one.
    public var audioTrack: String?

    /// Preferred subtitle track id/language, `"off"`, or `nil` for default.
    public var subtitleTrack: String?

    public init(
        position: Double,
        duration: Double? = nil,
        isWatched: Bool = false,
        lastWatchedAt: Date = Date(),
        audioTrack: String? = nil,
        subtitleTrack: String? = nil
    ) {
        self.position = max(0, position)
        self.duration = duration
        self.isWatched = isWatched
        self.lastWatchedAt = lastWatchedAt
        self.audioTrack = audioTrack
        self.subtitleTrack = subtitleTrack
    }
}

/// How a source detects changes.
public enum FreshnessStrategy: String, Codable, Sendable, CaseIterable {
    case webhook
    case push
    case etag
    case modificationTime = "mtime"
    case none
}

/// Freshness state returned by ``SourceAdapter/freshness(session:)``.
public struct FreshnessInfo: Codable, Sendable, Equatable {
    public var strategy: FreshnessStrategy

    /// ETag or cursor used for the next conditional check.
    public var token: String?

    /// Last modification time reported by the source.
    public var lastModified: Date?

    /// When this check ran.
    public var checkedAt: Date

    /// Whether the adapter saw new or changed items.
    public var hasChanges: Bool

    /// Hint for when the next poll is useful, in seconds.
    public var nextCheckAfter: TimeInterval?

    public init(
        strategy: FreshnessStrategy,
        token: String? = nil,
        lastModified: Date? = nil,
        checkedAt: Date = Date(),
        hasChanges: Bool = false,
        nextCheckAfter: TimeInterval? = nil
    ) {
        self.strategy = strategy
        self.token = token
        self.lastModified = lastModified
        self.checkedAt = checkedAt
        self.hasChanges = hasChanges
        self.nextCheckAfter = nextCheckAfter
    }
}

/// Structured source failures, including the auth cases required by SRC-3.
public enum SourceAdapterError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration(String)
    case unauthorized
    case reauthenticationRequired
    case twoFactorRequired
    case hostUnreachable(String)
    case notFound(String)
    case rangeNotSatisfiable(ByteRange, size: Int64?)
    case unsupported(String)
    case transport(String)
    case protocolViolation(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid source configuration: \(message)"
        case .unauthorized:
            return "The source rejected the credentials."
        case .reauthenticationRequired:
            return "The source requires you to sign in again."
        case .twoFactorRequired:
            return "The source requires two-factor authentication."
        case .hostUnreachable(let host):
            return "Could not reach the source host '\(host)'."
        case .notFound(let item):
            return "The source item '\(item)' was not found."
        case .rangeNotSatisfiable(let range, let size):
            let sizeDescription = size.map { "\($0) bytes" } ?? "an unknown size"
            return "Range \(range.httpHeaderValue) is outside \(sizeDescription)."
        case .unsupported(let feature):
            return "This source does not support \(feature)."
        case .transport(let message):
            return "Source transport failed: \(message)"
        case .protocolViolation(let message):
            return "The source violated its protocol: \(message)"
        case .cancelled:
            return "The source request was cancelled."
        }
    }
}

/// The contract every source adapter implements.
///
/// Adapters are the only code that understands a vendor protocol (SRC-1).
/// They must be `Sendable`; library and playback code depend on this protocol
/// only.
public protocol SourceAdapter: Sendable {
    /// The source family this adapter handles.
    var kind: SourceKind { get }

    /// Authenticates and discovers source capabilities.
    func connect(config: SourceConfig) async throws -> SourceSession

    /// Enumerates items in a library scope.
    func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream

    /// Reads item bytes, honoring a byte range when one is supplied (SRC-2).
    func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error>

    /// Best-effort watch-state write (SRC-6).
    func pushWatchState(
        session: SourceSession,
        item: SourceItem,
        state: SourceWatchState
    ) async throws

    /// Reports the source's freshness state.
    func freshness(session: SourceSession) async throws -> FreshnessInfo

    /// Releases any connection resources.
    func disconnect(session: SourceSession) async
}

public extension SourceAdapter {
    func pushWatchState(
        session: SourceSession,
        item: SourceItem,
        state: SourceWatchState
    ) async throws {
        throw SourceAdapterError.unsupported("watch-state writes")
    }

    func freshness(session: SourceSession) async throws -> FreshnessInfo {
        FreshnessInfo(strategy: .none)
    }

    func disconnect(session: SourceSession) async {}
}
