import PlayItRightStoreKit
import SwiftUI

/// The Pro upsell sheet: one benefit line, the monthly/yearly/lifetime plans,
/// the 7-day trial CTA, and Restore Purchases (BIZ-1, BIZ-2, BIZ-4, BIZ-7).
///
/// The sheet is shown only at a moment of value. If the viewer has already seen
/// a proactive upsell today, callers should show an inline notice or badge
/// instead of presenting this again.
public struct ProPaywallSheet: View {
    public let manager: PurchaseManager
    public let upsell: ProUpsell?
    public let onDismiss: () -> Void

    @State private var busyProduct: SubscriptionProduct?
    @State private var isRestoring = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    public init(
        manager: PurchaseManager,
        upsell: ProUpsell? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.manager = manager
        self.upsell = upsell
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DesignGrid.spacing(4)) {
                header
                plans
                actions
                finePrint
            }
            .padding(DesignGrid.contentMargin)
            .frame(maxWidth: 1_400, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(DesignTokens.palette.background.color.ignoresSafeArea())
        .task {
            manager.start()
            if manager.products.isEmpty {
                _ = try? await manager.loadProducts()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(2)) {
            HStack(spacing: DesignGrid.spacing(2)) {
                Image(systemName: "sparkles")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(DesignTokens.palette.accent.color)

                VStack(alignment: .leading, spacing: 4) {
                    Text("PlayItRight Pro")
                        .font(DesignTypography.display)
                        .foregroundStyle(DesignTokens.palette.textPrimary.color)
                        .accessibilityAddTraits(.isHeader)

                    Text(upsell?.headline ?? "Unlock everything")
                        .font(DesignTypography.title2)
                        .foregroundStyle(DesignTokens.palette.textSecondary.color)
                }
            }

            Text(
                upsell?.benefit
                    ?? "Pro adds every video codec, lossless audio, unlimited sources, cloud drives, iCloud sync, and casting."
            )
            .font(DesignTypography.body)
            .foregroundStyle(DesignTokens.palette.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)

            if let trial = upsell?.trialMessage {
                Label(trial, systemImage: "gift")
                    .font(DesignTypography.callout)
                    .foregroundStyle(DesignTokens.palette.success.color)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Plans

    private var plans: some View {
        HStack(alignment: .top, spacing: DesignGrid.spacing(3)) {
            ForEach(SubscriptionProduct.allCases, id: \.self) { product in
                planCard(product)
            }
        }
    }

    private func planCard(_ product: SubscriptionProduct) -> some View {
        let info = manager.productInfo(for: product)
        let isRecommended = product == .yearly
        let isBusy = busyProduct == product

        return VStack(alignment: .leading, spacing: DesignGrid.spacing(1)) {
            HStack {
                Text(product.displayName)
                    .font(DesignTypography.headline)
                    .foregroundStyle(DesignTokens.palette.textPrimary.color)

                Spacer(minLength: DesignGrid.spacing(1))

                if isRecommended {
                    Text("BEST VALUE")
                        .font(DesignTypography.badge)
                        .foregroundStyle(DesignTokens.palette.background.color)
                        .padding(.horizontal, DesignGrid.spacing(1))
                        .padding(.vertical, 4)
                        .background(DesignTokens.palette.accent.color)
                        .clipShape(Capsule())
                }
            }

            Text(priceText(product, info: info))
                .font(DesignTypography.title2)
                .foregroundStyle(DesignTokens.palette.textPrimary.color)

            Text(periodText(product, info: info))
                .font(DesignTypography.caption)
                .foregroundStyle(DesignTokens.palette.textSecondary.color)

            if showsTrial(product, info: info) {
                Text("7-day free trial")
                    .font(DesignTypography.badge)
                    .foregroundStyle(DesignTokens.palette.success.color)
            }

            Spacer(minLength: DesignGrid.spacing(2))

            Button {
                purchase(product)
            } label: {
                if isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(buttonTitle(product, info: info))
                        .font(DesignTypography.callout)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busyProduct != nil || isRestoring)
            .accessibilityLabel(
                "\(buttonTitle(product, info: info)): \(product.displayName) plan"
            )
        }
        .padding(DesignGrid.spacing(3))
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .leading)
        .background(
            isRecommended
                ? DesignTokens.palette.surfaceElevated.color
                : DesignTokens.palette.surface.color
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: DesignTokens.Focus.cornerRadius,
                style: .continuous
            )
            .stroke(
                isRecommended
                    ? DesignTokens.palette.accent.color
                    : Color.clear,
                lineWidth: 3
            )
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: DesignTokens.Focus.cornerRadius,
                style: .continuous
            )
        )
        .accessibilityElement(children: .contain)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: DesignGrid.spacing(2)) {
            HStack(spacing: DesignGrid.spacing(2)) {
                Button {
                    restore()
                } label: {
                    if isRestoring {
                        ProgressView()
                    } else {
                        Label("Restore Purchases", systemImage: "arrow.clockwise")
                            .font(DesignTypography.callout)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(busyProduct != nil || isRestoring)

                Spacer()

                Button("Not Now") {
                    dismiss()
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .disabled(busyProduct != nil || isRestoring)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.textSecondary.color)
                    .accessibilityAddTraits(.isStaticText)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(DesignTypography.caption)
                    .foregroundStyle(DesignTokens.palette.danger.color)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }

    private var finePrint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                "Subscriptions renew automatically until canceled in Settings. The monthly plan includes a 7-day free trial where eligible."
            )
            Text(
                "Purchases restore on Apple TVs signed in with the same Apple ID. Family Sharing is not available for Pro."
            )
        }
        .font(DesignTypography.badge)
        .foregroundStyle(DesignTokens.palette.textTertiary.color)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Copy

    private func priceText(
        _ product: SubscriptionProduct,
        info: StoreProductInfo?
    ) -> String {
        if let info {
            return info.displayPrice
        }
        return product.referencePrice.formatted(
            .currency(code: "USD").precision(.fractionLength(2))
        )
    }

    private func periodText(
        _ product: SubscriptionProduct,
        info: StoreProductInfo?
    ) -> String {
        switch product {
        case .monthly:
            return "per month"
        case .yearly:
            return "per year · save over 28%"
        case .lifetime:
            return "one-time purchase"
        }
    }

    private func showsTrial(
        _ product: SubscriptionProduct,
        info: StoreProductInfo?
    ) -> Bool {
        guard product == .monthly else {
            return false
        }
        return info?.hasFreeTrial ?? (product.trialPeriodDays != nil)
    }

    private func buttonTitle(
        _ product: SubscriptionProduct,
        info: StoreProductInfo?
    ) -> String {
        switch product.kind {
        case .nonConsumable:
            return "Buy Once"
        case .autoRenewable:
            if showsTrial(product, info: info) {
                return "Start Free Trial"
            }
            return "Subscribe"
        }
    }

    // MARK: - Store actions

    private func purchase(_ product: SubscriptionProduct) {
        busyProduct = product
        statusMessage = nil
        errorMessage = nil

        Task {
            defer { busyProduct = nil }
            do {
                let outcome = try await manager.purchase(product)
                switch outcome {
                case .purchased:
                    dismiss()
                    onDismiss()
                case .pending:
                    statusMessage = "Your purchase is pending approval. Pro unlocks as soon as the App Store confirms it."
                case .cancelled:
                    break
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func restore() {
        isRestoring = true
        statusMessage = nil
        errorMessage = nil

        Task {
            defer { isRestoring = false }
            do {
                let entitlement = try await manager.restorePurchases()
                if entitlement.isActive {
                    dismiss()
                    onDismiss()
                } else {
                    statusMessage = "No active Pro purchase was found for this Apple ID."
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
