import Foundation
import Supabase

private enum FanUpdatesGoingProfilesPrefetchTTL {
    static let profiles: TimeInterval = 45
}

extension MapViewModel {

    /// Same normalized **Supabase Auth session** email as ``strictNormalizedSessionEmailForSocialTables`` (writes + Following reloads). Do not substitute profile/owner UI emails.
    private func resolvedInterestMutationEmail() async -> String? {
        await strictNormalizedSessionEmailForSocialTables()
    }

    @MainActor
    private func barAndTitleForDiscoverInterestKey(venueEventID: UUID) -> (BarVenue, String)? {
        if let item = followingTabGoingItems.first(where: { $0.id == venueEventID }),
           let title = item.venueEvent.event_title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return (item.bar, title)
        }
        guard let row = venueEventRows.first(where: { $0.id == venueEventID }),
              let title = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        if let vid = row.venue_id, let b = bars.first(where: { $0.id == vid }) {
            return (b, title)
        }
        let vname = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !vname.isEmpty, let b = bars.first(where: { $0.name == vname }) {
            return (b, title)
        }
        return nil
    }

    /// Keeps ``followingTabGoingItems`` / Discover ``interestedVenueEventKeys`` aligned after a local interest mutation (including Interested-only rows from UserDefaults).
    @MainActor
    private func reconcileFollowingGoingDisplayAfterInterestMutation(venueEventID: UUID) {
        let snapshot = barAndTitleForDiscoverInterestKey(venueEventID: venueEventID)
        let localOnly = MapViewModel.followingInterestedOnlyVenueEventIDsFromUserDefaults()
        let hasServer = venueEventInterestIDs.contains(venueEventID)
            || followingTabUserVenueEventInterestIDs.contains(venueEventID)
        let keep = hasServer || localOnly.contains(venueEventID)

        if let (bar, title) = snapshot {
            let key = venueEventInterestKey(for: bar, gameTitle: title)
            if keep {
                interestedVenueEventKeys.insert(key)
            } else {
                interestedVenueEventKeys.remove(key)
            }
        }

        if followingTabGoingInterestCounts[venueEventID] != nil || followingTabGoingItems.contains(where: { $0.id == venueEventID }) {
            followingTabGoingInterestCounts[venueEventID] = venueEventInterestCounts[venueEventID] ?? 0
        }

        if !keep {
            followingTabGoingItems.removeAll { $0.id == venueEventID }
            goingProfilesByVenueEventID.removeValue(forKey: venueEventID)
#if DEBUG
            print("[FollowingState] removed not-going event from list id=\(venueEventID.uuidString)")
#endif
            return
        }
    }

    @MainActor
    private func applyLocalVenueEventInterestState(venueEventID: UUID, isInterested: Bool) {
        let inDiscover = venueEventInterestIDs.contains(venueEventID)
        let inFollowingTab = followingTabUserVenueEventInterestIDs.contains(venueEventID)
        let wasInterested = inDiscover || inFollowingTab

        if isInterested {
            if !wasInterested {
                venueEventInterestIDs.insert(venueEventID)
                venueEventInterestCounts[venueEventID, default: 0] += 1
                followingTabUserVenueEventInterestIDs.insert(venueEventID)
            }
        } else {
            guard wasInterested else { return }
            venueEventInterestIDs.remove(venueEventID)
            venueEventInterestCounts[venueEventID] = max((venueEventInterestCounts[venueEventID] ?? 0) - 1, 0)
            followingTabUserVenueEventInterestIDs.remove(venueEventID)
        }

        reconcileFollowingGoingDisplayAfterInterestMutation(venueEventID: venueEventID)
    }

    @discardableResult
    func setVenueEventInterest(
        venueEventID: UUID,
        isInterested: Bool,
        refreshFollowing: Bool = true
    ) async -> Bool {
        guard !venueEventInterestWriteInFlightIDs.contains(venueEventID) else { return true }
        guard canMarkGoing else {
            logBusinessUserGateBlocked(action: "markGoing")
            print("USER MUST BE LOGGED IN TO MARK INTEREST")
            return false
        }

        guard let interestEmail = await resolvedInterestMutationEmail() else {
            print("USER MUST BE LOGGED IN TO MARK INTEREST")
            return false
        }

        let previousInterestIDs = venueEventInterestIDs
        let previousInterestCounts = venueEventInterestCounts
        let previousFollowingInterestIDs = followingTabUserVenueEventInterestIDs
        let previousFollowingInterestCounts = followingTabGoingInterestCounts
        let previousFollowingItems = followingTabGoingItems
        let wasAlreadyInterested = venueEventInterestIDs.contains(venueEventID)
            || followingTabUserVenueEventInterestIDs.contains(venueEventID)

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
                    .eq("venue_event_id", value: venueEventID.uuidString.lowercased())
                    .eq("user_email", value: interestEmail)
                    .execute()
            }

            _ = await MainActor.run {
                venueEventInterestWriteInFlightIDs.remove(venueEventID)
            }

            if refreshFollowing {
#if DEBUG
                if hasAuthenticatedVenueOwnerSession {
                    print("[FollowingState] business attendance change event=\(venueEventID.uuidString)")
                }
#endif
                await refreshFollowingTabDataGlobally()
                await loadGoingUserProfiles(for: venueEventID)
                refreshFollowingInterestDerivedSnapshotsForUI()
#if DEBUG
                if hasAuthenticatedVenueOwnerSession {
                    print("[FollowingState] following recomputed after discover attendance")
                }
#endif
            }

            if isInterested {
                await loadVisibleVenueEventInterests()
            }

            if isInterested, !wasAlreadyInterested, let uid = await MainActor.run(body: { currentUserAuthId }) {
                await awardFanXP(
                    userId: uid,
                    amount: 5,
                    source: FanXPSource.venueEventInterest,
                    sourceId: venueEventID
                )
            }

            if isInterested {
                await scheduleGameReminderIfPossible(venueEventID: venueEventID)
            } else {
                await cancelGameReminder(venueEventID: venueEventID)
            }

            return true
        } catch {
            let message = error.localizedDescription.lowercased()
            if isInterested, message.contains("duplicate key") || message.contains("23505") {
                await MainActor.run {
                    venueEventInterestWriteInFlightIDs.remove(venueEventID)
                    applyLocalVenueEventInterestState(venueEventID: venueEventID, isInterested: true)
                }
                await loadVisibleVenueEventInterests()
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
#if DEBUG
            if hasAuthenticatedVenueOwnerSession {
                print("[FollowingState] business attendance save failed")
            }
#endif
            print("ERROR SETTING INTEREST:", error)
            return false
        }
    }

    @discardableResult
    func markInterestedInVenueEvent(
        venueEventID: UUID,
        refreshFollowing: Bool = true
    ) async -> Bool {
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
        guard canUseFanSocialFeatures else { return [] }
        return (goingProfilesByVenueEventID[venueEventID] ?? [])
            .filter { $0.isFanVisibleForLivePresence(to: currentUserAuthId) }
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
        guard canUseFanSocialFeatures else {
            await MainActor.run {
                goingUserProfiles = []
                goingProfilesByVenueEventID[venueEventID] = []
                fanUpdatesGoingProfilePrefetchedAt[venueEventID] = Date()
            }
            return
        }

        do {
            let interestRows: [VenueEventInterestRow] = try await supabase
                .from("venue_event_interests")
                .select("user_email")
                .eq("venue_event_id", value: venueEventID.uuidString.lowercased())
                .execute()
                .value

            let emails = interestRows.compactMap(\.user_email)

            guard !emails.isEmpty else {
                await MainActor.run {
                    goingUserProfiles = []
                    goingProfilesByVenueEventID[venueEventID] = []
                    fanUpdatesGoingProfilePrefetchedAt[venueEventID] = Date()
                }
                return
            }

            let profileRows = try await SocialIdentityService().fetchUserProfileRows(forEmails: emails)

            let fanPresenceRows = profileRows.filter {
                $0.isFanVisibleForLivePresence(to: currentUserAuthId)
            }

            await MainActor.run {
                goingUserProfiles = fanPresenceRows
                goingProfilesByVenueEventID[venueEventID] = profileRows
                fanUpdatesGoingProfilePrefetchedAt[venueEventID] = Date()
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

    @MainActor
    func prefetchGoingProfilesForFanUpdatesCardIfNeeded(venueEventID: UUID) {
        if let task = fanUpdatesGoingProfilePrefetchTasks[venueEventID] {
            Task { await task.value }
            return
        }
        if fanUpdatesGoingProfilesPrefetchIsFresh(fanUpdatesGoingProfilePrefetchedAt[venueEventID]),
           goingProfilesByVenueEventID[venueEventID] != nil {
            return
        }

        fanUpdatesGoingProfilePrefetchTasks[venueEventID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.fanUpdatesGoingProfilePrefetchTasks[venueEventID] = nil }
            await self.loadGoingUserProfiles(for: venueEventID)
        }
    }

    @MainActor
    private func fanUpdatesGoingProfilesPrefetchIsFresh(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) < FanUpdatesGoingProfilesPrefetchTTL.profiles
    }

    func removeInterested(in bar: BarVenue, gameTitle: String) {
        guard canMarkGoing else {
            logBusinessUserGateBlocked(action: "markGoing")
            return
        }
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
        guard canMarkGoing else {
            logBusinessUserGateBlocked(action: "markGoing")
            return
        }
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
        guard canMarkGoing else {
            logBusinessUserGateBlocked(action: "markGoing")
            return
        }
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
        guard canMarkGoing else {
            logBusinessUserGateBlocked(action: "markGoing")
            return
        }
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
            let q = supabase
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
        /// Must match ``strictNormalizedSessionEmailForSocialTables`` / inserts to `venue_event_interests` (not `currentUserEmail`, which may diverge after profile load).
        let sessionInterestEmail = await strictNormalizedSessionEmailForSocialTables()
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
                let chunkIds = chunk.map { $0.uuidString.lowercased() }

                let rows: [VenueEventInterestRow] = try await supabase
                    .from("venue_event_interests")
                    .select(selectCols)
                    .in("venue_event_id", values: chunkIds)
                    .execute()
                    .value

                totalRows += rows.count
                for row in rows {
                    guard let eventID = row.venue_event_id else { continue }
                    counts[eventID, default: 0] += 1
                    if let sessionInterestEmail,
                       OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(sessionInterestEmail)),
                       OwnerBusinessEmail.normalized(row.user_email ?? "") == OwnerBusinessEmail.normalized(sessionInterestEmail) {
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
