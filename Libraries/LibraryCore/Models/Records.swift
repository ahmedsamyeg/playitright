import Foundation
import GRDB

// MARK: - MetaRecord
public struct MetaRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "meta"

    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

// MARK: - SourceRecord
public struct SourceRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "sources"

    public var sourceId: String
    public var kind: SourceKind
    public var name: String
    public var configRef: String
    public var status: SourceStatus
    public var lastSyncAt: Int64?
    public var etag: String?
    public var lastError: String?
    public var addedAt: Int64

    public var id: String { sourceId }

    public enum Columns {
        public static let sourceId = Column(CodingKeys.sourceId)
        public static let kind = Column(CodingKeys.kind)
        public static let name = Column(CodingKeys.name)
        public static let configRef = Column(CodingKeys.configRef)
        public static let status = Column(CodingKeys.status)
        public static let lastSyncAt = Column(CodingKeys.lastSyncAt)
        public static let etag = Column(CodingKeys.etag)
        public static let lastError = Column(CodingKeys.lastError)
        public static let addedAt = Column(CodingKeys.addedAt)
    }

    enum CodingKeys: String, CodingKey {
        case sourceId = "source_id"
        case kind
        case name
        case configRef = "config_ref"
        case status
        case lastSyncAt = "last_sync_at"
        case etag
        case lastError = "last_error"
        case addedAt = "added_at"
    }

    public init(
        sourceId: String,
        kind: SourceKind,
        name: String,
        configRef: String,
        status: SourceStatus = .ok,
        lastSyncAt: Int64? = nil,
        etag: String? = nil,
        lastError: String? = nil,
        addedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.sourceId = sourceId
        self.kind = kind
        self.name = name
        self.configRef = configRef
        self.status = status
        self.lastSyncAt = lastSyncAt
        self.etag = etag
        self.lastError = lastError
        self.addedAt = addedAt
    }
}

// MARK: - MovieRecord
public struct MovieRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "movies"

    public var tmdbId: Int
    public var title: String
    public var originalTitle: String?
    public var originalLanguage: String?
    public var alternativeTitles: String? // JSON [{"lang","title"}]
    public var releaseDate: String?      // ISO 8601 date
    public var status: String?
    public var runtimeMin: Int?
    public var overview: String?
    public var tagline: String?
    public var ratingScore: Double?
    public var ratingVotes: Int?
    public var homepage: String?
    public var imdbId: String?
    public var scrapedAt: Int64?
    public var scrapedSource: String?

    public var id: Int { tmdbId }

    public enum Columns {
        public static let tmdbId = Column(CodingKeys.tmdbId)
        public static let title = Column(CodingKeys.title)
        public static let originalTitle = Column(CodingKeys.originalTitle)
        public static let originalLanguage = Column(CodingKeys.originalLanguage)
        public static let alternativeTitles = Column(CodingKeys.alternativeTitles)
        public static let releaseDate = Column(CodingKeys.releaseDate)
        public static let status = Column(CodingKeys.status)
        public static let runtimeMin = Column(CodingKeys.runtimeMin)
        public static let overview = Column(CodingKeys.overview)
        public static let tagline = Column(CodingKeys.tagline)
        public static let ratingScore = Column(CodingKeys.ratingScore)
        public static let ratingVotes = Column(CodingKeys.ratingVotes)
        public static let homepage = Column(CodingKeys.homepage)
        public static let imdbId = Column(CodingKeys.imdbId)
        public static let scrapedAt = Column(CodingKeys.scrapedAt)
        public static let scrapedSource = Column(CodingKeys.scrapedSource)
    }

    enum CodingKeys: String, CodingKey {
        case tmdbId = "tmdb_id"
        case title
        case originalTitle = "original_title"
        case originalLanguage = "original_language"
        case alternativeTitles = "alternative_titles"
        case releaseDate = "release_date"
        case status
        case runtimeMin = "runtime_min"
        case overview
        case tagline
        case ratingScore = "rating_score"
        case ratingVotes = "rating_votes"
        case homepage
        case imdbId = "imdb_id"
        case scrapedAt = "scraped_at"
        case scrapedSource = "scraped_source"
    }

    public init(
        tmdbId: Int,
        title: String,
        originalTitle: String? = nil,
        originalLanguage: String? = nil,
        alternativeTitles: String? = nil,
        releaseDate: String? = nil,
        status: String? = nil,
        runtimeMin: Int? = nil,
        overview: String? = nil,
        tagline: String? = nil,
        ratingScore: Double? = nil,
        ratingVotes: Int? = nil,
        homepage: String? = nil,
        imdbId: String? = nil,
        scrapedAt: Int64? = nil,
        scrapedSource: String? = nil
    ) {
        self.tmdbId = tmdbId
        self.title = title
        self.originalTitle = originalTitle
        self.originalLanguage = originalLanguage
        self.alternativeTitles = alternativeTitles
        self.releaseDate = releaseDate
        self.status = status
        self.runtimeMin = runtimeMin
        self.overview = overview
        self.tagline = tagline
        self.ratingScore = ratingScore
        self.ratingVotes = ratingVotes
        self.homepage = homepage
        self.imdbId = imdbId
        self.scrapedAt = scrapedAt
        self.scrapedSource = scrapedSource
    }
}

// MARK: - TVShowRecord
public struct TVShowRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "tv_shows"

    public var showId: String             // e.g. 'tmdb:1396' or 'tvrage:81081'
    public var tmdbId: Int?
    public var tvdbId: Int?
    public var title: String
    public var originalTitle: String?
    public var originalLanguage: String?
    public var alternativeTitles: String?
    public var firstAirDate: String?
    public var lastAirDate: String?
    public var status: String?
    public var overview: String?
    public var ratingScore: Double?
    public var ratingVotes: Int?
    public var homepage: String?
    public var imdbId: String?
    public var scrapedAt: Int64?
    public var scrapedSource: String?

    public var id: String { showId }

    public enum Columns {
        public static let showId = Column(CodingKeys.showId)
        public static let tmdbId = Column(CodingKeys.tmdbId)
        public static let tvdbId = Column(CodingKeys.tvdbId)
        public static let title = Column(CodingKeys.title)
        public static let originalTitle = Column(CodingKeys.originalTitle)
        public static let originalLanguage = Column(CodingKeys.originalLanguage)
        public static let alternativeTitles = Column(CodingKeys.alternativeTitles)
        public static let firstAirDate = Column(CodingKeys.firstAirDate)
        public static let lastAirDate = Column(CodingKeys.lastAirDate)
        public static let status = Column(CodingKeys.status)
        public static let overview = Column(CodingKeys.overview)
        public static let ratingScore = Column(CodingKeys.ratingScore)
        public static let ratingVotes = Column(CodingKeys.ratingVotes)
        public static let homepage = Column(CodingKeys.homepage)
        public static let imdbId = Column(CodingKeys.imdbId)
        public static let scrapedAt = Column(CodingKeys.scrapedAt)
        public static let scrapedSource = Column(CodingKeys.scrapedSource)
    }

    enum CodingKeys: String, CodingKey {
        case showId = "show_id"
        case tmdbId = "tmdb_id"
        case tvdbId = "tvdb_id"
        case title
        case originalTitle = "original_title"
        case originalLanguage = "original_language"
        case alternativeTitles = "alternative_titles"
        case firstAirDate = "first_air_date"
        case lastAirDate = "last_air_date"
        case status
        case overview
        case ratingScore = "rating_score"
        case ratingVotes = "rating_votes"
        case homepage
        case imdbId = "imdb_id"
        case scrapedAt = "scraped_at"
        case scrapedSource = "scraped_source"
    }

    public init(
        showId: String,
        tmdbId: Int? = nil,
        tvdbId: Int? = nil,
        title: String,
        originalTitle: String? = nil,
        originalLanguage: String? = nil,
        alternativeTitles: String? = nil,
        firstAirDate: String? = nil,
        lastAirDate: String? = nil,
        status: String? = nil,
        overview: String? = nil,
        ratingScore: Double? = nil,
        ratingVotes: Int? = nil,
        homepage: String? = nil,
        imdbId: String? = nil,
        scrapedAt: Int64? = nil,
        scrapedSource: String? = nil
    ) {
        self.showId = showId
        self.tmdbId = tmdbId
        self.tvdbId = tvdbId
        self.title = title
        self.originalTitle = originalTitle
        self.originalLanguage = originalLanguage
        self.alternativeTitles = alternativeTitles
        self.firstAirDate = firstAirDate
        self.lastAirDate = lastAirDate
        self.status = status
        self.overview = overview
        self.ratingScore = ratingScore
        self.ratingVotes = ratingVotes
        self.homepage = homepage
        self.imdbId = imdbId
        self.scrapedAt = scrapedAt
        self.scrapedSource = scrapedSource
    }
}

// MARK: - SeasonRecord
public struct SeasonRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "seasons"

    public var showId: String
    public var seasonNumber: Int
    public var title: String?
    public var overview: String?
    public var airDate: String?

    public enum Columns {
        public static let showId = Column(CodingKeys.showId)
        public static let seasonNumber = Column(CodingKeys.seasonNumber)
        public static let title = Column(CodingKeys.title)
        public static let overview = Column(CodingKeys.overview)
        public static let airDate = Column(CodingKeys.airDate)
    }

    enum CodingKeys: String, CodingKey {
        case showId = "show_id"
        case seasonNumber = "season_number"
        case title
        case overview
        case airDate = "air_date"
    }

    public init(
        showId: String,
        seasonNumber: Int,
        title: String? = nil,
        overview: String? = nil,
        airDate: String? = nil
    ) {
        self.showId = showId
        self.seasonNumber = seasonNumber
        self.title = title
        self.overview = overview
        self.airDate = airDate
    }
}

// MARK: - EpisodeRecord
public struct EpisodeRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "episodes"

    public var showId: String
    public var seasonNumber: Int
    public var episodeNumber: Int
    public var title: String?
    public var overview: String?
    public var airDate: String?
    public var runtimeMin: Int?
    public var voteAverage: Double?
    public var tmdbEpisodeId: Int?

    public var episodeRef: String {
        EntityRef.episodeRef(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
    }

    public enum Columns {
        public static let showId = Column(CodingKeys.showId)
        public static let seasonNumber = Column(CodingKeys.seasonNumber)
        public static let episodeNumber = Column(CodingKeys.episodeNumber)
        public static let title = Column(CodingKeys.title)
        public static let overview = Column(CodingKeys.overview)
        public static let airDate = Column(CodingKeys.airDate)
        public static let runtimeMin = Column(CodingKeys.runtimeMin)
        public static let voteAverage = Column(CodingKeys.voteAverage)
        public static let tmdbEpisodeId = Column(CodingKeys.tmdbEpisodeId)
    }

    enum CodingKeys: String, CodingKey {
        case showId = "show_id"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case title
        case overview
        case airDate = "air_date"
        case runtimeMin = "runtime_min"
        case voteAverage = "vote_average"
        case tmdbEpisodeId = "tmdb_episode_id"
    }

    public init(
        showId: String,
        seasonNumber: Int,
        episodeNumber: Int,
        title: String? = nil,
        overview: String? = nil,
        airDate: String? = nil,
        runtimeMin: Int? = nil,
        voteAverage: Double? = nil,
        tmdbEpisodeId: Int? = nil
    ) {
        self.showId = showId
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.title = title
        self.overview = overview
        self.airDate = airDate
        self.runtimeMin = runtimeMin
        self.voteAverage = voteAverage
        self.tmdbEpisodeId = tmdbEpisodeId
    }
}

// MARK: - IdentifierRecord
public struct IdentifierRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "identifiers"

    public var entityKind: EntityKind
    public var entityRef: String
    public var provider: String
    public var id: String

    public enum Columns {
        public static let entityKind = Column(CodingKeys.entityKind)
        public static let entityRef = Column(CodingKeys.entityRef)
        public static let provider = Column(CodingKeys.provider)
        public static let id = Column(CodingKeys.id)
    }

    enum CodingKeys: String, CodingKey {
        case entityKind = "entity_kind"
        case entityRef = "entity_ref"
        case provider
        case id
    }

    public init(
        entityKind: EntityKind,
        entityRef: String,
        provider: String,
        id: String
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.provider = provider
        self.id = id
    }
}

// MARK: - MediaFileRecord
public struct MediaFileRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "media_files"

    public var fileId: String
    public var sourceId: String
    public var path: String
    public var uri: String
    public var container: String?
    public var sizeBytes: Int64?
    public var mtime: Int64?
    public var durationMs: Int64?
    public var matchState: MatchState
    public var matchedMovie: Int?
    public var matchedEpisode: String?
    public var matchedShow: String?
    public var matchProvenance: MatchProvenance?
    public var addedAt: Int64

    public var id: String { fileId }

    public enum Columns {
        public static let fileId = Column(CodingKeys.fileId)
        public static let sourceId = Column(CodingKeys.sourceId)
        public static let path = Column(CodingKeys.path)
        public static let uri = Column(CodingKeys.uri)
        public static let container = Column(CodingKeys.container)
        public static let sizeBytes = Column(CodingKeys.sizeBytes)
        public static let mtime = Column(CodingKeys.mtime)
        public static let durationMs = Column(CodingKeys.durationMs)
        public static let matchState = Column(CodingKeys.matchState)
        public static let matchedMovie = Column(CodingKeys.matchedMovie)
        public static let matchedEpisode = Column(CodingKeys.matchedEpisode)
        public static let matchedShow = Column(CodingKeys.matchedShow)
        public static let matchProvenance = Column(CodingKeys.matchProvenance)
        public static let addedAt = Column(CodingKeys.addedAt)
    }

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case sourceId = "source_id"
        case path
        case uri
        case container
        case sizeBytes = "size_bytes"
        case mtime
        case durationMs = "duration_ms"
        case matchState = "match_state"
        case matchedMovie = "matched_movie"
        case matchedEpisode = "matched_episode"
        case matchedShow = "matched_show"
        case matchProvenance = "match_provenance"
        case addedAt = "added_at"
    }

    public init(
        fileId: String,
        sourceId: String,
        path: String,
        uri: String,
        container: String? = nil,
        sizeBytes: Int64? = nil,
        mtime: Int64? = nil,
        durationMs: Int64? = nil,
        matchState: MatchState = .unmatched,
        matchedMovie: Int? = nil,
        matchedEpisode: String? = nil,
        matchedShow: String? = nil,
        matchProvenance: MatchProvenance? = nil,
        addedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.fileId = fileId
        self.sourceId = sourceId
        self.path = path
        self.uri = uri
        self.container = container
        self.sizeBytes = sizeBytes
        self.mtime = mtime
        self.durationMs = durationMs
        self.matchState = matchState
        self.matchedMovie = matchedMovie
        self.matchedEpisode = matchedEpisode
        self.matchedShow = matchedShow
        self.matchProvenance = matchProvenance
        self.addedAt = addedAt
    }
}

// MARK: - TrackRecord
public struct TrackRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "tracks"

    public var fileId: String
    public var kind: TrackKind
    public var index: Int
    public var title: String?
    public var lang: String?
    public var isDefault: Bool
    public var isForced: Bool
    public var sampled: Bool

    // Video
    public var codec: String?
    public var profile: String?
    public var level: String?
    public var width: Int?
    public var height: Int?
    public var fpsNum: Int?
    public var fpsDen: Int?
    public var bitDepth: Int?
    public var pixFmt: String?
    public var colorPrimaries: String?
    public var colorTrc: String?
    public var colorSpace: String?
    public var hdrFormat: String?
    public var sdciPresent: Bool?

    // Audio
    public var channels: Int?
    public var channelLayout: String?
    public var sampleRate: Int?
    public var audioBitDepth: Int?

    // Subtitle
    public var subtitleFormat: String?

    public enum Columns {
        public static let fileId = Column(CodingKeys.fileId)
        public static let kind = Column(CodingKeys.kind)
        public static let index = Column("index")
        public static let title = Column(CodingKeys.title)
        public static let lang = Column(CodingKeys.lang)
        public static let isDefault = Column(CodingKeys.isDefault)
        public static let isForced = Column(CodingKeys.isForced)
        public static let sampled = Column(CodingKeys.sampled)
        public static let codec = Column(CodingKeys.codec)
        public static let width = Column(CodingKeys.width)
        public static let height = Column(CodingKeys.height)
        public static let hdrFormat = Column(CodingKeys.hdrFormat)
        public static let channels = Column(CodingKeys.channels)
        public static let subtitleFormat = Column(CodingKeys.subtitleFormat)
    }

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case kind
        case index
        case title
        case lang
        case isDefault = "is_default"
        case isForced = "is_forced"
        case sampled
        case codec
        case profile
        case level
        case width
        case height
        case fpsNum = "fps_num"
        case fpsDen = "fps_den"
        case bitDepth = "bit_depth"
        case pixFmt = "pix_fmt"
        case colorPrimaries = "color_primaries"
        case colorTrc = "color_trc"
        case colorSpace = "color_space"
        case hdrFormat = "hdr_format"
        case sdciPresent = "sdci_present"
        case channels
        case channelLayout = "channel_layout"
        case sampleRate = "sample_rate"
        case audioBitDepth = "audio_bit_depth"
        case subtitleFormat = "subtitle_format"
    }

    public init(
        fileId: String,
        kind: TrackKind,
        index: Int,
        title: String? = nil,
        lang: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        sampled: Bool = true,
        codec: String? = nil,
        profile: String? = nil,
        level: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fpsNum: Int? = nil,
        fpsDen: Int? = nil,
        bitDepth: Int? = nil,
        pixFmt: String? = nil,
        colorPrimaries: String? = nil,
        colorTrc: String? = nil,
        colorSpace: String? = nil,
        hdrFormat: String? = nil,
        sdciPresent: Bool? = nil,
        channels: Int? = nil,
        channelLayout: String? = nil,
        sampleRate: Int? = nil,
        audioBitDepth: Int? = nil,
        subtitleFormat: String? = nil
    ) {
        self.fileId = fileId
        self.kind = kind
        self.index = index
        self.title = title
        self.lang = lang
        self.isDefault = isDefault
        self.isForced = isForced
        self.sampled = sampled
        self.codec = codec
        self.profile = profile
        self.level = level
        self.width = width
        self.height = height
        self.fpsNum = fpsNum
        self.fpsDen = fpsDen
        self.bitDepth = bitDepth
        self.pixFmt = pixFmt
        self.colorPrimaries = colorPrimaries
        self.colorTrc = colorTrc
        self.colorSpace = colorSpace
        self.hdrFormat = hdrFormat
        self.sdciPresent = sdciPresent
        self.channels = channels
        self.channelLayout = channelLayout
        self.sampleRate = sampleRate
        self.audioBitDepth = audioBitDepth
        self.subtitleFormat = subtitleFormat
    }
}

// MARK: - PersonRecord
public struct PersonRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "people"

    public var personId: String           // e.g. 'tmdb:32231' or 'local:<slug>'
    public var tmdbId: Int?
    public var name: String
    public var gender: String?
    public var birthday: String?
    public var deathday: String?
    public var knownForDepartment: String?
    public var biography: String?
    public var homepage: String?
    public var socials: String?          // JSON
    public var popularity: Double?
    public var scrapedAt: Int64?
    public var scrapedSource: String?

    public var id: String { personId }

    public enum Columns {
        public static let personId = Column(CodingKeys.personId)
        public static let tmdbId = Column(CodingKeys.tmdbId)
        public static let name = Column(CodingKeys.name)
        public static let popularity = Column(CodingKeys.popularity)
    }

    enum CodingKeys: String, CodingKey {
        case personId = "person_id"
        case tmdbId = "tmdb_id"
        case name
        case gender
        case birthday
        case deathday
        case knownForDepartment = "known_for_department"
        case biography
        case homepage
        case socials
        case popularity
        case scrapedAt = "scraped_at"
        case scrapedSource = "scraped_source"
    }

    public init(
        personId: String,
        tmdbId: Int? = nil,
        name: String,
        gender: String? = nil,
        birthday: String? = nil,
        deathday: String? = nil,
        knownForDepartment: String? = nil,
        biography: String? = nil,
        homepage: String? = nil,
        socials: String? = nil,
        popularity: Double? = nil,
        scrapedAt: Int64? = nil,
        scrapedSource: String? = nil
    ) {
        self.personId = personId
        self.tmdbId = tmdbId
        self.name = name
        self.gender = gender
        self.birthday = birthday
        self.deathday = deathday
        self.knownForDepartment = knownForDepartment
        self.biography = biography
        self.homepage = homepage
        self.socials = socials
        self.popularity = popularity
        self.scrapedAt = scrapedAt
        self.scrapedSource = scrapedSource
    }
}

// MARK: - CreditRecord
public struct CreditRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "credits"

    public var entityKind: EntityKind
    public var entityRef: String
    public var personId: String
    public var creditRole: CreditRole
    public var character: String?
    public var job: String?
    public var ord: Int

    public enum Columns {
        public static let entityKind = Column(CodingKeys.entityKind)
        public static let entityRef = Column(CodingKeys.entityRef)
        public static let personId = Column(CodingKeys.personId)
        public static let creditRole = Column(CodingKeys.creditRole)
        public static let character = Column(CodingKeys.character)
        public static let job = Column(CodingKeys.job)
        public static let ord = Column(CodingKeys.ord)
    }

    enum CodingKeys: String, CodingKey {
        case entityKind = "entity_kind"
        case entityRef = "entity_ref"
        case personId = "person_id"
        case creditRole = "credit_role"
        case character
        case job
        case ord
    }

    public init(
        entityKind: EntityKind,
        entityRef: String,
        personId: String,
        creditRole: CreditRole,
        character: String? = nil,
        job: String? = nil,
        ord: Int
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.personId = personId
        self.creditRole = creditRole
        self.character = character
        self.job = job
        self.ord = ord
    }
}

// MARK: - GenreRecord
public struct GenreRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "genres"

    public var kind: GenreKind
    public var genreId: Int
    public var name: String

    public enum Columns {
        public static let kind = Column(CodingKeys.kind)
        public static let genreId = Column(CodingKeys.genreId)
        public static let name = Column(CodingKeys.name)
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case genreId = "genre_id"
        case name
    }

    public init(kind: GenreKind, genreId: Int, name: String) {
        self.kind = kind
        self.genreId = genreId
        self.name = name
    }
}

// MARK: - MediaGenreRecord
public struct MediaGenreRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "media_genres"

    public var entityKind: EntityKind
    public var entityRef: String
    public var genreId: Int
    public var rank: Int

    public enum Columns {
        public static let entityKind = Column(CodingKeys.entityKind)
        public static let entityRef = Column(CodingKeys.entityRef)
        public static let genreId = Column(CodingKeys.genreId)
        public static let rank = Column(CodingKeys.rank)
    }

    enum CodingKeys: String, CodingKey {
        case entityKind = "entity_kind"
        case entityRef = "entity_ref"
        case genreId = "genre_id"
        case rank
    }

    public init(entityKind: EntityKind, entityRef: String, genreId: Int, rank: Int) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.genreId = genreId
        self.rank = rank
    }
}

// MARK: - AccountRecord
public struct AccountRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "accounts"

    public var accountId: String
    public var displayName: String
    public var isCloud: Bool
    public var cloudRef: String?

    public var id: String { accountId }

    public enum Columns {
        public static let accountId = Column(CodingKeys.accountId)
        public static let displayName = Column(CodingKeys.displayName)
        public static let isCloud = Column(CodingKeys.isCloud)
        public static let cloudRef = Column(CodingKeys.cloudRef)
    }

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case displayName = "display_name"
        case isCloud = "is_cloud"
        case cloudRef = "cloud_ref"
    }

    public init(
        accountId: String,
        displayName: String,
        isCloud: Bool = false,
        cloudRef: String? = nil
    ) {
        self.accountId = accountId
        self.displayName = displayName
        self.isCloud = isCloud
        self.cloudRef = cloudRef
    }
}

// MARK: - WatchStateRecord
public struct WatchStateRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "watch_state"

    public var entityKind: EntityKind
    public var entityRef: String
    public var account: String
    public var positionMs: Int64
    public var durationMs: Int64?
    public var watched: Bool
    public var lastWatchedAt: Int64?
    public var resumeAt: Int64?
    public var userRating: Int?
    public var trackChoices: String?    // JSON {audio: idx, subtitle: idx}
    public var lastPlan: String?        // JSON PipelinePlan summary
    public var updatedAt: Int64

    public enum Columns {
        public static let entityKind = Column(CodingKeys.entityKind)
        public static let entityRef = Column(CodingKeys.entityRef)
        public static let account = Column(CodingKeys.account)
        public static let positionMs = Column(CodingKeys.positionMs)
        public static let durationMs = Column(CodingKeys.durationMs)
        public static let watched = Column(CodingKeys.watched)
        public static let lastWatchedAt = Column(CodingKeys.lastWatchedAt)
        public static let resumeAt = Column(CodingKeys.resumeAt)
        public static let userRating = Column(CodingKeys.userRating)
        public static let trackChoices = Column(CodingKeys.trackChoices)
        public static let lastPlan = Column(CodingKeys.lastPlan)
        public static let updatedAt = Column(CodingKeys.updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case entityKind = "entity_kind"
        case entityRef = "entity_ref"
        case account
        case positionMs = "position_ms"
        case durationMs = "duration_ms"
        case watched
        case lastWatchedAt = "last_watched_at"
        case resumeAt = "resume_at"
        case userRating = "user_rating"
        case trackChoices = "track_choices"
        case lastPlan = "last_plan"
        case updatedAt = "updated_at"
    }

    public init(
        entityKind: EntityKind,
        entityRef: String,
        account: String,
        positionMs: Int64 = 0,
        durationMs: Int64? = nil,
        watched: Bool = false,
        lastWatchedAt: Int64? = nil,
        resumeAt: Int64? = nil,
        userRating: Int? = nil,
        trackChoices: String? = nil,
        lastPlan: String? = nil,
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.account = account
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.watched = watched
        self.lastWatchedAt = lastWatchedAt
        self.resumeAt = resumeAt
        self.userRating = userRating
        self.trackChoices = trackChoices
        self.lastPlan = lastPlan
        self.updatedAt = updatedAt
    }
}

// MARK: - Organization Records

public struct LibraryRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "libraries"

    public var id: String
    public var name: String
    public var sourceRefs: String        // JSON array [source_id, ...]
    public var visibility: String
    public var ord: Int
    public var autoRule: String?         // JSON predicate

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let sourceRefs = Column(CodingKeys.sourceRefs)
        public static let visibility = Column(CodingKeys.visibility)
        public static let ord = Column(CodingKeys.ord)
        public static let autoRule = Column(CodingKeys.autoRule)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sourceRefs = "source_refs"
        case visibility
        case ord
        case autoRule = "auto_rule"
    }

    public init(
        id: String,
        name: String,
        sourceRefs: String,
        visibility: String = "visible",
        ord: Int,
        autoRule: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceRefs = sourceRefs
        self.visibility = visibility
        self.ord = ord
        self.autoRule = autoRule
    }
}

public struct CollectionRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "collections"

    public var id: String
    public var name: String
    public var artworkRef: String?
    public var ord: Int

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let artworkRef = Column(CodingKeys.artworkRef)
        public static let ord = Column(CodingKeys.ord)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case artworkRef = "artwork_ref"
        case ord
    }

    public init(id: String, name: String, artworkRef: String? = nil, ord: Int) {
        self.id = id
        self.name = name
        self.artworkRef = artworkRef
        self.ord = ord
    }
}

public struct CollectionItemRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "collection_items"

    public var collectionId: String
    public var entityKind: EntityKind
    public var entityRef: String
    public var fileId: String?
    public var addedAt: Int64

    public enum Columns {
        public static let collectionId = Column(CodingKeys.collectionId)
        public static let entityKind = Column(CodingKeys.entityKind)
        public static let entityRef = Column(CodingKeys.entityRef)
        public static let fileId = Column(CodingKeys.fileId)
        public static let addedAt = Column(CodingKeys.addedAt)
    }

    enum CodingKeys: String, CodingKey {
        case collectionId = "collection_id"
        case entityKind = "entity_kind"
        case entityRef = "entity_ref"
        case fileId = "file_id"
        case addedAt = "added_at"
    }

    public init(
        collectionId: String,
        entityKind: EntityKind,
        entityRef: String,
        fileId: String? = nil,
        addedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.collectionId = collectionId
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.fileId = fileId
        self.addedAt = addedAt
    }
}

public struct PlaylistRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "playlists"

    public var id: String
    public var name: String
    public var shuffle: Bool
    public var loop: Bool
    public var ord: Int

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let shuffle = Column(CodingKeys.shuffle)
        public static let loop = Column(CodingKeys.loop)
        public static let ord = Column(CodingKeys.ord)
    }

    public init(id: String, name: String, shuffle: Bool = false, loop: Bool = false, ord: Int) {
        self.id = id
        self.name = name
        self.shuffle = shuffle
        self.loop = loop
        self.ord = ord
    }
}

public struct PlaylistItemRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "playlist_items"

    public var playlistId: String
    public var ord: Int
    public var entityKind: EntityKind
    public var entityRef: String
    public var fileId: String?

    public enum Columns {
        public static let playlistId = Column(CodingKeys.playlistId)
        public static let ord = Column(CodingKeys.ord)
        public static let entityKind = Column(CodingKeys.entityKind)
        public static let entityRef = Column(CodingKeys.entityRef)
        public static let fileId = Column(CodingKeys.fileId)
    }

    enum CodingKeys: String, CodingKey {
        case playlistId = "playlist_id"
        case ord
        case entityKind = "entity_kind"
        case entityRef = "entity_ref"
        case fileId = "file_id"
    }

    public init(
        playlistId: String,
        ord: Int,
        entityKind: EntityKind,
        entityRef: String,
        fileId: String? = nil
    ) {
        self.playlistId = playlistId
        self.ord = ord
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.fileId = fileId
    }
}

public struct PinRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "pins"

    public var entityKind: EntityKind
    public var entityRef: String
    public var fileId: String?
    public var ord: Int

    public enum Columns {
        public static let entityKind = Column(CodingKeys.entityKind)
        public static let entityRef = Column(CodingKeys.entityRef)
        public static let fileId = Column(CodingKeys.fileId)
        public static let ord = Column(CodingKeys.ord)
    }

    enum CodingKeys: String, CodingKey {
        case entityKind = "entity_kind"
        case entityRef = "entity_ref"
        case fileId = "file_id"
        case ord
    }

    public init(
        entityKind: EntityKind,
        entityRef: String,
        fileId: String? = nil,
        ord: Int
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.fileId = fileId
        self.ord = ord
    }
}

public struct SmartLibraryRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "smart_libraries"

    public var id: String
    public var name: String
    public var filters: String           // JSON predicate
    public var ord: Int

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let filters = Column(CodingKeys.filters)
        public static let ord = Column(CodingKeys.ord)
    }

    public init(id: String, name: String, filters: String, ord: Int) {
        self.id = id
        self.name = name
        self.filters = filters
        self.ord = ord
    }
}

public struct SimilarRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "similar"

    public var entityKind: EntityKind
    public var entityRef: String
    public var simKind: SimilarKind
    public var simRef: String
    public var rank: Int

    public enum Columns {
        public static let entityKind = Column(CodingKeys.entityKind)
        public static let entityRef = Column(CodingKeys.entityRef)
        public static let simKind = Column(CodingKeys.simKind)
        public static let simRef = Column(CodingKeys.simRef)
        public static let rank = Column(CodingKeys.rank)
    }

    enum CodingKeys: String, CodingKey {
        case entityKind = "entity_kind"
        case entityRef = "entity_ref"
        case simKind = "sim_kind"
        case simRef = "sim_ref"
        case rank
    }

    public init(
        entityKind: EntityKind,
        entityRef: String,
        simKind: SimilarKind,
        simRef: String,
        rank: Int
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.simKind = simKind
        self.simRef = simRef
        self.rank = rank
    }
}

// MARK: - ArtworkRecord
public struct ArtworkRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "artwork"

    public var entityKind: EntityKind
    public var entityRef: String
    public var kind: ArtworkKind
    public var provider: String
    public var variant: String
    public var localPath: String?
    public var w: Int?
    public var h: Int?
    public var fetchedAt: Int64?

    public enum Columns {
        public static let entityKind = Column(CodingKeys.entityKind)
        public static let entityRef = Column(CodingKeys.entityRef)
        public static let kind = Column(CodingKeys.kind)
        public static let provider = Column(CodingKeys.provider)
        public static let variant = Column(CodingKeys.variant)
        public static let localPath = Column(CodingKeys.localPath)
        public static let w = Column(CodingKeys.w)
        public static let h = Column(CodingKeys.h)
        public static let fetchedAt = Column(CodingKeys.fetchedAt)
    }

    enum CodingKeys: String, CodingKey {
        case entityKind = "entity_kind"
        case entityRef = "entity_ref"
        case kind
        case provider
        case variant
        case localPath = "local_path"
        case w
        case h
        case fetchedAt = "fetched_at"
    }

    public init(
        entityKind: EntityKind,
        entityRef: String,
        kind: ArtworkKind,
        provider: String,
        variant: String,
        localPath: String? = nil,
        w: Int? = nil,
        h: Int? = nil,
        fetchedAt: Int64? = nil
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.kind = kind
        self.provider = provider
        self.variant = variant
        self.localPath = localPath
        self.w = w
        self.h = h
        self.fetchedAt = fetchedAt
    }
}

// MARK: - SearchIndexRecord
public struct SearchIndexRecord: Codable, FetchableRecord, PersistableRecord, TableRecord, Sendable, Equatable {
    public static let databaseTableName = "search_index"

    public var entityKind: EntityKind
    public var entityRef: String
    public var title: String?
    public var altTitles: String?
    public var overview: String?
    public var peopleNames: String?

    public enum Columns {
        public static let entityKind = Column("entity_kind")
        public static let entityRef = Column("entity_ref")
        public static let title = Column("title")
        public static let altTitles = Column("alt_titles")
        public static let overview = Column("overview")
        public static let peopleNames = Column("people_names")
    }

    enum CodingKeys: String, CodingKey {
        case entityKind = "entity_kind"
        case entityRef = "entity_ref"
        case title
        case altTitles = "alt_titles"
        case overview
        case peopleNames = "people_names"
    }

    public init(
        entityKind: EntityKind,
        entityRef: String,
        title: String? = nil,
        altTitles: String? = nil,
        overview: String? = nil,
        peopleNames: String? = nil
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.title = title
        self.altTitles = altTitles
        self.overview = overview
        self.peopleNames = peopleNames
    }
}
