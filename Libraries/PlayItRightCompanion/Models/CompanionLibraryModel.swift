import Foundation
import LibraryCore
import Observation

/// Drives the iOS/iPadOS companion library browser.
///
/// The companion reads the same `LibraryCore` schema as the tvOS app. It never
/// writes to the database and never loads source credentials; it only projects
/// the synced metadata into a phone-sized browsing surface.
@MainActor
@Observable
public final class CompanionLibraryModel {
    public enum LoadState: Equatable {
        case idle
        case loaded
        case failed(String)
    }

    public private(set) var recentItems: [RecentlyAddedItem] = []
    public private(set) var shelves: [LibraryShelfSummary] = []
    public private(set) var state: LoadState = .idle

    private let reader: MediaDatabaseReader?

    public init(database: MediaDatabase?) {
        if let database {
            self.reader = MediaDatabaseReader(database: database)
        } else {
            self.reader = nil
        }
    }

    /// Opens the on-device library, creating an empty one when this is the
    /// first launch on the companion.
    public convenience init() {
        let url = MediaDatabaseConfiguration.defaultDatabaseURL
        self.init(database: try? MediaDatabase.open(at: url))
    }

    public func load() {
        guard let reader else {
            state = .failed("The shared library is unavailable on this device.")
            return
        }

        do {
            recentItems = try reader.fetchRecentlyAdded(limit: 50)
            shelves = try reader.fetchLibraryShelves()
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
