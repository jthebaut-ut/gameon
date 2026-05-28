import Foundation
import Combine
import StoreKit

enum BusinessMembershipPolicy {
    static let freeVenueListingLimit = 5
    static let freeMonthlyVenueGameLimit = 5

    static func currentMonthWindow(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            ?? calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .month, value: 1, to: start)
            ?? now.addingTimeInterval(31 * 24 * 60 * 60)
        return (start, end)
    }
}

enum BusinessLimitCopy {
    static let venueLimitReached = "You’ve reached your active venue limit. Upgrade to FanGeo Pro for unlimited locations."
    static let hostedGameLimitReached = "You’ve reached your monthly hosted game limit. Upgrade to FanGeo Pro for unlimited hosted games, or wait until your next monthly cycle."
    static let planLockedVenueBanner = "Some of your venues are locked because your business exceeds the free plan limit. Upgrade to FanGeo Pro to reactivate all locations."
    static let planLockedVenueBadge = "Locked"
    static let planLockedVenueSubtitle = "Upgrade to FanGeo Pro to reactivate."
    static let planLockedVenueHostedGameBlocked = "This venue is locked under the current business plan. Upgrade to FanGeo Pro to host games here."
    static let backendCompatibilityRequired = "FanGeo needs a quick update before this business feature can be used. Please update the app and try again."
}

struct BusinessEntitlementSnapshot: Decodable, Equatable {
    let business_id: UUID
    let plan_type: String?
    let plan_status: String?
    let pro_expires_at: String?
    let is_pro_active: Bool
    let days_remaining: Int?
    let statistics_enabled: Bool
    let sponsored_enabled: Bool
    let unlimited_venues: Bool
    let unlimited_hosting: Bool
    let venue_limit: Int?
    let monthly_host_limit: Int?
    let venues_used: Int
    let hosted_games_this_month: Int
}

struct BusinessVenueGamePostingStatus: Equatable {
    let promoActive: Bool
    let businessVenueCount: Int
    let monthlyHostedGameCount: Int
    let freeVenueListingLimitReached: Bool
    let freeMonthlyVenueGameLimitReached: Bool
    let limitsOverriddenBySummerPromo: Bool
    let businessProActive: Bool
    let businessId: UUID?
    let planType: String
    let planStatus: String
    let proExpiresAt: String?
    let daysRemaining: Int?
    let statisticsEnabled: Bool
    let sponsoredEnabled: Bool
    let unlimitedVenues: Bool
    let unlimitedHosting: Bool
    let venueLimit: Int
    let monthlyHostLimit: Int

    var isBusinessPro: Bool { businessProActive }
    var activeVenueCount: Int { businessVenueCount }
    var activeVenueLimit: Int? { unlimitedVenues || isBusinessPro ? nil : venueLimit }
    var monthlyHostedGameLimit: Int? { unlimitedHosting || isBusinessPro ? nil : monthlyHostLimit }
    var currentMonthHostedGameCount: Int { monthlyHostedGameCount }
    var hostedGameLimit: Int { monthlyHostLimit }
    var monthlyPostCount: Int { monthlyHostedGameCount }
    var freeLimitReached: Bool { freeMonthlyVenueGameLimitReached }

    private static let proPlanTypes: Set<String> = ["pro_promo", "pro_paid", "manual_pro"]
    private static let effectivelyUnlimitedMonthlyHostLimit = 10_000
    private static let effectivelyUnlimitedVenueLimit = 10_000

    var canAddVenue: Bool {
        if isBusinessPro || unlimitedVenues { return true }
        return activeVenueCount < max(1, venueLimit)
    }

    var canAddHostedGame: Bool {
        if isBusinessPro || unlimitedHosting { return true }
        return monthlyHostedGameCount < max(1, monthlyHostLimit)
    }

    var canHostBusinessGames: Bool { canAddHostedGame }

    var venueLimitReason: String {
        if isBusinessPro { return "business_pro" }
        if unlimitedVenues { return "unlimited_venues" }
        if activeVenueCount < max(1, venueLimit) { return "within_active_venue_limit" }
        return "active_venue_limit_reached"
    }

    var hostedGameLimitReason: String {
        if isBusinessPro { return "business_pro" }
        if unlimitedHosting {
            if monthlyHostLimitIsEffectivelyUnlimited { return "monthly_host_limit_unlimited" }
            return "unlimited_hosting"
        }
        if monthlyHostedGameCount < max(1, monthlyHostLimit) {
            return "within_monthly_host_limit"
        }
        return "monthly_host_limit_reached"
    }

    var canHostBusinessGamesReason: String { hostedGameLimitReason }

    private var monthlyHostLimitIsEffectivelyUnlimited: Bool {
        monthlyHostLimit >= Self.effectivelyUnlimitedMonthlyHostLimit
    }

    static func freeFallback(
        businessId: UUID?,
        venuesUsed: Int = 0,
        hostedGamesThisMonth: Int = 0,
        planStatus: String = "active"
    ) -> BusinessVenueGamePostingStatus {
        BusinessVenueGamePostingStatus(
            promoActive: false,
            businessVenueCount: venuesUsed,
            monthlyHostedGameCount: hostedGamesThisMonth,
            freeVenueListingLimitReached: venuesUsed >= BusinessMembershipPolicy.freeVenueListingLimit,
            freeMonthlyVenueGameLimitReached: hostedGamesThisMonth >= BusinessMembershipPolicy.freeMonthlyVenueGameLimit,
            limitsOverriddenBySummerPromo: false,
            businessProActive: false,
            businessId: businessId,
            planType: "free",
            planStatus: planStatus,
            proExpiresAt: nil,
            daysRemaining: nil,
            statisticsEnabled: false,
            sponsoredEnabled: false,
            unlimitedVenues: false,
            unlimitedHosting: false,
            venueLimit: BusinessMembershipPolicy.freeVenueListingLimit,
            monthlyHostLimit: BusinessMembershipPolicy.freeMonthlyVenueGameLimit
        )
    }

    static func fromServer(
        _ entitlement: BusinessEntitlementSnapshot,
        activeVenueCount: Int? = nil
    ) -> BusinessVenueGamePostingStatus {
        let rawPlanType = entitlement.plan_type ?? "free"
        let rawPlanStatus = entitlement.plan_status ?? "active"
        let planType = rawPlanType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let planStatus = rawPlanStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let planStatusAllowsProAccess = planStatus.isEmpty || planStatus == "active"
        let expirationAllowsProAccess: Bool = {
            guard let raw = entitlement.pro_expires_at?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return true
            }
            guard let expiry = SupabaseTimestampParsing.parseTimestamptz(raw) else {
                return false
            }
            return expiry > Date()
        }()
        let venueLimitIsUnlimited = entitlement.venue_limit == nil
            || (entitlement.venue_limit ?? 0) >= effectivelyUnlimitedVenueLimit
        let monthlyLimitIsUnlimited = entitlement.monthly_host_limit == nil
            || (entitlement.monthly_host_limit ?? 0) >= effectivelyUnlimitedMonthlyHostLimit
        let activeProPlan = proPlanTypes.contains(planType)
            && planStatusAllowsProAccess
            && expirationAllowsProAccess
        let rawUnlimitedVenuesIsActive = entitlement.unlimited_venues && planStatusAllowsProAccess && expirationAllowsProAccess
        let rawUnlimitedHostingIsActive = entitlement.unlimited_hosting && planStatusAllowsProAccess && expirationAllowsProAccess
        let normalizedBusinessProActive = (entitlement.is_pro_active && planStatusAllowsProAccess && expirationAllowsProAccess)
            || activeProPlan
            || rawUnlimitedVenuesIsActive
            || rawUnlimitedHostingIsActive
        let venueLimitGrantsUnlimitedVenues = venueLimitIsUnlimited
            && planStatusAllowsProAccess
            && expirationAllowsProAccess
            && (normalizedBusinessProActive || planType != "free")
        let monthlyLimitGrantsUnlimitedHosting = monthlyLimitIsUnlimited
            && planStatusAllowsProAccess
            && expirationAllowsProAccess
            && (normalizedBusinessProActive || planType != "free")
        let normalizedUnlimitedVenues = normalizedBusinessProActive
            || venueLimitGrantsUnlimitedVenues
        let normalizedUnlimitedHosting = normalizedBusinessProActive
            || monthlyLimitGrantsUnlimitedHosting
        let normalizedVenueLimit: Int
        if normalizedUnlimitedVenues {
            normalizedVenueLimit = entitlement.venue_limit ?? effectivelyUnlimitedVenueLimit
        } else if venueLimitIsUnlimited {
            normalizedVenueLimit = BusinessMembershipPolicy.freeVenueListingLimit
        } else {
            normalizedVenueLimit = entitlement.venue_limit ?? BusinessMembershipPolicy.freeVenueListingLimit
        }
        let normalizedMonthlyHostLimit: Int
        if normalizedUnlimitedHosting {
            normalizedMonthlyHostLimit = entitlement.monthly_host_limit ?? effectivelyUnlimitedMonthlyHostLimit
        } else if monthlyLimitIsUnlimited {
            normalizedMonthlyHostLimit = BusinessMembershipPolicy.freeMonthlyVenueGameLimit
        } else {
            normalizedMonthlyHostLimit = entitlement.monthly_host_limit ?? BusinessMembershipPolicy.freeMonthlyVenueGameLimit
        }
        let isPromo = normalizedBusinessProActive && planType == "pro_promo"
        let venueCount = activeVenueCount ?? entitlement.venues_used
        return BusinessVenueGamePostingStatus(
            promoActive: isPromo,
            businessVenueCount: venueCount,
            monthlyHostedGameCount: entitlement.hosted_games_this_month,
            freeVenueListingLimitReached: !normalizedUnlimitedVenues && venueCount >= normalizedVenueLimit,
            freeMonthlyVenueGameLimitReached: !normalizedUnlimitedHosting && entitlement.hosted_games_this_month >= normalizedMonthlyHostLimit,
            limitsOverriddenBySummerPromo: isPromo,
            businessProActive: normalizedBusinessProActive,
            businessId: entitlement.business_id,
            planType: rawPlanType,
            planStatus: rawPlanStatus,
            proExpiresAt: entitlement.pro_expires_at,
            daysRemaining: entitlement.days_remaining,
            statisticsEnabled: entitlement.statistics_enabled,
            sponsoredEnabled: entitlement.sponsored_enabled,
            unlimitedVenues: normalizedUnlimitedVenues,
            unlimitedHosting: normalizedUnlimitedHosting,
            venueLimit: normalizedVenueLimit,
            monthlyHostLimit: normalizedMonthlyHostLimit
        )
    }
}

@MainActor
final class BusinessProPurchaseService: ObservableObject {
    static let shared = BusinessProPurchaseService()
    static let productID = "com.fangeo.businesspro.monthly"

    @Published private(set) var product: Product?
    @Published private(set) var isLoadingProduct = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published private(set) var productLoadFailed = false
    @Published var purchaseMessage = ""

    private var didLoadProducts = false
    private var updatesTask: Task<Void, Never>?

    /// Compatibility value for older call sites. Business Pro activation must come from Supabase entitlements only.
    var businessProActive: Bool { false }

    var canPurchase: Bool {
        product != nil && !isLoadingProduct && !isPurchasing
    }

    var billingUnavailableMessage: String {
        "Business Pro billing is coming soon."
    }

    var manageSubscriptionURL: URL? {
        URL(string: "https://apps.apple.com/account/subscriptions")
    }

    private init() {
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handleTransactionUpdate(result)
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func prepare() async {
        await loadProductIfNeeded()
    }

    func loadProductIfNeeded() async {
        guard !didLoadProducts, !isLoadingProduct else { return }
        didLoadProducts = true
        isLoadingProduct = true
        productLoadFailed = false
        defer { isLoadingProduct = false }

        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first(where: { $0.id == Self.productID })
            productLoadFailed = product == nil
            if product == nil {
                purchaseMessage = billingUnavailableMessage
#if DEBUG
                print("[BusinessProPurchase] productLoad productId=\(Self.productID) found=false")
#endif
            } else {
#if DEBUG
                print("[BusinessProPurchase] productLoad productId=\(Self.productID) found=true")
#endif
            }
        } catch {
            product = nil
            productLoadFailed = true
            purchaseMessage = billingUnavailableMessage
#if DEBUG
            print("[BusinessProPurchase] productLoad error=\(error.localizedDescription)")
#endif
        }
    }

    @discardableResult
    func purchaseBusinessPro() async -> Bool {
        await loadProductIfNeeded()
#if DEBUG
        print("[BusinessProPurchase] purchaseStarted productId=\(Self.productID)")
#endif
        guard let product else {
            purchaseMessage = billingUnavailableMessage
#if DEBUG
            print("[BusinessProPurchase] purchaseUnavailable reason=product_not_found")
#endif
            return false
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verified(verification)
                await sendTransactionToBackendPlaceholder(transaction)
                await transaction.finish()
                purchaseMessage = "Purchase received. Activation will be verified shortly."
#if DEBUG
                print("[BusinessProPurchase] purchaseSucceeded transactionId=\(transaction.id)")
                print("[BusinessProPurchase] localUnlock=false sourceOfTruth=supabase")
#endif
                return true
            case .pending:
                purchaseMessage = "Purchase pending."
#if DEBUG
                print("[BusinessProPurchase] purchasePending=true")
#endif
                return false
            case .userCancelled:
                purchaseMessage = ""
#if DEBUG
                print("[BusinessProPurchase] purchaseCancelled=true")
#endif
                return false
            @unknown default:
                purchaseMessage = "Purchase unavailable."
#if DEBUG
                print("[BusinessProPurchase] purchaseFailed=unknown_result")
#endif
                return false
            }
        } catch {
            purchaseMessage = error.localizedDescription
#if DEBUG
            print("[BusinessProPurchase] purchaseFailed error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    func restorePurchases() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
#if DEBUG
            print("[BusinessProPurchase] restoreStarted=true")
#endif
            try await AppStore.sync()
            let foundBusinessProTransaction = await sendCurrentBusinessProTransactionsToBackendPlaceholder()
            purchaseMessage = foundBusinessProTransaction
                ? "Purchase received. Activation will be verified shortly."
                : "No Business Pro purchases found."
#if DEBUG
            print("[BusinessProPurchase] restoreFinished foundBusinessProTransaction=\(foundBusinessProTransaction)")
            print("[BusinessProPurchase] localUnlock=false sourceOfTruth=supabase")
#endif
        } catch {
            purchaseMessage = error.localizedDescription
#if DEBUG
            print("[BusinessProPurchase] restoreFailed error=\(error.localizedDescription)")
#endif
        }
    }

    func refreshPurchasedEntitlements() async {
#if DEBUG
        print("[BusinessProPurchase] refreshPurchasedEntitlements localUnlock=false")
#endif
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard let transaction = try? verified(result) else { return }
        if transaction.productID == Self.productID {
            await sendTransactionToBackendPlaceholder(transaction)
            await transaction.finish()
#if DEBUG
            print("[BusinessProPurchase] transactionUpdate transactionId=\(transaction.id)")
            print("[BusinessProPurchase] localUnlock=false sourceOfTruth=supabase")
#endif
        }
    }

    @discardableResult
    private func sendCurrentBusinessProTransactionsToBackendPlaceholder() async -> Bool {
        var foundBusinessProTransaction = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verified(result), transaction.productID == Self.productID else {
                continue
            }
            foundBusinessProTransaction = true
            await sendTransactionToBackendPlaceholder(transaction)
        }
        return foundBusinessProTransaction
    }

    private func sendTransactionToBackendPlaceholder(_ transaction: Transaction) async {
#if DEBUG
        print("[BusinessProPurchase] backendPlaceholder notImplemented=true")
        print("[BusinessProPurchase] transactionId=\(transaction.id) originalId=\(transaction.originalID) productId=\(transaction.productID)")
#endif
        // Real activation must be performed later by backend App Store Server validation updating Supabase.
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified(_, let error):
            throw error
        }
    }
}

typealias BusinessProEntitlementManager = BusinessProPurchaseService
