import Foundation
import Supabase

extension MapViewModel {
    func venueGameCardState(
        input: VenueGameCardInput,
        friendUserIDs: Set<UUID>
    ) -> VenueGameCardState {
        let bar = venueGameCardBar(for: input.barID)
        let event = SportsEvent(
            id: input.venueEventID,
            title: input.title,
            sport: input.sport,
            league: "",
            date: input.date,
            time: input.eventTime,
            country: ""
        )
        let energy = bar.map {
            liveEnergy(for: $0, event: event, friendUserIDs: friendUserIDs)
        } ?? VenueGameCardState.emptyLiveEnergy
        let isGoing: Bool
        if let bar, isInterested(in: bar, gameTitle: input.title) {
            isGoing = true
        } else if recentlyConfirmedVenueEventNotGoingAt[input.venueEventID] != nil {
            isGoing = false
        } else if isInterestedInVenueEvent(input.venueEventID) {
            isGoing = true
        } else if venueEventInterestWriteInFlightIDs.contains(input.venueEventID) {
            isGoing = true
        } else {
            isGoing = recentlyConfirmedVenueEventGoingAt[input.venueEventID] != nil
        }
        let computedAvatarProfiles = goingAvatarProfiles(
            for: input.venueEventID,
            fallbackProfiles: energy.socialPresenceProfiles,
            currentUserGoing: isGoing
        )
        let visibleAvatarCount = computedAvatarProfiles
            .filter { $0.isFanVisibleForLivePresence(to: currentUserAuthId) }
            .count
        let cachedGoing = venueEventInterestWriteInFlightIDs.contains(input.venueEventID)
            ? nil
            : venueGameCardSnapshotStore.snapshot(for: input.venueEventID)
        let fanChatCount = fanUpdatesDisplayCommentCount(for: input.venueEventID)
        let vibeCounts = venueEventVibeCounts[input.venueEventID] ?? [:]
        let selectedVibes = myVenueEventVibes[input.venueEventID] ?? []
        let miniStats = VenueGameCardMiniStats(
            vibeCounts: vibeCounts,
            selectedVibes: selectedVibes,
            topVibeText: venueGameCardTopVibeText(from: vibeCounts),
            trendingScore: energy.goingCount + fanChatCount + vibeCounts.values.reduce(0, +)
        )

        return VenueGameCardState(
            input: input,
            isCurrentUserGoing: cachedGoing?.isCurrentUserGoing ?? isGoing,
            goingCount: cachedGoing?.goingCount
                ?? max(energy.goingCount, isGoing ? 1 : 0, visibleAvatarCount),
            goingAvatarProfiles: cachedGoing?.goingAvatarProfiles ?? computedAvatarProfiles,
            predictionSummary: venueEventPredictionSummaries[input.venueEventID],
            fanChatCount: fanChatCount,
            miniStats: miniStats,
            liveEnergy: energy,
            isLoading: false,
            reconcileStatus: venueEventInterestWriteInFlightIDs.contains(input.venueEventID)
                ? .optimistic
                : (cachedGoing?.reconcileStatus ?? .idle),
            lastGoingUpdatedAt: cachedGoing?.lastGoingUpdatedAt,
            lastAvatarUpdatedAt: cachedGoing?.lastAvatarUpdatedAt,
            lastFanChatUpdatedAt: nil,
            lastMiniStatsUpdatedAt: nil,
            lastPredictionUpdatedAt: nil
        )
    }

    func selectVenueForPreview(_ bar: BarVenue, source: String) {
#if DEBUG
        print("[VenueGameCardStoreDebug] initialTrigger source=\(source)")
#endif
        selectedPickupGameForMap = nil
        selectedBar = bar
        scheduleInitialVenueGameCardGoingRefresh(reason: source)
    }

    func scheduleInitialVenueGameCardGoingRefresh(reason: String) {
#if DEBUG
        print("[VenueGameCardStoreDebug] initialSchedulerEntered=true")
#endif
        venueGameCardInitialGoingRefreshTask?.cancel()
        venueGameCardInitialGoingRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
#if DEBUG
                print("[VenueGameCardStoreDebug] initialSchedulerAborted reason=debounceAlreadyPending")
#endif
                return
            }
            guard let self else {
#if DEBUG
                print("[VenueGameCardStoreDebug] initialSchedulerAborted reason=viewModelReleased")
#endif
                return
            }
            guard !Task.isCancelled else {
#if DEBUG
                print("[VenueGameCardStoreDebug] initialSchedulerAborted reason=debounceAlreadyPending")
#endif
                return
            }
            await self.refreshInitialVenueGameCardGoingState(reason: reason)
            if !Task.isCancelled {
                self.venueGameCardInitialGoingRefreshTask = nil
            }
        }
    }

    private func refreshInitialVenueGameCardGoingState(reason: String) async {
#if DEBUG
        if currentUserAuthId == nil {
            print("[VenueGameCardStoreDebug] initialSchedulerAborted reason=notLoggedIn diagnosticOnly=true")
        }
        if !canUseFanSocialFeatures {
            print("[VenueGameCardStoreDebug] initialSchedulerAborted reason=featureDisabled diagnosticOnly=true")
        }
#endif
        let ids = resolvedInitialVenueGameCardGoingRefreshIDs()
        let idList = ids.map { $0.uuidString.lowercased() }.joined(separator: ",")
#if DEBUG
        print(
            "[VenueGameCardStoreDebug] initialGoingRefreshRequested ids=\(idList.isEmpty ? "[]" : idList)"
        )
        print("[VenueGameCardStoreDebug] initialResolvedIds ids=\(idList.isEmpty ? "[]" : idList)")
#endif

        guard !ids.isEmpty else {
            venueGameCardInitialGoingRefreshLastIDs = []
#if DEBUG
            let skipReason: String
            if selectedBar == nil {
                skipReason = "noSelectedBar"
            } else if venueEventRows.isEmpty {
                skipReason = "noVenueEventRows"
            } else {
                skipReason = "noResolvedEventIds"
            }
            print("[VenueGameCardStoreDebug] initialSchedulerAborted reason=\(skipReason)")
            print("[VenueGameCardStoreDebug] initialGoingRefreshSkipped reason=\(skipReason)")
#endif
            return
        }

        let now = Date()
        var refreshIDs = ids.filter {
            venueGameCardGoingSnapshotNeedsInitialRefresh(
                eventID: $0,
                snapshot: venueGameCardSnapshotStore.snapshot(for: $0),
                now: now
            )
        }
        if refreshIDs.isEmpty, ids != venueGameCardInitialGoingRefreshLastIDs {
            refreshIDs = ids
        }

        guard !refreshIDs.isEmpty else {
#if DEBUG
            let skipReason = "sameIdsFresh"
            print("[VenueGameCardStoreDebug] initialSchedulerAborted reason=\(skipReason)")
            print("[VenueGameCardStoreDebug] initialGoingRefreshSkipped reason=\(skipReason)")
#endif
            venueGameCardInitialGoingRefreshLastIDs = ids
            return
        }

        venueGameCardInitialGoingRefreshLastIDs = ids
#if DEBUG
        let partialList = refreshIDs.map { $0.uuidString.lowercased() }.joined(separator: ",")
        print(
            "[VenueGameCardStoreDebug] initialGoingRefreshPartial ids=\(partialList.isEmpty ? "[]" : partialList)"
        )
#endif

        for eventID in refreshIDs {
            if Task.isCancelled { return }
#if DEBUG
            print(
                "[VenueGameCardStoreDebug] initialGoingRefreshStarted eventId=\(eventID.uuidString.lowercased())"
            )
#endif
            await refreshVenueGameCardGoingState(venueEventID: eventID)
#if DEBUG
            if let snapshot = venueGameCardSnapshotStore.snapshot(for: eventID) {
                let avatarCount = snapshot.goingAvatarProfiles
                    .filter { $0.isFanVisibleForLivePresence(to: currentUserAuthId) }
                    .count
                print(
                    "[VenueGameCardStoreDebug] initialGoingRefreshSucceeded eventId=\(eventID.uuidString.lowercased()) count=\(snapshot.goingCount) avatarCount=\(avatarCount)"
                )
            }
#endif
        }
    }

    func refreshVenueGameCardGoingState(venueEventID: UUID) async {
#if DEBUG
        print("[VenueGameCardStoreDebug] phase=goingOwnership")
        print(
            "[VenueGameCardStoreDebug] goingRefreshStarted eventId=\(venueEventID.uuidString.lowercased())"
        )
#endif
        await MainActor.run {
            let existing = venueGameCardSnapshotStore.snapshot(for: venueEventID)
            venueGameCardSnapshotStore.setSnapshot(
                VenueGameCardGoingSnapshot(
                    isCurrentUserGoing: existing?.isCurrentUserGoing ?? isInterestedInVenueEvent(venueEventID),
                    goingCount: existing?.goingCount
                        ?? venueEventInterestCounts[venueEventID]
                        ?? followingTabGoingInterestCounts[venueEventID]
                        ?? 0,
                    goingAvatarProfiles: existing?.goingAvatarProfiles
                        ?? goingProfilesByVenueEventID[venueEventID]
                        ?? [],
                    reconcileStatus: .reconciling,
                    lastGoingUpdatedAt: existing?.lastGoingUpdatedAt,
                    lastAvatarUpdatedAt: existing?.lastAvatarUpdatedAt
                ),
                for: venueEventID
            )
        }

        do {
            let rows: [VenueEventInterestRow] = try await supabase
                .from("venue_event_interests")
                .select("venue_event_id,user_email")
                .eq("venue_event_id", value: venueEventID.uuidString.lowercased())
                .execute()
                .value

            let count = rows.count
            let sessionInterestEmail = await strictNormalizedSessionEmailForSocialTables()
                ?? OwnerBusinessEmail.normalized(
                    !currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail
                )
            let currentUserIsGoing = rows.contains {
                OwnerBusinessEmail.normalized($0.user_email ?? "")
                    == OwnerBusinessEmail.normalized(sessionInterestEmail)
            }
            let emails = rows.compactMap { row -> String? in
                let email = OwnerBusinessEmail.normalized(row.user_email ?? "")
                return OwnerBusinessEmail.isValidStrict(email) ? email : nil
            }
            let profileRows = emails.isEmpty
                ? []
                : try await SocialIdentityService().fetchUserProfileRows(forEmails: Array(Set(emails)))
            var profilesByEmail: [String: UserProfileRow] = [:]
            for profile in profileRows {
                let email = OwnerBusinessEmail.normalized(profile.email ?? "")
                guard OwnerBusinessEmail.isValidStrict(email), profilesByEmail[email] == nil else { continue }
                profilesByEmail[email] = profile
            }
            var eventProfiles = emails.compactMap { profilesByEmail[$0] }
            if currentUserIsGoing, let current = venueGameCardCurrentUserProfileRow() {
                eventProfiles.removeAll { venueGameCardProfile($0, matchesCurrentUserProfile: current) }
                eventProfiles.insert(current, at: 0)
            } else if let current = venueGameCardCurrentUserProfileRow() {
                eventProfiles.removeAll { venueGameCardProfile($0, matchesCurrentUserProfile: current) }
            }

            await MainActor.run {
                let now = Date()
                venueGameCardSnapshotStore.setSnapshot(
                    VenueGameCardGoingSnapshot(
                        isCurrentUserGoing: currentUserIsGoing,
                        goingCount: count,
                        goingAvatarProfiles: eventProfiles,
                        reconcileStatus: .idle,
                        lastGoingUpdatedAt: now,
                        lastAvatarUpdatedAt: now
                    ),
                    for: venueEventID
                )
#if DEBUG
                let avatarCount = eventProfiles
                    .filter { $0.isFanVisibleForLivePresence(to: currentUserAuthId) }
                    .count
                print(
                    "[VenueGameCardStoreDebug] goingRefreshSucceeded eventId=\(venueEventID.uuidString.lowercased()) count=\(count) avatarCount=\(avatarCount)"
                )
                print(
                    "[VenueGameCardStoreDebug] goingStateUpdated eventId=\(venueEventID.uuidString.lowercased())"
                )
#endif
            }
        } catch {
            await MainActor.run {
                let existing = venueGameCardSnapshotStore.snapshot(for: venueEventID)
                venueGameCardSnapshotStore.setSnapshot(
                    VenueGameCardGoingSnapshot(
                        isCurrentUserGoing: existing?.isCurrentUserGoing
                            ?? isInterestedInVenueEvent(venueEventID),
                        goingCount: existing?.goingCount
                            ?? venueEventInterestCounts[venueEventID]
                            ?? followingTabGoingInterestCounts[venueEventID]
                            ?? 0,
                        goingAvatarProfiles: existing?.goingAvatarProfiles
                            ?? goingProfilesByVenueEventID[venueEventID]
                            ?? [],
                        reconcileStatus: .failed(error.localizedDescription),
                        lastGoingUpdatedAt: existing?.lastGoingUpdatedAt,
                        lastAvatarUpdatedAt: existing?.lastAvatarUpdatedAt
                    ),
                    for: venueEventID
                )
            }
        }
    }

    private func resolvedInitialVenueGameCardGoingRefreshIDs() -> [UUID] {
        guard let bar = selectedBar else { return [] }
        let selectedSportFilter = selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)

        let matchingRows = venueEventRows.filter { row in
            guard row.id != nil else { return false }
            guard venueGameCardVenueEventRow(row, matches: bar) else { return false }
            guard VenueGameExpiration.isActiveOnDiscoverSurfaces(row: row) else { return false }

            if let adminStatus = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !adminStatus.isEmpty,
               adminStatus != "active" {
                return false
            }

            if !selectedSportFilter.isEmpty, selectedSportFilter != "All" {
                let rowSport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard rowSport == selectedSportFilter else { return false }
            }

            return true
        }
        .sorted { lhs, rhs in
            let lhsDate = lhs.event_date ?? ""
            let rhsDate = rhs.event_date ?? ""
            if lhsDate != rhsDate { return lhsDate < rhsDate }

            let lhsStart = lhs.scheduled_start_at ?? ""
            let rhsStart = rhs.scheduled_start_at ?? ""
            if lhsStart != rhsStart { return lhsStart < rhsStart }

            let lhsTime = lhs.event_time ?? ""
            let rhsTime = rhs.event_time ?? ""
            if lhsTime != rhsTime { return lhsTime < rhsTime }

            let lhsTitle = lhs.event_title ?? ""
            let rhsTitle = rhs.event_title ?? ""
            if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }

            return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
        }

        var seen: Set<UUID> = []
        var ids: [UUID] = []
        ids.reserveCapacity(min(matchingRows.count, 12))
        for row in matchingRows {
            guard let id = row.id, seen.insert(id).inserted else { continue }
            ids.append(id)
            if ids.count >= 12 { break }
        }
        return ids
    }

    private func venueGameCardGoingSnapshotNeedsInitialRefresh(
        eventID: UUID,
        snapshot: VenueGameCardGoingSnapshot?,
        now: Date
    ) -> Bool {
        let hasSnapshot = snapshot != nil
        let lastUpdated = [snapshot?.lastGoingUpdatedAt, snapshot?.lastAvatarUpdatedAt]
            .compactMap { $0 }
            .max()
        let ageSeconds = lastUpdated.map { max(0, Int(now.timeIntervalSince($0))) }
        let count = snapshot?.goingCount ?? 0
        let avatarCount = snapshot?.goingAvatarProfiles.count ?? 0
        let hasSuccessfulLoad = snapshot?.reconcileStatus == .idle
            && snapshot?.lastGoingUpdatedAt != nil
            && snapshot?.lastAvatarUpdatedAt != nil
        let isFresh = ageSeconds.map { TimeInterval($0) < venueGameCardGoingSnapshotTTL } ?? false
        let missingAvatarData = count > 0 && avatarCount == 0
        let needsRefresh = !hasSnapshot
            || !hasSuccessfulLoad
            || !isFresh
            || missingAvatarData
#if DEBUG
        let ageText = ageSeconds.map(String.init) ?? "nil"
        print(
            "[VenueGameCardStoreDebug] freshnessCheck eventId=\(eventID.uuidString.lowercased()) hasSnapshot=\(hasSnapshot) ageSeconds=\(ageText) count=\(count) avatarCount=\(avatarCount) needsRefresh=\(needsRefresh)"
        )
#endif
        return needsRefresh
    }

    private func venueGameCardVenueEventRow(_ row: VenueEventRow, matches bar: BarVenue) -> Bool {
        if let venueID = row.venue_id, venueID == bar.id { return true }

        let rowName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rowName.isEmpty, rowName.caseInsensitiveCompare(bar.name) == .orderedSame {
            return true
        }

        let rowOwner = OwnerBusinessEmail.normalized(row.owner_email ?? "")
        let barOwner = OwnerBusinessEmail.normalized(bar.ownerEmail ?? "")
        return OwnerBusinessEmail.isValidStrict(rowOwner) && rowOwner == barOwner
    }

    private func venueGameCardBar(for barID: UUID) -> BarVenue? {
        if let selectedBar, selectedBar.id == barID {
            return selectedBar
        }
        if let bar = bars.first(where: { $0.id == barID }) {
            return bar
        }
        if let bar = filteredBars.first(where: { $0.id == barID }) {
            return bar
        }
        if let bar = followingTabSavedVenues.first(where: { $0.id == barID }) {
            return bar
        }
        return nil
    }

    private func venueGameCardTopVibeText(from counts: [String: Int]) -> String? {
        guard let top = counts.max(by: { $0.value < $1.value }),
              top.value > 0 else {
            return nil
        }

        switch top.key {
        case "audio_on":
            return "Audio confirmed - \(top.value)"
        case "packed":
            return "Packed - \(top.value)"
        case "seats_open":
            return "Seats open - \(top.value)"
        case "specials":
            return "Specials - \(top.value)"
        case "tv_visible":
            return "TVs visible - \(top.value)"
        case "crowd":
            return "Crowd checked - \(top.value)"
        default:
            return nil
        }
    }

    private func venueGameCardCurrentUserProfileRow() -> UserProfileRow? {
        guard let id = currentUserAuthId else { return nil }
        let email = OwnerBusinessEmail.normalized(currentUserEmail)
        let displayName = currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        return UserProfileRow(
            id: id,
            email: email.isEmpty ? nil : email,
            display_name: displayName.isEmpty ? nil : displayName,
            username: handle.isEmpty ? nil : handle,
            bio: nil,
            avatar_url: ImageDisplayURL.canonicalStorageURLString(currentUserAvatarURL),
            avatar_thumbnail_url: ImageDisplayURL.canonicalStorageURLString(currentUserAvatarThumbnailURL),
            is_business_account: false,
            admin_status: "active",
            live_visibility_enabled: true,
            live_visibility_mode: LiveVisibilityMode.allFriends.rawValue,
            selected_live_visibility_friend_ids: nil,
            discoverable_by_fans: true,
            created_at: nil,
            national_team_country_code: currentUserNationalTeam?.countryCode,
            national_team_country_name: currentUserNationalTeam?.countryName,
            national_team_flag: currentUserNationalTeam?.flag,
            national_team_supporter_label: currentUserNationalTeam?.supporterLabel,
            national_team_updated_at: nil
        )
    }

    private func venueGameCardProfile(
        _ lhs: UserProfileRow,
        matchesCurrentUserProfile rhs: UserProfileRow
    ) -> Bool {
        if let lhsID = lhs.id, let rhsID = rhs.id, lhsID == rhsID {
            return true
        }
        let lhsEmail = OwnerBusinessEmail.normalized(lhs.email ?? "")
        let rhsEmail = OwnerBusinessEmail.normalized(rhs.email ?? "")
        return OwnerBusinessEmail.isValidStrict(lhsEmail) && lhsEmail == rhsEmail
    }
}

private extension VenueGameCardState {
    static let emptyLiveEnergy = FanGeoLiveEnergy(
        isLiveNow: false,
        startsSoon: false,
        minutesUntilStart: nil,
        goingCount: 0,
        commentCount: 0,
        friendGoingCount: 0,
        friendAvatarURLs: [],
        mutualTeamLabel: nil,
        energyLabel: nil,
        energySubtitle: nil,
        friendPresenceLabel: nil,
        friendProfiles: [],
        socialPresenceProfiles: [],
        socialPresenceLabel: nil
    )
}

