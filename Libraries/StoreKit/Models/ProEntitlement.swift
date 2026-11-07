import Foundation

/// Which purchase or StoreKit state currently unlocks Pro (BIZ-3).
public enum ProEntitlementSource: String, Codable, Sendable, Equatable {
    /// A paid auto-renewable subscription.
    case subscription

    /// A free trial attached to a subscription.
    case trial

    /// A one-time lifetime purchase.
    case lifetime

    /// An expired subscription that StoreKit still honors during its grace
    /// window. Pro stays on, and the UI can show a gentle renewal notice.
    case gracePeriod

    /// The viewer has no active Pro purchase.
    case none
}

/// The resolved Pro entitlement.
///
/// This value is safe to persist in the Keychain: it contains only product
/// identifiers and dates, never a receipt, token, or App Store credential.
public struct ProEntitlement: Codable, Sendable, Equatable {
    /// Whether Pro features should be enabled right now.
    public var isActive: Bool

    /// Why Pro is active, or `.none` when it is not.
    public var source: ProEntitlementSource

    /// The product that granted the entitlement, when known.
    public var productIdentifier: String?

    /// When the current subscription term ends. `nil` for lifetime purchases.
    public var expirationDate: Date?

    /// When StoreKit last confirmed this entitlement. Used to show freshness
    /// and to re-validate on the next connectivity (BIZ-4).
    public var lastValidatedAt: Date

    /// StoreKit reported the purchase as revoked (for example, a refund).
    public var isRevoked: Bool

    /// StoreKit is retrying billing and has granted a grace period.
    public var isInGracePeriod: Bool

    /// StoreKit is retrying billing but the grace period has ended.
    public var isInBillingRetry: Bool

    public init(
        isActive: Bool,
        source: ProEntitlementSource = .none,
        productIdentifier: String? = nil,
        expirationDate: Date? = nil,
        lastValidatedAt: Date,
        isRevoked: Bool = false,
        isInGracePeriod: Bool = false,
        isInBillingRetry: Bool = false
    ) {
        self.isActive = isActive
        self.source = source
        self.productIdentifier = productIdentifier
        self.expirationDate = expirationDate
        self.lastValidatedAt = lastValidatedAt
        self.isRevoked = isRevoked
        self.isInGracePeriod = isInGracePeriod
        self.isInBillingRetry = isInBillingRetry
    }

    /// A free-tier entitlement with no stored purchase.
    public static func free(at date: Date) -> ProEntitlement {
        ProEntitlement(isActive: false, lastValidatedAt: date)
    }

    /// The known Pro product, if the identifier still maps.
    public var product: SubscriptionProduct? {
        productIdentifier.flatMap(SubscriptionProduct.init(productIdentifier:))
    }

    /// Whether this entitlement should be re-checked when the network returns.
    public var needsRefresh: Bool {
        !isActive || (expirationDate.map { $0.timeIntervalSince(lastValidatedAt) < 86_400 } ?? false)
    }
}

/// A StoreKit transaction normalized for entitlement evaluation.
///
/// This mirrors the fields the app needs without exposing StoreKit types to
/// tests or to the purchase cache.
public struct StoreTransactionInfo: Sendable, Equatable, Identifiable {
    /// How the transaction was obtained from StoreKit.
    public enum OfferType: String, Sendable, Equatable {
        case introductory
        case promotional
        case code
    }

    /// StoreKit's transaction identifier.
    public var id: UInt64

    /// The original transaction identifier for renewals.
    public var originalID: UInt64?

    public var productID: String
    public var purchaseDate: Date
    public var expirationDate: Date?
    public var revocationDate: Date?
    public var isUpgraded: Bool
    public var isInGracePeriod: Bool
    public var isInBillingRetry: Bool
    public var offerType: OfferType?

    public init(
        id: UInt64,
        originalID: UInt64? = nil,
        productID: String,
        purchaseDate: Date,
        expirationDate: Date? = nil,
        revocationDate: Date? = nil,
        isUpgraded: Bool = false,
        isInGracePeriod: Bool = false,
        isInBillingRetry: Bool = false,
        offerType: OfferType? = nil
    ) {
        self.id = id
        self.originalID = originalID
        self.productID = productID
        self.purchaseDate = purchaseDate
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isUpgraded = isUpgraded
        self.isInGracePeriod = isInGracePeriod
        self.isInBillingRetry = isInBillingRetry
        self.offerType = offerType
    }

    public var isRevoked: Bool {
        revocationDate != nil
    }

    /// A trial is an introductory offer, or a subscription term short enough
    /// to be one when StoreKit omits the offer type.
    public var isTrial: Bool {
        if offerType == .introductory {
            return true
        }
        guard let expirationDate else {
            return false
        }
        let duration = expirationDate.timeIntervalSince(purchaseDate)
        return duration > 0 && duration <= 8 * 86_400
    }
}

/// The result of a purchase attempt.
public enum StorePurchaseResult: Sendable, Equatable {
    case purchased(StoreTransactionInfo)
    case pending
    case cancelled
}

/// The seam over StoreKit 2.
///
/// The live implementation is ``StoreKit2Provider``. Tests use an in-memory
/// provider so no App Store connection, sandbox account, or StoreKit
/// configuration is required.
public protocol StoreKitProviding: Sendable {
    /// Loads localized product metadata for the given identifiers.
    func products(for identifiers: [String]) async throws -> [StoreProductInfo]

    /// Starts a purchase and returns StoreKit's outcome.
    func purchase(productID: String) async throws -> StorePurchaseResult

    /// Returns the transactions StoreKit currently considers entitled.
    func currentEntitlements() async throws -> [StoreTransactionInfo]

    /// Delivers purchases and renewals that happen while the app is running.
    func transactionUpdates() -> AsyncStream<StoreTransactionInfo>

    /// Asks the App Store to sync and returns current entitlements.
    func restore() async throws -> [StoreTransactionInfo]

    /// Marks a transaction as delivered so StoreKit stops replaying it.
    func finish(transactionID: UInt64) async
}

/// Purchase-manager failures with user-facing descriptions.
public enum PurchaseError: Error, Sendable, Equatable, LocalizedError {
    case productNotFound(SubscriptionProduct)
    case unverifiedTransaction
    case storeUnavailable(String)
    case unknownProduct(String)

    public var errorDescription: String? {
        switch self {
        case .productNotFound(let product):
            return "\(product.displayName) isn't available right now. Please try again later."
        case .unverifiedTransaction:
            return "The App Store couldn't verify this purchase. Nothing was charged."
        case .storeUnavailable(let message):
            return "The App Store is unavailable: \(message)"
        case .unknownProduct(let identifier):
            return "This purchase isn't recognized by this version of PlayItRight (\(identifier))."
        }
    }
}
