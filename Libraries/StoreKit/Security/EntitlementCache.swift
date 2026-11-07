import Foundation
import Security

/// A clock seam so entitlement expiry can be tested deterministically.
public protocol EntitlementClock: Sendable {
    var now: Date { get }
}

/// The production clock.
public struct SystemEntitlementClock: EntitlementClock, Sendable {
    public init() {}
    public var now: Date { Date() }
}

/// A fixed clock for tests and previews.
public struct StaticEntitlementClock: EntitlementClock, Sendable {
    public var now: Date

    public init(now: Date) {
        self.now = now
    }
}

/// Storage behind the entitlement cache.
///
/// The Keychain implementation never leaves the device. Tests use an
/// in-memory store.
public protocol EntitlementStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func clear() throws
}

/// Keychain-backed storage for the cached entitlement (BIZ-4).
///
/// The cache holds dates and product identifiers only. It never contains a
/// receipt, JWS payload, Apple ID, or App Store credential.
public final class KeychainEntitlementStore: EntitlementStore, Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(
        service: String = "com.playitright.storekit",
        account: String = "pro-entitlement",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainEntitlementError.unexpectedStatus(errSecInternalError)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainEntitlementError.unexpectedStatus(status)
        }
    }

    public func write(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var insert = baseQuery
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainEntitlementError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainEntitlementError.unexpectedStatus(updateStatus)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainEntitlementError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

public enum KeychainEntitlementError: Error, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
}

/// A thread-safe in-memory store, useful for tests, previews, and a future
/// non-persistent debug build.
public final class InMemoryEntitlementStore: EntitlementStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    public init(data: Data? = nil) {
        self.data = data
    }

    public func read() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        data = nil
    }
}

/// Offline-ready entitlement cache with expiry validation (BIZ-4).
///
/// A cached subscription is honored until its expiration date. During a
/// StoreKit billing grace period it stays active for up to ``gracePeriod``
/// after expiry, matching Apple's documented maximum. Lifetime purchases stay
/// active offline indefinitely. Revoked purchases are never honored.
public struct EntitlementCache: Sendable {
    /// Apple's maximum subscription grace period (16 days).
    public static let gracePeriod: TimeInterval = 16 * 24 * 60 * 60

    private let store: any EntitlementStore
    private let clock: any EntitlementClock
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        store: any EntitlementStore = KeychainEntitlementStore(),
        clock: any EntitlementClock = SystemEntitlementClock()
    ) {
        self.store = store
        self.clock = clock
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Persists the latest entitlement seen from StoreKit.
    public func save(_ entitlement: ProEntitlement) throws {
        let data = try encoder.encode(entitlement)
        try store.write(data)
    }

    /// Loads the cached entitlement and normalizes it against the clock and
    /// expiry date.
    ///
    /// Returns `nil` when nothing is cached. An expired subscription returns
    /// a value with `isActive == false` so the UI can display its last known
    /// state; a revoked purchase is dropped entirely.
    public func load() -> ProEntitlement? {
        guard let data = try? store.read(),
              let cached = try? decoder.decode(ProEntitlement.self, from: data) else {
            return nil
        }
        return Self.validated(cached, now: clock.now)
    }

    /// Removes the cached entitlement. Used when the account changes.
    public func clear() throws {
        try store.clear()
    }

    /// Applies expiry and grace-period rules to a cached value.
    public static func validated(
        _ entitlement: ProEntitlement,
        now: Date,
        gracePeriod: TimeInterval = EntitlementCache.gracePeriod
    ) -> ProEntitlement? {
        guard !entitlement.isRevoked else {
            return nil
        }

        var result = entitlement

        guard let expiration = entitlement.expirationDate else {
            // Lifetime purchases never expire.
            result.isActive = entitlement.isActive
            if entitlement.source == .lifetime {
                result.isActive = true
            }
            return result
        }

        if now < expiration {
            result.isActive = true
            if result.source == .none {
                result.source = .subscription
            }
            return result
        }

        if entitlement.isInGracePeriod,
           now < expiration.addingTimeInterval(gracePeriod) {
            result.isActive = true
            result.source = .gracePeriod
            return result
        }

        result.isActive = false
        result.source = .none
        return result
    }
}
