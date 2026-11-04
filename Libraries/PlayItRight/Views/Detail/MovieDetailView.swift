import LibraryCore
import SwiftUI

/// Rich movie detail screen with hero backdrop, cast, tracks, and actions
/// (doc 05 §2, doc 06 §2.3).
public struct MovieDetailView: View {
    @State private var viewModel: DetailViewModel
    private let onPlay: (DetailPlayTarget) -> Void
    private let onAddToCollection: () -> Void
    private let onShowPipeline: () -> Void

    @State private var errorMessage: String?

    public init(
        viewModel: DetailViewModel,
        onPlay: @escaping (DetailPlayTarget) -> Void = { _ in },
        onAddToCollection: @escaping () -> Void = {},
        onShowPipeline: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onPlay = onPlay
        self.onAddToCollection = onAddToCollection
        self.onShowPipeline = onShowPipeline
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
                Text("Detail unavailable")
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
            subtitle: movieSubtitle,
            overview: viewModel.overview,
            backdropPath: viewModel.backdropPath,
            badges: viewModel.badges,
            progress: viewModel.movieProgress.map { $0.fraction },
            onShowPipeline: onShowPipeline
        )
    }

    private var actions: some View {
        HStack(spacing: DesignGrid.spacing(2)) {
            Button("Play") {
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

            if !viewModel.mediaFiles.isEmpty {
                Text("\(viewModel.mediaFiles.count) file\(viewModel.mediaFiles.count == 1 ? "" : "s") in your library")
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textTertiary.color)
            }
        }
        .padding(.horizontal, DesignGrid.contentMargin)
    }

    @ViewBuilder
    private var castShelf: some View {
        if !viewModel.topCast.isEmpty {
            DetailCastShelf(cast: viewModel.topCast)
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
                        trackColumn(
                            title: "Audio",
                            tracks: viewModel.audioTracks
                        )
                    }
                    if !viewModel.subtitleTracks.isEmpty {
                        trackColumn(
                            title: "Subtitles",
                            tracks: viewModel.subtitleTracks
                        )
                    }
                }
            }
            .padding(.horizontal, DesignGrid.contentMargin)
        }
    }

    private func trackColumn(
        title: String,
        tracks: [TrackRecord]
    ) -> some View {
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

    private var movieSubtitle: String {
        var parts: [String] = []
        if let release = viewModel.movie?.releaseDate, release.count >= 4 {
            parts.append(String(release.prefix(4)))
        }
        if let runtime = viewModel.movie?.runtimeMin {
            parts.append("\(runtime) min")
        }
        if let rating = viewModel.movie?.ratingScore {
            parts.append(String(format: "%.1f", rating))
        }
        return parts.joined(separator: " · ")
    }
}

/// Full-bleed hero shared by movie and show detail screens.
public struct DetailHero: View {
    public let title: String
    public let subtitle: String
    public let overview: String?
    public let backdropPath: String?
    public let badges: [MediaBadge]
    public let progress: Double?
    public let onShowPipeline: () -> Void

    public init(
        title: String,
        subtitle: String,
        overview: String?,
        backdropPath: String?,
        badges: [MediaBadge],
        progress: Double? = nil,
        onShowPipeline: @escaping () -> Void = {}
    ) {
        self.title = title
        self.subtitle = subtitle
        self.overview = overview
        self.backdropPath = backdropPath
        self.badges = badges
        self.progress = progress
        self.onShowPipeline = onShowPipeline
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
                .frame(height: 620)
                .clipped()

            LinearGradient(
                colors: [
                    .clear,
                    DesignTokens.palette.background.color.opacity(0.85),
                    DesignTokens.palette.background.color
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
                Text(title)
                    .font(DesignTypography.hero)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
                    .lineLimit(2)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DesignTypography.body)
                        .foregroundStyle(DesignTokens.palette.textSecondary.color)
                }

                if !badges.isEmpty {
                    Button(action: onShowPipeline) {
                        HStack(spacing: 8) {
                            ForEach(badges) { badge in
                                Text(badge.rawValue)
                                    .font(DesignTypography.badge)
                                    .foregroundStyle(DesignTokens.palette.background.color)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(DesignTokens.palette.textPrimary.color)
                                    .clipShape(Capsule())
                            }
                            Image(systemName: "info.circle")
                                .font(DesignTypography.caption)
                                .foregroundStyle(DesignTokens.palette.textSecondary.color)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the pipeline explanation.")
                }

                if let progress, progress > 0 {
                    ProgressView(value: min(1, max(0, progress)))
                        .progressViewStyle(.linear)
                        .tint(DesignTokens.palette.accent.color)
                        .frame(maxWidth: 600)
                }
            }
            .padding(DesignGrid.contentMargin)
        }
        .frame(maxWidth: .infinity, minHeight: 620, alignment: .bottomLeading)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let backdropPath, let url = URL(string: backdropPath) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [
                DesignTokens.palette.surfaceElevated.color,
                DesignTokens.palette.surface.color
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Top-billed cast shelf with headshot placeholders.
public struct DetailCastShelf: View {
    public let cast: [CreditDetailItem]

    public init(cast: [CreditDetailItem]) {
        self.cast = cast
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
            Text("Cast & Crew")
                .font(DesignTypography.title2)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: DesignGrid.gutter) {
                    ForEach(cast) { credit in
                        VStack(spacing: 6) {
                            headshot(credit)
                            Text(credit.name)
                                .font(DesignTypography.caption)
                                .foregroundStyle(DesignTokens.palette.textPrimary.color)
                                .lineLimit(1)
                            if let character = credit.character, !character.isEmpty {
                                Text(character)
                                    .font(DesignTypography.badge)
                                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 180)
                    }
                }
                .padding(.horizontal, DesignGrid.contentMargin)
            }
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private func headshot(_ credit: CreditDetailItem) -> some View {
        if let path = credit.headshotPath, let url = URL(string: path) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    initials(credit.name)
                }
            }
            .frame(width: 160, height: 160)
            .clipShape(Circle())
        } else {
            initials(credit.name)
        }
    }

    private func initials(_ name: String) -> some View {
        ZStack {
            Circle()
                .fill(DesignTokens.palette.surfaceElevated.color)
            Text(name.prefix(2).uppercased())
                .font(DesignTypography.headline)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)
        }
        .frame(width: 160, height: 160)
    }
}
