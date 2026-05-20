import CoreLocation
import Foundation
import Supabase

private enum FanUpdatesGoingProfilesPrefetchTTL {
    static let profiles: TimeInterval = 45
}

extension MapViewModel {

    private func normalizedVenueGameTitle(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func venueEventTitlesMatch(_ storedTitle: String?, _ gameTitle: String) -> Bool {
        let lhs = normalizedVenueGameTitle(storedTitle)
        let rhs = normalizedVenueGameTitle(gameTitle)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func venueEventRow(_ row: VenueEventRow, matches bar: BarVenue) -> Bool {
        if let vid = row.venue_id, vid == bar.id { return true }
        let barName = bar.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let venueName = normalizedVenueGameTitle(row.venue_name)
        if !venueName.isEmpty,
           venueName.caseInsensitiveCompare(barName) == .orderedSame {
            return true
        }
        if let o = row.owner_email, let bo = bar.ownerEmail,
           OwnerBusinessEmail.normalized(o) == OwnerBusinessEmail.normalized(bo) {
            return true
        }
        return false
    }

    private func cacheDiscoveredVenueEventID(
        _ id: UUID,
        bar: BarVenue,
        gameTitle: String,
        rowTitle: String?
    ) {
        let trimmed = normalizedVenueGameTitle(gameTitle)
        guard !trimmed.isEmpty else { return }
        venueEventIDsByKey[venueEventLookupKeyPrimary(for: bar, gameTitle: trimmed)] = id
        venueEventIDsByKey[venueEventLookupKey(for: bar, gameTitle: trimmed)] = id
        let canonical = normalizedVenueGameTitle(rowTitle)
        if !canonical.isEmpty, canonical != trimmed {
            venueEventIDsByKey[venueEventLookupKeyPrimary(for: bar, gameTitle: canonical)] = id
            venueEventIDsByKey[venueEventLookupKey(for: bar, gameTitle: canonical)] = id
        }
    }

    /// Discover venue-game cards: local optimistic key and/or server-backed interest rows.
    @MainActor
    func userIsGoingToVenueGame(bar: BarVenue, gameTitle: String, venueEventID: UUID?) -> Bool {
        let trimmed = normalizedVenueGameTitle(gameTitle)
        if isInterested(in: bar, gameTitle: trimmed) { return true }
        guard let venueEventID else { return false }
        if isRecentlyConfirmedVenueEventNotGoing(venueEventID) { return false }
        if isInterestedInVenueEvent(venueEventID) { return true }
        if venueEventInterestWriteInFlightIDs.contains(venueEventID) { return true }
        if isRecentlyConfirmedVenueEventGoing(venueEventID) { return true }
        return false
    }

    func normalizedVenueEventWireId(_ venueEventID: UUID) -> String {
        venueEventID.uuidString.lowercased()
    }

    func isVenueEventInterestMutationInFlight(_ venueEventID: UUID) -> Bool {
        venueEventInterestWriteInFlightIDs.contains(venueEventID)
    }

    @MainActor
    func pruneVenueEventInterestLocalReconcileGuards(now: Date = Date()) {
        let ttl = venueEventInterestLocalReconcileTTL
        recentlyConfirmedVenueEventGoingAt = recentlyConfirmedVenueEventGoingAt.filter {
            now.timeIntervalSince($0.value) < ttl
        }
        recentlyConfirmedVenueEventNotGoingAt = recentlyConfirmedVenueEventNotGoingAt.filter {
            now.timeIntervalSince($0.value) < ttl
        }
    }

    @MainActor
    func recordRecentlyConfirmedVenueEventInterest(venueEventID: UUID, isGoing: Bool, now: Date = Date()) {
        pruneVenueEventInterestLocalReconcileGuards(now: now)
        if isGoing {
            recentlyConfirmedVenueEventGoingAt[venueEventID] = now
            recentlyConfirmedVenueEventNotGoingAt.removeValue(forKey: venueEventID)
        } else {
            recentlyConfirmedVenueEventNotGoingAt[venueEventID] = now
            recentlyConfirmedVenueEventGoingAt.removeValue(forKey: venueEventID)
        }
    }

    @MainActor
    func activeRecentlyConfirmedVenueEventGoingIDs(now: Date = Date()) -> Set<UUID> {
        pruneVenueEventInterestLocalReconcileGuards(now: now)
        return Set(recentlyConfirmedVenueEventGoingAt.keys)
    }

    @MainActor
    func activeRecentlyConfirmedVenueEventNotGoingIDs(now: Date = Date()) -> Set<UUID> {
        pruneVenueEventInterestLocalReconcileGuards(now: now)
        return Set(recentlyConfirmedVenueEventNotGoingAt.keys)
    }

    @MainActor
    func isRecentlyConfirmedVenueEventGoing(_ venueEventID: UUID, now: Date = Date()) -> Bool {
        pruneVenueEventInterestLocalReconcileGuards(now: now)
        return recentlyConfirmedVenueEventGoingAt[venueEventID] != nil
    }

    @MainActor
    func isRecentlyConfirmedVenueEventNotGoing(_ venueEventID: UUID, now: Date = Date()) -> Bool {
        pruneVenueEventInterestLocalReconcileGuards(now: now)
        return recentlyConfirmedVenueEventNotGoingAt[venueEventID] != nil
    }

    /// Immediate optimistic Going toggle from Discover venue cards; Supabase runs after first paint.
    @MainActor
    func toggleVenueGameGoingFromUI(
        bar: BarVenue,
        gameTitle: String,
        eventDate: Date,
        knownVenueEventID: UUID?,
        source: String,
        onRequiresLogin: () -> Void,
        onBusinessBlocked: () -> Void
    ) {
        let trimmed = normalizedVenueGameTitle(gameTitle)
        let eventIdRaw = knownVenueEventID.map { normalizedVenueEventWireId($0) } ?? "nil"
        print(
            "[GoingButtonDebug] tap source=\(source) eventIdRaw=\(eventIdRaw) venueId=\(bar.id.uuidString.lowercased()) title=\(trimmed)"
        )

        guard isAuthenticatedForSocialFeatures else {
            print("[GoingButtonDebug] blocked reason=noAuthUser")
            onRequiresLogin()
            return
        }
        guard currentUserAuthId != nil else {
            print("[GoingButtonDebug] blocked reason=noAuthUser")
            onRequiresLogin()
            return
        }
        guard canMarkGoing else {
            print("[GoingButtonDebug] blocked reason=businessUser")
            onBusinessBlocked()
            return
        }

        let resolvedCacheID = knownVenueEventID ?? cachedVenueEventID(for: bar, gameTitle: trimmed)
        if let resolvedCacheID,
           let row = venueEventRows.first(where: { $0.id == resolvedCacheID }),
           !VenueGameExpiration.isActiveOnDiscoverSurfaces(row: row) {
            print("[GoingButtonDebug] blocked reason=expiredEvent eventId=\(normalizedVenueEventWireId(resolvedCacheID))")
            showSocialActionToast("This game has ended.")
            return
        }

        if let resolvedCacheID, venueEventInterestWriteInFlightIDs.contains(resolvedCacheID) {
            print("[GoingButtonDebug] blocked reason=pending eventId=\(normalizedVenueEventWireId(resolvedCacheID))")
            return
        }

        let wasGoing: Bool
        if let resolvedCacheID {
            wasGoing = userIsGoingToVenueGame(bar: bar, gameTitle: trimmed, venueEventID: resolvedCacheID)
        } else {
            wasGoing = isInterested(in: bar, gameTitle: trimmed)
        }
        let targetGoing = !wasGoing

        let rollbackSnapshot = VenueGameGoingRollbackSnapshot(
            interestIDs: venueEventInterestIDs,
            interestCounts: venueEventInterestCounts,
            followingInterestIDs: followingTabUserVenueEventInterestIDs,
            followingInterestCounts: followingTabGoingInterestCounts,
            followingItems: followingTabGoingItems
        )

        applyOptimisticVenueGameGoingUI(
            bar: bar,
            gameTitle: trimmed,
            venueEventID: resolvedCacheID,
            isGoing: targetGoing
        )

        Task {
            await completeVenueGameGoingToggle(
                bar: bar,
                gameTitle: trimmed,
                eventDate: eventDate,
                cachedVenueEventID: resolvedCacheID,
                targetGoing: targetGoing,
                source: source,
                rollbackSnapshot: rollbackSnapshot
            )
        }
    }

    private struct VenueGameGoingRollbackSnapshot {
        let interestIDs: Set<UUID>
        let interestCounts: [UUID: Int]
        let followingInterestIDs: Set<UUID>
        let followingInterestCounts: [UUID: Int]
        let followingItems: [FollowingGoingDisplayItem]
    }

    @MainActor
    private func applyOptimisticVenueGameGoingUI(
        bar: BarVenue,
        gameTitle: String,
        venueEventID: UUID?,
        isGoing: Bool
    ) {
        if isGoing {
            markInterested(in: bar, gameTitle: gameTitle)
        } else {
            removeInterested(in: bar, gameTitle: gameTitle)
        }
        if let venueEventID {
            venueEventInterestWriteInFlightIDs.insert(venueEventID)
            applyLocalVenueEventInterestState(
                venueEventID: venueEventID,
                isInterested: isGoing,
                discoverBar: bar
            )
            print(
                "[GoingButtonDebug] optimisticUpdate eventId=\(normalizedVenueEventWireId(venueEventID)) going=\(isGoing)"
            )
        } else {
            print("[GoingButtonDebug] optimisticUpdate eventId=nil going=\(isGoing)")
        }
    }

    @MainActor
    private func rollbackOptimisticVenueGameGoingUI(
        bar: BarVenue,
        gameTitle: String,
        venueEventID: UUID?,
        restoreGoing: Bool,
        previousInterestIDs: Set<UUID>,
        previousInterestCounts: [UUID: Int],
        previousFollowingInterestIDs: Set<UUID>,
        previousFollowingInterestCounts: [UUID: Int],
        previousFollowingItems: [FollowingGoingDisplayItem]
    ) {
        if let venueEventID {
            venueEventInterestWriteInFlightIDs.remove(venueEventID)
            print(
                "[GoingTabSyncDebug] rollback eventId=\(normalizedVenueEventWireId(venueEventID))"
            )
        }
        venueEventInterestIDs = previousInterestIDs
        venueEventInterestCounts = previousInterestCounts
        followingTabUserVenueEventInterestIDs = previousFollowingInterestIDs
        followingTabGoingInterestCounts = previousFollowingInterestCounts
        followingTabGoingItems = previousFollowingItems
        if restoreGoing {
            markInterested(in: bar, gameTitle: gameTitle)
        } else {
            removeInterested(in: bar, gameTitle: gameTitle)
        }
        if let venueEventID {
            reconcileFollowingGoingDisplayAfterInterestMutation(venueEventID: venueEventID)
        }
    }

    private func completeVenueGameGoingToggle(
        bar: BarVenue,
        gameTitle: String,
        eventDate: Date,
        cachedVenueEventID: UUID?,
        targetGoing: Bool,
        source: String,
        rollbackSnapshot: VenueGameGoingRollbackSnapshot
    ) async {
        guard let interestEmail = await resolvedInterestMutationEmail() else {
            print("[GoingButtonDebug] blocked reason=noEmail source=\(source)")
            await MainActor.run {
                rollbackOptimisticVenueGameGoingUI(
                    bar: bar,
                    gameTitle: gameTitle,
                    venueEventID: cachedVenueEventID,
                    restoreGoing: !targetGoing,
                    previousInterestIDs: rollbackSnapshot.interestIDs,
                    previousInterestCounts: rollbackSnapshot.interestCounts,
                    previousFollowingInterestIDs: rollbackSnapshot.followingInterestIDs,
                    previousFollowingInterestCounts: rollbackSnapshot.followingInterestCounts,
                    previousFollowingItems: rollbackSnapshot.followingItems
                )
                showSocialActionToast("Please log in with a FanGeo account to mark yourself as going.")
            }
            return
        }

        guard let wireEventID = await venueEventID(for: bar, gameTitle: gameTitle, on: eventDate) ?? cachedVenueEventID else {
            print("[GoingButtonDebug] blocked reason=noEventId source=\(source) title=\(gameTitle)")
            await MainActor.run {
                rollbackOptimisticVenueGameGoingUI(
                    bar: bar,
                    gameTitle: gameTitle,
                    venueEventID: cachedVenueEventID,
                    restoreGoing: !targetGoing,
                    previousInterestIDs: rollbackSnapshot.interestIDs,
                    previousInterestCounts: rollbackSnapshot.interestCounts,
                    previousFollowingInterestIDs: rollbackSnapshot.followingInterestIDs,
                    previousFollowingInterestCounts: rollbackSnapshot.followingInterestCounts,
                    previousFollowingItems: rollbackSnapshot.followingItems
                )
                showSocialActionToast("Couldn't find this game yet. Try again in a moment.")
            }
            return
        }

        if cachedVenueEventID != wireEventID {
            await MainActor.run {
                if targetGoing {
                    if let cachedVenueEventID {
                        venueEventInterestWriteInFlightIDs.remove(cachedVenueEventID)
                        venueEventInterestIDs.remove(cachedVenueEventID)
                    }
                    venueEventInterestWriteInFlightIDs.insert(wireEventID)
                    applyLocalVenueEventInterestState(
                        venueEventID: wireEventID,
                        isInterested: true,
                        discoverBar: bar
                    )
                } else if let cachedVenueEventID, cachedVenueEventID != wireEventID {
                    applyLocalVenueEventInterestState(
                        venueEventID: cachedVenueEventID,
                        isInterested: false,
                        discoverBar: bar
                    )
                }
                print(
                    "[GoingButtonDebug] normalizedEventId=\(normalizedVenueEventWireId(wireEventID)) source=resolvedMismatch cached=\(cachedVenueEventID?.uuidString.lowercased() ?? "nil")"
                )
            }
        }

        let ok = await setVenueEventInterest(
            venueEventID: wireEventID,
            isInterested: targetGoing,
            refreshFollowing: false,
            applyOptimistic: false,
            manageWriteInFlight: false
        )

        if !ok {
            await MainActor.run {
                venueEventInterestWriteInFlightIDs.remove(wireEventID)
                if let cachedVenueEventID, cachedVenueEventID != wireEventID {
                    venueEventInterestWriteInFlightIDs.remove(cachedVenueEventID)
                }
            }
            await MainActor.run {
                rollbackOptimisticVenueGameGoingUI(
                    bar: bar,
                    gameTitle: gameTitle,
                    venueEventID: wireEventID,
                    restoreGoing: !targetGoing,
                    previousInterestIDs: rollbackSnapshot.interestIDs,
                    previousInterestCounts: rollbackSnapshot.interestCounts,
                    previousFollowingInterestIDs: rollbackSnapshot.followingInterestIDs,
                    previousFollowingInterestCounts: rollbackSnapshot.followingInterestCounts,
                    previousFollowingItems: rollbackSnapshot.followingItems
                )
                showSocialActionToast("Couldn't update your game plan.")
            }
            return
        }

        await MainActor.run {
            venueEventInterestWriteInFlightIDs.remove(wireEventID)
            if let cachedVenueEventID, cachedVenueEventID != wireEventID {
                venueEventInterestWriteInFlightIDs.remove(cachedVenueEventID)
            }
        }

        scheduleDeferredVisibleVenueEventInterestsReload()
        scheduleDeferredFollowingTabGoingReconcile(venueEventID: wireEventID)

        if targetGoing {
            await addGameToCalendar(
                title: gameTitle,
                date: eventDate,
                location: bar.address
            )
        }

        _ = interestEmail
    }

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
    private func reconcileFollowingGoingDisplayAfterInterestMutation(
        venueEventID: UUID,
        discoverBar: BarVenue? = nil
    ) {
        let snapshot = barAndTitleForDiscoverInterestKey(venueEventID: venueEventID)
        let localOnly = MapViewModel.followingInterestedOnlyVenueEventIDsFromUserDefaults()
        let hasServer = venueEventInterestIDs.contains(venueEventID)
            || followingTabUserVenueEventInterestIDs.contains(venueEventID)
        let keep = hasServer
            || localOnly.contains(venueEventID)
            || venueEventInterestWriteInFlightIDs.contains(venueEventID)
            || isRecentlyConfirmedVenueEventGoing(venueEventID)

        if let (bar, title) = snapshot {
            let key = venueEventInterestKey(for: bar, gameTitle: title)
            if keep {
                interestedVenueEventKeys.insert(key)
            } else if !venueEventInterestWriteInFlightIDs.contains(venueEventID),
                      !isRecentlyConfirmedVenueEventGoing(venueEventID) {
                interestedVenueEventKeys.remove(key)
            }
        } else if let discoverBar, keep {
            let title = discoverBar.games.first ?? ""
            if !title.isEmpty {
                interestedVenueEventKeys.insert(venueEventInterestKey(for: discoverBar, gameTitle: title))
            }
        }

        if keep {
            optimisticAddFollowingTabGoingItem(venueEventID: venueEventID, discoverBar: discoverBar ?? snapshot?.0)
        } else {
            optimisticRemoveFollowingTabGoingItem(venueEventID: venueEventID)
        }
    }

    @MainActor
    private func optimisticAddFollowingTabGoingItem(venueEventID: UUID, discoverBar: BarVenue?) {
        let wireId = normalizedVenueEventWireId(venueEventID)
        guard let row = venueEventRows.first(where: { $0.id == venueEventID }) else {
            print("[GoingTabSyncDebug] optimisticAdd skipped missingRow eventId=\(wireId)")
            return
        }

        let attendeeCount = max(venueEventInterestCounts[venueEventID] ?? 0, 1)
        followingTabGoingInterestCounts[venueEventID] = attendeeCount

        if let index = followingTabGoingItems.firstIndex(where: { $0.id == venueEventID }) {
            let existing = followingTabGoingItems[index]
            followingTabGoingItems[index] = FollowingGoingDisplayItem(
                id: venueEventID,
                venueEvent: row,
                bar: discoverBar ?? existing.bar,
                attendeeCount: attendeeCount,
                isServerGoing: true,
                isInterestedOnlyLocal: false
            )
            print("[GoingTabSyncDebug] optimisticAdd eventId=\(wireId) updatedExisting=true")
            refreshFollowingInterestDerivedSnapshotsForUI()
            return
        }

        let bar = resolveBarForOptimisticFollowingTabItem(row: row, preferredBar: discoverBar)
        let item = FollowingGoingDisplayItem(
            id: venueEventID,
            venueEvent: row,
            bar: bar,
            attendeeCount: attendeeCount,
            isServerGoing: true,
            isInterestedOnlyLocal: false
        )
        var items = followingTabGoingItems
        items.append(item)
        items.sort { $0.id.uuidString < $1.id.uuidString }
        followingTabGoingItems = items
        print("[GoingTabSyncDebug] optimisticAdd eventId=\(wireId) count=\(followingTabGoingItems.count)")
        refreshFollowingInterestDerivedSnapshotsForUI()
    }

    @MainActor
    private func optimisticRemoveFollowingTabGoingItem(venueEventID: UUID) {
        let wireId = normalizedVenueEventWireId(venueEventID)
        let hadItem = followingTabGoingItems.contains { $0.id == venueEventID }
        followingTabGoingItems.removeAll { $0.id == venueEventID }
        goingProfilesByVenueEventID.removeValue(forKey: venueEventID)
        if venueEventInterestCounts[venueEventID] != nil {
            venueEventInterestCounts[venueEventID] = max((venueEventInterestCounts[venueEventID] ?? 0), 0)
            followingTabGoingInterestCounts[venueEventID] = venueEventInterestCounts[venueEventID]
        } else {
            followingTabGoingInterestCounts.removeValue(forKey: venueEventID)
        }
        if hadItem {
            print("[GoingTabSyncDebug] optimisticRemove eventId=\(wireId) count=\(followingTabGoingItems.count)")
            refreshFollowingInterestDerivedSnapshotsForUI()
        }
    }

    @MainActor
    private func resolveBarForOptimisticFollowingTabItem(row: VenueEventRow, preferredBar: BarVenue?) -> BarVenue {
        if let preferredBar { return preferredBar }
        if let vid = row.venue_id, let bar = bars.first(where: { $0.id == vid }) {
            return bar
        }
        let venueName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !venueName.isEmpty, let bar = bars.first(where: { $0.name == venueName }) {
            return bar
        }
        if let item = followingTabGoingItems.first(where: { $0.id == row.id }) {
            return item.bar
        }
        return placeholderBarForFollowingGoingList(row: row)
    }

    @MainActor
    private func placeholderBarForFollowingGoingList(row: VenueEventRow) -> BarVenue {
        let trimmedName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmedName.isEmpty ? "Venue" : trimmedName
        let title = row.event_title ?? ""
        let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return BarVenue(
            id: row.venue_id ?? UUID(),
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
            ownerEmail: row.owner_email,
            businessId: nil,
            adminStatus: row.admin_status,
            venueOwnerEmailRaw: row.owner_email,
            businessOwnerEmailRaw: nil,
            contactEmailRaw: nil
        )
    }

    private func scheduleDeferredFollowingTabGoingReconcile(venueEventID: UUID) {
        let wireId = normalizedVenueEventWireId(venueEventID)
        print("[GoingTabSyncDebug] reconcileScheduled eventId=\(wireId)")
        followingTabGoingReconcileTask?.cancel()
        followingTabGoingReconcileTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.refreshFollowingTabDataGlobally()
            await MainActor.run {
                print(
                    "[GoingTabSyncDebug] reconcileApplied count=\(self.followingTabGoingItems.count) eventId=\(wireId)"
                )
            }
        }
    }

    @MainActor
    private func applyLocalVenueEventInterestState(
        venueEventID: UUID,
        isInterested: Bool,
        discoverBar: BarVenue? = nil
    ) {
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

        reconcileFollowingGoingDisplayAfterInterestMutation(
            venueEventID: venueEventID,
            discoverBar: discoverBar
        )
    }

    private func discoverSQLDateString(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: day)
    }

    private func goingButtonDebugAuthContext() async -> (userId: String, email: String) {
        let userId = await MainActor.run {
            currentUserAuthId?.uuidString.lowercased() ?? "nil"
        }
        let email = await resolvedInterestMutationEmail() ?? "nil"
        return (userId, email)
    }

    private func logGoingButtonInsertPayload(
        _ interest: VenueEventInterestInsert,
        venueEventID: UUID
    ) {
        print(
            "[GoingButtonDebug] insertPayload=venue_event_id:\(normalizedVenueEventWireId(venueEventID)) user_email:\(interest.user_email) eventId=\(venueEventID.uuidString.lowercased())"
        )
    }

    private func logGoingButtonSupabaseError(_ error: Error, venueEventID: UUID) {
        if let pe = error as? PostgrestError {
            print(
                "[GoingButtonDebug] supabaseError code=\(pe.code ?? "") message=\(pe.message) details=\(pe.detail ?? "") hint=\(pe.hint ?? "") eventId=\(venueEventID.uuidString.lowercased())"
            )
        } else {
            print(
                "[GoingButtonDebug] supabaseError code= message=\(error.localizedDescription) details= hint= eventId=\(venueEventID.uuidString.lowercased())"
            )
        }
    }

    private func isVenueEventInterestDuplicateError(_ error: Error) -> Bool {
        if let pe = error as? PostgrestError, pe.code == "23505" {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("duplicate key") || message.contains("23505")
    }

    private func scheduleDeferredVisibleVenueEventInterestsReload() {
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self.loadVisibleVenueEventInterests(preserveLocalOptimistic: true)
        }
    }

    @discardableResult
    func setVenueEventInterest(
        venueEventID: UUID,
        isInterested: Bool,
        refreshFollowing: Bool = true,
        applyOptimistic: Bool = true,
        manageWriteInFlight: Bool = true
    ) async -> Bool {
        let normalizedEventId = normalizedVenueEventWireId(venueEventID)
        if manageWriteInFlight, venueEventInterestWriteInFlightIDs.contains(venueEventID) {
            print("[GoingButtonDebug] blocked reason=pending eventId=\(normalizedEventId)")
            return false
        }
        guard canMarkGoing else {
            logBusinessUserGateBlocked(action: "markGoing")
            print("[GoingButtonDebug] blocked reason=businessUser eventId=\(normalizedEventId)")
            print("USER MUST BE LOGGED IN TO MARK INTEREST")
            return false
        }

        let auth = await goingButtonDebugAuthContext()
        guard let interestEmail = await resolvedInterestMutationEmail() else {
            print(
                "[GoingButtonDebug] blocked reason=noEmail eventId=\(normalizedEventId) auth userId=\(auth.userId) email=\(auth.email)"
            )
            print("USER MUST BE LOGGED IN TO MARK INTEREST")
            return false
        }

        let snapshot = await MainActor.run { () -> (
            previousInterestIDs: Set<UUID>,
            previousInterestCounts: [UUID: Int],
            previousFollowingInterestIDs: Set<UUID>,
            previousFollowingInterestCounts: [UUID: Int],
            previousFollowingItems: [FollowingGoingDisplayItem],
            wasAlreadyInterested: Bool
        ) in
            (
                venueEventInterestIDs,
                venueEventInterestCounts,
                followingTabUserVenueEventInterestIDs,
                followingTabGoingInterestCounts,
                followingTabGoingItems,
                venueEventInterestIDs.contains(venueEventID)
                    || followingTabUserVenueEventInterestIDs.contains(venueEventID)
            )
        }

        if applyOptimistic {
            await MainActor.run {
                if manageWriteInFlight {
                    venueEventInterestWriteInFlightIDs.insert(venueEventID)
                }
                applyLocalVenueEventInterestState(venueEventID: venueEventID, isInterested: isInterested)
                print(
                    "[GoingButtonDebug] optimisticUpdate eventId=\(normalizedEventId) going=\(isInterested)"
                )
            }
        }

        do {
            print("[GoingButtonDebug] interestEmailWrite=\(interestEmail)")
            print("[GoingButtonDebug] interestEmailRead=\(interestEmail)")
            if isInterested {
                print("[GoingButtonDebug] insertStart eventId=\(normalizedEventId)")
                let interest = VenueEventInterestInsert(
                    venue_event_id: venueEventID,
                    user_email: interestEmail
                )
                logGoingButtonInsertPayload(interest, venueEventID: venueEventID)
                // Plain insert only — upsert triggers RLS UPDATE on conflict and can roll back Going UI.
                try await supabase
                    .from("venue_event_interests")
                    .insert(interest)
                    .execute()
                print("[GoingButtonDebug] insertSuccess eventId=\(normalizedEventId)")
            } else {
                print("[GoingButtonDebug] deleteStart eventId=\(normalizedEventId)")
                print(
                    "[GoingButtonDebug] payload=action:delete venue_event_id:\(normalizedEventId) user_email:\(interestEmail) eventId=\(normalizedEventId)"
                )
                try await supabase
                    .from("venue_event_interests")
                    .delete()
                    .eq("venue_event_id", value: normalizedEventId)
                    .eq("user_email", value: interestEmail)
                    .execute()
                print("[GoingButtonDebug] deleteSuccess eventId=\(normalizedEventId)")
            }
        } catch {
            if isInterested, isVenueEventInterestDuplicateError(error) {
                print("[GoingButtonDebug] duplicateTreatedAsSuccess eventId=\(normalizedEventId)")
                print("[GoingButtonDebug] insertSuccess eventId=\(normalizedEventId)")
            } else {
                await MainActor.run {
                    venueEventInterestIDs = snapshot.previousInterestIDs
                    venueEventInterestCounts = snapshot.previousInterestCounts
                    followingTabUserVenueEventInterestIDs = snapshot.previousFollowingInterestIDs
                    followingTabGoingInterestCounts = snapshot.previousFollowingInterestCounts
                    followingTabGoingItems = snapshot.previousFollowingItems
                    if manageWriteInFlight {
                        venueEventInterestWriteInFlightIDs.remove(venueEventID)
                    }
                }
#if DEBUG
                if hasAuthenticatedVenueOwnerSession {
                    print("[FollowingState] business attendance save failed")
                }
#endif
                logGoingButtonSupabaseError(error, venueEventID: venueEventID)
                print(
                    "[GoingButtonDebug] rollback eventId=\(normalizedEventId) reason=supabaseFailure"
                )
                print("ERROR SETTING INTEREST:", error)
                return false
            }
        }

        await MainActor.run {
            recordRecentlyConfirmedVenueEventInterest(venueEventID: venueEventID, isGoing: isInterested)
            applyLocalVenueEventInterestState(venueEventID: venueEventID, isInterested: isInterested)
            if manageWriteInFlight {
                venueEventInterestWriteInFlightIDs.remove(venueEventID)
            }
        }

        if refreshFollowing {
            Task { @MainActor in
#if DEBUG
                if self.hasAuthenticatedVenueOwnerSession {
                    print("[FollowingState] business attendance change event=\(venueEventID.uuidString)")
                }
#endif
                await self.loadGoingUserProfiles(for: venueEventID)
                self.refreshFollowingInterestDerivedSnapshotsForUI()
            }
            scheduleDeferredFollowingTabGoingReconcile(venueEventID: venueEventID)
        } else {
            scheduleDeferredVisibleVenueEventInterestsReload()
            scheduleDeferredFollowingTabGoingReconcile(venueEventID: venueEventID)
        }

        if isInterested, !snapshot.wasAlreadyInterested, let uid = await MainActor.run(body: { currentUserAuthId }) {
            Task {
                await self.awardFanXP(
                    userId: uid,
                    amount: 5,
                    source: FanXPSource.venueEventInterest,
                    sourceId: venueEventID
                )
            }
        }

        if isInterested {
            await scheduleGameReminderIfPossible(venueEventID: venueEventID)
        } else {
            await cancelGameReminder(venueEventID: venueEventID)
        }

        return true
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
        let trimmed = normalizedVenueGameTitle(gameTitle)
        guard !trimmed.isEmpty else { return nil }
        let primary = venueEventLookupKeyPrimary(for: bar, gameTitle: trimmed)
        if let id = venueEventIDsByKey[primary] ?? venueEventIDsByKey[venueEventLookupKey(for: bar, gameTitle: trimmed)] {
            return id
        }
        if let row = venueEventRows.first(where: { venueEventRow($0, matches: bar) && venueEventTitlesMatch($0.event_title, trimmed) }),
           let id = row.id {
            cacheDiscoveredVenueEventID(id, bar: bar, gameTitle: trimmed, rowTitle: row.event_title)
            return id
        }
        return nil
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
    func prefetchGoingProfilesForVisibleEventBatchIfNeeded(eventIDs: [UUID]) async {
        let idsToFetch = eventIDs.filter { eventID in
            !(fanUpdatesGoingProfilesPrefetchIsFresh(fanUpdatesGoingProfilePrefetchedAt[eventID]) &&
              goingProfilesByVenueEventID[eventID] != nil)
        }
        guard !idsToFetch.isEmpty else { return }

        guard canUseFanSocialFeatures else {
            let now = Date()
            for eventID in idsToFetch {
                goingProfilesByVenueEventID[eventID] = []
                fanUpdatesGoingProfilePrefetchedAt[eventID] = now
            }
            return
        }

        do {
            let rows: [VenueEventInterestRow] = try await supabase
                .from("venue_event_interests")
                .select("venue_event_id,user_email")
                .in("venue_event_id", values: idsToFetch.map { $0.uuidString.lowercased() })
                .execute()
                .value

            var emailsByEventID: [UUID: [String]] = [:]
            var allEmails: Set<String> = []
            for row in rows {
                guard let eventID = row.venue_event_id else { continue }
                let email = OwnerBusinessEmail.normalized(row.user_email ?? "")
                guard OwnerBusinessEmail.isValidStrict(email) else { continue }
                emailsByEventID[eventID, default: []].append(email)
                allEmails.insert(email)
            }

            let profileRows = allEmails.isEmpty
                ? []
                : try await SocialIdentityService().fetchUserProfileRows(forEmails: Array(allEmails))
            var profilesByEmail: [String: UserProfileRow] = [:]
            for profile in profileRows {
                let email = OwnerBusinessEmail.normalized(profile.email ?? "")
                guard OwnerBusinessEmail.isValidStrict(email), profilesByEmail[email] == nil else { continue }
                profilesByEmail[email] = profile
            }

            let now = Date()
            for eventID in idsToFetch {
                let eventProfiles = (emailsByEventID[eventID] ?? []).compactMap { profilesByEmail[$0] }
                goingProfilesByVenueEventID[eventID] = eventProfiles
                fanUpdatesGoingProfilePrefetchedAt[eventID] = now
            }
        } catch {
            if error is CancellationError {
                #if DEBUG
                print("[LoadCancelled] going profiles visible batch")
                #endif
            } else {
                print("ERROR LOADING GOING USER PROFILES BATCH:", error)
            }
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
        "\(bar.id.uuidString)-\(normalizedVenueGameTitle(gameTitle))"
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
            || followingTabUserVenueEventInterestIDs.contains(venueEventID)
    }

    func interestCountForVenueEvent(_ venueEventID: UUID) -> Int {
        venueEventInterestCounts[venueEventID] ?? 0
    }

    func venueEventID(for bar: BarVenue, gameTitle: String, on eventDay: Date? = nil) async -> UUID? {
        let trimmed = normalizedVenueGameTitle(gameTitle)
        guard !trimmed.isEmpty else { return nil }

        let day = eventDay ?? selectedDate
        let selectedDaySQL = discoverSQLDateString(for: day)

        if let cached = cachedVenueEventID(for: bar, gameTitle: trimmed) {
            if let row = venueEventRows.first(where: { $0.id == cached }),
               let rowDate = row.event_date,
               rowDate == selectedDaySQL {
                print("[GoingButtonDebug] normalizedEventId=\(cached.uuidString.lowercased()) source=cache")
                return cached
            }
            if !venueEventRows.contains(where: { $0.id == cached }) {
                print("[GoingButtonDebug] normalizedEventId=\(cached.uuidString.lowercased()) source=cache")
                return cached
            }
        }

        if let row = venueEventRows.first(where: { row in
            guard venueEventRow(row, matches: bar), venueEventTitlesMatch(row.event_title, trimmed) else { return false }
            guard let rowDate = row.event_date else { return true }
            return rowDate == selectedDaySQL
        }),
           let id = row.id {
            cacheDiscoveredVenueEventID(id, bar: bar, gameTitle: trimmed, rowTitle: row.event_title)
            print("[GoingButtonDebug] normalizedEventId=\(id.uuidString.lowercased()) source=inMemoryRows")
            return id
        }

        do {
            let rowsByVenueId: [VenueEventRow] = try await supabase
                .from("venue_events")
                .select("id,venue_id,owner_email,venue_name,event_title,event_date")
                .eq("admin_status", value: "active")
                .eq("venue_id", value: bar.id)
                .eq("event_date", value: selectedDaySQL)
                .execute()
                .value

            if let row = rowsByVenueId.first(where: { venueEventTitlesMatch($0.event_title, trimmed) }),
               let id = row.id {
                cacheDiscoveredVenueEventID(id, bar: bar, gameTitle: trimmed, rowTitle: row.event_title)
                print("[GoingButtonDebug] normalizedEventId=\(id.uuidString.lowercased()) source=networkVenueId")
                return id
            }

            var qLegacy = supabase
                .from("venue_events")
                .select("id,venue_id,owner_email,venue_name,event_title,event_date")
                .eq("admin_status", value: "active")
                .eq("event_date", value: selectedDaySQL)
                .is("venue_id", value: nil)

            let ownerNorm = OwnerBusinessEmail.normalized(bar.ownerEmail ?? "")
            if OwnerBusinessEmail.isValidStrict(ownerNorm) {
                qLegacy = qLegacy.eq("owner_email", value: ownerNorm)
            } else {
                qLegacy = qLegacy.eq("venue_name", value: bar.name)
            }

            let rows: [VenueEventRow] = try await qLegacy
                .execute()
                .value

            if let row = rows.first(where: { venueEventTitlesMatch($0.event_title, trimmed) }),
               let id = row.id {
                cacheDiscoveredVenueEventID(id, bar: bar, gameTitle: trimmed, rowTitle: row.event_title)
                print("[GoingButtonDebug] normalizedEventId=\(id.uuidString.lowercased()) source=networkLegacy")
                #if DEBUG
                print("[DiscoverPerf] venueEventID legacy lookup title=\(trimmed) matched=\(row.event_title ?? "")")
                #endif
                return id
            }

            print(
                "[GoingButtonDebug] blocked reason=venueEventLookupFailed title=\(trimmed) venueId=\(bar.id.uuidString.lowercased()) selectedDay=\(selectedDaySQL) networkRows=\(rowsByVenueId.count + rows.count)"
            )
            #if DEBUG
            print("[DiscoverPerf] venueEventID network lookup title=\(trimmed) rows=\(rows.count)")
            #endif
            return nil

        } catch {
            print("[GoingButtonDebug] blocked reason=venueEventLookupFailed title=\(trimmed) error=\(error.localizedDescription)")
            #if DEBUG
            print("ERROR FINDING VENUE EVENT ID:", error)
            #endif
            return nil
        }
    }

    func loadVisibleVenueEventInterests(preserveLocalOptimistic: Bool = true) async {
        let visibleEventIDs = await MainActor.run { venueEventRows.compactMap(\.id) }

        guard !visibleEventIDs.isEmpty else {
            return
        }

        let t0 = Date()
        /// Must match ``strictNormalizedSessionEmailForSocialTables`` / inserts to `venue_event_interests` (not `currentUserEmail`, which may diverge after profile load).
        let sessionInterestEmail = await strictNormalizedSessionEmailForSocialTables()
        let interestEmailRead = sessionInterestEmail ?? "nil"
        print("[GoingButtonDebug] interestEmailRead=\(interestEmailRead)")

        let previousInterestCounts = await MainActor.run { venueEventInterestCounts }

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
                       OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(sessionInterestEmail)) {
                        let rowEmail = row.user_email ?? ""
                        let normalizedRowEmail = OwnerBusinessEmail.normalized(rowEmail)
                        let normalizedSessionEmail = OwnerBusinessEmail.normalized(sessionInterestEmail)
                        if normalizedRowEmail == normalizedSessionEmail {
                            print(
                                "[GoingButtonDebug] rowEmail=\(rowEmail) eventId=\(normalizedVenueEventWireId(eventID))"
                            )
                            myInterests.insert(eventID)
                        }
                    }
                }
            }

            let serverMineSummary = myInterests.map { normalizedVenueEventWireId($0) }.sorted().joined(separator: ",")
            print("[GoingButtonDebug] reconcileStart serverMine=\(serverMineSummary.isEmpty ? "[]" : serverMineSummary)")

            await MainActor.run {
                var mergedIDs = myInterests
                var mergedCounts = counts

                if preserveLocalOptimistic {
                    pruneVenueEventInterestLocalReconcileGuards()
                    let preserveInFlight = venueEventInterestWriteInFlightIDs
                    let preserveConfirmedGoing = activeRecentlyConfirmedVenueEventGoingIDs()
                    let preserveConfirmedNotGoing = activeRecentlyConfirmedVenueEventNotGoingIDs()

                    for eventID in preserveInFlight.union(preserveConfirmedGoing) {
                        if preserveConfirmedNotGoing.contains(eventID) { continue }
                        if !myInterests.contains(eventID) {
                            print(
                                "[GoingButtonDebug] flipPrevented eventId=\(normalizedVenueEventWireId(eventID))"
                            )
                        }
                        if preserveInFlight.contains(eventID), !myInterests.contains(eventID) {
                            print(
                                "[GoingButtonDebug] preserveOptimistic eventId=\(normalizedVenueEventWireId(eventID))"
                            )
                        }
                        if preserveConfirmedGoing.contains(eventID), !myInterests.contains(eventID) {
                            print(
                                "[GoingButtonDebug] preserveConfirmed eventId=\(normalizedVenueEventWireId(eventID))"
                            )
                        }
                        mergedIDs.insert(eventID)
                        let prior = previousInterestCounts[eventID] ?? venueEventInterestCounts[eventID] ?? 0
                        let serverCount = counts[eventID] ?? 0
                        mergedCounts[eventID] = max(serverCount, prior, 1)
                    }

                    for eventID in preserveConfirmedNotGoing {
                        mergedIDs.remove(eventID)
                    }

                    for eventID in mergedIDs where preserveInFlight.contains(eventID) || preserveConfirmedGoing.contains(eventID) {
                        let prior = previousInterestCounts[eventID] ?? venueEventInterestCounts[eventID] ?? 0
                        if (mergedCounts[eventID] ?? 0) < prior {
                            mergedCounts[eventID] = prior
                        }
                    }
                }

                let appliedMineSummary = mergedIDs.map { normalizedVenueEventWireId($0) }.sorted().joined(separator: ",")
                print(
                    "[GoingButtonDebug] reconcileApplied myInterests=\(appliedMineSummary.isEmpty ? "[]" : appliedMineSummary)"
                )

                venueEventInterestCounts = mergedCounts
                venueEventInterestIDs = mergedIDs
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
