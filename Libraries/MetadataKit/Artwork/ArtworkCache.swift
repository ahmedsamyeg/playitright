import CryptoKit
import Foundation

/// Disk-cache settings for artwork.
public struct ArtworkCacheConfiguration: Sendable, Equatable {
    /// Default cap from doc 05 §2 (2 GB).
    public static let defaultByteLimit: Int64 = 2 * 1024 * 1024 * 1024

    /// Smallest user-selectable cap (0.5 GB).
    public static let minimumByteLimit: Int64 = 512 * 1024 * 1024

    /// Largest user-selectable cap (10 GB).
    public static let maximumByteLimit: Int64 = 10 * 1024 * 1024 * 1024

    /// Directory holding artwork files.
    public var directory: URL

    /// Maximum number of bytes allowed on disk.
    public var byteLimit: Int64

    public init(
        directory: URL = ArtworkCacheConfiguration.defaultDirectory,
        byteLimit: Int64 = ArtworkCacheConfiguration.defaultByteLimit
    ) {
        self.directory = directory
        self.byteLimit = max(0, byteLimit)
    }

    /// Clamps a user-selected cache size to the supported 0.5–10 GB range.
    public static func clampedByteLimit(_ value: Int64) -> Int64 {
        min(max(value, minimumByteLimit), maximumByteLimit)
    }

    /// Default cache location, matching
    /// `Application Support/PlayItRight/Artwork`.
    public static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("PlayItRight", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
    }
}

/// A size-capped, least-recently-used disk cache for artwork.
///
/// Files are named by `sha256(url)` and carry an `.img` extension. Reads bump
/// the file's modification date so eviction follows actual use rather than
/// insertion order (APFS does not reliably update `atime`).
public actor ArtworkCache {
    public let configuration: ArtworkCacheConfiguration

    /// Current disk cap in bytes.
    public private(set) var byteLimit: Int64

    private let fileManager: FileManager
    private let extensionName = "img"

    public init(
        configuration: ArtworkCacheConfiguration = ArtworkCacheConfiguration(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.byteLimit = configuration.byteLimit
        self.fileManager = fileManager
    }

    /// Directory backing this cache.
    public nonisolated var directory: URL {
        configuration.directory
    }

    /// Stable cache key for an artwork URL (`sha256` of the absolute URL).
    public nonisolated static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// File location for a cache key.
    public nonisolated func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent("\(key).\(extensionName)")
    }

    /// Reads cached artwork and marks it as recently used.
    public func data(forKey key: String) throws -> Data? {
        let url = fileURL(forKey: key)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        try? touch(url)
        return data
    }

    /// Stores artwork, evicting least-recently-used files if the cap is
    /// exceeded.
    @discardableResult
    public func store(_ data: Data, forKey key: String) throws -> URL {
        try ensureDirectory()

        let url = fileURL(forKey: key)
        try data.write(to: url, options: .atomic)
        try? touch(url)
        try evictIfNeeded(keeping: url)
        return url
    }

    /// Whether a key currently exists on disk.
    public func contains(key: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(forKey: key).path)
    }

    /// Removes one cached file.
    public func remove(key: String) throws {
        let url = fileURL(forKey: key)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    /// Total bytes used by artwork files.
    public func currentSize() throws -> Int64 {
        try cacheEntries().reduce(0) { $0 + $1.size }
    }

    /// Updates the cap and evicts until the cache fits.
    public func setByteLimit(_ limit: Int64) throws {
        byteLimit = max(0, limit)
        try evictIfNeeded()
    }

    /// Removes every cached artwork file.
    public func clear() throws {
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        try fileManager.removeItem(at: directory)
        try ensureDirectory()
    }

    // MARK: - Eviction

    private struct Entry {
        let url: URL
        let size: Int64
        let modified: Date
    }

    private func evictIfNeeded(keeping protectedURL: URL? = nil) throws {
        var entries = try cacheEntries()
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > byteLimit else {
            return
        }

        entries.sort { $0.modified < $1.modified }

        for entry in entries {
            guard total > byteLimit else {
                break
            }
            if entry.url == protectedURL, entries.count > 1 {
                continue
            }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private func cacheEntries() throws -> [Entry] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url -> Entry? in
            guard url.pathExtension == extensionName,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                return nil
            }
            return Entry(
                url: url,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            )
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private func touch(_ url: URL) throws {
        try fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }
}
