import CapKit
import Foundation
import GRDB
import LibraryCore
import MetadataKit
import PlaybackKit
import Testing
@testable import PlayItRight

// MARK: - Fakes

private final class SpySettingsStore: SettingsConfigurationStore {
    var configuration: SettingsConfiguration
    private(set) var saveCount = 0

    init(configuration: SettingsConfiguration = SettingsConfiguration()) {
        self.configuration = configuration
    }

    func load() -> SettingsConfiguration {
        configuration
    }

    func save(_ configuration: SettingsConfiguration) {
        self.configuration = configuration
        saveCount += 1
    }
}

private struct SettingsHarness {
    let database: MediaDatabase
    let writer: MediaDatabaseWriter
    let reader: MediaDatabaseReader
    let store: SpySettingsStore
    let cache: ArtworkCache
    let cacheDirectory: URL
    let registry: CapabilityRegistry
}

private func makeProfile() -> DeviceCapabilityProfile {
    DeviceCapabilityProfile(
        id: "apple-tv-4k-gen4",
        displayName: "Apple TV 4K (3rd generation)",
        generation: 4,
        chip: "A15 Bionic",
        tvOSMinimum: "18.0",
        maxVideoOutput: "4K at 60 Hz",
        maxHDRVideoOutput: "Dolby Vision",
        videoCodecs: [
            VideoCodecCapability(
                codec: .h264,
                decode: .hw,
                maxWidth: 3_840,
                maxHeight: 2_160,
                maxBitDepth: 8
            ),
            VideoCodecCapability(
                codec: .hevc,
                decode: .hw,
                maxWidth: 3_840,
                maxHeight: 2_160,
                maxBitDepth: 10,
                hdrFormats: [.hdr10, .hlg],
                dolbyVisionProfiles: [5, 8]
            ),
            VideoCodecCapability(
                codec: .av1,
                decode: .sw,
                maxWidth: 3_840,
                maxHeight: 2_160,
                maxBitDepth: 10
            )
        ],
        audioCodecs: [
            AudioCodecCapability(
                codec: .aac,
                hardwareDecode: true,
                softwareDecode: true,
                passthrough: false
            ),
            AudioCodecCapability(
                codec: .truehd,
                hardwareDecode: false,
                softwareDecode: true,
                passthrough: true
            )
        ]
    )
}

@MainActor
private func makeHarness() throws -> SettingsHarness {
    let database = try MediaDatabase.inMemory()
    try database.write { db in
        try AccountRecord(accountId: "local", displayName: "Local").insert(db)
    }
    let writer = MediaDatabaseWriter(database: database)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return SettingsHarness(
        database: database,
        writer: writer,
        reader: MediaDatabaseReader(database: database),
        store: SpySettingsStore(),
        cache: ArtworkCache(
            configuration: ArtworkCacheConfiguration(directory: directory)
        ),
        cacheDirectory: directory,
        registry: CapabilityRegistry(profile: makeProfile())
    )
}

@MainActor
private func makeViewModel(_ harness: SettingsHarness) -> SettingsViewModel {
    SettingsViewModel(
        reader: harness.reader,
        writer: harness.writer,
        capabilityRegistry: harness.registry,
        store: harness.store,
        artworkCache: harness.cache,
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
}

// MARK: - Tests

@MainActor
@Suite("SettingsViewModel Tests")
struct SettingsViewModelTests {
    @Test("Playback and sink settings persist through the configuration store")
    func settingsPersist() async throws {
        let harness = try makeHarness()
        let viewModel = makeViewModel(harness)

        viewModel.qualityBias = .lowestCPU
        viewModel.colorMode = .precise
        viewModel.displayOverride = .hdr10
        viewModel.audioSetup = .receiverAtmos

        #expect(harness.store.saveCount == 4)
        #expect(harness.store.configuration.playback.qualityBias == .lowestCPU)
        #expect(harness.store.configuration.playback.colorMode == .precise)
        #expect(harness.store.configuration.sinkOverrides.display == .hdr10)
        #expect(harness.store.configuration.sinkOverrides.audio == .receiverAtmos)

        let restored = makeViewModel(harness)
        #expect(restored.qualityBias == .lowestCPU)
        #expect(restored.colorMode == .precise)
        #expect(restored.displayProfileName == "HDR10")
        #expect(restored.audioSetupName == "Receiver (Atmos)")
    }

    @Test("Removing a source deletes it from the library database")
    func removeSourcePersists() async throws {
        let harness = try makeHarness()
        try harness.writer.saveSource(
            SourceRecord(
                sourceId: "s1",
                kind: .local,
                name: "Movies",
                configRef: "s1"
            )
        )
        try harness.writer.saveSource(
            SourceRecord(
                sourceId: "s2",
                kind: .plex,
                name: "Plex",
                configRef: "s2"
            )
        )

        let viewModel = makeViewModel(harness)
        await viewModel.load()
        #expect(viewModel.state == .loaded)
        #expect(viewModel.sources.map(\.sourceId) == ["s1", "s2"])
        #expect(viewModel.sourceSummary == "2 sources connected")

        let source = try #require(viewModel.sources.first { $0.sourceId == "s1" })
        try await viewModel.removeSource(source)

        #expect(viewModel.sources.map(\.sourceId) == ["s2"])
        #expect(viewModel.sourceSummary == "1 source connected")
        #expect(try harness.reader.fetchSources().map(\.sourceId) == ["s2"])
    }

    @Test("Clearing the artwork cache removes bytes and updates usage")
    func clearArtworkCache() async throws {
        let harness = try makeHarness()
        try await harness.cache.store(
            Data(repeating: 0xAB, count: 2_048),
            forKey: "poster"
        )

        let viewModel = makeViewModel(harness)
        await viewModel.load()

        #expect(viewModel.cacheBytes > 0)
        #expect(viewModel.cacheUsageLabel.isEmpty == false)

        try await viewModel.clearArtworkCache()

        #expect(viewModel.cacheBytes == 0)
        let remaining = try await harness.cache.currentSize()
        #expect(remaining == 0)
        #expect(try await harness.cache.contains(key: "poster") == false)
    }

    @Test("Artwork cache limit is clamped and persisted")
    func cacheLimitIsClamped() async throws {
        let harness = try makeHarness()
        let viewModel = makeViewModel(harness)

        await viewModel.setArtworkCacheLimit(1)
        #expect(
            viewModel.artworkCacheByteLimit
                == ArtworkCacheConfiguration.minimumByteLimit
        )
        #expect(
            harness.store.configuration.artworkCacheByteLimit
                == ArtworkCacheConfiguration.minimumByteLimit
        )

        await viewModel.setArtworkCacheLimit(Int64.max)
        #expect(
            viewModel.artworkCacheByteLimit
                == ArtworkCacheConfiguration.maximumByteLimit
        )
    }

    @Test("Rescan records the time and invokes the scan callback")
    func rescanInvokesCallback() async throws {
        let harness = try makeHarness()
        var rescanned = false
        let viewModel = SettingsViewModel(
            reader: harness.reader,
            writer: harness.writer,
            capabilityRegistry: harness.registry,
            store: harness.store,
            artworkCache: harness.cache,
            onRescan: { rescanned = true },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        viewModel.rescanLibrary()
        #expect(rescanned)
        #expect(
            viewModel.lastRescanAt
                == Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("About This Apple TV renders active registry facts")
    func capabilityFacts() throws {
        let harness = try makeHarness()
        let viewModel = makeViewModel(harness)
        let facts = viewModel.capabilityFacts

        #expect(facts.map(\.key) == [
            "device",
            "tvos",
            "video",
            "hdr",
            "hardware-codecs",
            "passthrough",
            "software-forced"
        ])
        #expect(
            facts.first { $0.key == "device" }?.value
                == "Apple TV 4K (3rd generation)"
        )
        #expect(
            facts.first { $0.key == "device" }?.explanation
                == "Identified as A15 Bionic, generation 4."
        )
        #expect(
            facts.first { $0.key == "hardware-codecs" }?.value
                == "H264, HEVC"
        )
        #expect(
            facts.first { $0.key == "passthrough" }?.value
                == "TRUEHD"
        )
        #expect(
            facts.first { $0.key == "software-forced" }?.value
                == "Automatic"
        )

        harness.registry.setForceSoftwarePath(true)
        let forced = viewModel.capabilityFacts
            .first { $0.key == "software-forced" }
        #expect(forced?.value == "Forced software")
        #expect(forced?.explanation.contains("override") == true)
    }
}
