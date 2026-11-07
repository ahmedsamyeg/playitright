import Foundation
import Observation
import StoreKit

/// Evaluates StoreKit transactions into one Pro entitlement (BIZ-3).
///
/// Lifetime wins over subscriptions. Among subscriptions, the one that expires
/// last wins, and a StoreKit grace period keeps Pro on after expiry.
public enum ProEntitlementEvaluator {
    public static func evaluate(
        transactions: [StoreTransactionInfo],
        now: Date,
        gracePeriod: TimeInterval = EntitlementCache.gracePeriod
    ) -> ProEntitlement {
        let usable = transactions.filter { !$0.isRevoked && !$0.isUpgraded }

        // Lifetime unlock never expires and outranks any subscription.
        if let lifetime = usable.first(where: {
            $0.productID == SubscriptionProduct.lifetime.productIdentifier
        }) {
            return ProEntitlement(
                isActive: true,
                source: .lifetime,
                productIdentifier: lifetime.productID,
                expirationDate: nil,
                lastValidatedAt: now,
                isInGracePeriod: false,
                isInBillingRetry: false
            )
        }

        let subscriptions = usable
            .filter { $0.productID != SubscriptionProduct.lifetime.productIdentifier }
            .sorted { lhs, rhs in
                (lhs.expirationDate ?? .distantPast)
                    > (rhs.expirationDate ?? .distantPast)
            }

        for transaction in subscriptions {
            guard let expiration = transaction.expirationDate else {
                continue
            }

            if now < expiration {
                return ProEntitlement(
                    isActive: true,
                    source: transaction.isTrial ? .trial : .subscription,
                    productIdentifier: transaction.productID,
                    expirationDate: expiration,
                    lastValidatedAt: now,
                    isInGracePeriod: transaction.isInGracePeriod,
                    isInBillingRetry: transaction.isInBillingRetry
                )
            }

            if transaction.isInGracePeriod,
               now < expiration.addingTimeInterval(gracePeriod) {
                return ProEntitlement(
                    isActive: true,
                    source: .gracePeriod,
                    productIdentifier: transaction.productID,
                    expirationDate: expiration,
                    lastValidatedAt: now,
                    isInGracePeriod: true,
                    isInBillingRetry: transaction.isInBillingRetry
                )
            }
        }

        // No active purchase. Preserve the latest known state so the UI can
        // explain what expired without treating the viewer as a new customer.
        let latest = subscriptions.first
        return ProEntitlement(
            isActive: false,
            source: .none,
            productIdentifier: latest?.productID,
            expirationDate: latest?.expirationDate,
            lastValidatedAt: now,
            isInGracePeriod: false,
            isInBillingRetry: latest?.isInBillingRetry ?? false
        )
    }
}

/// The live StoreKit 2 adapter.
///
/// All StoreKit types are converted to the app's value types at this boundary,
/// which keeps the purchase manager testable and lets a future platform reuse
/// the entitlement logic.
public struct StoreKit2Provider: StoreKitProviding, Sendable {
    public init() {}

    public func products(for identifiers: [String]) async throws -> [StoreProductInfo] {
        let products = try await Product.products(for: identifiers)
        return products.map(Self.info(for:))
    }

    public func purchase(productID: String) async throws -> StorePurchaseResult {
        let products = try await Product.products(for: [productID])
        guard let product = products.first else {
            throw PurchaseError.unknownProduct(productID)
        }

        let result = try await product.purchase()
        switch result {
        case .success(.verified(let transaction)):
            return .purchased(StoreTransactionInfo(transaction: transaction))
        case .success(.unverified):
            throw PurchaseError.unverifiedTransaction
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    public func currentEntitlements() async throws -> [StoreTransactionInfo] {
        var transactions: [StoreTransactionInfo] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                continue
            }
            transactions.append(StoreTransactionInfo(transaction: transaction))
        }
        return transactions
    }

    public func transactionUpdates() -> AsyncStream<StoreTransactionInfo> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard case .verified(let transaction) = result else {
                        continue
                    }
                    continuation.yield(
                        StoreTransactionInfo(transaction: transaction)
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func restore() async throws -> [StoreTransactionInfo] {
        try await AppStore.sync()
        return try await currentEntitlements()
    }

    public func finish(transactionID: UInt64) async {
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result,
               transaction.id == transactionID {
                await transaction.finish()
                return
            }
        }
    }

    // MARK: - Mapping

    private static func info(for product: Product) -> StoreProductInfo {
        let subscription = product.subscription
        let periodUnit: String?
        if let unit = subscription?.subscriptionPeriod.unit {
            switch unit {
            case .day:
                periodUnit = "day"
            case .week:
                periodUnit = "week"
            case .month:
                periodUnit = "month"
            case .year:
                periodUnit = "year"
            @unknown default:
                periodUnit = nil
            }
        } else {
            periodUnit = nil
        }

        let offer = subscription?.introductoryOffer
        let offerDays = offer.map { days(for: $0.period) }
        let isFreeTrial = offer?.paymentMode == .freeTrial

        return StoreProductInfo(
            id: product.id,
            displayName: product.displayName,
            description: product.description,
            displayPrice: product.displayPrice,
            price: product.price,
            subscriptionPeriodUnit: periodUnit,
            hasIntroductoryOffer: offer != nil,
            introductoryOfferDays: isFreeTrial ? offerDays : nil
        )
    }

    private static func days(for period: Product.SubscriptionPeriod) -> Int {
        let value = max(1, period.value)
        switch period.unit {
        case .day:
            return value
        case .week:
            return value * 7
        case .month:
            return value * 30
        case .year:
            return value * 365
        @unknown default:
            return value
        }
    }
}

extension StoreTransactionInfo {
    init(transaction: Transaction) {
        let now = Date()
        let grace = transaction.expirationDate.map { expiration in
            expiration <= now
                && now < expiration.addingTimeInterval(EntitlementCache.gracePeriod)
        } ?? false

        self.init(
            id: transaction.id,
            originalID: transaction.originalID,
            productID: transaction.productID,
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded,
            isInGracePeriod: grace,
            isInBillingRetry: grace,
            offerType: nil
        )
    }
}

/// The result of a purchase initiated through ``PurchaseManager``.
public enum PurchaseOutcome: Sendable, Equatable {
    case purchased(ProEntitlement)
    case pending
    case cancelled
}

/// StoreKit 2 subscription and lifetime purchase manager (BIZ-1, BIZ-2,
/// BIZ-4, BIZ-5).
///
/// The manager keeps one authoritative ``ProEntitlement``, restores it from the
/// Keychain cache at launch so Pro works offline, listens for transactions for
/// as long as the app is running, and re-validates with the App Store whenever
/// the network allows.
@MainActor
@Observable
public final class PurchaseManager {
    /// The current entitlement. Reads are safe before any network call because
    /// the Keychain cache is loaded in `init`.
    public private(set) var entitlement: ProEntitlement

    /// Localized Pro products, populated by ``loadProducts()``.
    public private(set) var products: [StoreProductInfo] = []

    /// Whether a restore is in flight, so the UI can disable the button.
    public private(set) var isRestoring = false

    /// Whether the transaction listener is running.
    public var isListening: Bool { listenerTask != nil }

    /// Whether Pro features should be unlocked right now.
    public var isProUnlocked: Bool { entitlement.isActive }

    @ObservationIgnored private let provider: any StoreKitProviding
    @ObservationIgnored private let cache: EntitlementCache
    @ObservationIgnored private let clock: any EntitlementClock
    @ObservationIgnored private var listenerTask: Task<Void, Never>?

    /// - Parameters:
    ///   - provider: StoreKit seam. The default talks to the live App Store.
    ///   - cache: Keychain-backed offline entitlement cache.
    ///   - clock: Time source used for expiry checks.
    public init(
        provider: any StoreKitProviding = StoreKit2Provider(),
        cache: EntitlementCache = EntitlementCache(),
        clock: any EntitlementClock = SystemEntitlementClock()
    ) {
        self.provider = provider
        self.cache = cache
        self.clock = clock
        self.entitlement = cache.load() ?? .free(at: clock.now)
    }

    /// Starts listening for purchases and renewals. Safe to call repeatedly.
    public func start() {
        guard listenerTask == nil else {
            return
        }
        let provider = self.provider
        listenerTask = Task { [weak self] in
            for await transaction in provider.transactionUpdates() {
                guard let self else {
                    return
                }
                await self.handle(transaction)
            }
        }
    }

    /// Stops the transaction listener. Call from scene teardown.
    public func stop() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    /// Loads localized product metadata from the App Store.
    @discardableResult
    public func loadProducts() async throws -> [StoreProductInfo] {
        let loaded = try await provider.products(
            for: SubscriptionProduct.allProductIdentifiers
        )
        products = loaded.sorted { lhs, rhs in
            let lhsOrder = SubscriptionProduct(productIdentifier: lhs.id)
                .flatMap { SubscriptionProduct.allCases.firstIndex(of: $0) } ?? .max
            let rhsOrder = SubscriptionProduct(productIdentifier: rhs.id)
                .flatMap { SubscriptionProduct.allCases.firstIndex(of: $0) } ?? .max
            return lhsOrder < rhsOrder
        }
        return products
    }

    /// Metadata for one known product after ``loadProducts()``.
    public func productInfo(for product: SubscriptionProduct) -> StoreProductInfo? {
        products.first { $0.id == product.productIdentifier }
    }

    /// Purchases a Pro product.
    public func purchase(
        _ product: SubscriptionProduct
    ) async throws -> PurchaseOutcome {
        let result: StorePurchaseResult
        do {
            result = try await provider.purchase(
                productID: product.productIdentifier
            )
        } catch let error as PurchaseError {
            throw error
        } catch {
            throw PurchaseError.storeUnavailable(error.localizedDescription)
        }

        switch result {
        case .purchased(let transaction):
            let resolved = ProEntitlementEvaluator.evaluate(
                transactions: [transaction],
                now: clock.now
            )
            apply(resolved)
            await provider.finish(transactionID: transaction.id)
            return .purchased(resolved)
        case .pending:
            return .pending
        case .cancelled:
            return .cancelled
        }
    }

    /// Restores purchases by syncing with the App Store, then caching the
    /// resulting entitlement so it survives going offline (BIZ-4).
    @discardableResult
    public func restorePurchases() async throws -> ProEntitlement {
        isRestoring = true
        defer { isRestoring = false }

        let transactions: [StoreTransactionInfo]
        do {
            transactions = try await provider.restore()
        } catch let error as PurchaseError {
            throw error
        } catch {
            throw PurchaseError.storeUnavailable(error.localizedDescription)
        }

        let resolved = ProEntitlementEvaluator.evaluate(
            transactions: transactions,
            now: clock.now
        )
        apply(resolved)
        return resolved
    }

    /// Re-validates entitlements with the App Store, falling back to the
    /// offline cache when the network is unavailable.
    @discardableResult
    public func refreshEntitlement() async throws -> ProEntitlement {
        let transactions: [StoreTransactionInfo]
        do {
            transactions = try await provider.currentEntitlements()
        } catch {
            if let cached = cache.load() {
                entitlement = cached
                return cached
            }
            throw error
        }

        let resolved = ProEntitlementEvaluator.evaluate(
            transactions: transactions,
            now: clock.now
        )
        apply(resolved)

        // Acknowledge anything StoreKit is still replaying.
        for transaction in transactions {
            await provider.finish(transactionID: transaction.id)
        }
        return resolved
    }

    /// Clears the offline entitlement, for example when the Apple ID changes.
    public func clearCachedEntitlement() {
        try? cache.clear()
        entitlement = .free(at: clock.now)
    }

    // MARK: - Transaction listener

    private func handle(_ transaction: StoreTransactionInfo) async {
        var transactions = (try? await provider.currentEntitlements()) ?? []
        if !transactions.contains(where: { $0.id == transaction.id }) {
            transactions.append(transaction)
        }

        let resolved = ProEntitlementEvaluator.evaluate(
            transactions: transactions,
            now: clock.now
        )
        apply(resolved)
        await provider.finish(transactionID: transaction.id)
    }

    private func apply(_ entitlement: ProEntitlement) {
        self.entitlement = entitlement
        try? cache.save(entitlement)
    }
}

extension PurchaseManager: ProEntitlementReading {}
