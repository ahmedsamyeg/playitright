import Foundation

/// Represents the active deployment or runtime environment.
public enum AppEnvironment: String, Sendable, CaseIterable, Equatable {
    case development
    case testing
    case production

    public var name: String {
        rawValue
    }

    public var shortName: String {
        switch self {
        case .development: return "dev"
        case .testing: return "test"
        case .production: return "prod"
        }
    }

    public var isProduction: Bool {
        self == .production
    }

    public var isTesting: Bool {
        self == .testing
    }

    public var isDevelopment: Bool {
        self == .development
    }

    /// Initializes from standard names or short aliases (case-insensitive).
    public init?(string: String) {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "dev", "development":
            self = .development
        case "test", "testing":
            self = .testing
        case "prod", "production":
            self = .production
        default:
            return nil
        }
    }

    /// Resolves the current environment from process environment variables (`PLAYITRIGHT_ENV` or `APP_ENV`).
    /// Defaults to `.development` if not specified or unknown.
    public static var current: AppEnvironment {
        let envDict = ProcessInfo.processInfo.environment
        if let explicit = envDict["PLAYITRIGHT_ENV"] ?? envDict["APP_ENV"],
           let env = AppEnvironment(string: explicit) {
            return env
        }
        return .development
    }
}
