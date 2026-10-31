import Foundation
import Testing
@testable import CoreKit

@Suite("KeychainStore Tests")
struct KeychainStoreTests {
    // MARK: - Test doubles

    private final class InMemoryKeychain: KeychainProtocol, @unchecked Sendable {
        enum Operation: Hashable {
            case read
            case write
            case delete
            case removeAll
        }

        private let lock = NSLock()
        private var storage: [String: Data] = [:]
        private var failingOperations: Set<Operation> = []

        init(storage: [String: Data] = [:]) {
            self.storage = storage
        }

        func fail(_ operation: Operation) {
            lock.lock()
            defer { lock.unlock() }
            failingOperations.insert(operation)
        }

        func storedData(for key: String) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func keys() -> Set<String> {
            lock.lock()
            defer { lock.unlock() }
            return Set(storage.keys)
        }

        func data(for key: String) throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            if failingOperations.contains(.read) {
                throw KeychainError.unexpectedStatus(-1)
            }
            return storage[key]
        }

        func set(_ data: Data, for key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            if failingOperations.contains(.write) {
                throw KeychainError.unexpectedStatus(-2)
            }
            storage[key] = data
        }

        func remove(for key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            if failingOperations.contains(.delete) {
                throw KeychainError.unexpectedStatus(-3)
            }
            storage.removeValue(forKey: key)
        }

        func removeAll() throws {
            lock.lock()
            defer { lock.unlock() }
            if failingOperations.contains(.removeAll) {
                throw KeychainError.unexpectedStatus(-4)
            }
            storage.removeAll()
        }
    }

    private struct Credentials: Codable, Equatable {
        let username: String
        let token: String
        let expiresAt: Date
    }

    // MARK: - Data

    @Test("Raw data round-trips through the store")
    func dataRoundTrip() throws {
        let keychain = InMemoryKeychain()
        let payload = Data([0x00, 0x01, 0xFE, 0xFF])

        try keychain.set(payload, for: "binary")
        let loaded = try keychain.data(for: "binary")

        #expect(loaded == payload)
    }

    @Test("Reading an unknown key returns nil")
    func unknownKeyReturnsNil() throws {
        let keychain = InMemoryKeychain()

        #expect(try keychain.data(for: "missing") == nil)
        #expect(try keychain.string(for: "missing") == nil)
        #expect(try keychain.value(Credentials.self, for: "missing") == nil)
    }

    // MARK: - Strings

    @Test("String values round-trip through the store")
    func stringRoundTrip() throws {
        let keychain = InMemoryKeychain()

        try keychain.set("s3cret-token", for: "token")

        #expect(try keychain.string(for: "token") == "s3cret-token")
    }

    @Test("Invalid UTF-8 surfaces as a decoding error")
    func invalidUTF8Throws() throws {
        let keychain = InMemoryKeychain(storage: ["token": Data([0xFF, 0xFE])])

        #expect(throws: KeychainError.decodingFailed) {
            _ = try keychain.string(for: "token")
        }
    }

    // MARK: - Codable

    @Test("Codable values round-trip through the store")
    func codableRoundTrip() throws {
        let keychain = InMemoryKeychain()
        let credentials = Credentials(
            username: "alex",
            token: "abc123",
            expiresAt: Date(timeIntervalSince1970: 1_000_000)
        )

        try keychain.set(credentials, for: "credentials")
        let loaded = try keychain.value(Credentials.self, for: "credentials")

        #expect(loaded == credentials)
    }

    @Test("Corrupt Codable payloads surface as a decoding error")
    func corruptCodableThrows() throws {
        let keychain = InMemoryKeychain(storage: ["credentials": Data("not json".utf8)])

        #expect(throws: KeychainError.decodingFailed) {
            _ = try keychain.value(Credentials.self, for: "credentials")
        }
    }

    // MARK: - Updates and deletion

    @Test("Setting an existing key updates the stored value")
    func setUpdatesExistingValue() throws {
        let keychain = InMemoryKeychain()

        try keychain.set("initial", for: "token")
        try keychain.set("updated", for: "token")

        #expect(try keychain.string(for: "token") == "updated")
        #expect(keychain.keys() == ["token"])
    }

    @Test("Removing a key deletes only that value")
    func removeDeletesValue() throws {
        let keychain = InMemoryKeychain()
        try keychain.set("a", for: "first")
        try keychain.set("b", for: "second")

        try keychain.remove(for: "first")

        #expect(try keychain.string(for: "first") == nil)
        #expect(try keychain.string(for: "second") == "b")
    }

    @Test("Removing an unknown key is a no-op")
    func removeUnknownKeyIsNoOp() throws {
        let keychain = InMemoryKeychain()

        try keychain.remove(for: "missing")

        #expect(keychain.keys().isEmpty)
    }

    @Test("removeAll clears every stored value")
    func removeAllClearsStore() throws {
        let keychain = InMemoryKeychain()
        try keychain.set("a", for: "first")
        try keychain.set("b", for: "second")

        try keychain.removeAll()

        #expect(keychain.keys().isEmpty)
    }

    // MARK: - Error propagation

    @Test("Read failures propagate from the backing store")
    func readFailurePropagates() {
        let keychain = InMemoryKeychain()
        keychain.fail(.read)

        #expect(throws: KeychainError.unexpectedStatus(-1)) {
            _ = try keychain.data(for: "token")
        }
    }

    @Test("Write failures propagate from the backing store")
    func writeFailurePropagates() {
        let keychain = InMemoryKeychain()
        keychain.fail(.write)

        #expect(throws: KeychainError.unexpectedStatus(-2)) {
            try keychain.set("value", for: "token")
        }
    }

    @Test("Delete failures propagate from the backing store")
    func deleteFailurePropagates() {
        let keychain = InMemoryKeychain()
        keychain.fail(.delete)

        #expect(throws: KeychainError.unexpectedStatus(-3)) {
            try keychain.remove(for: "token")
        }
    }

    @Test("removeAll failures propagate from the backing store")
    func removeAllFailurePropagates() {
        let keychain = InMemoryKeychain()
        keychain.fail(.removeAll)

        #expect(throws: KeychainError.unexpectedStatus(-4)) {
            try keychain.removeAll()
        }
    }

    // MARK: - Sensitive-data hygiene

    @Test("zeroize clears the buffer after overwriting")
    func zeroizeClearsBuffer() {
        var secret = Data("super-secret".utf8)

        KeychainStore.zeroize(&secret)

        #expect(secret.isEmpty)
    }

    @Test("zeroize leaves an already-empty buffer empty")
    func zeroizeEmptyBuffer() {
        var empty = Data()

        KeychainStore.zeroize(&empty)

        #expect(empty.isEmpty)
    }
}
