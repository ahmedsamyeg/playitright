import SwiftUI
import LibraryCore

@main
struct PlayItRightVisionApp: App {
    var body: some Scene {
        WindowGroup {
            VisionLibraryShellView()
        }
    }
}

/// visionOS shell for the shared library.
///
/// The wrapper mirrors the macOS shell's data path (via `LibraryCore`) while
/// adapting the presentation to visionOS window idioms.

/// Value type rendered by the platform-adaptive shells.
struct LibrarySurfaceSummary {
    var shelfCount = 0
    var recentlyAddedCount = 0
}

struct LibrarySurfaceSummaryView: View {
    let summary: LibrarySurfaceSummary

    var body: some View {
        List {
            LabeledContent("Shelves", value: "\(summary.shelfCount)")
            LabeledContent("Recently added", value: "\(summary.recentlyAddedCount)")
        }
        .navigationTitle("Library")
    }
}

struct VisionLibraryShellView: View {
    @State private var summary = LibrarySurfaceSummary()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            LibrarySurfaceSummaryView(summary: summary)
        }
        .overlay {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task { load() }
    }

    private func load() {
        do {
            let url = MediaDatabaseConfiguration.defaultDatabaseURL
            if let database = try? MediaDatabase.open(at: url) {
                let reader = MediaDatabaseReader(database: database)
                summary = LibrarySurfaceSummary(
                    shelfCount: try reader.fetchLibraryShelves().count,
                    recentlyAddedCount: try reader.fetchRecentlyAdded(limit: 50).count
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
