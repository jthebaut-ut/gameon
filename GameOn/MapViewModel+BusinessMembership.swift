import Foundation
import Supabase

private struct BusinessEntitlementRpcParams: Encodable {
    let p_business_id: String
}

private struct BusinessHostedGameCycleAuditRPCRow: Decodable {
    let business_id: UUID
    let cycle_start_at: String?
    let cycle_end_at: String?
    let next_reset_at: String?
    let hosted_games_used_this_cycle: Int?
    let monthly_host_limit: Int?
    let is_unlimited_hosting: Bool?
    let venue_event_id: UUID?
    let title: String?
    let sport: String?
    let scheduled_start_at: String?
    let event_date: String?
    let event_time: String?
    let status: String?
    let venue_name: String?
}

private enum BusinessHostedGameCycleAuditError: Error {
    case emptyResponse
}

extension MapViewModel {
    func businessVenueGamePostingStatus(
        storeKitBusinessProActive: Bool,
        businessId explicitBusinessId: UUID? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> BusinessVenueGamePostingStatus {
        _ = storeKitBusinessProActive

        guard let businessId = explicitBusinessId ?? currentBusinessIdForAddLocation() else {
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
            logBusinessVenueAddGate(
                businessId: businessId,
                status: fallback,
                activeApprovedCount: activeVenueCount
            )
            logBusinessEntitlementDebug(
                businessId: businessId,
                source: "rpcFallbackFree",
                status: fallback
            )
            return fallback
        }

        let activeVenueCount = activeManagedVenueListingCount(businessId: businessId)
        let status = BusinessVenueGamePostingStatus.fromServer(
            entitlement,
            activeVenueCount: activeVenueCount
        )
        logBusinessVenueAddGate(
            businessId: businessId,
            status: status,
            activeApprovedCount: activeVenueCount
        )
        logBusinessEntitlementDebug(
            businessId: businessId,
            source: "business_entitlements",
            status: status
        )
        return status
    }

    func loadBusinessEntitlements(businessId: UUID) async -> BusinessEntitlementSnapshot? {
        if let v2 = await loadBusinessEntitlements(
            rpcName: "get_business_entitlements_v2",
            businessId: businessId
        ) {
            return v2
        }
        return await loadBusinessEntitlements(
            rpcName: "get_business_entitlements",
            businessId: businessId
        )
    }

    private func loadBusinessEntitlements(
        rpcName: String,
        businessId: UUID
    ) async -> BusinessEntitlementSnapshot? {
        do {
            let rows: [BusinessEntitlementSnapshot] = try await supabase
                .rpc(
                    rpcName,
                    params: BusinessEntitlementRpcParams(p_business_id: businessId.uuidString.lowercased())
                )
                .execute()
                .value
            return rows.first
        } catch {
#if DEBUG
            print("[BusinessEntitlementDebug] rpc=\(rpcName) businessId=\(businessId.uuidString.lowercased()) error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    func loadBusinessHostedGamesThisCycle(businessId: UUID) async throws -> BusinessHostedGameCycleAudit {
        do {
            let rows: [BusinessHostedGameCycleAuditRPCRow] = try await supabase
                .rpc(
                    "get_business_hosted_games_this_cycle",
                    params: BusinessEntitlementRpcParams(p_business_id: businessId.uuidString.lowercased())
                )
                .execute()
                .value

            guard let summary = rows.first else {
#if DEBUG
                print("[BusinessUsageCycleDebug] business_id=\(businessId.uuidString.lowercased()) cycle_start=nil cycle_end=nil returned_row_count=0 hosted_games_used_this_cycle=0 limit=0 unlimited=false")
#endif
                throw BusinessHostedGameCycleAuditError.emptyResponse
            }

            let games = rows.compactMap { row -> BusinessHostedGameCycleGame? in
                guard let id = row.venue_event_id else { return nil }
                let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return BusinessHostedGameCycleGame(
                    id: id,
                    title: title?.isEmpty == false ? (title ?? "Hosted game") : "Hosted game",
                    sport: row.sport,
                    scheduledStartAt: row.scheduled_start_at,
                    eventDate: row.event_date,
                    eventTime: row.event_time,
                    status: row.status,
                    venueName: row.venue_name
                )
            }

            let audit = BusinessHostedGameCycleAudit(
                businessId: summary.business_id,
                cycleStartAt: summary.cycle_start_at,
                cycleEndAt: summary.cycle_end_at,
                nextResetAt: summary.next_reset_at,
                hostedGamesUsedThisCycle: summary.hosted_games_used_this_cycle ?? games.count,
                monthlyHostLimit: summary.monthly_host_limit ?? BusinessMembershipPolicy.freeMonthlyVenueGameLimit,
                isUnlimitedHosting: summary.is_unlimited_hosting ?? false,
                games: games
            )
#if DEBUG
            print("[BusinessUsageCycleDebug] business_id=\(audit.businessId.uuidString.lowercased()) cycle_start=\(audit.cycleStartAt ?? "nil") cycle_end=\(audit.cycleEndAt ?? audit.nextResetAt ?? "nil") returned_row_count=\(audit.games.count) hosted_games_used_this_cycle=\(audit.hostedGamesUsedThisCycle) limit=\(audit.monthlyHostLimit) unlimited=\(audit.isUnlimitedHosting)")
#endif
            return audit
        } catch {
#if DEBUG
            print("[BusinessUsageCycleDebug] business_id=\(businessId.uuidString.lowercased()) error=\(error.localizedDescription)")
#endif
            throw error
        }
    }

    private func activeManagedVenueListingCount(businessId: UUID) -> Int {
        let ids = managedVenuesForOwner().compactMap { row -> UUID? in
            guard venueRowBelongsToBusiness(row, businessId: businessId) else { return nil }
            guard Self.venueIsActiveForBusinessLimit(row) else { return nil }
            return row.id
        }
        return Set(ids).count
    }

    private func venueRowBelongsToBusiness(_ row: VenueProfileRow, businessId: UUID) -> Bool {
        if row.business_id == businessId { return true }
        if let id = row.id,
           approvedVenueClaimMetadataByVenueID[id]?.businessId == businessId {
            return true
        }
        return row.business_id == nil && ownedBusinesses.count == 1
    }

    private func managedVenueStatusCount(
        businessId: UUID,
        matching isMatch: (String) -> Bool
    ) -> Int {
        let ids = managedVenuesForOwner().compactMap { row -> UUID? in
            guard venueRowBelongsToBusiness(row, businessId: businessId) else { return nil }
            guard isMatch(Self.venueAdminStatus(row.admin_status)) else { return nil }
            return row.id
        }
        return Set(ids).count
    }

    private func logBusinessVenueAddGate(
        businessId: UUID,
        status: BusinessVenueGamePostingStatus,
        activeApprovedCount: Int
    ) {
#if DEBUG
        let effectiveVenueLimit = status.activeVenueLimit.map(String.init) ?? "unlimited"
        let archivedCount = managedVenueStatusCount(businessId: businessId) { $0 == "archived" }
        let deletedCount = managedVenueStatusCount(businessId: businessId) {
            $0 == "deleted" || $0 == "removed" || $0 == "hard_deleted"
        }
        print("[BusinessVenueLimitDebug] addVenueGate businessId=\(businessId.uuidString.lowercased()) activeApprovedCount=\(activeApprovedCount) effectiveVenueLimit=\(effectiveVenueLimit) archivedCount=\(archivedCount) deletedCount=\(deletedCount) isLocked=\(!status.canAddVenue)")
#endif
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
        print("[BusinessEntitlementDebug] planType=\(status.planType) planStatus=\(status.planStatus) entitlementSource=\(status.entitlementSource ?? "nil") proExpiresAt=\(status.proExpiresAt ?? "nil") isProActive=\(status.computedIsPro) loadedFromServer=\(status.loadedFromServer)")
        print("[BusinessEntitlementDebug] activeVenueCount=\(status.activeVenueCount) activeVenueLimit=\(status.activeVenueLimit.map(String.init) ?? "unlimited") unlimitedVenues=\(status.unlimitedVenues)")
        print("[BusinessEntitlementDebug] hostedGamesThisMonth=\(status.monthlyHostedGameCount) hostedGamesUsedThisCycle=\(status.hostedGamesUsedThisCycle.map(String.init) ?? "nil") monthlyHostLimit=\(status.monthlyHostLimit) nextResetAt=\(status.nextResetAt ?? "nil") unlimitedHosting=\(status.unlimitedHosting)")
        print("[BusinessEntitlementDebug] statisticsAccess=\(status.statisticsAccessGranted) sponsoredAccess=\(status.sponsoredPlacementAllowed)")
        print("[BusinessEntitlementDebug] businessId=\(businessId?.uuidString.lowercased() ?? "nil") plan_type=\(status.planType) plan_status=\(status.planStatus) pro_expires_at=\(status.proExpiresAt ?? "nil") unlimited_venues=\(status.unlimitedVenues) unlimited_hosting=\(status.unlimitedHosting) activeVenueCount=\(status.activeVenueCount) activeVenueLimit=\(status.activeVenueLimit.map(String.init) ?? "unlimited") currentMonthHostedGameCount=\(status.currentMonthHostedGameCount) hostedGamesUsedForDisplay=\(status.hostedGamesUsedForDisplay) monthlyHostedGameLimit=\(status.monthlyHostedGameLimit.map(String.init) ?? "unlimited") canAddVenue=\(status.canAddVenue) canAddHostedGame=\(status.canAddHostedGame) venueLimitReason=\(status.venueLimitReason) hostedGameLimitReason=\(status.hostedGameLimitReason)")
#endif
    }
}
