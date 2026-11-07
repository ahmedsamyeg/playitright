import Foundation
@preconcurrency import CloudKit

// MARK: - Database seam

/// The subset of `CKDatabase` the zone manager needs.
///
/// Injecting this seam keeps the schema and CRUD tests independent of a signed
/// iCloud account while still exercising real `CKRecord` values.
public protocol CloudKitDatabase: Sendable {
    /// Saves a custom zone. Re-saving an existing zone is idempotent at the
    /// manager level; implementations may treat it as an upsert.
    @discardableResult
    func save(zone: CKRecordZone) async throws -> CKRecordZone

    /// Saves one record and returns the server's copy.
    func save(record: CKRecord) async throws -> CKRecord

    /// Fetches a record, returning `nil` when it does not exist.
    func fetchRecord(id: CKRecord.ID) async throws -> CKRecord?

    /// Fetches every record of one type in a zone.
    func fetchRecords(
        zoneID: CKRecordZone.ID,
        recordType: String
    ) async throws -> [CKRecord]

    /// Deletes a record by id.
    func deleteRecord(id: CKRecord.ID) async throws
}

/// `CKDatabase`-backed implementation using the user's private database.
public struct LiveCloudKitDatabase: CloudKitDatabase, @unchecked Sendable {
    public let database: CKDatabase

    public init(database: CKDatabase = CKContainer.default().privateCloudDatabase) {
        self.database = database
    }

    @discardableResult
    public func save(zone: CKRecordZone) async throws -> CKRecordZone {
        try await database.save(zone)
    }

    public func save(record: CKRecord) async throws -> CKRecord {
        try await database.save(record)
    }

    public func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    public func fetchRecords(
        zoneID: CKRecordZone.ID,
        recordType: String
    ) async throws -> [CKRecord] {
        let query = CKQuery(
            recordType: recordType,
            predicate: NSPredicate(value: true)
        )
        let (results, _) = try await database.records(
            matching: query,
            inZoneWith: zoneID
        )
        return results.compactMap { _, result in
            try? result.get()
        }
    }

    public func deleteRecord(id: CKRecord.ID) async throws {
        try await database.deleteRecord(withID: id)
    }
}

// MARK: - Zone manager

/// Creates and manages the app's custom CloudKit zone and converts sync-safe
/// domain records to and from `CKRecord` values (SYNC-1, doc 07 §1).
public struct CloudKitZoneManager: Sendable {
    /// Default custom zone name. One user zone per Apple ID.
    public static let defaultZoneName = "PlayItRight"

    public let database: any CloudKitDatabase
    public let zoneID: CKRecordZone.ID

    public init(
        database: any CloudKitDatabase,
        zoneName: String = CloudKitZoneManager.defaultZoneName,
        ownerName: String = CKCurrentUserDefaultName
    ) {
        self.database = database
        self.zoneID = CKRecordZone.ID(
            zoneName: zoneName,
            ownerName: ownerName
        )
    }

    // MARK: Zone lifecycle

    /// Creates the custom zone if needed and returns its id.
    @discardableResult
    public func ensureZone() async throws -> CKRecordZone.ID {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.save(zone: zone)
        return zoneID
    }

    // MARK: Typed CRUD

    /// Validates and saves one sync record.
    @discardableResult
    public func save<R: SyncCloudRecord>(_ value: R) async throws -> R {
        let cloudRecord = try value.makeCloudRecord(in: zoneID)
        let saved = try await database.save(record: cloudRecord)
        guard let decoded = R(cloudRecord: saved) else {
            throw SyncBoundaryError.malformedRecord(
                "The server returned an unreadable \(R.cloudRecordType) record."
            )
        }
        return decoded
    }

    /// Saves several records in order and returns the server copies.
    @discardableResult
    public func saveAll<R: SyncCloudRecord>(
        _ values: [R]
    ) async throws -> [R] {
        var saved: [R] = []
        saved.reserveCapacity(values.count)
        for value in values {
            saved.append(try await save(value))
        }
        return saved
    }

    /// Fetches one record by its stable name.
    public func fetch<R: SyncCloudRecord>(
        _ type: R.Type,
        recordName: String
    ) async throws -> R? {
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        guard let record = try await database.fetchRecord(id: id) else {
            return nil
        }
        guard let decoded = R(cloudRecord: record) else {
            throw SyncBoundaryError.malformedRecord(
                "Stored \(R.cloudRecordType) record '\(recordName)' is unreadable."
            )
        }
        return decoded
    }

    /// Fetches one record using its own stable name.
    public func fetch<R: SyncCloudRecord>(_ value: R) async throws -> R? {
        try await fetch(R.self, recordName: value.cloudRecordName)
    }

    /// Fetches every record of a type in the zone.
    public func fetchAll<R: SyncCloudRecord>(
        _ type: R.Type
    ) async throws -> [R] {
        let records = try await database.fetchRecords(
            zoneID: zoneID,
            recordType: R.cloudRecordType
        )
        return try records.map { record in
            guard let decoded = R(cloudRecord: record) else {
                throw SyncBoundaryError.malformedRecord(
                    "Stored \(R.cloudRecordType) record is unreadable."
                )
            }
            return decoded
        }
    }

    /// Deletes a value's CloudKit record.
    public func delete<R: SyncCloudRecord>(_ value: R) async throws {
        try await delete(recordName: value.cloudRecordName)
    }

    /// Deletes one record by its stable name.
    public func delete(recordName: String) async throws {
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        try await database.deleteRecord(id: id)
    }

    // MARK: Raw records

    /// Validates and saves a pre-built record.
    ///
    /// This is primarily useful for migrations and tests: it enforces the
    /// never-sync boundary even when the caller bypasses the typed models.
    @discardableResult
    public func save(cloudRecord: CKRecord) async throws -> CKRecord {
        try SyncBoundary.validate(record: cloudRecord)
        guard cloudRecord.recordID.zoneID == zoneID else {
            throw SyncBoundaryError.malformedRecord(
                "The record belongs to a different CloudKit zone."
            )
        }
        return try await database.save(record: cloudRecord)
    }

    /// Builds a record id in this manager's zone.
    public func recordID(for value: some SyncCloudRecord) -> CKRecord.ID {
        CKRecord.ID(recordName: value.cloudRecordName, zoneID: zoneID)
    }
}
