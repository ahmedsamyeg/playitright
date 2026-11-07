import Foundation

/// A read-only disc backed by a directory on disk (`BDMV` or `VIDEO_TS`).
public struct DirectoryDiscFileSystem: DiscFileSystem, Sendable {
    public let rootURL: URL
    private let rootPath: String

    public init(rootURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: rootURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw DiscFileSystemError.notFound(rootURL.lastPathComponent)
        }
        self.rootURL = rootURL
        self.rootPath = rootURL.standardizedFileURL.path
    }

    public func entry(at path: String) throws -> DiscEntry? {
        let normalized = try Self.normalize(path)
        let url = fileURL(for: normalized)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try makeEntry(url: url, path: normalized)
    }

    public func entries(in path: String) throws -> [DiscEntry] {
        let normalized = try Self.normalize(path)
        let directoryURL = fileURL(for: normalized)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw DiscFileSystemError.notFound(normalized)
        }

        let names = try FileManager.default.contentsOfDirectory(
            atPath: directoryURL.path
        )
        return try names.map { name in
            let childPath = normalized.isEmpty ? name : normalized + "/" + name
            let childURL = directoryURL.appendingPathComponent(name)
            return try makeEntry(url: childURL, path: childPath)
        }
        .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    public func read(at path: String, range: ByteRange?) throws -> Data {
        let normalized = try Self.normalize(path)
        let url = fileURL(for: normalized)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else {
            throw DiscFileSystemError.notFound(normalized)
        }
        guard !isDirectory.boolValue else {
            throw DiscFileSystemError.isDirectory(normalized)
        }

        let source = FileDiscByteSource(url: url)
        let size = source.byteCount
        guard let clamped = (range ?? .full).clamped(to: size) else {
            throw DiscFileSystemError.rangeNotSatisfiable(
                path: normalized,
                size: size
            )
        }
        let length = clamped.length ?? (size - clamped.start)
        guard length > 0 else {
            return Data()
        }
        return try source.read(offset: clamped.start, length: Int(length))
    }

    // MARK: Helpers

    private func makeEntry(url: URL, path: String) throws -> DiscEntry {
        let values = try url.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey
            ]
        )
        return DiscEntry(
            path: path,
            name: url.lastPathComponent,
            isDirectory: values.isDirectory ?? false,
            size: Int64(values.fileSize ?? 0),
            byteOffset: nil,
            modifiedAt: values.contentModificationDate
        )
    }

    private func fileURL(for path: String) -> URL {
        guard !path.isEmpty else {
            return rootURL
        }
        var url = rootURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    /// Rejects absolute paths and parent traversal.
    static func normalize(_ path: String) throws -> String {
        let normalized = ISO9660Parser.normalize(path)
        guard !normalized.split(separator: "/").contains("..") else {
            throw DiscFileSystemError.notFound(path)
        }
        return normalized
    }
}

/// Local disc-image and disc-folder playback (SRC-17, PB-3).
///
/// The adapter mounts an `.iso`/`.img` image or a `BDMV` / `VIDEO_TS` folder
/// as a single "disc" source. Enumeration exposes one playlist item per title;
/// playback reads the title's M2TS or VOB streams through the disc
/// filesystem, honoring ranged reads so seeking works without extracting the
/// image.
public struct DiscImageAdapter: SourceAdapter, Sendable {
    public let kind: SourceKind = .local

    /// Bytes yielded per read chunk.
    public var chunkSize: Int

    public init(chunkSize: Int = 256 * 1024) {
        self.chunkSize = max(1, chunkSize)
    }

    // MARK: SourceAdapter

    public func connect(config: SourceConfig) async throws -> SourceSession {
        guard let endpoint = config.endpoint, endpoint.isFileURL else {
            throw SourceAdapterError.invalidConfiguration(
                "Disc sources require a file URL."
            )
        }
        let mounted = try MountedDisc.open(at: endpoint)
        return SourceSession(
            sourceID: config.id,
            capabilities: [.rangeRequests, .recursiveEnumeration, .directPlay],
            metadata: [
                Self.pathKey: endpoint.standardizedFileURL.path,
                Self.typeKey: mounted.type.rawValue,
                Self.volumeKey: mounted.volumeName
            ]
        )
    }

    public func enumerate(
        session: SourceSession,
        scope: LibraryScope
    ) async throws -> ItemStream {
        let mounted = try mountedDisc(for: session)
        let items = try items(for: mounted, sourceID: session.sourceID)
        return ItemStream { continuation in
            Task {
                for item in items {
                    if Task.isCancelled {
                        break
                    }
                    continuation.yield(item)
                }
                continuation.finish()
            }
        }
    }

    public func read(
        session: SourceSession,
        item: SourceItem,
        range: ByteRange?
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let mounted = try self.mountedDisc(for: session)
                    let paths = try self.streamPaths(
                        for: item,
                        mounted: mounted,
                        sourceID: session.sourceID
                    )
                    try self.stream(
                        paths: paths,
                        filesystem: mounted.filesystem,
                        range: range,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func freshness(session: SourceSession) async throws -> FreshnessInfo {
        let path = session.metadata[Self.pathKey]
        let attributes = path.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0)
        }
        return FreshnessInfo(
            strategy: .modificationTime,
            lastModified: attributes?[.modificationDate] as? Date,
            checkedAt: Date()
        )
    }

    // MARK: Mounting

    private static let pathKey = "disc.path"
    private static let typeKey = "disc.type"
    private static let volumeKey = "disc.volume"

    private func mountedDisc(for session: SourceSession) throws -> MountedDisc {
        guard let path = session.metadata[Self.pathKey] else {
            throw SourceAdapterError.invalidConfiguration(
                "The disc session is missing its image path."
            )
        }
        return try MountedDisc.open(at: URL(fileURLWithPath: path))
    }

    // MARK: Items

    private func items(
        for mounted: MountedDisc,
        sourceID: UUID
    ) throws -> [SourceItem] {
        switch mounted.type {
        case .bdmv:
            return try bdmvItems(mounted: mounted, sourceID: sourceID)
        case .videoTS:
            return try videoTSItems(mounted: mounted, sourceID: sourceID)
        case .iso:
            if (try? mounted.filesystem.entry(at: "BDMV/index.bdmv")) != nil {
                return try bdmvItems(mounted: mounted, sourceID: sourceID)
            }
            if (try? mounted.filesystem.entry(at: "VIDEO_TS/VIDEO_TS.IFO")) != nil {
                return try videoTSItems(mounted: mounted, sourceID: sourceID)
            }
            return try mediaItems(mounted: mounted, sourceID: sourceID)
        }
    }

    private func bdmvItems(
        mounted: MountedDisc,
        sourceID: UUID
    ) throws -> [SourceItem] {
        let disc = try BDMVParser(filesystem: mounted.filesystem).parse()
        let titles = disc.titles.filter { !$0.streamPaths.isEmpty }
        if !titles.isEmpty {
            return titles.map { title in
                SourceItem(
                    id: "\(sourceID.uuidString)-bdmv-title-\(title.id)",
                    sourceID: sourceID,
                    kind: .playlist,
                    name: "Title \(title.id)",
                    location: "bdmv:\(title.id)",
                    parentID: "bdmv",
                    container: "m2ts"
                )
            }
        }

        // Fall back to the stream files when the playlist table is unusable.
        let streams = (try? mounted.filesystem.entries(in: "BDMV/STREAM")) ?? []
        return streams
            .filter { !$0.isDirectory && $0.name.lowercased().hasSuffix(".m2ts") }
            .sorted { $0.path < $1.path }
            .enumerated()
            .map { offset, entry in
                SourceItem(
                    id: "\(sourceID.uuidString)-bdmv-stream-\(offset)",
                    sourceID: sourceID,
                    kind: .movie,
                    name: entry.name,
                    location: "file:\(entry.path)",
                    sizeBytes: entry.size,
                    modifiedAt: entry.modifiedAt,
                    container: "m2ts"
                )
            }
    }

    private func videoTSItems(
        mounted: MountedDisc,
        sourceID: UUID
    ) throws -> [SourceItem] {
        let titles = VideoTSTitles.groups(in: mounted.filesystem)
        if !titles.isEmpty {
            return titles.map { group in
                SourceItem(
                    id: "\(sourceID.uuidString)-video-ts-title-\(group.number)",
                    sourceID: sourceID,
                    kind: .playlist,
                    name: "Title \(group.number)",
                    location: "video-ts:\(group.number)",
                    parentID: "video-ts",
                    container: "vob"
                )
            }
        }
        return try mediaItems(mounted: mounted, sourceID: sourceID)
    }

    private func mediaItems(
        mounted: MountedDisc,
        sourceID: UUID
    ) throws -> [SourceItem] {
        let entries = try mounted.filesystem.entries(in: "")
        return entries
            .filter { !$0.isDirectory && Self.isMediaFile($0.name) }
            .sorted { $0.path < $1.path }
            .map { entry in
                SourceItem(
                    id: "\(sourceID.uuidString)-file-\(entry.path)",
                    sourceID: sourceID,
                    kind: .movie,
                    name: entry.name,
                    location: "file:\(entry.path)",
                    sizeBytes: entry.size,
                    modifiedAt: entry.modifiedAt,
                    container: (entry.name as NSString).pathExtension.lowercased()
                )
            }
    }

    private static func isMediaFile(_ name: String) -> Bool {
        let extensions: Set<String> = [
            "mkv", "mp4", "m4v", "mov", "ts", "m2ts", "mts",
            "avi", "vob", "mpg", "mpeg", "webm", "iso"
        ]
        return extensions.contains(
            (name as NSString).pathExtension.lowercased()
        )
    }

    // MARK: Reading

    private func streamPaths(
        for item: SourceItem,
        mounted: MountedDisc,
        sourceID: UUID
    ) throws -> [String] {
        if item.location.hasPrefix("file:") {
            return [String(item.location.dropFirst("file:".count))]
        }
        if item.location.hasPrefix("bdmv:") {
            guard let titleID = Int(item.location.dropFirst("bdmv:".count)) else {
                throw SourceAdapterError.notFound(item.location)
            }
            let disc = try BDMVParser(filesystem: mounted.filesystem).parse()
            guard let title = disc.titles.first(where: { $0.id == titleID }) else {
                throw SourceAdapterError.notFound(item.location)
            }
            guard !title.streamPaths.isEmpty else {
                throw SourceAdapterError.unsupported(
                    "title \(titleID) without a playlist stream"
                )
            }
            return title.streamPaths
        }
        if item.location.hasPrefix("video-ts:") {
            guard let number = Int(item.location.dropFirst("video-ts:".count)) else {
                throw SourceAdapterError.notFound(item.location)
            }
            guard let group = VideoTSTitles.groups(in: mounted.filesystem)
                .first(where: { $0.number == number }) else {
                throw SourceAdapterError.notFound(item.location)
            }
            return group.paths
        }
        throw SourceAdapterError.unsupported(
            "disc location '\(item.location)'"
        )
    }

    private func stream(
        paths: [String],
        filesystem: any DiscFileSystem,
        range: ByteRange?,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) throws {
        var sizes: [Int64] = []
        sizes.reserveCapacity(paths.count)
        for path in paths {
            guard let entry = try filesystem.entry(at: path), !entry.isDirectory else {
                throw SourceAdapterError.notFound(path)
            }
            sizes.append(max(0, entry.size))
        }

        let total = sizes.reduce(0, +)
        let requested = range ?? .full
        guard requested.start < total else {
            if total == 0, requested.start == 0 {
                return
            }
            throw SourceAdapterError.rangeNotSatisfiable(requested, size: total)
        }
        let endExclusive = min(requested.end.map { $0 + 1 } ?? total, total)
        guard endExclusive > requested.start else {
            return
        }

        var virtualOffset: Int64 = 0
        for (index, path) in paths.enumerated() {
            let size = sizes[index]
            defer { virtualOffset += size }
            guard size > 0 else {
                continue
            }
            let fileStart = virtualOffset
            let fileEnd = virtualOffset + size
            guard fileEnd > requested.start, fileStart < endExclusive else {
                continue
            }

            let localStart = max(0, requested.start - fileStart)
            let localEnd = min(size, endExclusive - fileStart)
            var cursor = localStart
            while cursor < localEnd {
                if Task.isCancelled {
                    return
                }
                let chunkEnd = min(localEnd, cursor + Int64(chunkSize)) - 1
                let chunk = try filesystem.read(
                    at: path,
                    range: try ByteRange(start: cursor, end: chunkEnd)
                )
                if !chunk.isEmpty {
                    continuation.yield(chunk)
                }
                cursor = chunkEnd + 1
            }
        }
    }
}

/// The disc mounted for one source configuration.
struct MountedDisc: Sendable {
    let type: DiscType
    let volumeName: String
    let filesystem: any DiscFileSystem

    static func open(at url: URL) throws -> MountedDisc {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else {
            throw SourceAdapterError.notFound(url.lastPathComponent)
        }

        if isDirectory.boolValue {
            let filesystem = try DirectoryDiscFileSystem(rootURL: url)
            if (try? filesystem.entry(at: "BDMV/index.bdmv")) != nil
                || (try? filesystem.entry(at: "BDMV/PLAYLIST")) != nil {
                return MountedDisc(
                    type: .bdmv,
                    volumeName: url.lastPathComponent,
                    filesystem: filesystem
                )
            }
            if (try? filesystem.entry(at: "VIDEO_TS")) != nil {
                return MountedDisc(
                    type: .videoTS,
                    volumeName: url.lastPathComponent,
                    filesystem: filesystem
                )
            }
            throw SourceAdapterError.invalidConfiguration(
                "'\(url.lastPathComponent)' is not a BDMV or VIDEO_TS folder."
            )
        }

        let parser: ISO9660Parser
        do {
            parser = try ISO9660Parser(
                source: FileDiscByteSource(url: url)
            )
        } catch {
            throw SourceAdapterError.invalidConfiguration(
                "'\(url.lastPathComponent)' is not a valid ISO 9660 image."
            )
        }
        return MountedDisc(
            type: .iso,
            volumeName: parser.volumeName.isEmpty
                ? url.deletingPathExtension().lastPathComponent
                : parser.volumeName,
            filesystem: parser
        )
    }
}

/// Groups DVD `VTS_nn_m.VOB` files into playable titles.
enum VideoTSTitles {
    struct Group: Sendable, Equatable {
        let number: Int
        let paths: [String]
    }

    static func groups(
        in filesystem: any DiscFileSystem
    ) -> [Group] {
        guard let entries = try? filesystem.entries(in: "VIDEO_TS") else {
            return []
        }

        var grouped: [Int: [(part: Int, path: String)]] = [:]
        for entry in entries where !entry.isDirectory {
            let name = entry.name.lowercased()
            guard name.hasSuffix(".vob"),
                  let number = titleNumber(from: name),
                  let part = partNumber(from: name) else {
                continue
            }
            grouped[number, default: []].append((part, entry.path))
        }

        return grouped.keys.sorted().map { number in
            Group(
                number: number,
                paths: grouped[number, default: []]
                    .sorted { $0.part < $1.part }
                    .map(\.path)
            )
        }
    }

    /// Parses `vts_01_1.vob` into `1`.
    static func titleNumber(from name: String) -> Int? {
        let parts = name.split(separator: "_")
        guard parts.count >= 3,
              parts[0] == "vts",
              let number = Int(parts[1]) else {
            return nil
        }
        return number
    }

    /// Parses `vts_01_2.vob` into `2`.
    static func partNumber(from name: String) -> Int? {
        let parts = name.split(separator: "_")
        guard parts.count >= 3 else {
            return nil
        }
        let stem = parts[2].split(separator: ".").first ?? parts[2]
        return Int(stem)
    }
}
