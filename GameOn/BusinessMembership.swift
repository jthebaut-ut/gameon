import Foundation
import Combine
import StoreKit

enum BusinessMembershipPolicy {
    static let freeVenueListingLimit = 5
    static let freeMonthlyVenueGameLimit = 5

    static func summerPromotionEnd(calendar: Calendar = .current) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = 2026
        components.month = 8
        components.day = 31
        components.hour = 23
        components.minute = 59
        components.second = 59
        return components.date ?? .distantPast
    }

    static func summerPromotionIsActive(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        now <= summerPromotionEnd(calendar: calendar)
    }

    static func currentMonthWindow(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            ?? calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .month, value: 1, to: start)
            ?? now.addingTimeInterval(31 * 24 * 60 * 60)
        return (start, end)
    }
}

struct BusinessVenueGamePostingStatus: Equatable {
    let promoActive: Bool
    let businessVenueCount: Int
    let monthlyHostedGameCount: Int
    let freeVenueListingLimitReached: Bool
    let freeMonthlyVenueGameLimitReached: Bool
    let limitsOverriddenBySummerPromo: Bool
    let businessProActive: Bool

    var monthlyPostCount: Int { monthlyHostedGameCount }
    var freeLimitReached: Bool { freeMonthlyVenueGameLimitReached }

    static var summerPromo: BusinessVenueGamePostingStatus {
        BusinessVenueGamePostingStatus(
            promoActive: true,
            businessVenueCount: 0,
            monthlyHostedGameCount: 0,
            freeVenueListingLimitReached: false,
            freeMonthlyVenueGameLimitReached: false,
            limitsOverriddenBySummerPromo: true,
            businessProActive: false
        )
    }
}

@MainActor
final class BusinessProEntitlementManager: ObservableObject {
    static let shared = BusinessProEntitlementManager()
    static let productID = "fangeo_business_pro_monthly"

    @Published private(set) var product: Product?
    @Published private(set) var businessProActive = false
    @Published private(set) var isLoadingProduct = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var productLoadFailed = false
    @Published var purchaseMessage = ""

    private var didLoadProducts = false
    private var updatesTask: Task<Void, Never>?

    var canPurchase: Bool {
        product != nil && !isPurchasing
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
        await refreshPurchasedEntitlements()
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
                purchaseMessage = "Subscription coming soon"
            }
        } catch {
            product = nil
            productLoadFailed = true
            purchaseMessage = "Subscription coming soon"
        }
    }

    @discardableResult
    func purchaseBusinessPro() async -> Bool {
        print("[BusinessMembershipDebug] purchaseStarted=true")
        guard let product else {
            purchaseMessage = "Subscription coming soon"
            print("[BusinessMembershipDebug] purchaseFailed=product_unavailable")
            return false
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verified(verification)
                await transaction.finish()
                businessProActive = true
                purchaseMessage = "FanGeo Business Pro is active."
                print("[BusinessMembershipDebug] purchaseSucceeded=true")
                return true
            case .pending:
                purchaseMessage = "Purchase pending."
                print("[BusinessMembershipDebug] purchaseFailed=pending")
                return false
            case .userCancelled:
                purchaseMessage = ""
                print("[BusinessMembershipDebug] purchaseFailed=user_cancelled")
                return false
            @unknown default:
                purchaseMessage = "Purchase unavailable."
                print("[BusinessMembershipDebug] purchaseFailed=unknown_result")
                return false
            }
        } catch {
            purchaseMessage = error.localizedDescription
            print("[BusinessMembershipDebug] purchaseFailed=\(error.localizedDescription)")
            return false
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshPurchasedEntitlements()
            purchaseMessage = businessProActive ? "Purchases restored." : "No active Business Pro purchase found."
        } catch {
            purchaseMessage = error.localizedDescription
        }
    }

    func refreshPurchasedEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verified(result) else { continue }
            if transaction.productID == Self.productID {
                active = true
                break
            }
        }
        businessProActive = active
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard let transaction = try? verified(result) else { return }
        if transaction.productID == Self.productID {
            businessProActive = true
            await transaction.finish()
        }
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
