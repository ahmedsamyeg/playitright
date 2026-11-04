import Foundation
import LibraryCore
import Observation

/// What a detail screen is showing.
public enum DetailTarget: Sendable, Equatable {
    case movie(tmdbId: Int)
    case show(showId: String)
}

/// Where the primary Play button should resume.
public struct DetailPlayTarget: Sendable, Equatable {
    public let entityKind: EntityKind
    public let entityRef: String
    public let fileId: String?
    public let title: String

    public init(
        entityKind: EntityKind,
        entityRef: String,
        fileId: String?,
        title: String
    ) {
        self.entityKind = entityKind
        self.entityRef = entityRef
        self.fileId = fileId
        self.title = title
    }
}

/// Episode row state including its progress bar (doc 06 §2.3).
public struct EpisodeProgress: Sendable, Equatable, Identifiable {
    public let episode: EpisodeRecord
    public let positionMs: Int64
    public let durationMs: Int64?
    public let watched: Bool

    public var id: String { episode.episodeRef }

    public var fraction: Double {
        guard let durationMs, durationMs > 0 else {
            return 0
        }
        return min(1, max(0, Double(positionMs) / Double(durationMs)))
    }

    public init(
        episode: EpisodeRecord,
        positionMs: Int64,
        durationMs: Int64?,
        watched: Bool
    ) {
        self.episode = episode
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.watched = watched
    }
}

/// Loads movie/show detail metadata, cast, tracks, seasons, episodes, and the
/// next unwatched episode (doc 05 §2, doc 06 §2.3, DB-4).
@MainActor
@Observable
public final class DetailViewModel {
    public enum State: Sendable, Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public let target: DetailTarget
    public let account: String

    public private(set) var state: State = .idle
    public private(set) var movie: MovieRecord?
    public private(set) var show: TVShowRecord?
    public private(set) var mediaFiles: [MediaFileRecord] = []
    public private(set) var cast: [CreditDetailItem] = []
    public private(set) var seasons: [SeasonRecord] = []
    public private(set) var episodes: [EpisodeRecord] = []
    public private(set) var nextUnwatchedEpisode: EpisodeRecord?
    public private(set) var tracks: [TrackRecord] = []
    public private(set) var watchStates: [WatchStateRecord] = []
    public private(set) var backdropPath: String?
    public private(set) var posterPath: String?
    public private(set) var selectedSeason: Int?

    private let reader: MediaDatabaseReader
    private let writer: MediaDatabaseWriter?

    public init(
        reader: MediaDatabaseReader,
        writer: MediaDatabaseWriter? = nil,
        target: DetailTarget,
        account: String = "local"
    ) {
        self.reader = reader
        self.writer = writer
        self.target = target
        self.account = account
    }

    public var title: String {
        movie?.title ?? show?.title ?? ""
    }

    public var overview: String? {
        movie?.overview ?? show?.overview
    }

    public var castHeading: String {
        "Cast & Crew"
    }

    /// Top six billed actors for the detail shelf.
    public var topCast: [CreditDetailItem] {
        Array(
            cast
                .filter { $0.creditRole == .actor }
                .prefix(6)
        )
    }

    public var audioTracks: [TrackRecord] {
        tracks.filter { $0.kind == .audio }
    }

    public var subtitleTracks: [TrackRecord] {
        tracks.filter { $0.kind == .subtitle }
    }

    public var badges: [MediaBadge] {
        MediaBadge.badges(for: tracks)
    }

    /// The primary Play CTA target: the movie itself or the next unwatched
    /// episode for a show.
    public var playTarget: DetailPlayTarget? {
        switch target {
        case .movie(let tmdbId):
            return DetailPlayTarget(
                entityKind: .movie,
                entityRef: String(tmdbId),
                fileId: fileId(forMovie: tmdbId),
                title: movie?.title ?? "Movie"
            )
        case .show:
            guard let episode = nextUnwatchedEpisode else {
                return nil
            }
            return DetailPlayTarget(
                entityKind: .episode,
                entityRef: episode.episodeRef,
                fileId: fileId(forEpisode: episode.episodeRef),
                title: episode.title ?? "Episode \(episode.episodeNumber)"
            )
        }
    }

    public var episodeProgress: [EpisodeProgress] {
        episodes.map { episode in
            let state = watchStates.first {
                $0.entityKind == .episode && $0.entityRef == episode.episodeRef
            }
            let duration = state?.durationMs
                ?? episode.runtimeMin.map { Int64($0 * 60_000) }
            return EpisodeProgress(
                episode: episode,
                positionMs: state?.positionMs ?? 0,
                durationMs: duration,
                watched: state?.watched ?? false
            )
        }
    }

    /// Movie resume progress for the detail hero.
    public var movieProgress: EpisodeProgress? {
        guard let movie else {
            return nil
        }
        let state = watchStates.first {
            $0.entityKind == .movie && $0.entityRef == String(movie.tmdbId)
        }
        guard let state else {
            return nil
        }
        let duration = state.durationMs
            ?? movie.runtimeMin.map { Int64($0 * 60_000) }
        return EpisodeProgress(
            episode: EpisodeRecord(
                showId: "",
                seasonNumber: 0,
                episodeNumber: 0,
                title: movie.title
            ),
            positionMs: state.positionMs,
            durationMs: duration,
            watched: state.watched
        )
    }

    public func load() async {
        guard state == .idle else {
            return
        }
        state = .loading

        let reader = reader
        let target = target
        let account = account

        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try Self.snapshot(
                    reader: reader,
                    target: target,
                    account: account
                )
            }.value
            apply(snapshot)
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func selectSeason(_ seasonNumber: Int) async {
        guard seasons.contains(where: { $0.seasonNumber == seasonNumber }) else {
            return
        }
        selectedSeason = seasonNumber

        guard case .show(let showId) = target else {
            return
        }
        let reader = reader
        do {
            let episodes = try await Task.detached(priority: .userInitiated) {
                try reader.fetchEpisodes(
                    showId: showId,
                    seasonNumber: seasonNumber
                )
            }.value
            self.episodes = episodes
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Marks the movie or the next unwatched episode as watched.
    public func markWatched() async throws {
        guard let writer else {
            throw DetailError.databaseUnavailable
        }
        guard let playTarget else {
            throw DetailError.nothingToWatch
        }

        let reader = reader
        let account = account
        let writerCopy = writer
        let target = target

        _ = try await Task.detached(priority: .userInitiated) {
            try writerCopy.updateWatchProgress(
                account: account,
                entityKind: playTarget.entityKind,
                entityRef: playTarget.entityRef,
                positionMs: 0,
                durationMs: nil,
                watched: true
            )
            let states = try reader.fetchWatchStates(account: account)
            let next: EpisodeRecord?
            if case .show(let showId) = target {
                next = try reader.fetchNextUnwatchedEpisode(
                    showId: showId,
                    account: account
                )
            } else {
                next = nil
            }
            return (states, next)
        }.value

        watchStates = try await Task.detached {
            try reader.fetchWatchStates(account: account)
        }.value

        if case .show(let showId) = target {
            nextUnwatchedEpisode = try await Task.detached {
                try reader.fetchNextUnwatchedEpisode(
                    showId: showId,
                    account: account
                )
            }.value
        }
    }

    // MARK: - Private

    private func fileId(forMovie tmdbId: Int) -> String? {
        mediaFiles.first?.fileId
    }

    private func fileId(forEpisode episodeRef: String) -> String? {
        mediaFiles.first { $0.matchedEpisode == episodeRef }?.fileId
            ?? mediaFiles.first?.fileId
    }

    private func apply(_ snapshot: DetailSnapshot) {
        movie = snapshot.movie
        show = snapshot.show
        mediaFiles = snapshot.mediaFiles
        cast = snapshot.cast
        seasons = snapshot.seasons
        episodes = snapshot.episodes
        nextUnwatchedEpisode = snapshot.nextUnwatched
        tracks = snapshot.tracks
        watchStates = snapshot.watchStates
        backdropPath = snapshot.backdropPath
        posterPath = snapshot.posterPath
        selectedSeason = snapshot.selectedSeason
    }

    nonisolated private static func snapshot(
        reader: MediaDatabaseReader,
        target: DetailTarget,
        account: String
    ) throws -> DetailSnapshot {
        let watchStates = try reader.fetchWatchStates(account: account)

        switch target {
        case .movie(let tmdbId):
            guard let movie = try reader.fetchMovie(tmdbId: tmdbId) else {
                throw DetailError.notFound
            }
            let files = try reader.fetchMediaFiles(movieId: tmdbId)
            let cast = try reader.fetchCastAndCrew(
                entityKind: .movie,
                entityRef: String(tmdbId)
            )
            let tracks = try files.first.map {
                try reader.fetchTracks(fileId: $0.fileId)
            } ?? []
            let backdrop = try reader.fetchArtwork(
                entityKind: .movie,
                entityRef: String(tmdbId),
                kind: .backdrop
            )
            let poster = try reader.fetchArtwork(
                entityKind: .movie,
                entityRef: String(tmdbId),
                kind: .poster
            )
            return DetailSnapshot(
                movie: movie,
                show: nil,
                mediaFiles: files,
                cast: cast,
                seasons: [],
                episodes: [],
                nextUnwatched: nil,
                tracks: tracks,
                watchStates: watchStates,
                backdropPath: backdrop?.localPath,
                posterPath: poster?.localPath,
                selectedSeason: nil
            )

        case .show(let showId):
            guard let show = try reader.fetchShow(showId: showId) else {
                throw DetailError.notFound
            }
            let files = try reader.fetchMediaFiles(showId: showId)
            let cast = try reader.fetchCastAndCrew(
                entityKind: .show,
                entityRef: showId
            )
            let seasons = try reader.fetchSeasons(showId: showId)
            let selectedSeason = seasons.first?.seasonNumber
            let episodes: [EpisodeRecord]
            if let selectedSeason {
                episodes = try reader.fetchEpisodes(
                    showId: showId,
                    seasonNumber: selectedSeason
                )
            } else {
                episodes = []
            }
            let next = try reader.fetchNextUnwatchedEpisode(
                showId: showId,
                account: account
            )
            let tracks = try files.first.map {
                try reader.fetchTracks(fileId: $0.fileId)
            } ?? []
            let backdrop = try reader.fetchArtwork(
                entityKind: .show,
                entityRef: showId,
                kind: .backdrop
            )
            let poster = try reader.fetchArtwork(
                entityKind: .show,
                entityRef: showId,
                kind: .poster
            )
            return DetailSnapshot(
                movie: nil,
                show: show,
                mediaFiles: files,
                cast: cast,
                seasons: seasons,
                episodes: episodes,
                nextUnwatched: next,
                tracks: tracks,
                watchStates: watchStates,
                backdropPath: backdrop?.localPath,
                posterPath: poster?.localPath,
                selectedSeason: selectedSeason
            )
        }
    }
}

public enum DetailError: Error, Sendable, Equatable, LocalizedError {
    case notFound
    case nothingToWatch
    case databaseUnavailable

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "That title is no longer in your library."
        case .nothingToWatch:
            return "There is nothing to play yet."
        case .databaseUnavailable:
            return "The library database is unavailable."
        }
    }
}

private struct DetailSnapshot: Sendable {
    let movie: MovieRecord?
    let show: TVShowRecord?
    let mediaFiles: [MediaFileRecord]
    let cast: [CreditDetailItem]
    let seasons: [SeasonRecord]
    let episodes: [EpisodeRecord]
    let nextUnwatched: EpisodeRecord?
    let tracks: [TrackRecord]
    let watchStates: [WatchStateRecord]
    let backdropPath: String?
    let posterPath: String?
    let selectedSeason: Int?

    nonisolated init(
        movie: MovieRecord?,
        show: TVShowRecord?,
        mediaFiles: [MediaFileRecord],
        cast: [CreditDetailItem],
        seasons: [SeasonRecord],
        episodes: [EpisodeRecord],
        nextUnwatched: EpisodeRecord?,
        tracks: [TrackRecord],
        watchStates: [WatchStateRecord],
        backdropPath: String?,
        posterPath: String?,
        selectedSeason: Int?
    ) {
        self.movie = movie
        self.show = show
        self.mediaFiles = mediaFiles
        self.cast = cast
        self.seasons = seasons
        self.episodes = episodes
        self.nextUnwatched = nextUnwatched
        self.tracks = tracks
        self.watchStates = watchStates
        self.backdropPath = backdropPath
        self.posterPath = posterPath
        self.selectedSeason = selectedSeason
    }
}
