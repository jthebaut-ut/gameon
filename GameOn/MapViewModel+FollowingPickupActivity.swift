import Foundation
import Supabase

// MARK: - Following → Games to Play (activity, refresh cadence, requester realtime)

extension MapViewModel {

    func resetPickupFollowingActivityStateForCacheClear() {
        hasUnreadPickupActivity = false
        pickupActivityCount = 0
        lastJoinStatusRefreshAt = nil
        lastKnownJoinStatus = [:]
        pickupFollowingUnreadActivityGameIds = []
        pickupFollowingCardRefreshSpinGameId = nil
        pickupFollowingActivityPrimed = false
        pickupFollowingSeenActivitySignatureByGameId.removeAll()
        Task { await stopFollowingPickupRealtime() }
    }

    /// Call when user opens **Games to Play** segment (Following).
    func acknowledgePickupFollowingGamesToPlayActivity() {
        pickupFollowingUnreadActivityGameIds.removeAll()
        var nextSeen: [UUID: String] = [:]
        var seenGame: Set<UUID> = []
        for c in myPickupGameJoinRequestCards {
            guard !seenGame.contains(c.pickupGameId) else { continue }
            seenGame.insert(c.pickupGameId)
            guard let g = pickupGamesFollowingTabCache[c.pickupGameId] else { continue }
            let join = lastKnownJoinStatus[c.pickupGameId] ?? Self.joinStatusTokenFromPill(c.pill)
            nextSeen[c.pickupGameId] = Self.pickupFollowingActivitySignature(
                game: g,
                joinStatus: join,
                spotsSummary: c.spotsRemainingSummary
            )
        }
        pickupFollowingSeenActivitySignatureByGameId = nextSeen
        hasUnreadPickupActivity = false
        pickupActivityCount = 0
#if DEBUG
        print("[PickupFollowingActivity] acknowledged gamesToPlay unreadCleared=true")
#endif
    }

    func pickupFollowingCaptureActivityBaseline() -> [UUID: String] {
        var map: [UUID: String] = [:]
        var seenGame: Set<UUID> = []
        for c in myPickupGameJoinRequestCards {
            guard !seenGame.contains(c.pickupGameId) else { continue }
            seenGame.insert(c.pickupGameId)
            guard let g = pickupGamesFollowingTabCache[c.pickupGameId] else { continue }
            let join = lastKnownJoinStatus[c.pickupGameId] ?? Self.joinStatusTokenFromPill(c.pill)
            map[c.pickupGameId] = Self.pickupFollowingActivitySignature(
                game: g,
                joinStatus: join,
                spotsSummary: c.spotsRemainingSummary
            )
        }
        return map
    }

    func pickupFollowingApplyActivityAfterJoinListLoad(
        baseline: [UUID: String],
        wasPrimed: Bool,
        cards: [PickupGameJoinRequestCardDisplay],
        gameById: [UUID: PickupGameRow],
        statusByGameId: [UUID: String]
    ) {
        lastKnownJoinStatus = statusByGameId
        lastJoinStatusRefreshAt = Date()

        var firstCardByGame: [UUID: PickupGameJoinRequestCardDisplay] = [:]
        for c in cards {
            if firstCardByGame[c.pickupGameId] != nil { continue }
            firstCardByGame[c.pickupGameId] = c
        }

        if !wasPrimed {
            pickupFollowingActivityPrimed = true
            var seed: [UUID: String] = [:]
            for (_, c) in firstCardByGame {
                guard let g = gameById[c.pickupGameId] else { continue }
                let join = statusByGameId[c.pickupGameId] ?? Self.joinStatusTokenFromPill(c.pill)
                seed[c.pickupGameId] = Self.pickupFollowingActivitySignature(
                    game: g,
                    joinStatus: join,
                    spotsSummary: c.spotsRemainingSummary
                )
            }
            pickupFollowingSeenActivitySignatureByGameId = seed
            pickupFollowingUnreadActivityGameIds.removeAll()
            hasUnreadPickupActivity = false
            pickupActivityCount = 0
#if DEBUG
            print("[PickupFollowingActivity] first_load seedGames=\(seed.count)")
#endif
            return
        }

        var changed: Set<UUID> = []
        for (gid, c) in firstCardByGame {
            guard let g = gameById[gid] else { continue }
            let join = statusByGameId[gid] ?? Self.joinStatusTokenFromPill(c.pill)
            let sig = Self.pickupFollowingActivitySignature(game: g, joinStatus: join, spotsSummary: c.spotsRemainingSummary)
            if let old = baseline[gid] {
                if old != sig { changed.insert(gid) }
            } else {
                changed.insert(gid)
            }
        }
        for gid in baseline.keys where firstCardByGame[gid] == nil {
            changed.insert(gid)
        }

        for gid in changed {
            guard let c = firstCardByGame[gid], let g = gameById[gid] else {
                pickupFollowingUnreadActivityGameIds.insert(gid)
                continue
            }
            let join = statusByGameId[gid] ?? Self.joinStatusTokenFromPill(c.pill)
            let currentSig = Self.pickupFollowingActivitySignature(game: g, joinStatus: join, spotsSummary: c.spotsRemainingSummary)
            let seen = pickupFollowingSeenActivitySignatureByGameId[gid]
            if seen != currentSig {
                pickupFollowingUnreadActivityGameIds.insert(gid)
            }
        }
        pickupActivityCount = pickupFollowingUnreadActivityGameIds.count
        hasUnreadPickupActivity = pickupActivityCount > 0
#if DEBUG
        print("[PickupFollowingActivity] changed=\(changed.count) unread=\(pickupActivityCount)")
#endif
    }

    /// Pull-to-refresh on Following scroll or timer / foreground.
    func performPickupFollowingJoinListRefresh(isUserPull: Bool) async {
#if DEBUG
        print("[PickupJoinRefresh] trigger=\(isUserPull ? "pull" : "auto_or_foreground")")
#endif
        await loadMyPickupGameJoinRequestsForFollowing()
    }

    /// Per-card refresh (Games to Play row).
    func refreshPickupFollowingJoinCard(pickupGameId: UUID) async {
#if DEBUG
        print("[PickupJoinRefresh] manual card gameId=\(pickupGameId.uuidString.lowercased())")
#endif
        pickupFollowingUnreadActivityGameIds.remove(pickupGameId)
        if let game = pickupGamesFollowingTabCache[pickupGameId],
           let card = myPickupGameJoinRequestCards.first(where: { $0.pickupGameId == pickupGameId }) {
            let join = lastKnownJoinStatus[pickupGameId] ?? Self.joinStatusTokenFromPill(card.pill)
            pickupFollowingSeenActivitySignatureByGameId[pickupGameId] = Self.pickupFollowingActivitySignature(
                game: game,
                joinStatus: join,
                spotsSummary: card.spotsRemainingSummary
            )
        }
        pickupFollowingCardRefreshSpinGameId = pickupGameId
        await loadMyPickupGameJoinRequestsForFollowing()
        pickupFollowingCardRefreshSpinGameId = nil
        pickupActivityCount = pickupFollowingUnreadActivityGameIds.count
        hasUnreadPickupActivity = pickupActivityCount > 0
    }

    func stopFollowingPickupRealtime() async {
        pickupFollowingRealtimeDebounceTask?.cancel()
        pickupFollowingRealtimeDebounceTask = nil
        if let t = pickupFollowingRealtimeTask {
            t.cancel()
            _ = await t.result
            pickupFollowingRealtimeTask = nil
        }
        if let ch = pickupFollowingRealtimeChannel {
            await supabase.removeChannel(ch)
            pickupFollowingRealtimeChannel = nil
        }
    }

    func scheduleFollowingPickupRealtimeDebouncedReload() {
        pickupFollowingRealtimeDebounceTask?.cancel()
        pickupFollowingRealtimeDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
#if DEBUG
            print("[PickupRealtimeUpdate] debounced_reload")
#endif
            await self.loadMyPickupGameJoinRequestsForFollowing()
        }
    }

    func syncFollowingPickupRealtimeSubscriptionIfNeeded(gameIds: [UUID]) async {
        let unique = Array(Set(gameIds))
        guard canFanUsePickupGamesUI, let uid = currentUserAuthId, !unique.isEmpty else {
            await stopFollowingPickupRealtime()
            return
        }
        let capped = Array(unique.prefix(120)).sorted { $0.uuidString < $1.uuidString }

        await stopFollowingPickupRealtime()

        pickupFollowingRealtimeTask = Task { [weak self] in
            guard let self else { return }
            await self.runFollowingPickupRealtimeLoop(userId: uid, gameIds: capped)
        }
    }

    private func runFollowingPickupRealtimeLoop(userId: UUID, gameIds: [UUID]) async {
        guard !Task.isCancelled, !gameIds.isEmpty else { return }

        let channel = supabase.channel("pickup-following-requester-\(userId.uuidString.lowercased())")
        pickupFollowingRealtimeChannel = channel

        let requesterFilter = RealtimePostgresFilter.eq("requester_user_id", value: userId.uuidString.lowercased())
        let requestStream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "pickup_game_requests",
            filter: requesterFilter
        )

        let gameFilter = RealtimePostgresFilter.in("id", values: gameIds)
        let gameStream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "pickup_games",
            filter: gameFilter
        )

        do {
            #if DEBUG
            print("[RealtimePublicationVerify] expected table=pickup_games publication=supabase_realtime migration=20260731_0030")
            #endif
            try await channel.subscribeWithError()
        } catch {
            if pickupFollowingRealtimeChannel === channel {
                pickupFollowingRealtimeChannel = nil
            }
#if DEBUG
            print("[PickupRealtimeUpdate] subscribe_failed error=\(String(describing: error))")
#endif
            return
        }

#if DEBUG
        print("[PickupRealtimeUpdate] subscribed games=\(gameIds.count)")
#endif

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                for await _ in requestStream {
                    if Task.isCancelled { break }
#if DEBUG
                    print("[PickupRealtimeUpdate] event=requests")
#endif
                    await MainActor.run { self.scheduleFollowingPickupRealtimeDebouncedReload() }
                }
            }
            group.addTask { [weak self] in
                guard let self else { return }
                for await _ in gameStream {
                    if Task.isCancelled { break }
#if DEBUG
                    print("[PickupRealtimeUpdate] event=pickup_games")
#endif
                    await MainActor.run { self.scheduleFollowingPickupRealtimeDebouncedReload() }
                }
            }
        }

        if pickupFollowingRealtimeChannel === channel {
            await supabase.removeChannel(channel)
            pickupFollowingRealtimeChannel = nil
        }
    }

    // MARK: - Signatures

    static func joinStatusTokenFromPill(_ pill: PickupFollowingJoinRequestPillKind) -> String {
        switch pill {
        case .pending: return "pending"
        case .approved: return "approved"
        case .declined: return "rejected"
        case .cancelled: return "cancelled"
        case .withdrawing: return "withdrawing"
        case .canceledByOrganizer: return "canceled_by_organizer"
        }
    }

    static func pickupFollowingActivitySignature(
        game: PickupGameRow,
        joinStatus: String,
        spotsSummary: String?
    ) -> String {
        let spotsKey = spotsSummary ?? ""
        let appr = game.approved_join_count ?? -1
        return "\(joinStatus)|\(game.status)|\(game.title)|\(appr)|\(spotsKey)|\(game.game_start_at)|\(game.is_visible)|\(game.players_needed)"
    }
}
