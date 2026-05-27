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

struct BusinessEntitlementSnapshot: Decodable, Equatable {
    let business_id: UUID
    let plan_type: String
    let plan_status: String
    let pro_expires_at: String?
    let is_pro_active: Bool
    let days_remaining: Int?
    let statistics_enabled: Bool
    let sponsored_enabled: Bool
    let unlimited_venues: Bool
    let unlimited_hosting: Bool
    let venue_limit: Int
    let monthly_host_limit: Int
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

    var monthlyPostCount: Int { monthlyHostedGameCount }
    var freeLimitReached: Bool { freeMonthlyVenueGameLimitReached }

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

    static func fromServer(_ entitlement: BusinessEntitlementSnapshot) -> BusinessVenueGamePostingStatus {
        let isPromo = entitlement.is_pro_active && entitlement.plan_type == "pro_promo"
        return BusinessVenueGamePostingStatus(
            promoActive: isPromo,
            businessVenueCount: entitlement.venues_used,
            monthlyHostedGameCount: entitlement.hosted_games_this_month,
            freeVenueListingLimitReached: !entitlement.unlimited_venues && entitlement.venues_used >= entitlement.venue_limit,
            freeMonthlyVenueGameLimitReached: !entitlement.unlimited_hosting && entitlement.hosted_games_this_month >= entitlement.monthly_host_limit,
            limitsOverriddenBySummerPromo: isPromo,
            businessProActive: entitlement.is_pro_active,
            businessId: entitlement.business_id,
            planType: entitlement.plan_type,
            planStatus: entitlement.plan_status,
            proExpiresAt: entitlement.pro_expires_at,
            daysRemaining: entitlement.days_remaining,
            statisticsEnabled: entitlement.statistics_enabled,
            sponsoredEnabled: entitlement.sponsored_enabled,
            unlimitedVenues: entitlement.unlimited_venues,
            unlimitedHosting: entitlement.unlimited_hosting,
            venueLimit: entitlement.venue_limit,
            monthlyHostLimit: entitlement.monthly_host_limit
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
