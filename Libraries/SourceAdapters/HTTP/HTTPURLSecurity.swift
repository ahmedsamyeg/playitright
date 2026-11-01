import Foundation

/// Errors raised while validating source URLs.
public enum HTTPURLSecurityError: Error, Equatable, Sendable, LocalizedError {
    /// The URL used a scheme outside the allowlist.
    case unsupportedScheme(String)

    /// The URL had no host.
    case missingHost

    /// The URL embedded credentials instead of a Keychain reference.
    case embeddedCredentials

    /// The URL contained a `..` path segment.
    case pathTraversal(String)

    /// A relative URL was supplied without a base.
    case missingBaseURL(String)

    /// A redirect exceeded the configured hop limit.
    case redirectLimitExceeded(max: Int)

    /// A `.strm` file contained no URL.
    case emptyStrm

    /// A UNC path is not an HTTP/HTTPS target.
    case unsupportedUNC(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            return "The '\(scheme)' URL scheme is not allowed for this source."
        case .missingHost:
            return "The URL has no host."
        case .embeddedCredentials:
            return "URLs must not embed credentials; store them in the Keychain."
        case .pathTraversal(let path):
            return "The URL contains a path traversal segment: '\(path)'."
        case .missingBaseURL(let value):
            return "The relative URL '\(value)' requires a base URL."
        case .redirectLimitExceeded(let max):
            return "The redirect limit of \(max) hops was exceeded."
        case .emptyStrm:
            return "The .strm file did not contain a target URL."
        case .unsupportedUNC(let value):
            return "The UNC path '\(value)' is not an HTTP/HTTPS target."
        }
    }
}

/// URL validation and redirect policy for HTTP/HTTPS sources.
///
/// Implements NFR-9: a scheme allowlist, no embedded credentials, no path
/// traversal, and a bounded redirect chain. `.strm` targets may point at any
/// host by default, but callers can restrict hosts explicitly.
public struct HTTPURLSecurityPolicy: Sendable, Equatable {
    /// Schemes this policy accepts.
    public var allowedSchemes: Set<String>

    /// When non-nil, hosts are restricted to this set (case-insensitive).
    public var allowedHosts: Set<String>?

    /// Maximum redirect hops.
    public var maxRedirects: Int

    public init(
        allowedSchemes: Set<String> = ["http", "https"],
        allowedHosts: Set<String>? = nil,
        maxRedirects: Int = 3
    ) {
        self.allowedSchemes = Set(allowedSchemes.map { $0.lowercased() })
        self.allowedHosts = allowedHosts.map { Set($0.map { $0.lowercased() }) }
        self.maxRedirects = max(0, maxRedirects)
    }

    /// Validates an absolute URL.
    @discardableResult
    public func validate(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw HTTPURLSecurityError.unsupportedScheme("")
        }
        guard allowedSchemes.contains(scheme) else {
            throw HTTPURLSecurityError.unsupportedScheme(scheme)
        }

        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw HTTPURLSecurityError.missingHost
        }

        if url.user != nil || url.password != nil {
            throw HTTPURLSecurityError.embeddedCredentials
        }

        if let allowedHosts, !allowedHosts.contains(host) {
            throw HTTPURLSecurityError.missingHost
        }

        try validatePath(url.path)
        return url
    }

    /// Resolves a raw `.strm` target or configured location.
    ///
    /// Relative targets resolve against `baseURL` and must stay inside the
    /// base directory; absolute targets may point elsewhere but still must pass
    /// the scheme/host/path checks.
    public func resolve(_ raw: String, relativeTo baseURL: URL?) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HTTPURLSecurityError.emptyStrm
        }

        if trimmed.hasPrefix("\\\\") || trimmed.hasPrefix("//") {
            throw HTTPURLSecurityError.unsupportedUNC(trimmed)
        }
        if trimmed.contains("\\") {
            throw HTTPURLSecurityError.unsupportedUNC(trimmed)
        }

        let isAbsolute = URLComponents(string: trimmed)?.scheme != nil
        let resolved: URL
        if isAbsolute {
            guard let url = URL(string: trimmed) else {
                throw HTTPURLSecurityError.unsupportedScheme(trimmed)
            }
            resolved = url
        } else {
            guard let baseURL else {
                throw HTTPURLSecurityError.missingBaseURL(trimmed)
            }
            guard let url = URL(string: trimmed, relativeTo: baseURL)?
                .absoluteURL else {
                throw HTTPURLSecurityError.missingBaseURL(trimmed)
            }

            let root = baseURL.hasDirectoryPath
                ? baseURL
                : baseURL.deletingLastPathComponent()
            let rootPath = normalizedPath(root)
            let resolvedPath = normalizedPath(url)
            guard resolvedPath.hasPrefix(rootPath) else {
                throw HTTPURLSecurityError.pathTraversal(trimmed)
            }
            resolved = url
        }

        return try validate(resolved)
    }

    /// Validates a redirect target and hop count.
    @discardableResult
    public func validateRedirect(
        to target: URL,
        hop: Int
    ) throws -> URL {
        guard hop <= maxRedirects else {
            throw HTTPURLSecurityError.redirectLimitExceeded(
                max: maxRedirects
            )
        }
        return try validate(target)
    }

    private func validatePath(_ path: String) throws {
        guard !path.isEmpty else {
            return
        }
        for segment in path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ) {
            let decoded = String(segment)
                .removingPercentEncoding ?? String(segment)
            if decoded == ".." || decoded == "." {
                throw HTTPURLSecurityError.pathTraversal(path)
            }
            if decoded.contains("\u{0}") {
                throw HTTPURLSecurityError.pathTraversal(path)
            }
        }
    }

    private func normalizedPath(_ url: URL) -> String {
        let path = url.standardized.path
        return path.hasSuffix("/") ? path : path + "/"
    }
}
