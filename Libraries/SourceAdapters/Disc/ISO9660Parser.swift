import Foundation

/// The disc families the local adapter can mount (SRC-17).
public enum DiscType: String, Codable, Sendable, CaseIterable, Equatable {
    case iso
    case bdmv
    case videoTS = "video-ts"

    /// Plain-language name shown in diagnostics and the player.
    public var displayName: String {
        switch self {
        case .iso:
            return "Disc image"
        case .bdmv:
            return "Blu-ray disc"
        case .videoTS:
            return "DVD-Video"
        }
    }
}

/// One file or directory inside a mounted disc.
public struct DiscEntry: Sendable, Equatable, Hashable {
    /// Normalized, disc-relative path (no leading slash).
    public var path: String

    /// Final path component.
    public var name: String

    /// Whether the entry is a directory.
    public var isDirectory: Bool

    /// Size in bytes. Directories report the size of their directory record.
    public var size: Int64

    /// Absolute byte offset of the file contents, when the filesystem stores
    /// extents (ISO 9660). `nil` for directory-backed discs.
    public var byteOffset: Int64?

    /// Recording or modification time, when available.
    public var modifiedAt: Date?

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        size: Int64,
        byteOffset: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.byteOffset = byteOffset
        self.modifiedAt = modifiedAt
    }
}

/// A byte-addressable backing store for disc images.
///
/// ISO images are usually too large to load into memory, so the parser reads
/// the volume descriptors and directory extents through this seam. Tests use
/// ``DataDiscByteSource``; production uses ``FileDiscByteSource``.
public protocol DiscByteSource: Sendable {
    /// Total image size in bytes.
    var byteCount: Int64 { get }

    /// Reads up to `length` bytes starting at `offset`.
    func read(offset: Int64, length: Int) throws -> Data
}

/// An in-memory disc image, useful for tests and small fixtures.
public struct DataDiscByteSource: DiscByteSource, Sendable, Equatable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public var byteCount: Int64 {
        Int64(data.count)
    }

    public func read(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0 else {
            throw DiscFileSystemError.invalidOffset(offset)
        }
        guard offset < Int64(data.count) else {
            return Data()
        }
        let start = Int(data.startIndex) + Int(offset)
        let end = min(data.count, start + length)
        return data.subdata(in: start..<end)
    }
}

/// A file-backed disc image using random-access reads.
public struct FileDiscByteSource: DiscByteSource, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var byteCount: Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    public func read(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0 else {
            throw DiscFileSystemError.invalidOffset(offset)
        }
        guard length > 0 else {
            return Data()
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DiscFileSystemError.unreadable(url.lastPathComponent)
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: length) ?? Data()
        } catch {
            throw DiscFileSystemError.unreadable(url.lastPathComponent)
        }
    }
}

/// Errors raised while mounting or reading a disc filesystem.
public enum DiscFileSystemError: Error, Equatable, Sendable, LocalizedError {
    /// The disc image has no recognizable volume descriptor.
    case invalidVolumeDescriptor

    /// A required directory record was malformed.
    case malformedDirectoryRecord(String)

    /// The requested path does not exist.
    case notFound(String)

    /// The path exists but is a directory.
    case isDirectory(String)

    /// A byte range is outside the file.
    case rangeNotSatisfiable(path: String, size: Int64)

    /// A negative or otherwise invalid byte offset was requested.
    case invalidOffset(Int64)

    /// A backing file could not be read.
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidVolumeDescriptor:
            return "The disc image has no ISO 9660 volume descriptor."
        case .malformedDirectoryRecord(let path):
            return "The disc directory record for '\(path)' is malformed."
        case .notFound(let path):
            return "The disc path '\(path)' was not found."
        case .isDirectory(let path):
            return "The disc path '\(path)' is a directory."
        case .rangeNotSatisfiable(let path, let size):
            return "The requested range is outside '\(path)' (\(size) bytes)."
        case .invalidOffset(let offset):
            return "Invalid disc byte offset \(offset)."
        case .unreadable(let name):
            return "The disc file '\(name)' could not be read."
        }
    }
}

/// A read-only filesystem view shared by ISO images and disc folders.
public protocol DiscFileSystem: Sendable {
    /// Looks up one entry, case-insensitively.
    func entry(at path: String) throws -> DiscEntry?

    /// Lists the immediate children of a directory.
    func entries(in path: String) throws -> [DiscEntry]

    /// Reads bytes from a file, honoring an inclusive byte range.
    func read(at path: String, range: ByteRange?) throws -> Data
}

public extension DiscFileSystem {
    /// Reads a whole file.
    func read(at path: String) throws -> Data {
        try read(at: path, range: nil)
    }
}

/// A pure-Swift ISO 9660 reader with Joliet name support.
///
/// The parser reads the primary and supplementary volume descriptors at
/// sector 16, walks the directory hierarchy, and exposes file extents so the
/// disc adapter can serve ranged reads without extracting the image
/// (SRC-17, PB-3).
public struct ISO9660Parser: DiscFileSystem, Sendable {
    /// Disc sector size used by ISO 9660 images.
    public static let sectorSize: Int64 = 2_048

    public let byteSource: any DiscByteSource
    public let volumeName: String
    public let blockSize: Int64
    public let allEntries: [DiscEntry]

    private let entriesByPath: [String: DiscEntry]

    public init(source: any DiscByteSource) throws {
        self.byteSource = source
        let volume = try Self.readVolumeDescriptors(from: source)
        self.volumeName = volume.volumeName
        self.blockSize = volume.blockSize

        var entries: [DiscEntry] = []
        var visited: Set<Int64> = []
        try Self.walkDirectory(
            source: source,
            extent: volume.rootExtent,
            size: volume.rootSize,
            blockSize: volume.blockSize,
            parentPath: "",
            isJoliet: volume.isJoliet,
            visited: &visited,
            entries: &entries
        )
        let sorted = entries.sorted { $0.path < $1.path }
        self.allEntries = sorted
        self.entriesByPath = Dictionary(
            uniqueKeysWithValues: sorted.map { ($0.path.lowercased(), $0) }
        )
    }

    // MARK: DiscFileSystem

    public func entry(at path: String) throws -> DiscEntry? {
        entriesByPath[Self.normalize(path).lowercased()]
    }

    public func entries(in path: String) throws -> [DiscEntry] {
        let directory = Self.normalize(path)
        let prefix = directory.isEmpty ? "" : directory + "/"
        return allEntries.filter { entry in
            guard entry.path != directory, entry.path.hasPrefix(prefix) else {
                return false
            }
            let remainder = entry.path.dropFirst(prefix.count)
            return !remainder.contains("/")
        }
    }

    public func read(at path: String, range: ByteRange?) throws -> Data {
        guard let entry = try entry(at: path) else {
            throw DiscFileSystemError.notFound(path)
        }
        guard !entry.isDirectory else {
            throw DiscFileSystemError.isDirectory(path)
        }
        guard let offset = entry.byteOffset else {
            throw DiscFileSystemError.notFound(path)
        }
        return try Self.read(
            source: byteSource,
            offset: offset * blockSize,
            size: entry.size,
            path: entry.path,
            range: range
        )
    }

    // MARK: Descriptors

    private struct VolumeInfo {
        var volumeName: String
        var blockSize: Int64
        var rootExtent: Int64
        var rootSize: Int64
        var isJoliet: Bool
    }

    private static func readVolumeDescriptors(
        from source: any DiscByteSource
    ) throws -> VolumeInfo {
        var primary: VolumeInfo?
        var joliet: VolumeInfo?

        for index in 0..<64 {
            let offset = Int64(16 + index) * sectorSize
            let descriptor = try source.read(
                offset: offset,
                length: Int(sectorSize)
            )
            guard descriptor.count >= 7 else {
                break
            }
            guard descriptor[1] == 0x43, // C
                  descriptor[2] == 0x44, // D
                  descriptor[3] == 0x30, // 0
                  descriptor[4] == 0x30, // 0
                  descriptor[5] == 0x31 else { // 1
                break
            }

            let type = descriptor[0]
            if type == 1, primary == nil {
                primary = parseVolumeDescriptor(
                    descriptor,
                    joliet: false
                )
            } else if type == 2, joliet == nil {
                let escape = descriptor.subdata(in: 88..<91)
                if escape == Data([0x25, 0x2F, 0x40])
                    || escape == Data([0x25, 0x2F, 0x43])
                    || escape == Data([0x25, 0x2F, 0x45]) {
                    joliet = parseVolumeDescriptor(
                        descriptor,
                        joliet: true
                    )
                }
            } else if type == 255 {
                break
            }
        }

        guard let volume = joliet ?? primary else {
            throw DiscFileSystemError.invalidVolumeDescriptor
        }
        return volume
    }

    private static func parseVolumeDescriptor(
        _ data: Data,
        joliet: Bool
    ) -> VolumeInfo? {
        guard data.count >= 190 else {
            return nil
        }
        let blockSize = Int64(leUInt16(data, at: 128))
        let rootRecord = data.subdata(in: 156..<190)
        guard blockSize > 0,
              let root = parseDirectoryRecord(
                rootRecord,
                at: 0,
                path: "",
                isJoliet: joliet
              ) else {
            return nil
        }

        let rawName = data.subdata(in: 40..<72)
        let volumeName: String
        if joliet {
            volumeName = decodeJoliet(rawName)
        } else {
            let printable = rawName.filter { $0 >= 0x20 && $0 != 0x7F }
            volumeName = String(decoding: printable, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return VolumeInfo(
            volumeName: volumeName.isEmpty ? "Disc" : volumeName,
            blockSize: blockSize,
            rootExtent: root.byteOffset ?? 0,
            rootSize: root.size,
            isJoliet: joliet
        )
    }

    // MARK: Directories

    private static func walkDirectory(
        source: any DiscByteSource,
        extent: Int64,
        size: Int64,
        blockSize: Int64,
        parentPath: String,
        isJoliet: Bool,
        visited: inout Set<Int64>,
        entries: inout [DiscEntry]
    ) throws {
        guard !visited.contains(extent) else {
            return
        }
        visited.insert(extent)

        let directoryData = try source.read(
            offset: extent * blockSize,
            length: Int(min(size, 4 * 1_048_576))
        )
        var offset = 0

        while offset < directoryData.count {
            let length = Int(directoryData[offset])
            if length == 0 {
                // Records never cross a sector boundary; skip the remainder.
                let nextSector = ((offset / Int(sectorSize)) + 1) * Int(sectorSize)
                if nextSector <= offset {
                    break
                }
                offset = nextSector
                continue
            }
            guard offset + length <= directoryData.count else {
                throw DiscFileSystemError.malformedDirectoryRecord(parentPath)
            }
            let recordData = directoryData.subdata(
                in: (directoryData.startIndex + offset)..<(directoryData.startIndex + offset + length)
            )
            defer { offset += length }

            guard let record = parseDirectoryRecord(
                recordData,
                at: 0,
                path: parentPath,
                isJoliet: isJoliet
            ) else {
                continue
            }
            guard record.name != ".", record.name != ".." else {
                continue
            }
            let path = parentPath.isEmpty
                ? record.name
                : parentPath + "/" + record.name
            let entry = DiscEntry(
                path: path,
                name: record.name,
                isDirectory: record.isDirectory,
                size: record.size,
                byteOffset: record.byteOffset,
                modifiedAt: record.modifiedAt
            )
            entries.append(entry)

            if record.isDirectory {
                try walkDirectory(
                    source: source,
                    extent: record.byteOffset ?? 0,
                    size: record.size,
                    blockSize: blockSize,
                    parentPath: path,
                    isJoliet: isJoliet,
                    visited: &visited,
                    entries: &entries
                )
            }
        }
    }

    private struct ParsedRecord {
        var name: String
        var isDirectory: Bool
        var size: Int64
        var byteOffset: Int64?
        var modifiedAt: Date?
    }

    private static func parseDirectoryRecord(
        _ data: Data,
        at start: Int,
        path: String,
        isJoliet: Bool
    ) -> ParsedRecord? {
        guard data.count >= start + 33 else {
            return nil
        }
        let record = data.subdata(
            in: (data.startIndex + start)..<(data.startIndex + data.count)
        )
        guard !record.isEmpty else {
            return nil
        }
        let bytes = record
        let identifierLength = Int(bytes[32])
        guard bytes.count >= 33 + identifierLength else {
            return nil
        }
        let flags = bytes[25]
        let identifier = bytes.subdata(in: 33..<(33 + identifierLength))
        let name: String
        if identifier == Data([0x00]) {
            name = "."
        } else if identifier == Data([0x01]) {
            name = ".."
        } else if isJoliet {
            name = decodeJoliet(identifier)
        } else {
            name = String(decoding: identifier, as: UTF8.self)
        }
        let normalizedName = normalizeName(name)
        guard !normalizedName.isEmpty else {
            return nil
        }

        let extent = Int64(leUInt32(bytes, at: 2))
        let size = Int64(leUInt32(bytes, at: 10))
        let modifiedAt = parseRecordingDate(bytes, at: 18)
        let isDirectory = (flags & 0x02) != 0
        return ParsedRecord(
            name: normalizedName,
            isDirectory: isDirectory,
            size: size,
            byteOffset: extent,
            modifiedAt: modifiedAt
        )
    }

    // MARK: Reading

    static func read(
        source: any DiscByteSource,
        offset: Int64,
        size: Int64,
        path: String,
        range: ByteRange?
    ) throws -> Data {
        let fileSize = max(0, size)
        let requested = range ?? ByteRange.full
        guard let clamped = requested.clamped(to: fileSize) else {
            throw DiscFileSystemError.rangeNotSatisfiable(
                path: path,
                size: fileSize
            )
        }
        let length = clamped.length ?? (fileSize - clamped.start)
        guard length > 0 else {
            return Data()
        }
        return try source.read(
            offset: offset + clamped.start,
            length: Int(length)
        )
    }

    // MARK: Helpers

    /// Normalizes a disc-relative path for lookup.
    public static func normalize(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .joined(separator: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeName(_ name: String) -> String {
        if name == "." || name == ".." {
            return name
        }
        var value = name
        if let semicolon = value.firstIndex(of: ";") {
            value = String(value[..<semicolon])
        }
        if value.hasSuffix(".") {
            value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeJoliet(_ data: Data) -> String {
        guard data.count >= 2 else {
            return ""
        }
        let even = data.count - (data.count % 2)
        let text = String(
            data: data.prefix(even),
            encoding: .utf16BigEndian
        ) ?? ""
        return text
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func leUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard data.count >= offset + 2 else {
            return 0
        }
        return UInt16(data[data.startIndex + offset])
            | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func leUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else {
            return 0
        }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(data[data.startIndex + offset + index]) << (8 * index)
        }
        return value
    }

    private static func parseRecordingDate(
        _ data: Data,
        at offset: Int
    ) -> Date? {
        guard data.count >= offset + 7 else {
            return nil
        }
        let year = 1900 + Int(data[data.startIndex + offset])
        let month = Int(data[data.startIndex + offset + 1])
        let day = Int(data[data.startIndex + offset + 2])
        let hour = Int(data[data.startIndex + offset + 3])
        let minute = Int(data[data.startIndex + offset + 4])
        let second = Int(data[data.startIndex + offset + 5])
        let gmtOffset = Int(Int8(bitPattern: data[data.startIndex + offset + 6]))
        guard (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: gmtOffset * 900)
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
