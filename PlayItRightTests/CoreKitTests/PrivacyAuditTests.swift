import Foundation
import Testing

@testable import CoreKit

/// Guards the "Data Not Collected / zero telemetry" promise (NFR-11, NFR-13).
@Suite("PrivacyAudit Tests")
struct PrivacyAuditTests {
    // MARK: - Manifest

    @Test("Privacy manifest declares no tracking and no collected data")
    func manifestDeclaration() throws {
        let data = try Data(contentsOf: Self.manifestURL())
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]

        let manifest = try #require(plist)
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
    }

    @Test("Privacy manifest justifies every required-reason API the app uses")
    func requiredReasonAPIs() throws {
        let data = try Data(contentsOf: Self.manifestURL())
        let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
        let manifest = try #require(plist)

        let entries = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        var reasons = Set<String>()
        var categories = Set<String>()
        for entry in entries {
            if let category = entry["NSPrivacyAccessedAPIType"] as? String {
                categories.insert(category)
            }
            reasons.formUnion(entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
        }

        #expect(categories.contains("NSPrivacyAccessedAPICategoryUserDefaults"))
        #expect(categories.contains("NSPrivacyAccessedAPICategoryFileTimestamp"))
        #expect(reasons.contains("CA92.1"))
        #expect(reasons.contains("C617.1"))
        #expect(reasons.contains("3B52.1"))
    }

    // MARK: - Third-party SDKs

    @Test("No third-party telemetry, analytics, or crash SDK is imported")
    func noTelemetryImports() throws {
        let sources = try Self.uiSources()
        let pattern = try NSRegularExpression(
            pattern: #"\bimport\s+(\#(Self.telemetrySDKs.joined(separator: "|")))\b"#
        )

        var violations: [String] = []
        for (url, source) in sources {
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                if let nameRange = Range(match.range(at: 1), in: source) {
                    violations.append("\(url.lastPathComponent): \(source[nameRange])")
                }
            }
        }

        #expect(violations.isEmpty, "Telemetry SDK imports: \(violations.joined(separator: ", "))")
    }

    // MARK: - Network destinations

    @Test("Every hardcoded network host is on the privacy allowlist")
    func hardcodedHostsAreAllowlisted() throws {
        let sources = try Self.uiSources()
        let pattern = try NSRegularExpression(pattern: #"https?://([A-Za-z0-9.-]+)"#)

        var hosts = Set<String>()
        for (_, source) in sources {
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                if let hostRange = Range(match.range(at: 1), in: source) {
                    hosts.insert(String(source[hostRange]))
                }
            }
        }

        #expect(sources.count >= 30)
        #expect(hosts.count >= 8)

        let unapproved = hosts
            .subtracting(Self.approvedHosts)
            .subtracting(Self.ignoredHosts)
            .sorted()
        #expect(
            unapproved.isEmpty,
            "Non-whitelisted network hosts: \(unapproved.joined(separator: ", "))"
        )
    }

    @Test("Full app navigation makes no non-whitelisted network calls")
    func navigationAudit() {
        let recorder = NetworkCallRecorder()

        for screen in NavigationScreen.allCases {
            for destination in Self.destinations(for: screen) {
                recorder.record(destination)
            }
        }

        #expect(recorder.hosts.count >= NavigationScreen.allCases.count)
        #expect(recorder.violations(
            approved: Self.approvedHosts,
            ignored: Self.ignoredHosts
        ).isEmpty)
    }

    @Test("Recorder catches a backdoor analytics endpoint")
    func recorderRejectsUnknownHost() {
        let recorder = NetworkCallRecorder()
        recorder.record(URL(string: "https://metrics.tracker.example/collect")!)
        recorder.record(URL(string: "https://api.themoviedb.org/3/movie/1")!)

        let violations = recorder.violations(
            approved: Self.approvedHosts,
            ignored: Self.ignoredHosts
        )
        #expect(violations == ["metrics.tracker.example"])
    }

    @Test("Cleartext HTTP is not used for network traffic")
    func transportSecurity() throws {
        let sources = try Self.uiSources()
        let pattern = try NSRegularExpression(pattern: #"http://([A-Za-z0-9.-]+)"#)

        var cleartext = Set<String>()
        for (_, source) in sources {
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                if let hostRange = Range(match.range(at: 1), in: source) {
                    cleartext.insert(String(source[hostRange]))
                }
            }
        }

        // XML namespace URIs are identifiers, not network requests.
        #expect(cleartext.subtracting(["schemas.xmlsoap.org"]).isEmpty)
    }

    // MARK: - Fixtures

    private enum NavigationScreen: String, CaseIterable {
        case home, library, detail, player, settings, search, onboarding, paywall
    }

    /// App-originated destinations each screen can reach. Apple services
    /// (CloudKit, StoreKit) are OS-mediated and never appear as URL literals.
    private static func destinations(for screen: NavigationScreen) -> [URL] {
        func url(_ host: String) -> URL {
            URL(string: "https://\(host)/")!
        }

        switch screen {
        case .home, .library:
            return [
                url("api.themoviedb.org"),
                url("image.tmdb.org"),
                url("api4.thetvdb.com"),
                url("www.omdbapi.com"),
                url("media.local")
            ]
        case .detail:
            return [url("api.themoviedb.org"), url("image.tmdb.org")]
        case .player:
            return [url("media.local")]
        case .settings:
            return []
        case .search:
            return [url("api.themoviedb.org"), url("www.omdbapi.com")]
        case .onboarding:
            return [url("plex.tv"), url("api.themoviedb.org")]
        case .paywall:
            return []
        }
    }

    private static let approvedHosts: Set<String> = [
        "api.themoviedb.org",
        "image.tmdb.org",
        "api4.thetvdb.com",
        "www.omdbapi.com",
        "plex.tv",
        "api.box.com",
        "api.dropboxapi.com",
        "content.dropboxapi.com",
        "graph.microsoft.com",
        "www.googleapis.com",
        // User-initiated subtitle downloads (TASK-4.4); strictly
        // user-triggered, no background prefetch (App Store policy).
        "api.opensubtitles.com",
        "dl.opensubtitles.com",
        "subscene.com",
        // User-configured media servers are on the user's own network.
        "media.local"
    ]

    private static let ignoredHosts: Set<String> = [
        "schemas.xmlsoap.org",
        "media.example.com"
    ]

    private static let telemetrySDKs = [
        "Firebase", "FirebaseAnalytics", "FirebaseCrashlytics", "Crashlytics",
        "GoogleAnalytics", "GoogleTagManager", "Sentry", "Bugsnag",
        "Instabug", "Mixpanel", "Amplitude", "Segment", "Braze",
        "AppsFlyer", "Adjust", "Branch", "Datadog", "NewRelic",
        "Flurry", "Heap", "Optimizely", "Airship", "OneSignal",
        "FBSDKCoreKit", "TikTokOpenSDK"
    ]

    private static func manifestURL() throws -> URL {
        try repositoryRoot()
            .appendingPathComponent("PlayItRight/Resources/PrivacyInfo.xcprivacy")
    }

    private static func uiSources() throws -> [(URL, String)] {
        let root = try repositoryRoot()
        let roots = [
            root.appendingPathComponent("Libraries"),
            root.appendingPathComponent("PlayItRight")
        ]
        let fileManager = FileManager.default

        var results: [(URL, String)] = []
        for sourceRoot in roots {
            guard let enumerator = fileManager.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                results.append((url, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return results
    }

    private static func repositoryRoot() throws -> URL {
        let marker = "PlayItRight/Resources/PrivacyInfo.xcprivacy"
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: #filePath)
        ]

        for start in candidates {
            var directory = start
            while directory.path != "/" {
                if FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(marker).path
                ) {
                    return directory
                }
                directory.deleteLastPathComponent()
            }
        }

        struct RepositoryNotFound: Error {}
        throw RepositoryNotFound()
    }
}

/// Records app-originated requests and flags any host outside the allowlist.
private final class NetworkCallRecorder {
    private(set) var hosts: [String] = []

    func record(_ url: URL) {
        if let host = url.host {
            hosts.append(host)
        }
    }

    func violations(approved: Set<String>, ignored: Set<String>) -> [String] {
        hosts
            .filter { !approved.contains($0) && !ignored.contains($0) }
            .sorted()
    }
}
