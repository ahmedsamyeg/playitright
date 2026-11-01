import Foundation

/// One event from a streaming HTTP response.
enum HTTPStreamEvent: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
}

/// Transport-level failures from the streaming client.
enum HTTPStreamError: Error, Sendable, Equatable {
    case transport(String)
    case cancelled
    case invalidResponse
}

/// A delegate-backed `URLSession` bridge that turns a request into an
/// `AsyncThrowingStream` of response headers and body chunks.
///
/// `URLSession.bytes(for:)` yields individual bytes and is too slow for
/// multi-gigabyte video. This client receives `Data` chunks from
/// `URLSessionDataDelegate`, so the player sees natural buffer-sized pieces.
/// The same delegate enforces the redirect policy and optional self-signed
/// certificate trust.
final class HTTPStreamingClient: NSObject, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable {
    private struct Handler {
        let continuation: AsyncThrowingStream<HTTPStreamEvent, Error>.Continuation
    }

    private final class RedirectState {
        var hops = 0
    }

    private let policy: HTTPURLSecurityPolicy
    private let allowsSelfSignedCertificates: Bool
    private var credential: URLCredential?

    private let lock = NSLock()
    private var handlers: [Int: Handler] = [:]
    private var redirectStates: [Int: RedirectState] = [:]
    private var session: URLSession!

    init(
        configuration: URLSessionConfiguration,
        policy: HTTPURLSecurityPolicy,
        allowsSelfSignedCertificates: Bool,
        credential: URLCredential? = nil
    ) {
        self.policy = policy
        self.allowsSelfSignedCertificates = allowsSelfSignedCertificates
        self.credential = credential
        super.init()
        session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Supplies credentials for basic/digest challenges after connecting.
    func setCredential(_ credential: URLCredential?) {
        lock.lock()
        defer { lock.unlock() }
        self.credential = credential
    }

    /// Starts a request and streams its response.
    func stream(_ request: URLRequest) -> AsyncThrowingStream<
        HTTPStreamEvent,
        Error
    > {
        AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            let identifier = task.taskIdentifier

            lock.lock()
            handlers[identifier] = Handler(continuation: continuation)
            redirectStates[identifier] = RedirectState()
            lock.unlock()

            continuation.onTermination = { _ in
                task.cancel()
            }
            task.resume()
        }
    }

    /// Waits for the response headers and cancels the body.
    func response(for request: URLRequest) async throws -> HTTPURLResponse {
        for try await event in stream(request) {
            if case .response(let response) = event {
                return response
            }
        }
        throw HTTPStreamError.invalidResponse
    }

    /// Fetches a small resource such as a `.strm` file.
    func fetch(
        _ request: URLRequest,
        byteLimit: Int
    ) async throws -> (HTTPURLResponse, Data) {
        var response: HTTPURLResponse?
        var data = Data()

        for try await event in stream(request) {
            switch event {
            case .response(let value):
                response = value
            case .data(let chunk):
                guard data.count + chunk.count <= byteLimit else {
                    throw SourceAdapterError.protocolViolation(
                        "The resource exceeded \(byteLimit) bytes."
                    )
                }
                data.append(chunk)
            }
        }

        guard let response else {
            throw HTTPStreamError.invalidResponse
        }
        return (response, data)
    }

    // MARK: - URLSession delegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (
            URLSession.ResponseDisposition
        ) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(
                dataTask.taskIdentifier,
                throwing: HTTPStreamError.invalidResponse
            )
            completionHandler(.cancel)
            return
        }

        if let handler = handler(for: dataTask.taskIdentifier) {
            handler.continuation.yield(.response(http))
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        handler(for: dataTask.taskIdentifier)?.continuation.yield(.data(data))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            if let urlError = error as? URLError,
               urlError.code == .cancelled {
                finish(task.taskIdentifier, throwing: HTTPStreamError.cancelled)
            } else {
                finish(
                    task.taskIdentifier,
                    throwing: HTTPStreamError.transport(
                        error.localizedDescription
                    )
                )
            }
            return
        }
        finish(task.taskIdentifier, throwing: nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let identifier = task.taskIdentifier
        let state = redirectState(for: identifier)
        state.hops += 1

        guard let url = request.url, state.hops <= policy.maxRedirects,
              (try? policy.validateRedirect(to: url, hop: state.hops)) != nil
        else {
            // Refuse the redirect. URLSession then delivers the 3xx response,
            // which the adapter turns into a protocol error.
            completionHandler(nil)
            return
        }

        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        if allowsSelfSignedCertificates,
           challenge.protectionSpace.authenticationMethod
            == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(
                .useCredential,
                URLCredential(trust: trust)
            )
            return
        }

        let method = challenge.protectionSpace.authenticationMethod
        if (method == NSURLAuthenticationMethodHTTPBasic
            || method == NSURLAuthenticationMethodHTTPDigest),
           let credential = currentCredential(),
           challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, credential)
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    private func currentCredential() -> URLCredential? {
        lock.lock()
        defer { lock.unlock() }
        return credential
    }

    // MARK: - Handler bookkeeping

    private func handler(for identifier: Int) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[identifier]
    }

    private func redirectState(for identifier: Int) -> RedirectState {
        lock.lock()
        defer { lock.unlock() }
        if let state = redirectStates[identifier] {
            return state
        }
        let state = RedirectState()
        redirectStates[identifier] = state
        return state
    }

    private func finish(
        _ identifier: Int,
        throwing error: Error?
    ) {
        lock.lock()
        let handler = handlers.removeValue(forKey: identifier)
        redirectStates.removeValue(forKey: identifier)
        lock.unlock()

        if let error {
            handler?.continuation.finish(throwing: error)
        } else {
            handler?.continuation.finish()
        }
    }
}
