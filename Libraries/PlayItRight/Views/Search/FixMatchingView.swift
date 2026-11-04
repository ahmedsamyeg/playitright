import LibraryCore
import SwiftUI

/// Resolves unmatched or low-confidence files by picking a TMDB candidate
/// (MD-2, doc 05 §1, doc 06 §2.6).
public struct FixMatchingView: View {
    public let viewModel: SearchViewModel

    @State private var errorMessage: String?

    public init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DesignGrid.spacing(4)) {
            fileList
                .frame(width: 620)

            candidatePane
        }
        .padding(DesignGrid.contentMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DesignTokens.palette.background.color.ignoresSafeArea())
        .task {
            if viewModel.unmatchedFiles.isEmpty {
                await viewModel.loadUnmatchedFiles()
            }
        }
        .alert(
            "Match",
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

    private var fileList: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(2)) {
            Text("Fix Matching")
                .font(DesignTypography.title1)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)
                .accessibilityAddTraits(.isHeader)

            Text("Choose a file with no match or a low-confidence match.")
                .font(DesignTypography.body)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)

            if viewModel.unmatchedFiles.isEmpty {
                Text("Everything is matched.")
                    .font(DesignTypography.body)
                    .foregroundStyle(DesignTokens.palette.textTertiary.color)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
                        ForEach(viewModel.unmatchedFiles) { file in
                            fileRow(file)
                        }
                    }
                }
            }
        }
    }

    private func fileRow(_ file: MediaFileRecord) -> some View {
        Button {
            Task { await viewModel.selectFile(file) }
        } label: {
            HStack(spacing: DesignGrid.spacing(2)) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(DesignTokens.palette.warning.color)

                VStack(alignment: .leading, spacing: 4) {
                    Text(SearchViewModel.titleFromFileName(file.path))
                        .font(DesignTypography.headline)
                        .foregroundStyle(DesignTokens.palette.textPrimary.color)
                        .lineLimit(1)

                    Text(file.path)
                        .font(DesignTypography.caption)
                        .foregroundStyle(DesignTokens.palette.textTertiary.color)
                        .lineLimit(1)
                }

                Spacer()

                Text(file.matchState.rawValue)
                    .font(DesignTypography.badge)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
            }
            .padding(DesignGrid.spacing(2))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                viewModel.selectedFile?.fileId == file.fileId
                    ? DesignTokens.palette.accent.color.opacity(0.25)
                    : DesignTokens.palette.surfaceElevated.color
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DesignTokens.Focus.cornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var candidatePane: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(2)) {
            if viewModel.selectedFile == nil {
                Text("Select a file to see candidate titles.")
                    .font(DesignTypography.body)
                    .foregroundStyle(DesignTokens.palette.textTertiary.color)
            } else if viewModel.isLoadingCandidates {
                ProgressView("Searching TMDB…")
                    .font(DesignTypography.body)
            } else if viewModel.candidates.isEmpty {
                VStack(alignment: .leading, spacing: DesignGrid.spacing(2)) {
                    Text("No candidates found.")
                        .font(DesignTypography.body)
                        .foregroundStyle(DesignTokens.palette.textSecondary.color)

                    Button("Keep Needing Review") {
                        Task { await markNeedsReview() }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 220), spacing: DesignGrid.gutter)
                        ],
                        alignment: .leading,
                        spacing: DesignGrid.gutter
                    ) {
                        ForEach(viewModel.candidates) { candidate in
                            candidateCard(candidate)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func candidateCard(_ candidate: MatchCandidate) -> some View {
        Button {
            Task { await apply(candidate) }
        } label: {
            VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
                poster(candidate)

                Text(candidate.title)
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)
                    .lineLimit(2)

                if let year = candidate.year {
                    Text(String(year))
                        .font(DesignTypography.badge)
                        .foregroundStyle(DesignTokens.palette.textSecondary.color)
                }
            }
            .frame(width: 220, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            [candidate.title, candidate.year.map(String.init)]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    private func poster(_ candidate: MatchCandidate) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    DesignTokens.palette.surfaceElevated.color,
                    DesignTokens.palette.surface.color
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let path = candidate.posterPath, let url = URL(string: path) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Image(systemName: "film")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(
                                DesignTokens.palette.textTertiary.color.opacity(0.6)
                            )
                    }
                }
            } else {
                Image(systemName: "film")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(DesignTokens.palette.textTertiary.color.opacity(0.6))
            }
        }
        .frame(width: 220, height: 330)
        .clipShape(
            RoundedRectangle(
                cornerRadius: DesignTokens.Focus.cornerRadius,
                style: .continuous
            )
        )
    }

    private func apply(_ candidate: MatchCandidate) async {
        do {
            try await viewModel.applyMovieMatch(tmdbId: candidate.tmdbId)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func markNeedsReview() async {
        do {
            try await viewModel.markSelectedNeedsReview()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
