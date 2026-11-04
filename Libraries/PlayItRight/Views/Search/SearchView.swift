import LibraryCore
import SwiftUI

/// Instant local search with a Fix Matching entry point (MD-1, MD-2,
/// doc 05 §1, doc 06 §2.6).
public struct SearchView: View {
    public let viewModel: SearchViewModel
    public let onSelectResult: (SearchResultItem) -> Void
    public let onFixMatching: () -> Void

    @State private var text = ""

    public init(
        viewModel: SearchViewModel,
        onSelectResult: @escaping (SearchResultItem) -> Void = { _ in },
        onFixMatching: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onSelectResult = onSelectResult
        self.onFixMatching = onFixMatching
    }

    public var body: some View {
        ZStack {
            DesignTokens.palette.background.color
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: DesignGrid.spacing(3)) {
                header
                searchField

                switch viewModel.state {
                case .idle:
                    prompt("Search movies, shows, and people.")
                case .searching:
                    ProgressView("Searching…")
                        .font(DesignTypography.body)
                case .failed(let message):
                    prompt(message)
                case .loaded:
                    if viewModel.isEmpty {
                        prompt("No matches for “\(viewModel.query)”.")
                    } else {
                        results
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(DesignGrid.contentMargin)
        }
        .task {
            if viewModel.state == .idle {
                await viewModel.loadUnmatchedFiles()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Search")
                .font(DesignTypography.display)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button(action: onFixMatching) {
                Label(
                    "Fix Matching (\(viewModel.unmatchedFiles.count))",
                    systemImage: "questionmark.folder"
                )
                .font(DesignTypography.callout)
            }
            .accessibilityHint("Resolve unmatched or low-confidence files.")
        }
    }

    private var searchField: some View {
        TextField("Search your library", text: $text)
            .font(DesignTypography.title2)
            .textFieldStyle(.plain)
            .padding(DesignGrid.spacing(2))
            .background(DesignTokens.palette.surfaceElevated.color)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DesignTokens.Focus.cornerRadius,
                    style: .continuous
                )
            )
            .onChange(of: text) { _, newValue in
                viewModel.queryChanged(newValue)
            }
            .onSubmit {
                Task { await viewModel.searchImmediately() }
            }
            .accessibilityLabel("Search your library")
    }

    private var results: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
                ForEach(viewModel.results, id: \.entityRef) { result in
                    resultRow(result)
                }
            }
        }
    }

    private func resultRow(_ result: SearchResultItem) -> some View {
        FocusableCard(
            title: result.title,
            subtitle: subtitle(result),
            action: { onSelectResult(result) }
        ) {
            HStack(spacing: DesignGrid.spacing(2)) {
                Image(systemName: iconName(result.entityKind))
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(DesignTokens.palette.textTertiary.color)
                    .frame(width: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(DesignTypography.headline)
                        .foregroundStyle(DesignTokens.palette.textPrimary.color)
                        .lineLimit(1)

                    if let overview = result.overview, !overview.isEmpty {
                        Text(overview)
                            .font(DesignTypography.caption)
                            .foregroundStyle(DesignTokens.palette.textSecondary.color)
                            .lineLimit(2)
                    }
                }

                Spacer()
            }
            .padding(DesignGrid.spacing(2))
            .frame(maxWidth: 1_400, alignment: .leading)
        }
    }

    private func subtitle(_ result: SearchResultItem) -> String? {
        if let people = result.peopleNames, !people.isEmpty {
            return people
        }
        return result.entityKind.rawValue.capitalized
    }

    private func iconName(_ kind: EntityKind) -> String {
        switch kind {
        case .movie:
            return "film"
        case .show:
            return "tv"
        case .episode:
            return "play.rectangle"
        case .person:
            return "person"
        case .season:
            return "rectangle.stack"
        }
    }

    private func prompt(_ message: String) -> some View {
        Text(message)
            .font(DesignTypography.body)
            .foregroundStyle(DesignTokens.palette.textSecondary.color)
    }
}
