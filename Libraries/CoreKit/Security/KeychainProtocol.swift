import Foundation

/// Abstraction over secure credential storage.
///
/// Production code uses `KeychainStore`. Tests and previews should use an
/// in-memory implementation so they never touch the host Keychain.
public protocol KeychainProtocol: Sendable {
    /// Returns the stored data for `key`, or `nil` if the key is not present.
    func data(for key: String) throws -> Data?

    /// Stores `data` for `key`, replacing any existing value.
    func set(_ data: Data, for key: String) throws

    /// Removes the value stored for `key`. Removing a missing key is a no-op.
    func remove(for key: String) throws

    /// Removes every value owned by this store's service namespace.
    func removeAll() throws
}

// MARK: - Typed convenience accessors

extension KeychainProtocol {
    /// Reads a UTF-8 string value for `key`.
    ///
    /// - Throws: `KeychainError.decodingFailed` when the stored bytes are not
    ///   valid UTF-8.
    public func string(for key: String) throws -> String? {
        guard let data = try data(for: key) else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return string
    }

    /// Stores a UTF-8 string value for `key`.
    public func set(_ string: String, for key: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try set(data, for: key)
    }

    /// Decodes a Codable value previously stored for `key`.
    public func value<T: Decodable>(
        _ type: T.Type,
        for key: String,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T? {
        guard let data = try data(for: key) else {
            return nil
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw KeychainError.decodingFailed
        }
    }

    /// Encodes and stores a Codable value for `key`.
    ///
    /// Encoding failures surface as `KeychainError.encodingFailed`; storage
    /// errors from the underlying store pass through unchanged.
    public func set<T: Encodable>(
        _ value: T,
        for key: String,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw KeychainError.encodingFailed
        }
        try set(data, for: key)
    }
}

/// Errors surfaced by Keychain operations.
public enum KeychainError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A Security framework operation failed with the given status.
    case unexpectedStatus(OSStatus)

    /// A value could not be encoded before storage.
    case encodingFailed

    /// A stored value could not be decoded into the requested type.
    case decodingFailed

    public var description: String {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed with OSStatus \(status)."
        case .encodingFailed:
            return "The value could not be encoded for Keychain storage."
        case .decodingFailed:
            return "The Keychain value could not be decoded."
        }
    }
}
