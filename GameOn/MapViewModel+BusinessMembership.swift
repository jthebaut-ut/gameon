import Foundation
import Supabase

private struct BusinessEntitlementRpcParams: Encodable {
    let p_business_id: String
}

extension MapViewModel {
    func businessVenueGamePostingStatus(
        storeKitBusinessProActive: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> BusinessVenueGamePostingStatus {
        _ = storeKitBusinessProActive

        guard let businessId = currentBusinessIdForAddLocation() else {
            logBusinessEntitlementDebug(
                businessId: nil,
                source: "missingBusinessId",
                status: .freeFallback(businessId: nil)
            )
            return .freeFallback(businessId: nil)
        }

        guard let entitlement = await loadBusinessEntitlements(businessId: businessId) else {
            let activeVenueCount = activeManagedVenueListingCount(businessId: businessId)
            let fallback = BusinessVenueGamePostingStatus.freeFallback(
                businessId: businessId,
                venuesUsed: activeVenueCount
            )
            logBusinessEntitlementDebug(
                businessId: businessId,
                source: "rpcFallbackFree",
                status: fallback
            )
            return fallback
        }

        let status = BusinessVenueGamePostingStatus.fromServer(entitlement)
        logBusinessEntitlementDebug(
            businessId: businessId,
            source: "get_business_entitlements",
            status: status
        )
        return status
    }

    func loadBusinessEntitlements(businessId: UUID) async -> BusinessEntitlementSnapshot? {
        do {
            let rows: [BusinessEntitlementSnapshot] = try await supabase
                .rpc(
                    "get_business_entitlements",
                    params: BusinessEntitlementRpcParams(p_business_id: businessId.uuidString.lowercased())
                )
                .execute()
                .value
            return rows.first
        } catch {
#if DEBUG
            print("[BusinessEntitlementDebug] rpc=get_business_entitlements businessId=\(businessId.uuidString.lowercased()) error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    private func activeManagedVenueListingCount(businessId: UUID) -> Int {
        let ids = managedVenuesForOwner().compactMap { row -> UUID? in
            guard row.business_id == businessId else { return nil }
            guard Self.venueIsActiveForBusinessLimit(row) else { return nil }
            return row.id
        }
        return Set(ids).count
    }

    func canBusinessCreateVenueServerSide(businessId: UUID) async -> Bool {
        await loadBusinessLimitHelper(
            rpcName: "can_business_create_venue",
            businessId: businessId
        )
    }

    func canBusinessHostGameServerSide(businessId: UUID) async -> Bool {
        await loadBusinessLimitHelper(
            rpcName: "can_business_host_game",
            businessId: businessId
        )
    }

    func canBusinessAccessStatisticsServerSide(businessId: UUID) async -> Bool {
        await loadBusinessLimitHelper(
            rpcName: "can_business_access_statistics",
            businessId: businessId
        )
    }

    private func loadBusinessLimitHelper(rpcName: String, businessId: UUID) async -> Bool {
        do {
            let allowed: Bool = try await supabase
                .rpc(
                    rpcName,
                    params: BusinessEntitlementRpcParams(p_business_id: businessId.uuidString.lowercased())
                )
                .execute()
                .value
#if DEBUG
            print("[BusinessEntitlementDebug] rpc=\(rpcName) businessId=\(businessId.uuidString.lowercased()) allowed=\(allowed)")
#endif
            return allowed
        } catch {
#if DEBUG
            print("[BusinessEntitlementDebug] rpc=\(rpcName) businessId=\(businessId.uuidString.lowercased()) error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    private func logBusinessEntitlementDebug(
        businessId: UUID?,
        source: String,
        status: BusinessVenueGamePostingStatus
    ) {
#if DEBUG
        print("[BusinessEntitlementDebug] source=\(source) businessId=\(businessId?.uuidString.lowercased() ?? "nil")")
        print("[BusinessEntitlementDebug] planType=\(status.planType) planStatus=\(status.planStatus) proExpiresAt=\(status.proExpiresAt ?? "nil") isProActive=\(status.businessProActive)")
        print("[BusinessEntitlementDebug] activeVenueCount=\(status.activeVenueCount) activeVenueLimit=\(status.activeVenueLimit.map(String.init) ?? "unlimited") unlimitedVenues=\(status.unlimitedVenues)")
        print("[BusinessEntitlementDebug] hostedGamesThisMonth=\(status.monthlyHostedGameCount) monthlyHostLimit=\(status.monthlyHostLimit) unlimitedHosting=\(status.unlimitedHosting)")
        print("[BusinessEntitlementDebug] statisticsAccess=\(status.statisticsEnabled) sponsoredAccess=\(status.sponsoredEnabled)")
        print("[BusinessEntitlementDebug] businessId=\(businessId?.uuidString.lowercased() ?? "nil") plan_type=\(status.planType) plan_status=\(status.planStatus) pro_expires_at=\(status.proExpiresAt ?? "nil") unlimited_venues=\(status.unlimitedVenues) unlimited_hosting=\(status.unlimitedHosting) activeVenueCount=\(status.activeVenueCount) activeVenueLimit=\(status.activeVenueLimit.map(String.init) ?? "unlimited") currentMonthHostedGameCount=\(status.currentMonthHostedGameCount) monthlyHostedGameLimit=\(status.monthlyHostedGameLimit.map(String.init) ?? "unlimited") canAddVenue=\(status.canAddVenue) canAddHostedGame=\(status.canAddHostedGame) venueLimitReason=\(status.venueLimitReason) hostedGameLimitReason=\(status.hostedGameLimitReason)")
#endif
    }
}
