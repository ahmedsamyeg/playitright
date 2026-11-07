import Foundation

/// The object type recorded in `index.bdmv` for one title.
public enum BDMVTitleObjectType: String, Codable, Sendable, Equatable {
    case movie
    case interactive
    case unknown
}

/// The playback engine recorded in `index.bdmv` for one title.
public enum BDMVTitleAccessType: String, Codable, Sendable, Equatable {
    case hdmv
    case bdJ = "bd-j"
    case unknown
}

/// One title entry parsed from `BDMV/index.bdmv`.
public struct BDMVTitleEntry: Sendable, Equatable, Identifiable {
    /// 1-based title number, in the order encoded in `index.bdmv`.
    public let id: Int

    public let objectType: BDMVTitleObjectType
    public let accessType: BDMVTitleAccessType

    /// Movie-object id referenced by this title.
    public let titleIDRef: Int

    public init(
        id: Int,
        objectType: BDMVTitleObjectType,
        accessType: BDMVTitleAccessType,
        titleIDRef: Int
    ) {
        self.id = id
        self.objectType = objectType
        self.accessType = accessType
        self.titleIDRef = titleIDRef
    }
}

/// The parsed header and title table of `BDMV/index.bdmv`.
public struct BDMVIndex: Sendable, Equatable {
    public let version: String
    public let initialOutputMode: Int
    public let contentExists: Bool
    public let titles: [BDMVTitleEntry]

    public init(
        version: String,
        initialOutputMode: Int,
        contentExists: Bool,
        titles: [BDMVTitleEntry]
    ) {
        self.version = version
        self.initialOutputMode = initialOutputMode
        self.contentExists = contentExists
        self.titles = titles
    }
}

/// One `*.mpls` playlist and the clips it references.
public struct BDMVPlaylist: Sendable, Equatable, Identifiable {
    /// Five-digit playlist number, for example `"00000"`.
    public let number: String

    /// Disc-relative path, for example `BDMV/PLAYLIST/00000.mpls`.
    public let path: String

    /// Size of the playlist file in bytes.
    public let sizeBytes: Int64?

    /// Disc-relative stream paths referenced by the playlist's play items.
    public let clipPaths: [String]

    public var id: String { number }

    public init(
        number: String,
        path: String,
        sizeBytes: Int64? = nil,
        clipPaths: [String] = []
    ) {
        self.number = number
        self.path = path
        self.sizeBytes = sizeBytes
        self.clipPaths = clipPaths
    }
}

/// A title exposed by a Blu-ray disc, combining `index.bdmv` metadata with a
/// playlist from `BDMV/PLAYLIST`.
public struct BDMVTitle: Sendable, Equatable, Identifiable {
    /// 1-based title number.
    public let id: Int

    /// `index.bdmv` metadata, when the disc supplied it.
    public let entry: BDMVTitleEntry?

    /// The playlist backing this title, when one could be resolved.
    public let playlist: BDMVPlaylist?

    public init(
        id: Int,
        entry: BDMVTitleEntry?,
        playlist: BDMVPlaylist?
    ) {
        self.id = id
        self.entry = entry
        self.playlist = playlist
    }

    /// Stream paths that make up the title, in playback order.
    public var streamPaths: [String] {
        playlist?.clipPaths ?? []
    }
}

/// The parsed contents of a `BDMV` folder or Blu-ray ISO image.
public struct BDMVDisc: Sendable, Equatable {
    public let index: BDMVIndex?
    public let playlists: [BDMVPlaylist]

    public init(index: BDMVIndex?, playlists: [BDMVPlaylist]) {
        self.index = index
        self.playlists = playlists
    }

    /// Titles in disc order. When `index.bdmv` is present its title table
    /// drives the order; otherwise every playlist becomes one title.
    public var titles: [BDMVTitle] {
        if let index, !index.titles.isEmpty {
            return index.titles.enumerated().map { offset, entry in
                BDMVTitle(
                    id: entry.id,
                    entry: entry,
                    playlist: offset < playlists.count
                        ? playlists[offset]
                        : nil
                )
            }
        }
        return playlists.enumerated().map { offset, playlist in
            BDMVTitle(id: offset + 1, entry: nil, playlist: playlist)
        }
    }
}

/// Parses `index.bdmv`, `MovieObject`-free playlist lists, and the MPLS
/// play-item tables needed for title playback (SRC-17, PB-3, doc 03 §5).
public struct BDMVParser: Sendable {
    public let filesystem: any DiscFileSystem

    public init(filesystem: any DiscFileSystem) {
        self.filesystem = filesystem
    }

    /// Reads the whole `BDMV` structure from the filesystem.
    public func parse() throws -> BDMVDisc {
        let indexData = try? filesystem.read(at: "BDMV/index.bdmv")
        let index = indexData.flatMap { try? Self.parseIndex($0) }
        let playlists = try parsePlaylists()
        return BDMVDisc(index: index, playlists: playlists)
    }

    /// Enumerates and parses every `BDMV/PLAYLIST/*.mpls` file.
    public func parsePlaylists() throws -> [BDMVPlaylist] {
        let entries: [DiscEntry]
        do {
            entries = try filesystem.entries(in: "BDMV/PLAYLIST")
        } catch DiscFileSystemError.notFound {
            return []
        }

        var playlists: [BDMVPlaylist] = []
        for entry in entries where !entry.isDirectory {
            guard let number = Self.playlistNumber(fromFileName: entry.name) else {
                continue
            }
            let clips = (try? filesystem.read(at: entry.path))
                .flatMap { try? Self.parsePlaylistClips($0) } ?? []
            playlists.append(
                BDMVPlaylist(
                    number: number,
                    path: entry.path,
                    sizeBytes: entry.size,
                    clipPaths: clips
                )
            )
        }
        return playlists.sorted { $0.number < $1.number }
    }

    // MARK: index.bdmv

    /// Parses the header and title table of `index.bdmv`.
    public static func parseIndex(_ data: Data) throws -> BDMVIndex {
        guard data.count >= 16 else {
            throw BDMVError.malformedIndex
        }
        guard data[0] == 0x49, // I
              data[1] == 0x4E, // N
              data[2] == 0x44, // D
              data[3] == 0x58 else { // X
            throw BDMVError.malformedIndex
        }

        let version = String(
            data: data.subdata(in: 4..<8),
            encoding: .ascii
        ) ?? ""

        let declaredStart = Int(beUInt32(data, at: 8))
        let blockOffset = validIndexesOffset(declaredStart, in: data)
            ?? findIndexesBlock(in: data)
        guard let block = blockOffset else {
            throw BDMVError.malformedIndex
        }

        guard data.count >= block + 18 else {
            throw BDMVError.malformedIndex
        }
        let marker = data.subdata(in: block..<(block + 8))
        guard marker == Data("Indexes\0".utf8) || marker == Data("Indexes".utf8) else {
            throw BDMVError.malformedIndex
        }

        let length = Int(beUInt32(data, at: block + 8))
        let initialOutputMode = Int(data[block + 14])
        let contentExists = data[block + 15] != 0
        let titleCount = Int(beUInt16(data, at: block + 16))
        let entriesStart = block + 18

        // The length field lets us reject a bogus count without trusting it
        // blindly. Some authoring tools include the 12-byte header, some do
        // not, so accept either convention.
        let expectedAfterLength = 6 + titleCount * 4
        if length > 0,
           length != expectedAfterLength,
           length != 12 + expectedAfterLength,
           length != titleCount * 4 {
            throw BDMVError.malformedIndex
        }
        guard entriesStart + titleCount * 4 <= data.count else {
            throw BDMVError.malformedIndex
        }

        var titles: [BDMVTitleEntry] = []
        titles.reserveCapacity(titleCount)
        for index in 0..<titleCount {
            let offset = entriesStart + index * 4
            let objectRaw = data[offset]
            let accessRaw = data[offset + 1]
            let titleIDRef = Int(beUInt16(data, at: offset + 2))
            titles.append(
                BDMVTitleEntry(
                    id: index + 1,
                    objectType: BDMVTitleObjectType(rawValue: objectRaw == 1 ? "movie" : objectRaw == 2 ? "interactive" : "unknown") ?? .unknown,
                    accessType: accessRaw == 0 ? .hdmv : (accessRaw == 1 ? .bdJ : .unknown),
                    titleIDRef: titleIDRef
                )
            )
        }

        return BDMVIndex(
            version: version,
            initialOutputMode: initialOutputMode,
            contentExists: contentExists,
            titles: titles
        )
    }

    // MARK: MPLS

    /// Extracts clip names from a playlist's play-item table.
    public static func parsePlaylistClips(_ data: Data) throws -> [String] {
        guard data.count >= 12,
              data[0] == 0x4D, // M
              data[1] == 0x50, // P
              data[2] == 0x4C, // L
              data[3] == 0x53 else { // S
            throw BDMVError.malformedPlaylist
        }

        let playListStart = Int(beUInt32(data, at: 8))
        guard playListStart >= 0, playListStart + 18 <= data.count else {
            throw BDMVError.malformedPlaylist
        }
        guard data.subdata(in: playListStart..<(playListStart + 8))
            == Data("PlayList".utf8) else {
            throw BDMVError.malformedPlaylist
        }

        let itemCount = Int(beUInt16(data, at: playListStart + 14))
        var offset = playListStart + 18
        var clips: [String] = []

        for _ in 0..<itemCount {
            guard offset + 2 <= data.count else {
                throw BDMVError.malformedPlaylist
            }
            let itemLength = Int(beUInt16(data, at: offset))
            guard itemLength >= 10, offset + itemLength <= data.count else {
                throw BDMVError.malformedPlaylist
            }
            let nameData = data.subdata(in: (offset + 2)..<(offset + 7))
            let clipName = String(data: nameData, encoding: .ascii) ?? ""
            if !clipName.isEmpty, clipName.allSatisfy(\.isNumber) {
                clips.append("BDMV/STREAM/\(clipName).m2ts")
            }
            offset += itemLength
        }
        return clips
    }

    /// Returns the five-digit playlist number for a `.mpls` file name.
    public static func playlistNumber(fromFileName name: String) -> String? {
        let lower = name.lowercased()
        guard lower.hasSuffix(".mpls") else {
            return nil
        }
        let stem = String(lower.dropLast(".mpls".count))
        guard stem.count == 5, stem.allSatisfy(\.isNumber) else {
            return nil
        }
        return stem
    }

    // MARK: Helpers

    private static func validIndexesOffset(_ offset: Int, in data: Data) -> Int? {
        guard offset >= 0, offset + 18 <= data.count else {
            return nil
        }
        let marker = data.subdata(in: offset..<(offset + 8))
        guard marker == Data("Indexes\0".utf8) || marker == Data("Indexes".utf8) else {
            return nil
        }
        return offset
    }

    private static func findIndexesBlock(in data: Data) -> Int? {
        let marker = Data("Indexes".utf8)
        guard data.count >= marker.count else {
            return nil
        }
        var offset = 0
        while offset + marker.count <= data.count {
            if data.subdata(in: offset..<(offset + marker.count)) == marker {
                return offset
            }
            offset += 1
        }
        return nil
    }

    private static func beUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard data.count >= offset + 2 else {
            return 0
        }
        return (UInt16(data[data.startIndex + offset]) << 8)
            | UInt16(data[data.startIndex + offset + 1])
    }

    private static func beUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else {
            return 0
        }
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(data[data.startIndex + offset + index])
        }
        return value
    }
}

/// Errors raised while parsing Blu-ray structures.
public enum BDMVError: Error, Equatable, Sendable, LocalizedError {
    case malformedIndex
    case malformedPlaylist

    public var errorDescription: String? {
        switch self {
        case .malformedIndex:
            return "The Blu-ray disc index is malformed."
        case .malformedPlaylist:
            return "The Blu-ray disc playlist is malformed."
        }
    }
}
