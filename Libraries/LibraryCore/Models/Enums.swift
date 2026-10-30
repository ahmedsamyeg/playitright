import Foundation
import GRDB

public enum SourceKind: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case plex
    case jellyfin
    case emby
    case smb
    case nfs
    case webdav
    case ftp
    case ftps
    case sftp
    case http
    case upnp
    case gdrive
    case dropbox
    case onedrive
    case box
    case local
}

public enum SourceStatus: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case ok
    case unreachable
    case authFailed = "auth-failed"
    case disabled
}

public enum EntityKind: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case movie
    case show
    case season
    case episode
    case person
}

public enum MatchState: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case unmatched
    case needsReview = "needs_review"
    case matched
}

public enum MatchProvenance: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case serverId = "server-id"
    case nfo
    case filename
    case user
}

public enum TrackKind: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case video
    case audio
    case subtitle
    case chapter
}

public enum CreditRole: Codable, Sendable, Hashable, DatabaseValueConvertible {
    case actor
    case guest
    case director
    case producer
    case writer
    case music
    case editor
    case camera
    case selfRole
    case crew(String)

    public var rawValue: String {
        switch self {
        case .actor: return "actor"
        case .guest: return "guest"
        case .director: return "director"
        case .producer: return "producer"
        case .writer: return "writer"
        case .music: return "music"
        case .editor: return "editor"
        case .camera: return "camera"
        case .selfRole: return "self"
        case .crew(let job): return "crew:\(job)"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "actor": self = .actor
        case "guest": self = .guest
        case "director": self = .director
        case "producer": self = .producer
        case "writer": self = .writer
        case "music": self = .music
        case "editor": self = .editor
        case "camera": self = .camera
        case "self": self = .selfRole
        default:
            if rawValue.hasPrefix("crew:") {
                let job = String(rawValue.dropFirst(5))
                self = .crew(job)
            } else {
                return nil
            }
        }
    }

    public var databaseValue: DatabaseValue {
        rawValue.databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> CreditRole? {
        guard let string = String.fromDatabaseValue(dbValue) else { return nil }
        return CreditRole(rawValue: string)
    }
}

public enum GenreKind: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case movie
    case tv
}

public enum ArtworkKind: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case poster
    case backdrop
    case logo
    case fanart
    case still
    case profile
}

public enum SimilarKind: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case movie
    case show
    case person
}
