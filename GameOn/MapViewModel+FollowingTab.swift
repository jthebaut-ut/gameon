import CoreLocation
import Foundation
import Supabase

// MARK: - Following tab (global favorites + going; not scoped to Discover map region)

extension MapViewModel {

    /// UserDefaults key must match ``FollowingScreen`` `@AppStorage("gameon.following.interestedOnlyVenueEventIDs")`.
    private static let interestedOnlyVenueEventDefaultsKey = "gameon.following.interestedOnlyVenueEventIDs"

    private static let venueSelectColumnsFollowing =
        "id,owner_email,business_id,venue_name,address,city,state,zip_code,phone,website,description,features,screen_count,serves_food,has_wifi,has_garden,has_projector,pet_friendly,latitude,longitude,cover_photo_url,menu_photo_url,cover_photo_thumbnail_url,menu_photo_thumbnail_url"

    private static let venueEventSelectColumnsFollowing =
        "id,venue_id,owner_email,venue_name,event_title,sport,event_date,event_time"

    private static let interestChunkSize = 90

    func clearFollowingTabCaches() {
        followingTabSavedVenues = []
        followingTabGoingItems = []
        followingTabGoingInterestCounts = [:]
        followingTabUserVenueEventInterestIDs = []
        myPickupGameJoinRequestCards = []
        pickupGamesFollowingTabCache.removeAll()
        pendingFollowingMapVenueID = nil
        pendingFollowingMapVenueSnapshot = nil
    }

    func clearFollowingInterestedOnlyDefaults() {
        UserDefaults.standard.removeObject(forKey: Self.interestedOnlyVenueEventDefaultsKey)
    }

    /// Reloads Following tab data from Supabase: ordered saved venues by favorite ids, global user interests, event rows, per-event counts, and venue rows (by id or owner/name match).
    func refreshFollowingTabDataGlobally() async {
        guard let interestEmail = await strictNormalizedSessionEmailForSocialTables() else {
            clearFollowingTabCaches()
            return
        }

        await loadFavoriteVenuesFromSupabase()

        let localInterestedOnly = Self.decodeInterestedOnlyUUIDsFromDefaults()

        do {
            let orderedFavoriteIds = try await fetchOrderedFavoriteVenueIDs(userEmail: interestEmail)
            let savedBars = try await fetchBarsForFavoriteVenueIDs(orderedFavoriteIds)
            let barsById = Dictionary(uniqueKeysWithValues: savedBars.map { ($0.id, $0) })

            let interestRows: [VenueEventInterestRow] = try await supabase
                .from("venue_event_interests")
                .select("venue_event_id")
                .eq("user_email", value: interestEmail)
                .execute()
                .value

            let serverEventIDs = Set(interestRows.compactMap(\.venue_event_id))

            var eventRowsByID: [UUID: VenueEventRow] = [:]
            let serverIDsArray = Array(serverEventIDs)
            var index = 0
            while index < serverIDsArray.count {
                let end = min(index + Self.interestChunkSize, serverIDsArray.count)
                let chunk = Array(serverIDsArray[index..<end])
                index = end

                let rows: [VenueEventRow] = try await supabase
                    .from("venue_events")
                    .select(Self.venueEventSelectColumnsFollowing)
                    .in("id", values: chunk)
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
            var counts: [UUID: Int] = [:]
            var countIndex = 0
            while countIndex < allDisplayEventIDs.count {
                let end = min(countIndex + Self.interestChunkSize, allDisplayEventIDs.count)
                let chunk = Array(allDisplayEventIDs[countIndex..<end])
                countIndex = end

                let countRows: [VenueEventInterestRow] = try await supabase
                    .from("venue_event_interests")
                    .select("venue_event_id")
                    .in("venue_event_id", values: chunk)
                    .execute()
                    .value

                for row in countRows {
                    guard let eid = row.venue_event_id else { continue }
                    counts[eid, default: 0] += 1
                }
            }

            var goingItems: [FollowingGoingDisplayItem] = []
            goingItems.reserveCapacity(eventRowsByID.count)

            for id in allDisplayEventIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let row = eventRowsByID[id] else { continue }
                let bar = try await resolveBarForFollowingVenueEvent(
                    row: row,
                    barsById: barsById,
                    savedBars: savedBars
                )
                let isServer = serverEventIDs.contains(id)
                goingItems.append(
                    FollowingGoingDisplayItem(
                        id: id,
                        venueEvent: row,
                        bar: bar,
                        attendeeCount: counts[id] ?? 0,
                        isServerGoing: isServer
                    )
                )
            }

            let orderedSaved = orderedFavoriteIds.compactMap { barsById[$0] }

            await MainActor.run {
                followingTabSavedVenues = orderedSaved
                followingTabGoingItems = goingItems
                followingTabGoingInterestCounts = counts
                followingTabUserVenueEventInterestIDs = serverEventIDs
            }

        } catch {
#if DEBUG
            print("ERROR refreshFollowingTabDataGlobally:", error)
#endif
            await MainActor.run {
                clearFollowingTabCaches()
            }
        }
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

            let rows: [VenueRow] = try await supabase
                .from("venues")
                .select(Self.venueSelectColumnsFollowing)
                .in("id", values: chunk)
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
            .eq("id", value: id)
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
            screenCount: 1,
            servesFood: false,
            hasWifi: false,
            hasGarden: false,
            hasProjector: false,
            petFriendly: false,
            coverPhotoURL: nil,
            menuPhotoURL: nil,
            coverPhotoThumbnailURL: nil,
            menuPhotoThumbnailURL: nil,
            ownerEmail: event.owner_email,
            businessId: nil
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
}
