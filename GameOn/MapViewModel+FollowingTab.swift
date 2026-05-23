import CoreLocation
import Foundation
import Supabase

// MARK: - Following tab (global favorites + going; not scoped to Discover map region)

extension MapViewModel {

    /// UserDefaults key must match ``FollowingScreen`` `@AppStorage("gameon.following.interestedOnlyVenueEventIDs")`.
    private static let interestedOnlyVenueEventDefaultsKey = "gameon.following.interestedOnlyVenueEventIDs"

    private static let venueSelectColumnsFollowing =
        "id,owner_email,business_id,admin_status,venue_name,address,address_line1,address_line2,city,state,zip_code,region,postal_code,country,formatted_address,phone,website,description,features,screen_count,serves_food,has_wifi,has_garden,has_projector,pet_friendly,latitude,longitude,cover_photo_url,menu_photo_url,cover_photo_thumbnail_url,menu_photo_thumbnail_url,businesses!venues_business_id_fkey(owner_email,admin_status)"

    private static let venueEventSelectColumnsFollowing =
        "id,venue_id,owner_email,venue_name,event_title,sport,home_team,away_team,event_date,event_time,scheduled_start_at,cleanup_delay_hours,purge_after_at,external_league,external_game_id,external_source,imported_from_api"

    private static let interestChunkSize = 90
    private static let followingTabGlobalRefreshFreshnessInterval: TimeInterval = 60

    /// Skips ``refreshFollowingTabDataGlobally()`` when a global refresh completed recently (launch dedupe).
    func refreshFollowingTabDataGloballyUnlessFresh() async {
        if shouldSkipFollowingTabGlobalRefresh() {
#if DEBUG
            print("[PerfPhase1] followingRefreshSkipped reason=fresh")
#endif
            return
        }
        await refreshFollowingTabDataGlobally()
    }

    func shouldSkipFollowingTabGlobalRefresh() -> Bool {
        guard let last = lastFollowingTabGlobalRefreshAt else { return false }
        return Date().timeIntervalSince(last) < Self.followingTabGlobalRefreshFreshnessInterval
    }

    /// Clears only venue-game plan rows and interest-derived Following state. Does **not** remove saved venues or pickup join cards.
    func clearFollowingTabVenueGamePlanCachesOnly() {
        followingTabGoingItems = []
        followingTabGoingInterestCounts = [:]
        followingTabUserVenueEventInterestIDs = []
        pendingFollowingMapVenueID = nil
        pendingFollowingMapVenueSnapshot = nil
    }

    /// Email-scoped Following lists (`favorite_venues`, `venue_event_interests`) without a usable session email. Does **not** clear pickup join cards (``loadMyPickupGameJoinRequestsForFollowing()`` is keyed by auth user id).
    func clearFollowingTabCachesPreservingPickupJoinState() {
        clearFollowingTabVenueGamePlanCachesOnly()
        followingTabSavedVenues = []
        favoriteVenueIDs = []
    }

    func clearFollowingTabCaches() {
        clearFollowingTabVenueGamePlanCachesOnly()
        followingTabSavedVenues = []
        myPickupGameJoinRequestCards = []
        pickupGamesFollowingTabCache.removeAll()
        pickupJoinRequestLatestByPickupGameIdForFan.removeAll()
        resetPickupFollowingActivityStateForCacheClear()
        lastFollowingTabGlobalRefreshAt = nil
    }

    func clearFollowingInterestedOnlyDefaults() {
        UserDefaults.standard.removeObject(forKey: Self.interestedOnlyVenueEventDefaultsKey)
    }

    /// Reloads Following tab data from Supabase: ordered saved venues by favorite ids, global user interests, event rows, per-event counts, and venue rows (by id or owner/name match).
    ///
    /// Saved venues and venue-game membership are handled separately: failures loading interests or aggregate counts must not clear favorite venues (see ``clearFollowingTabVenueGamePlanCachesOnly()``).
    func refreshFollowingTabDataGlobally() async {
        if let inFlight = followingTabGlobalRefreshTask {
#if DEBUG
            print("[PerfPhase1] followingRefreshCoalesced=true")
#endif
            await inFlight.value
            return
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.refreshFollowingTabDataGloballyNow()
        }
        followingTabGlobalRefreshTask = task
        await task.value
        followingTabGlobalRefreshTask = nil
    }

    private func refreshFollowingTabDataGloballyNow() async {
        guard let interestEmail = await strictNormalizedSessionEmailForSocialTables() else {
            clearFollowingTabCachesPreservingPickupJoinState()
            return
        }

        await loadFavoriteVenuesFromSupabase(forceRefresh: true)

        let localInterestedOnly = Self.decodeInterestedOnlyUUIDsFromDefaults()

        // MARK: Saved venues (favorite list) — independent of venue_event_interests
        var orderedFavoriteIds: [UUID] = []
        var savedBars: [BarVenue] = []
        var barsById: [UUID: BarVenue] = [:]
        do {
            orderedFavoriteIds = try await fetchOrderedFavoriteVenueIDs(userEmail: interestEmail)
            savedBars = try await fetchBarsForFavoriteVenueIDs(orderedFavoriteIds)
            barsById = Dictionary(uniqueKeysWithValues: savedBars.map { ($0.id, $0) })
            let orderedSaved = orderedFavoriteIds.compactMap { barsById[$0] }
            followingTabSavedVenues = orderedSaved
        } catch {
#if DEBUG
            print("ERROR refreshFollowingTabDataGlobally favorites:", error)
#endif
            // Keep prior saved venues; do not wipe hearts on downstream errors.
        }

        // MARK: Venue games the user follows (membership ≠ aggregate counts)
        do {
            let interestRows: [VenueEventInterestRow] = try await supabase
                .from("venue_event_interests")
                .select("venue_event_id")
                .eq("user_email", value: interestEmail)
                .execute()
                .value

            let serverEventIDs = Set(interestRows.compactMap(\.venue_event_id))

            let mergedServerEventIDs = await MainActor.run { () -> Set<UUID> in
                pruneVenueEventInterestLocalReconcileGuards()
                let pendingGoing = Set(venueEventInterestWriteInFlightIDs.filter {
                    venueEventInterestPendingTargets[$0] != false
                })
                let pendingNotGoing = Set(venueEventInterestWriteInFlightIDs.filter {
                    venueEventInterestPendingTargets[$0] == false
                })
                let preserveGoing = activeRecentlyConfirmedVenueEventGoingIDs()
                    .union(pendingGoing)
                let preserveNotGoing = activeRecentlyConfirmedVenueEventNotGoingIDs()
                    .union(pendingNotGoing)
                return serverEventIDs
                    .union(preserveGoing)
                    .subtracting(preserveNotGoing)
            }

            let userMemberVenueEventIDs = mergedServerEventIDs.union(localInterestedOnly)

            var eventRowsByID: [UUID: VenueEventRow] = [:]
            let membershipArray = Array(userMemberVenueEventIDs)
            var index = 0
            while index < membershipArray.count {
                let end = min(index + Self.interestChunkSize, membershipArray.count)
                let chunk = Array(membershipArray[index..<end])
                index = end
                let idStrings = chunk.map { $0.uuidString.lowercased() }

                let rows: [VenueEventRow] = try await supabase
                    .from("venue_events")
                    .select(Self.venueEventSelectColumnsFollowing)
                    .in("id", values: idStrings)
                    .eq("admin_status", value: "active")
                    .execute()
                    .value

                for row in rows {
                    guard let id = row.id else { continue }
                    eventRowsByID[id] = row
                }
            }

            let localOnlyIDs = localInterestedOnly.subtracting(serverEventIDs)
            for id in localOnlyIDs {
                if eventRowsByID[id] != nil { continue }
                if let row = try await fetchSingleVenueEventRow(id: id) {
                    eventRowsByID[id] = row
                }
            }

            let allDisplayEventIDs = Array(eventRowsByID.keys)
            var totals: [UUID: Int] = [:]
            var countIndex = 0
            while countIndex < allDisplayEventIDs.count {
                let end = min(countIndex + Self.interestChunkSize, allDisplayEventIDs.count)
                let chunk = Array(allDisplayEventIDs[countIndex..<end])
                countIndex = end
                let venueEventIdStrings = chunk.map { $0.uuidString.lowercased() }

                let countRows: [VenueEventInterestRow] = try await supabase
                    .from("venue_event_interests")
                    .select("venue_event_id")
                    .in("venue_event_id", values: venueEventIdStrings)
                    .execute()
                    .value

                for row in countRows {
                    guard let eid = row.venue_event_id else { continue }
                    totals[eid, default: 0] += 1
                }
            }

            let activeServerGoingEventIDs = mergedServerEventIDs.subtracting(localInterestedOnly)
            let localInterestedOnlyIDs = localInterestedOnly

            var goingItems: [FollowingGoingDisplayItem] = []
            goingItems.reserveCapacity(eventRowsByID.count)

            for id in allDisplayEventIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let row = eventRowsByID[id] else { continue }

                let bar = try await resolveBarForFollowingVenueEvent(
                    row: row,
                    barsById: barsById,
                    savedBars: savedBars
                )
                let userHasServerInterestRow = activeServerGoingEventIDs.contains(id)
                let attendeeCount = totals[id] ?? 0
                goingItems.append(
                    FollowingGoingDisplayItem(
                        id: id,
                        venueEvent: row,
                        bar: bar,
                        attendeeCount: attendeeCount,
                        isServerGoing: userHasServerInterestRow,
                        isInterestedOnlyLocal: localInterestedOnlyIDs.contains(id)
                    )
                )
            }

            let favoriteVenuesCount = followingTabSavedVenues.count
            let userGoingVenueEventsCount = activeServerGoingEventIDs.count
            let userInterestedVenueEventsCount = localInterestedOnly.count
            goingItems = Self.sortFollowingGoingItemsChronologically(goingItems)

            let finalFollowingItemsCount = goingItems.count

            followingTabGoingItems = goingItems
            followingTabGoingInterestCounts = totals
            followingTabUserVenueEventInterestIDs = activeServerGoingEventIDs
            await reconcileGameRemindersAfterFollowingRefresh()

#if DEBUG
            print("[FollowingRegression] favoriteVenuesCount=\(favoriteVenuesCount)")
            print("[FollowingRegression] userGoingVenueEventsCount=\(userGoingVenueEventsCount)")
            print("[FollowingRegression] userInterestedVenueEventsCount=\(userInterestedVenueEventsCount)")
            print("[FollowingRegression] finalFollowingItemsCount=\(finalFollowingItemsCount)")
#endif
        } catch {
#if DEBUG
            print("ERROR refreshFollowingTabDataGlobally venue game plans:", error)
#endif
            clearFollowingTabVenueGamePlanCachesOnly()
        }

        // Host pickup game cache for the Going hub.
        if canFanUsePickupGamesUI, let uid = currentUserAuthId {
            await loadMyPickupGamesForSettings()
            await refreshPickupCreatorPublicRatingStats(creatorUserIds: [uid])
        }

        lastFollowingTabGlobalRefreshAt = Date()
    }

    // MARK: - Private helpers

    private func fetchOrderedFavoriteVenueIDs(userEmail: String) async throws -> [UUID] {
        let rows: [FavoriteVenueRow] = try await supabase
            .from("favorite_venues")
            .select("venue_id")
            .eq("user_email", value: userEmail)
            .order("id", ascending: false)
            .execute()
            .value

        return rows.compactMap(\.venue_id)
    }

    private func fetchBarsForFavoriteVenueIDs(_ orderedIds: [UUID]) async throws -> [BarVenue] {
        guard !orderedIds.isEmpty else { return [] }

        var collected: [VenueRow] = []
        var idx = 0
        while idx < orderedIds.count {
            let end = min(idx + Self.interestChunkSize, orderedIds.count)
            let chunk = Array(orderedIds[idx..<end])
            idx = end

            let idStrings = chunk.map { $0.uuidString.lowercased() }
            let rows: [VenueRow] = try await supabase
                .from("venues")
                .select(Self.venueSelectColumnsFollowing)
                .in("id", values: idStrings)
                .eq("admin_status", value: "active")
                .execute()
                .value

            collected.append(contentsOf: rows)
        }

        let (bars, _) = DiscoverVenueLoadAssembler.buildMappedBars(venueRows: collected, fetchedVenueEventRows: [])
        return bars
    }

    private func fetchSingleVenueEventRow(id: UUID) async throws -> VenueEventRow? {
        let rows: [VenueEventRow] = try await supabase
            .from("venue_events")
            .select(Self.venueEventSelectColumnsFollowing)
            .eq("id", value: id.uuidString.lowercased())
            .eq("admin_status", value: "active")
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    private func resolveBarForFollowingVenueEvent(
        row: VenueEventRow,
        barsById: [UUID: BarVenue],
        savedBars: [BarVenue]
    ) async throws -> BarVenue {
        if let vid = row.venue_id {
            if let b = barsById[vid] {
                return b
            }
            if let b = savedBars.first(where: { $0.id == vid }) {
                return b
            }
        }

        let venueName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let owner = OwnerBusinessEmail.normalized(row.owner_email ?? "")

        if !venueName.isEmpty, !owner.isEmpty,
           let match = savedBars.first(where: {
               $0.name == venueName && OwnerBusinessEmail.normalized($0.ownerEmail ?? "") == owner
           }) {
            return match
        }

        if !venueName.isEmpty,
           let match = savedBars.first(where: { $0.name == venueName }) {
            return match
        }

        if !venueName.isEmpty {
            for bar in barsById.values {
                guard bar.name == venueName else { continue }
                if owner.isEmpty { return bar }
                if OwnerBusinessEmail.normalized(bar.ownerEmail ?? "") == owner { return bar }
            }
        }

        if let venueRow = try await fetchVenueRowForFollowing(ownerEmail: owner.isEmpty ? nil : owner, venueName: venueName) {
            let (bars, _) = DiscoverVenueLoadAssembler.buildMappedBars(venueRows: [venueRow], fetchedVenueEventRows: [])
            if let b = bars.first { return b }
        }

        return Self.placeholderBarForFollowing(event: row)
    }

    private func fetchVenueRowForFollowing(ownerEmail: String?, venueName: String) async throws -> VenueRow? {
        guard !venueName.isEmpty else { return nil }

        var q = supabase
            .from("venues")
            .select(Self.venueSelectColumnsFollowing)
            .eq("venue_name", value: venueName)
            .eq("admin_status", value: "active")

        if let ownerEmail, !ownerEmail.isEmpty {
            let o = OwnerBusinessEmail.normalized(ownerEmail)
            if OwnerBusinessEmail.isValidStrict(o) {
                q = q.eq("owner_email", value: o)
            }
        }

        let rows: [VenueRow] = try await q
            .limit(2)
            .execute()
            .value

        return rows.first
    }

    private static func placeholderBarForFollowing(event: VenueEventRow) -> BarVenue {
        let trimmedName = event.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmedName.isEmpty ? "Venue" : trimmedName
        let title = event.event_title ?? ""
        let sport = event.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return BarVenue(
            id: UUID(),
            name: name,
            address: "Address unavailable",
            phone: "",
            primarySport: sport,
            distance: "",
            rating: 0,
            tags: [],
            games: title.isEmpty ? [] : [title],
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            goingCounts: [:],
            screenCount: nil,
            servesFood: nil,
            hasWifi: nil,
            hasGarden: nil,
            hasProjector: nil,
            petFriendly: nil,
            coverPhotoURL: nil,
            menuPhotoURL: nil,
            coverPhotoThumbnailURL: nil,
            menuPhotoThumbnailURL: nil,
            ownerEmail: event.owner_email,
            businessId: nil,
            adminStatus: event.admin_status,
            venueOwnerEmailRaw: event.owner_email,
            businessOwnerEmailRaw: nil,
            contactEmailRaw: nil
        )
    }

    private static func decodeInterestedOnlyUUIDsFromDefaults() -> Set<UUID> {
        Self.followingInterestedOnlyVenueEventIDsFromUserDefaults()
    }

    /// Same backing store as ``FollowingScreen`` `@AppStorage("gameon.following.interestedOnlyVenueEventIDs")` (Interested-without-server-row).
    static func followingInterestedOnlyVenueEventIDsFromUserDefaults() -> Set<UUID> {
        let encoded = UserDefaults.standard.string(forKey: interestedOnlyVenueEventDefaultsKey) ?? ""
        let parts = encoded.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var out: Set<UUID> = []
        for p in parts {
            if let u = UUID(uuidString: p) {
                out.insert(u)
            }
        }
        return out
    }

    /// Forces a read of ``interestedPlans()`` so any UI depending on shared interest caches stays coherent after optimistic Following updates.
    @MainActor
    func refreshFollowingInterestDerivedSnapshotsForUI() {
        _ = interestedPlans()
#if DEBUG
        print("[FollowingState] derived interest plans recomputed count=\(interestedPlans().count) goingRows=\(followingTabGoingItems.count)")
#endif
    }

    static func sortFollowingGoingItemsChronologically(
        _ items: [FollowingGoingDisplayItem],
        now: Date = Date()
    ) -> [FollowingGoingDisplayItem] {
        items.sorted { lhs, rhs in
            let lhsCompleted = VenueGameExpiration.isWatchingCompleted(row: lhs.venueEvent, now: now)
            let rhsCompleted = VenueGameExpiration.isWatchingCompleted(row: rhs.venueEvent, now: now)
            if lhsCompleted != rhsCompleted { return !lhsCompleted }

            let lhsStart = VenueGameExpiration.scheduledStartDate(for: lhs.venueEvent) ?? .distantFuture
            let rhsStart = VenueGameExpiration.scheduledStartDate(for: rhs.venueEvent) ?? .distantFuture
            if lhsStart != rhsStart { return lhsStart < rhsStart }

            let lhsTitle = lhs.venueEvent.event_title ?? lhs.bar.name
            let rhsTitle = rhs.venueEvent.event_title ?? rhs.bar.name
            if lhsTitle != rhsTitle {
                return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
