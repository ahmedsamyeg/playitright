import CapKit
import CoreKit
import Foundation
import LibraryCore
import MetadataKit
import Observation
import PlaybackKit

/// One plain-language fact in the "About This Apple TV" capability sheet.
public struct CapabilityFact: Sendable, Equatable, Identifiable {
    public let key: String
    public let title: String
    public let value: String
    public let explanation: String

    public var id: String { key }

    public init(
        key: String,
        title: String,
        value: String,
        explanation: String
    ) {
        self.key = key
        self.title = title
        self.value = value
        self.explanation = explanation
    }
}

/// User-configurable settings that live outside the media database.
public struct SettingsConfiguration: Codable, Sendable, Equatable {
    public var playback: PlaybackPreferences
    public var sinkOverrides: SinkOverrides
    public var artworkCacheByteLimit: Int64

    public init(
        playback: PlaybackPreferences = PlaybackPreferences(),
        sinkOverrides: SinkOverrides = SinkOverrides(),
        artworkCacheByteLimit: Int64 = ArtworkCacheConfiguration.defaultByteLimit
    ) {
        self.playback = playback
        self.sinkOverrides = sinkOverrides
        self.artworkCacheByteLimit = artworkCacheByteLimit
    }
}

/// Persists settings as a small JSON configuration file.
public protocol SettingsConfigurationStore: AnyObject {
    func load() -> SettingsConfiguration
    func save(_ configuration: SettingsConfiguration)
}

/// `UserDefaults`-backed settings configuration.
public final class UserDefaultsSettingsConfigurationStore: SettingsConfigurationStore {
    public static let defaultKey = "settings.configuration"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = UserDefaultsSettingsConfigurationStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> SettingsConfiguration {
        guard let data = defaults.data(forKey: key),
              let configuration = try? JSONDecoder().decode(
                  SettingsConfiguration.self,
                  from: data
              ) else {
            return SettingsConfiguration()
        }
        return configuration
    }

    public func save(_ configuration: SettingsConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// Drives Settings: sources management, playback and library preferences,
/// artwork cache maintenance, and the hardware capability sheet
/// (UI-3, doc 06 §2.5).
@MainActor
@Observable
public final class SettingsViewModel {
    public enum State: Sendable, Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var sources: [SourceRecord] = []
    public private(set) var cacheBytes: Int64 = 0
    public private(set) var isClearingCache = false
    public private(set) var lastRescanAt: Date?

    public var configuration: SettingsConfiguration

    public let capabilityRegistry: CapabilityRegistry

    private let reader: MediaDatabaseReader
    private let writer: MediaDatabaseWriter?
    private let store: SettingsConfigurationStore
    private let artworkCache: ArtworkCache
    private let onRescan: (() -> Void)?
    private let now: () -> Date

    public init(
        reader: MediaDatabaseReader,
        writer: MediaDatabaseWriter? = nil,
        capabilityRegistry: CapabilityRegistry,
        store: SettingsConfigurationStore = UserDefaultsSettingsConfigurationStore(),
        artworkCache: ArtworkCache = ArtworkCache(),
        onRescan: (() -> Void)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.reader = reader
        self.writer = writer
        self.capabilityRegistry = capabilityRegistry
        self.store = store
        self.artworkCache = artworkCache
        self.onRescan = onRescan
        self.now = now
        self.configuration = store.load()
    }

    // MARK: - Loading

    public func load() async {
        state = .loading
        let reader = reader
        do {
            let loadedSources = try await Task.detached(priority: .userInitiated) {
                try reader.fetchSources()
            }.value
            sources = loadedSources

            let bytes = try await artworkCache.currentSize()
            cacheBytes = bytes
            await applyCacheLimit()
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Sources

    public func removeSource(_ source: SourceRecord) async throws {
        guard let writer else {
            throw SettingsError.databaseUnavailable
        }
        let writerCopy = writer
        try await Task.detached(priority: .userInitiated) {
            try writerCopy.deleteSource(sourceId: source.sourceId)
        }.value
        sources.removeAll { $0.sourceId == source.sourceId }
    }

    public var sourceSummary: String {
        switch sources.count {
        case 0:
            return "No sources connected"
        case 1:
            return "1 source connected"
        default:
            return "\(sources.count) sources connected"
        }
    }

    // MARK: - Playback

    public var qualityBias: PlaybackPreferences.QualityBias {
        get { configuration.playback.qualityBias }
        set {
            configuration.playback.qualityBias = newValue
            save()
        }
    }

    public var colorMode: PlaybackPreferences.ColorMode {
        get { configuration.playback.colorMode }
        set {
            configuration.playback.colorMode = newValue
            save()
        }
    }

    public var playbackPreferences: PlaybackPreferences {
        configuration.playback
    }

    public var displayOverride: DisplayOverride? {
        get { configuration.sinkOverrides.display }
        set {
            configuration.sinkOverrides.display = newValue
            save()
        }
    }

    public var audioSetup: AudioSetup? {
        get { configuration.sinkOverrides.audio }
        set {
            configuration.sinkOverrides.audio = newValue
            save()
        }
    }

    public var displayProfileName: String {
        displayOverride?.displayName ?? "Automatic"
    }

    public var audioSetupName: String {
        audioSetup?.displayName ?? "Automatic"
    }

    // MARK: - Library

    public var artworkCacheByteLimit: Int64 {
        configuration.artworkCacheByteLimit
    }

    public func setArtworkCacheLimit(_ bytes: Int64) async {
        let clamped = ArtworkCacheConfiguration.clampedByteLimit(bytes)
        configuration.artworkCacheByteLimit = clamped
        save()
        await applyCacheLimit()
    }

    public var cacheUsageLabel: String {
        ByteCountFormatter.string(
            fromByteCount: cacheBytes,
            countStyle: .file
        )
    }

    /// Clears every cached artwork file and resets the usage indicator.
    public func clearArtworkCache() async throws {
        isClearingCache = true
        defer { isClearingCache = false }
        try await artworkCache.clear()
        cacheBytes = 0
    }

    public func rescanLibrary() {
        lastRescanAt = now()
        onRescan?()
    }

    // MARK: - Capabilities

    /// Plain-language facts for the "About This Apple TV" sheet.
    public var capabilityFacts: [CapabilityFact] {
        let profile = capabilityRegistry.profile
        var facts: [CapabilityFact] = [
            CapabilityFact(
                key: "device",
                title: "Apple TV",
                value: profile.displayName,
                explanation: "Identified as \(profile.chip), generation \(profile.generation)."
            ),
            CapabilityFact(
                key: "tvos",
                title: "tvOS",
                value: profile.tvOSMinimum,
                explanation: "The oldest tvOS version this profile supports."
            ),
            CapabilityFact(
                key: "video",
                title: "Video output",
                value: profile.maxVideoOutput,
                explanation: "The highest resolution this Apple TV can send to your display."
            ),
            CapabilityFact(
                key: "hdr",
                title: "HDR output",
                value: profile.maxHDRVideoOutput,
                explanation: "The best high-dynamic-range format available to the display."
            )
        ]

        let hardwareCodecs = profile.videoCodecs
            .filter { $0.supportsHardwareDecode }
            .map { $0.codec.rawValue.uppercased() }
            .sorted()
        facts.append(
            CapabilityFact(
                key: "hardware-codecs",
                title: "Hardware decoding",
                value: hardwareCodecs.isEmpty
                    ? "None"
                    : hardwareCodecs.joined(separator: ", "),
                explanation: "These codecs are decoded by the Apple TV media engine instead of the CPU."
            )
        )

        let passthroughCodecs = profile.audioCodecs
            .filter { $0.passthrough }
            .map { $0.codec.rawValue.uppercased() }
            .sorted()
        facts.append(
            CapabilityFact(
                key: "passthrough",
                title: "Audio passthrough",
                value: passthroughCodecs.isEmpty
                    ? "None"
                    : passthroughCodecs.joined(separator: ", "),
                explanation: "These formats can reach your receiver without being decoded by the Apple TV."
            )
        )

        facts.append(
            CapabilityFact(
                key: "software-forced",
                title: "Decode path",
                value: capabilityRegistry.forceSoftwarePath
                    ? "Forced software"
                    : "Automatic",
                explanation: capabilityRegistry.forceSoftwarePath
                    ? "A developer override is forcing software decoding."
                    : "Hardware decoding is used whenever the codec allows it."
            )
        )

        return facts
    }

    // MARK: - Private

    private func save() {
        store.save(configuration)
    }

    private func applyCacheLimit() async {
        try? await artworkCache.setByteLimit(configuration.artworkCacheByteLimit)
        cacheBytes = (try? await artworkCache.currentSize()) ?? cacheBytes
    }
}

public enum SettingsError: Error, Sendable, Equatable, LocalizedError {
    case databaseUnavailable

    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return "The library database is unavailable."
        }
    }
}
