import Foundation
import Testing
@testable import SourceAdapters

// MARK: - Test doubles

private struct StubResponse: Sendable {
    let status: Int
    let body: String
}

private actor StubOAuthTransport: OAuthHTTPTransport {
    private var responses: [StubResponse]
    private var recorded: [URLRequest] = []

    init(_ responses: [StubResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.append(request)
        guard !responses.isEmpty else {
            throw OAuthError.invalidResponse("No stub response queued.")
        }
        let response = responses.removeFirst()
        guard let url = request.url,
              let http = HTTPURLResponse(
                url: url,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            throw OAuthError.invalidResponse("Could not build a response.")
        }
        return (Data(response.body.utf8), http)
    }

    func requests() -> [URLRequest] {
        recorded
    }
}

private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []

    func record(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        values.append(interval)
    }

    var intervals: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class DateSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        if dates.count > 1 {
            return dates.removeFirst()
        }
        return dates.first ?? Date(timeIntervalSince1970: 0)
    }
}

private func provider() -> OAuthProviderConfiguration {
    OAuthProviderConfiguration(
        name: "Example Cloud",
        deviceAuthorizationURL: URL(string: "https://example.com/device")!,
        tokenURL: URL(string: "https://example.com/token")!,
        clientID: "client-123",
        scopes: ["read", "write"]
    )
}

private func formBody(_ request: URLRequest) -> [String: String] {
    guard let data = request.httpBody,
          let text = String(data: data, encoding: .utf8) else {
        return [:]
    }
    var components = URLComponents()
    components.percentEncodedQuery = text
    let items = components.queryItems ?? []
    return Dictionary(
        uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        }
    )
}

private func tokenJSON(
    access: String = "access-1",
    refresh: String? = "refresh-1",
    expiresIn: Int? = 3_600
) -> String {
    var fields: [String: String] = [
        "access_token": "\"\(access)\"",
        "token_type": "\"Bearer\"",
        "scope": "\"read write\""
    ]
    if let refresh {
        fields["refresh_token"] = "\"\(refresh)\""
    }
    if let expiresIn {
        fields["expires_in"] = String(expiresIn)
    }
    let body = fields
        .map { "\"\($0.key)\":\($0.value)" }
        .joined(separator: ",")
    return "{\(body)}"
}

private let deviceJSON = """
{
  "device_code": "device-abc",
  "user_code": "ABCD-EFGH",
  "verification_uri": "https://example.com/activate",
  "verification_uri_complete": "https://example.com/activate?code=ABCD-EFGH",
  "expires_in": 900,
  "interval": 5
}
"""

// MARK: - Tests

@Suite("OAuthDeviceFlow Tests")
struct OAuthDeviceFlowTests {
    @Test("Device authorization responses parse and build the right request")
    func deviceAuthorizationParsing() async throws {
        let transport = StubOAuthTransport(
            [StubResponse(status: 200, body: deviceJSON)]
        )
        let flow = OAuthDeviceFlow(
            configuration: provider(),
            store: InMemoryOAuthTokenStore(),
            transport: transport,
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let authorization = try await flow.start()
        #expect(authorization.deviceCode == "device-abc")
        #expect(authorization.userCode == "ABCD-EFGH")
        #expect(authorization.verificationURI.absoluteString
            == "https://example.com/activate")
        #expect(authorization.verificationURIComplete?.absoluteString
            == "https://example.com/activate?code=ABCD-EFGH")
        #expect(authorization.expiresIn == 900)
        #expect(authorization.interval == 5)

        let requests = await transport.requests()
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://example.com/device")
        #expect(request.value(forHTTPHeaderField: "Content-Type")
            == "application/x-www-form-urlencoded")

        let body = formBody(request)
        #expect(body["client_id"] == "client-123")
        #expect(body["scope"] == "read write")
    }

    @Test("Polling waits for authorization_pending then stores the token")
    func pollingHonorsInterval() async throws {
        let transport = StubOAuthTransport([
            StubResponse(
                status: 400,
                body: #"{"error":"authorization_pending"}"#
            ),
            StubResponse(status: 200, body: tokenJSON())
        ])
        let store = InMemoryOAuthTokenStore()
        let sleeper = SleepRecorder()
        let flow = OAuthDeviceFlow(
            configuration: provider(),
            store: store,
            transport: transport,
            sleep: { sleeper.record($0) },
            now: { Date(timeIntervalSince1970: 2_000) }
        )

        let authorization = OAuthDeviceAuthorization(
            deviceCode: "device-abc",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://example.com/activate")!,
            expiresIn: 900,
            interval: 5
        )
        let token = try await flow.poll(for: authorization)

        #expect(token.accessToken == "access-1")
        #expect(token.refreshToken == "refresh-1")
        #expect(token.expiresIn == 3_600)
        #expect(sleeper.intervals == [5])

        let requests = await transport.requests()
        #expect(requests.count == 2)
        let body = formBody(requests[1])
        #expect(
            body["grant_type"]
                == "urn:ietf:params:oauth:grant-type:device_code"
        )
        #expect(body["device_code"] == "device-abc")
        #expect(body["client_id"] == "client-123")

        let stored = try store.token(for: flow.providerKey)
        #expect(stored == token)
    }

    @Test("slow_down increases the polling interval by five seconds")
    func slowDownBacksOff() async throws {
        let transport = StubOAuthTransport([
            StubResponse(status: 400, body: #"{"error":"slow_down"}"#),
            StubResponse(status: 400, body: #"{"error":"slow_down"}"#),
            StubResponse(status: 200, body: tokenJSON())
        ])
        let sleeper = SleepRecorder()
        let flow = OAuthDeviceFlow(
            configuration: provider(),
            store: InMemoryOAuthTokenStore(),
            transport: transport,
            sleep: { sleeper.record($0) },
            now: { Date(timeIntervalSince1970: 3_000) }
        )

        let authorization = OAuthDeviceAuthorization(
            deviceCode: "device-abc",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://example.com/activate")!,
            expiresIn: 900,
            interval: 5
        )
        _ = try await flow.poll(for: authorization)

        #expect(sleeper.intervals == [10, 15])
        let count = await transport.requests().count
        #expect(count == 3)
    }

    @Test("Refresh exchanges the refresh token and keeps it when omitted")
    func tokenRefresh() async throws {
        let transport = StubOAuthTransport([
            StubResponse(status: 200, body: tokenJSON(access: "access-2"))
        ])
        let store = InMemoryOAuthTokenStore()
        let flow = OAuthDeviceFlow(
            configuration: provider(),
            store: store,
            transport: transport,
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 4_000) }
        )

        let old = OAuthToken(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            issuedAt: Date(timeIntervalSince1970: 1_000),
            expiresIn: 10
        )
        try store.save(old, for: flow.providerKey)

        let refreshed = try await flow.refresh(old)
        #expect(refreshed.accessToken == "access-2")
        #expect(refreshed.refreshToken == "refresh-1")
        #expect(refreshed.issuedAt == Date(timeIntervalSince1970: 4_000))

        let requests = await transport.requests()
        let request = try #require(requests.first)
        let body = formBody(request)
        #expect(body["grant_type"] == "refresh_token")
        #expect(body["refresh_token"] == "refresh-1")
        #expect(body["client_id"] == "client-123")

        #expect(try store.token(for: flow.providerKey) == refreshed)
    }

    @Test("validToken refreshes an expired stored token")
    func validTokenRefreshes() async throws {
        let transport = StubOAuthTransport([
            StubResponse(status: 200, body: tokenJSON(access: "access-new", refresh: nil))
        ])
        let store = InMemoryOAuthTokenStore()
        let now = Date(timeIntervalSince1970: 100_000)
        let flow = OAuthDeviceFlow(
            configuration: provider(),
            store: store,
            transport: transport,
            sleep: { _ in },
            now: { now }
        )
        try store.save(
            OAuthToken(
                accessToken: "access-old",
                refreshToken: "refresh-old",
                issuedAt: now.addingTimeInterval(-3_700),
                expiresIn: 3_600
            ),
            for: flow.providerKey
        )

        let refreshed = try await flow.validToken()
        let token = try #require(refreshed)
        #expect(token.accessToken == "access-new")
        #expect(token.refreshToken == "refresh-old")
    }

    @Test("Denied and expired grants surface as typed errors")
    func grantErrors() async {
        let deniedTransport = StubOAuthTransport([
            StubResponse(
                status: 400,
                body: #"{"error":"access_denied"}"#
            )
        ])
        let denied = OAuthDeviceFlow(
            configuration: provider(),
            store: InMemoryOAuthTokenStore(),
            transport: deniedTransport,
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 5_000) }
        )
        let authorization = OAuthDeviceAuthorization(
            deviceCode: "device-abc",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://example.com/activate")!
        )
        await #expect(throws: OAuthError.accessDenied) {
            _ = try await denied.poll(for: authorization)
        }

        let dates = DateSequence([
            Date(timeIntervalSince1970: 6_000),
            Date(timeIntervalSince1970: 7_000)
        ])
        let expired = OAuthDeviceFlow(
            configuration: provider(),
            store: InMemoryOAuthTokenStore(),
            transport: StubOAuthTransport([]),
            sleep: { _ in },
            now: { dates.next() }
        )
        await #expect(throws: OAuthError.expiredDeviceCode) {
            _ = try await expired.poll(
                for: OAuthDeviceAuthorization(
                    deviceCode: "device-abc",
                    userCode: "ABCD-EFGH",
                    verificationURI: URL(
                        string: "https://example.com/activate"
                    )!,
                    expiresIn: 5
                )
            )
        }
    }

    @Test("authorize returns the code to the UI before polling")
    func authorizeCallback() async throws {
        let transport = StubOAuthTransport([
            StubResponse(status: 200, body: deviceJSON),
            StubResponse(status: 200, body: tokenJSON())
        ])
        let flow = OAuthDeviceFlow(
            configuration: provider(),
            store: InMemoryOAuthTokenStore(),
            transport: transport,
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 8_000) }
        )

        let recorder = SleepRecorder()
        let token = try await flow.authorize { authorization in
            recorder.record(
                authorization.userCode == "ABCD-EFGH" ? 1 : -1
            )
        }

        #expect(token.accessToken == "access-1")
        #expect(recorder.intervals == [1])
    }

    @Test("Provider errors during device authorization are reported clearly")
    func deviceAuthorizationError() async {
        let transport = StubOAuthTransport([
            StubResponse(
                status: 400,
                body: #"{"error":"invalid_client","error_description":"Bad client"}"#
            )
        ])
        let flow = OAuthDeviceFlow(
            configuration: provider(),
            store: InMemoryOAuthTokenStore(),
            transport: transport,
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 9_000) }
        )

        await #expect(
            throws: OAuthError.server("invalid_client", "Bad client")
        ) {
            _ = try await flow.start()
        }
    }

    @Test("Refresh without a refresh token fails before any request")
    func refreshUnavailable() async {
        let transport = StubOAuthTransport([])
        let flow = OAuthDeviceFlow(
            configuration: provider(),
            store: InMemoryOAuthTokenStore(),
            transport: transport,
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 10_000) }
        )

        await #expect(throws: OAuthError.refreshUnavailable) {
            _ = try await flow.refresh(
                OAuthToken(accessToken: "access-only")
            )
        }
        let count = await transport.requests().count
        #expect(count == 0)
    }
}
