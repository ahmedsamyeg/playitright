//
//  LibraryView.swift
//  PlayItRight
//

import LibraryCore
import SwiftUI

struct LibraryView: View {
    let library: LibraryViewModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
        }
        .task {
            await library.load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch library.state {
        case .loading:
            ProgressView("Opening library…")

        case .failed(let message):
            ContentUnavailableView(
                "Library unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )

        case .loaded(let items) where items.isEmpty:
            ContentUnavailableView(
                "No media yet",
                systemImage: "film.stack",
                description: Text("Configure a source to start building your library.")
            )

        case .loaded(let items):
            List {
                Section("Recently added") {
                    ForEach(items) { item in
                        LibraryRow(item: item)
                    }
                }

                if let databasePath = library.databasePath {
                    Section("Database") {
                        Text(databasePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct LibraryRow: View {
    let item: LibraryGridItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.displayTitle)
                .font(.headline)

            Text(item.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    LibraryView(library: LibraryViewModel())
}
