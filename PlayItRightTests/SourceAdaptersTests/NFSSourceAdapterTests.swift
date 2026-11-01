import Foundation
import Testing
@testable import SourceAdapters

// MARK: - Fake client

private final class FakeNFSClient: NFSClient, @unchecked Sendable {
    private let stateLock = NSLock()

    /// Directory path -> entries.
    var directories: [String: [NFSEntry]] = [:]

    /// File path -> bytes.
    var files: [String: Data] = [:]

    /// Path -> metadata when it differs from the defaults.
    var stats: [String: NFSFileInfo] = [:]

    var failNextRead = false
    var staleNextRead = false

    var readRequests: [(handle: Data, offset: Int64, length: Int)] = []
    var lookupRequests: [String] = []

    private(set) var connectCount = 0
    private(set) var mountCount = 0
    private(set) var disconnectCount = 0
    private(set) var lastExport: String?

    static func handle(for path: String) -> Data {
        Data(path.utf8)
    }

    private func path(for handle: Data) -> String {
        String(decoding: handle, as: UTF8.self)
    }

    func connect() async throws {
        stateLock.withLock { connectCount += 1 }
    }

    func mount(export: String) async throws -> Data {
        stateLock.withLock {
            mountCount += 1
            lastExport = export
        }
        return Self.handle(for: "")
    }

    func listDirectory(handle: Data) async throws -> [NFSEntry] {
        let path = path(for: handle)
        guard let entries = stateLock.withLock({ directories[path] }) else {
            throw NFSError.notFound(path)
        }
        return entries
    }

    func stat(handle: Data) async throws -> NFSFileInfo {
        let path = path(for: handle)
        if let info = stateLock.withLock({ stats[path] }) {
            return info
        }
        throw NFSError.notFound(path)
    }

    func lookup(path: String) async throws -> NFSLookup {
        let normalized = path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let known = stateLock.withLock {
            lookupRequests.append(normalized)
            return directories[normalized] != nil
                || files[normalized] != nil
                || stats[normalized] != nil
                || (normalized.isEmpty && directories[""] != nil)
        }
        guard known else {
            throw NFSError.notFound(normalized)
        }

        let info = stateLock.withLock {
            stats[normalized]
                ?? NFSFileInfo(
                    size: files[normalized].map { Int64($0.count) },
                    modifiedAt: nil,
                    isDirectory: directories[normalized] != nil
                )
        }
        return NFSLookup(
            fileHandle: Self.handle(for: normalized),
            info: info
        )
    }

    func read(handle: Data, offset: Int64, length: Int) async throws -> Data {
        let path = path(for: handle)
        let failure = stateLock.withLock { () -> NFSError? in
            readRequests.append((handle, offset, length))
            if staleNextRead {
                staleNextRead = false
                return .staleHandle
            }
            if failNextRead {
                failNextRead = false
                return .transport("Simulated network drop")
            }
            return nil
        }
        if let failure {
            throw failure
        }

        guard let data = stateLock.withLock({ files[path] }) else {
            throw NFSError.notFound(path)
        }
        guard offset < Int64(data.count) else {
            return Data()
        }
        let start = Int(offset)
        let end = min(data.count, start + length)
        return data.subdata(in: start..<end)
    }

    func disconnect() async {
        stateLock.withLock { disconnectCount += 1 }
    }
}

// MARK: - Helpers

private func makeNFSAdapter(
    client: FakeNFSClient,
    configuration: NFSConfiguration = NFSConfiguration(
        reconnectBaseDelay: 0
    )
) -> NFSSourceAdapter {
    NFSSourceAdapter(
        configuration: configuration,
        clientFactory: { _, _ in client }
    )
}

private func makeNFSSession(
    _ adapter: NFSSourceAdapter,
    endpoint: String = "nfs://nas.local/media"
) async throws -> SourceSession {
    let config = SourceConfig(
        kind: .nfs,
        name: "NAS",
        endpoint: URL(string: endpoint)
    )
    return try await adapter.connect(config: config)
}

private func collectNFSItems(_ stream: ItemStream) async throws
    -> [SourceItem] {
    var items: [SourceItem] = []
    for try await item in stream {
        items.append(item)
    }
    return items
}

private func collectNFSData(
    _ stream: AsyncThrowingStream<Data, Error>
) async throws -> Data {
    var data = Data()
    for try await chunk in stream {
        data.append(chunk)
    }
    return data
}

private func nfsEntry(
    _ name: String,
    path: String,
    isDirectory: Bool,
    size: Int64? = nil,
    modifiedAt: Date? = nil
) -> NFSEntry {
    NFSEntry(
        name: name,
        fileHandle: FakeNFSClient.handle(for: path),
        isDirectory: isDirectory,
        size: size,
        modifiedAt: modifiedAt
    )
}

// MARK: - Adapter tests

@Suite("NFSSourceAdapter Tests", .serialized)
struct NFSSourceAdapterTests {
    @Test("Connect resolves ports, mounts the export, and records metadata")
    func connectHandshake() async throws {
        let client = FakeNFSClient()
        let adapter = makeNFSAdapter(client: client)
        let session = try await makeNFSSession(adapter)

        #expect(client.connectCount == 1)
        #expect(client.mountCount == 1)
        #expect(client.lastExport == "media")
        #expect(session.metadata["host"] == "nas.local")
        #expect(session.metadata["export"] == "media")
        #expect(session.metadata["rootPath"] == "")
        #expect(session.metadata["endpoint"] == "nfs://nas.local/media")
        #expect(session.capabilities.contains(.rangeRequests))
        #expect(session.capabilities.contains(.recursiveEnumeration))
        #expect(session.capabilities.contains(.modificationTimeFreshness))
    }

    @Test("Export and root path parse from the endpoint")
    func parsesTarget() throws {
        let config = SourceConfig(
            kind: .nfs,
            name: "NAS",
            endpoint: URL(
                string: "nfs://nas.local/volume1/media/Movies"
            )!
        )
        let target = try NFSTarget(config: config)

        #expect(target.host == "nas.local")
        #expect(target.export == "volume1")
        #expect(target.rootPath == "media/Movies")
        #expect(target.endpoint == "nfs://nas.local/volume1")
    }

    @Test("An export can be supplied through non-secret options")
    func parsesOptions() throws {
        let config = SourceConfig(
            kind: .nfs,
            name: "NAS",
            host: "192.168.1.10",
            options: ["export": "/volume1/media", "path": "/Movies"]
        )
        let target = try NFSTarget(config: config)

        #expect(target.host == "192.168.1.10")
        #expect(target.export == "volume1/media")
        #expect(target.rootPath == "Movies")
    }

    @Test("Directory walks map entries and apply glob filters")
    func enumerateAndFilter() async throws {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let client = FakeNFSClient()
        client.directories = [
            "": [
                nfsEntry(
                    "Movies",
                    path: "Movies",
                    isDirectory: true
                ),
                nfsEntry(
                    "readme.nfo",
                    path: "readme.nfo",
                    isDirectory: false,
                    size: 12
                )
            ],
            "Movies": [
                nfsEntry(
                    "Inception.mkv",
                    path: "Movies/Inception.mkv",
                    isDirectory: false,
                    size: 4096,
                    modifiedAt: modified
                ),
                nfsEntry(
                    "sample.mkv",
                    path: "Movies/sample.mkv",
                    isDirectory: false,
                    size: 10
                ),
                nfsEntry(
                    "Inception.nfo",
                    path: "Movies/Inception.nfo",
                    isDirectory: false,
                    size: 200
                ),
                nfsEntry(
                    "Extras",
                    path: "Movies/Extras",
                    isDirectory: true
                )
            ],
            "Movies/Extras": [
                nfsEntry(
                    "Trailer.mkv",
                    path: "Movies/Extras/Trailer.mkv",
                    isDirectory: false,
                    size: 50
                )
            ]
        ]

        let adapter = makeNFSAdapter(client: client)
        let session = try await makeNFSSession(adapter)

        let items = try await collectNFSItems(
            try await adapter.enumerate(
                session: session,
                scope: LibraryScope(
                    recursive: true,
                    excludeGlobs: ["*.nfo", "sample*"]
                )
            )
        )

        let names = Set(items.map(\.name))
        #expect(names == ["Inception.mkv", "Trailer.mkv"])

        let movie = try #require(
            items.first { $0.name == "Inception.mkv" }
        )
        #expect(movie.kind == .movie)
        #expect(movie.sizeBytes == 4096)
        #expect(movie.modifiedAt == modified)
        #expect(movie.container == "mkv")
        #expect(movie.parentID == "nfs://nas.local/media/Movies")
        #expect(
            movie.location == "nfs://nas.local/media/Movies/Inception.mkv"
        )
    }

    @Test("Non-recursive enumeration does not descend")
    func nonRecursiveEnumeration() async throws {
        let client = FakeNFSClient()
        client.directories = [
            "": [
                nfsEntry("Movies", path: "Movies", isDirectory: true),
                nfsEntry(
                    "root.mkv",
                    path: "root.mkv",
                    isDirectory: false,
                    size: 1
                )
            ],
            "Movies": [
                nfsEntry(
                    "Inception.mkv",
                    path: "Movies/Inception.mkv",
                    isDirectory: false,
                    size: 2
                )
            ]
        ]

        let adapter = makeNFSAdapter(client: client)
        let session = try await makeNFSSession(adapter)

        let items = try await collectNFSItems(
            try await adapter.enumerate(
                session: session,
                scope: LibraryScope(recursive: false)
            )
        )

        #expect(items.map(\.name) == ["root.mkv"])
    }

    @Test("Scoped enumeration resolves a subdirectory handle")
    func scopedEnumeration() async throws {
        let client = FakeNFSClient()
        client.directories = [
            "": [],
            "Movies": [
                nfsEntry(
                    "Inception.mkv",
                    path: "Movies/Inception.mkv",
                    isDirectory: false,
                    size: 4096
                )
            ]
        ]

        let adapter = makeNFSAdapter(client: client)
        let session = try await makeNFSSession(adapter)

        let items = try await collectNFSItems(
            try await adapter.enumerate(
                session: session,
                scope: LibraryScope(path: "Movies", recursive: false)
            )
        )

        #expect(items.map(\.name) == ["Inception.mkv"])
        #expect(client.lookupRequests.contains("Movies"))
    }

    @Test("Ranged reads return only the requested bytes")
    func rangedRead() async throws {
        let payload = Data((0..<1024).map { UInt8($0 & 0xFF) })
        let client = FakeNFSClient()
        client.files = ["Movies/Inception.mkv": payload]

        let adapter = makeNFSAdapter(client: client)
        let session = try await makeNFSSession(adapter)
        let location = NFSSourceAdapter.location(
            host: "nas.local",
            export: "media",
            path: "Movies/Inception.mkv"
        )
        let item = SourceItem(
            id: location,
            sourceID: session.sourceID,
            kind: .movie,
            name: "Inception.mkv",
            location: location,
            sizeBytes: Int64(payload.count)
        )

        let range = try ByteRange(start: 100, end: 199)
        let data = try await collectNFSData(
            adapter.read(session: session, item: item, range: range)
        )

        #expect(data == payload.subdata(in: 100..<200))
        #expect(client.readRequests.count == 1)
        #expect(client.readRequests[0].offset == 100)
        #expect(client.readRequests[0].length == 100)
    }

    @Test("An open-ended read stops at end of file")
    func openEndedRead() async throws {
        let payload = Data(repeating: 0xAB, count: 1024)
        let client = FakeNFSClient()
        client.files = ["Movies/Inception.mkv": payload]

        let adapter = makeNFSAdapter(client: client)
        let session = try await makeNFSSession(adapter)
        let location = NFSSourceAdapter.location(
            host: "nas.local",
            export: "media",
            path: "Movies/Inception.mkv"
        )
        let item = SourceItem(
            id: location,
            sourceID: session.sourceID,
            kind: .movie,
            name: "Inception.mkv",
            location: location,
            sizeBytes: Int64(payload.count)
        )

        let range = try ByteRange(start: 900)
        let data = try await collectNFSData(
            adapter.read(session: session, item: item, range: range)
        )

        #expect(data.count == 124)
        #expect(data == payload.subdata(in: 900..<1024))
    }

    @Test("A dropped read resumes from the current offset")
    func resumesAfterDrop() async throws {
        let payload = Data((0..<512).map { UInt8($0 & 0xFF) })
        let client = FakeNFSClient()
        client.files = ["Movies/Inception.mkv": payload]
        client.failNextRead = true

        let adapter = makeNFSAdapter(
            client: client,
            configuration: NFSConfiguration(
                maxReconnects: 2,
                reconnectBaseDelay: 0
            )
        )
        let session = try await makeNFSSession(adapter)
        let location = NFSSourceAdapter.location(
            host: "nas.local",
            export: "media",
            path: "Movies/Inception.mkv"
        )
        let item = SourceItem(
            id: location,
            sourceID: session.sourceID,
            kind: .movie,
            name: "Inception.mkv",
            location: location,
            sizeBytes: Int64(payload.count)
        )

        let data = try await collectNFSData(
            adapter.read(
                session: session,
                item: item,
                range: try ByteRange(start: 0, end: 511)
            )
        )

        #expect(data == payload)
        #expect(client.readRequests.count == 2)
        #expect(client.readRequests[0].offset == 0)
        #expect(client.readRequests[1].offset == 0)
    }

    @Test("A stale handle is re-resolved before retrying")
    func refreshesStaleHandle() async throws {
        let payload = Data((0..<256).map { UInt8($0 & 0xFF) })
        let client = FakeNFSClient()
        client.files = ["Movies/Inception.mkv": payload]
        client.staleNextRead = true

        let adapter = makeNFSAdapter(
            client: client,
            configuration: NFSConfiguration(
                maxReconnects: 2,
                reconnectBaseDelay: 0
            )
        )
        let session = try await makeNFSSession(adapter)
        let location = NFSSourceAdapter.location(
            host: "nas.local",
            export: "media",
            path: "Movies/Inception.mkv"
        )
        let item = SourceItem(
            id: location,
            sourceID: session.sourceID,
            kind: .movie,
            name: "Inception.mkv",
            location: location,
            sizeBytes: Int64(payload.count)
        )

        let data = try await collectNFSData(
            adapter.read(
                session: session,
                item: item,
                range: try ByteRange(start: 0, end: 255)
            )
        )

        #expect(data == payload)
        #expect(client.lookupRequests.contains("Movies/Inception.mkv"))
    }

    @Test("Freshness reports the root modification time")
    func freshness() async throws {
        let modified = Date(timeIntervalSince1970: 1_700_000_500)
        let client = FakeNFSClient()
        client.directories = ["": []]
        client.stats[""] = NFSFileInfo(
            size: nil,
            modifiedAt: modified,
            isDirectory: true
        )

        let adapter = makeNFSAdapter(client: client)
        let session = try await makeNFSSession(adapter)
        let info = try await adapter.freshness(session: session)

        #expect(info.strategy == .modificationTime)
        #expect(info.lastModified == modified)
    }

    @Test("Disconnect releases the session client")
    func disconnect() async throws {
        let client = FakeNFSClient()
        client.directories = ["": []]
        let adapter = makeNFSAdapter(client: client)
        let session = try await makeNFSSession(adapter)

        await adapter.disconnect(session: session)
        #expect(client.disconnectCount == 1)

        do {
            let stream = try await adapter.enumerate(
                session: session,
                scope: LibraryScope()
            )
            _ = try await collectNFSItems(stream)
            Issue.record("Expected reauthenticationRequired")
        } catch let error as SourceAdapterError {
            #expect(error == .reauthenticationRequired)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

// MARK: - XDR tests

@Suite("NFSXDR Tests")
struct NFSXDRTests {
    @Test("XDR round-trips primitives, strings, and opaque values")
    func roundTrip() throws {
        var writer = XDRWriter()
        writer.u32(0xDEAD_BEEF)
        writer.i32(-42)
        writer.u64(0x0102_0304_0506_0708)
        writer.bool(true)
        writer.string("Movies")
        writer.opaque(Data([0x01, 0x02, 0x03]))

        var reader = XDRReader(data: writer.data)
        #expect(try reader.u32() == 0xDEAD_BEEF)
        #expect(try reader.i32() == -42)
        #expect(try reader.u64() == 0x0102_0304_0506_0708)
        #expect(try reader.bool() == true)
        #expect(try reader.string() == "Movies")
        #expect(try reader.opaque() == Data([0x01, 0x02, 0x03]))
        #expect(reader.remaining == 0)
    }

    @Test("XDR rejects truncated values and oversized opacity")
    func boundsChecking() throws {
        var reader = XDRReader(data: Data([0x00, 0x00]))
        #expect(throws: NFSError.self) {
            _ = try reader.u32()
        }

        var writer = XDRWriter()
        writer.u32(0xFFFF_FFFF)
        var bad = XDRReader(data: writer.data)
        #expect(throws: NFSError.self) {
            _ = try bad.opaque()
        }
    }
}
