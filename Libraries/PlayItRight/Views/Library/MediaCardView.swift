import LibraryCore
import SwiftUI

/// Corner technology badges shown on library cards (MD-11, doc 06 §2.3).
public enum MediaBadge: String, CaseIterable, Sendable, Identifiable {
    case fourK = "4K"
    case dolbyVision = "DoVi"
    case atmos = "Atmos"

    public var id: String { rawValue }

    /// Derives badges from the probed tracks for a library file.
    public static func badges(for item: LibraryGridItem) -> [MediaBadge] {
        var badges: [MediaBadge] = []
        if item.has4K {
            badges.append(.fourK)
        }
        if item.hasDolbyVision {
            badges.append(.dolbyVision)
        }
        if item.hasAtmos {
            badges.append(.atmos)
        }
        return badges
    }

    /// Derives badges from probed tracks for a detail screen.
    public static func badges(for tracks: [TrackRecord]) -> [MediaBadge] {
        let video = tracks.filter { $0.kind == .video }
        let audio = tracks.filter { $0.kind == .audio }

        var badges: [MediaBadge] = []
        if video.contains(where: { ($0.width ?? 0) >= 3800 || ($0.height ?? 0) >= 2100 }) {
            badges.append(.fourK)
        }
        if video.contains(where: {
            ($0.hdrFormat ?? "").localizedCaseInsensitiveContains("dolby")
                || ($0.profile ?? "").localizedCaseInsensitiveContains("dv")
        }) {
            badges.append(.dolbyVision)
        }
        if audio.contains(where: {
            ($0.channelLayout ?? "").localizedCaseInsensitiveContains("atmos")
                || (($0.channels ?? 0) >= 8 && ["truehd", "eac3"].contains($0.codec ?? ""))
        }) {
            badges.append(.atmos)
        }
        return badges
    }

}

/// One poster card in the library grid.
public struct MediaCardView: View {
    public let item: LibraryGridItem
    public let isWatched: Bool
    public let isInProgress: Bool
    public let action: () -> Void

    public init(
        item: LibraryGridItem,
        isWatched: Bool = false,
        isInProgress: Bool = false,
        action: @escaping () -> Void
    ) {
        self.item = item
        self.isWatched = isWatched
        self.isInProgress = isInProgress
        self.action = action
    }

    public var body: some View {
        FocusableCard(
            title: item.displayTitle,
            subtitle: subtitle,
            action: action
        ) {
            ZStack(alignment: .topLeading) {
                poster

                VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
                    HStack(alignment: .top) {
                        watchedIndicator
                        Spacer()
                        badgeColumn
                    }

                    Spacer()

                    Text(item.displayTitle)
                        .font(DesignTypography.callout)
                        .foregroundStyle(DesignTokens.palette.textPrimary.color)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(DesignGrid.spacing(1))
            }
            .frame(
                width: DesignGrid.posterWidth,
                height: DesignGrid.posterHeight
            )
        }
    }

    private var poster: some View {
        ZStack {
            LinearGradient(
                colors: [
                    DesignTokens.palette.surfaceElevated.color,
                    DesignTokens.palette.surface.color
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "film")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(
                    DesignTokens.palette.textTertiary.color.opacity(0.55)
                )

            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private var watchedIndicator: some View {
        if isWatched {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(DesignTokens.palette.success.color)
                .accessibilityLabel("Watched")
        } else if isInProgress {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(DesignTokens.palette.accent.color)
                .accessibilityLabel("In progress")
        }
    }

    private var badgeColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(MediaBadge.badges(for: item)) { badge in
                Text(badge.rawValue)
                    .font(DesignTypography.badge)
                    .foregroundStyle(DesignTokens.palette.background.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DesignTokens.palette.textPrimary.color)
                    .clipShape(Capsule())
                    .accessibilityLabel(badge.accessibilityLabel)
            }
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let year = item.year {
            parts.append(String(year))
        }
        if let rating = item.ratingScore {
            parts.append(String(format: "%.1f", rating))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Shared sort and density controls for both library presentations.
public struct LibraryToolbar: View {
    public let sort: LibrarySortOrder
    public let density: LibraryDensity
    public let onSort: (LibrarySortOrder) -> Void
    public let onToggleDensity: () -> Void

    public init(
        sort: LibrarySortOrder,
        density: LibraryDensity,
        onSort: @escaping (LibrarySortOrder) -> Void,
        onToggleDensity: @escaping () -> Void
    ) {
        self.sort = sort
        self.density = density
        self.onSort = onSort
        self.onToggleDensity = onToggleDensity
    }

    public var body: some View {
        HStack(spacing: DesignGrid.spacing(2)) {
            Menu {
                ForEach(LibrarySortOrder.allCases, id: \.self) { option in
                    Button {
                        onSort(option)
                    } label: {
                        if option == sort {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            } label: {
                Label("Sort: \(sort.displayName)", systemImage: "arrow.up.arrow.down")
                    .font(DesignTypography.callout)
            }

            Spacer()

            Button(action: onToggleDensity) {
                Label(density.displayName, systemImage: density.systemImage)
                    .font(DesignTypography.callout)
            }
            .accessibilityLabel("Switch to \(density == .grid ? "list" : "grid") view")
        }
    }
}

extension MediaBadge {
    var accessibilityLabel: String {
        switch self {
        case .fourK:
            return "4K"
        case .dolbyVision:
            return "Dolby Vision"
        case .atmos:
            return "Dolby Atmos"
        }
    }
}
