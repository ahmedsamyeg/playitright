import Foundation

/// A client-side token bucket for the TMDB API.
///
/// TMDB allows roughly 40 requests per 10 seconds per API key. The limiter
/// spends one token per request and refills continuously, so bursts are fast
/// while sustained traffic is smoothed out. Server-issued `429` cooldowns are
/// layered on top through ``handleRateLimit(retryAfter:)``.
///
/// Time is injected so tests can verify waiting without actually sleeping.
public actor TMDBRateLimiter {
    /// Token-bucket settings.
    public struct Configuration: Sendable, Equatable {
        /// Maximum number of tokens held by the bucket.
        public var capacity: Double

        /// Number of tokens restored over one window.
        public var tokensPerWindow: Double

        /// Length of the refill window in seconds.
        public var window: TimeInterval

        public init(
            capacity: Double = 40,
            tokensPerWindow: Double = 40,
            window: TimeInterval = 10
        ) {
            self.capacity = max(1, capacity)
            self.tokensPerWindow = max(1, tokensPerWindow)
            self.window = max(0.001, window)
        }

        /// Tokens restored per second.
        public var refillRate: Double {
            tokensPerWindow / window
        }
    }

    /// Closure that returns the current monotonic-ish time in seconds.
    public typealias Clock = @Sendable () -> TimeInterval

    /// Closure that suspends for a number of seconds.
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    public let configuration: Configuration

    private let clock: Clock
    private let sleeper: Sleeper

    private var tokens: Double
    private var lastRefill: TimeInterval
    private var blockedUntil: TimeInterval

    public init(
        configuration: Configuration = Configuration(),
        now: @escaping Clock = { Date.timeIntervalSinceReferenceDate },
        sleep: @escaping Sleeper = { seconds in
            guard seconds > 0 else {
                return
            }
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.configuration = configuration
        self.clock = now
        self.sleeper = sleep
        self.tokens = configuration.capacity
        self.lastRefill = now()
        self.blockedUntil = 0
    }

    /// Waits until a request may be sent, then consumes one token.
    ///
    /// Cancellation is propagated and leaves the bucket unchanged.
    public func acquire() async throws {
        while true {
            try Task.checkCancellation()

            let now = clock()
            refill(at: now)

            if now < blockedUntil {
                try await sleeper(blockedUntil - now)
                continue
            }

            if tokens >= 1 {
                tokens -= 1
                return
            }

            let delay = (1 - tokens) / configuration.refillRate
            guard delay > 0 else {
                continue
            }
            try await sleeper(delay)
        }
    }

    /// Applies a server-issued cooldown after an HTTP `429`.
    ///
    /// The cooldown is additive with the local bucket: every caller waits at
    /// least `retryAfter` seconds before the next request. Tokens are still
    /// refilling during the cooldown.
    public func handleRateLimit(retryAfter: TimeInterval) {
        let until = clock() + max(0, retryAfter)
        blockedUntil = max(blockedUntil, until)
    }

    /// Number of tokens currently available. Intended for diagnostics/tests.
    public func availableTokens() -> Double {
        refill(at: clock())
        return tokens
    }

    /// Seconds that must pass before another request can be sent without
    /// waiting for a refill. Intended for diagnostics/tests.
    public func requiredDelay() -> TimeInterval {
        let now = clock()
        refill(at: now)

        if now < blockedUntil {
            return blockedUntil - now
        }
        if tokens >= 1 {
            return 0
        }
        return (1 - tokens) / configuration.refillRate
    }

    private func refill(at now: TimeInterval) {
        guard now > lastRefill else {
            return
        }
        let elapsed = now - lastRefill
        tokens = min(
            configuration.capacity,
            tokens + elapsed * configuration.refillRate
        )
        lastRefill = now
    }
}
