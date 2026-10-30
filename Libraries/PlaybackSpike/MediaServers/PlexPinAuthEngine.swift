import Foundation

/// State machine managing Plex PIN linking on 10-foot TV (SRC-1, SRC-8).
public actor PlexPinAuthEngine {

    public enum AuthState: Equatable, Sendable {
        case uninitialized
        case waitingForUser(pinCode: String, expiresInSeconds: Int)
        case authorized(authToken: String)
        case expired
        case failed(String)
    }

    public struct PinResponse: Codable, Sendable {
        public let id: Int
        public let code: String
        public let expiresIn: Int
        public let authToken: String?
    }

    public typealias PinRequestHandler = @Sendable () async throws -> PinResponse
    public typealias PinPollHandler = @Sendable (Int) async throws -> PinResponse

    private let requestPin: PinRequestHandler
    private let pollPin: PinPollHandler
    private var currentState: AuthState = .uninitialized
    private var activePinId: Int?

    public init(
        requestPin: @escaping PinRequestHandler,
        pollPin: @escaping PinPollHandler
    ) {
        self.requestPin = requestPin
        self.pollPin = pollPin
    }

    public var state: AuthState {
        currentState
    }

    /// Requests a new PIN code from Plex.tv.
    public func startLinking() async throws -> String {
        do {
            let response = try await requestPin()
            self.activePinId = response.id
            self.currentState = .waitingForUser(pinCode: response.code, expiresInSeconds: response.expiresIn)
            return response.code
        } catch {
            self.currentState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Polls Plex.tv for authorization status.
    public func pollStatus() async throws -> AuthState {
        guard let pinId = activePinId else {
            currentState = .failed("No active PIN")
            return currentState
        }

        do {
            let response = try await pollPin(pinId)
            if let token = response.authToken, !token.isEmpty {
                self.currentState = .authorized(authToken: token)
                self.activePinId = nil
            } else if response.expiresIn <= 0 {
                self.currentState = .expired
                self.activePinId = nil
            }
            return currentState
        } catch {
            self.currentState = .failed(error.localizedDescription)
            throw error
        }
    }
}
