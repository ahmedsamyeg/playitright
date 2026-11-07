import Foundation
import Synchronization
import Testing
@testable import SyncKit
@preconcurrency import CloudKit

// MARK: - In-memory database

/// Mutex-protected in-memory CloudKit stand-in. `CKRecord` is a reference
/// type, so tests only need identity-level storage.
private final class InMemoryCloudKitDatabase: CloudKitDatabase, @unchecked Sendable {
    private struct State {
        var zones: [CKRecordZone.ID: CKRecordZone] = [:]
        var records: [CKRecord.ID: CKRecord] = [:]
        var deleted: [CKRecord.ID] = []
    }

    private let state = Mutex(State())

    func save(zone: CKRecordZone) async throws -> CKRecordZone {
        state.withLock { state in
            state.zones[zone.zoneID] = zone
            return zone
        }
    }

    func save(record: CKRecord) async throws -> CKRecord {
        state.withLock { state in
            state.records[record.recordID] = record
            return record
        }
    }

    func fetchRecord(id: CKRecord.ID) async throws -> CKRecord? {
        state.withLock { $0.records[id] }
    }

    func fetchRecords(
        zoneID: CKRecordZone.ID,
        recordType: String
    ) async throws -> [CKRecord] {
        state.withLock { state in
            state.records.values
                .filter {
                    $0.recordID.zoneID == zoneID
                        && $0.recordType == recordType
                }
                .sorted { $0.recordID.recordName < $1.recordID.recordName }
        }
    }

    func deleteRecord(id: CKRecord.ID) async throws {
        state.withLock { state in
            state.records.removeValue(forKey: id)
            state.deleted.append(id)
        }
    }

    func savedZoneIDs() -> [CKRecordZone.ID] {
        state.withLock { Array($0.zones.keys) }
    }

    func deletedRecordIDs() -> [CKRecord.ID] {
        state.withLock { $0.deleted }
    }
}

// MARK: - Fixtures

private func sourceHandle(
    id: String = "source-1"
) -> SyncSourceHandle {
    SyncSourceHandle(kind: .plex, id: id)
}

private func canonicalReference(
    _ id: String = "tmdb:1396"
) -> SyncMediaReference {
    SyncMediaReference(canonicalID: id)
}

private func unmatchedReference(
    id: String = "file-42"
) -> SyncMediaReference {
    SyncMediaReference(
        sourceHandle: sourceHandle(),
        fileStableID: id
    )
}

private func metadata(sequence: Int64 = 7) -> SyncRecordMetadata {
    SyncRecordMetadata(
        clientModTimestamp: 1_700_000_000_000,
        clientSequence: sequence
    )
}

private func watchState() -> SyncWatchStateRecord {
    SyncWatchStateRecord(
        entityKind: .episode,
        entityRef: "tmdb:1396:s1e5",
        account: "account-a",
        positionMs: 120_000,
        durationMs: 2_700_000,
        watched: false,
        lastWatchedAt: 1_699_999_000_000,
        resumeAt: 119_000,
        trackChoices: ["audio": "eng", "subtitle": "off"],
        updatedAt: 1_700_000_000_000,
        metadata: metadata()
    )
}

private func userRating() -> SyncUserRatingRecord {
    SyncUserRatingRecord(
        entityKind: .movie,
        entityRef: "550",
        account: "account-a",
        rating: 9,
        updatedAt: 1_700_000_000_000,
        metadata: metadata(sequence: 3)
    )
}

private func matchOverride() -> SyncMatchOverrideRecord {
    SyncMatchOverrideRecord(
        entityKind: .movie,
        entityRef: "550",
        account: "account-a",
        chosenProvider: "tmdb",
        providerID: "550",
        manualFields: ["title": "Fight Club", "year": "1999"],
        updatedAt: 1_700_000_000_000,
        metadata: metadata(sequence: 4)
    )
}

private func library() -> SyncLibraryRecord {
    SyncLibraryRecord(
        id: "library-1",
        name: "Movies",
        sourceRefs: [sourceHandle()],
        visibility: "visible",
        order: 1,
        filters: #"{"genre":"Drama"}"#,
        updatedAt: 1_700_000_000_000,
        metadata: metadata(sequence: 5)
    )
}

private func collection() -> SyncCollectionRecord {
    SyncCollectionRecord(
        id: "collection-1",
        name: "Best of 2024",
        order: 2,
        members: [canonicalReference(), unmatchedReference()],
        updatedAt: 1_700_000_000_000,
        metadata: metadata(sequence: 6)
    )
}

private func playlist() -> SyncPlaylistRecord {
    SyncPlaylistRecord(
        id: "playlist-1",
        name: "Sunday",
        order: 3,
        shuffle: true,
        loop: false,
        members: [canonicalReference("tmdb:100")],
        updatedAt: 1_700_000_000_000,
        metadata: metadata(sequence: 8)
    )
}

private func pin() -> SyncPinRecord {
    SyncPinRecord(
        entityKind: .show,
        entityRef: "tmdb:1396",
        order: 1,
        updatedAt: 1_700_000_000_000,
        metadata: metadata(sequence: 9)
    )
}

private func preferences() -> SyncPreferencesRecord {
    SyncPreferencesRecord(
        values: [
            "subtitleStyle": "large-yellow",
            "qualityBias": "quality"
        ],
        updatedAt: 1_700_000_000_000,
        metadata: metadata(sequence: 10)
    )
}

private func makeManager() -> (CloudKitZoneManager, InMemoryCloudKitDatabase) {
    let database = InMemoryCloudKitDatabase()
    return (CloudKitZoneManager(database: database), database)
}

// MARK: - Tests

@Suite("CloudKitZoneManager Tests")
struct CloudKitZoneManagerTests {
    @Test("A custom zone is created once and its id is stable")
    func zoneCreation() async throws {
        let (manager, database) = makeManager()

        let first = try await manager.ensureZone()
        let second = try await manager.ensureZone()

        #expect(first == manager.zoneID)
        #expect(second == first)
        #expect(first.zoneName == CloudKitZoneManager.defaultZoneName)
        let savedZones = database.savedZoneIDs()
        #expect(savedZones == [first])
    }

    @Test("watchState round-trips through CKRecord")
    func watchStateRoundTrip() async throws {
        let (manager, _) = makeManager()
        let original = watchState()

        let saved = try await manager.save(original)
        #expect(saved == original)

        let cloudRecord = try original.makeCloudRecord(in: manager.zoneID)
        #expect(cloudRecord.recordType == "watchState")
        #expect(
            cloudRecord.recordID.recordName
                == SyncWatchStateRecord(cloudRecord: cloudRecord)?
                    .cloudRecordName
        )

        let fetched = try #require(
            try await manager.fetch(
                SyncWatchStateRecord.self,
                recordName: original.cloudRecordName
            )
        )
        #expect(fetched == original)
        #expect(fetched.positionMs == 120_000)
        #expect(fetched.trackChoices?["audio"] == "eng")
        #expect(fetched.metadata.clientSequence == 7)
    }

    @Test("userRating, matchOverride, and pin round-trip")
    func scalarRecordsRoundTrip() async throws {
        let (manager, _) = makeManager()

        let rating = userRating()
        let override = matchOverride()
        let pinned = pin()

        let savedRating = try await manager.save(rating)
        let savedOverride = try await manager.save(override)
        let savedPin = try await manager.save(pinned)
        #expect(savedRating == rating)
        #expect(savedOverride == override)
        #expect(savedPin == pinned)

        let fetchedRating = try #require(
            try await manager.fetch(rating)
        )
        #expect(fetchedRating.rating == 9)

        let fetchedOverride = try #require(
            try await manager.fetch(override)
        )
        #expect(fetchedOverride.chosenProvider == "tmdb")
        #expect(fetchedOverride.manualFields["title"] == "Fight Club")
        #expect(fetchedOverride.providerID == "550")

        let fetchedPin = try #require(try await manager.fetch(pinned))
        #expect(fetchedPin.entityKind == .show)
        #expect(fetchedPin.order == 1)
    }

    @Test("Library, collection, playlist, and prefs round-trip")
    func organizationRecordsRoundTrip() async throws {
        let (manager, _) = makeManager()

        let lib = library()
        let col = collection()
        let list = playlist()
        let prefs = preferences()

        let savedLibrary = try await manager.save(lib)
        let savedCollection = try await manager.save(col)
        let savedPlaylist = try await manager.save(list)
        let savedPrefs = try await manager.save(prefs)
        #expect(savedLibrary == lib)
        #expect(savedCollection == col)
        #expect(savedPlaylist == list)
        #expect(savedPrefs == prefs)

        let fetchedLibrary = try #require(try await manager.fetch(lib))
        #expect(fetchedLibrary.sourceRefs == [sourceHandle()])
        #expect(fetchedLibrary.filters == #"{"genre":"Drama"}"#)

        let fetchedCollection = try #require(try await manager.fetch(col))
        #expect(fetchedCollection.members.count == 2)
        #expect(fetchedCollection.members[0].canonicalID == "tmdb:1396")
        #expect(fetchedCollection.members[1].fileStableID == "file-42")

        let fetchedPlaylist = try #require(try await manager.fetch(list))
        #expect(fetchedPlaylist.shuffle)
        #expect(!fetchedPlaylist.loop)
        #expect(fetchedPlaylist.members.first?.canonicalID == "tmdb:100")

        let fetchedPrefs = try #require(try await manager.fetch(prefs))
        #expect(fetchedPrefs.values["qualityBias"] == "quality")
    }

    @Test("fetchAll returns every record of a type")
    func fetchAllRecords() async throws {
        let (manager, _) = makeManager()
        let first = watchState()
        var second = watchState()
        second.entityRef = "tmdb:1396:s1e6"
        second.positionMs = 0

        _ = try await manager.save(first)
        _ = try await manager.save(second)

        let all = try await manager.fetchAll(SyncWatchStateRecord.self)
        #expect(all.count == 2)
        #expect(Set(all.map(\.entityRef)) == [
            "tmdb:1396:s1e5",
            "tmdb:1396:s1e6"
        ])
    }

    @Test("Deleting a record removes it from the zone")
    func deleteRecord() async throws {
        let (manager, database) = makeManager()
        let value = pin()
        _ = try await manager.save(value)

        try await manager.delete(value)

        let fetched = try await manager.fetch(value)
        #expect(fetched == nil)
        let deleted = database.deletedRecordIDs()
        #expect(
            deleted == [
                CKRecord.ID(
                    recordName: value.cloudRecordName,
                    zoneID: manager.zoneID
                )
            ]
        )
    }

    @Test("Sensitive field names are rejected before a save")
    func forbiddenFieldsAreRejected() async throws {
        let (manager, database) = makeManager()

        for field in [
            "filePath",
            "local_path",
            "accessToken",
            "credentials",
            "artworkRef",
            "providerMetadata",
            "serverURL"
        ] {
            let record = CKRecord(
                recordType: "watchState",
                recordID: CKRecord.ID(
                    recordName: "bad-\(field)",
                    zoneID: manager.zoneID
                )
            )
            record[field] = "value"

            do {
                _ = try await manager.save(cloudRecord: record)
                Issue.record("Expected \(field) to be rejected.")
            } catch let error as SyncBoundaryError {
                #expect(error == .forbiddenField(field))
            }
        }

        let stored = try await database.fetchRecords(
            zoneID: manager.zoneID,
            recordType: "watchState"
        )
        #expect(stored.isEmpty)
    }

    @Test("Path-like media references and values are rejected")
    func pathsAreRejected() throws {
        let badHandle = SyncSourceHandle(
            kind: .smb,
            id: "/Volumes/Movies"
        )
        #expect(
            throws: SyncBoundaryError.forbiddenValue(
                field: "sourceHandle.id",
                reason: "identifiers must not contain path separators"
            )
        ) {
            try badHandle.validateForSync()
        }

        let urlHandle = SyncSourceHandle(
            kind: .webdav,
            id: "https://example.com/share"
        )
        #expect(
            throws: SyncBoundaryError.forbiddenValue(
                field: "sourceHandle.id",
                reason: "identifiers must not contain URLs"
            )
        ) {
            try urlHandle.validateForSync()
        }

        #expect(throws: SyncBoundaryError.self) {
            try SyncMediaReference(
                sourceHandle: badHandle,
                fileStableID: "abc"
            ).validateForSync()
        }

        let record = CKRecord(
            recordType: "watchState",
            recordID: CKRecord.ID(recordName: "bad-path")
        )
        record["entityRef"] = "/Users/samy/Movies/movie.mkv"
        #expect(throws: SyncBoundaryError.self) {
            try SyncBoundary.validate(record: record)
        }

        record["entityRef"] = "file:///Users/samy/movie.mkv"
        #expect(throws: SyncBoundaryError.self) {
            try SyncBoundary.validate(record: record)
        }
    }

    @Test("Boundary validation catches forbidden names and values")
    func boundaryValidation() throws {
        #expect(
            SyncBoundary.isForbidden(fieldName: "localFilePath")
        )
        #expect(
            SyncBoundary.isForbidden(fieldName: "refreshToken")
        )
        #expect(
            !SyncBoundary.isForbidden(fieldName: "canonicalID")
        )
        #expect(
            !SyncBoundary.isForbidden(fieldName: "sourceRefs")
        )

        #expect(throws: SyncBoundaryError.self) {
            try SyncBoundary.validate(
                fieldNames: ["name", "file_path"]
            )
        }

        #expect(throws: SyncBoundaryError.self) {
            try SyncBoundary.validateValue(
                "Bearer abc123",
                field: "account"
            )
        }
    }

    @Test("Record names are stable and distinguish reference forms")
    func stableRecordNames() {
        let first = watchState()
        let second = watchState()
        #expect(first.cloudRecordName == second.cloudRecordName)
        #expect(first.cloudRecordName.hasPrefix("watchState."))

        var otherEpisode = watchState()
        otherEpisode.entityRef = "tmdb:1396:s1e6"
        #expect(otherEpisode.cloudRecordName != first.cloudRecordName)

        let canonical = canonicalReference()
        let unmatched = unmatchedReference()
        #expect(canonical.stableKey != unmatched.stableKey)
        #expect(canonical.stableKey == canonicalReference().stableKey)
        #expect(canonical.isResolvable)
        #expect(unmatched.isResolvable)
        #expect(!SyncMediaReference().isResolvable)
    }

    @Test("Raw records outside the manager's zone are rejected")
    func foreignZoneRejected() async throws {
        let (manager, _) = makeManager()
        let foreignZone = CKRecordZone.ID(
            zoneName: "other",
            ownerName: "someone"
        )
        let record = CKRecord(
            recordType: "pin",
            recordID: CKRecord.ID(
                recordName: "pin-1",
                zoneID: foreignZone
            )
        )
        record["entityKind"] = "movie"

        do {
            _ = try await manager.save(cloudRecord: record)
            Issue.record("Expected a foreign-zone record to be rejected.")
        } catch let error as SyncBoundaryError {
            guard case .malformedRecord = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("Malformed stored records surface as a typed error")
    func malformedStoredRecord() async throws {
        let (manager, database) = makeManager()
        let record = CKRecord(
            recordType: SyncWatchStateRecord.cloudRecordType,
            recordID: CKRecord.ID(
                recordName: "broken",
                zoneID: manager.zoneID
            )
        )
        record["entityKind"] = "movie"
        _ = try await database.save(record: record)

        do {
            _ = try await manager.fetch(
                SyncWatchStateRecord.self,
                recordName: "broken"
            )
            Issue.record("Expected an unreadable record to throw.")
        } catch let error as SyncBoundaryError {
            guard case .malformedRecord = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }
}
