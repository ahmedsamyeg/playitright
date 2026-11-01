import Foundation
import Testing
@testable import SourceAdapters

// MARK: - Fake client

private final class FakeSMBClient: SMBClient, @unchecked Sendable {
    private let stateLock = SMBLock()

    var directories: [String: [SMBEntry]] = [:]
    var files: [String: Data] = [:]
    var stats: [String: SMBFileInfo] = [:]
    var failNextRead = false
    var readRequests: [(path: String, offset: Int64, length: Int)] = []

    private(set) var connectCount = 0
    private(set) var authenticateCount = 0
    private(set) var treeConnectCount = 0
    private(set) var disconnectCount = 0
    private(set) var lastCredentials: SMBCredentials?
    private(set) var lastShare: String?

    func connect() async throws {
        stateLock.withLock { connectCount += 1 }
    }

    func authenticate(credentials: SMBCredentials) async throws {
        stateLock.withLock {
            authenticateCount += 1
            lastCredentials = credentials
        }
    }

    func treeConnect(share: String) async throws {
        stateLock.withLock {
            treeConnectCount += 1
            lastShare = share
        }
    }

    func listDirectory(path: String) async throws -> [SMBEntry] {
        if let entries = stateLock.withLock({ directories[path] }) {
            return entries
        }
        throw SMBError.notFound(path)
    }

    func stat(path: String) async throws -> SMBFileInfo {
        if let info = stateLock.withLock({ stats[path] }) {
            return info
        }
        throw SMBError.notFound(path)
    }

    func read(path: String, offset: Int64, length: Int) async throws -> Data {
        let shouldFail = stateLock.withLock { () -> Bool in
            readRequests.append((path, offset, length))
            if failNextRead {
                failNextRead = false
                return true
            }
            return false
        }
        if shouldFail {
            throw SMBError.transport("Simulated network drop")
        }

        guard let data = stateLock.withLock({ files[path] }) else {
            throw SMBError.notFound(path)
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

private func makeSMBAdapter(
    client: FakeSMBClient,
    configuration: SMBConfiguration = SMBConfiguration(
        reconnectBaseDelay: 0
    ),
    credentials: SMBCredentials? = SMBCredentials(
        username: "samy",
        password: "secret",
        domain: "HOME"
    )
) -> SMBSourceAdapter {
    SMBSourceAdapter(
        configuration: configuration,
        credentialProvider: { _ in credentials },
        clientFactory: { _, _ in client }
    )
}

private func makeSMBSession(
    _ adapter: SMBSourceAdapter,
    endpoint: String = "smb://nas.local/media"
) async throws -> SourceSession {
    let config = SourceConfig(
        kind: .smb,
        name: "NAS",
        endpoint: URL(string: endpoint)
    )
    return try await adapter.connect(config: config)
}

private func collectSMBItems(_ stream: ItemStream) async throws
    -> [SourceItem] {
    var items: [SourceItem] = []
    for try await item in stream {
        items.append(item)
    }
    return items
}

private func collectSMBData(
    _ stream: AsyncThrowingStream<Data, Error>
) async throws -> Data {
    var data = Data()
    for try await chunk in stream {
        data.append(chunk)
    }
    return data
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Tests

@Suite("SMBSourceAdapter Tests", .serialized)
struct SMBSourceAdapterTests {
    @Test("Connect authenticates, tree-connects, and records capabilities")
    func connectHandshake() async throws {
        let client = FakeSMBClient()
        let adapter = makeSMBAdapter(client: client)
        let session = try await makeSMBSession(adapter)

        #expect(client.connectCount == 1)
        #expect(client.authenticateCount == 1)
        #expect(client.treeConnectCount == 1)
        #expect(client.lastShare == "media")
        #expect(client.lastCredentials?.username == "samy")
        #expect(client.lastCredentials?.domain == "HOME")
        #expect(session.metadata["host"] == "nas.local")
        #expect(session.metadata["share"] == "media")
        #expect(session.metadata["endpoint"] == "smb://nas.local/media")
        #expect(session.capabilities.contains(.rangeRequests))
        #expect(session.capabilities.contains(.recursiveEnumeration))
        #expect(session.capabilities.contains(.modificationTimeFreshness))
    }

    @Test("Share and root path parse from the endpoint")
    func parsesTarget() throws {
        let config = SourceConfig(
            kind: .smb,
            name: "NAS",
            endpoint: URL(string: "smb://nas.local/media/Movies")!
        )
        let target = try SMBTarget(
            config: config,
            fallback: SMBConfiguration(port: 445)
        )

        #expect(target.host == "nas.local")
        #expect(target.share == "media")
        #expect(target.rootPath == "Movies")
        #expect(target.port == 445)
        #expect(target.endpoint == "smb://nas.local/media")
    }

    @Test("Directory walks filter samples and sidecar files")
    func enumerateAndFilter() async throws {
        let client = FakeSMBClient()
        client.directories = [
            "": [
                SMBEntry(path: "Movies", name: "Movies", isDirectory: true),
                SMBEntry(
                    path: "readme.nfo",
                    name: "readme.nfo",
                    isDirectory: false,
                    size: 12
                )
            ],
            "Movies": [
                SMBEntry(
                    path: "Inception.mkv",
                    name: "Inception.mkv",
                    isDirectory: false,
                    size: 4096,
                    modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                SMBEntry(
                    path: "sample.mkv",
                    name: "sample.mkv",
                    isDirectory: false,
                    size: 10
                ),
                SMBEntry(
                    path: "Inception.nfo",
                    name: "Inception.nfo",
                    isDirectory: false,
                    size: 200
                )
            ],
            "Movies/Extras": [
                SMBEntry(
                    path: "Trailer.mkv",
                    name: "Trailer.mkv",
                    isDirectory: false,
                    size: 50
                )
            ]
        ]
        client.directories["Movies"]?.append(
            SMBEntry(path: "Extras", name: "Extras", isDirectory: true)
        )

        let adapter = makeSMBAdapter(client: client)
        let session = try await makeSMBSession(adapter)

        let items = try await collectSMBItems(
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

        let movie = try #require(items.first { $0.name == "Inception.mkv" })
        #expect(movie.kind == .movie)
        #expect(movie.sizeBytes == 4096)
        #expect(movie.container == "mkv")
        #expect(movie.parentID == "smb://nas.local/media/Movies")
        #expect(movie.location == "smb://nas.local/media/Movies/Inception.mkv")
    }

    @Test("Non-recursive enumeration does not descend")
    func nonRecursiveEnumeration() async throws {
        let client = FakeSMBClient()
        client.directories = [
            "": [
                SMBEntry(path: "Movies", name: "Movies", isDirectory: true),
                SMBEntry(
                    path: "root.mkv",
                    name: "root.mkv",
                    isDirectory: false,
                    size: 1
                )
            ],
            "Movies": [
                SMBEntry(
                    path: "Inception.mkv",
                    name: "Inception.mkv",
                    isDirectory: false,
                    size: 2
                )
            ]
        ]

        let adapter = makeSMBAdapter(client: client)
        let session = try await makeSMBSession(adapter)

        let items = try await collectSMBItems(
            try await adapter.enumerate(
                session: session,
                scope: LibraryScope(recursive: false)
            )
        )

        #expect(items.map(\.name) == ["root.mkv"])
    }

    @Test("Ranged reads return only the requested bytes")
    func rangedRead() async throws {
        let payload = Data((0..<1024).map { UInt8($0 & 0xFF) })
        let client = FakeSMBClient()
        client.files = ["Movies/Inception.mkv": payload]

        let adapter = makeSMBAdapter(client: client)
        let session = try await makeSMBSession(adapter)

        let location = SMBSourceAdapter.location(
            host: "nas.local",
            share: "media",
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
        let data = try await collectSMBData(
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
        let client = FakeSMBClient()
        client.files = ["Movies/Inception.mkv": payload]

        let adapter = makeSMBAdapter(client: client)
        let session = try await makeSMBSession(adapter)
        let location = SMBSourceAdapter.location(
            host: "nas.local",
            share: "media",
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
        let data = try await collectSMBData(
            adapter.read(session: session, item: item, range: range)
        )

        #expect(data.count == 124)
        #expect(data == payload.subdata(in: 900..<1024))
    }

    @Test("A dropped read resumes from the current offset")
    func resumesAfterDrop() async throws {
        let payload = Data((0..<512).map { UInt8($0 & 0xFF) })
        let client = FakeSMBClient()
        client.files = ["Movies/Inception.mkv": payload]
        client.failNextRead = true

        let adapter = makeSMBAdapter(
            client: client,
            configuration: SMBConfiguration(
                maxReconnects: 2,
                reconnectBaseDelay: 0
            )
        )
        let session = try await makeSMBSession(adapter)
        let location = SMBSourceAdapter.location(
            host: "nas.local",
            share: "media",
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

        let range = try ByteRange(start: 0, end: 511)
        let data = try await collectSMBData(
            adapter.read(session: session, item: item, range: range)
        )

        #expect(data == payload)
        #expect(client.readRequests.count == 2)
        #expect(client.readRequests[0].offset == 0)
        #expect(client.readRequests[1].offset == 0)
    }

    @Test("Freshness reports the root modification time")
    func freshness() async throws {
        let modified = Date(timeIntervalSince1970: 1_700_000_500)
        let client = FakeSMBClient()
        client.stats[""] = SMBFileInfo(
            size: nil,
            modifiedAt: modified,
            isDirectory: true
        )

        let adapter = makeSMBAdapter(client: client)
        let session = try await makeSMBSession(adapter)
        let info = try await adapter.freshness(session: session)

        #expect(info.strategy == .modificationTime)
        #expect(info.lastModified == modified)
    }

    @Test("Disconnect releases the session client")
    func disconnect() async throws {
        let client = FakeSMBClient()
        let adapter = makeSMBAdapter(client: client)
        let session = try await makeSMBSession(adapter)

        await adapter.disconnect(session: session)
        #expect(client.disconnectCount == 1)

        do {
            let stream = try await adapter.enumerate(
                session: session,
                scope: LibraryScope()
            )
            _ = try await collectSMBItems(stream)
            Issue.record("Expected reauthenticationRequired")
        } catch let error as SourceAdapterError {
            #expect(error == .reauthenticationRequired)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

// MARK: - NTLM tests

@Suite("NTLMv2 Tests")
struct NTLMv2Tests {
    @Test("The NT hash matches the known password vector")
    func ntHash() {
        // MD4 of the UTF-16LE string "password".
        #expect(
            hex(NTLMv2Response.ntHash(password: "password"))
                == "8846f7eaee8fb117ad06bdd830b7586c"
        )
    }

    @Test("A deterministic challenge produces stable NTLMv2 responses")
    func responses() {
        let serverChallenge = Data(repeating: 0x11, count: 8)
        let clientChallenge = Data(repeating: 0x22, count: 8)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var targetInfo = Data()
        targetInfo.append(contentsOf: [0x02, 0x00, 0x0C, 0x00])
        targetInfo.append(Data("HOME".utf16le))
        targetInfo.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        let first = NTLMv2Response(
            username: "samy",
            password: "secret",
            domain: "HOME",
            serverChallenge: serverChallenge,
            clientChallenge: clientChallenge,
            timestamp: timestamp,
            targetInfo: targetInfo
        )
        let second = NTLMv2Response(
            username: "samy",
            password: "secret",
            domain: "HOME",
            serverChallenge: serverChallenge,
            clientChallenge: clientChallenge,
            timestamp: timestamp,
            targetInfo: targetInfo
        )

        #expect(first == second)
        #expect(first.lmResponse.count == 24)
        #expect(first.ntResponse.count > 16)
        #expect(first.sessionBaseKey.count == 16)
    }
}
