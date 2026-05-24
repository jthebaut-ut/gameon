import Foundation
import Supabase

private struct BusinessMembershipVenueEventCountRow: Decodable {
    let id: UUID?
}

private struct BusinessMembershipHistoryCountRow: Decodable {
    let original_venue_event_id: UUID?
}

private struct BusinessMembershipProEntitlementRow: Decodable {
    let business_pro_active: Bool?
}

extension MapViewModel {
    func businessVenueGamePostingStatus(
        storeKitBusinessProActive: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> BusinessVenueGamePostingStatus {
        let promoActive = BusinessMembershipPolicy.summerPromotionIsActive(now: now, calendar: calendar)
            && hasBusinessAccountForOwner()
        let supabaseBusinessProActive = storeKitBusinessProActive
            ? true
            : await loadSupabaseBusinessProEntitlementIfAvailable()
        let businessProActive = storeKitBusinessProActive || supabaseBusinessProActive
        let businessVenueCount = await loadBusinessVenueListingCountForBusinessAccount()
        let monthlyHostedGameCount = await loadBusinessVenueGamePostCountForCurrentMonth(now: now, calendar: calendar)
        let limitsOverriddenBySummerPromo = promoActive
        let freeVenueListingLimitReached = !limitsOverriddenBySummerPromo
            && !businessProActive
            && businessVenueCount >= BusinessMembershipPolicy.freeVenueListingLimit
        let freeMonthlyVenueGameLimitReached = !limitsOverriddenBySummerPromo
            && !businessProActive
            && monthlyHostedGameCount >= BusinessMembershipPolicy.freeMonthlyVenueGameLimit

        logBusinessMembershipDebug(
            businessVenueCount: businessVenueCount,
            monthlyHostedGameCount: monthlyHostedGameCount,
            limitsOverriddenBySummerPromo: limitsOverriddenBySummerPromo,
            businessProActive: businessProActive
        )

        return BusinessVenueGamePostingStatus(
            promoActive: promoActive,
            businessVenueCount: businessVenueCount,
            monthlyHostedGameCount: monthlyHostedGameCount,
            freeVenueListingLimitReached: freeVenueListingLimitReached,
            freeMonthlyVenueGameLimitReached: freeMonthlyVenueGameLimitReached,
            limitsOverriddenBySummerPromo: limitsOverriddenBySummerPromo,
            businessProActive: businessProActive
        )
    }

    private func loadBusinessVenueListingCountForBusinessAccount() async -> Int {
        let ownerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
        let businessId = currentBusinessIdForAddLocation()
        var venueIds = Set<UUID>()

        if let businessId {
            do {
                let businessRows: [VenueProfileRow] = try await supabase
                    .from("venues")
                    .select("id")
                    .eq("business_id", value: businessId.uuidString.lowercased())
                    .eq("admin_status", value: "active")
                    .execute()
                    .value
                venueIds.formUnion(businessRows.compactMap(\.id))
            } catch {
                print("[BusinessMembershipDebug] businessVenueCountBusinessQueryFailed=\(error.localizedDescription)")
            }
        }

        if OwnerBusinessEmail.isValidStrict(ownerEmail) {
            do {
                let ownerRows: [VenueProfileRow] = try await supabase
                    .from("venues")
                    .select("id")
                    .eq("owner_email", value: ownerEmail)
                    .eq("admin_status", value: "active")
                    .execute()
                    .value
                venueIds.formUnion(ownerRows.compactMap(\.id))
            } catch {
                print("[BusinessMembershipDebug] businessVenueCountOwnerQueryFailed=\(error.localizedDescription)")
            }
        }

        if venueIds.isEmpty {
            venueIds.formUnion(managedVenuesForOwner().compactMap(\.id))
        }

        return venueIds.count
    }

    private func loadBusinessVenueGamePostCountForCurrentMonth(now: Date, calendar: Calendar) async -> Int {
        let window = BusinessMembershipPolicy.currentMonthWindow(now: now, calendar: calendar)
        let startISO = Self.businessMembershipISOFormatter.string(from: window.start)
        let endISO = Self.businessMembershipISOFormatter.string(from: window.end)
        let ownerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
        let businessId = currentBusinessIdForAddLocation()
        let managedVenueIds = managedVenuesForOwner()
            .filter { row in
                guard let businessId else { return true }
                return row.business_id == nil || row.business_id == businessId
            }
            .compactMap(\.id)

        var eventIds = Set<UUID>()

        if OwnerBusinessEmail.isValidStrict(ownerEmail) {
            do {
                let ownerRows: [BusinessMembershipVenueEventCountRow] = try await supabase
                    .from("venue_events")
                    .select("id")
                    .eq("owner_email", value: ownerEmail)
                    .gte("created_at", value: startISO)
                    .lt("created_at", value: endISO)
                    .execute()
                    .value
                eventIds.formUnion(ownerRows.compactMap(\.id))
            } catch {
                print("[BusinessMembershipDebug] monthlyHostedGameCountOwnerQueryFailed=\(error.localizedDescription)")
            }
        }

        if !managedVenueIds.isEmpty {
            do {
                let venueRows: [BusinessMembershipVenueEventCountRow] = try await supabase
                    .from("venue_events")
                    .select("id")
                    .in("venue_id", values: managedVenueIds.map { $0.uuidString.lowercased() })
                    .gte("created_at", value: startISO)
                    .lt("created_at", value: endISO)
                    .execute()
                    .value
                eventIds.formUnion(venueRows.compactMap(\.id))
            } catch {
                print("[BusinessMembershipDebug] monthlyHostedGameCountVenueQueryFailed=\(error.localizedDescription)")
            }
        }

        if let businessId {
            do {
                let historyRows: [BusinessMembershipHistoryCountRow] = try await supabase
                    .from("business_game_history")
                    .select("original_venue_event_id")
                    .eq("business_id", value: businessId.uuidString.lowercased())
                    .gte("created_at", value: startISO)
                    .lt("created_at", value: endISO)
                    .execute()
                    .value
                eventIds.formUnion(historyRows.compactMap(\.original_venue_event_id))
            } catch {
                print("[BusinessMembershipDebug] monthlyHostedGameCountHistoryQueryFailed=\(error.localizedDescription)")
            }
        }

        return eventIds.count
    }

    private func loadSupabaseBusinessProEntitlementIfAvailable() async -> Bool {
        if let businessId = currentBusinessIdForAddLocation(),
           await loadBusinessProEntitlementFromBusinessesTable(businessId: businessId) == true {
            return true
        }

        guard let authId = currentUserAuthId else { return false }
        return await loadBusinessProEntitlementFromUserProfile(userId: authId)
    }

    private func loadBusinessProEntitlementFromBusinessesTable(businessId: UUID) async -> Bool? {
        do {
            let rows: [BusinessMembershipProEntitlementRow] = try await supabase
                .from("businesses")
                .select("business_pro_active")
                .eq("id", value: businessId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            return rows.first?.business_pro_active == true
        } catch {
            print("[BusinessMembershipDebug] businessProActiveColumnMissingOrUnreadable=businesses.business_pro_active")
            return nil
        }
    }

    private func loadBusinessProEntitlementFromUserProfile(userId: UUID) async -> Bool {
        do {
            let rows: [BusinessMembershipProEntitlementRow] = try await supabase
                .from("user_profiles")
                .select("business_pro_active")
                .eq("id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            return rows.first?.business_pro_active == true
        } catch {
            print("[BusinessMembershipDebug] businessProActiveColumnMissingOrUnreadable=user_profiles.business_pro_active")
            return false
        }
    }

    private func logBusinessMembershipDebug(
        businessVenueCount: Int,
        monthlyHostedGameCount: Int,
        limitsOverriddenBySummerPromo: Bool,
        businessProActive: Bool
    ) {
        print("[BusinessEntitlementDebug] businessVenueCount=\(businessVenueCount)")
        print("[BusinessEntitlementDebug] monthlyHostedGameCount=\(monthlyHostedGameCount)")
        print("[BusinessEntitlementDebug] limitsOverriddenBySummerPromo=\(limitsOverriddenBySummerPromo)")
        print("[BusinessEntitlementDebug] businessProActive=\(businessProActive)")
    }

    private static let businessMembershipISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
