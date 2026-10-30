//
//  LibraryViewModel.swift
//  PlayItRight
//

import Foundation
import LibraryCore
import Observation

/// Owns the on-device library database for the app shell.
@MainActor
@Observable
final class LibraryViewModel {
    enum State: Equatable {
        case loading
        case loaded([LibraryGridItem])
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var databasePath: String?

    private let databaseURL: URL
    private var database: MediaDatabase?

    init(databaseURL: URL = MediaDatabaseConfiguration.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    /// Opens (or creates) the library database and loads the first grid page.
    func load() async {
        state = .loading
        let databaseURL = databaseURL

        do {
            let (database, items) = try await Task.detached(priority: .userInitiated) {
                let database = try MediaDatabase.open(at: databaseURL)
                try database.runQuickCheck()

                let reader = MediaDatabaseReader(database: database)
                let items = try reader.fetchLibraryGrid(limit: 200)
                return (database, items)
            }.value

            self.database = database
            self.databasePath = database.databaseURL?.path
            state = .loaded(items)
        } catch {
            database = nil
            state = .failed(error.localizedDescription)
        }
    }
}
