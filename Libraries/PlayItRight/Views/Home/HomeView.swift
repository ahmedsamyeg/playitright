import LibraryCore
import SwiftUI

/// The tvOS Home screen: reorderable shelves for Continue Watching, Recently
/// Added, and each configured library (MD-9, doc 06 §2.2).
public struct HomeView: View {
    @State private var viewModel: HomeViewModel
    private let onAddSource: () -> Void
    private let onSelect: (HomeShelfItem) -> Void

    public init(
        viewModel: HomeViewModel,
        onAddSource: @escaping () -> Void = {},
        onSelect: @escaping (HomeShelfItem) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onAddSource = onAddSource
        self.onSelect = onSelect
    }

    public var body: some View {
        ZStack {
            DesignTokens.palette.background.color
                .ignoresSafeArea()

            switch viewModel.state {
            case .idle, .loading:
                ProgressView("Loading your library…")
                    .font(DesignTypography.body)

            case .failed(let message):
                failure(message)

            case .loaded:
                if viewModel.isEmpty {
                    emptyState
                } else {
                    shelves
                }
            }
        }
        .task {
            if viewModel.state == .idle {
                await viewModel.load()
            }
        }
    }

    private var shelves: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: DesignGrid.spacing(4)) {
                Text("Home")
                    .font(DesignTypography.display)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
                    .padding(.horizontal, DesignGrid.contentMargin)

                ForEach(viewModel.shelves) { shelf in
                    shelfView(shelf)
                }
            }
            .padding(.vertical, DesignGrid.spacing(4))
        }
    }

    @ViewBuilder
    private func shelfView(_ shelf: HomeShelf) -> some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
            shelfHeader(shelf)

            switch shelf.kind {
            case .continueWatching:
                ContinueWatchingRow(items: shelf.items, onSelect: onSelect)

            case .recentlyAdded, .library:
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: DesignGrid.gutter) {
                        ForEach(shelf.items) { item in
                            posterCard(item)
                        }
                    }
                    .padding(.horizontal, DesignGrid.contentMargin)
                    .padding(.vertical, DesignGrid.spacing(1))
                }
                .scrollClipDisabled()
            }
        }
    }

    private func shelfHeader(_ shelf: HomeShelf) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(shelf.title)
                .font(DesignTypography.title2)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)
                .accessibilityAddTraits(.isHeader)

            Spacer()
        }
        .padding(.horizontal, DesignGrid.contentMargin)
        .contextMenu {
            Button("Move Up") {
                viewModel.moveShelfUp(shelf.id)
            }
            Button("Move Down") {
                viewModel.moveShelfDown(shelf.id)
            }
            Divider()
            Button("Reset Shelf Order") {
                viewModel.resetShelfOrder()
            }
        }
        .accessibilityHint("Long press to reorder this shelf.")
    }

    private func posterCard(_ item: HomeShelfItem) -> some View {
        FocusableCard(
            title: item.title,
            subtitle: item.subtitle,
            action: { onSelect(item) }
        ) {
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
                        DesignTokens.palette.textTertiary.color.opacity(0.7)
                    )
            }
            .frame(
                width: DesignGrid.posterWidth,
                height: DesignGrid.posterHeight
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignGrid.spacing(3)) {
            Image(systemName: "film.stack")
                .font(.system(size: 88, weight: .semibold))
                .foregroundStyle(DesignTokens.palette.textTertiary.color)

            Text("Your library is empty")
                .font(DesignTypography.title1)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)

            Text("Add a media source to start watching.")
                .font(DesignTypography.body)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)

            FocusableCard(
                title: "Add a Source",
                subtitle: "Connect a server or share",
                hint: "Opens source setup.",
                action: onAddSource
            ) {
                HStack(spacing: DesignGrid.spacing(2)) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 44, weight: .semibold))
                    Text("Add a Source")
                        .font(DesignTypography.title2)
                }
                .padding(DesignGrid.spacing(3))
                .foregroundStyle(DesignTokens.palette.textPrimary.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignGrid.contentMargin)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: DesignGrid.spacing(2)) {
            Text("Home unavailable")
                .font(DesignTypography.title1)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)

            Text(message)
                .font(DesignTypography.body)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                Task {
                    await viewModel.load()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(DesignGrid.contentMargin)
    }
}
