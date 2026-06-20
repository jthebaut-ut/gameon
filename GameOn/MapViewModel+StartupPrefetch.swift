import CoreLocation
import Foundation
import Supabase

extension MapViewModel {
    private static let lightweightStartupPrefetchTTL: TimeInterval = 120
    private static let followingTodayPlansPrefetchTTL: TimeInterval = 45

    func prefetchLightweightUserDataForStartup() async {
        if let inFlight = lightweightStartupPrefetchTask {
#if DEBUG
            print("[StartupPrefetchDebug] coalesced=true")
            print("[StartupPrefetchDebug] skippedReason=inFlight")
#endif
            await inFlight.value
            return
        }
        if let lastLightweightStartupPrefetchAt,
           Date().timeIntervalSince(lastLightweightStartupPrefetchAt) < Self.lightweightStartupPrefetchTTL {
            await refreshCurrentUserAdFreeEntitlementFromServer(reason: "startupPrefetchFreshCache")
#if DEBUG
            print("[StartupPrefetchDebug] started=false")
            print("[StartupPrefetchDebug] skippedReason=freshCache")
            print("[StartupPrefetchDebug] completed=true")
            print("[StartupPrefetchDebug] totalMs=0")
#endif
            return
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runLightweightStartupPrefetch()
        }
        lightweightStartupPrefetchTask = task
        await task.value
        lightweightStartupPrefetchTask = nil
    }

    private func runLightweightStartupPrefetch() async {
        let startedAt = Date()
#if DEBUG
        print("[StartupPrefetchDebug] started=true")
#endif
        var profileLoaded = false
        var goingLoaded = false
        var favoriteTeamsLoaded = false
        var avatarPrefetched = false

        switch await supabaseResolvedAuthSessionResult() {
        case .active:
            break
        case .missingSession:
            await markTransientMissingSessionPreserved(
                reason: "startupPrefetchMissingSession",
                source: "MapViewModel.runLightweightStartupPrefetch"
            )
#if DEBUG
            print("[BusinessLogoutTrace] warmPreloadSkippedNoLogout=true")
#endif
            logStartupPrefetchCompletion(
                startedAt: startedAt,
                profileLoaded: false,
                avatarPrefetched: false,
                goingLoaded: false,
                favoriteTeamsLoaded: false,
                skippedReason: "missingSessionDuringRestore"
            )
            return
        case .refreshFailed(let error):
#if DEBUG
            print("[AuthStateDebug] tokenRefreshFailed=true reason=startupPrefetch error=\(error.localizedDescription)")
#endif
            await MainActor.run {
                authSessionState = .authRefreshFailed
#if DEBUG
                print("[AuthStateDebug] authStateTransition=startupPrefetch->authRefreshFailed")
#endif
            }
            logStartupPrefetchCompletion(
                startedAt: startedAt,
                profileLoaded: false,
                avatarPrefetched: false,
                goingLoaded: false,
                favoriteTeamsLoaded: false,
                skippedReason: "authRefreshFailed"
            )
            return
        }

        guard await checkCurrentUserAdminStatus() else {
            logStartupPrefetchCompletion(
                startedAt: startedAt,
                profileLoaded: false,
                avatarPrefetched: false,
                goingLoaded: false,
                favoriteTeamsLoaded: false,
                skippedReason: "adminStatusBlocked"
            )
            return
        }

        let skipPersonalization = await MainActor.run { isAdminLoggedIn }
        guard !skipPersonalization else {
            logStartupPrefetchCompletion(
                startedAt: startedAt,
                profileLoaded: false,
                avatarPrefetched: false,
                goingLoaded: false,
                favoriteTeamsLoaded: false,
                skippedReason: "adminSession"
            )
            return
        }

        await MainActor.run {
            beginProfilePresentationLoad()
        }
        await ensureUserProfileExists()
        await loadUserProfile()
        profileLoaded = await MainActor.run { hasLoadedUserProfileForPresentation }
        avatarPrefetched = await MainActor.run {
            !currentUserAvatarThumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !currentUserAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || UserDefaults.standard.string(forKey: "cachedUserAvatarThumbnailURL")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || UserDefaults.standard.string(forKey: "cachedUserAvatarURL")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        await loadFavoriteVenuesFromSupabase()
        await loadFavoriteTeamsFromSupabase()
        favoriteTeamsLoaded = true
        await refreshFollowingTodayVenueEventPlansLightweight()
        goingLoaded = true

        await loadFanIdentityPreferencesFromProfile()
        await loadHomeCrowdFromProfile()
        await enforceFanSingleSessionOnForeground()
        await startFanSingleSessionRealtimeIfNeeded()
        await loadPendingPickupGameJoinRequestCountForCreator()
        await ensurePickupInviteRealtimeIfNeeded()

        await MainActor.run {
            lastLightweightStartupPrefetchAt = Date()
        }
        logStartupPrefetchCompletion(
            startedAt: startedAt,
            profileLoaded: profileLoaded,
            avatarPrefetched: avatarPrefetched,
            goingLoaded: goingLoaded,
            favoriteTeamsLoaded: favoriteTeamsLoaded,
            skippedReason: nil
        )
    }

    private func logStartupPrefetchCompletion(
        startedAt: Date,
        profileLoaded: Bool,
        avatarPrefetched: Bool,
        goingLoaded: Bool,
        favoriteTeamsLoaded: Bool,
        skippedReason: String?
    ) {
#if DEBUG
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("[StartupPrefetchDebug] profilePrefetched=\(profileLoaded)")
        print("[StartupPrefetchDebug] avatarPrefetched=\(avatarPrefetched)")
        print("[StartupPrefetchDebug] goingLoaded=\(goingLoaded)")
        print("[StartupPrefetchDebug] favoriteTeamsPrefetched=\(favoriteTeamsLoaded)")
        print("[StartupPrefetchDebug] skippedReason=\(skippedReason ?? "none")")
        print("[StartupPrefetchDebug] completed=true")
        print("[StartupPrefetchDebug] totalMs=\(durationMs)")
#endif
    }

    func warmPreloadRegionalDiscoverCaches(chatViewModel: ChatViewModel) async {
        let startedAt = Date()
        print("[StartupWarmCache] regionalWarmStart mode=\(discoverMapContentMode.rawValue) sport=\(selectedSport)")

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                if self.bars.isEmpty {
                    print("[StartupWarmCache] task=nearbyVenues cacheHit=false")
                    await self.refreshDiscoverCoreInBackground()
                } else {
                    print("[StartupWarmCache] task=nearbyVenues cacheHit=true rows=\(self.bars.count)")
                    guard self.discoverMapContentMode == .venues else { return }
                    let requestID = UUID()
                    self.discoverSelectedDayRefreshRequestID = requestID
                    await self.refreshDiscoverSelectedDayVenueEventsForCurrentContext(requestID: requestID)
                }
            }

            group.addTask { @MainActor [weak self] in
                guard let self, self.canFanUsePickupGamesUI else {
                    print("[StartupWarmCache] task=pickupGames skipped reason=featureUnavailable")
                    return
                }
                await self.warmPreloadPickupGamesForCurrentContext()
            }

            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                await self.warmPreloadPickupPlacesForCurrentRegion()
            }

            group.addTask { @MainActor [weak self, weak chatViewModel] in
                guard let self, let chatViewModel else { return }
                guard self.isAuthenticatedForSocialFeatures else {
                    print("[StartupWarmCache] task=notificationBadges skipped reason=notAuthenticated")
                    return
                }
                let chatResult = await chatViewModel.prefetchLightweightStartupChatData()
                if self.canFanUsePickupGamesUI {
                    await self.loadIncomingPickupGameInvites()
                }
                print("[StartupWarmCache] task=notificationBadges skippedReason=\(chatResult.skippedReason ?? "none")")
            }
        }

        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("[StartupWarmCache] regionalWarmEnd ms=\(ms)")
    }

    func refreshFollowingTodayVenueEventPlansLightweight(forceRefresh: Bool = false) async {
        if !forceRefresh, let inFlight = followingTodayPlansLoadTask {
            await inFlight.value
            return
        }
        if !forceRefresh,
           let lastFollowingTodayPlansLoadAt,
           Date().timeIntervalSince(lastFollowingTodayPlansLoadAt) < Self.followingTodayPlansPrefetchTTL {
            return
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.loadFollowingTodayVenueEventPlansLightweightNow()
        }
        followingTodayPlansLoadTask = task
        await task.value
        followingTodayPlansLoadTask = nil
    }

    private func loadFollowingTodayVenueEventPlansLightweightNow() async {
        guard let interestEmail = await strictNormalizedSessionEmailForSocialTables() else { return }
        do {
            let interestRows: [VenueEventInterestRow] = try await supabase
                .from("venue_event_interests")
                .select("venue_event_id")
                .eq("user_email", value: interestEmail)
                .execute()
                .value

            let localInterestedOnly = Self.followingInterestedOnlyVenueEventIDsFromUserDefaults()
            let eventIDs = Set(interestRows.compactMap(\.venue_event_id)).union(localInterestedOnly)
            guard !eventIDs.isEmpty else {
                followingTabGoingItems = []
                followingTabGoingInterestCounts = [:]
                followingTabUserVenueEventInterestIDs = []
                lastFollowingTodayPlansLoadAt = Date()
                return
            }

            let today = Self.startupPrefetchDateFormatter.string(from: Date())
            let rows: [VenueEventRow] = try await supabase
                .from("venue_events")
                .select("id,venue_id,owner_email,venue_name,event_title,sport,home_team,away_team,event_date,event_time,scheduled_start_at,cleanup_delay_hours,purge_after_at,external_league,external_game_id,external_source,imported_from_api")
                .in("id", values: eventIDs.map { $0.uuidString.lowercased() })
                .eq("admin_status", value: "active")
                .gte("event_date", value: today)
                .limit(60)
                .execute()
                .value

            let serverIDs = Set(interestRows.compactMap(\.venue_event_id)).subtracting(localInterestedOnly)
            let items = rows.compactMap { row -> FollowingGoingDisplayItem? in
                guard let id = row.id else { return nil }
                return FollowingGoingDisplayItem(
                    id: id,
                    venueEvent: row,
                    bar: Self.startupPrefetchPlaceholderBar(for: row),
                    attendeeCount: serverIDs.contains(id) ? 1 : 0,
                    isServerGoing: serverIDs.contains(id),
                    isInterestedOnlyLocal: localInterestedOnly.contains(id)
                )
            }

            followingTabGoingItems = Self.sortFollowingGoingItemsChronologically(items)
            followingTabGoingInterestCounts = Dictionary(
                uniqueKeysWithValues: items.map { ($0.id, $0.attendeeCount) }
            )
            followingTabUserVenueEventInterestIDs = serverIDs
            lastFollowingTodayPlansLoadAt = Date()
#if DEBUG
            print("[StartupPrefetchDebug] goingLoaded=true")
#endif
        } catch {
#if DEBUG
            print("[StartupPrefetchDebug] goingLoaded=false")
#endif
        }
    }

    private static let startupPrefetchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static func startupPrefetchPlaceholderBar(for row: VenueEventRow) -> BarVenue {
        let venueName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let eventTitle = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return BarVenue(
            id: row.venue_id ?? UUID(),
            name: venueName.isEmpty ? "Venue" : venueName,
            address: "Address unavailable",
            phone: "",
            primarySport: sport,
            distance: "",
            rating: 0,
            tags: [],
            games: eventTitle.isEmpty ? [] : [eventTitle],
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
}
