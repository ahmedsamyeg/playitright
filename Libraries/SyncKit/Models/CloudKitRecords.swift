import Foundation
@preconcurrency import CloudKit

// MARK: - Sync-safe value types

/// The entity kinds that may travel through CloudKit.
///
/// Provider-scraped rows themselves never sync; only these references to the
/// user's own state do (doc 07 §1.1, doc 11 §3.3).
public enum SyncEntityKind: String, Codable, Sendable, CaseIterable, Equatable {
    case movie
    case show
    case season
    case episode
    case person
}

/// A source family stored as a *handle*, never a credential or a raw URL.
public enum SyncSourceKind: String, Codable, Sendable, CaseIterable, Equatable {
    case plex
    case jellyfin
    case emby
    case smb
    case nfs
    case webdav
    case ftp
    case ftps
    case sftp
    case http
    case upnp
    case googleDrive = "gdrive"
    case dropbox
    case oneDrive = "onedrive"
    case box
    case local
}

/// An opaque source handle: a kind plus the source's stable id.
///
/// The id is deliberately opaque. Endpoints, host names, share paths, and
/// credentials must remain in the per-device Keychain/database.
public struct SyncSourceHandle: Codable, Sendable, Equatable, Hashable {
    public var kind: SyncSourceKind
    public var id: String

    public init(kind: SyncSourceKind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// Validates that the handle does not smuggle a path or URL into sync.
    public func validateForSync() throws {
        try SyncBoundary.validateOpaqueIdentifier(id, field: "sourceHandle.id")
    }
}

/// A reference to a media item that can be resolved on another device.
///
/// Matched media uses the canonical provider-independent id (doc 11). Unmatched
/// media uses the source handle plus the source's stable file id. Raw file paths
/// are never part of this type.
public struct SyncMediaReference: Codable, Sendable, Equatable, Hashable {
    /// Canonical media id, when the item is matched.
    public var canonicalID: String?

    /// Source handle for an unmatched item.
    public var sourceHandle: SyncSourceHandle?

    /// Stable per-source file id for an unmatched item.
    public var fileStableID: String?

    public init(
        canonicalID: String? = nil,
        sourceHandle: SyncSourceHandle? = nil,
        fileStableID: String? = nil
    ) {
        self.canonicalID = canonicalID
        self.sourceHandle = sourceHandle
        self.fileStableID = fileStableID
    }

    /// Whether this reference can be resolved.
    public var isResolvable: Bool {
        if let canonicalID, !canonicalID.isEmpty {
            return true
        }
        return sourceHandle != nil && !(fileStableID ?? "").isEmpty
    }

    /// Validates the reference against the never-sync boundary.
    public func validateForSync() throws {
        if let canonicalID {
            try SyncBoundary.validateOpaqueIdentifier(
                canonicalID,
                field: "mediaReference.canonicalID"
            )
        }
        try sourceHandle?.validateForSync()
        if let fileStableID {
            try SyncBoundary.validateOpaqueIdentifier(
                fileStableID,
                field: "mediaReference.fileStableID"
            )
        }
        guard isResolvable else {
            throw SyncBoundaryError.invalidReference(
                "A media reference needs a canonical id or a source handle + file id."
            )
        }
    }

    /// Stable key used in CloudKit record names.
    public var stableKey: String {
        if let canonicalID, !canonicalID.isEmpty {
            return "c-\(canonicalID)"
        }
        if let sourceHandle, let fileStableID, !fileStableID.isEmpty {
            return "f-\(sourceHandle.kind.rawValue)-\(sourceHandle.id)-\(fileStableID)"
        }
        return "invalid"
    }
}

/// Per-record sync bookkeeping (doc 07 §1.2).
public struct SyncRecordMetadata: Codable, Sendable, Equatable {
    /// Last local modification time in milliseconds since the epoch.
    public var clientModTimestamp: Int64

    /// Monotonically increasing client sequence number.
    public var clientSequence: Int64

    public init(clientModTimestamp: Int64, clientSequence: Int64) {
        self.clientModTimestamp = clientModTimestamp
        self.clientSequence = clientSequence
    }

    public static func now(sequence: Int64, date: Date = Date()) -> Self {
        Self(
            clientModTimestamp: Int64(date.timeIntervalSince1970 * 1_000),
            clientSequence: sequence
        )
    }
}

// MARK: - Never-sync boundary

/// Errors raised when a CloudKit value would violate the sync boundary.
public enum SyncBoundaryError: Error, Equatable, CustomStringConvertible, Sendable {
    /// A field name is reserved for data that must stay on-device.
    case forbiddenField(String)

    /// A value looks like a path, URL, token, or other non-portable data.
    case forbiddenValue(field: String, reason: String)

    /// A media reference cannot be resolved on another device.
    case invalidReference(String)

    /// A CloudKit record is malformed or missing required fields.
    case malformedRecord(String)

    public var description: String {
        switch self {
        case .forbiddenField(let field):
            return "The field '\(field)' is outside the sync boundary."
        case .forbiddenValue(let field, let reason):
            return "The field '\(field)' is outside the sync boundary: \(reason)"
        case .invalidReference(let message):
            return "Invalid sync media reference: \(message)"
        case .malformedRecord(let message):
            return "Malformed CloudKit record: \(message)"
        }
    }
}

/// Enforces doc 07 §1.1 and doc 11 §3.3.
public enum SyncBoundary {
    /// Field names that must never appear in a CloudKit record.
    public static let forbiddenFieldNames: Set<String> = [
        "path",
        "filepath",
        "file_path",
        "localpath",
        "local_path",
        "rawpath",
        "raw_path",
        "url",
        "endpoint",
        "serverurl",
        "server_url",
        "streamurl",
        "stream_url",
        "token",
        "accesstoken",
        "access_token",
        "refreshtoken",
        "refresh_token",
        "password",
        "credential",
        "credentials",
        "apikey",
        "api_key",
        "secret",
        "cookie",
        "cookies",
        "artwork",
        "artworkref",
        "artwork_ref",
        "diagnostics",
        "providerpayload",
        "provider_payload",
        "providerdata",
        "provider_data",
        "providermetadata",
        "provider_metadata",
        "useragent",
        "user_agent"
    ]

    /// Returns true when `fieldName` is reserved for on-device data.
    public static func isForbidden(fieldName: String) -> Bool {
        let normalized = fieldName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if forbiddenFieldNames.contains(normalized) {
            return true
        }
        // Catch common `foo_path`, `fileURL`, etc. spellings while leaving
        // harmless names such as `sourceHandle` and `canonicalID` alone.
        return normalized.hasSuffix("_path")
            || normalized.hasSuffix("path")
            || normalized.hasSuffix("_url")
            || normalized.hasSuffix("url")
            || normalized.hasSuffix("_token")
            || normalized.hasSuffix("token")
            || normalized.hasSuffix("_secret")
    }

    /// Validates a list of prospective CloudKit keys.
    public static func validate(fieldNames: some Sequence<String>) throws {
        for field in fieldNames where isForbidden(fieldName: field) {
            throw SyncBoundaryError.forbiddenField(field)
        }
    }

    /// Validates an already-built CloudKit record.
    public static func validate(record: CKRecord) throws {
        try validate(fieldNames: record.allKeys())
        for key in record.allKeys() {
            if let string = record[key] as? String {
                try validateValue(string, field: key)
            }
        }
    }

    /// Validates an opaque identifier such as an entity ref, canonical id, or
    /// source/file id. It may contain provider punctuation (`:`), but it may
    /// not look like a filesystem path or a URL.
    public static func validateOpaqueIdentifier(
        _ value: String,
        field: String
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SyncBoundaryError.forbiddenValue(
                field: field,
                reason: "identifiers must not be empty"
            )
        }
        if trimmed.lowercased().contains("://") {
            throw SyncBoundaryError.forbiddenValue(
                field: field,
                reason: "identifiers must not contain URLs"
            )
        }
        if trimmed.contains("/") || trimmed.contains("\\") {
            throw SyncBoundaryError.forbiddenValue(
                field: field,
                reason: "identifiers must not contain path separators"
            )
        }
        if trimmed.contains("..") || trimmed.hasPrefix("~") {
            throw SyncBoundaryError.forbiddenValue(
                field: field,
                reason: "identifiers must not contain path components"
            )
        }
    }

    /// Validates a string value that is about to be written to CloudKit.
    public static func validateValue(_ value: String, field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if lowercased.hasPrefix("file://") {
            throw SyncBoundaryError.forbiddenValue(
                field: field,
                reason: "file URLs never sync"
            )
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            throw SyncBoundaryError.forbiddenValue(
                field: field,
                reason: "absolute file paths never sync"
            )
        }
        if trimmed.contains("\\") {
            throw SyncBoundaryError.forbiddenValue(
                field: field,
                reason: "Windows file paths never sync"
            )
        }
        if lowercased.hasPrefix("bearer ") || lowercased.hasPrefix("basic ") {
            throw SyncBoundaryError.forbiddenValue(
                field: field,
                reason: "credentials never sync"
            )
        }
    }
}

// MARK: - Field encoding

/// A portable CloudKit scalar. Complex values are JSON-encoded strings so the
/// schema stays small and remains inspectable in the CloudKit dashboard.
public enum SyncField: Sendable, Equatable, Codable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case data(Data)

    func apply(to record: CKRecord, key: String) {
        switch self {
        case .string(let value):
            record[key] = value
        case .int(let value):
            record[key] = NSNumber(value: value)
        case .double(let value):
            record[key] = NSNumber(value: value)
        case .bool(let value):
            record[key] = NSNumber(value: value)
        case .data(let value):
            record[key] = value
        }
    }
}

enum SyncJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SyncBoundaryError.malformedRecord("Could not encode JSON.")
        }
        return string
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        from string: String?
    ) throws -> T? {
        guard let string, !string.isEmpty else {
            return nil
        }
        guard let data = string.data(using: .utf8) else {
            throw SyncBoundaryError.malformedRecord("JSON was not UTF-8.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension CKRecord {
    func syncString(_ key: String) -> String? {
        self[key] as? String
    }

    func syncInt64(_ key: String) -> Int64? {
        (self[key] as? NSNumber)?.int64Value
    }

    func syncInt(_ key: String) -> Int? {
        (self[key] as? NSNumber)?.intValue
    }

    func syncDouble(_ key: String) -> Double? {
        (self[key] as? NSNumber)?.doubleValue
    }

    func syncBool(_ key: String) -> Bool? {
        (self[key] as? NSNumber)?.boolValue
    }

    func syncData(_ key: String) -> Data? {
        self[key] as? Data
    }

    func requireString(_ key: String) throws -> String {
        guard let value = syncString(key) else {
            throw SyncBoundaryError.malformedRecord("Missing string field '\(key)'.")
        }
        return value
    }

    func requireInt64(_ key: String) throws -> Int64 {
        guard let value = syncInt64(key) else {
            throw SyncBoundaryError.malformedRecord("Missing integer field '\(key)'.")
        }
        return value
    }
}

/// Stable record-name construction.
///
/// CloudKit record names use dots between type and identity components and
/// base64url for arbitrary text, so two different ids can never collide.
public enum SyncRecordName {
    public static func make(
        recordType: String,
        components: [String]
    ) -> String {
        ([recordType] + components.map(encode)).joined(separator: ".")
    }

    static func encode(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Record protocol

/// A value that can be stored in the PlayItRight CloudKit zone.
public protocol SyncCloudRecord: Sendable, Equatable {
    /// CloudKit record type.
    static var cloudRecordType: String { get }

    /// Stable record name inside the custom zone.
    var cloudRecordName: String { get }

    /// Portable fields, already stripped of anything outside the sync boundary.
    func syncFields() throws -> [String: SyncField]

    /// Builds a value from a CloudKit record.
    init?(cloudRecord: CKRecord)
}

extension SyncCloudRecord {
    /// Validates every field name and scalar value against the sync boundary.
    public func validateForSync() throws {
        let fields = try syncFields()
        try SyncBoundary.validate(fieldNames: fields.keys)
        for (key, field) in fields {
            switch field {
            case .string(let value):
                try SyncBoundary.validateValue(value, field: key)
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) {
                    try SyncBoundary.validateValue(text, field: key)
                }
            case .int, .double, .bool:
                break
            }
        }
    }

    /// Builds the CloudKit record after enforcing the sync boundary.
    public func makeCloudRecord(in zoneID: CKRecordZone.ID) throws -> CKRecord {
        try validateForSync()
        let recordID = CKRecord.ID(
            recordName: cloudRecordName,
            zoneID: zoneID
        )
        let record = CKRecord(
            recordType: Self.cloudRecordType,
            recordID: recordID
        )
        for (key, field) in try syncFields() {
            field.apply(to: record, key: key)
        }
        return record
    }
}

// MARK: - watchState

/// The hot per-item record (doc 07 §1.1). High write frequency is handled by
/// the sync engine's batching; this type stays small.
public struct SyncWatchStateRecord: SyncCloudRecord {
    public static let cloudRecordType = "watchState"

    public var entityKind: SyncEntityKind
    public var entityRef: String
    public var account: String
    public var positionMs: Int64
    public var durationMs: Int64?
    public var watched: Bool
    public var lastWatchedAt: Int64?
    public var resumeAt: Int64?
    public var trackChoices: [String: String]?
    public var updatedAt: Int64
    public var metadata: SyncRecordMetadata

    public init(
        entityKind: SyncEntityKind,
        entityRef: String,
        account: String,
        positionMs: Int64 = 0,
        durationMs: Int64? = nil,
        watched: Bool = false,
        lastWatchedAt: Int64? = nil,
        resumeAt: Int64? = nil,
        trackChoices: [String: String]? = nil,
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        metadata: SyncRecordMetadata = .now(sequence: 0)
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.account = account
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.watched = watched
        self.lastWatchedAt = lastWatchedAt
        self.resumeAt = resumeAt
        self.trackChoices = trackChoices
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    public var cloudRecordName: String {
        SyncRecordName.make(
            recordType: Self.cloudRecordType,
            components: [account, entityKind.rawValue, entityRef]
        )
    }

    public func syncFields() throws -> [String: SyncField] {
        var fields: [String: SyncField] = [
            "entityKind": .string(entityKind.rawValue),
            "entityRef": .string(entityRef),
            "account": .string(account),
            "positionMs": .int(positionMs),
            "watched": .bool(watched),
            "updatedAt": .int(updatedAt),
            "clientModTimestamp": .int(metadata.clientModTimestamp),
            "clientSequence": .int(metadata.clientSequence)
        ]
        if let durationMs {
            fields["durationMs"] = .int(durationMs)
        }
        if let lastWatchedAt {
            fields["lastWatchedAt"] = .int(lastWatchedAt)
        }
        if let resumeAt {
            fields["resumeAt"] = .int(resumeAt)
        }
        if let trackChoices {
            fields["trackChoices"] = .string(try SyncJSON.encode(trackChoices))
        }
        return fields
    }

    public init?(cloudRecord: CKRecord) {
        guard let kindRaw = cloudRecord.syncString("entityKind"),
              let kind = SyncEntityKind(rawValue: kindRaw),
              let entityRef = cloudRecord.syncString("entityRef"),
              let account = cloudRecord.syncString("account"),
              let positionMs = cloudRecord.syncInt64("positionMs"),
              let watched = cloudRecord.syncBool("watched"),
              let updatedAt = cloudRecord.syncInt64("updatedAt"),
              let clientModTimestamp = cloudRecord.syncInt64(
                  "clientModTimestamp"
              ),
              let clientSequence = cloudRecord.syncInt64("clientSequence") else {
            return nil
        }
        self.init(
            entityKind: kind,
            entityRef: entityRef,
            account: account,
            positionMs: positionMs,
            durationMs: cloudRecord.syncInt64("durationMs"),
            watched: watched,
            lastWatchedAt: cloudRecord.syncInt64("lastWatchedAt"),
            resumeAt: cloudRecord.syncInt64("resumeAt"),
            trackChoices: try? SyncJSON.decode(
                [String: String].self,
                from: cloudRecord.syncString("trackChoices")
            ),
            updatedAt: updatedAt,
            metadata: SyncRecordMetadata(
                clientModTimestamp: clientModTimestamp,
                clientSequence: clientSequence
            )
        )
    }
}

// MARK: - userRating

/// A standalone rating record, kept separate from the high-frequency
/// watch-state record so rating edits do not rewrite playback progress.
public struct SyncUserRatingRecord: SyncCloudRecord {
    public static let cloudRecordType = "userRating"

    public var entityKind: SyncEntityKind
    public var entityRef: String
    public var account: String
    public var rating: Int
    public var updatedAt: Int64
    public var metadata: SyncRecordMetadata

    public init(
        entityKind: SyncEntityKind,
        entityRef: String,
        account: String,
        rating: Int,
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        metadata: SyncRecordMetadata = .now(sequence: 0)
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.account = account
        self.rating = rating
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    public var cloudRecordName: String {
        SyncRecordName.make(
            recordType: Self.cloudRecordType,
            components: [account, entityKind.rawValue, entityRef]
        )
    }

    public func syncFields() throws -> [String: SyncField] {
        [
            "entityKind": .string(entityKind.rawValue),
            "entityRef": .string(entityRef),
            "account": .string(account),
            "rating": .int(Int64(rating)),
            "updatedAt": .int(updatedAt),
            "clientModTimestamp": .int(metadata.clientModTimestamp),
            "clientSequence": .int(metadata.clientSequence)
        ]
    }

    public init?(cloudRecord: CKRecord) {
        guard let kindRaw = cloudRecord.syncString("entityKind"),
              let kind = SyncEntityKind(rawValue: kindRaw),
              let entityRef = cloudRecord.syncString("entityRef"),
              let account = cloudRecord.syncString("account"),
              let rating = cloudRecord.syncInt("rating"),
              let updatedAt = cloudRecord.syncInt64("updatedAt"),
              let clientModTimestamp = cloudRecord.syncInt64(
                  "clientModTimestamp"
              ),
              let clientSequence = cloudRecord.syncInt64("clientSequence") else {
            return nil
        }
        self.init(
            entityKind: kind,
            entityRef: entityRef,
            account: account,
            rating: rating,
            updatedAt: updatedAt,
            metadata: SyncRecordMetadata(
                clientModTimestamp: clientModTimestamp,
                clientSequence: clientSequence
            )
        )
    }
}

// MARK: - matchOverride

/// A user's manual re-match. It carries the chosen provider id and any manual
/// fields, but never the provider's scraped payload.
public struct SyncMatchOverrideRecord: SyncCloudRecord {
    public static let cloudRecordType = "matchOverride"

    public var entityKind: SyncEntityKind
    public var entityRef: String
    public var account: String
    public var chosenProvider: String
    public var providerID: String
    public var manualFields: [String: String]
    public var updatedAt: Int64
    public var metadata: SyncRecordMetadata

    public init(
        entityKind: SyncEntityKind,
        entityRef: String,
        account: String,
        chosenProvider: String,
        providerID: String,
        manualFields: [String: String] = [:],
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        metadata: SyncRecordMetadata = .now(sequence: 0)
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.account = account
        self.chosenProvider = chosenProvider
        self.providerID = providerID
        self.manualFields = manualFields
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    public var cloudRecordName: String {
        SyncRecordName.make(
            recordType: Self.cloudRecordType,
            components: [account, entityKind.rawValue, entityRef]
        )
    }

    public func syncFields() throws -> [String: SyncField] {
        [
            "entityKind": .string(entityKind.rawValue),
            "entityRef": .string(entityRef),
            "account": .string(account),
            "chosenProvider": .string(chosenProvider),
            "providerID": .string(providerID),
            "manualFields": .string(try SyncJSON.encode(manualFields)),
            "updatedAt": .int(updatedAt),
            "clientModTimestamp": .int(metadata.clientModTimestamp),
            "clientSequence": .int(metadata.clientSequence)
        ]
    }

    public init?(cloudRecord: CKRecord) {
        guard let kindRaw = cloudRecord.syncString("entityKind"),
              let kind = SyncEntityKind(rawValue: kindRaw),
              let entityRef = cloudRecord.syncString("entityRef"),
              let account = cloudRecord.syncString("account"),
              let chosenProvider = cloudRecord.syncString("chosenProvider"),
              let providerID = cloudRecord.syncString("providerID"),
              let updatedAt = cloudRecord.syncInt64("updatedAt"),
              let clientModTimestamp = cloudRecord.syncInt64(
                  "clientModTimestamp"
              ),
              let clientSequence = cloudRecord.syncInt64("clientSequence") else {
            return nil
        }
        self.init(
            entityKind: kind,
            entityRef: entityRef,
            account: account,
            chosenProvider: chosenProvider,
            providerID: providerID,
            manualFields: (try? SyncJSON.decode(
                [String: String].self,
                from: cloudRecord.syncString("manualFields")
            )) ?? [:],
            updatedAt: updatedAt,
            metadata: SyncRecordMetadata(
                clientModTimestamp: clientModTimestamp,
                clientSequence: clientSequence
            )
        )
    }
}

// MARK: - library

/// A user library definition. Source refs are handles only.
public struct SyncLibraryRecord: SyncCloudRecord {
    public static let cloudRecordType = "library"

    public var id: String
    public var name: String
    public var sourceRefs: [SyncSourceHandle]
    public var visibility: String
    public var order: Int
    public var filters: String?
    public var updatedAt: Int64
    public var metadata: SyncRecordMetadata

    public init(
        id: String,
        name: String,
        sourceRefs: [SyncSourceHandle] = [],
        visibility: String = "visible",
        order: Int,
        filters: String? = nil,
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        metadata: SyncRecordMetadata = .now(sequence: 0)
    ) {
        self.id = id
        self.name = name
        self.sourceRefs = sourceRefs
        self.visibility = visibility
        self.order = order
        self.filters = filters
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    public var cloudRecordName: String {
        SyncRecordName.make(recordType: Self.cloudRecordType, components: [id])
    }

    public func syncFields() throws -> [String: SyncField] {
        try sourceRefs.forEach { try $0.validateForSync() }
        var fields: [String: SyncField] = [
            "id": .string(id),
            "name": .string(name),
            "sourceRefs": .string(try SyncJSON.encode(sourceRefs)),
            "visibility": .string(visibility),
            "order": .int(Int64(order)),
            "updatedAt": .int(updatedAt),
            "clientModTimestamp": .int(metadata.clientModTimestamp),
            "clientSequence": .int(metadata.clientSequence)
        ]
        if let filters {
            fields["filters"] = .string(filters)
        }
        return fields
    }

    public init?(cloudRecord: CKRecord) {
        guard let id = cloudRecord.syncString("id"),
              let name = cloudRecord.syncString("name"),
              let sourceRefsJSON = cloudRecord.syncString("sourceRefs"),
              let visibility = cloudRecord.syncString("visibility"),
              let order = cloudRecord.syncInt("order"),
              let updatedAt = cloudRecord.syncInt64("updatedAt"),
              let clientModTimestamp = cloudRecord.syncInt64(
                  "clientModTimestamp"
              ),
              let clientSequence = cloudRecord.syncInt64("clientSequence"),
              let sourceRefs = try? SyncJSON.decode(
                  [SyncSourceHandle].self,
                  from: sourceRefsJSON
              ) else {
            return nil
        }
        self.init(
            id: id,
            name: name,
            sourceRefs: sourceRefs,
            visibility: visibility,
            order: order,
            filters: cloudRecord.syncString("filters"),
            updatedAt: updatedAt,
            metadata: SyncRecordMetadata(
                clientModTimestamp: clientModTimestamp,
                clientSequence: clientSequence
            )
        )
    }
}

// MARK: - collection

public struct SyncCollectionRecord: SyncCloudRecord {
    public static let cloudRecordType = "collection"

    public var id: String
    public var name: String
    public var order: Int
    public var members: [SyncMediaReference]
    public var updatedAt: Int64
    public var metadata: SyncRecordMetadata

    public init(
        id: String,
        name: String,
        order: Int,
        members: [SyncMediaReference] = [],
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        metadata: SyncRecordMetadata = .now(sequence: 0)
    ) {
        self.id = id
        self.name = name
        self.order = order
        self.members = members
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    public var cloudRecordName: String {
        SyncRecordName.make(recordType: Self.cloudRecordType, components: [id])
    }

    public func syncFields() throws -> [String: SyncField] {
        try members.forEach { try $0.validateForSync() }
        return [
            "id": .string(id),
            "name": .string(name),
            "order": .int(Int64(order)),
            "members": .string(try SyncJSON.encode(members)),
            "updatedAt": .int(updatedAt),
            "clientModTimestamp": .int(metadata.clientModTimestamp),
            "clientSequence": .int(metadata.clientSequence)
        ]
    }

    public init?(cloudRecord: CKRecord) {
        guard let id = cloudRecord.syncString("id"),
              let name = cloudRecord.syncString("name"),
              let order = cloudRecord.syncInt("order"),
              let membersJSON = cloudRecord.syncString("members"),
              let updatedAt = cloudRecord.syncInt64("updatedAt"),
              let clientModTimestamp = cloudRecord.syncInt64(
                  "clientModTimestamp"
              ),
              let clientSequence = cloudRecord.syncInt64("clientSequence"),
              let members = try? SyncJSON.decode(
                  [SyncMediaReference].self,
                  from: membersJSON
              ) else {
            return nil
        }
        self.init(
            id: id,
            name: name,
            order: order,
            members: members,
            updatedAt: updatedAt,
            metadata: SyncRecordMetadata(
                clientModTimestamp: clientModTimestamp,
                clientSequence: clientSequence
            )
        )
    }
}

// MARK: - playlist

public struct SyncPlaylistRecord: SyncCloudRecord {
    public static let cloudRecordType = "playlist"

    public var id: String
    public var name: String
    public var order: Int
    public var shuffle: Bool
    public var loop: Bool
    public var members: [SyncMediaReference]
    public var updatedAt: Int64
    public var metadata: SyncRecordMetadata

    public init(
        id: String,
        name: String,
        order: Int,
        shuffle: Bool = false,
        loop: Bool = false,
        members: [SyncMediaReference] = [],
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        metadata: SyncRecordMetadata = .now(sequence: 0)
    ) {
        self.id = id
        self.name = name
        self.order = order
        self.shuffle = shuffle
        self.loop = loop
        self.members = members
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    public var cloudRecordName: String {
        SyncRecordName.make(recordType: Self.cloudRecordType, components: [id])
    }

    public func syncFields() throws -> [String: SyncField] {
        try members.forEach { try $0.validateForSync() }
        return [
            "id": .string(id),
            "name": .string(name),
            "order": .int(Int64(order)),
            "shuffle": .bool(shuffle),
            "loop": .bool(loop),
            "members": .string(try SyncJSON.encode(members)),
            "updatedAt": .int(updatedAt),
            "clientModTimestamp": .int(metadata.clientModTimestamp),
            "clientSequence": .int(metadata.clientSequence)
        ]
    }

    public init?(cloudRecord: CKRecord) {
        guard let id = cloudRecord.syncString("id"),
              let name = cloudRecord.syncString("name"),
              let order = cloudRecord.syncInt("order"),
              let shuffle = cloudRecord.syncBool("shuffle"),
              let loop = cloudRecord.syncBool("loop"),
              let membersJSON = cloudRecord.syncString("members"),
              let updatedAt = cloudRecord.syncInt64("updatedAt"),
              let clientModTimestamp = cloudRecord.syncInt64(
                  "clientModTimestamp"
              ),
              let clientSequence = cloudRecord.syncInt64("clientSequence"),
              let members = try? SyncJSON.decode(
                  [SyncMediaReference].self,
                  from: membersJSON
              ) else {
            return nil
        }
        self.init(
            id: id,
            name: name,
            order: order,
            shuffle: shuffle,
            loop: loop,
            members: members,
            updatedAt: updatedAt,
            metadata: SyncRecordMetadata(
                clientModTimestamp: clientModTimestamp,
                clientSequence: clientSequence
            )
        )
    }
}

// MARK: - pin

public struct SyncPinRecord: SyncCloudRecord {
    public static let cloudRecordType = "pin"

    public var entityKind: SyncEntityKind
    public var entityRef: String
    public var order: Int
    public var updatedAt: Int64
    public var metadata: SyncRecordMetadata

    public init(
        entityKind: SyncEntityKind,
        entityRef: String,
        order: Int,
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        metadata: SyncRecordMetadata = .now(sequence: 0)
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.order = order
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    public var cloudRecordName: String {
        SyncRecordName.make(
            recordType: Self.cloudRecordType,
            components: [entityKind.rawValue, entityRef]
        )
    }

    public func syncFields() throws -> [String: SyncField] {
        [
            "entityKind": .string(entityKind.rawValue),
            "entityRef": .string(entityRef),
            "order": .int(Int64(order)),
            "updatedAt": .int(updatedAt),
            "clientModTimestamp": .int(metadata.clientModTimestamp),
            "clientSequence": .int(metadata.clientSequence)
        ]
    }

    public init?(cloudRecord: CKRecord) {
        guard let kindRaw = cloudRecord.syncString("entityKind"),
              let kind = SyncEntityKind(rawValue: kindRaw),
              let entityRef = cloudRecord.syncString("entityRef"),
              let order = cloudRecord.syncInt("order"),
              let updatedAt = cloudRecord.syncInt64("updatedAt"),
              let clientModTimestamp = cloudRecord.syncInt64(
                  "clientModTimestamp"
              ),
              let clientSequence = cloudRecord.syncInt64("clientSequence") else {
            return nil
        }
        self.init(
            entityKind: kind,
            entityRef: entityRef,
            order: order,
            updatedAt: updatedAt,
            metadata: SyncRecordMetadata(
                clientModTimestamp: clientModTimestamp,
                clientSequence: clientSequence
            )
        )
    }
}

// MARK: - prefs

/// User preferences that should follow the Apple ID. Device capability and
/// per-source credentials remain local.
public struct SyncPreferencesRecord: SyncCloudRecord {
    public static let cloudRecordType = "prefs"

    public var values: [String: String]
    public var updatedAt: Int64
    public var metadata: SyncRecordMetadata

    public init(
        values: [String: String] = [:],
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        metadata: SyncRecordMetadata = .now(sequence: 0)
    ) {
        self.values = values
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    public var cloudRecordName: String {
        SyncRecordName.make(recordType: Self.cloudRecordType, components: [])
    }

    public func syncFields() throws -> [String: SyncField] {
        for key in values.keys {
            try SyncBoundary.validate(fieldNames: [key])
        }
        return [
            "values": .string(try SyncJSON.encode(values)),
            "updatedAt": .int(updatedAt),
            "clientModTimestamp": .int(metadata.clientModTimestamp),
            "clientSequence": .int(metadata.clientSequence)
        ]
    }

    public init?(cloudRecord: CKRecord) {
        guard let valuesJSON = cloudRecord.syncString("values"),
              let updatedAt = cloudRecord.syncInt64("updatedAt"),
              let clientModTimestamp = cloudRecord.syncInt64(
                  "clientModTimestamp"
              ),
              let clientSequence = cloudRecord.syncInt64("clientSequence"),
              let values = try? SyncJSON.decode(
                  [String: String].self,
                  from: valuesJSON
              ) else {
            return nil
        }
        self.init(
            values: values,
            updatedAt: updatedAt,
            metadata: SyncRecordMetadata(
                clientModTimestamp: clientModTimestamp,
                clientSequence: clientSequence
            )
        )
    }
}
