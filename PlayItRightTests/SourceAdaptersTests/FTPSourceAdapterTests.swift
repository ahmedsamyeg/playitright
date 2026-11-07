import Foundation
import Testing
@testable import SourceAdapters

// MARK: - Test doubles

private actor MockFTPClient: FTPClient {
    struct ReadCall: Equatable {
        let path: String
        let offset: Int64
        let length: Int
    }

    private let listings: [String: [FTPEntry]]
    private let payload: Data
    private var reads: [ReadCall] = []
    private var authenticatedUser: String?

    init(listings: [String: [FTPEntry]], payload: Data) {
        self.listings = listings
        self.payload = payload
    }

    func connect() async throws {}

    func authenticate(credentials: FTPCredentials) async throws {
        authenticatedUser = credentials.username
    }

    func listDirectory(path: String) async throws -> [FTPEntry] {
        guard let entries = listings[path] else {
            throw FTPError.notFound(path)
        }
        return entries
    }

    func stat(path: String) async throws -> FTPFileInfo {
        FTPFileInfo(size: Int64(payload.count))
    }

    func read(path: String, offset: Int64, length: Int) async throws -> Data {
        reads.append(ReadCall(path: path, offset: offset, length: length))
        guard offset < Int64(payload.count) else {
            return Data()
        }
        let start = Int(offset)
        let end = min(payload.count, start + length)
        return payload.subdata(in: start..<end)
    }

    func disconnect() async {}

    func readCalls() -> [ReadCall] {
        reads
    }

    func user() -> String? {
        authenticatedUser
    }
}

private func collect<T: Sendable>(
    _ stream: AsyncThrowingStream<T, Error>
) async throws -> [T] {
    var values: [T] = []
    for try await value in stream {
        values.append(value)
    }
    return values
}

private func collectData(
    _ stream: AsyncThrowingStream<Data, Error>
) async throws -> Data {
    try await collect(stream).reduce(into: Data()) { $0.append($1) }
}

private let payload = Data("0123456789ABCDEFGHIJ".utf8)

// MARK: - Tests

@Suite("FTPSourceAdapter Tests")
struct FTPSourceAdapterTests {
    @Test("UNIX LIST lines parse directories, files, and symlinks")
    func unixListing() {
        let listing = """
        total 8
        drwxr-xr-x    2 alice  staff        4096 Jan 02 12:34 Movies
        -rw-r--r--    1 alice  staff       12345 Jan 02  2023 movie.mkv
        lrwxrwxrwx    1 alice  staff           7 Jan 02 12:34 sample -> movie.mkv
        """
        let entries = FTPDirectoryParser.parse(listing, currentPath: "/media")

        #expect(entries.count == 3)
        #expect(entries[0].name == "Movies")
        #expect(entries[0].isDirectory)
        #expect(entries[0].path == "/media/Movies")
        #expect(entries[0].size == nil)

        #expect(entries[1].name == "movie.mkv")
        #expect(entries[1].isDirectory == false)
        #expect(entries[1].size == 12_345)
        #expect(
            Calendar(identifier: .gregorian)
                .component(.year, from: entries[1].modifiedAt ?? Date()) == 2023
        )

        #expect(entries[2].name == "sample")
        #expect(entries[2].isDirectory == false)
    }

    @Test("Windows IIS listings parse <DIR> and file sizes")
    func windowsListing() {
        let listing = """
        01-02-24  03:04PM       <DIR>          Movies
        01-02-24  03:04 PM             12345 movie.mkv
        """
        let entries = FTPDirectoryParser.parse(listing, currentPath: "/")

        #expect(entries.count == 2)
        #expect(entries[0].name == "Movies")
        #expect(entries[0].isDirectory)
        #expect(entries[0].path == "/Movies")
        #expect(entries[1].name == "movie.mkv")
        #expect(entries[1].size == 12_345)
    }

    @Test("MLSD facts parse type, size, and UTC modification time")
    func machineListing() {
        let listing = """
        type=dir;modify=20240102030405; Movies
        type=file;size=42;modify=20240102030405; movie.mkv
        type=cdir;modify=20240102030405; .
        """
        let entries = FTPDirectoryParser.parse(listing, currentPath: "/media")

        #expect(entries.count == 2)
        #expect(entries[0].isDirectory)
        #expect(entries[1].name == "movie.mkv")
        #expect(entries[1].size == 42)
        #expect(entries[1].modifiedAt != nil)
    }

    @Test("The adapter walks directories and yields matching files")
    func directoryWalk() async throws {
        let root = [
            FTPEntry(path: "/Movies", name: "Movies", isDirectory: true),
            FTPEntry(
                path: "/root.mkv",
                name: "root.mkv",
                isDirectory: false,
                size: 20
            )
        ]
        let movies = [
            FTPEntry(path: "/Movies/movie.mkv", name: "movie.mkv",
                     isDirectory: false, size: 20),
            FTPEntry(path: "/Movies/notes.txt", name: "notes.txt",
                     isDirectory: false, size: 5)
        ]
        let client = MockFTPClient(
            listings: ["": root, "/Movies": movies],
            payload: payload
        )
        let adapter = FTPSourceAdapter(
            configuration: FTPConfiguration(chunkSize: 4),
            credentialProvider: { _ in
                FTPCredentials(username: "alice", password: "secret")
            },
            clientFactory: { _, _, _ in client }
        )

        let session = try await adapter.connect(
            config: SourceConfig(
                kind: .ftp,
                name: "FTP",
                host: "example.com"
            )
        )
        #expect(session.metadata["host"] == "example.com")
        #expect(await client.user() == "alice")

        let all = try await collect(
            adapter.enumerate(session: session, scope: LibraryScope())
        )
        #expect(all.count == 3)
        #expect(all.contains { $0.name == "root.mkv" })
        #expect(all.contains { $0.name == "movie.mkv" })
        #expect(
            all.first { $0.name == "movie.mkv" }?.location
                == "/Movies/movie.mkv"
        )

        let filtered = try await collect(
            adapter.enumerate(
                session: session,
                scope: LibraryScope(
                    includeGlobs: ["*.mkv"]
                )
            )
        )
        #expect(filtered.count == 2)

        let shallow = try await collect(
            adapter.enumerate(
                session: session,
                scope: LibraryScope(recursive: false)
            )
        )
        #expect(shallow.count == 1)
        #expect(shallow.first?.name == "root.mkv")
    }

    @Test("The adapter retrieves inclusive ranges in chunks")
    func rangedRead() async throws {
        let client = MockFTPClient(
            listings: [
                "": [
                    FTPEntry(
                        path: "/movie.mkv",
                        name: "movie.mkv",
                        isDirectory: false,
                        size: 20
                    )
                ]
            ],
            payload: payload
        )
        let adapter = FTPSourceAdapter(
            configuration: FTPConfiguration(chunkSize: 4),
            clientFactory: { _, _, _ in client }
        )
        let session = try await adapter.connect(
            config: SourceConfig(
                kind: .ftp,
                name: "FTP",
                host: "example.com"
            )
        )
        let items = try await collect(
            adapter.enumerate(session: session, scope: LibraryScope())
        )
        let item = try #require(items.first)

        let range = try ByteRange(start: 5, end: 9)
        let data = try await collectData(
            adapter.read(session: session, item: item, range: range)
        )
        #expect(data == Data("56789".utf8))

        let calls = await client.readCalls()
        #expect(calls.map(\.offset) == [5, 9])
        #expect(calls.allSatisfy { $0.path == "/movie.mkv" })

        let tailRange = try ByteRange(start: 15, end: nil)
        let tail = try await collectData(
            adapter.read(session: session, item: item, range: tailRange)
        )
        #expect(tail == Data("FGHIJ".utf8))
    }

    @Test("PASV replies resolve host and port")
    func passiveEndpoint() {
        let endpoint = FTPControlClient.passiveEndpoint(
            from: "227 Entering Passive Mode (192,168,1,2,10,20)."
        )
        #expect(endpoint?.host == "192.168.1.2")
        #expect(endpoint?.port == 2_580)

        #expect(
            FTPControlClient.passiveEndpoint(from: "227 no parenthesis") == nil
        )
    }

    @Test("SFTP adapters map the shared walk and read contract")
    func sftpAdapter() async throws {
        let client = MockSFTPClient(
            listings: [
                "": [
                    SFTPEntry(
                        path: "/show.mkv",
                        name: "show.mkv",
                        isDirectory: false,
                        size: 20
                    )
                ]
            ],
            payload: payload
        )
        let adapter = SFTPSourceAdapter(
            configuration: SFTPConfiguration(chunkSize: 4),
            credentialProvider: { _ in
                SFTPCredentials(username: "alice", password: "secret")
            },
            clientFactory: { _, _, _ in client }
        )
        let session = try await adapter.connect(
            config: SourceConfig(
                kind: .sftp,
                name: "SFTP",
                host: "example.com"
            )
        )
        #expect(adapter.kind == .sftp)

        let items = try await collect(
            adapter.enumerate(session: session, scope: LibraryScope())
        )
        #expect(items.count == 1)
        #expect(items[0].name == "show.mkv")

        let range = try ByteRange(start: 3, end: 6)
        let data = try await collectData(
            adapter.read(session: session, item: items[0], range: range)
        )
        #expect(data == Data("3456".utf8))
    }
}

private actor MockSFTPClient: SFTPClient {
    private let listings: [String: [SFTPEntry]]
    private let payload: Data

    init(listings: [String: [SFTPEntry]], payload: Data) {
        self.listings = listings
        self.payload = payload
    }

    func connect() async throws {}
    func authenticate(credentials: SFTPCredentials) async throws {}
    func listDirectory(path: String) async throws -> [SFTPEntry] {
        listings[path] ?? []
    }
    func stat(path: String) async throws -> SFTPFileInfo {
        SFTPFileInfo(size: Int64(payload.count))
    }
    func read(path: String, offset: Int64, length: Int) async throws -> Data {
        guard offset < Int64(payload.count) else {
            return Data()
        }
        let start = Int(offset)
        return payload.subdata(in: start..<min(payload.count, start + length))
    }
    func disconnect() async {}
}
