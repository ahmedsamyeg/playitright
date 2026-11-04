import CoreKit
import Foundation
import GRDB
import LibraryCore
import PlaybackKit
import SourceAdapters
import Testing
@testable import PlayItRight

// MARK: - Fakes

private final class MemoryPreferences: OnboardingPreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String: String] = [:]
    private var datas: [String: Data] = [:]
    private var bools: [String: Bool] = [:]
    private var integers: [String: Int] = [:]

    func string(forKey key: String) -> String? {
        withLock { strings[key] }
    }

    func data(forKey key: String) -> Data? {
        withLock { datas[key] }
    }

    func bool(forKey key: String) -> Bool {
        withLock { bools[key] ?? false }
    }

    func integer(forKey key: String) -> Int {
        withLock { integers[key] ?? 0 }
    }

    func set(_ value: String?, forKey key: String) {
        withLock { strings[key] = value }
    }

    func set(_ value: Data?, forKey key: String) {
        withLock { datas[key] = value }
    }

    func set(_ value: Bool, forKey key: String) {
        withLock { bools[key] = value }
    }

    func set(_ value: Int, forKey key: String) {
        withLock { integers[key] = value }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class MemoryKeychain: KeychainProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func data(for key: String) throws -> Data? {
        withLock { storage[key] }
    }

    func set(_ data: Data, for key: String) throws {
        withLock { storage[key] = data }
    }

    func remove(for key: String) throws {
        withLock { storage.removeValue(forKey: key) }
    }

    func removeAll() throws {
        withLock { storage.removeAll() }
    }

    func string(for key: String) -> String? {
        guard let data = withLock({ storage[key] }) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@MainActor
private func makeSinkManager() -> SinkProfileManager {
    SinkProfileManager(
        notificationCenter: NotificationCenter(),
        observation: {
            SinkObservation(
                display: DisplayCapabilities(
                    width: 3_840,
                    height: 2_160,
                    maxRefreshRate: 60
                ),
                audioSetup: .stereo,
                routeName: "TV Speakers"
            )
        }
    )
}

private struct Harness {
    var viewModel: OnboardingViewModel
    var sinkManager: SinkProfileManager
    var database: MediaDatabase
    var writer: MediaDatabaseWriter
    var keychain: MemoryKeychain
    var preferences: MemoryPreferences
}

@MainActor
private func makeHarness() throws -> Harness {
    let database = try MediaDatabase.inMemory()
    let writer = MediaDatabaseWriter(database: database)
    let keychain = MemoryKeychain()
    let preferences = MemoryPreferences()
    let sinkManager = makeSinkManager()
    let viewModel = OnboardingViewModel(
        sinkManager: sinkManager,
        databaseWriter: writer,
        keychain: keychain,
        preferences: preferences,
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    return Harness(
        viewModel: viewModel,
        sinkManager: sinkManager,
        database: database,
        writer: writer,
        keychain: keychain,
        preferences: preferences
    )
}

@MainActor
private extension Harness {
    /// Advances through display, audio, and source type with the given answers.
    func answerSink(
        display: DisplayOverride = .dolbyVision,
        audio: AudioSetup = .receiverAtmos,
        source: SourceAdapters.SourceKind = .smb
    ) {
        viewModel.selectDisplay(display)
        _ = viewModel.advance()
        viewModel.selectAudio(audio)
        _ = viewModel.advance()
        viewModel.selectSourceKind(source)
        _ = viewModel.advance()
    }
}

// MARK: - Tests

@MainActor
@Suite("OnboardingViewModel Tests")
struct OnboardingViewModelTests {
    @Test("Completing sink setup saves the profile to preferences and the manager")
    func sinkProfileSaved() throws {
        let harness = try makeHarness()
        let viewModel = harness.viewModel

        viewModel.selectDisplay(.dolbyVision)
        #expect(viewModel.advance())
        #expect(viewModel.step == .audio)

        viewModel.selectAudio(.receiverAtmos)
        #expect(viewModel.advance())
        #expect(viewModel.step == .sourceType)

        let profile = try #require(viewModel.savedSinkProfile)
        #expect(profile.declaredDisplay == .dolbyVision)
        #expect(profile.declaredAudio == .receiverAtmos)
        #expect(profile.display.supportsDolbyVision)
        #expect(profile.audio.supportsAtmos)
        #expect(harness.sinkManager.profile == profile)

        #expect(
            harness.preferences.string(
                forKey: OnboardingViewModel.PreferenceKey.display
            ) == "dolbyVision"
        )
        #expect(
            harness.preferences.string(
                forKey: OnboardingViewModel.PreferenceKey.audio
            ) == "receiver-atmos"
        )

        let data = try #require(
            harness.preferences.data(
                forKey: OnboardingViewModel.PreferenceKey.sinkProfile
            )
        )
        let stored = try JSONDecoder().decode(SinkProfile.self, from: data)
        #expect(stored.declaredDisplay == .dolbyVision)
        #expect(stored.declaredAudio == .receiverAtmos)
    }

    @Test("Connecting the first source saves the database row, Keychain secret, and completion flag")
    func connectFirstSource() throws {
        let harness = try makeHarness()
        let viewModel = harness.viewModel
        harness.answerSink(display: .hdr10, audio: .receiverAC3, source: .smb)

        viewModel.sourceName = "Living Room NAS"
        viewModel.sourceAddress = "192.168.1.20"
        viewModel.username = "samy"
        viewModel.credential = "correct horse battery staple"

        let config = try viewModel.connectSource()

        #expect(config.kind == .smb)
        #expect(config.name == "Living Room NAS")
        #expect(config.host == "192.168.1.20")
        #expect(config.endpoint == nil)
        #expect(config.username == "samy")
        #expect(config.requiresTLS == false)
        #expect(config.credentialReference == "source.\(config.id.uuidString)")

        let reference = try #require(config.credentialReference)
        #expect(harness.keychain.string(for: reference) == "correct horse battery staple")
        #expect(viewModel.credential.isEmpty)

        let record = try harness.database.read { db in
            try SourceRecord.fetchOne(db, key: config.id.uuidString)
        }
        let source = try #require(record)
        #expect(source.kind == .smb)
        #expect(source.name == "Living Room NAS")
        #expect(source.configRef == reference)
        #expect(source.status == .ok)
        #expect(source.addedAt == 1_700_000_000_000)

        #expect(viewModel.step == .complete)
        #expect(viewModel.isCompleted)
        #expect(
            harness.preferences.bool(
                forKey: OnboardingViewModel.PreferenceKey.completed
            )
        )
        #expect(viewModel.savedSourceConfig == config)

        let configData = try #require(
            harness.preferences.data(
                forKey: OnboardingViewModel.PreferenceKey.sourceConfig
            )
        )
        let storedConfig = try JSONDecoder().decode(
            SourceConfig.self,
            from: configData
        )
        #expect(storedConfig.id == config.id)
    }

    @Test("First-scan progress counts are immediate and persisted")
    func progressCounts() throws {
        let harness = try makeHarness()
        let viewModel = harness.viewModel
        harness.answerSink()
        viewModel.sourceName = "NAS"
        viewModel.sourceAddress = "nas.local"
        _ = try viewModel.connectSource()

        #expect(viewModel.connectionState == .scanning)
        #expect(viewModel.progressSummary.contains("Scanning"))

        viewModel.updateProgress(discovered: 42, indexed: 40)

        #expect(viewModel.connectionState == .ready(itemCount: 42))
        #expect(viewModel.progressSummary == "42 items ready to play.")
        #expect(viewModel.discoveredItemCount == 42)
        #expect(viewModel.indexedFileCount == 40)
        #expect(
            harness.preferences.integer(
                forKey: OnboardingViewModel.PreferenceKey.discoveredItems
            ) == 42
        )
        #expect(
            harness.preferences.integer(
                forKey: OnboardingViewModel.PreferenceKey.indexedFiles
            ) == 40
        )
    }

    @Test("WebDAV connections keep a URL endpoint and require TLS")
    func webDAVEndpoint() throws {
        let harness = try makeHarness()
        harness.answerSink(display: .sdr, audio: .stereo, source: .webdav)

        harness.viewModel.sourceName = "Cloud"
        harness.viewModel.sourceAddress = "https://media.example.com"
        harness.viewModel.credential = "token"

        let config = try harness.viewModel.connectSource()
        #expect(config.endpoint?.absoluteString == "https://media.example.com")
        #expect(config.host == nil)
        #expect(config.requiresTLS)
    }

    @Test("A local folder stores its path in options and saves no secret")
    func localFolder() throws {
        let harness = try makeHarness()
        harness.answerSink(display: .sdr, audio: .stereo, source: .local)

        harness.viewModel.sourceName = "Movies"
        harness.viewModel.sourceAddress = "/Users/Shared/Movies"

        let config = try harness.viewModel.connectSource()
        #expect(config.options["rootPath"] == "/Users/Shared/Movies")
        #expect(config.credentialReference == nil)
        #expect(config.requiresTLS == false)

        let record = try harness.database.read { db in
            try SourceRecord.fetchOne(db, key: config.id.uuidString)
        }
        #expect(record?.configRef == config.id.uuidString)
    }

    @Test("The flow will not advance until each question is answered")
    func questionValidation() throws {
        let harness = try makeHarness()
        let viewModel = harness.viewModel

        #expect(viewModel.step == .display)
        #expect(!viewModel.advance())
        #expect(viewModel.step == .display)

        viewModel.selectDisplay(.hdr10)
        #expect(viewModel.advance())
        #expect(!viewModel.advance())
        #expect(viewModel.step == .audio)

        viewModel.selectAudio(.stereo)
        #expect(viewModel.advance())
        #expect(viewModel.step == .sourceType)
        #expect(!viewModel.advance())

        viewModel.selectSourceKind(.plex)
        #expect(viewModel.advance())
        #expect(viewModel.step == .sourceSetup)
        #expect(!viewModel.advance())
    }

    @Test("Connecting validates the source type and name")
    func connectionValidation() throws {
        let harness = try makeHarness()
        let viewModel = harness.viewModel

        #expect(throws: OnboardingError.missingSourceKind) {
            try viewModel.connectSource()
        }
        #expect(viewModel.lastError == OnboardingError.missingSourceKind.errorDescription)

        viewModel.selectSourceKind(.plex)
        #expect(throws: OnboardingError.missingSourceName) {
            try viewModel.connectSource()
        }
        #expect(viewModel.progressSummary == "Connect a source to start building your library.")
    }

    @Test("A completed onboarding restores from preferences")
    func restoresCompletedState() throws {
        let harness = try makeHarness()
        harness.preferences.set(true, forKey: OnboardingViewModel.PreferenceKey.completed)
        harness.preferences.set(
            "dolbyVision",
            forKey: OnboardingViewModel.PreferenceKey.display
        )
        harness.preferences.set(
            "receiver-atmos",
            forKey: OnboardingViewModel.PreferenceKey.audio
        )

        let restored = OnboardingViewModel(
            sinkManager: makeSinkManager(),
            databaseWriter: harness.writer,
            keychain: harness.keychain,
            preferences: harness.preferences
        )

        #expect(restored.isCompleted)
        #expect(restored.step == .complete)
        #expect(restored.display == .dolbyVision)
        #expect(restored.audio == .receiverAtmos)
        #expect(
            OnboardingViewModel.hasCompleted(in: harness.preferences)
        )
    }

    @Test("Going back returns to the previous question")
    func backNavigation() throws {
        let harness = try makeHarness()
        let viewModel = harness.viewModel

        viewModel.selectDisplay(.hdr10)
        #expect(viewModel.advance())
        viewModel.selectAudio(.stereo)
        #expect(viewModel.advance())

        viewModel.goBack()
        #expect(viewModel.step == .audio)
        viewModel.goBack()
        #expect(viewModel.step == .display)
        viewModel.goBack()
        #expect(viewModel.step == .display)
    }
}
