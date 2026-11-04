import LibraryCore
import SwiftUI

/// Names and saves the active filter chips, and recalls existing Smart
/// Libraries (MD-4, doc 05 §4).
public struct SaveSmartLibrarySheet: View {
    public let viewModel: FilterBarViewModel
    public let onRecalled: (SmartLibraryRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    public init(
        viewModel: FilterBarViewModel,
        onRecalled: @escaping (SmartLibraryRecord) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onRecalled = onRecalled
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(3)) {
            Text("Save Smart Library")
                .font(DesignTypography.title1)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)

            Text("\(viewModel.activeGroupCount) active filters")
                .font(DesignTypography.body)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)

            TextField("Name", text: $name)
                .font(DesignTypography.headline)
                .textContentType(.name)

            if let errorMessage {
                Text(errorMessage)
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.danger.color)
            }

            HStack(spacing: DesignGrid.spacing(2)) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button(isSaving ? "Saving…" : "Save") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !viewModel.savedLibraries.isEmpty {
                Divider()

                Text("Saved")
                    .font(DesignTypography.title2)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)

                ScrollView {
                    VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
                        ForEach(viewModel.savedLibraries) { record in
                            savedRow(record)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(DesignGrid.contentMargin)
        .frame(minWidth: 720, minHeight: 520, alignment: .topLeading)
        .background(DesignTokens.palette.background.color)
        .task {
            if viewModel.savedLibraries.isEmpty {
                await viewModel.load()
            }
        }
    }

    private func savedRow(_ record: SmartLibraryRecord) -> some View {
        HStack(spacing: DesignGrid.spacing(2)) {
            Button {
                recall(record)
            } label: {
                Label(record.name, systemImage: "bookmark.fill")
                    .font(DesignTypography.body)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                Task {
                    try? await viewModel.deleteSavedLibrary(record)
                }
            } label: {
                Image(systemName: "trash")
                    .accessibilityLabel("Delete \(record.name)")
            }
            .buttonStyle(.bordered)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let record = try await viewModel.saveCurrentFilters(name: name)
            name = ""
            errorMessage = nil
            onRecalled(record)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func recall(_ record: SmartLibraryRecord) {
        do {
            try viewModel.recall(record)
            onRecalled(record)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
