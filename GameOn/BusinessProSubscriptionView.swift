import SwiftUI
import StoreKit

struct BusinessProSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @ObservedObject private var purchaseService = BusinessProPurchaseService.shared
    let businessStatus: BusinessVenueGamePostingStatus?

    init(businessStatus: BusinessVenueGamePostingStatus? = nil) {
        self.businessStatus = businessStatus
    }

    private let proFeatureListItems = [
        "Unlimited venues",
        "Unlimited hosted games",
        "Analytics access"
    ]

    private var regularFeatureListItems: [String] {
        [
            "\(currentActiveVenueLimit) active venues",
            "\(currentHostedGameLimit) hosted games/month"
        ]
    }

    private var currentActiveVenueLimit: Int {
        guard let businessStatus else { return BusinessMembershipPolicy.freeVenueListingLimit }
        return max(1, businessStatus.activeVenueLimit ?? businessStatus.venueLimit)
    }

    private var currentHostedGameLimit: Int {
        guard let businessStatus else { return BusinessMembershipPolicy.freeMonthlyVenueGameLimit }
        return max(1, businessStatus.hostedGamesEffectiveMonthlyHostLimitForDisplay ?? businessStatus.monthlyHostLimit)
    }

    private let fallbackRegularFeatures = [
        "5 active venues",
        "5 hosted games/month"
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                entitlementPlanCard
                if !isCurrentBusinessRegular {
                    regularReferenceCard
                }
                entitlementExplanation
                actionButtons
            }
            .padding(20)
        }
        .background(background)
        .task {
            await purchaseService.prepare()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(FGColor.accentGreen)
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("FanGeo Business Pro")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Compare free business tools with unlimited listings and hosting.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var entitlementPlanCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            planHeader(
                title: entitlementTitle,
                subtitle: entitlementSubtitle,
                badge: entitlementBadge,
                badgeColor: entitlementBadgeColor
            )

            Text(entitlementDetailText)
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            Text(futureBillingText)
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            planFeatureList(entitlementFeatures, tint: entitlementFeatureTint)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.14),
                            FGColor.accentYellow.opacity(colorScheme == .dark ? 0.18 : 0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.42), lineWidth: 1)
        }
    }

    private var regularReferenceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            planHeader(
                title: "FanGeo Business",
                subtitle: "Free business tools for sports venues",
                badge: "FREE",
                badgeColor: FGColor.accentBlue
            )

            Text("Free plan")
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            planFeatureList(fallbackRegularFeatures, tint: FGColor.accentBlue)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.72), lineWidth: 1)
        }
    }

    private func planHeader(
        title: String,
        subtitle: String,
        badge: String,
        badgeColor: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(subtitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text(badge)
                .font(.caption2.weight(.black))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(badgeColor.opacity(colorScheme == .dark ? 0.20 : 0.12), in: Capsule(style: .continuous))
        }
    }

    private func planFeatureList(_ features: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(features, id: \.self) { feature in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(feature)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var entitlementExplanation: some View {
        Text(entitlementExplanationText)
            .font(.caption.weight(.semibold))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if !purchaseService.purchaseMessage.isEmpty {
                Text(purchaseService.purchaseMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(messageTint)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(messageTint.opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Button {
                Task {
                    await purchaseService.purchaseBusinessPro()
                }
            } label: {
                HStack(spacing: 8) {
                    if purchaseService.isLoadingProduct || purchaseService.isPurchasing {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(purchaseButtonTitle)
                        .font(.headline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .foregroundStyle(.white)
                .background(purchaseButtonBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .opacity(purchaseService.canPurchase ? 1 : 0.62)
            }
            .buttonStyle(.plain)
            .disabled(!purchaseService.canPurchase)

            Button {
                Task {
                    await purchaseService.restorePurchases()
                }
            } label: {
                HStack(spacing: 8) {
                    if purchaseService.isRestoring {
                        ProgressView()
                    }
                    Text("Restore Purchases")
                        .font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .background(FGAdaptiveSurface.capsuleUnselected, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(purchaseService.isRestoring)

            if let manageSubscriptionURL = purchaseService.manageSubscriptionURL {
                Button {
#if DEBUG
                    print("[BusinessProPurchase] manageSubscriptionTapped=true")
#endif
                    openURL(manageSubscriptionURL)
                } label: {
                    Text("Manage Subscription")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .foregroundStyle(FGColor.accentBlue)
                        .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if isCurrentBusinessFreePromo {
                Button {
                    dismiss()
                } label: {
                    Text("Continue Free Promo Access")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(.white)
                        .background(
                            LinearGradient(
                                colors: [FGColor.accentGreen, FGColor.businessGreen],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var futureBillingText: String {
        guard let product = purchaseService.product else {
            return purchaseService.billingUnavailableMessage
        }
        return "Future Apple subscription: \(product.displayPrice) / month"
    }

    private var entitlementTitle: String {
        guard businessStatus != nil else { return "Checking plan status" }
        if isCurrentBusinessFreePromo { return "Free User Promotion" }
        if isCurrentBusinessSubscriptionPro { return "Business Pro Active" }
        return "Business Regular"
    }

    private var entitlementSubtitle: String {
        guard businessStatus != nil else { return "Refreshing entitlement" }
        if isCurrentBusinessFreePromo { return "Promotion access" }
        if isCurrentBusinessSubscriptionPro { return "Subscription Pro" }
        return "Free plan"
    }

    private var entitlementBadge: String {
        guard businessStatus != nil else { return "CHECKING" }
        if isCurrentBusinessFreePromo { return "FREE" }
        if isCurrentBusinessSubscriptionPro { return "ACTIVE" }
        return "REGULAR"
    }

    private var entitlementBadgeColor: Color {
        if isCurrentBusinessFreePromo { return FGColor.accentYellow }
        if isCurrentBusinessSubscriptionPro { return FGColor.accentGreen }
        return FGColor.accentBlue
    }

    private var entitlementFeatureTint: Color {
        isCurrentBusinessRegular ? FGColor.accentBlue : FGColor.accentGreen
    }

    private var entitlementFeatures: [String] {
        guard businessStatus != nil else { return fallbackRegularFeatures }
        return isCurrentBusinessRegular ? regularFeatureListItems : proFeatureListItems
    }

    private var entitlementDetailText: String {
        guard businessStatus != nil else {
            return "Business Pro details are refreshing from your business account."
        }
        if isCurrentBusinessFreePromo {
            return businessStatus?.businessProPromoEndDateText
                ?? "Promotion end date refreshes from your business account."
        }
        if isCurrentBusinessSubscriptionPro {
            return businessStatus?.businessProSubscriptionExpiryText ?? "No scheduled expiration."
        }
        return "Upgrade to Business Pro for unlimited venues and hosted games."
    }

    private var entitlementExplanationText: String {
        guard businessStatus != nil else {
            return "FanGeo is checking this business’s current entitlement before showing plan details."
        }
        if isCurrentBusinessFreePromo {
            return "This business has temporary Business Pro access through the Free User Promotion."
        }
        if isCurrentBusinessSubscriptionPro {
            return "This business currently has Business Pro access from its subscription entitlement."
        }
        return "This business is on the Regular plan. Free plan limits are enforced by your business entitlement."
    }

    private var isCurrentBusinessFreePromo: Bool {
        businessStatus?.isBusinessProPromo == true
    }

    private var isCurrentBusinessSubscriptionPro: Bool {
        businessStatus?.isBusinessSubscriptionPro == true
    }

    private var isCurrentBusinessRegular: Bool {
        businessStatus != nil && !isCurrentBusinessFreePromo && !isCurrentBusinessSubscriptionPro
    }

    private var purchaseButtonTitle: String {
        if purchaseService.isPurchasing { return "Processing..." }
        if purchaseService.isLoadingProduct { return "Checking Billing..." }
        guard let product = purchaseService.product else {
            return purchaseService.billingUnavailableMessage
        }
        return "Prepare Business Pro Billing - \(product.displayPrice)"
    }

    private var messageTint: Color {
        purchaseService.product == nil ? Color.orange : FGColor.accentGreen
    }

    private var purchaseButtonBackground: LinearGradient {
        if purchaseService.canPurchase {
            return LinearGradient(
                colors: [FGColor.accentBlue, FGColor.accentGreen],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [Color.gray.opacity(0.72), Color.gray.opacity(0.54)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var background: some View {
        ZStack {
            FGAdaptiveSurface.sheetRoot.ignoresSafeArea()
            LinearGradient(
                colors: [
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.10),
                    FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.06),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }
}

struct BusinessProSubscriptionView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            BusinessProSubscriptionView()
                .preferredColorScheme(.light)
            BusinessProSubscriptionView()
                .preferredColorScheme(.dark)
        }
    }
}
