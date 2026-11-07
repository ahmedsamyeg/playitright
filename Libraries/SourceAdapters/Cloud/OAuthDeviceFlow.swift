import Foundation
import Security

// MARK: - Configuration

/// OAuth endpoints and client identity for one cloud provider.
public struct OAuthProviderConfiguration: Sendable, Equatable {
    /// Human-readable provider name used in prompts and diagnostics.
    public var name: String

    /// RFC 8628 device authorization endpoint.
    public var deviceAuthorizationURL: URL

    /// Token endpoint used for both device-code and refresh grants.
    public var tokenURL: URL

    /// Public client id issued by the provider.
    public var clientID: String

    /// Optional client secret for providers that require one on the device
    /// grant (most TV clients are public clients and do not).
    public var clientSecret: String?

    /// Requested scopes.
    public var scopes: [String]

    /// Provider-specific authorization parameters, such as an audience.
    public var authorizationParameters: [String: String]

    /// Provider-specific token parameters, such as a resource id.
    public var tokenParameters: [String: String]

    public init(
        name: String,
        deviceAuthorizationURL: URL,
        tokenURL: URL,
        clientID: String,
        clientSecret: String? = nil,
        scopes: [String] = [],
        authorizationParameters: [String: String] = [:],
        tokenParameters: [String: String] = [:]
    ) {
        self.name = name
        self.deviceAuthorizationURL = deviceAuthorizationURL
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.authorizationParameters = authorizationParameters
        self.tokenParameters = tokenParameters
    }
}

// MARK: - Models

/// The RFC 8628 device authorization response shown on the TV.
public struct OAuthDeviceAuthorization: Sendable, Equatable {
    /// Opaque code polled against the token endpoint. Never display this.
    public let deviceCode: String

    /// Short code the user enters at ``verificationURI``.
    public let userCode: String

    /// Page the user visits to approve the device.
    public let verificationURI: URL

    /// Pre-filled verification URL, when the provider supplies one.
    public let verificationURIComplete: URL?

    /// Lifetime of the device code in seconds.
    public let expiresIn: TimeInterval

    /// Minimum polling interval in seconds.
    public let interval: TimeInterval

    public init(
        deviceCode: String,
        userCode: String,
        verificationURI: URL,
        verificationURIComplete: URL? = nil,
        expiresIn: TimeInterval = 600,
        interval: TimeInterval = 5
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresIn = max(1, expiresIn)
        self.interval = max(1, interval)
    }

    /// Whether the user code has expired at `date`.
    public func isExpired(
        at date: Date,
        issuedAt: Date
    ) -> Bool {
        date.timeIntervalSince(issuedAt) >= expiresIn
    }
}

/// An access/refresh token pair returned by the token endpoint.
public struct OAuthToken: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String
    public var scope: String?

    /// When the token was issued.
    public var issuedAt: Date

    /// Lifetime in seconds, when the provider supplies one.
    public var expiresIn: TimeInterval?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        tokenType: String = "Bearer",
        scope: String? = nil,
        issuedAt: Date = Date(),
        expiresIn: TimeInterval? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scope = scope
        self.issuedAt = issuedAt
        self.expiresIn = expiresIn.map { max(0, $0) }
    }

    /// Absolute expiry time, when the provider supplied a lifetime.
    public var expiresAt: Date? {
        expiresIn.map { issuedAt.addingTimeInterval($0) }
    }

    /// Whether the access token is expired at `date`, including a safety leeway.
    public func isExpired(
        at date: Date = Date(),
        leeway: TimeInterval = 60
    ) -> Bool {
        guard let expiresAt else {
            return false
        }
        return date.addingTimeInterval(leeway) >= expiresAt
    }
}

/// Errors surfaced by ``OAuthDeviceFlow``.
public enum OAuthError: Error, Equatable, Sendable, LocalizedError {
    case invalidResponse(String)
    case transport(String)
    case authorizationPending
    case slowDown
    case accessDenied
    case expiredDeviceCode
    case refreshUnavailable
    case server(String, String?)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let message):
            return "The sign-in response was invalid: \(message)"
        case .transport(let message):
            return "The sign-in request failed: \(message)"
        case .authorizationPending:
            return "Waiting for approval on the provider's website."
        case .slowDown:
            return "The provider asked the device to poll less often."
        case .accessDenied:
            return "Sign-in was denied."
        case .expiredDeviceCode:
            return "The sign-in code expired. Please try again."
        case .refreshUnavailable:
            return "This sign-in cannot be refreshed. Please sign in again."
        case .server(let error, let description):
            if let description, !description.isEmpty {
                return "The provider rejected the request: \(description)"
            }
            return "The provider rejected the request (\(error))."
        case .cancelled:
            return "Sign-in was cancelled."
        }
    }
}

// MARK: - Seams

/// HTTP seam so the flow can be tested without a network.
public protocol OAuthHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession-backed transport.
public struct URLSessionOAuthTransport: OAuthHTTPTransport, Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse("The response was not HTTP.")
        }
        return (data, http)
    }
}

/// Token persistence seam. Production uses ``KeychainOAuthTokenStore``; tests
/// use ``InMemoryOAuthTokenStore`` so they never touch the host Keychain.
public protocol OAuthTokenStoring: Sendable {
    func token(for key: String) throws -> OAuthToken?
    func save(_ token: OAuthToken, for key: String) throws
    func removeToken(for key: String) throws
}

/// Process-local token store for tests and previews.
public final class InMemoryOAuthTokenStore: OAuthTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: OAuthToken] = [:]

    public init() {}

    public func token(for key: String) throws -> OAuthToken? {
        lock.lock()
        defer { lock.unlock() }
        return tokens[key]
    }

    public func save(_ token: OAuthToken, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        tokens[key] = token
    }

    public func removeToken(for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        tokens.removeValue(forKey: key)
    }
}

/// Keychain-backed token store (SRC-3, SRC-12).
///
/// Tokens are generic-password items namespaced by `service`, marked
/// `kSecAttrAccessibleAfterFirstUnlock` so background refresh can read them
/// after the first unlock.
public final class KeychainOAuthTokenStore: OAuthTokenStoring, Sendable {
    private let service: String

    public init(service: String = "com.playitright.oauth") {
        self.service = service
    }

    public func token(for key: String) throws -> OAuthToken? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw OAuthError.invalidResponse("The Keychain item is not data.")
            }
            do {
                return try JSONDecoder().decode(OAuthToken.self, from: data)
            } catch {
                throw OAuthError.invalidResponse("The stored token could not be decoded.")
            }
        case errSecItemNotFound:
            return nil
        default:
            throw OAuthError.transport("Keychain read failed (\(status)).")
        }
    }

    public func save(_ token: OAuthToken, for key: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(token)
        } catch {
            throw OAuthError.invalidResponse("The token could not be encoded.")
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(
            baseQuery(for: key) as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var insert = baseQuery(for: key)
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw OAuthError.transport("Keychain write failed (\(addStatus)).")
            }
        } else if updateStatus != errSecSuccess {
            throw OAuthError.transport("Keychain write failed (\(updateStatus)).")
        }
    }

    public func removeToken(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OAuthError.transport("Keychain delete failed (\(status)).")
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

// MARK: - Flow

/// RFC 8628 OAuth 2.0 device authorization grant for TV sign-in (SRC-12).
///
/// The flow is deliberately UI-agnostic: ``start()`` returns the code to show
/// on screen, and ``poll(for:)`` returns the token once the user approves on a
/// phone or computer. ``authorize(onAuthorization:)`` combines both for the
/// common case.
public struct OAuthDeviceFlow: Sendable {
    /// Sleep seam used to honor the polling interval in tests.
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    public let configuration: OAuthProviderConfiguration
    public let providerKey: String
    public let store: any OAuthTokenStoring

    private let transport: any OAuthHTTPTransport
    private let sleep: Sleeper
    private let now: @Sendable () -> Date

    public init(
        configuration: OAuthProviderConfiguration,
        providerKey: String? = nil,
        store: any OAuthTokenStoring = InMemoryOAuthTokenStore(),
        transport: any OAuthHTTPTransport = URLSessionOAuthTransport(),
        sleep: @escaping Sleeper = { seconds in
            try await Task.sleep(
                nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
            )
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.providerKey = providerKey ?? "oauth.\(configuration.clientID)"
        self.store = store
        self.transport = transport
        self.sleep = sleep
        self.now = now
    }

    // MARK: Device authorization

    /// Requests a device and user code from the provider.
    public func start() async throws -> OAuthDeviceAuthorization {
        var parameters = configuration.authorizationParameters
        parameters["client_id"] = configuration.clientID
        if !configuration.scopes.isEmpty {
            parameters["scope"] = configuration.scopes.joined(separator: " ")
        }
        if let secret = configuration.clientSecret {
            parameters["client_secret"] = secret
        }

        let request = Self.formRequest(
            url: configuration.deviceAuthorizationURL,
            parameters: parameters
        )
        let data = try await send(request, decodingError: true)
        let response: DeviceAuthorizationResponse
        do {
            response = try JSONDecoder().decode(
                DeviceAuthorizationResponse.self,
                from: data
            )
        } catch {
            throw OAuthError.invalidResponse(
                "The device authorization JSON was malformed."
            )
        }

        if let error = response.error {
            throw Self.error(for: error, description: response.errorDescription)
        }
        guard let deviceCode = response.deviceCode,
              !deviceCode.isEmpty,
              let userCode = response.userCode,
              !userCode.isEmpty,
              let verificationText = response.verificationURI,
              let verificationURI = URL(string: verificationText) else {
            throw OAuthError.invalidResponse(
                "The device authorization response is missing required fields."
            )
        }

        return OAuthDeviceAuthorization(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: verificationURI,
            verificationURIComplete: response.verificationURIComplete.flatMap(
                URL.init(string:)
            ),
            expiresIn: response.expiresIn ?? 600,
            interval: response.interval ?? 5
        )
    }

    /// Polls until the user approves, denies, or the code expires.
    public func poll(
        for authorization: OAuthDeviceAuthorization
    ) async throws -> OAuthToken {
        let issuedAt = now()
        var interval = authorization.interval

        while true {
            try Task.checkCancellation()
            if authorization.isExpired(at: now(), issuedAt: issuedAt) {
                throw OAuthError.expiredDeviceCode
            }

            do {
                let token = try await requestToken(
                    grant: [
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                        "device_code": authorization.deviceCode,
                        "client_id": configuration.clientID
                    ],
                    fallbackRefreshToken: nil
                )
                try store.save(token, for: providerKey)
                return token
            } catch OAuthError.authorizationPending {
                try await sleep(interval)
            } catch OAuthError.slowDown {
                interval += 5
                try await sleep(interval)
            }
        }
    }

    /// Starts the flow, hands the code to the UI, then polls for the token.
    public func authorize(
        onAuthorization: @Sendable (OAuthDeviceAuthorization) async -> Void
    ) async throws -> OAuthToken {
        let authorization = try await start()
        await onAuthorization(authorization)
        return try await poll(for: authorization)
    }

    // MARK: Stored tokens

    /// Returns the stored token for this provider, if any.
    public func storedToken() throws -> OAuthToken? {
        try store.token(for: providerKey)
    }

    /// Returns a usable token, refreshing it when it is close to expiry.
    public func validToken(leeway: TimeInterval = 60) async throws -> OAuthToken? {
        guard let token = try store.token(for: providerKey) else {
            return nil
        }
        if token.isExpired(at: now(), leeway: leeway) {
            return try await refresh(token)
        }
        return token
    }

    /// Exchanges the refresh token for a new access token and stores it.
    public func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken,
              !refreshToken.isEmpty else {
            throw OAuthError.refreshUnavailable
        }

        let refreshed = try await requestToken(
            grant: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": configuration.clientID
            ],
            fallbackRefreshToken: refreshToken
        )
        try store.save(refreshed, for: providerKey)
        return refreshed
    }

    /// Removes the stored token, for example when the user signs out.
    public func signOut() throws {
        try store.removeToken(for: providerKey)
    }

    // MARK: Requests

    private func requestToken(
        grant: [String: String],
        fallbackRefreshToken: String?
    ) async throws -> OAuthToken {
        var parameters = configuration.tokenParameters
        parameters.merge(grant) { _, new in new }
        if let secret = configuration.clientSecret {
            parameters["client_secret"] = secret
        }

        let request = Self.formRequest(
            url: configuration.tokenURL,
            parameters: parameters
        )
        let data = try await send(request, decodingError: true)
        let response: TokenResponse
        do {
            response = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthError.invalidResponse(
                "The token response JSON was malformed."
            )
        }

        if let error = response.error {
            throw Self.error(
                for: error,
                description: response.errorDescription
            )
        }
        guard let accessToken = response.accessToken,
              !accessToken.isEmpty else {
            throw OAuthError.invalidResponse(
                "The token response is missing an access token."
            )
        }

        return OAuthToken(
            accessToken: accessToken,
            refreshToken: response.refreshToken ?? fallbackRefreshToken,
            tokenType: response.tokenType ?? "Bearer",
            scope: response.scope,
            issuedAt: now(),
            expiresIn: response.expiresIn
        )
    }

    private func send(
        _ request: URLRequest,
        decodingError: Bool
    ) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw OAuthError.cancelled
        } catch {
            throw OAuthError.transport(error.localizedDescription)
        }

        if !(200..<300).contains(response.statusCode) {
            // OAuth token errors arrive as JSON even with a 4xx status.
            if decodingError,
               let failure = try? JSONDecoder().decode(
                   TokenResponse.self,
                   from: data
               ),
               let error = failure.error {
                throw Self.error(
                    for: error,
                    description: failure.errorDescription
                )
            }
            throw OAuthError.server(
                "HTTP \(response.statusCode)",
                String(data: data, encoding: .utf8)
            )
        }
        return data
    }

    static func formRequest(
        url: URL,
        parameters: [String: String]
    ) -> URLRequest {
        var components = URLComponents()
        components.queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.httpBody = components.percentEncodedQuery?
            .data(using: .utf8)
        return request
    }

    private static func error(
        for code: String,
        description: String?
    ) -> OAuthError {
        switch code {
        case "authorization_pending":
            return .authorizationPending
        case "slow_down":
            return .slowDown
        case "access_denied":
            return .accessDenied
        case "expired_token":
            return .expiredDeviceCode
        default:
            return .server(code, description)
        }
    }
}

// MARK: - Wire formats

private struct DeviceAuthorizationResponse: Decodable {
    let deviceCode: String?
    let userCode: String?
    let verificationURI: String?
    let verificationURIComplete: String?
    let expiresIn: TimeInterval?
    let interval: TimeInterval?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
        case error
        case errorDescription = "error_description"
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let tokenType: String?
    let expiresIn: TimeInterval?
    let refreshToken: String?
    let scope: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case error
        case errorDescription = "error_description"
    }
}
