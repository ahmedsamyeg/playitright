import LibraryCore
import SwiftUI

/// The virtualized compact list presentation (MD-11, NFR-1, doc 06 §2.3).
public struct LibraryListView: View {
    public let viewModel: LibraryViewModel
    public let onSelect: (LibraryGridItem) -> Void

    public init(
        viewModel: LibraryViewModel,
        onSelect: @escaping (LibraryGridItem) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onSelect = onSelect
    }

    public var body: some View {
        ZStack {
            DesignTokens.palette.background.color
                .ignoresSafeArea()

            switch viewModel.state {
            case .idle, .loading:
                ProgressView("Loading library…")
                    .font(DesignTypography.body)

            case .failed(let message):
                failure(message)

            case .loaded:
                if viewModel.items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: DesignGrid.spacing(2)) {
                LibraryToolbar(
                    sort: viewModel.sort,
                    density: viewModel.density,
                    onSort: { option in
                        Task { await viewModel.setSort(option) }
                    },
                    onToggleDensity: {
                        viewModel.toggleDensity()
                    }
                )

                ForEach(viewModel.items) { item in
                    MediaListRow(
                        item: item,
                        isWatched: viewModel.isWatched(item),
                        isInProgress: viewModel.isInProgress(item)
                    ) {
                        onSelect(item)
                    }
                    .onAppear {
                        Task {
                            await viewModel.loadNextPageIfNeeded(currentItem: item)
                        }
                    }
                }
            }
            .padding(.horizontal, DesignGrid.contentMargin)
            .padding(.vertical, DesignGrid.spacing(3))
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignGrid.spacing(2)) {
            Image(systemName: "film.stack")
                .font(.system(size: 80, weight: .semibold))
                .foregroundStyle(DesignTokens.palette.textTertiary.color)

            Text("No titles yet")
                .font(DesignTypography.title1)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)

            Text("Add a source or adjust your filters.")
                .font(DesignTypography.body)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignGrid.contentMargin)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: DesignGrid.spacing(2)) {
            Text("Library unavailable")
                .font(DesignTypography.title1)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)

            Text(message)
                .font(DesignTypography.body)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                Task { await viewModel.reload() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(DesignGrid.contentMargin)
    }
}

private struct MediaListRow: View {
    let item: LibraryGridItem
    let isWatched: Bool
    let isInProgress: Bool
    let action: () -> Void

    var body: some View {
        FocusableCard(
            title: item.displayTitle,
            subtitle: subtitle,
            action: action
        ) {
            HStack(spacing: DesignGrid.spacing(2)) {
                thumbnail

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .font(DesignTypography.headline)
                        .foregroundStyle(DesignTokens.palette.textPrimary.color)
                        .lineLimit(1)

                    if let subtitle {
                        Text(subtitle)
                            .font(DesignTypography.caption)
                            .foregroundStyle(DesignTokens.palette.textSecondary.color)
                    }

                    HStack(spacing: DesignGrid.spacing(1)) {
                        ForEach(MediaBadge.badges(for: item)) { badge in
                            Text(badge.rawValue)
                                .font(DesignTypography.badge)
                                .foregroundStyle(DesignTokens.palette.background.color)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(DesignTokens.palette.textPrimary.color)
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                statusIndicator
            }
            .padding(DesignGrid.spacing(1))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var thumbnail: some View {
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
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(DesignTokens.palette.textTertiary.color.opacity(0.6))
        }
        .frame(width: 96, height: 144)
        .clipShape(
            RoundedRectangle(
                cornerRadius: DesignTokens.Focus.cornerRadius,
                style: .continuous
            )
        )
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if isWatched {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(DesignTokens.palette.success.color)
                .accessibilityLabel("Watched")
        } else if isInProgress {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(DesignTokens.palette.accent.color)
                .accessibilityLabel("In progress")
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
