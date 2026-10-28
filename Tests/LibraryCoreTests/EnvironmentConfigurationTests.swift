import Testing
import Foundation
@testable import LibraryCore

@Suite("Environment & Configuration Tests")
struct EnvironmentConfigurationTests {
    @Test("AppEnvironment parsing and aliases")
    func appEnvironmentAliases() {
        #expect(AppEnvironment(string: "dev") == .development)
        #expect(AppEnvironment(string: "development") == .development)
        #expect(AppEnvironment(string: "DEV") == .development)

        #expect(AppEnvironment(string: "test") == .testing)
        #expect(AppEnvironment(string: "testing") == .testing)

        #expect(AppEnvironment(string: "prod") == .production)
        #expect(AppEnvironment(string: "production") == .production)

        #expect(AppEnvironment(string: "invalid") == nil)

        #expect(AppEnvironment.development.shortName == "dev")
        #expect(AppEnvironment.testing.shortName == "test")
        #expect(AppEnvironment.production.shortName == "prod")
    }

    @Test("DotEnv text parsing handles quotes and comments")
    func dotEnvParsing() {
        let sample = """
        # Global Comment
        KEY1=simple_value
        KEY2="quoted value with spaces"
        KEY3='single quoted value'
        KEY4=value_with_inline # inline comment
        EMPTY_VALUE=
        # ANOTHER_KEY=ignored
        TRIMMED_KEY  =  trimmed_value
        """

        let parsed = DotEnv.parse(sample)
        #expect(parsed["KEY1"] == "simple_value")
        #expect(parsed["KEY2"] == "quoted value with spaces")
        #expect(parsed["KEY3"] == "single quoted value")
        #expect(parsed["KEY4"] == "value_with_inline")
        #expect(parsed["EMPTY_VALUE"] == "")
        #expect(parsed["TRIMMED_KEY"] == "trimmed_value")
        #expect(parsed["ANOTHER_KEY"] == nil)
    }

    @Test("DotEnv directory loading merges config/environments files")
    func dotEnvDirectoryLoading() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let devVars = DotEnv.load(environment: .development, directory: root, includeProcessEnvironment: false)
        #expect(devVars["PLAYITRIGHT_ENV"] == "dev")
        #expect(devVars["PLAYITRIGHT_DB_PATH"] == "db/dev/library.db")

        let testVars = DotEnv.load(environment: .testing, directory: root, includeProcessEnvironment: false)
        #expect(testVars["PLAYITRIGHT_ENV"] == "test")
        #expect(testVars["PLAYITRIGHT_DB_PATH"] == ":memory:")

        let prodVars = DotEnv.load(environment: .production, directory: root, includeProcessEnvironment: false)
        #expect(prodVars["PLAYITRIGHT_ENV"] == "prod")
    }

    @Test("EnvironmentConfiguration resolves paths and options per environment")
    func environmentConfigurationResolution() {
        // Dev
        let devConfig = EnvironmentConfiguration(environment: .development, variables: [
            "PLAYITRIGHT_ENV": "dev",
            "PLAYITRIGHT_DB_PATH": "db/dev/library.db",
            "PLAYITRIGHT_BUSY_TIMEOUT": "7.5",
            "PLAYITRIGHT_CACHE_SIZE_KB": "16384"
        ])
        #expect(!devConfig.isInMemoryDatabase)
        #expect(devConfig.databaseURL?.lastPathComponent == "library.db")
        #expect(devConfig.busyTimeout == 7.5)
        #expect(devConfig.cacheSizeInKiB == 16384)

        // Test
        let testConfig = EnvironmentConfiguration(environment: .testing, variables: [
            "PLAYITRIGHT_ENV": "test",
            "PLAYITRIGHT_DB_PATH": ":memory:"
        ])
        #expect(testConfig.isInMemoryDatabase)
        #expect(testConfig.databaseURL == nil)

        // Prod
        let prodConfig = EnvironmentConfiguration(environment: .production, variables: [
            "PLAYITRIGHT_ENV": "prod"
        ])
        #expect(!prodConfig.isInMemoryDatabase)
        #expect(prodConfig.databaseURL?.lastPathComponent == "library.db")
    }

    @Test("MediaDatabase.open with environment loads successfully")
    func mediaDatabaseOpenWithEnvironment() throws {
        // Test environment defaults to in-memory database
        let db = try MediaDatabase.open(environment: .testing)
        #expect(try db.runQuickCheck() == true)

        try db.write { dbConn in
            let movie = MovieRecord(tmdbId: 999, title: "Env Test Movie")
            try movie.insert(dbConn)
        }

        let fetched = try db.read { dbConn in
            try MovieRecord.fetchOne(dbConn, key: 999)
        }
        #expect(fetched?.title == "Env Test Movie")
    }
}
