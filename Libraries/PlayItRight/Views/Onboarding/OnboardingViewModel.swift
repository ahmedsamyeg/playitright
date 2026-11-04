import CoreKit
import Foundation
import LibraryCore
import Observation
import PlaybackKit
import SourceAdapters

/// Persistence for the handful of onboarding answers that are not credentials.
///
/// The production implementation wraps `UserDefaults`; tests use an in-memory
/// store so they never touch the host preferences domain.
public protocol OnboardingPreferencesStore: Sendable {
    func string(forKey key: String) -> String?
    func data(forKey key: String) -> Data?
    func bool(forKey key: String) -> Bool
    func integer(forKey key: String) -> Int

    func set(_ value: String?, forKey key: String)
    func set(_ value: Data?, forKey key: String)
    func set(_ value: Bool, forKey key: String)
    func set(_ value: Int, forKey key: String)
}

/// `UserDefaults`-backed onboarding preferences.
public final class UserDefaultsOnboardingPreferences: OnboardingPreferencesStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    public func integer(forKey key: String) -> Int {
        defaults.integer(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func set(_ value: Data?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// Drives the three-question sink setup and the first-source connection flow
/// (UI-1, doc 06 §2.1).
///
/// Answers are applied to ``SinkProfileManager`` so the planner immediately
/// uses them, persisted to preferences, and the first source's credentials go
/// to the Keychain. The source row is written to the library database before
/// the first scan so progress can be counted from the first enumeration.
@MainActor
@Observable
public final class OnboardingViewModel {
    public enum Step: Int, CaseIterable, Sendable, Equatable {
        case display
        case audio
        case sourceType
        case sourceSetup
        case complete
    }

    public enum ConnectionState: Sendable, Equatable {
        case idle
        case scanning
        case ready(itemCount: Int)
        case failed(String)
    }

    public enum PreferenceKey {
        public static let display = "onboarding.sink.display"
        public static let audio = "onboarding.sink.audio"
        public static let sinkProfile = "onboarding.sink.profile"
        public static let sourceKind = "onboarding.source.kind"
        public static let sourceConfig = "onboarding.source.config"
        public static let discoveredItems = "onboarding.progress.discovered"
        public static let indexedFiles = "onboarding.progress.indexed"
        public static let completed = "onboarding.completed"
    }

    public static let displayChoices: [DisplayOverride] = [
        .sdr,
        .hdr10,
        .dolbyVision
    ]

    public static let audioChoices: [AudioSetup] = [
        .stereo,
        .receiverAC3,
        .receiverAtmos,
        .homePod
    ]

    /// Source types offered during onboarding. The full Settings screen adds
    /// the remaining adapters once the basics are working.
    public static let sourceChoices: [SourceAdapters.SourceKind] = [
        .plex,
        .jellyfin,
        .emby,
        .smb,
        .nfs,
        .webdav,
        .local
    ]

    public private(set) var step: Step = .display
    public var display: DisplayOverride?
    public var audio: AudioSetup?
    public var sourceKind: SourceAdapters.SourceKind?
    public var sourceName: String = ""
    public var sourceAddress: String = ""
    public var username: String = ""
    public var credential: String = ""

    public private(set) var connectionState: ConnectionState = .idle
    public private(set) var discoveredItemCount: Int = 0
    public private(set) var indexedFileCount: Int = 0
    public private(set) var savedSinkProfile: SinkProfile?
    public private(set) var savedSourceConfig: SourceConfig?
    public private(set) var isCompleted = false
    public private(set) var lastError: String?

    private let sinkManager: SinkProfileManager
    private let databaseWriter: MediaDatabaseWriter?
    private let keychain: any KeychainProtocol
    private let preferences: any OnboardingPreferencesStore
    private let now: @Sendable () -> Date

    public init(
        sinkManager: SinkProfileManager,
        databaseWriter: MediaDatabaseWriter? = nil,
        keychain: any KeychainProtocol = KeychainStore(
            service: "com.playitright.onboarding"
        ),
        preferences: any OnboardingPreferencesStore = UserDefaultsOnboardingPreferences(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sinkManager = sinkManager
        self.databaseWriter = databaseWriter
        self.keychain = keychain
        self.preferences = preferences
        self.now = now

        if let display = preferences.string(forKey: PreferenceKey.display)
            .flatMap(DisplayOverride.init(rawValue:)) {
            self.display = display
        }
        if let audio = preferences.string(forKey: PreferenceKey.audio)
            .flatMap(AudioSetup.init(rawValue:)) {
            self.audio = audio
        }
        if let kind = preferences.string(forKey: PreferenceKey.sourceKind)
            .flatMap(SourceAdapters.SourceKind.init(rawValue:)) {
            self.sourceKind = kind
        }
        self.isCompleted = preferences.bool(forKey: PreferenceKey.completed)
        self.discoveredItemCount = preferences.integer(
            forKey: PreferenceKey.discoveredItems
        )
        self.indexedFileCount = preferences.integer(
            forKey: PreferenceKey.indexedFiles
        )
        if self.isCompleted {
            self.step = .complete
        }
    }

    // MARK: - Questions

    public func selectDisplay(_ display: DisplayOverride) {
        self.display = display
        preferences.set(display.rawValue, forKey: PreferenceKey.display)
    }

    public func selectAudio(_ audio: AudioSetup) {
        self.audio = audio
        preferences.set(audio.rawValue, forKey: PreferenceKey.audio)
    }

    public func selectSourceKind(_ kind: SourceAdapters.SourceKind) {
        sourceKind = kind
        preferences.set(kind.rawValue, forKey: PreferenceKey.sourceKind)
    }

    public var canAdvance: Bool {
        switch step {
        case .display:
            return display != nil
        case .audio:
            return audio != nil
        case .sourceType:
            return sourceKind != nil
        case .sourceSetup:
            // The source step is completed by connectSource(), not by Next.
            return false
        case .complete:
            return false
        }
    }

    public var canConnect: Bool {
        sourceKind != nil && !trimmedSourceName.isEmpty
    }

    public var isSinkConfigured: Bool {
        display != nil && audio != nil
    }

    @discardableResult
    public func advance() -> Bool {
        guard canAdvance, let next = Step(rawValue: step.rawValue + 1) else {
            return false
        }

        switch step {
        case .display:
            applySinkProfile()
        case .audio:
            applySinkProfile()
        default:
            break
        }

        step = next
        return true
    }

    public func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else {
            return
        }
        step = previous
    }

    /// Applies the two sink answers to the live profile and persists them.
    @discardableResult
    public func applySinkProfile() -> SinkProfile? {
        guard let display, let audio else {
            return nil
        }

        sinkManager.setOverrides(
            SinkOverrides(display: display, audio: audio)
        )
        let profile = sinkManager.profile
        savedSinkProfile = profile

        preferences.set(display.rawValue, forKey: PreferenceKey.display)
        preferences.set(audio.rawValue, forKey: PreferenceKey.audio)
        if let data = try? JSONEncoder().encode(profile) {
            preferences.set(data, forKey: PreferenceKey.sinkProfile)
        }
        return profile
    }

    // MARK: - First source

    /// Saves the first source, stores its credential in the Keychain, and marks
    /// onboarding complete. The caller then hands the config to the sync
    /// coordinator and reports progress through ``updateProgress``.
    @discardableResult
    public func connectSource() throws -> SourceConfig {
        guard let sourceKind else {
            let error = OnboardingError.missingSourceKind
            lastError = error.errorDescription
            throw error
        }

        guard canConnect else {
            let error = OnboardingError.missingSourceName
            lastError = error.errorDescription
            throw error
        }

        applySinkProfile()

        let id = UUID()
        let reference = credentialReference(for: id)
        let trimmedCredential = credential.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !trimmedCredential.isEmpty {
            try keychain.set(
                trimmedCredential,
                for: reference
            )
            // Do not keep the secret in the view model once it is stored.
            credential = ""
        }

        let address = sourceAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        var options: [String: String] = [:]
        if sourceKind == .local, !address.isEmpty {
            options["rootPath"] = address
        }

        let config = SourceConfig(
            id: id,
            kind: sourceKind,
            name: trimmedSourceName,
            endpoint: endpoint(for: sourceKind, address: address),
            host: host(for: sourceKind, address: address),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : username.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialReference: trimmedCredential.isEmpty ? nil : reference,
            requiresTLS: sourceKind != .smb
                && sourceKind != .nfs
                && sourceKind != .local,
            options: options
        )

        if let databaseWriter {
            let record = SourceRecord(
                sourceId: id.uuidString,
                kind: libraryKind(sourceKind),
                name: config.name,
                configRef: config.credentialReference ?? id.uuidString,
                status: .ok,
                addedAt: Int64(now().timeIntervalSince1970 * 1_000)
            )
            try databaseWriter.saveSource(record)
        }

        if let data = try? JSONEncoder().encode(config) {
            preferences.set(data, forKey: PreferenceKey.sourceConfig)
        }
        preferences.set(sourceKind.rawValue, forKey: PreferenceKey.sourceKind)
        preferences.set(true, forKey: PreferenceKey.completed)

        savedSourceConfig = config
        isCompleted = true
        connectionState = .scanning
        step = .complete
        lastError = nil
        return config
    }

    /// Reports first-scan counts so the onboarding screen can show immediate
    /// progress instead of an opaque spinner.
    public func updateProgress(
        discovered: Int,
        indexed: Int,
        hasPlayableItem: Bool = false
    ) {
        discoveredItemCount = max(0, discovered)
        indexedFileCount = max(0, indexed)
        preferences.set(discoveredItemCount, forKey: PreferenceKey.discoveredItems)
        preferences.set(indexedFileCount, forKey: PreferenceKey.indexedFiles)

        if hasPlayableItem || discoveredItemCount > 0 {
            connectionState = .ready(itemCount: discoveredItemCount)
        } else {
            connectionState = .scanning
        }
    }

    public func failConnection(_ message: String) {
        lastError = message
        connectionState = .failed(message)
    }

    public var progressSummary: String {
        switch connectionState {
        case .idle:
            return "Connect a source to start building your library."
        case .scanning:
            return "Scanning… \(discoveredItemCount) items found, \(indexedFileCount) indexed."
        case .ready(let itemCount):
            return "\(itemCount) items ready to play."
        case .failed(let message):
            return message
        }
    }

    public var stepTitle: String {
        switch step {
        case .display:
            return "What does your TV support?"
        case .audio:
            return "How is your audio connected?"
        case .sourceType:
            return "Where are your movies stored?"
        case .sourceSetup:
            return "Connect your first source"
        case .complete:
            return "You're ready to watch"
        }
    }

    public var stepNumber: Int {
        min(3, step.rawValue + 1)
    }

    public var totalQuestions: Int {
        3
    }

    // MARK: - Criteria

    public static func hasCompleted(
        in preferences: any OnboardingPreferencesStore
    ) -> Bool {
        preferences.bool(forKey: PreferenceKey.completed)
    }

    // MARK: - Helpers

    private var trimmedSourceName: String {
        sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func credentialReference(for id: UUID) -> String {
        "source.\(id.uuidString)"
    }

    private func endpoint(
        for kind: SourceAdapters.SourceKind,
        address: String
    ) -> URL? {
        guard !address.isEmpty else {
            return nil
        }
        switch kind {
        case .plex, .jellyfin, .emby, .webdav:
            return URL(string: address)
        case .http:
            return URL(string: address)
        default:
            return nil
        }
    }

    private func host(
        for kind: SourceAdapters.SourceKind,
        address: String
    ) -> String? {
        switch kind {
        case .smb, .nfs:
            return address.isEmpty ? nil : address
        default:
            return nil
        }
    }

    private func libraryKind(
        _ kind: SourceAdapters.SourceKind
    ) -> LibraryCore.SourceKind {
        if kind == .googleDrive {
            return .gdrive
        }
        return LibraryCore.SourceKind(rawValue: kind.rawValue) ?? .local
    }
}

public enum OnboardingError: Error, Sendable, Equatable, LocalizedError {
    case missingSourceKind
    case missingSourceName

    public var errorDescription: String? {
        switch self {
        case .missingSourceKind:
            return "Choose a source type before connecting."
        case .missingSourceName:
            return "Give this source a name before connecting."
        }
    }
}
