import Foundation
import Testing
import GRDB
import LibraryCore
@testable import SourceAdapters

// MARK: - Fake adapter

private final class FakeSyncAdapter: SourceAdapter, @unchecked Sendable {
    let kind: SourceAdapters.SourceKind = .http

    private let stateLock = SMBLock()
    private var storedItems: [SourceItem]
    private var storedFreshness: FreshnessInfo
    private var storedError: SourceAdapterError?
    private var storedEnumerateCount = 0

    init(
        items: [SourceItem],
        freshness: FreshnessInfo = FreshnessInfo(strategy: .none),
        error: SourceAdapterError? = nil
    ) {
        self.storedItems = items
        self.storedFreshness = freshness
        self.storedError = error
    }

    var items: [SourceItem] {
        get { stateLock.withLock { storedItems } }
        set { stateLock.withLock { storedItems = newValue } }
    }

    var freshnessInfo: FreshnessInfo {
        get { stateLock.withLock { storedFreshness } }
        set { stateLock.withLock { storedFreshness = newValue } }
    }

    var error: SourceAdapterError? {
        get { stateLock.withLock { storedError } }
        set { stateLock.withLock { storedError = newValue } }
    }

    var enumerateCount: Int {
        stateLock.withLock { storedEnumerateCount }
    }

    func connect(config: SourceConfig) async throws -> SourceSession {
        SourceSession(sourceID: config.id)
    }

    func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        let error = stateLock.withLock { () -> SourceAdapterError? in
            storedEnumerateCount += 1
            return storedError
        }
        if let error {
            throw error
        }

        let items = stateLock.withLock { storedItems }
        return AsyncThrowingStream { continuation in
            for item in items {
                continuation.yield(item)
            }
            continuation.finish()
        }
    }

    func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func freshness(session: SourceSession) async throws -> FreshnessInfo {
        stateLock.withLock { storedFreshness }
    }
}

// MARK: - Helpers

private func millisDate(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
}

private func makeSyncTarget(
    adapter: FakeSyncAdapter,
    sourceID: UUID,
    scope: LibraryScope = LibraryScope()
) -> SourceSyncTarget {
    let config = SourceConfig(
        id: sourceID,
        kind: .http,
        name: "Test Source"
    )
    return SourceSyncTarget(
        config: config,
        session: SourceSession(sourceID: sourceID),
        scope: scope,
        adapter: adapter
    )
}

private func makeItem(
    id: String = "item",
    sourceID: UUID,
    location: String,
    sizeBytes: Int64?,
    modifiedAt: Date? = nil,
    etag: String? = nil,
    container: String? = "mkv",
    durationSeconds: Double? = nil,
    providerIDs: [String: String] = [:]
) -> SourceItem {
    SourceItem(
        id: id,
        sourceID: sourceID,
        kind: .movie,
        name: (location as NSString).lastPathComponent,
        location: location,
        sizeBytes: sizeBytes,
        modifiedAt: modifiedAt,
        etag: etag,
        container: container,
        durationSeconds: durationSeconds,
        providerIDs: providerIDs
    )
}

private func makeDatabase() throws
    -> (MediaDatabase, MediaDatabaseReader, MediaDatabaseWriter) {
    let database = try MediaDatabase.inMemory()
    return (
        database,
        MediaDatabaseReader(database: database),
        MediaDatabaseWriter(database: database)
    )
}

// MARK: - Tests

@Suite("SourceSyncCoordinator Tests", .serialized)
struct SourceSyncCoordinatorTests {
    @Test("A moved file keeps its file_id and match")
    func renamePreservesFileID() async throws {
        let (_, reader, writer) = try makeDatabase()
        let sourceID = UUID()
        let sourceKey = sourceID.uuidString
        try writer.saveSource(
            SourceRecord(
                sourceId: sourceKey,
                kind: .smb,
                name: "NAS",
                configRef: "nas"
            )
        )
        try writer.database.write { db in
            try MovieRecord(tmdbId: 27_205, title: "Inception").insert(db)
        }
        try writer.saveMediaFiles([
            MediaFileRecord(
                fileId: "file-1",
                sourceId: sourceKey,
                path: "smb://nas/Old/Movie.mkv",
                uri: "smb://nas/Old/Movie.mkv",
                container: "mkv",
                sizeBytes: 4_000,
                mtime: 1_000,
                durationMs: 90_000,
                matchState: .matched,
                matchedMovie: 27_205,
                matchProvenance: .filename
            )
        ])

        let adapter = FakeSyncAdapter(
            items: [
                makeItem(
                    sourceID: sourceID,
                    location: "smb://nas/New/Movie.mkv",
                    sizeBytes: 4_000,
                    container: "mkv",
                    durationSeconds: 90
                )
            ]
        )
        let coordinator = SourceSyncCoordinator(
            reader: reader,
            writer: writer
        )
        let result = await coordinator.sync(
            target: makeSyncTarget(adapter: adapter, sourceID: sourceID)
        )

        #expect(result.renames.count == 1)
        #expect(result.renames.first?.fileID == "file-1")
        #expect(result.addedFileIDs.isEmpty)

        let files = try reader.fetchFiles(sourceId: sourceKey)
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.fileId == "file-1")
        #expect(file.path == "smb://nas/New/Movie.mkv")
        #expect(file.matchedMovie == 27_205)
        #expect(file.matchState == .matched)
        #expect(file.sizeBytes == 4_000)
    }

    @Test("Incremental sync only writes files whose mtime or size changed")
    func incrementalMTime() async throws {
        let (_, reader, writer) = try makeDatabase()
        let sourceID = UUID()
        let sourceKey = sourceID.uuidString
        try writer.saveSource(
            SourceRecord(
                sourceId: sourceKey,
                kind: .smb,
                name: "NAS",
                configRef: "nas"
            )
        )
        try writer.saveMediaFiles([
            MediaFileRecord(
                fileId: "unchanged",
                sourceId: sourceKey,
                path: "smb://nas/unchanged.mkv",
                uri: "smb://nas/unchanged.mkv",
                sizeBytes: 100,
                mtime: 1_000
            ),
            MediaFileRecord(
                fileId: "changed",
                sourceId: sourceKey,
                path: "smb://nas/changed.mkv",
                uri: "smb://nas/changed.mkv",
                sizeBytes: 200,
                mtime: 2_000
            )
        ])

        let adapter = FakeSyncAdapter(
            items: [
                makeItem(
                    id: "unchanged",
                    sourceID: sourceID,
                    location: "smb://nas/unchanged.mkv",
                    sizeBytes: 100,
                    modifiedAt: millisDate(1_000)
                ),
                makeItem(
                    id: "changed",
                    sourceID: sourceID,
                    location: "smb://nas/changed.mkv",
                    sizeBytes: 250,
                    modifiedAt: millisDate(3_000)
                )
            ]
        )
        let coordinator = SourceSyncCoordinator(
            reader: reader,
            writer: writer
        )
        let result = await coordinator.sync(
            target: makeSyncTarget(adapter: adapter, sourceID: sourceID)
        )

        #expect(result.skippedFileIDs == ["unchanged"])
        #expect(result.updatedFileIDs == ["changed"])
        #expect(result.addedFileIDs.isEmpty)

        let changed = try #require(
            try reader.fetchFiles(sourceId: sourceKey)
                .first { $0.fileId == "changed" }
        )
        #expect(changed.sizeBytes == 250)
        #expect(changed.mtime == 3_000)
    }

    @Test("Per-file ETags skip unchanged items and rewrite changed ones")
    func incrementalETag() async throws {
        let (_, reader, writer) = try makeDatabase()
        let sourceID = UUID()
        let sourceKey = sourceID.uuidString
        let location = "https://example.com/Movie.mkv"

        let adapter = FakeSyncAdapter(items: [])
        adapter.items = [
            makeItem(
                id: "movie",
                sourceID: sourceID,
                location: location,
                sizeBytes: 500,
                etag: "v1"
            )
        ]
        let coordinator = SourceSyncCoordinator(
            reader: reader,
            writer: writer
        )
        let target = makeSyncTarget(adapter: adapter, sourceID: sourceID)

        let first = await coordinator.sync(target: target)
        #expect(first.addedFileIDs.count == 1)

        let second = await coordinator.sync(target: target)
        #expect(second.addedFileIDs.isEmpty)
        #expect(second.updatedFileIDs.isEmpty)
        #expect(second.skippedFileIDs.count == 1)

        adapter.items = [
            makeItem(
                id: "movie",
                sourceID: sourceID,
                location: location,
                sizeBytes: 500,
                etag: "v2"
            )
        ]
        let third = await coordinator.sync(target: target)
        #expect(third.updatedFileIDs.count == 1)
        #expect(third.skippedFileIDs.isEmpty)

        let files = try reader.fetchFiles(sourceId: sourceKey)
        #expect(files.count == 1)
    }

    @Test("A not-modified freshness check skips enumeration")
    func freshnessSkipsEnumeration() async throws {
        let (_, reader, writer) = try makeDatabase()
        let sourceID = UUID()
        let sourceKey = sourceID.uuidString
        try writer.saveSource(
            SourceRecord(
                sourceId: sourceKey,
                kind: .plex,
                name: "Plex",
                configRef: "plex",
                etag: "etag-1"
            )
        )

        let adapter = FakeSyncAdapter(
            items: [
                makeItem(
                    sourceID: sourceID,
                    location: "https://plex/Movie.mkv",
                    sizeBytes: 10
                )
            ],
            freshness: FreshnessInfo(
                strategy: .etag,
                token: "etag-1",
                hasChanges: false
            )
        )
        let coordinator = SourceSyncCoordinator(
            reader: reader,
            writer: writer
        )
        let target = makeSyncTarget(adapter: adapter, sourceID: sourceID)

        let result = await coordinator.sync(target: target)
        #expect(result.enumerated == false)
        #expect(result.hasChanges == false)
        #expect(adapter.enumerateCount == 0)

        let source = try #require(
            try reader.fetchSource(sourceId: sourceKey)
        )
        #expect(source.etag == "etag-1")
        #expect(source.status == .ok)

        let forced = await coordinator.sync(target: target, force: true)
        #expect(forced.enumerated == true)
        #expect(adapter.enumerateCount == 1)
    }

    @Test("Different files surface as added and missing, not renames")
    func addedAndMissing() async throws {
        let (_, reader, writer) = try makeDatabase()
        let sourceID = UUID()
        let sourceKey = sourceID.uuidString
        try writer.saveSource(
            SourceRecord(
                sourceId: sourceKey,
                kind: .smb,
                name: "NAS",
                configRef: "nas"
            )
        )
        try writer.saveMediaFiles([
            MediaFileRecord(
                fileId: "old",
                sourceId: sourceKey,
                path: "smb://nas/old.mkv",
                uri: "smb://nas/old.mkv",
                container: "mkv",
                sizeBytes: 100,
                durationMs: 60_000
            )
        ])

        let adapter = FakeSyncAdapter(
            items: [
                makeItem(
                    sourceID: sourceID,
                    location: "smb://nas/new.mkv",
                    sizeBytes: 9_999,
                    container: "mkv",
                    durationSeconds: 60
                )
            ]
        )
        let coordinator = SourceSyncCoordinator(
            reader: reader,
            writer: writer
        )
        let result = await coordinator.sync(
            target: makeSyncTarget(adapter: adapter, sourceID: sourceID)
        )

        #expect(result.renames.isEmpty)
        #expect(result.addedFileIDs.count == 1)
        #expect(result.missing.map(\.fileID) == ["old"])
    }

    @Test("Tied rename candidates are reported as ambiguous")
    func ambiguousRename() async throws {
        let (_, reader, writer) = try makeDatabase()
        let sourceID = UUID()
        let sourceKey = sourceID.uuidString
        try writer.saveSource(
            SourceRecord(
                sourceId: sourceKey,
                kind: .smb,
                name: "NAS",
                configRef: "nas"
            )
        )
        try writer.saveMediaFiles([
            MediaFileRecord(
                fileId: "a",
                sourceId: sourceKey,
                path: "smb://nas/A/movie.mkv",
                uri: "smb://nas/A/movie.mkv",
                container: "mkv",
                sizeBytes: 4_000,
                durationMs: 90_000
            ),
            MediaFileRecord(
                fileId: "b",
                sourceId: sourceKey,
                path: "smb://nas/B/movie.mkv",
                uri: "smb://nas/B/movie.mkv",
                container: "mkv",
                sizeBytes: 4_000,
                durationMs: 90_000
            )
        ])

        let adapter = FakeSyncAdapter(
            items: [
                makeItem(
                    sourceID: sourceID,
                    location: "smb://nas/C/movie.mkv",
                    sizeBytes: 4_000,
                    container: "mkv",
                    durationSeconds: 90
                )
            ]
        )
        let coordinator = SourceSyncCoordinator(
            reader: reader,
            writer: writer
        )
        let result = await coordinator.sync(
            target: makeSyncTarget(adapter: adapter, sourceID: sourceID)
        )

        #expect(result.renames.isEmpty)
        #expect(result.ambiguous.count == 1)
        #expect(result.ambiguous.first?.candidates.count == 2)
        #expect(result.addedFileIDs.count == 1)
        #expect(result.missing.count == 2)
    }

    @Test("A webhook forces a registered source to re-enumerate")
    func webhookForcesSync() async throws {
        let (_, reader, writer) = try makeDatabase()
        let sourceID = UUID()
        let adapter = FakeSyncAdapter(
            items: [
                makeItem(
                    sourceID: sourceID,
                    location: "https://example.com/movie.mkv",
                    sizeBytes: 42
                )
            ],
            freshness: FreshnessInfo(
                strategy: .etag,
                token: "same",
                hasChanges: false
            )
        )
        let coordinator = SourceSyncCoordinator(
            reader: reader,
            writer: writer
        )
        let target = makeSyncTarget(adapter: adapter, sourceID: sourceID)
        await coordinator.register(target)

        #expect(await coordinator.registeredSourceIDs == [sourceID])
        let result = await coordinator.handleWebhook(sourceID: sourceID)
        #expect(result?.enumerated == true)
        #expect(result?.addedFileIDs.count == 1)
        #expect(adapter.enumerateCount == 1)

        await coordinator.unregister(sourceID: sourceID)
        #expect(await coordinator.registeredSourceIDs.isEmpty)
    }

    @Test("An authentication failure marks the source as needing sign-in")
    func authFailureUpdatesStatus() async throws {
        let (_, reader, writer) = try makeDatabase()
        let sourceID = UUID()
        let sourceKey = sourceID.uuidString
        let adapter = FakeSyncAdapter(
            items: [],
            error: .unauthorized
        )
        let coordinator = SourceSyncCoordinator(
            reader: reader,
            writer: writer
        )
        let result = await coordinator.sync(
            target: makeSyncTarget(adapter: adapter, sourceID: sourceID)
        )

        #expect(result.error != nil)
        let source = try #require(
            try reader.fetchSource(sourceId: sourceKey)
        )
        #expect(source.status == .authFailed)
        #expect(source.lastError != nil)
    }
}
