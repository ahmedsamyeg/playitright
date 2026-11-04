import LibraryCore
import SwiftUI

/// Horizontal chips for source, watched status, genre, resolution, codec, and
/// HDR, with a Save action for Smart Libraries (MD-4, doc 06 §2.3).
public struct LibraryFilterBar: View {
    public let viewModel: FilterBarViewModel
    public let onSave: () -> Void

    public init(
        viewModel: FilterBarViewModel,
        onSave: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onSave = onSave
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignGrid.spacing(1)) {
                sourceMenu
                watchedMenu
                genreMenu
                resolutionMenu
                codecMenu
                hdrMenu

                if viewModel.hasActiveFilters {
                    Button("Clear") {
                        viewModel.clear()
                    }
                    .font(DesignTypography.callout)
                }

                Button(action: onSave) {
                    Label("Save", systemImage: "bookmark")
                        .font(DesignTypography.callout)
                }
                .accessibilityHint("Saves the active filters as a Smart Library.")
            }
            .padding(.horizontal, DesignGrid.contentMargin)
            .padding(.vertical, DesignGrid.spacing(1))
        }
        .scrollClipDisabled()
    }

    private var sourceMenu: some View {
        Menu {
            Button("All Sources") {
                viewModel.sourceId = nil
            }
            ForEach(viewModel.sources) { source in
                Button(source.name) {
                    viewModel.sourceId = source.sourceId
                }
            }
        } label: {
            chip(
                title: sourceTitle,
                isActive: viewModel.sourceId != nil
            )
        }
    }

    private var watchedMenu: some View {
        Menu {
            ForEach(WatchedFilter.allCases, id: \.self) { option in
                Button(option.displayName) {
                    viewModel.watched = option
                }
            }
        } label: {
            chip(
                title: viewModel.watched == .any
                    ? "Watched"
                    : viewModel.watched.displayName,
                isActive: viewModel.watched != .any
            )
        }
    }

    private var genreMenu: some View {
        Menu {
            ForEach(viewModel.genres, id: \.genreId) { genre in
                Button {
                    viewModel.toggleGenre(genre.genreId)
                } label: {
                    if viewModel.genreIds.contains(genre.genreId) {
                        Label(genre.name, systemImage: "checkmark")
                    } else {
                        Text(genre.name)
                    }
                }
            }
        } label: {
            chip(
                title: viewModel.genreIds.isEmpty
                    ? "Genre"
                    : "Genre (\(viewModel.genreIds.count))",
                isActive: !viewModel.genreIds.isEmpty
            )
        }
    }

    private var resolutionMenu: some View {
        Menu {
            ForEach(ResolutionFilter.allCases, id: \.self) { option in
                Button(option.displayName) {
                    viewModel.resolution = option
                }
            }
        } label: {
            chip(
                title: viewModel.resolution == .any
                    ? "Resolution"
                    : viewModel.resolution.displayName,
                isActive: viewModel.resolution != .any
            )
        }
    }

    private var codecMenu: some View {
        Menu {
            Button("Any Codec") {
                viewModel.codec = nil
            }
            ForEach(FilterBarViewModel.codecChoices, id: \.id) { choice in
                Button(choice.name) {
                    viewModel.codec = choice.id
                }
            }
        } label: {
            chip(
                title: codecTitle,
                isActive: viewModel.codec != nil
            )
        }
    }

    private var hdrMenu: some View {
        Menu {
            ForEach(HDRFilter.allCases, id: \.self) { option in
                Button(option.displayName) {
                    viewModel.hdr = option
                }
            }
        } label: {
            chip(
                title: viewModel.hdr == .any ? "HDR" : viewModel.hdr.displayName,
                isActive: viewModel.hdr != .any
            )
        }
    }

    private func chip(title: String, isActive: Bool) -> some View {
        Text(title)
            .font(DesignTypography.callout)
            .foregroundStyle(
                isActive
                    ? DesignTokens.palette.background.color
                    : DesignTokens.palette.textPrimary.color
            )
            .padding(.horizontal, DesignGrid.spacing(1))
            .padding(.vertical, 6)
            .background(
                isActive
                    ? DesignTokens.palette.accent.color
                    : DesignTokens.palette.surface.color
            )
            .clipShape(Capsule())
    }

    private var sourceTitle: String {
        guard let sourceId = viewModel.sourceId else {
            return "Source"
        }
        return viewModel.sources.first { $0.sourceId == sourceId }?.name ?? "Source"
    }

    private var codecTitle: String {
        guard let codec = viewModel.codec else {
            return "Codec"
        }
        return FilterBarViewModel.codecChoices.first { $0.id == codec }?.name ?? codec
    }
}
