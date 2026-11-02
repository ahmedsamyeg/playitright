import CryptoKit
import Foundation
import LibraryCore

/// A registered source and the adapter state needed to poll it.
public struct SourceSyncTarget: Sendable {
    public var config: SourceConfig
    public var session: SourceSession
    public var scope: LibraryScope

    /// Preferred poll interval for scheduled syncs.
    public var interval: TimeInterval

    public var adapter: any SourceAdapter

    public init(
        config: SourceConfig,
        session: SourceSession,
        scope: LibraryScope = LibraryScope(),
        interval: TimeInterval = 300,
        adapter: any SourceAdapter
    ) {
        self.config = config
        self.session = session
        self.scope = scope
        self.interval = max(30, interval)
        self.adapter = adapter
    }
}

/// What one sync pass changed. This is the data behind the "What changed"
/// view (MD-12) and the source status in Settings.
public struct SourceSyncResult: Sendable, Equatable {
    public var sourceID: UUID
    public var enumerated: Bool
    public var addedFileIDs: [String]
    public var updatedFileIDs: [String]
    public var skippedFileIDs: [String]
    public var missing: [SourceFileSnapshot]
    public var renames: [RenameMatch]
    public var ambiguous: [RenameAmbiguity]
    public var etag: String?
    public var lastSyncAt: Date
    public var error: String?

    public var hasChanges: Bool {
        !addedFileIDs.isEmpty
            || !updatedFileIDs.isEmpty
            || !missing.isEmpty
            || !renames.isEmpty
    }

    public init(
        sourceID: UUID,
        enumerated: Bool = false,
        addedFileIDs: [String] = [],
        updatedFileIDs: [String] = [],
        skippedFileIDs: [String] = [],
        missing: [SourceFileSnapshot] = [],
        renames: [RenameMatch] = [],
        ambiguous: [RenameAmbiguity] = [],
        etag: String? = nil,
        lastSyncAt: Date = Date(),
        error: String? = nil
    ) {
        self.sourceID = sourceID
        self.enumerated = enumerated
        self.addedFileIDs = addedFileIDs
        self.updatedFileIDs = updatedFileIDs
        self.skippedFileIDs = skippedFileIDs
        self.missing = missing
        self.renames = renames
        self.ambiguous = ambiguous
        self.etag = etag
        self.lastSyncAt = lastSyncAt
        self.error = error
    }
}

/// Coordinates freshness checks, enumeration, rename detection, and index
/// writes for every registered source.
///
/// The coordinator is the only place that turns ``SourceItem`` values into
/// `LibraryCore` rows. It uses the adapter's freshness strategy before
/// enumerating (SRC-20), diffs files by mtime/size/ETag, and delegates renamed
/// files to ``RenameDetector`` so watch state and artwork survive a move
/// (SRC-19). Offline browsing keeps working because a failed sync leaves the
/// existing rows intact (SRC-5).
public actor SourceSyncCoordinator {
    public let reader: MediaDatabaseReader
    public let writer: MediaDatabaseWriter
    public var renameDetector: RenameDetector

    private var targets: [UUID: SourceSyncTarget] = [:]

    /// Per-file ETags seen in this process. LibraryCore stores source-level
    /// validators; this cache lets server sources skip unchanged files even
    /// when they expose no modification time.
    private var fileValidators: [String: String] = [:]

    private var scheduleTask: Task<Void, Never>?
    private let now: @Sendable () -> Date

    public init(
        reader: MediaDatabaseReader,
        writer: MediaDatabaseWriter,
        renameDetector: RenameDetector = RenameDetector(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reader = reader
        self.writer = writer
        self.renameDetector = renameDetector
        self.now = now
    }

    // MARK: - Registration

    public func register(_ target: SourceSyncTarget) {
        targets[target.config.id] = target
    }

    public func unregister(sourceID: UUID) {
        targets.removeValue(forKey: sourceID)
    }

    public var registeredSourceIDs: [UUID] {
        Array(targets.keys)
    }

    // MARK: - Manual and webhook sync

    /// The manual "Check for updates" action (SRC-20).
    public func checkForUpdates(force: Bool = false) async -> [SourceSyncResult] {
        var results: [SourceSyncResult] = []
        for id in targets.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            if let result = await sync(sourceID: id, force: force) {
                results.append(result)
            }
        }
        return results
    }

    /// A webhook or push notification asked one source to refresh now.
    @discardableResult
    public func handleWebhook(sourceID: UUID) async -> SourceSyncResult? {
        await sync(sourceID: sourceID, force: true)
    }

    @discardableResult
    public func sync(
        sourceID: UUID,
        force: Bool = false
    ) async -> SourceSyncResult? {
        guard let target = targets[sourceID] else {
            return nil
        }
        return await sync(target: target, force: force)
    }

    @discardableResult
    public func sync(
        target: SourceSyncTarget,
        force: Bool = false
    ) async -> SourceSyncResult {
        let sourceID = target.config.id
        let sourceKey = sourceID.uuidString
        let startedAt = now()

        var record: SourceRecord
        do {
            record = try loadOrCreateSource(target)
        } catch {
            return SourceSyncResult(
                sourceID: sourceID,
                lastSyncAt: startedAt,
                error: error.localizedDescription
            )
        }

        let freshness: FreshnessInfo
        do {
            freshness = try await target.adapter.freshness(
                session: target.session
            )
        } catch {
            let message = error.localizedDescription
            record.status = syncStatus(for: error)
            record.lastError = message
            record.lastSyncAt = milliseconds(startedAt)
            try? writer.saveSource(record)
            return SourceSyncResult(
                sourceID: sourceID,
                lastSyncAt: startedAt,
                error: message
            )
        }

        if !force,
           freshness.strategy != .none,
           !freshness.hasChanges {
            record.lastSyncAt = milliseconds(startedAt)
            record.etag = freshness.token ?? record.etag
            record.status = .ok
            record.lastError = nil
            try? writer.saveSource(record)
            return SourceSyncResult(
                sourceID: sourceID,
                enumerated: false,
                etag: freshness.token ?? record.etag,
                lastSyncAt: startedAt
            )
        }

        var items: [SourceItem] = []
        do {
            let scope = effectiveScope(for: target)
            let stream = try await target.adapter.enumerate(
                session: target.session,
                scope: scope
            )
            for try await item in stream {
                items.append(item)
            }
        } catch {
            let message = error.localizedDescription
            record.status = syncStatus(for: error)
            record.lastError = message
            record.lastSyncAt = milliseconds(startedAt)
            try? writer.saveSource(record)
            return SourceSyncResult(
                sourceID: sourceID,
                lastSyncAt: startedAt,
                error: message
            )
        }

        let existing: [MediaFileRecord]
        do {
            existing = try reader.fetchFiles(sourceId: sourceKey)
        } catch {
            let message = error.localizedDescription
            record.status = .unreachable
            record.lastError = message
            try? writer.saveSource(record)
            return SourceSyncResult(
                sourceID: sourceID,
                enumerated: true,
                lastSyncAt: startedAt,
                error: message
            )
        }

        var byPath: [String: MediaFileRecord] = [:]
        for file in existing {
            byPath[file.path] = file
            byPath[file.uri] = file
        }

        var addedFileIDs: [String] = []
        var updatedFileIDs: [String] = []
        var skippedFileIDs: [String] = []
        var recordsToSave: [MediaFileRecord] = []
        var usedFileIDs: Set<String> = []
        var newItems: [SourceItem] = []

        for item in items {
            if let file = byPath[item.location] {
                usedFileIDs.insert(file.fileId)

                let validatorKey = "\(sourceKey)|\(file.fileId)"
                if hasChanged(item: item, file: file, validatorKey: validatorKey) {
                    recordsToSave.append(
                        makeRecord(
                            item: item,
                            fileID: file.fileId,
                            existing: file,
                            sourceKey: sourceKey,
                            target: target
                        )
                    )
                    updatedFileIDs.append(file.fileId)
                } else {
                    skippedFileIDs.append(file.fileId)
                }

                if let etag = item.etag {
                    fileValidators[validatorKey] = etag
                }
            } else {
                newItems.append(item)
            }
        }

        let missingRecords = existing.filter {
            !usedFileIDs.contains($0.fileId)
        }
        let missingSnapshots = missingRecords.map(snapshot)

        let detection = renameDetector.detect(
            existing: missingSnapshots,
            discovered: newItems
        )

        let recordsByID = Dictionary(
            existing.map { ($0.fileId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for match in detection.matches {
            guard let old = recordsByID[match.fileID] else {
                continue
            }
            recordsToSave.append(
                makeRecord(
                    item: match.item,
                    fileID: match.fileID,
                    existing: old,
                    sourceKey: sourceKey,
                    target: target
                )
            )
            updatedFileIDs.append(match.fileID)
            usedFileIDs.insert(match.fileID)
            if let etag = match.item.etag {
                fileValidators["\(sourceKey)|\(match.fileID)"] = etag
            }
        }

        for item in detection.added {
            let fileID = stableFileID(sourceKey: sourceKey, item: item)
            recordsToSave.append(
                makeRecord(
                    item: item,
                    fileID: fileID,
                    existing: nil,
                    sourceKey: sourceKey,
                    target: target
                )
            )
            addedFileIDs.append(fileID)
            usedFileIDs.insert(fileID)
            if let etag = item.etag {
                fileValidators["\(sourceKey)|\(fileID)"] = etag
            }
        }

        do {
            try writer.saveMediaFiles(recordsToSave)

            record.lastSyncAt = milliseconds(startedAt)
            record.etag = freshness.token ?? record.etag
            record.status = .ok
            record.lastError = nil
            try writer.saveSource(record)
        } catch {
            let message = error.localizedDescription
            record.status = .unreachable
            record.lastError = message
            try? writer.saveSource(record)
            return SourceSyncResult(
                sourceID: sourceID,
                enumerated: true,
                lastSyncAt: startedAt,
                error: message
            )
        }

        let stillMissing = detection.missing.filter {
            !usedFileIDs.contains($0.fileID)
        }

        return SourceSyncResult(
            sourceID: sourceID,
            enumerated: true,
            addedFileIDs: addedFileIDs,
            updatedFileIDs: updatedFileIDs,
            skippedFileIDs: skippedFileIDs,
            missing: stillMissing,
            renames: detection.matches,
            ambiguous: detection.ambiguous,
            etag: record.etag,
            lastSyncAt: startedAt
        )
    }

    // MARK: - Scheduling

    /// Starts a polling loop. The shortest registered interval wins; manual
    /// checks and webhooks can run at any time alongside it.
    public func startScheduling(defaultInterval: TimeInterval = 300) {
        stopScheduling()
        let fallback = max(30, defaultInterval)
        scheduleTask = Task { [weak self] in
            guard let self else {
                return
            }
            while !Task.isCancelled {
                _ = await self.checkForUpdates(force: false)
                let interval = await self.shortestInterval(
                    fallback: fallback
                )
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
    }

    public func stopScheduling() {
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    private func shortestInterval(fallback: TimeInterval) -> TimeInterval {
        targets.values.map(\.interval).min() ?? fallback
    }

    // MARK: - Record mapping

    private func loadOrCreateSource(
        _ target: SourceSyncTarget
    ) throws -> SourceRecord {
        let sourceKey = target.config.id.uuidString
        if let existing = try reader.fetchSource(sourceId: sourceKey) {
            return existing
        }

        let record = SourceRecord(
            sourceId: sourceKey,
            kind: libraryKind(target.config.kind),
            name: target.config.name,
            configRef: target.config.credentialReference ?? sourceKey
        )
        try writer.saveSource(record)
        return record
    }

    private func effectiveScope(
        for target: SourceSyncTarget
    ) -> LibraryScope {
        var scope = target.scope
        if scope.includeGlobs.isEmpty {
            scope.includeGlobs = target.config.includeGlobs
        }
        if scope.excludeGlobs.isEmpty {
            scope.excludeGlobs = target.config.excludeGlobs
        }
        return scope
    }

    private func hasChanged(
        item: SourceItem,
        file: MediaFileRecord,
        validatorKey: String
    ) -> Bool {
        if let etag = item.etag,
           let known = fileValidators[validatorKey] {
            return known != etag
        }

        if let itemSize = item.sizeBytes,
           itemSize != file.sizeBytes {
            return true
        }

        if let itemMtime = item.modifiedAt.map(milliseconds),
           let fileMtime = file.mtime {
            return itemMtime != fileMtime
        }

        if item.sizeBytes == nil, file.sizeBytes != nil {
            return true
        }
        return false
    }

    private func makeRecord(
        item: SourceItem,
        fileID: String,
        existing: MediaFileRecord?,
        sourceKey: String,
        target: SourceSyncTarget
    ) -> MediaFileRecord {
        MediaFileRecord(
            fileId: fileID,
            sourceId: sourceKey,
            path: item.location,
            uri: item.location,
            container: item.container,
            sizeBytes: item.sizeBytes,
            mtime: item.modifiedAt.map(milliseconds),
            durationMs: item.durationSeconds.map {
                Int64(($0 * 1_000).rounded())
            },
            matchState: existing?.matchState ?? .unmatched,
            matchedMovie: existing?.matchedMovie,
            matchedEpisode: existing?.matchedEpisode,
            matchedShow: existing?.matchedShow,
            matchProvenance: existing?.matchProvenance,
            addedAt: existing?.addedAt
                ?? milliseconds(now())
        )
    }

    private func snapshot(_ file: MediaFileRecord) -> SourceFileSnapshot {
        SourceFileSnapshot(
            fileID: file.fileId,
            path: file.path,
            uri: file.uri,
            container: file.container,
            sizeBytes: file.sizeBytes,
            durationMs: file.durationMs,
            etag: nil,
            modifiedAt: file.mtime.map {
                Date(timeIntervalSince1970: Double($0) / 1_000)
            }
        )
    }

    private func stableFileID(
        sourceKey: String,
        item: SourceItem
    ) -> String {
        var providerIdentity = item.providerIDs
            .sorted { $0.key < $1.key }
            .map { "\($0.key.lowercased()):\($0.value)" }
            .joined(separator: "|")
        if providerIdentity.isEmpty && !item.id.isEmpty {
            providerIdentity = "source-id:\(item.id)"
        }
        if providerIdentity.isEmpty {
            providerIdentity = "path:\(item.location)"
        }

        let digest = SHA256.hash(
            data: Data("\(sourceKey)|\(providerIdentity)".utf8)
        )
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func syncStatus(for error: Error) -> SourceStatus {
        guard let sourceError = error as? SourceAdapterError else {
            return .unreachable
        }
        switch sourceError {
        case .unauthorized, .reauthenticationRequired, .twoFactorRequired:
            return .authFailed
        case .hostUnreachable, .transport, .protocolViolation:
            return .unreachable
        case .invalidConfiguration:
            return .disabled
        default:
            return .unreachable
        }
    }

    private func libraryKind(_ kind: SourceKind) -> LibraryCore.SourceKind {
        if kind == .googleDrive {
            return .gdrive
        }
        return LibraryCore.SourceKind(rawValue: kind.rawValue) ?? .local
    }
}
