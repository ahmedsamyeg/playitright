import Foundation
import Testing

@testable import PlayItRight

/// Verifies that every static, user-visible string in the UI source trees is
/// present in the String Catalog with an English baseline (NFR-22).
@Suite("LocalizationCoverage Tests")
struct LocalizationCoverageTests {
    // MARK: - Catalog

    @Test("Catalog loads with an English source language")
    func catalogBaseline() throws {
        let catalog = try Self.loadCatalog()

        #expect(catalog.sourceLanguage == "en")
        #expect(catalog.version == "1.0")
        #expect(catalog.strings.count >= 80)
    }

    @Test("Every catalog entry has a non-empty English translation")
    func englishTranslations() throws {
        let catalog = try Self.loadCatalog()

        for (key, entry) in catalog.strings {
            let unit = entry.localizations?["en"]?.stringUnit
            #expect(unit != nil, "\(key) has no English string unit")
            #expect(
                unit?.value.isEmpty == false,
                "\(key) has an empty English translation"
            )
            #expect(
                unit?.state == "translated",
                "\(key) is not marked translated"
            )
            #expect(
                !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Catalog contains an empty key"
            )
        }
    }

    // MARK: - Source crawler

    @Test("Crawler scans the shipped UI source trees")
    func crawlerCoverage() throws {
        let scan = try Self.crawlUIStrings()

        // Guard against the crawler silently finding nothing when paths move.
        #expect(scan.scannedFiles >= 30, "Only scanned \(scan.scannedFiles) files")
        #expect(scan.keys.count >= 80, "Only found \(scan.keys.count) strings")
        #expect(scan.keys.contains("PlayItRight Pro"))
        #expect(scan.keys.contains("Clear Cache"))
    }

    @Test("No hardcoded user-visible strings remain in UI views")
    func zeroHardcodedStrings() throws {
        let catalog = try Self.loadCatalog()
        let scan = try Self.crawlUIStrings()

        let missing = scan.keys
            .subtracting(catalog.strings.keys)
            .sorted()

        #expect(
            missing.isEmpty,
            "Hardcoded strings missing from Localizable.xcstrings: \(missing.joined(separator: " | "))"
        )
    }

    @Test("Crawler skips interpolated strings, which are localized at runtime")
    func crawlerSkipsInterpolation() throws {
        let scan = try Self.crawlUIStrings()

        let interpolated = scan.keys.filter { $0.contains("\\(") }
        #expect(interpolated.isEmpty)
    }

    // MARK: - Helpers

    private struct StringCatalog: Decodable {
        let sourceLanguage: String
        let version: String
        let strings: [String: CatalogEntry]
    }

    private struct CatalogEntry: Decodable {
        let localizations: [String: CatalogLocalization]?
    }

    private struct CatalogLocalization: Decodable {
        let stringUnit: CatalogStringUnit?
    }

    private struct CatalogStringUnit: Decodable {
        let state: String?
        let value: String
    }

    private struct CrawlResult {
        var scannedFiles: Int
        var keys: Set<String>
    }

    private static func loadCatalog() throws -> StringCatalog {
        let url = try repositoryRoot()
            .appendingPathComponent("Libraries/PlayItRight/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(StringCatalog.self, from: data)
    }

    /// Finds every static string literal passed to a user-visible SwiftUI API.
    private static func crawlUIStrings() throws -> CrawlResult {
        let root = try repositoryRoot()
        let roots = [
            root.appendingPathComponent("Libraries/PlayItRight"),
            root.appendingPathComponent("PlayItRight")
        ]

        let fileManager = FileManager.default
        var files: [URL] = []
        for sourceRoot in roots {
            guard let enumerator = fileManager.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(url)
            }
        }

        var keys = Set<String>()
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            keys.formUnion(strings(in: source))
        }
        return CrawlResult(scannedFiles: files.count, keys: keys)
    }

    /// The SwiftUI APIs whose first argument is a user-visible string.
    private static let stringAPIs = [
        "Text", "Button", "Label", "TextField", "SecureField",
        "Toggle", "Picker", "Section"
    ]

    private static let argumentPatterns: [NSRegularExpression] = {
        let callPatterns = stringAPIs.map {
            #"\b\#($0)\(\s*"((?:[^"\\]|\\.)*)""#
        }
        let modifierPatterns = [
            #"\.navigationTitle\(\s*"((?:[^"\\]|\\.)*)""#,
            #"\.accessibilityLabel\(\s*"((?:[^"\\]|\\.)*)""#,
            #"\.accessibilityHint\(\s*"((?:[^"\\]|\\.)*)""#
        ]
        return (callPatterns + modifierPatterns).compactMap {
            try? NSRegularExpression(pattern: $0)
        }
    }()

    private static func strings(in source: String) -> Set<String> {
        let range = NSRange(source.startIndex..., in: source)
        var result = Set<String>()

        for pattern in argumentPatterns {
            for match in pattern.matches(in: source, range: range) {
                guard let matchRange = Range(match.range(at: 1), in: source) else {
                    continue
                }
                let value = String(source[matchRange])
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                // Interpolated strings need runtime localization; the catalog
                // stores their static format rather than the resolved value.
                guard !value.contains("\\(") else {
                    continue
                }
                result.insert(value)
            }
        }
        return result
    }

    /// Finds the repository root regardless of the test runner's directory.
    private static func repositoryRoot() throws -> URL {
        let catalogPath = "Libraries/PlayItRight/Resources/Localizable.xcstrings"
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: #filePath)
        ]

        for start in candidates {
            var directory = start
            while directory.path != "/" {
                if FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(catalogPath).path
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
