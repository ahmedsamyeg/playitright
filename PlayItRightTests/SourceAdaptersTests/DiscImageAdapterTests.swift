import Foundation
import Testing
@testable import SourceAdapters

// MARK: - Helpers

private let sectorSize = 2_048

private func bothEndian16(_ value: UInt16) -> [UInt8] {
    [
        UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
    ]
}

private func bothEndian32(_ value: UInt32) -> [UInt8] {
    [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ]
}

private func write(
    _ bytes: [UInt8],
    into data: inout Data,
    at offset: Int
) {
    data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
}

private func directoryRecord(
    identifier: [UInt8],
    extent: UInt32,
    size: UInt32,
    isDirectory: Bool
) -> [UInt8] {
    var length = 33 + identifier.count
    if length % 2 == 1 {
        length += 1
    }
    var record = [UInt8](repeating: 0, count: length)
    record[0] = UInt8(length)
    record[1] = 0
    let extentBytes = bothEndian32(extent)
    record.replaceSubrange(2..<10, with: extentBytes)
    let sizeBytes = bothEndian32(size)
    record.replaceSubrange(10..<18, with: sizeBytes)
    record.replaceSubrange(18..<25, with: [120, 1, 1, 0, 0, 0, 0])
    record[25] = isDirectory ? 0x02 : 0x00
    record[26] = 0
    record[27] = 0
    record.replaceSubrange(28..<32, with: bothEndian16(1))
    record[32] = UInt8(identifier.count)
    record.replaceSubrange(33..<(33 + identifier.count), with: identifier)
    return record
}

private func makeISOImage() -> Data {
    let sectors = 24
    var data = Data(repeating: 0, count: sectors * sectorSize)

    // Primary volume descriptor at sector 16.
    var pvd = [UInt8](repeating: 0, count: sectorSize)
    pvd[0] = 1
    pvd.replaceSubrange(1..<6, with: Array("CD001".utf8))
    pvd[6] = 1
    let volumeName = Array("TESTDISC".utf8)
    pvd.replaceSubrange(40..<(40 + volumeName.count), with: volumeName)
    pvd.replaceSubrange(
        80..<88,
        with: bothEndian32(UInt32(sectors))
    )
    pvd.replaceSubrange(128..<132, with: bothEndian16(2_048))
    pvd.replaceSubrange(132..<140, with: bothEndian32(0))
    let rootRecord = directoryRecord(
        identifier: [0x00],
        extent: 18,
        size: 2_048,
        isDirectory: true
    )
    pvd.replaceSubrange(156..<(156 + rootRecord.count), with: rootRecord)
    write(pvd, into: &data, at: 16 * sectorSize)

    // Terminator descriptor at sector 17.
    var terminator = [UInt8](repeating: 0, count: sectorSize)
    terminator[0] = 255
    terminator.replaceSubrange(1..<6, with: Array("CD001".utf8))
    terminator[6] = 1
    write(terminator, into: &data, at: 17 * sectorSize)

    // Root directory at sector 18.
    var root = [UInt8]()
    root += directoryRecord(
        identifier: [0x00],
        extent: 18,
        size: 2_048,
        isDirectory: true
    )
    root += directoryRecord(
        identifier: [0x01],
        extent: 18,
        size: 2_048,
        isDirectory: true
    )
    root += directoryRecord(
        identifier: Array("BDMV".utf8),
        extent: 19,
        size: 2_048,
        isDirectory: true
    )
    root += directoryRecord(
        identifier: Array("MOVIE.MKV;1".utf8),
        extent: 20,
        size: 9,
        isDirectory: false
    )
    write(root, into: &data, at: 18 * sectorSize)

    // BDMV directory at sector 19.
    var bdmv = [UInt8]()
    bdmv += directoryRecord(
        identifier: [0x00],
        extent: 19,
        size: 2_048,
        isDirectory: true
    )
    bdmv += directoryRecord(
        identifier: [0x01],
        extent: 18,
        size: 2_048,
        isDirectory: true
    )
    bdmv += directoryRecord(
        identifier: Array("INDEX.BDM;1".utf8),
        extent: 21,
        size: 4,
        isDirectory: false
    )
    write(bdmv, into: &data, at: 19 * sectorSize)

    write(Array("MOVIEDATA".utf8), into: &data, at: 20 * sectorSize)
    write(Array("IDX!".utf8), into: &data, at: 21 * sectorSize)
    return data
}

private func makeIndexData(
    titles: [(object: UInt8, access: UInt8, ref: UInt16)]
) -> Data {
    let headerSize = 72
    let count = titles.count
    var data = Data(repeating: 0, count: headerSize + 18 + count * 4)
    write(Array("INDX".utf8), into: &data, at: 0)
    write(Array("0200".utf8), into: &data, at: 4)

    var start = [UInt8](repeating: 0, count: 4)
    start[3] = UInt8(headerSize)
    write(start, into: &data, at: 8)

    write(Array("Indexes\0".utf8), into: &data, at: headerSize)
    let length = UInt32(6 + count * 4)
    var lengthBytes = [UInt8](repeating: 0, count: 4)
    lengthBytes[2] = UInt8((length >> 8) & 0xFF)
    lengthBytes[3] = UInt8(length & 0xFF)
    write(lengthBytes, into: &data, at: headerSize + 8)
    data[headerSize + 14] = 0
    data[headerSize + 15] = 1
    data[headerSize + 16] = UInt8((count >> 8) & 0xFF)
    data[headerSize + 17] = UInt8(count & 0xFF)

    for (index, title) in titles.enumerated() {
        let offset = headerSize + 18 + index * 4
        data[offset] = title.object
        data[offset + 1] = title.access
        data[offset + 2] = UInt8((title.ref >> 8) & 0xFF)
        data[offset + 3] = UInt8(title.ref & 0xFF)
    }
    return data
}

private func makePlaylistData(clip: String) -> Data {
    let playlistStart = 64
    var data = Data(repeating: 0, count: playlistStart + 18 + 22)
    write(Array("MPLS".utf8), into: &data, at: 0)
    write(Array("0200".utf8), into: &data, at: 4)
    var startBytes = [UInt8](repeating: 0, count: 4)
    startBytes[3] = UInt8(playlistStart)
    write(startBytes, into: &data, at: 8)

    write(Array("PlayList".utf8), into: &data, at: playlistStart)
    data[playlistStart + 14] = 0
    data[playlistStart + 15] = 1
    data[playlistStart + 16] = 0
    data[playlistStart + 17] = 0

    let itemOffset = playlistStart + 18
    data[itemOffset] = 0
    data[itemOffset + 1] = 22
    write(Array(clip.utf8), into: &data, at: itemOffset + 2)
    write(Array("M2TS".utf8), into: &data, at: itemOffset + 7)
    return data
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("disc-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

private func makeBDMVFolder() throws -> URL {
    let root = try makeTemporaryDirectory()
    let bdmv = root.appendingPathComponent("BDMV")
    let playlists = bdmv.appendingPathComponent("PLAYLIST")
    let streams = bdmv.appendingPathComponent("STREAM")
    for directory in [bdmv, playlists, streams] {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }
    try makeIndexData(
        titles: [(object: 1, access: 0, ref: 0), (object: 1, access: 0, ref: 1)]
    ).write(to: bdmv.appendingPathComponent("index.bdmv"))
    try makePlaylistData(clip: "00000").write(
        to: playlists.appendingPathComponent("00000.mpls")
    )
    try makePlaylistData(clip: "00001").write(
        to: playlists.appendingPathComponent("00001.mpls")
    )
    try Data("STREAMDATA".utf8).write(
        to: streams.appendingPathComponent("00000.m2ts")
    )
    try Data("SECOND".utf8).write(
        to: streams.appendingPathComponent("00001.m2ts")
    )
    return root
}

private func makeVideoTSFolder() throws -> URL {
    let root = try makeTemporaryDirectory()
    let videoTS = root.appendingPathComponent("VIDEO_TS")
    try FileManager.default.createDirectory(
        at: videoTS,
        withIntermediateDirectories: true
    )
    try Data().write(to: videoTS.appendingPathComponent("VIDEO_TS.IFO"))
    try Data("AAAA".utf8).write(to: videoTS.appendingPathComponent("VTS_01_1.VOB"))
    try Data("BBBB".utf8).write(to: videoTS.appendingPathComponent("VTS_01_2.VOB"))
    try Data("CCCC".utf8).write(to: videoTS.appendingPathComponent("VTS_02_1.VOB"))
    return root
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

// MARK: - Tests

@Suite("DiscImageAdapter Tests")
struct DiscImageAdapterTests {
    @Test("ISO 9660 parses the volume descriptor and nested directories")
    func isoVolumeAndDirectories() throws {
        let parser = try ISO9660Parser(
            source: DataDiscByteSource(data: makeISOImage())
        )

        #expect(parser.volumeName == "TESTDISC")
        #expect(parser.blockSize == 2_048)
        #expect(parser.allEntries.contains { $0.path == "MOVIE.MKV" })
        #expect(parser.allEntries.contains { $0.path == "BDMV" && $0.isDirectory })
        #expect(parser.allEntries.contains { $0.path == "BDMV/INDEX.BDM" })

        let root = try parser.entries(in: "")
        #expect(root.map(\.name).sorted() == ["BDMV", "MOVIE.MKV"])

        let bdmv = try parser.entries(in: "BDMV")
        #expect(bdmv.map(\.name) == ["INDEX.BDM"])
    }

    @Test("ISO 9660 extracts files and honors inclusive byte ranges")
    func isoFileExtraction() throws {
        let parser = try ISO9660Parser(
            source: DataDiscByteSource(data: makeISOImage())
        )

        #expect(try parser.read(at: "MOVIE.MKV") == Data("MOVIEDATA".utf8))
        #expect(try parser.read(at: "movie.mkv") == Data("MOVIEDATA".utf8))

        let range = try ByteRange(start: 2, end: 5)
        #expect(
            try parser.read(at: "MOVIE.MKV", range: range)
                == Data("VIED".utf8)
        )

        #expect(throws: DiscFileSystemError.isDirectory("BDMV")) {
            _ = try parser.read(at: "BDMV")
        }
        #expect(throws: DiscFileSystemError.notFound("NOPE.MKV")) {
            _ = try parser.read(at: "NOPE.MKV")
        }
    }

    @Test("index.bdmv enumerates titles and their object types")
    func bdmvIndexTitles() throws {
        let data = makeIndexData(
            titles: [
                (object: 1, access: 0, ref: 0),
                (object: 2, access: 1, ref: 3)
            ]
        )
        let index = try BDMVParser.parseIndex(data)

        #expect(index.version == "0200")
        #expect(index.contentExists)
        #expect(index.titles.count == 2)
        #expect(index.titles[0].id == 1)
        #expect(index.titles[0].objectType == .movie)
        #expect(index.titles[0].accessType == .hdmv)
        #expect(index.titles[0].titleIDRef == 0)
        #expect(index.titles[1].objectType == .interactive)
        #expect(index.titles[1].accessType == .bdJ)
        #expect(index.titles[1].titleIDRef == 3)
    }

    @Test("MPLS play items resolve to STREAM clip paths")
    func mplsClips() throws {
        let clips = try BDMVParser.parsePlaylistClips(
            makePlaylistData(clip: "00042")
        )
        #expect(clips == ["BDMV/STREAM/00042.m2ts"])

        let playlist = BDMVParser.playlistNumber(fromFileName: "00042.mpls")
        #expect(playlist == "00042")
        #expect(BDMVParser.playlistNumber(fromFileName: "movie.mpls") == nil)
    }

    @Test("BDMV index and playlist files enumerate titles")
    func bdmvTitles() throws {
        let root = try makeBDMVFolder()
        let filesystem = try DirectoryDiscFileSystem(rootURL: root)
        let disc = try BDMVParser(filesystem: filesystem).parse()

        #expect(disc.index?.titles.count == 2)
        #expect(disc.playlists.map(\.number) == ["00000", "00001"])
        #expect(disc.titles.count == 2)
        #expect(disc.titles[0].playlist?.number == "00000")
        #expect(disc.titles[0].streamPaths == ["BDMV/STREAM/00000.m2ts"])
        #expect(disc.titles[1].streamPaths == ["BDMV/STREAM/00001.m2ts"])
    }

    @Test("The adapter mounts a BDMV folder and plays titles in ranges")
    func bdmvAdapter() async throws {
        let root = try makeBDMVFolder()
        let adapter = DiscImageAdapter(chunkSize: 4)
        let session = try await adapter.connect(
            config: SourceConfig(
                kind: .local,
                name: "Blu-ray",
                endpoint: root
            )
        )

        #expect(session.metadata["disc.type"] == "bdmv")
        #expect(session.capabilities.contains(.rangeRequests))

        let items = try await collect(
            adapter.enumerate(
                session: session,
                scope: LibraryScope()
            )
        )
        #expect(items.count == 2)
        #expect(items[0].kind == .playlist)
        #expect(items[0].name == "Title 1")
        #expect(items[0].container == "m2ts")

        let full = try await collectData(
            adapter.read(session: session, item: items[0], range: nil)
        )
        #expect(full == Data("STREAMDATA".utf8))

        let range = try ByteRange(start: 2, end: 5)
        let partial = try await collectData(
            adapter.read(session: session, item: items[0], range: range)
        )
        #expect(partial == Data("REAM".utf8))
        #expect(partial.count == 4)

        let second = try await collectData(
            adapter.read(session: session, item: items[1], range: nil)
        )
        #expect(second == Data("SECOND".utf8))
    }

    @Test("The adapter concatenates VIDEO_TS VOB sets into titles")
    func videoTSAdapter() async throws {
        let root = try makeVideoTSFolder()
        let adapter = DiscImageAdapter(chunkSize: 2)
        let session = try await adapter.connect(
            config: SourceConfig(
                kind: .local,
                name: "DVD",
                endpoint: root
            )
        )

        #expect(session.metadata["disc.type"] == "video-ts")

        let items = try await collect(
            adapter.enumerate(
                session: session,
                scope: LibraryScope()
            )
        )
        #expect(items.count == 2)
        #expect(items[0].location == "video-ts:1")
        #expect(items[1].location == "video-ts:2")

        let first = try await collectData(
            adapter.read(session: session, item: items[0], range: nil)
        )
        #expect(first == Data("AAAABBBB".utf8))

        let range = try ByteRange(start: 2, end: 4)
        let partial = try await collectData(
            adapter.read(session: session, item: items[0], range: range)
        )
        #expect(partial == Data("AAB".utf8))

        let second = try await collectData(
            adapter.read(session: session, item: items[1], range: nil)
        )
        #expect(second == Data("CCCC".utf8))
    }

    @Test("The adapter mounts an ISO image and reads media files")
    func isoAdapter() async throws {
        let root = try makeTemporaryDirectory()
        let isoURL = root.appendingPathComponent("movie.iso")
        try makeISOImage().write(to: isoURL)

        let adapter = DiscImageAdapter(chunkSize: 3)
        let session = try await adapter.connect(
            config: SourceConfig(
                kind: .local,
                name: "Image",
                endpoint: isoURL
            )
        )
        #expect(session.metadata["disc.type"] == "iso")
        #expect(session.metadata["disc.volume"] == "TESTDISC")

        let items = try await collect(
            adapter.enumerate(
                session: session,
                scope: LibraryScope()
            )
        )
        #expect(items.count == 1)
        #expect(items[0].name == "MOVIE.MKV")
        #expect(items[0].container == "mkv")
        #expect(items[0].sizeBytes == 9)

        let data = try await collectData(
            adapter.read(session: session, item: items[0], range: nil)
        )
        #expect(data == Data("MOVIEDATA".utf8))

        let range = try ByteRange(start: 6, end: nil)
        let tail = try await collectData(
            adapter.read(session: session, item: items[0], range: range)
        )
        #expect(tail == Data("ATA".utf8))
    }

    @Test("Invalid disc configurations are rejected with clear errors")
    func invalidDisc() async throws {
        let root = try makeTemporaryDirectory()
        let adapter = DiscImageAdapter()
        await #expect(throws: SourceAdapterError.self) {
            _ = try await adapter.connect(
                config: SourceConfig(
                    kind: .local,
                    name: "Empty",
                    endpoint: root
                )
            )
        }
        await #expect(throws: SourceAdapterError.self) {
            _ = try await adapter.connect(
                config: SourceConfig(kind: .local, name: "No endpoint")
            )
        }
    }
}
