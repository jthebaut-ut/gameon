import Foundation
import Supabase

extension MapViewModel {

    var canMarkInterest: Bool {
        isAuthenticatedForSocialFeatures
    }

    private func resolvedInterestMutationEmail() async -> String? {
        let session = try? await supabase.auth.session
        let fromSession = OwnerBusinessEmail.normalized(session?.user.email ?? "")
        if OwnerBusinessEmail.isValidStrict(fromSession) {
            return fromSession
        }
        let fallback = OwnerBusinessEmail.normalized(!currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail)
        return OwnerBusinessEmail.isValidStrict(fallback) ? fallback : nil
    }

    @MainActor
    private func applyLocalVenueEventInterestState(venueEventID: UUID, isInterested: Bool) {
        let wasInterested = venueEventInterestIDs.contains(venueEventID)
        guard wasInterested != isInterested else { return }

        if isInterested {
            venueEventInterestIDs.insert(venueEventID)
            venueEventInterestCounts[venueEventID, default: 0] += 1
            followingTabUserVenueEventInterestIDs.insert(venueEventID)
        } else {
            venueEventInterestIDs.remove(venueEventID)
            venueEventInterestCounts[venueEventID] = max((venueEventInterestCounts[venueEventID] ?? 1) - 1, 0)
            followingTabUserVenueEventInterestIDs.remove(venueEventID)
        }

        if followingTabGoingInterestCounts[venueEventID] != nil || followingTabGoingItems.contains(where: { $0.id == venueEventID }) {
            followingTabGoingInterestCounts[venueEventID] = venueEventInterestCounts[venueEventID] ?? 0
        }

        if let index = followingTabGoingItems.firstIndex(where: { $0.id == venueEventID }) {
            let item = followingTabGoingItems[index]
            followingTabGoingItems[index] = FollowingGoingDisplayItem(
                id: item.id,
                venueEvent: item.venueEvent,
                bar: item.bar,
                attendeeCount: venueEventInterestCounts[venueEventID] ?? item.attendeeCount,
                isServerGoing: isInterested
            )
        }
    }

    @discardableResult
    func setVenueEventInterest(
        venueEventID: UUID,
        isInterested: Bool,
        refreshFollowing: Bool = true
    ) async -> Bool {
        guard !venueEventInterestWriteInFlightIDs.contains(venueEventID) else { return true }
        guard let interestEmail = await resolvedInterestMutationEmail() else {
            print("USER MUST BE LOGGED IN TO MARK INTEREST")
            return false
        }

        let previousInterestIDs = venueEventInterestIDs
        let previousInterestCounts = venueEventInterestCounts
        let previousFollowingInterestIDs = followingTabUserVenueEventInterestIDs
        let previousFollowingInterestCounts = followingTabGoingInterestCounts
        let previousFollowingItems = followingTabGoingItems

        await MainActor.run {
            venueEventInterestWriteInFlightIDs.insert(venueEventID)
            applyLocalVenueEventInterestState(venueEventID: venueEventID, isInterested: isInterested)
        }

        do {
            if isInterested {
                let interest = VenueEventInterestInsert(
                    venue_event_id: venueEventID,
                    user_email: interestEmail
                )
                try await supabase
                    .from("venue_event_interests")
                    .upsert(
                        interest,
                        onConflict: "user_email,venue_event_id"
                    )
                    .execute()
            } else {
                try await supabase
                    .from("venue_event_interests")
                    .delete()
                    .eq("venue_event_id", value: venueEventID)
                    .eq("user_email", value: interestEmail)
                    .execute()
            }

            await MainActor.run {
                venueEventInterestWriteInFlightIDs.remove(venueEventID)
            }

            if refreshFollowing {
                Task { @MainActor [weak self] in
                    await self?.loadGoingUserProfiles(for: venueEventID)
                }
            }

            return true
        } catch {
            let message = error.localizedDescription.lowercased()
            if isInterested, message.contains("duplicate key") || message.contains("23505") {
                await MainActor.run {
                    venueEventInterestWriteInFlightIDs.remove(venueEventID)
                    applyLocalVenueEventInterestState(venueEventID: venueEventID, isInterested: true)
                }
                return true
            }

            await MainActor.run {
                venueEventInterestIDs = previousInterestIDs
                venueEventInterestCounts = previousInterestCounts
                followingTabUserVenueEventInterestIDs = previousFollowingInterestIDs
                followingTabGoingInterestCounts = previousFollowingInterestCounts
                followingTabGoingItems = previousFollowingItems
                venueEventInterestWriteInFlightIDs.remove(venueEventID)
            }
            print("ERROR SETTING INTEREST:", error)
            return false
        }
    }

    @discardableResult
    func markInterestedInVenueEvent(venueEventID: UUID, refreshFollowing: Bool = true) async -> Bool {
        await setVenueEventInterest(
            venueEventID: venueEventID,
            isInterested: true,
            refreshFollowing: refreshFollowing
        )
    }

    @discardableResult
    func removeInterestInVenueEvent(venueEventID: UUID, refreshFollowing: Bool = true) async -> Bool {
        await setVenueEventInterest(
            venueEventID: venueEventID,
            isInterested: false,
            refreshFollowing: refreshFollowing
        )
    }

    func goingProfiles(for venueEventID: UUID) -> [UserProfileRow] {
        goingProfilesByVenueEventID[venueEventID] ?? []
    }

    func venueEventLookupKey(for bar: BarVenue, gameTitle: String) -> String {
        "\(bar.name)-\(gameTitle)"
    }

    /// Prefer ``venues.id`` + title; fall back to legacy name + title for rows with null ``venue_events.venue_id``.
    func venueEventLookupKeyPrimary(for bar: BarVenue, gameTitle: String) -> String {
        "\(bar.id.uuidString)-\(gameTitle)"
    }

    func cachedVenueEventID(for bar: BarVenue, gameTitle: String) -> UUID? {
        let primary = venueEventLookupKeyPrimary(for: bar, gameTitle: gameTitle)
        if let id = venueEventIDsByKey[primary] {
            return id
        }
        return venueEventIDsByKey[venueEventLookupKey(for: bar, gameTitle: gameTitle)]
    }

    func interestedPlans() -> [(bar: BarVenue, gameTitle: String, date: String, time: String, count: Int)] {
        var plans: [(bar: BarVenue, gameTitle: String, date: String, time: String, count: Int)] = []

        for row in venueEventRows {
            guard
                let id = row.id,
                venueEventInterestIDs.contains(id),
                let title = row.event_title
            else {
                continue
            }

            guard let bar = bars.first(where: { bar in
                if let vid = row.venue_id, vid == bar.id {
                    return true
                }
                if let venueName = row.venue_name,
                   bar.name == venueName {
                    return true
                }

                if let title = row.event_title,
                   bar.games.contains(title) {
                    return true
                }

                return false
            }) else {
                continue
            }

            plans.append((
                bar: bar,
                gameTitle: title,
                date: row.event_date ?? "Date TBD",
                time: row.event_time ?? "Time TBD",
                count: venueEventInterestCounts[id] ?? 0
            ))
        }

        return plans
    }

    func loadGoingUserProfiles(for venueEventID: UUID) async {
        do {
            let interestRows: [VenueEventInterestRow] = try await supabase
                .from("venue_event_interests")
                .select()
                .eq("venue_event_id", value: venueEventID)
                .execute()
                .value

            let emails = interestRows.compactMap { $0.user_email }

            guard !emails.isEmpty else {
                await MainActor.run {
                    goingUserProfiles = []
                    goingProfilesByVenueEventID[venueEventID] = []
                }
                return
            }

            let profileRows = try await SocialIdentityService().fetchUserProfileRows(forEmails: emails)

            await MainActor.run {
                goingUserProfiles = profileRows
                goingProfilesByVenueEventID[venueEventID] = profileRows
            }

        } catch {
            if error is CancellationError {
#if DEBUG
                print("[LoadCancelled] going profiles")
#endif
            } else {
                print("ERROR LOADING GOING USER PROFILES:", error)
            }
        }
    }

    func removeInterested(in bar: BarVenue, gameTitle: String) {
        let key = venueEventInterestKey(for: bar, gameTitle: gameTitle)
        interestedVenueEventKeys.remove(key)
    }

    func interestKey(for bar: BarVenue) -> String? {
        guard let selectedEvent else { return nil }
        return "\(bar.id.uuidString)-\(selectedEvent.title)"
    }

    func isInterested(in bar: BarVenue) -> Bool {
        guard let key = interestKey(for: bar) else { return false }
        return interestedVenueEventKeys.contains(key)
    }

    func toggleInterest(in bar: BarVenue) {
        guard let key = interestKey(for: bar) else { return }

        if interestedVenueEventKeys.contains(key) {
            interestedVenueEventKeys.remove(key)
        } else {
            interestedVenueEventKeys.insert(key)
        }
    }

    func venueEventInterestKey(for bar: BarVenue, gameTitle: String) -> String {
        "\(bar.id.uuidString)-\(gameTitle)"
    }

    func isInterested(in bar: BarVenue, gameTitle: String) -> Bool {
        let key = venueEventInterestKey(for: bar, gameTitle: gameTitle)
        return interestedVenueEventKeys.contains(key)
    }

    func markInterested(in bar: BarVenue, gameTitle: String) {
        let key = venueEventInterestKey(for: bar, gameTitle: gameTitle)
        interestedVenueEventKeys.insert(key)
    }

    func displayedGoingCount(for bar: BarVenue, gameTitle: String) -> Int {
        let baseCount = bar.goingCounts[gameTitle] ?? 0
        return isInterested(in: bar, gameTitle: gameTitle) ? baseCount + 1 : baseCount
    }

    func venueEventInterestKey(for bar: BarVenue) -> String? {
        guard let selectedEvent else { return nil }
        return "\(bar.id.uuidString)-\(selectedEvent.title)"
    }

    func isInterestedInSelectedEvent(at bar: BarVenue) -> Bool {
        guard let key = venueEventInterestKey(for: bar) else { return false }
        return interestedVenueEventKeys.contains(key)
    }

    func toggleInterestForSelectedEvent(at bar: BarVenue) {
        guard let key = venueEventInterestKey(for: bar) else { return }

        if interestedVenueEventKeys.contains(key) {
            interestedVenueEventKeys.remove(key)
        } else {
            interestedVenueEventKeys.insert(key)
        }
    }

    func displayedGoingCount(for bar: BarVenue) -> Int {
        let baseCount = goingCount(for: bar)
        return isInterestedInSelectedEvent(at: bar) ? baseCount + 1 : baseCount
    }

    func isInterestedInVenueEvent(_ venueEventID: UUID) -> Bool {
        venueEventInterestIDs.contains(venueEventID)
    }

    func interestCountForVenueEvent(_ venueEventID: UUID) -> Int {
        venueEventInterestCounts[venueEventID] ?? 0
    }

    func venueEventID(for bar: BarVenue, gameTitle: String) async -> UUID? {
        let keyPrimary = venueEventLookupKeyPrimary(for: bar, gameTitle: gameTitle)
        let keyLegacy = venueEventLookupKey(for: bar, gameTitle: gameTitle)
        if let cached = venueEventIDsByKey[keyPrimary] ?? venueEventIDsByKey[keyLegacy] {
            return cached
        }

        if let row = venueEventRows.first(where: { row in
            guard row.event_title == gameTitle else { return false }
            if let vid = row.venue_id, vid == bar.id { return true }
            if row.venue_name == bar.name { return true }
            if let o = row.owner_email, let bo = bar.ownerEmail,
               OwnerBusinessEmail.normalized(o) == OwnerBusinessEmail.normalized(bo) { return true }
            return false
        }), let id = row.id {
            venueEventIDsByKey[keyPrimary] = id
            venueEventIDsByKey[keyLegacy] = id
            return id
        }

        do {
            var q = supabase
                .from("venue_events")
                .select("id,venue_id,owner_email,venue_name,event_title")
                .eq("event_title", value: gameTitle)
                .eq("admin_status", value: "active")
                .eq("venue_id", value: bar.id)

            let rowsByVenueId: [VenueEventRow] = try await q
                .limit(1)
                .execute()
                .value

            if let id = rowsByVenueId.first?.id {
                venueEventIDsByKey[keyPrimary] = id
                venueEventIDsByKey[keyLegacy] = id
                return id
            }

            var qLegacy = supabase
                .from("venue_events")
                .select("id,venue_id,owner_email,venue_name,event_title")
                .eq("event_title", value: gameTitle)
                .eq("admin_status", value: "active")
                .is("venue_id", value: nil)

            let ownerNorm = OwnerBusinessEmail.normalized(bar.ownerEmail ?? "")
            if OwnerBusinessEmail.isValidStrict(ownerNorm) {
                qLegacy = qLegacy.eq("owner_email", value: ownerNorm)
            } else {
                qLegacy = qLegacy.eq("venue_name", value: bar.name)
            }

            let rows: [VenueEventRow] = try await qLegacy
                .limit(1)
                .execute()
                .value

            #if DEBUG
            print("[DiscoverPerf] venueEventID network lookup title=\(gameTitle) rows=\(rows.count)")
            #endif

            if let id = rows.first?.id {
                venueEventIDsByKey[keyPrimary] = id
                venueEventIDsByKey[keyLegacy] = id
                return id
            }

            return nil

        } catch {
            #if DEBUG
            print("ERROR FINDING VENUE EVENT ID:", error)
            #endif
            return nil
        }
    }

    func loadVisibleVenueEventInterests() async {
        let visibleEventIDs = venueEventRows.compactMap { $0.id }

        guard !visibleEventIDs.isEmpty else {
            return
        }

        let t0 = Date()
        let interestEmail = OwnerBusinessEmail.normalized(!currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail)
        let selectCols = "venue_event_id,user_email"
        let chunkSize = 90

        do {
            var counts: [UUID: Int] = [:]
            var myInterests: Set<UUID> = []
            var totalRows = 0

            var index = 0
            while index < visibleEventIDs.count {
                let end = min(index + chunkSize, visibleEventIDs.count)
                let chunk = Array(visibleEventIDs[index..<end])
                index = end

                let rows: [VenueEventInterestRow] = try await supabase
                    .from("venue_event_interests")
                    .select(selectCols)
                    .in("venue_event_id", values: chunk)
                    .execute()
                    .value

                totalRows += rows.count
                for row in rows {
                    guard let eventID = row.venue_event_id else { continue }
                    counts[eventID, default: 0] += 1
                    if OwnerBusinessEmail.normalized(row.user_email ?? "") == interestEmail {
                        myInterests.insert(eventID)
                    }
                }
            }

            await MainActor.run {
                venueEventInterestCounts = counts
                venueEventInterestIDs = myInterests
            }

            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[DiscoverPerf] visible interests loaded events=\(visibleEventIDs.count) rows=\(totalRows) ms=\(ms)")
            #endif

        } catch {
            #if DEBUG
            print("ERROR LOADING VISIBLE VENUE EVENT INTERESTS:", error)
            #endif
        }
    }

    /// Going counts / “I’m in” state for visible venue events, plus low-priority map image prefetch. Runs after Discover core data is current.
    func refreshSocialEnrichmentInBackground() async {
        let t0 = Date()
        await loadVisibleVenueEventInterests()
        let urls = Array(bars.compactMap { bar -> URL? in
            guard let s = bar.coverPhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return URL(string: s)
        }.prefix(14))
        await DiscoverMapImageCache.shared.prefetch(urls: urls)
        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[Phase3Perf] social enrichment load ms=\(ms)")
        #endif
    }
}
