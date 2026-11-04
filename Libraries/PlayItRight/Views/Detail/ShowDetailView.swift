import LibraryCore
import SwiftUI

/// Rich TV show detail screen with season selector, episode progress, and the
/// "Play Next Unwatched" primary action (doc 05 §2, doc 06 §2.3).
public struct ShowDetailView: View {
    @State private var viewModel: DetailViewModel
    private let onPlay: (DetailPlayTarget) -> Void
    private let onAddToCollection: () -> Void
    private let onShowPipeline: () -> Void
    private let onShowFullCast: () -> Void

    @State private var errorMessage: String?

    public init(
        viewModel: DetailViewModel,
        onPlay: @escaping (DetailPlayTarget) -> Void = { _ in },
        onAddToCollection: @escaping () -> Void = {},
        onShowPipeline: @escaping () -> Void = {},
        onShowFullCast: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onPlay = onPlay
        self.onAddToCollection = onAddToCollection
        self.onShowPipeline = onShowPipeline
        self.onShowFullCast = onShowFullCast
    }

    public var body: some View {
        ZStack {
            DesignTokens.palette.background.color
                .ignoresSafeArea()
            content
        }
        .task {
            await viewModel.load()
        }
        .alert(
            "Playback",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("Loading…")

        case .failed(let message):
            VStack(spacing: DesignGrid.spacing(2)) {
                Text("Show unavailable")
                    .font(DesignTypography.title1)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
                Text(message)
                    .font(DesignTypography.body)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
            }
            .padding(DesignGrid.contentMargin)

        case .loaded:
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: DesignGrid.spacing(4)) {
                    hero
                    actions
                    overview
                    SeasonEpisodePicker(
                        seasons: viewModel.seasons,
                        episodes: viewModel.episodeProgress,
                        selectedSeason: viewModel.selectedSeason,
                        onSelectSeason: { season in
                            Task { await viewModel.selectSeason(season) }
                        },
                        onPlayEpisode: { progress in
                            onPlay(
                                DetailPlayTarget(
                                    entityKind: .episode,
                                    entityRef: progress.episode.episodeRef,
                                    fileId: viewModel.mediaFiles.first?.fileId,
                                    title: progress.episode.title
                                        ?? "Episode \(progress.episode.episodeNumber)"
                                )
                            )
                        }
                    )
                    castShelf
                    trackPreview
                }
                .padding(.bottom, DesignGrid.spacing(5))
            }
        }
    }

    private var hero: some View {
        DetailHero(
            title: viewModel.title,
            subtitle: showSubtitle,
            overview: viewModel.overview,
            backdropPath: viewModel.backdropPath,
            badges: viewModel.badges,
            onShowPipeline: onShowPipeline
        )
    }

    private var actions: some View {
        HStack(spacing: DesignGrid.spacing(2)) {
            Button(playButtonTitle) {
                if let target = viewModel.playTarget {
                    onPlay(target)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.playTarget == nil)

            Button("Mark Watched") {
                Task {
                    do {
                        try await viewModel.markWatched()
                    } catch {
                        errorMessage = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.playTarget == nil)

            Button("Add to Collection") {
                onAddToCollection()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, DesignGrid.contentMargin)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
            if let overview = viewModel.overview, !overview.isEmpty {
                Text(overview)
                    .font(DesignTypography.body)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
                    .frame(maxWidth: 1_400, alignment: .leading)
            }

            if let next = viewModel.nextUnwatchedEpisode {
                Text(
                    "Up next: S\(next.seasonNumber) E\(next.episodeNumber) · \(next.title ?? "Episode \(next.episodeNumber)")"
                )
                .font(DesignTypography.caption)
                .foregroundStyle(DesignTokens.palette.accent.color)
            }
        }
        .padding(.horizontal, DesignGrid.contentMargin)
    }

    @ViewBuilder
    private var castShelf: some View {
        if !viewModel.topCast.isEmpty {
            VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
                DetailCastShelf(cast: viewModel.topCast)

                Button("Full Cast & Crew") {
                    onShowFullCast()
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, DesignGrid.contentMargin)
            }
        }
    }

    @ViewBuilder
    private var trackPreview: some View {
        if !viewModel.audioTracks.isEmpty || !viewModel.subtitleTracks.isEmpty {
            VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
                Text("Tracks")
                    .font(DesignTypography.title2)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)

                HStack(alignment: .top, spacing: DesignGrid.spacing(4)) {
                    if !viewModel.audioTracks.isEmpty {
                        trackColumn(title: "Audio", tracks: viewModel.audioTracks)
                    }
                    if !viewModel.subtitleTracks.isEmpty {
                        trackColumn(title: "Subtitles", tracks: viewModel.subtitleTracks)
                    }
                }
            }
            .padding(.horizontal, DesignGrid.contentMargin)
        }
    }

    private func trackColumn(title: String, tracks: [TrackRecord]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DesignTypography.headline)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)

            ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                Text(trackLabel(track))
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
            }
        }
    }

    private func trackLabel(_ track: TrackRecord) -> String {
        switch track.kind {
        case .audio:
            let codec = (track.codec ?? "Audio").uppercased()
            let layout = track.channelLayout ?? "\(track.channels ?? 2) ch"
            return "\(codec) · \(layout)\(track.lang.map { " · \($0)" } ?? "")"
        case .subtitle:
            let format = track.subtitleFormat?.uppercased() ?? "Subtitle"
            return "\(format)\(track.lang.map { " · \($0)" } ?? "")"
        default:
            return track.codec ?? track.kind.rawValue
        }
    }

    private var showSubtitle: String {
        var parts: [String] = []
        if let firstAir = viewModel.show?.firstAirDate, firstAir.count >= 4 {
            parts.append(String(firstAir.prefix(4)))
        }
        if !viewModel.seasons.isEmpty {
            parts.append("\(viewModel.seasons.count) seasons")
        }
        if let rating = viewModel.show?.ratingScore {
            parts.append(String(format: "%.1f", rating))
        }
        return parts.joined(separator: " · ")
    }

    private var playButtonTitle: String {
        viewModel.nextUnwatchedEpisode == nil
            ? "Play"
            : "Play Next Unwatched"
    }
}
