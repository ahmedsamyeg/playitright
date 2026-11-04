import CoreKit
import Foundation
import Observation
import PlaybackKit

/// Persists the user's playback preferences per source/codec scope (PB-5).
///
/// The planner only reads ``PlaybackPreferences``; this store is what makes a
/// "Lock this path" action survive relaunches and apply to the next item with
/// the same source and codec.
public protocol PlaybackPreferencesStore: AnyObject {
    func load(sourceId: String?, codec: String?) -> PlaybackPreferences
    func save(
        _ preferences: PlaybackPreferences,
        sourceId: String?,
        codec: String?
    )
}

/// `UserDefaults`-backed playback preference storage.
public final class UserDefaultsPlaybackPreferencesStore: PlaybackPreferencesStore {
    public static let keyPrefix = "playback.preferences"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(sourceId: String?, codec: String?) -> PlaybackPreferences {
        guard let data = defaults.data(forKey: key(sourceId: sourceId, codec: codec)),
              let preferences = try? JSONDecoder().decode(
                  PlaybackPreferences.self,
                  from: data
              ) else {
            return PlaybackPreferences()
        }
        return preferences
    }

    public func save(
        _ preferences: PlaybackPreferences,
        sourceId: String?,
        codec: String?
    ) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        defaults.set(data, forKey: key(sourceId: sourceId, codec: codec))
    }

    public func key(sourceId: String?, codec: String?) -> String {
        let source = sourceId ?? "any"
        let codecName = codec?.lowercased() ?? "any"
        return "\(Self.keyPrefix).\(source).\(codecName)"
    }
}

/// Drives the player's quality badge and pipeline detail sheet, including the
/// per-source/codec path lock (PRD-D1, PB-5, UI-3, doc 06 §2.4).
@MainActor
@Observable
public final class PipelineDetailSheetViewModel {
    public let plan: PipelinePlan
    public let sourceId: String?
    public let codec: String?
    public let store: PlaybackPreferencesStore

    public var isSheetPresented = false
    public private(set) var badge: QualityBadgeViewModel

    public init(
        plan: PipelinePlan,
        thermalState: ThermalState = .nominal,
        sourceId: String? = nil,
        codec: String? = nil,
        store: PlaybackPreferencesStore = UserDefaultsPlaybackPreferencesStore()
    ) {
        self.plan = plan
        self.sourceId = sourceId
        self.codec = codec
        self.store = store

        let stored = store.load(sourceId: sourceId, codec: codec)
        var preferences = stored
        preferences.qualityBias = plan.qualityBias
        preferences.colorMode = plan.colorMode
        self.badge = QualityBadgeViewModel(
            plan: plan,
            thermalState: thermalState,
            preferences: preferences
        )
    }

    public var label: String {
        badge.label
    }

    public var color: BadgeColor {
        badge.color
    }

    public var summary: String {
        badge.summary
    }

    public var sections: [PipelineDetailSection] {
        badge.sections
    }

    public var reasons: [String] {
        badge.reasons
    }

    public var thermalWarning: String? {
        badge.thermalWarning
    }

    public var isPathLocked: Bool {
        badge.isPathLocked
    }

    public var lockActionTitle: String {
        badge.lockActionTitle
    }

    public var preferences: PlaybackPreferences {
        badge.preferences
    }

    public func presentSheet() {
        isSheetPresented = true
    }

    public func dismissSheet() {
        isSheetPresented = false
    }

    /// Locks playback to the selected rung and persists it for the scope.
    @discardableResult
    public func lockPath() -> PlaybackPreferences {
        var updated = badge
        let preferences = updated.lockPath()
        badge = updated
        store.save(preferences, sourceId: sourceId, codec: codec)
        return preferences
    }

    /// Removes the path lock and persists the unlocked preferences.
    @discardableResult
    public func unlockPath() -> PlaybackPreferences {
        var updated = badge
        let preferences = updated.unlockPath()
        badge = updated
        store.save(preferences, sourceId: sourceId, codec: codec)
        return preferences
    }

    /// Toggles the lock and returns the resulting preferences.
    @discardableResult
    public func togglePathLock() -> PlaybackPreferences {
        isPathLocked ? unlockPath() : lockPath()
    }
}
