import Foundation
import Synchronization
import Testing
@testable import PlayItRightStoreKit

// MARK: - Fake StoreKit

private final class FakeStoreKitProvider: StoreKitProviding, @unchecked Sendable {
    private struct State {
        var products: [StoreProductInfo] = []
        var purchaseResults: [String: StorePurchaseResult] = [:]
        var entitlements: [StoreTransactionInfo] = []
        var restored: [StoreTransactionInfo] = []
        var finished: [UInt64] = []
        var productsError: PurchaseError?
        var entitlementError: PurchaseError?
        var restoreError: PurchaseError?
        var restoreCalls = 0
    }

    private let state: Mutex<State>
    private let continuation: AsyncStream<StoreTransactionInfo>.Continuation
    private let updates: AsyncStream<StoreTransactionInfo>

    init(
        products: [StoreProductInfo] = [],
        purchaseResults: [String: StorePurchaseResult] = [:],
        entitlements: [StoreTransactionInfo] = [],
        restored: [StoreTransactionInfo] = []
    ) {
        self.state = Mutex(
            State(
                products: products,
                purchaseResults: purchaseResults,
                entitlements: entitlements,
                restored: restored
            )
        )

        var capturedContinuation: AsyncStream<StoreTransactionInfo>.Continuation?
        self.updates = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
    }

    func products(for identifiers: [String]) async throws -> [StoreProductInfo] {
        try state.withLock { state in
            if let error = state.productsError {
                throw error
            }
            return state.products.filter { identifiers.contains($0.id) }
        }
    }

    func purchase(productID: String) async throws -> StorePurchaseResult {
        try state.withLock { state in
            guard let result = state.purchaseResults[productID] else {
                throw PurchaseError.unknownProduct(productID)
            }
            return result
        }
    }

    func currentEntitlements() async throws -> [StoreTransactionInfo] {
        try state.withLock { state in
            if let error = state.entitlementError {
                throw error
            }
            return state.entitlements
        }
    }

    func transactionUpdates() -> AsyncStream<StoreTransactionInfo> {
        updates
    }

    func restore() async throws -> [StoreTransactionInfo] {
        try state.withLock { state in
            state.restoreCalls += 1
            if let error = state.restoreError {
                throw error
            }
            return state.restored
        }
    }

    func finish(transactionID: UInt64) async {
        state.withLock { state in
            state.finished.append(transactionID)
        }
    }

    // MARK: Test controls

    func emit(_ transaction: StoreTransactionInfo) {
        continuation.yield(transaction)
    }

    func setEntitlements(_ transactions: [StoreTransactionInfo]) {
        state.withLock { $0.entitlements = transactions }
    }

    func failEntitlements(_ error: PurchaseError) {
        state.withLock { $0.entitlementError = error }
    }

    var finishedTransactions: [UInt64] {
        state.withLock { $0.finished }
    }

    var restoreCallCount: Int {
        state.withLock { $0.restoreCalls }
    }
}

// MARK: - Fixtures

private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
private let day: TimeInterval = 86_400

private func monthlyTransaction(
    id: UInt64 = 1,
    purchase: Date = baseDate,
    expiresIn days: Double = 30,
    trial: Bool = false,
    grace: Bool = false,
    revoked: Bool = false
) -> StoreTransactionInfo {
    StoreTransactionInfo(
        id: id,
        productID: SubscriptionProduct.monthly.productIdentifier,
        purchaseDate: purchase,
        expirationDate: purchase.addingTimeInterval(days * day),
        revocationDate: revoked ? purchase : nil,
        isInGracePeriod: grace,
        isInBillingRetry: grace,
        offerType: trial ? .introductory : nil
    )
}

private func lifetimeTransaction(id: UInt64 = 2) -> StoreTransactionInfo {
    StoreTransactionInfo(
        id: id,
        productID: SubscriptionProduct.lifetime.productIdentifier,
        purchaseDate: baseDate
    )
}

@MainActor
private func makeManager(
    provider: FakeStoreKitProvider,
    store: InMemoryEntitlementStore = InMemoryEntitlementStore(),
    now: Date = baseDate
) -> (PurchaseManager, EntitlementCache) {
    let clock = StaticEntitlementClock(now: now)
    let cache = EntitlementCache(store: store, clock: clock)
    let manager = PurchaseManager(provider: provider, cache: cache, clock: clock)
    return (manager, cache)
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

// MARK: - Tests

@Suite("PurchaseManager Tests")
struct PurchaseManagerTests {
    @Test("An active subscription unlocks Pro")
    @MainActor
    func activeSubscription() async throws {
        let provider = FakeStoreKitProvider(
            entitlements: [monthlyTransaction(expiresIn: 30)]
        )
        let (manager, _) = makeManager(provider: provider)

        let entitlement = try await manager.refreshEntitlement()

        #expect(entitlement.isActive)
        #expect(entitlement.source == .subscription)
        #expect(entitlement.productIdentifier == SubscriptionProduct.monthly.productIdentifier)
        #expect(manager.isProUnlocked)
    }

    @Test("A free trial is reported as a trial entitlement")
    @MainActor
    func activeTrial() async throws {
        let provider = FakeStoreKitProvider(
            entitlements: [monthlyTransaction(expiresIn: 7, trial: true)]
        )
        let (manager, _) = makeManager(provider: provider)

        let entitlement = try await manager.refreshEntitlement()

        #expect(entitlement.isActive)
        #expect(entitlement.source == .trial)
    }

    @Test("A lifetime purchase unlocks Pro without an expiry")
    @MainActor
    func lifetime() async throws {
        let provider = FakeStoreKitProvider(
            entitlements: [lifetimeTransaction()]
        )
        let (manager, cache) = makeManager(provider: provider)

        let entitlement = try await manager.refreshEntitlement()

        #expect(entitlement.isActive)
        #expect(entitlement.source == .lifetime)
        #expect(entitlement.expirationDate == nil)

        // Years later, with no network, the cached lifetime entitlement holds.
        let futureClock = StaticEntitlementClock(
            now: baseDate.addingTimeInterval(3_650 * day)
        )
        let offlineCache = EntitlementCache(
            store: InMemoryEntitlementStore(),
            clock: futureClock
        )
        try offlineCache.save(entitlement)
        let offline = offlineCache.load()
        #expect(offline?.isActive == true)
        #expect(offline?.source == .lifetime)
        _ = cache
    }

    @Test("An expired subscription no longer unlocks Pro")
    @MainActor
    func expiredSubscription() async throws {
        let provider = FakeStoreKitProvider(
            entitlements: [monthlyTransaction(expiresIn: -1)]
        )
        let (manager, _) = makeManager(provider: provider)

        let entitlement = try await manager.refreshEntitlement()

        #expect(!entitlement.isActive)
        #expect(entitlement.source == .none)
        #expect(!manager.isProUnlocked)
    }

    @Test("A StoreKit grace period keeps Pro enabled")
    @MainActor
    func gracePeriod() async throws {
        let provider = FakeStoreKitProvider(
            entitlements: [monthlyTransaction(expiresIn: -2, grace: true)]
        )
        let (manager, _) = makeManager(provider: provider)

        let entitlement = try await manager.refreshEntitlement()

        #expect(entitlement.isActive)
        #expect(entitlement.source == .gracePeriod)
        #expect(entitlement.isInGracePeriod)
    }

    @Test("Grace ends after sixteen days")
    @MainActor
    func gracePeriodExpires() async throws {
        let provider = FakeStoreKitProvider(
            entitlements: [monthlyTransaction(expiresIn: -20, grace: true)]
        )
        let (manager, _) = makeManager(provider: provider)

        let entitlement = try await manager.refreshEntitlement()

        #expect(!entitlement.isActive)
        #expect(entitlement.source == .none)
    }

    @Test("The offline cache validates expiry without any network")
    func offlineCacheExpiry() throws {
        let store = InMemoryEntitlementStore()
        let cache = EntitlementCache(
            store: store,
            clock: StaticEntitlementClock(now: baseDate)
        )

        try cache.save(
            ProEntitlement(
                isActive: true,
                source: .subscription,
                productIdentifier: SubscriptionProduct.yearly.productIdentifier,
                expirationDate: baseDate.addingTimeInterval(10 * day),
                lastValidatedAt: baseDate
            )
        )

        let beforeExpiry = EntitlementCache(
            store: store,
            clock: StaticEntitlementClock(
                now: baseDate.addingTimeInterval(5 * day)
            )
        ).load()
        #expect(beforeExpiry?.isActive == true)

        let afterExpiry = EntitlementCache(
            store: store,
            clock: StaticEntitlementClock(
                now: baseDate.addingTimeInterval(11 * day)
            )
        ).load()
        #expect(afterExpiry?.isActive == false)
        #expect(afterExpiry?.source == ProEntitlementSource.none)
    }

    @Test("A revoked purchase is dropped from the cache")
    func revokedCache() throws {
        let store = InMemoryEntitlementStore()
        let cache = EntitlementCache(
            store: store,
            clock: StaticEntitlementClock(now: baseDate)
        )
        try cache.save(
            ProEntitlement(
                isActive: true,
                source: .lifetime,
                productIdentifier: SubscriptionProduct.lifetime.productIdentifier,
                lastValidatedAt: baseDate,
                isRevoked: true
            )
        )

        #expect(cache.load() == nil)
    }

    @Test("The transaction listener applies and finishes purchases")
    @MainActor
    func transactionListener() async throws {
        let store = InMemoryEntitlementStore()
        let provider = FakeStoreKitProvider()
        let (manager, cache) = makeManager(provider: provider, store: store)
        manager.start()

        let transaction = monthlyTransaction(id: 41, expiresIn: 30)
        provider.setEntitlements([transaction])
        provider.emit(transaction)

        await waitUntil {
            manager.isProUnlocked
                && provider.finishedTransactions.contains(41)
        }
        #expect(manager.entitlement.source == .subscription)
        #expect(provider.finishedTransactions.contains(41))
        #expect(cache.load()?.isActive == true)

        manager.stop()
    }

    @Test("The listener degrades to Free when a purchase is revoked")
    @MainActor
    func listenerHandlesRevocation() async throws {
        let provider = FakeStoreKitProvider(
            entitlements: [monthlyTransaction(id: 1, expiresIn: 30)]
        )
        let (manager, _) = makeManager(provider: provider)
        manager.start()
        _ = try await manager.refreshEntitlement()
        #expect(manager.isProUnlocked)

        let revoked = monthlyTransaction(
            id: 2,
            purchase: baseDate.addingTimeInterval(day),
            expiresIn: 30,
            revoked: true
        )
        provider.setEntitlements([])
        provider.emit(revoked)

        await waitUntil {
            !manager.isProUnlocked
                && provider.finishedTransactions.contains(2)
        }
        #expect(!manager.isProUnlocked)
        #expect(provider.finishedTransactions.contains(2))

        manager.stop()
    }

    @Test("Restore purchases syncs with the App Store and caches Pro")
    @MainActor
    func restorePurchases() async throws {
        let store = InMemoryEntitlementStore()
        let restored = monthlyTransaction(id: 7, expiresIn: 365)
        let provider = FakeStoreKitProvider(restored: [restored])
        let (manager, cache) = makeManager(provider: provider, store: store)

        let entitlement = try await manager.restorePurchases()

        #expect(provider.restoreCallCount == 1)
        #expect(entitlement.isActive)
        #expect(manager.isProUnlocked)
        #expect(cache.load()?.isActive == true)
        #expect(!manager.isRestoring)
    }

    @Test("Purchasing a product unlocks Pro and finishes the transaction")
    @MainActor
    func purchaseProduct() async throws {
        let transaction = monthlyTransaction(id: 99, expiresIn: 30, trial: true)
        let provider = FakeStoreKitProvider(
            purchaseResults: [
                SubscriptionProduct.monthly.productIdentifier: .purchased(transaction)
            ]
        )
        let (manager, _) = makeManager(provider: provider)

        let outcome = try await manager.purchase(.monthly)

        guard case .purchased(let entitlement) = outcome else {
            Issue.record("Expected a completed purchase.")
            return
        }
        #expect(entitlement.isActive)
        #expect(manager.isProUnlocked)
        #expect(provider.finishedTransactions.contains(99))
    }

    @Test("Pending and cancelled purchases do not change the entitlement")
    @MainActor
    func purchasePendingAndCancelled() async throws {
        let provider = FakeStoreKitProvider(
            purchaseResults: [
                SubscriptionProduct.monthly.productIdentifier: .pending,
                SubscriptionProduct.yearly.productIdentifier: .cancelled
            ]
        )
        let (manager, _) = makeManager(provider: provider)

        let pending = try await manager.purchase(.monthly)
        #expect(pending == .pending)
        #expect(!manager.isProUnlocked)

        let cancelled = try await manager.purchase(.yearly)
        #expect(cancelled == .cancelled)
        #expect(!manager.isProUnlocked)
    }

    @Test("Product metadata is ordered and exposes the monthly trial")
    @MainActor
    func loadProducts() async throws {
        let provider = FakeStoreKitProvider(
            products: [
                StoreProductInfo(
                    id: SubscriptionProduct.lifetime.productIdentifier,
                    displayName: "Pro Lifetime",
                    displayPrice: "$99.99",
                    price: Decimal(string: "99.99")!
                ),
                StoreProductInfo(
                    id: SubscriptionProduct.monthly.productIdentifier,
                    displayName: "Pro Monthly",
                    displayPrice: "$1.99",
                    price: Decimal(string: "1.99")!,
                    subscriptionPeriodUnit: "month",
                    hasIntroductoryOffer: true,
                    introductoryOfferDays: 7
                ),
                StoreProductInfo(
                    id: SubscriptionProduct.yearly.productIdentifier,
                    displayName: "Pro Yearly",
                    displayPrice: "$16.99",
                    price: Decimal(string: "16.99")!,
                    subscriptionPeriodUnit: "year"
                )
            ]
        )
        let (manager, _) = makeManager(provider: provider)

        let products = try await manager.loadProducts()

        #expect(products.map(\.id) == [
            SubscriptionProduct.monthly.productIdentifier,
            SubscriptionProduct.yearly.productIdentifier,
            SubscriptionProduct.lifetime.productIdentifier
        ])
        let monthly = manager.productInfo(for: .monthly)
        #expect(monthly?.hasFreeTrial == true)
        #expect(monthly?.introductoryOfferDays == 7)
        #expect(monthly?.displayPrice == "$1.99")
        #expect(manager.productInfo(for: .lifetime)?.subscriptionPeriodUnit == nil)
    }

    @Test("Refresh falls back to the offline cache when StoreKit is unreachable")
    @MainActor
    func offlineRefresh() async throws {
        let store = InMemoryEntitlementStore()
        let clock = StaticEntitlementClock(now: baseDate)
        let cache = EntitlementCache(store: store, clock: clock)
        try cache.save(
            ProEntitlement(
                isActive: true,
                source: .subscription,
                productIdentifier: SubscriptionProduct.monthly.productIdentifier,
                expirationDate: baseDate.addingTimeInterval(10 * day),
                lastValidatedAt: baseDate
            )
        )

        let provider = FakeStoreKitProvider()
        provider.failEntitlements(.storeUnavailable("offline"))
        let manager = PurchaseManager(provider: provider, cache: cache, clock: clock)

        #expect(manager.isProUnlocked)
        let entitlement = try await manager.refreshEntitlement()
        #expect(entitlement.isActive)
        #expect(manager.isProUnlocked)
    }

    @Test("Pro product identifiers, pricing, and Family Sharing follow the business model")
    func productCatalog() {
        #expect(SubscriptionProduct.allCases.count == 3)
        #expect(SubscriptionProduct.monthly.referencePrice == Decimal(string: "1.99"))
        #expect(SubscriptionProduct.yearly.referencePrice == Decimal(string: "16.99"))
        #expect(SubscriptionProduct.lifetime.referencePrice == Decimal(string: "99.99"))
        #expect(SubscriptionProduct.monthly.trialPeriodDays == 7)
        #expect(SubscriptionProduct.yearly.trialPeriodDays == nil)
        #expect(SubscriptionProduct.allCases.allSatisfy { !$0.supportsFamilySharing })
        #expect(
            SubscriptionProduct(productIdentifier: "com.playitright.pro.yearly")
                == .yearly
        )
        #expect(
            SubscriptionProduct(productIdentifier: "unknown.product") == nil
        )
    }
}
