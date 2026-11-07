import LibraryCore
import SwiftUI

/// A phone- and iPad-sized browser over the shared `LibraryCore` catalog.
public struct CompanionLibraryView: View {
    @State private var model: CompanionLibraryModel

    public init(model: CompanionLibraryModel? = nil) {
        _model = State(initialValue: model ?? CompanionLibraryModel())
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        AirPlayRouteButton()
                            .frame(width: 44, height: 44)
                    }
                }
                .task {
                    model.load()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            ProgressView("Loading your library…")
        case .failed(let message):
            ContentUnavailableView(
                "Library unavailable",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(message)
            )
        case .loaded where model.recentItems.isEmpty:
            ContentUnavailableView(
                "No titles yet",
                systemImage: "film.stack",
                description: Text("Scan a source on your Apple TV to fill this library.")
            )
        case .loaded:
            List {
                if !model.shelves.isEmpty {
                    Section("Sources") {
                        ForEach(model.shelves) { shelf in
                            LabeledContent(shelf.name, value: "\(shelf.itemCount)")
                        }
                    }
                }

                Section("Recently added") {
                    ForEach(model.recentItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.headline)
                            if let duration = item.durationMs {
                                Text(Self.durationText(milliseconds: duration))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private static func durationText(milliseconds: Int64) -> String {
        let totalMinutes = max(0, milliseconds) / 60_000
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
