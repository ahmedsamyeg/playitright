import Foundation
import GRDB

/// Whitelisted fields for smart-library filter predicates (Design 01 §5.8).
public enum SmartFilterField: String, Codable, Sendable, CaseIterable {
    // media_files
    case sourceId = "source_id"
    case path
    case mtime
    case durationMs = "duration_ms"
    case matchState = "match_state"
    case container

    // tracks
    case trackKind = "kind"
    case codec
    case width
    case height
    case hdrFormat = "hdr_format"
    case channels
    case lang
    case subtitleFormat = "subtitle_format"

    // movies / tv_shows
    case title
    case releaseDate = "release_date"
    case firstAirDate = "first_air_date"
    case ratingScore = "rating_score"
    case status

    // media_genres
    case genreId = "genre_id"

    // watch_state
    case watched
    case positionMs = "position_ms"

    /// SQL column expression with table qualifier
    var sqlColumn: String {
        switch self {
        case .sourceId: return "f.source_id"
        case .path: return "f.path"
        case .mtime: return "f.mtime"
        case .durationMs: return "f.duration_ms"
        case .matchState: return "f.match_state"
        case .container: return "f.container"

        case .trackKind: return "t.kind"
        case .codec: return "t.codec"
        case .width: return "t.width"
        case .height: return "t.height"
        case .hdrFormat: return "t.hdr_format"
        case .channels: return "t.channels"
        case .lang: return "t.lang"
        case .subtitleFormat: return "t.subtitle_format"

        case .title: return "COALESCE(m.title, s.title)"
        case .releaseDate: return "m.release_date"
        case .firstAirDate: return "s.first_air_date"
        case .ratingScore: return "COALESCE(m.rating_score, s.rating_score)"
        case .status: return "COALESCE(m.status, s.status)"

        case .genreId: return "g.genre_id"

        case .watched: return "w.watched"
        case .positionMs: return "w.position_ms"
        }
    }

    /// Checks if this field requires joining a particular table
    var requiresTracksJoin: Bool {
        switch self {
        case .trackKind, .codec, .width, .height, .hdrFormat, .channels, .lang, .subtitleFormat:
            return true
        default:
            return false
        }
    }

    var requiresMoviesOrShowsJoin: Bool {
        switch self {
        case .title, .releaseDate, .firstAirDate, .ratingScore, .status:
            return true
        default:
            return false
        }
    }

    var requiresGenreJoin: Bool {
        self == .genreId
    }

    var requiresWatchStateJoin: Bool {
        self == .watched || self == .positionMs
    }
}

public enum SmartFilterOperator: String, Codable, Sendable {
    case equals = "eq"
    case notEquals = "ne"
    case greaterThan = "gt"
    case greaterThanOrEqual = "gte"
    case lessThan = "lt"
    case lessThanOrEqual = "lte"
    case contains = "contains"
    case inList = "in"
}

public struct SmartFilterRule: Codable, Sendable, Equatable {
    public let field: SmartFilterField
    public let `operator`: SmartFilterOperator
    public let value: String

    public init(field: SmartFilterField, operator: SmartFilterOperator, value: String) {
        self.field = field
        self.operator = `operator`
        self.value = value
    }
}

public enum SmartFilterConjunction: String, Codable, Sendable {
    case and
    case or
}

public struct SmartLibraryFilter: Codable, Sendable, Equatable {
    public let conjunction: SmartFilterConjunction
    public let rules: [SmartFilterRule]

    public init(conjunction: SmartFilterConjunction = .and, rules: [SmartFilterRule]) {
        self.conjunction = conjunction
        self.rules = rules
    }

    /// Compiles filter rules to a SQL WHERE clause and SQL arguments safely.
    public func compile() -> (whereClause: String, arguments: StatementArguments, joins: [String]) {
        guard !rules.isEmpty else {
            return ("", StatementArguments(), [])
        }

        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        var joins: Set<String> = []

        for rule in rules {
            if rule.field.requiresTracksJoin {
                joins.insert("LEFT JOIN tracks t ON t.file_id = f.file_id")
            }
            if rule.field.requiresMoviesOrShowsJoin {
                joins.insert("LEFT JOIN movies m ON m.tmdb_id = f.matched_movie")
                joins.insert("LEFT JOIN tv_shows s ON s.show_id = f.matched_show")
            }
            if rule.field.requiresGenreJoin {
                joins.insert("LEFT JOIN media_genres g ON (g.entity_kind = 'movie' AND g.entity_ref = CAST(f.matched_movie AS TEXT)) OR (g.entity_kind = 'show' AND g.entity_ref = f.matched_show)")
            }
            if rule.field.requiresWatchStateJoin {
                joins.insert("LEFT JOIN watch_state w ON (w.entity_kind = 'movie' AND w.entity_ref = CAST(f.matched_movie AS TEXT)) OR (w.entity_kind = 'episode' AND w.entity_ref = f.matched_episode)")
            }

            let col = rule.field.sqlColumn
            switch rule.operator {
            case .equals:
                clauses.append("\(col) = ?")
                args.append(rule.value)
            case .notEquals:
                clauses.append("\(col) != ?")
                args.append(rule.value)
            case .greaterThan:
                clauses.append("\(col) > ?")
                args.append(rule.value)
            case .greaterThanOrEqual:
                clauses.append("\(col) >= ?")
                args.append(rule.value)
            case .lessThan:
                clauses.append("\(col) < ?")
                args.append(rule.value)
            case .lessThanOrEqual:
                clauses.append("\(col) <= ?")
                args.append(rule.value)
            case .contains:
                clauses.append("\(col) LIKE ?")
                args.append("%\(rule.value)%")
            case .inList:
                let items = rule.value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                let placeholders = Array(repeating: "?", count: items.count).joined(separator: ", ")
                clauses.append("\(col) IN (\(placeholders))")
                args.append(contentsOf: items)
            }
        }

        let op = conjunction == .and ? " AND " : " OR "
        let whereClause = "(\(clauses.joined(separator: op)))"
        return (whereClause, StatementArguments(args), Array(joins))
    }
}
