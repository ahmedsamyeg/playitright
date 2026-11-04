import Foundation
import LibraryCore
import Observation

/// Watched-state filter choices in the library filter bar.
public enum WatchedFilter: String, CaseIterable, Sendable, Codable, Equatable {
    case any
    case watched
    case unwatched
    case inProgress

    public var displayName: String {
        switch self {
        case .any:
            return "Any Status"
        case .watched:
            return "Watched"
        case .unwatched:
            return "Unwatched"
        case .inProgress:
            return "In Progress"
        }
    }
}

/// Resolution filter choices.
public enum ResolutionFilter: String, CaseIterable, Sendable, Codable, Equatable {
    case any
    case hd
    case uhd4K

    public var displayName: String {
        switch self {
        case .any:
            return "Any Resolution"
        case .hd:
            return "HD"
        case .uhd4K:
            return "4K"
        }
    }
}

/// HDR filter choices.
public enum HDRFilter: String, CaseIterable, Sendable, Codable, Equatable {
    case any
    case hdr10
    case dolbyVision

    public var displayName: String {
        switch self {
        case .any:
            return "Any Dynamic Range"
        case .hdr10:
            return "HDR10"
        case .dolbyVision:
            return "Dolby Vision"
        }
    }
}

/// The state behind the library filter bar (MD-4, doc 05 §4, doc 06 §2.3).
///
/// Selections compile into a ``SmartLibraryFilter`` whose predicates are
/// whitelisted in `LibraryCore`, so user input never reaches raw SQL.
@MainActor
@Observable
public final class FilterBarViewModel {
    public var sourceId: String?
    public var watched: WatchedFilter = .any
    public var genreIds: Set<Int> = []
    public var resolution: ResolutionFilter = .any
    public var codec: String?
    public var hdr: HDRFilter = .any

    public private(set) var sources: [SourceRecord] = []
    public private(set) var genres: [GenreRecord] = []
    public private(set) var savedLibraries: [SmartLibraryRecord] = []

    private let reader: MediaDatabaseReader
    private let writer: MediaDatabaseWriter?

    public init(
        reader: MediaDatabaseReader,
        writer: MediaDatabaseWriter? = nil
    ) {
        self.reader = reader
        self.writer = writer
    }

    public static let codecChoices: [(id: String, name: String)] = [
        ("hevc", "HEVC"),
        ("h264", "H.264"),
        ("av1", "AV1"),
        ("vp9", "VP9")
    ]

    public var activeGroupCount: Int {
        var count = 0
        if sourceId != nil { count += 1 }
        if watched != .any { count += 1 }
        if !genreIds.isEmpty { count += 1 }
        if resolution != .any { count += 1 }
        if codec != nil { count += 1 }
        if hdr != .any { count += 1 }
        return count
    }

    public var hasActiveFilters: Bool {
        activeGroupCount > 0
    }

    /// Loads sources, genres, and previously saved Smart Libraries.
    public func load() async {
        let reader = reader
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                FilterBarSnapshot(
                    sources: try reader.fetchSources(),
                    genres: try reader.fetchGenres(),
                    saved: try reader.fetchSmartLibraries()
                )
            }.value
            sources = snapshot.sources
            genres = snapshot.genres
            savedLibraries = snapshot.saved
        } catch {
            // A filter-bar load failure should not block browsing; the chips
            // simply remain empty until the next attempt.
            sources = []
            genres = []
        }
    }

    public func clear() {
        sourceId = nil
        watched = .any
        genreIds = []
        resolution = .any
        codec = nil
        hdr = .any
    }

    public func toggleGenre(_ genreId: Int) {
        if genreIds.contains(genreId) {
            genreIds.remove(genreId)
        } else {
            genreIds.insert(genreId)
        }
    }

    /// Compiles the active chips into a whitelisted Smart Library predicate.
    public func makeFilter() -> SmartLibraryFilter {
        var rules: [SmartFilterRule] = []

        if let sourceId {
            rules.append(
                SmartFilterRule(field: .sourceId, operator: .equals, value: sourceId)
            )
        }

        switch watched {
        case .any:
            break
        case .watched:
            rules.append(
                SmartFilterRule(field: .watched, operator: .equals, value: "1")
            )
        case .unwatched:
            rules.append(
                SmartFilterRule(field: .watched, operator: .equals, value: "0")
            )
        case .inProgress:
            rules.append(
                SmartFilterRule(field: .watched, operator: .equals, value: "0")
            )
            rules.append(
                SmartFilterRule(field: .positionMs, operator: .greaterThan, value: "0")
            )
        }

        if !genreIds.isEmpty {
            let value = genreIds.sorted().map(String.init).joined(separator: ",")
            rules.append(
                SmartFilterRule(field: .genreId, operator: .inList, value: value)
            )
        }

        switch resolution {
        case .any:
            break
        case .hd:
            rules.append(
                SmartFilterRule(field: .height, operator: .lessThan, value: "2000")
            )
        case .uhd4K:
            rules.append(
                SmartFilterRule(
                    field: .height,
                    operator: .greaterThanOrEqual,
                    value: "2000"
                )
            )
        }

        if let codec {
            rules.append(
                SmartFilterRule(field: .codec, operator: .equals, value: codec)
            )
        }

        switch hdr {
        case .any:
            break
        case .hdr10:
            rules.append(
                SmartFilterRule(field: .hdrFormat, operator: .contains, value: "HDR")
            )
        case .dolbyVision:
            rules.append(
                SmartFilterRule(field: .hdrFormat, operator: .contains, value: "Dolby")
            )
        }

        return SmartLibraryFilter(conjunction: .and, rules: rules)
    }

    /// Restores a saved Smart Library's chips from its compiled rules.
    public func apply(_ filter: SmartLibraryFilter) {
        clear()

        var sawInProgressRule = false
        for rule in filter.rules {
            switch rule.field {
            case .sourceId:
                if rule.operator == .equals {
                    sourceId = rule.value
                }

            case .watched:
                switch rule.value {
                case "1":
                    watched = .watched
                case "0":
                    watched = .unwatched
                default:
                    break
                }

            case .genreId:
                genreIds = Set(
                    rule.value
                        .split(separator: ",")
                        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                )

            case .height:
                if rule.operator == .greaterThanOrEqual,
                   let value = Int(rule.value),
                   value >= 2000 {
                    resolution = .uhd4K
                } else if rule.operator == .lessThan {
                    resolution = .hd
                }

            case .codec:
                if rule.operator == .equals {
                    codec = rule.value
                }

            case .hdrFormat:
                if rule.value.localizedCaseInsensitiveContains("dolby") {
                    hdr = .dolbyVision
                } else if rule.value.localizedCaseInsensitiveContains("hdr") {
                    hdr = .hdr10
                }

            case .positionMs:
                if rule.operator == .greaterThan, rule.value == "0" {
                    sawInProgressRule = true
                }

            default:
                break
            }
        }

        if sawInProgressRule && watched == .unwatched {
            watched = .inProgress
        }
    }

    /// Saves the active chips as a new Smart Library and returns its record.
    @discardableResult
    public func saveCurrentFilters(name: String) async throws -> SmartLibraryRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FilterBarError.missingName
        }
        guard let writer else {
            throw FilterBarError.databaseUnavailable
        }

        let filter = makeFilter()
        let data = try JSONEncoder().encode(filter)
        guard let json = String(data: data, encoding: .utf8) else {
            throw FilterBarError.encodingFailed
        }

        let record = SmartLibraryRecord(
            id: UUID().uuidString,
            name: trimmed,
            filters: json,
            ord: savedLibraries.count
        )
        let writerCopy = writer
        try await Task.detached(priority: .userInitiated) {
            try writerCopy.saveSmartLibrary(record)
        }.value

        savedLibraries.append(record)
        return record
    }

    /// Loads a saved Smart Library into the active chips.
    public func recall(_ record: SmartLibraryRecord) throws {
        guard let data = record.filters.data(using: .utf8) else {
            throw FilterBarError.decodingFailed
        }
        let filter = try JSONDecoder().decode(SmartLibraryFilter.self, from: data)
        apply(filter)
    }

    public func deleteSavedLibrary(_ record: SmartLibraryRecord) async throws {
        guard let writer else {
            throw FilterBarError.databaseUnavailable
        }
        let writerCopy = writer
        try await Task.detached(priority: .userInitiated) {
            try writerCopy.deleteSmartLibrary(id: record.id)
        }.value
        savedLibraries.removeAll { $0.id == record.id }
    }
}

public enum FilterBarError: Error, Sendable, Equatable, LocalizedError {
    case missingName
    case databaseUnavailable
    case encodingFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .missingName:
            return "Give this Smart Library a name."
        case .databaseUnavailable:
            return "The library database is unavailable."
        case .encodingFailed:
            return "The filter could not be encoded."
        case .decodingFailed:
            return "The saved filter could not be read."
        }
    }
}

private struct FilterBarSnapshot: Sendable {
    let sources: [SourceRecord]
    let genres: [GenreRecord]
    let saved: [SmartLibraryRecord]

    nonisolated init(
        sources: [SourceRecord],
        genres: [GenreRecord],
        saved: [SmartLibraryRecord]
    ) {
        self.sources = sources
        self.genres = genres
        self.saved = saved
    }
}
