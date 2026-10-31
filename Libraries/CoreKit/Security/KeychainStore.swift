import Foundation
import Security

/// Keychain-backed implementation of `KeychainProtocol`.
///
/// Values are stored as generic-password items with
/// `kSecAttrAccessibleAfterFirstUnlock`, which keeps credentials available to
/// background refresh after the device has been unlocked once since boot.
///
/// Each store is namespaced by `service`. Use one service per feature or
/// subsystem so `removeAll()` cannot delete unrelated credentials.
public final class KeychainStore: KeychainProtocol, Sendable {
    private let service: String
    private let accessGroup: String?

    /// - Parameters:
    ///   - service: Keychain service namespace. Defaults to the app bundle id.
    ///   - accessGroup: Optional Keychain access group for shared app groups.
    public init(
        service: String = Bundle.main.bundleIdentifier ?? "com.playitright.core",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func data(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.unexpectedStatus(errSecInternalError)
            }
            return data

        case errSecItemNotFound:
            return nil

        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func set(_ data: Data, for key: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(
            baseQuery(for: key) as CFDictionary,
            attributes as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            var insert = baseQuery(for: key)
            insert.merge(attributes) { _, new in new }

            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func remove(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func removeAll() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Sensitive-data hygiene

    /// Overwrites a mutable data buffer with zeroes before releasing it.
    ///
    /// Use this for short-lived decrypted tokens. Swift strings cannot be
    /// reliably zeroed once created, so keep secrets in `Data` for as long as
    /// possible.
    public static func zeroize(_ data: inout Data) {
        data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            memset(baseAddress, 0, buffer.count)
        }
        data.removeAll(keepingCapacity: false)
    }

    // MARK: - Private

    private func baseQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
