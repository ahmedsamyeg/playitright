import Foundation

/// The Pro products offered by PlayItRight (BIZ-1, BIZ-2, doc 08 §2).
///
/// The identifiers here must match App Store Connect. Prices in the app come
/// from StoreKit's localized `displayPrice`; the constants below are launch
/// positioning anchors, not strings to show the viewer.
public enum SubscriptionProduct: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Auto-renewable monthly subscription, $1.99 at launch.
    case monthly

    /// Auto-renewable yearly subscription, $16.99 at launch.
    case yearly

    /// One-time non-consumable lifetime unlock, $99.99 at launch.
    case lifetime

    public var id: String { productIdentifier }

    /// Whether the product renews automatically.
    public enum Kind: String, Codable, Sendable {
        case autoRenewable
        case nonConsumable
    }

    public var kind: Kind {
        switch self {
        case .monthly, .yearly:
            return .autoRenewable
        case .lifetime:
            return .nonConsumable
        }
    }

    /// App Store Connect product identifier.
    public var productIdentifier: String {
        switch self {
        case .monthly:
            return "com.playitright.pro.monthly"
        case .yearly:
            return "com.playitright.pro.yearly"
        case .lifetime:
            return "com.playitright.pro.lifetime"
        }
    }

    /// A short name for purchase sheets and settings rows.
    public var displayName: String {
        switch self {
        case .monthly:
            return "Monthly"
        case .yearly:
            return "Yearly"
        case .lifetime:
            return "Lifetime"
        }
    }

    /// Launch price anchoring. StoreKit's localized price always wins in UI.
    public var referencePrice: Decimal {
        switch self {
        case .monthly:
            return Decimal(199) / Decimal(100)
        case .yearly:
            return Decimal(1_699) / Decimal(100)
        case .lifetime:
            return Decimal(9_999) / Decimal(100)
        }
    }

    /// The introductory free-trial length, when one applies.
    ///
    /// BIZ-2 offers a 7-day trial on the monthly plan at launch. Whether a
    /// viewer is eligible is determined by the App Store, so the UI must use
    /// StoreKit's introductory offer rather than assuming eligibility.
    public var trialPeriodDays: Int? {
        switch self {
        case .monthly:
            return 7
        case .yearly, .lifetime:
            return nil
        }
    }

    /// Family Sharing is intentionally off for Pro (BIZ-5).
    public var supportsFamilySharing: Bool { false }

    /// Every identifier the app asks StoreKit about.
    public static var allProductIdentifiers: [String] {
        allCases.map(\.productIdentifier)
    }

    /// Resolves an App Store identifier back to a known product.
    public init?(productIdentifier: String) {
        guard let product = Self.allCases.first(
            where: { $0.productIdentifier == productIdentifier }
        ) else {
            return nil
        }
        self = product
    }
}

/// A StoreKit product normalized for the rest of the app.
///
/// The purchase manager keeps StoreKit's types behind this value so tests,
/// previews, and offline UI never need a live App Store session.
public struct StoreProductInfo: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var description: String
    public var displayPrice: String
    public var price: Decimal

    /// The subscription billing unit, e.g. `month` or `year`. `nil` for the
    /// lifetime non-consumable.
    public var subscriptionPeriodUnit: String?

    /// Whether StoreKit reports an introductory offer for this viewer.
    public var hasIntroductoryOffer: Bool

    /// The introductory offer length in days, when known.
    public var introductoryOfferDays: Int?

    public init(
        id: String,
        displayName: String,
        description: String = "",
        displayPrice: String,
        price: Decimal,
        subscriptionPeriodUnit: String? = nil,
        hasIntroductoryOffer: Bool = false,
        introductoryOfferDays: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.displayPrice = displayPrice
        self.price = price
        self.subscriptionPeriodUnit = subscriptionPeriodUnit
        self.hasIntroductoryOffer = hasIntroductoryOffer
        self.introductoryOfferDays = introductoryOfferDays
    }

    /// The known Pro product this entry represents, if any.
    public var product: SubscriptionProduct? {
        SubscriptionProduct(productIdentifier: id)
    }

    /// Whether the introductory offer is a free trial.
    public var hasFreeTrial: Bool {
        hasIntroductoryOffer && introductoryOfferDays != nil
    }
}
