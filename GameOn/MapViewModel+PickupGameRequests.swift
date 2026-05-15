import Foundation
import Supabase

private let pickupGameRequestsSelectColumns =
    "id,pickup_game_id,requester_user_id,requester_email,requester_display_name,requester_skill_level,message,status,created_at,updated_at,responded_at"

private struct PickupGameRequestStatusOnly: Decodable {
    let pickup_game_id: UUID
    let status: String
}

extension MapViewModel {

    func resolvedPickupGameRow(for id: UUID) -> PickupGameRow? {
        if let s = selectedPickupGameForMap, s.id == id { return s }
        if let m = pickupGamesForDiscoverMap.first(where: { $0.id == id }) { return m }
        if let m = myPickupGamesForSettings.first(where: { $0.id == id }) { return m }
        return pickupGamesFollowingTabCache[id]
    }

    func refreshPickupJoinCachesAfterMutation() {
#if DEBUG
        print("[PickupRequest] caches refreshed")
#endif
        pickupGameCalendarDotDatesCache.removeAll()
        invalidatePickupGameClusterAnnotationCache()
    }

    /// Loads `user_profiles` display name + avatar URLs + email for pickup detail (existing columns only).
    func loadPickupCreatorDisplayNameIfNeeded(creatorUserId: UUID) async {
        let shouldFetch = await MainActor.run { () -> Bool in
            if pickupCreatorAvatarTokenByUserId[creatorUserId] != nil {
                return false
            }
            pickupCreatorAvatarTokenByUserId[creatorUserId] = UUID()
            return true
        }
        guard shouldFetch else { return }

        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select("id,email,display_name,avatar_url,avatar_thumbnail_url")
                .eq("id", value: creatorUserId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            let row = rows.first
            let name = row?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let email = row?.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let full = ImageDisplayURL.canonicalStorageURLString(row?.avatar_url)
            let thumb = ImageDisplayURL.canonicalStorageURLString(row?.avatar_thumbnail_url)
            await MainActor.run {
                pickupCreatorDisplayNameByUserId[creatorUserId] = name
                pickupCreatorEmailByUserId[creatorUserId] = email
                pickupCreatorAvatarURLByUserId[creatorUserId] = full
                pickupCreatorAvatarThumbnailURLByUserId[creatorUserId] = thumb
            }
        } catch {
            await MainActor.run {
                pickupCreatorDisplayNameByUserId[creatorUserId] = ""
                pickupCreatorEmailByUserId[creatorUserId] = ""
                pickupCreatorAvatarURLByUserId[creatorUserId] = ""
                pickupCreatorAvatarThumbnailURLByUserId[creatorUserId] = ""
            }
        }
    }

    func pickupCreatorDisplayLabel(for userId: UUID) -> String? {
        guard let v = pickupCreatorDisplayNameByUserId[userId] else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func pickupOrganizerAvatarThumbnailForDetail(userId: UUID) -> String? {
        let s = pickupCreatorAvatarThumbnailURLByUserId[userId] ?? ""
        return s.isEmpty ? nil : s
    }

    func pickupOrganizerAvatarFullForDetail(userId: UUID) -> String {
        pickupCreatorAvatarURLByUserId[userId] ?? ""
    }

    func pickupOrganizerAvatarRefreshTokenForDetail(userId: UUID) -> UUID {
        pickupCreatorAvatarTokenByUserId[userId]
            ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    }

    func pickupOrganizerEmailForDetail(userId: UUID) -> String {
        (pickupCreatorEmailByUserId[userId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Latest join request from the current user for this game (by `created_at` desc).
    func loadMyLatestJoinRequestForPickupGame(pickupGameId: UUID) async {
        guard let uid = currentUserAuthId, isAuthenticatedForSocialFeatures else { return }
        do {
            let rows: [PickupGameRequestRow] = try await supabase
                .from("pickup_game_requests")
                .select(pickupGameRequestsSelectColumns)
                .eq("pickup_game_id", value: pickupGameId.uuidString.lowercased())
                .eq("requester_user_id", value: uid.uuidString.lowercased())
                .order("created_at", ascending: false)
                .limit(12)
                .execute()
                .value
            pickupMyLatestJoinRequestByGameId[pickupGameId] = rows.first
        } catch {
            pickupMyLatestJoinRequestByGameId[pickupGameId] = nil
        }
    }

    func refreshPickupMyJoinRequestsForDiscoverGames(gameIds: [UUID]) async {
        guard let uid = currentUserAuthId, isAuthenticatedForSocialFeatures else { return }
        let unique = Array(Set(gameIds))
        guard !unique.isEmpty else { return }
        do {
            let rows: [PickupGameRequestRow] = try await supabase
                .from("pickup_game_requests")
                .select(pickupGameRequestsSelectColumns)
                .eq("requester_user_id", value: uid.uuidString.lowercased())
                .in("pickup_game_id", values: unique)
                .order("created_at", ascending: false)
                .limit(800)
                .execute()
                .value
            var latest: [UUID: PickupGameRequestRow] = [:]
            for r in rows {
                if latest[r.pickup_game_id] != nil { continue }
                latest[r.pickup_game_id] = r
            }
            for id in unique {
                if latest[id] == nil {
                    pickupMyLatestJoinRequestByGameId.removeValue(forKey: id)
                }
            }
            for (k, v) in latest {
                pickupMyLatestJoinRequestByGameId[k] = v
            }
        } catch {
            // Leave existing cache; Discover still works.
        }
    }

    func loadOrganizerPickupRequestSummaries(gameIds: [UUID]) async {
        guard canFanUsePickupGamesUI else {
            pickupOrganizerJoinStatsByGameId = [:]
            return
        }
        guard !gameIds.isEmpty else { return }

        var next: [UUID: PickupOrganizerJoinStats] = [:]
        for gid in gameIds {
            next[gid] = PickupOrganizerJoinStats(pending: 0, approved: 0)
        }
        do {
            let rows: [PickupGameRequestStatusOnly] = try await supabase
                .from("pickup_game_requests")
                .select("pickup_game_id,status")
                .in("pickup_game_id", values: gameIds)
                .limit(4000)
                .execute()
                .value
            for r in rows {
                var s = next[r.pickup_game_id] ?? PickupOrganizerJoinStats(pending: 0, approved: 0)
                if r.status == "pending" { s.pending += 1 }
                if r.status == "approved" { s.approved += 1 }
                next[r.pickup_game_id] = s
            }
        } catch {
#if DEBUG
            print("[PickupRequest] organizer summary load failed:", error)
#endif
        }
        var merged = pickupOrganizerJoinStatsByGameId
        for (k, v) in next {
            merged[k] = v
        }
        pickupOrganizerJoinStatsByGameId = merged
    }

    /// Pending join requests for one owned pickup game (same cache as organizer Settings / per-row badges).
    func organizerPendingPickupJoinRequests(for gameId: UUID) -> Int {
        pickupOrganizerJoinStatsByGameId[gameId]?.pending ?? 0
    }

    func fetchOrganizerPickupRequests(pickupGameId: UUID) async throws -> [PickupGameRequestRow] {
        try await supabase
            .from("pickup_game_requests")
            .select(pickupGameRequestsSelectColumns)
            .eq("pickup_game_id", value: pickupGameId.uuidString.lowercased())
            .order("created_at", ascending: false)
            .limit(200)
            .execute()
            .value
    }

    /// Loads `user_profiles` rows for join requesters (Manage Requests sheet avatars).
    func loadPickupJoinRequesterProfilesForOrganizerSheet(requesterIds: Set<UUID>) async {
        guard !requesterIds.isEmpty else { return }
        for id in requesterIds where pickupJoinRequesterAvatarTokenByUserId[id] == nil {
            pickupJoinRequesterAvatarTokenByUserId[id] = UUID()
        }
        do {
            let ids = Array(requesterIds)
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select("id,email,display_name,avatar_url,avatar_thumbnail_url,is_business_account,admin_status")
                .in("id", values: ids.map { $0.uuidString.lowercased() })
                .limit(200)
                .execute()
                .value
            for r in rows {
                guard let id = r.id else { continue }
                pickupJoinRequesterProfileByUserId[id] = r
                pickupJoinRequesterAvatarTokenByUserId[id] = UUID()
            }
        } catch {
#if DEBUG
            print("[PickupRequest] organizer requester profile batch failed:", error)
#endif
        }
    }

    func createPickupJoinRequest(pickupGameId: UUID, requesterSkillLevel: String, message: String?) async throws {
        guard let uid = currentUserAuthId else {
            throw PickupGameClientError.notSignedIn
        }
        guard canJoinPickupGames else {
            logBusinessUserGateBlocked(action: "joinPickupGame")
            throw PickupGameClientError.businessAccountsCannotUsePickupGames
        }
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let msgPayload: String? = trimmed.isEmpty ? nil : String(trimmed.prefix(280))
        let display = pickupRequesterDisplayNamePayload()
        do {
            let inserted: [PickupGameRequestRow] = try await supabase
                .from("pickup_game_requests")
                .insert(
                    PickupGameRequestInsert(
                        pickup_game_id: pickupGameId,
                        requester_user_id: uid,
                        requester_email: nil,
                        requester_display_name: display,
                        requester_skill_level: requesterSkillLevel,
                        message: msgPayload
                    )
                )
                .select(pickupGameRequestsSelectColumns)
                .execute()
                .value
            guard let row = inserted.first else {
                throw PickupGameClientError.missingRowAfterWrite
            }
#if DEBUG
            print("[PickupRequest] request created game=\(pickupGameId.uuidString.lowercased())")
#endif
            pickupMyLatestJoinRequestByGameId[pickupGameId] = row
            refreshPickupJoinCachesAfterMutation()
            await refreshPickupGamesForDiscoverMap(force: true)
            recomputeCalendarDotDates()
            await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
            await loadMyPickupGameJoinRequestsForFollowing()
        } catch {
#if DEBUG
            print("[PickupRequest] request failed game=\(pickupGameId.uuidString.lowercased()) error=\(error)")
#endif
            throw error
        }
    }

    func cancelMyPickupJoinRequest(requestId: UUID, pickupGameId: UUID) async throws {
        guard canJoinPickupGames else {
            logBusinessUserGateBlocked(action: "joinPickupGame")
            throw PickupGameClientError.businessAccountsCannotUsePickupGames
        }
        try await supabase
            .from("pickup_game_requests")
            .update(PickupJoinRequestStatusUpdate(status: "cancelled"))
            .eq("id", value: requestId.uuidString.lowercased())
            .execute()
        await loadMyLatestJoinRequestForPickupGame(pickupGameId: pickupGameId)
        refreshPickupJoinCachesAfterMutation()
        await refreshPickupGamesForDiscoverMap(force: true)
        recomputeCalendarDotDates()
        await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
        await loadMyPickupGameJoinRequestsForFollowing()
    }

    func approvePickupJoinRequest(requestId: UUID, pickupGameId: UUID) async throws {
        guard canJoinPickupGames else {
            logBusinessUserGateBlocked(action: "joinPickupGame")
            throw PickupGameClientError.businessAccountsCannotUsePickupGames
        }
#if DEBUG
        print("[PickupRequest] approve requested id=\(requestId.uuidString.lowercased())")
#endif
        do {
            try await supabase
                .from("pickup_game_requests")
                .update(PickupJoinRequestStatusUpdate(status: "approved"))
                .eq("id", value: requestId.uuidString.lowercased())
                .execute()
            try await refreshPickupGameRowFromServerAndMerge(id: pickupGameId)
#if DEBUG
            print("[PickupRequest] approve completed id=\(requestId.uuidString.lowercased())")
#endif
            refreshPickupJoinCachesAfterMutation()
            await refreshPickupGamesForDiscoverMap(force: true)
            recomputeCalendarDotDates()
            await loadOrganizerPickupRequestSummaries(gameIds: [pickupGameId])
            await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
        } catch {
            if isPickupGameFullPostgresError(error) {
#if DEBUG
                print("[PickupRequest] game full id=\(pickupGameId.uuidString.lowercased())")
#endif
            }
            throw error
        }
    }

    func rejectPickupJoinRequest(requestId: UUID, pickupGameId: UUID) async throws {
        guard canJoinPickupGames else {
            logBusinessUserGateBlocked(action: "joinPickupGame")
            throw PickupGameClientError.businessAccountsCannotUsePickupGames
        }
#if DEBUG
        print("[PickupRequest] reject requested id=\(requestId.uuidString.lowercased())")
#endif
        try await supabase
            .from("pickup_game_requests")
            .update(PickupJoinRequestStatusUpdate(status: "rejected"))
            .eq("id", value: requestId.uuidString.lowercased())
            .execute()
#if DEBUG
        print("[PickupRequest] reject completed id=\(requestId.uuidString.lowercased())")
#endif
        try await refreshPickupGameRowFromServerAndMerge(id: pickupGameId)
        refreshPickupJoinCachesAfterMutation()
        await refreshPickupGamesForDiscoverMap(force: true)
        recomputeCalendarDotDates()
        await loadOrganizerPickupRequestSummaries(gameIds: [pickupGameId])
        await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
    }

    private func isPickupGameFullPostgresError(_ error: Error) -> Bool {
        let s = String(describing: error).lowercased()
        return s.contains("pickup_game_full")
    }

    private func pickupRequesterDisplayNamePayload() -> String? {
        let t = currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Re-fetch a single pickup game row (creator always readable) and merge into local caches.
    private func refreshPickupGameRowFromServerAndMerge(id: UUID) async throws {
        let rows: [PickupGameRow] = try await supabase
            .from("pickup_games")
            .select(pickupGamesSelectColumns)
            .eq("id", value: id.uuidString.lowercased())
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else {
            throw PickupGameClientError.missingRowAfterWrite
        }
        mergePickupInsertedLocally(row)
    }

    // MARK: - Organizer pending join requests (Account tab badge)

    /// Counts `pickup_game_requests` in `pending` status for active pickup games created by the current fan user.
    func loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: Bool = true) async {
        guard canFanUsePickupGamesUI, let uid = currentUserAuthId else {
            pendingPickupGameJoinRequestCount = 0
            await stopPickupJoinRequestBadgeRealtime()
            return
        }

        struct PickupGameIdOnlyRow: Decodable {
            let id: UUID
        }

        do {
            let rows: [PickupGameIdOnlyRow] = try await supabase
                .from("pickup_games")
                .select("id")
                .eq("creator_user_id", value: uid.uuidString.lowercased())
                .eq("status", value: "active")
                .limit(200)
                .execute()
                .value
            let ids = rows.map(\.id)
            guard !ids.isEmpty else {
                pendingPickupGameJoinRequestCount = 0
                await stopPickupJoinRequestBadgeRealtime()
                return
            }

            let response = try await supabase
                .from("pickup_game_requests")
                .select("id", count: .exact)
                .in("pickup_game_id", values: ids)
                .eq("status", value: "pending")
                .execute()
            pendingPickupGameJoinRequestCount = response.count ?? 0

            if resyncRealtimeSubscription {
                await syncPickupJoinRequestBadgeRealtimeSubscription(trackedGameIds: ids)
            }
        } catch {
#if DEBUG
            print("[PickupRequest] pending badge count load failed:", error)
#endif
        }
    }

    func stopPickupJoinRequestBadgeRealtime() async {
        pickupJoinRequestBadgeDebounceTask?.cancel()
        pickupJoinRequestBadgeDebounceTask = nil

        if let task = pickupJoinRequestBadgeRealtimeTask {
            task.cancel()
            _ = await task.result
            pickupJoinRequestBadgeRealtimeTask = nil
        }

        if let ch = pickupJoinRequestBadgeRealtimeChannel {
            await supabase.removeChannel(ch)
            pickupJoinRequestBadgeRealtimeChannel = nil
        }
    }

    func syncPickupJoinRequestBadgeRealtimeSubscription(trackedGameIds: [UUID]) async {
        let uniqueSorted = Array(Set(trackedGameIds)).sorted { $0.uuidString < $1.uuidString }
        let capped = Array(uniqueSorted.prefix(200))
        guard canFanUsePickupGamesUI, currentUserAuthId != nil, !capped.isEmpty else {
            await stopPickupJoinRequestBadgeRealtime()
            return
        }

        await stopPickupJoinRequestBadgeRealtime()

        pickupJoinRequestBadgeRealtimeTask = Task { [weak self] in
            guard let self else { return }
            await self.runPickupJoinRequestBadgeRealtimeLoop(trackedGameIds: capped)
        }
    }

    private func scheduleDebouncedPickupJoinRequestBadgeCountRefresh() {
        pickupJoinRequestBadgeDebounceTask?.cancel()
        pickupJoinRequestBadgeDebounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 360_000_000)
            guard !Task.isCancelled else { return }
            await self.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
        }
    }

    private func runPickupJoinRequestBadgeRealtimeLoop(trackedGameIds: [UUID]) async {
        let ids = trackedGameIds
        guard !Task.isCancelled, !ids.isEmpty else { return }

        let channel = supabase.channel("pickup-join-request-badge-\(UUID().uuidString.lowercased())")
        pickupJoinRequestBadgeRealtimeChannel = channel

        let filter = RealtimePostgresFilter.in("pickup_game_id", values: ids)
        let stream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "pickup_game_requests",
            filter: filter
        )

        do {
            try await channel.subscribeWithError()
        } catch {
            if pickupJoinRequestBadgeRealtimeChannel === channel {
                pickupJoinRequestBadgeRealtimeChannel = nil
            }
            return
        }

        for await _ in stream {
            guard !Task.isCancelled else { break }
            await MainActor.run {
                self.scheduleDebouncedPickupJoinRequestBadgeCountRefresh()
            }
        }
    }

    // MARK: - Following tab (requester pickup cards)

    /// Pickup “Games to Play”: same visibility / lifecycle signals as Discover list rows, without the map’s “full game” or calendar-day filters (approved joiners should still see the game).
    private func isPickupGameEligibleForFollowingGamesToPlay(_ game: PickupGameRow) -> Bool {
        guard game.status == "active", game.is_visible else { return false }
        let now = Date()
        if let rem = game.remove_after_at,
           let remd = PickupGameModels.parseSupabaseTimestamptz(rem),
           remd <= now {
            return false
        }
        return true
    }

    func loadMyPickupGameJoinRequestsForFollowing() async {
        guard canFanUsePickupGamesUI, let uid = currentUserAuthId else {
            myPickupGameJoinRequestCards = []
            pickupGamesFollowingTabCache.removeAll()
#if DEBUG
            print("[GamesToPlayDebug] approvedRequestsCount=0 activeApprovedGamesCount=0 filteredExpiredGamesCount=0 finalGamesToPlayCount=0 reason=no_uid_or_pickup_gate")
#endif
            return
        }

        do {
            let requests: [PickupGameRequestRow] = try await supabase
                .from("pickup_game_requests")
                .select(pickupGameRequestsSelectColumns)
                .eq("requester_user_id", value: uid.uuidString.lowercased())
                .order("updated_at", ascending: false)
                .limit(100)
                .execute()
                .value

            guard !requests.isEmpty else {
                myPickupGameJoinRequestCards = []
                pickupGamesFollowingTabCache.removeAll()
#if DEBUG
                print("[GamesToPlayDebug] approvedRequestsCount=0 activeApprovedGamesCount=0 filteredExpiredGamesCount=0 finalGamesToPlayCount=0 reason=no_requests")
#endif
                return
            }

            let gameIds = Array(Set(requests.map(\.pickup_game_id)))
            let games: [PickupGameRow] = try await supabase
                .from("pickup_games")
                .select(pickupGamesSelectColumns)
                .in("id", values: gameIds)
                .limit(200)
                .execute()
                .value

            var gameById: [UUID: PickupGameRow] = [:]
            for g in games {
                gameById[g.id] = g
            }
            pickupGamesFollowingTabCache = gameById

            let creatorIds = Array(Set(games.map(\.creator_user_id)))
            for cid in creatorIds {
                await loadPickupCreatorDisplayNameIfNeeded(creatorUserId: cid)
            }

            var approvedRequestsCount = 0
            var activeApprovedGamesCount = 0
            var filteredExpiredGamesCount = 0

            for req in requests {
                let st = req.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if st == "approved" { approvedRequestsCount += 1 }
            }

            var cards: [PickupGameJoinRequestCardDisplay] = []
            cards.reserveCapacity(requests.count)
            for req in requests {
                let st = req.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if st == "rejected" || st == "cancelled" { continue }

                guard let game = gameById[req.pickup_game_id] else {
                    if st == "approved" { filteredExpiredGamesCount += 1 }
                    continue
                }

                let playable = isPickupGameEligibleForFollowingGamesToPlay(game)
                if st == "approved" {
                    if playable {
                        activeApprovedGamesCount += 1
                    } else {
                        filteredExpiredGamesCount += 1
                        continue
                    }
                }

                let pill = pillKindForFollowingPickupRequest(status: req.status)
                let rawName = pickupCreatorDisplayLabel(for: game.creator_user_id)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let resolvedOrg = rawName.isEmpty ? "Organizer" : rawName
                cards.append(
                    PickupGameJoinRequestCardDisplay(
                        id: req.id,
                        pickupGameId: game.id,
                        title: game.title,
                        sport: game.sport,
                        dateTimeLine: dateTimeLineForFollowingPickupCard(game: game),
                        locationLine: locationLineForFollowingPickupCard(game: game),
                        organizerUserId: game.creator_user_id,
                        organizerName: resolvedOrg,
                        pill: pill,
                        spotsRemainingSummary: spotsSummaryForFollowingPickupCard(game: game)
                    )
                )
            }

#if DEBUG
            print("[GamesToPlayDebug] approvedRequestsCount=\(approvedRequestsCount)")
            print("[GamesToPlayDebug] activeApprovedGamesCount=\(activeApprovedGamesCount)")
            print("[GamesToPlayDebug] filteredExpiredGamesCount=\(filteredExpiredGamesCount)")
            print("[GamesToPlayDebug] finalGamesToPlayCount=\(cards.count)")
#endif
            myPickupGameJoinRequestCards = cards
        } catch {
#if DEBUG
            print("[FollowingPickup] load join cards failed:", error)
#endif
        }
    }

    private func pillKindForFollowingPickupRequest(status: String) -> PickupFollowingJoinRequestPillKind {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending": return .pending
        case "approved": return .approved
        case "rejected": return .declined
        case "cancelled": return .cancelled
        default: return .pending
        }
    }

    private func dateTimeLineForFollowingPickupCard(game: PickupGameRow) -> String {
        guard let d = PickupGameModels.parseSupabaseTimestamptz(game.game_start_at) else { return "" }
        return Self.followingPickupCardDateFormatter.string(from: d)
    }

    private func locationLineForFollowingPickupCard(game: PickupGameRow) -> String {
        let addr = game.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let loc = [game.city, game.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !addr.isEmpty, !loc.isEmpty { return "\(addr) · \(loc)" }
        if !addr.isEmpty { return addr }
        return loc
    }

    private func spotsSummaryForFollowingPickupCard(game: PickupGameRow) -> String? {
        if game.isPickupFullForDiscover { return "Full" }
        let n = game.pickupOpenSlotsRemaining
        guard n > 0 else { return nil }
        return n == 1 ? "1 spot open" : "\(n) spots open"
    }

    private static let followingPickupCardDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
