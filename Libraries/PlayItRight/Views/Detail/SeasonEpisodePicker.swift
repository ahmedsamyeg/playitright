import LibraryCore
import SwiftUI

/// Season selector and episode list with progress bars (doc 06 §2.3).
public struct SeasonEpisodePicker: View {
    public let seasons: [SeasonRecord]
    public let episodes: [EpisodeProgress]
    public let selectedSeason: Int?
    public let onSelectSeason: (Int) -> Void
    public let onPlayEpisode: (EpisodeProgress) -> Void

    public init(
        seasons: [SeasonRecord],
        episodes: [EpisodeProgress],
        selectedSeason: Int?,
        onSelectSeason: @escaping (Int) -> Void,
        onPlayEpisode: @escaping (EpisodeProgress) -> Void
    ) {
        self.seasons = seasons
        self.episodes = episodes
        self.selectedSeason = selectedSeason
        self.onSelectSeason = onSelectSeason
        self.onPlayEpisode = onPlayEpisode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(2)) {
            HStack(alignment: .firstTextBaseline) {
                Text("Episodes")
                    .font(DesignTypography.title2)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                seasonMenu
            }

            LazyVStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
                ForEach(episodes) { progress in
                    EpisodeRow(progress: progress) {
                        onPlayEpisode(progress)
                    }
                }
            }
        }
        .padding(.horizontal, DesignGrid.contentMargin)
    }

    private var seasonMenu: some View {
        Menu {
            ForEach(seasons, id: \.seasonNumber) { season in
                Button(seasonTitle(season)) {
                    onSelectSeason(season.seasonNumber)
                }
            }
        } label: {
            Label(currentSeasonTitle, systemImage: "chevron.down")
                .font(DesignTypography.callout)
        }
    }

    private var currentSeasonTitle: String {
        guard let selectedSeason,
              let season = seasons.first(where: { $0.seasonNumber == selectedSeason }) else {
            return "Season"
        }
        return seasonTitle(season)
    }

    private func seasonTitle(_ season: SeasonRecord) -> String {
        if let title = season.title, !title.isEmpty {
            return title
        }
        return season.seasonNumber == 0
            ? "Specials"
            : "Season \(season.seasonNumber)"
    }
}

private struct EpisodeRow: View {
    let progress: EpisodeProgress
    let action: () -> Void

    var body: some View {
        FocusableCard(
            title: title,
            subtitle: subtitle,
            action: action
        ) {
            HStack(spacing: DesignGrid.spacing(2)) {
                Text("\(progress.episode.episodeNumber)")
                    .font(DesignTypography.title2)
                    .foregroundStyle(DesignTokens.palette.textTertiary.color)
                    .frame(width: 80, alignment: .trailing)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(title)
                            .font(DesignTypography.headline)
                            .foregroundStyle(DesignTokens.palette.textPrimary.color)
                            .lineLimit(1)

                        Spacer()

                        if progress.watched {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(DesignTokens.palette.success.color)
                                .accessibilityLabel("Watched")
                        } else if progress.fraction > 0 {
                            Text("\(Int((progress.fraction * 100).rounded()))%")
                                .font(DesignTypography.caption)
                                .foregroundStyle(DesignTokens.palette.textSecondary.color)
                        }
                    }

                    if let overview = progress.episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(DesignTypography.caption)
                            .foregroundStyle(DesignTokens.palette.textSecondary.color)
                            .lineLimit(2)
                    }

                    if progress.fraction > 0 && !progress.watched {
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .tint(DesignTokens.palette.accent.color)
                    }
                }
            }
            .padding(DesignGrid.spacing(2))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: String {
        progress.episode.title ?? "Episode \(progress.episode.episodeNumber)"
    }

    private var subtitle: String {
        var parts: [String] = []
        if let airDate = progress.episode.airDate {
            parts.append(airDate)
        }
        if let runtime = progress.episode.runtimeMin {
            parts.append("\(runtime) min")
        }
        return parts.joined(separator: " · ")
    }
}
