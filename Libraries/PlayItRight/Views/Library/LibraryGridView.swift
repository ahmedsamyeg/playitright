import LibraryCore
import SwiftUI

/// The virtualized poster grid (MD-11, NFR-1, doc 06 §2.3).
public struct LibraryGridView: View {
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
                    grid
                }
            }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DesignGrid.spacing(2)) {
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
                .padding(.horizontal, DesignGrid.contentMargin)

                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: DesignGrid.posterWidth),
                            spacing: DesignGrid.gutter
                        )
                    ],
                    alignment: .leading,
                    spacing: DesignGrid.gutter
                ) {
                    ForEach(viewModel.items) { item in
                        MediaCardView(
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
            }
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
