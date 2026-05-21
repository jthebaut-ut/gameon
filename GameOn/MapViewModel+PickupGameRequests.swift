import Foundation
import Supabase

private let pickupGameRequestsSelectColumns =
    "id,pickup_game_id,requester_user_id,requester_email,requester_display_name,requester_skill_level,message,status,created_at,updated_at,responded_at"

private let pickupFollowingOrganizerCanceledUserClearedKeyPrefix = "gameon.following.pickupOrganizerCanceledClearedIds."

private struct PickupGameRequestStatusOnly: Decodable {
    let pickup_game_id: UUID
    let status: String
}

extension MapViewModel {
    private static let followingJoinRequestsFreshnessInterval: TimeInterval = 60


    func resolvedPickupGameRow(for id: UUID) -> PickupGameRow? {
        if let s = selectedPickupGameForMap, s.id == id { return s }
        if let m = pickupGamesForDiscoverMap.first(where: { $0.id == id }) { return m }
        if let m = myPickupGamesForSettings.first(where: { $0.id == id }) { return m }
        return pickupGamesFollowingTabCache[id]
    }

    /// Persists per-user “Clear now” for Following → Games to Play organizer-canceled pickup cards.
    func markPickupFollowingOrganizerCanceledCardUserCleared(pickupGameId: UUID) {
        guard let uid = currentUserAuthId else { return }
        let cleanupAt = resolvedPickupGameRow(for: pickupGameId)?.pickupHistoryClientCleanupDeadline()
        var s = Self.readPickupFollowingOrganizerCanceledUserClearedSet(userId: uid)
        s.insert(pickupGameId)
        Self.writePickupFollowingOrganizerCanceledUserClearedSet(userId: uid, ids: s)
        myPickupGameJoinRequestCards.removeAll { $0.pickupGameId == pickupGameId && $0.pill == .canceledByOrganizer }
        pickupActivityCount = pickupFollowingUnreadActivityGameIds.count
        hasUnreadPickupActivity = pickupActivityCount > 0
#if DEBUG
        let cleanupStr = cleanupAt.map { Self.pickupCanceledVisibilityLogISO8601.string(from: $0) } ?? "nil"
        print("[PickupHistoryClear] gameId=\(pickupGameId.uuidString.lowercased())")
        print("[PickupHistoryClear] cleanupAt=\(cleanupStr)")
        print("[PickupHistoryClear] userTappedClear=true")
        print("[PickupHistoryClear] autoExpired=false")
        print("[PickupHistoryClear] visible=false")
#endif
        showSocialActionToast("Removed from history", isError: false)
    }

    private static func readPickupFollowingOrganizerCanceledUserClearedSet(userId: UUID) -> Set<UUID> {
        let raw = UserDefaults.standard.string(forKey: pickupFollowingOrganizerCanceledUserClearedKeyPrefix + userId.uuidString.lowercased()) ?? ""
        return Set(
            raw.split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap { UUID(uuidString: $0) }
        )
    }

    private static func writePickupFollowingOrganizerCanceledUserClearedSet(userId: UUID, ids: Set<UUID>) {
        let capped = ids.sorted { $0.uuidString < $1.uuidString }.prefix(240)
        let raw = capped.map { $0.uuidString.lowercased() }.joined(separator: ",")
        UserDefaults.standard.set(raw, forKey: pickupFollowingOrganizerCanceledUserClearedKeyPrefix + userId.uuidString.lowercased())
    }

    private static let pickupCanceledVisibilityLogISO8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Organizer bulk-cancel + soft-removed game: fan still sees a Games to Play card until cleanup or “Clear now”.
    private func isPickupJoinRequestOrganizerCanceledFollowingFanView(
        request: PickupGameRequestRow,
        resolvedGame: PickupGameRow?
    ) -> Bool {
        let st = request.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard st == "cancelled" else { return false }
        guard let g = resolvedGame else { return true }
        let gst = g.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if gst == "active", g.is_visible { return false }
        return true
    }

    private func followingGamesToPlayOrganizerCanceledCleanupInstant(
        resolvedGame: PickupGameRow?,
        priorCard: PickupGameJoinRequestCardDisplay?,
        request: PickupGameRequestRow
    ) -> Date? {
        if let g = resolvedGame, let d = g.pickupHistoryClientCleanupDeadline() {
            return d
        }
        if let priorCard,
           let start = PickupGameModels.parseSupabaseTimestamptz(priorCard.game_start_at) {
            return start.addingTimeInterval(Double(PickupGameAutoRemoval.hoursAfterGameStart) * 3600)
        }
        if let raw = request.updated_at, let u = PickupGameModels.parseSupabaseTimestamptz(raw) {
            return u.addingTimeInterval(Double(PickupGameAutoRemoval.hoursAfterGameStart) * 3600)
        }
        return nil
    }

    private func logPickupCanceledVisibilityDebug(
        gameId: UUID,
        requestStatus: String,
        gameStatus: String?,
        cleanupAt: Date?,
        userCleared: Bool,
        visible: Bool
    ) {
#if DEBUG
        let cleanupStr: String
        if let cleanupAt {
            cleanupStr = Self.pickupCanceledVisibilityLogISO8601.string(from: cleanupAt)
        } else {
            cleanupStr = "nil"
        }
        print("[PickupCanceledVisibility] gameId=\(gameId.uuidString.lowercased())")
        print("[PickupCanceledVisibility] requestStatus=\(requestStatus)")
        print("[PickupCanceledVisibility] gameStatus=\(gameStatus ?? "nil")")
        print("[PickupCanceledVisibility] cleanupAt=\(cleanupStr)")
        print("[PickupCanceledVisibility] userCleared=\(userCleared)")
        print("[PickupCanceledVisibility] visible=\(visible)")
#endif
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
        await loadPickupCreatorProfilesIfNeeded(creatorUserIds: [creatorUserId])
    }

    /// Batch-loads organizer profile hints for pickup cards without per-card profile queries.
    func loadPickupCreatorProfilesIfNeeded(creatorUserIds: Set<UUID>) async {
        let idsToFetch = await MainActor.run { () -> [UUID] in
            let missing = creatorUserIds.filter { pickupCreatorAvatarTokenByUserId[$0] == nil }
            for id in missing {
                pickupCreatorAvatarTokenByUserId[id] = UUID()
            }
            return Array(missing)
        }
        guard !idsToFetch.isEmpty else { return }

        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select("id,email,display_name,username,bio,avatar_url,avatar_thumbnail_url,is_business_account")
                .in("id", values: idsToFetch.map { $0.uuidString.lowercased() })
                .limit(idsToFetch.count)
                .execute()
                .value
            let rowsById = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (UUID, UserProfileRow)? in
                guard let id = row.id else { return nil }
                return (id, row)
            })

            await MainActor.run {
                for id in idsToFetch {
                    let row = rowsById[id]
                    let isBusiness = row?.is_business_account == true
                    let name = isBusiness ? "" : (row?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                    let email = isBusiness ? "" : (row?.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                    let full = isBusiness ? "" : ImageDisplayURL.canonicalStorageURLString(row?.avatar_url)
                    let thumb = isBusiness ? "" : ImageDisplayURL.canonicalStorageURLString(row?.avatar_thumbnail_url)
                    pickupCreatorDisplayNameByUserId[id] = name
                    pickupCreatorEmailByUserId[id] = email
                    pickupCreatorAvatarURLByUserId[id] = full
                    pickupCreatorAvatarThumbnailURLByUserId[id] = thumb
                    pickupCreatorAvatarTokenByUserId[id] = UUID()
                    PickupOrganizerDebug.log(
                        organizerUserId: id,
                        organizerAvatarUrl: ImageDisplayURL.forList(thumbnail: thumb, full: full) ?? "",
                        organizerDisplayName: name
                    )
                }
            }
        } catch {
            await MainActor.run {
                for id in idsToFetch {
                    pickupCreatorDisplayNameByUserId[id] = ""
                    pickupCreatorEmailByUserId[id] = ""
                    pickupCreatorAvatarURLByUserId[id] = ""
                    pickupCreatorAvatarThumbnailURLByUserId[id] = ""
                    PickupOrganizerDebug.log(
                        organizerUserId: id,
                        organizerAvatarUrl: "",
                        organizerDisplayName: ""
                    )
                }
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
                .order("updated_at", ascending: false)
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
            if let latest = try await fetchPickupMyJoinRequestsForDiscoverGames(gameIds: unique, userId: uid) {
                applyPickupMyJoinRequestsForDiscoverGames(gameIds: unique, latest: latest)
            }
        } catch {
            // Leave existing cache; Discover still works.
        }
    }

    func fetchPickupMyJoinRequestsForDiscoverGames(gameIds: [UUID]) async throws -> [UUID: PickupGameRequestRow]? {
        guard let uid = currentUserAuthId, isAuthenticatedForSocialFeatures else { return nil }
        return try await fetchPickupMyJoinRequestsForDiscoverGames(gameIds: gameIds, userId: uid)
    }

    private func fetchPickupMyJoinRequestsForDiscoverGames(
        gameIds: [UUID],
        userId: UUID
    ) async throws -> [UUID: PickupGameRequestRow]? {
        let unique = Array(Set(gameIds))
        guard !unique.isEmpty else { return [:] }
        let rows: [PickupGameRequestRow] = try await supabase
            .from("pickup_game_requests")
            .select(pickupGameRequestsSelectColumns)
            .eq("requester_user_id", value: userId.uuidString.lowercased())
            .in("pickup_game_id", values: unique)
            .order("updated_at", ascending: false)
            .limit(800)
            .execute()
            .value
        return PickupGameRequestRow.pickupLatestRequestByGameId(rows)
    }

    func applyPickupMyJoinRequestsForDiscoverGames(
        gameIds: [UUID],
        latest: [UUID: PickupGameRequestRow]
    ) {
        for id in Array(Set(gameIds)) {
            if latest[id] == nil {
                pickupMyLatestJoinRequestByGameId.removeValue(forKey: id)
            }
        }
        for (k, v) in latest {
            pickupMyLatestJoinRequestByGameId[k] = v
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

    /// Loads withdrawn / cancelled join rows for organizer Settings (“Can’t make it”).
    func loadOrganizerWithdrawnPickupRequestsForSettings(gameIds: [UUID]) async {
        guard canFanUsePickupGamesUI else {
            pickupOrganizerWithdrawnRequestsByGameId = [:]
            return
        }
        let unique = Array(Set(gameIds))
        guard !unique.isEmpty else { return }

        do {
            let rows: [PickupGameRequestRow] = try await supabase
                .from("pickup_game_requests")
                .select(pickupGameRequestsSelectColumns)
                .in("pickup_game_id", values: unique.map { $0.uuidString.lowercased() })
                .or("status.eq.cancelled,status.eq.withdrawn")
                .limit(2000)
                .execute()
                .value

            var grouped: [UUID: [PickupGameRequestRow]] = [:]
            for gid in unique {
                grouped[gid] = []
            }
            for r in rows {
                guard grouped[r.pickup_game_id] != nil else { continue }
                grouped[r.pickup_game_id, default: []].append(r)
            }
            for gid in unique {
                grouped[gid]?.sort { $0.pickupJoinRequestRecencyInstant > $1.pickupJoinRequestRecencyInstant }
            }
            for gid in unique {
                pickupOrganizerWithdrawnRequestsByGameId[gid] = grouped[gid] ?? []
            }
            let requesterIds = Set(rows.map(\.requester_user_id))
            await loadPickupJoinRequesterProfilesForOrganizerSheet(requesterIds: requesterIds)
        } catch {
#if DEBUG
            print("[PickupRequest] organizer withdrawn load failed:", error)
#endif
        }
    }

    /// Approved join requester ids per game (Settings → My pickup games roster strip).
    func loadOrganizerApprovedPickupJoinersForSettings(gameIds: [UUID]) async {
        guard canFanUsePickupGamesUI else {
            pickupOrganizerApprovedJoinerUserIdsByGameId = [:]
            return
        }
        let unique = Array(Set(gameIds))
        guard !unique.isEmpty else { return }

        do {
            let rows: [PickupGameRequestRow] = try await supabase
                .from("pickup_game_requests")
                .select(pickupGameRequestsSelectColumns)
                .in("pickup_game_id", values: unique.map { $0.uuidString.lowercased() })
                .eq("status", value: "approved")
                .order("updated_at", ascending: false)
                .limit(4000)
                .execute()
                .value

            var orderedPerGame: [UUID: [UUID]] = [:]
            for gid in unique {
                orderedPerGame[gid] = []
            }
            for r in rows {
                guard orderedPerGame[r.pickup_game_id] != nil else { continue }
                if !(orderedPerGame[r.pickup_game_id]?.contains(r.requester_user_id) ?? false) {
                    orderedPerGame[r.pickup_game_id]?.append(r.requester_user_id)
                }
            }

            await MainActor.run {
                for gid in unique {
                    pickupOrganizerApprovedJoinerUserIdsByGameId[gid] = orderedPerGame[gid] ?? []
                }
            }
            let requesterIds = Set(rows.map(\.requester_user_id))
            await loadPickupJoinRequesterProfilesForOrganizerSheet(requesterIds: requesterIds)
        } catch {
#if DEBUG
            print("[PickupRequest] organizer approved joiners load failed:", error)
#endif
        }
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
            .order("updated_at", ascending: false)
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
                .select("id,email,display_name,username,bio,avatar_url,avatar_thumbnail_url,admin_status")
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
            await loadMyPickupGameJoinRequestsForFollowing(
                forceRefresh: true,
                reason: "pickupJoinRequestCreated"
            )
        } catch {
#if DEBUG
            print("[PickupRequest] request failed game=\(pickupGameId.uuidString.lowercased()) error=\(error)")
#endif
            throw error
        }
    }

    func cancelMyPickupJoinRequest(requestId: UUID, pickupGameId: UUID) async throws {
        try await withdrawMyPickupJoinRequest(requestId: requestId, pickupGameId: pickupGameId)
    }

    /// Requester cancels or withdraws (pending, approved, or rejected→clear). Updates counts via DB trigger + local caches.
    func withdrawMyPickupJoinRequest(requestId: UUID, pickupGameId: UUID) async throws {
        guard canJoinPickupGames else {
            logBusinessUserGateBlocked(action: "joinPickupGame")
            throw PickupGameClientError.businessAccountsCannotUsePickupGames
        }

        let effectiveRequestId = pickupJoinRequestLatestByPickupGameIdForFan[pickupGameId]?.id
            ?? pickupMyLatestJoinRequestByGameId[pickupGameId]?.id
            ?? requestId

        let gameBefore = resolvedPickupGameRow(for: pickupGameId)
        let approvedCountBefore = gameBefore?.approved_join_count ?? -1
        let spotsOpenBefore = gameBefore.map { $0.pickupOpenSlotsRemaining } ?? -1
        let playersNeededBefore = gameBefore?.playersNeededClamped ?? -1

        let reqSnapshot = pickupJoinRequestLatestByPickupGameIdForFan[pickupGameId]
            ?? pickupMyLatestJoinRequestByGameId[pickupGameId]
        let oldLower = reqSnapshot?.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        let organizerActivityCreated: Bool = {
            guard let uid = currentUserAuthId, let g = gameBefore else { return false }
            return g.creator_user_id != uid
        }()

        if let idx = myPickupGameJoinRequestCards.firstIndex(where: { $0.pickupGameId == pickupGameId }) {
            let c = myPickupGameJoinRequestCards[idx]
            myPickupGameJoinRequestCards[idx] = PickupGameJoinRequestCardDisplay(
                id: c.id,
                pickupGameId: c.pickupGameId,
                title: c.title,
                sport: c.sport,
                game_start_at: c.game_start_at,
                dateTimeLine: c.dateTimeLine,
                locationLine: c.locationLine,
                organizerUserId: c.organizerUserId,
                organizerName: c.organizerName,
                pill: .withdrawing,
                spotsRemainingSummary: c.spotsRemainingSummary
            )
        }

        var didOptimisticApproved = false
        let originalGame = gameBefore
        if oldLower == "approved", let g = gameBefore {
            let nextC = max(0, g.approvedJoinCount - 1)
            let optimistic = g.replacingApprovedJoinCount(nextC)
            mergePickupInsertedLocally(optimistic)
            pickupGamesFollowingTabCache[pickupGameId] = optimistic
            didOptimisticApproved = true
        }

        var updatePayloadLog = ""
        var newStatusLog = ""
        var updateSucceeded = false
        var lastErrorDescription = ""

        do {
            if oldLower == "approved" {
                updatePayloadLog = "withdrawn"
                do {
                    try await supabase
                        .from("pickup_game_requests")
                        .update(PickupJoinRequestStatusUpdate(status: "withdrawn"))
                        .eq("id", value: effectiveRequestId.uuidString.lowercased())
                        .execute()
                    newStatusLog = "withdrawn"
                    updateSucceeded = true
                } catch {
                    updatePayloadLog = "withdrawn_failed_then_cancelled"
                    try await supabase
                        .from("pickup_game_requests")
                        .update(PickupJoinRequestStatusUpdate(status: "cancelled"))
                        .eq("id", value: effectiveRequestId.uuidString.lowercased())
                        .execute()
                    newStatusLog = "cancelled"
                    updateSucceeded = true
                }
            } else {
                updatePayloadLog = "cancelled"
                try await supabase
                    .from("pickup_game_requests")
                    .update(PickupJoinRequestStatusUpdate(status: "cancelled"))
                    .eq("id", value: effectiveRequestId.uuidString.lowercased())
                    .execute()
                newStatusLog = "cancelled"
                updateSucceeded = true
            }
        } catch {
            lastErrorDescription = error.localizedDescription
            if didOptimisticApproved, let orig = originalGame {
                mergePickupInsertedLocally(orig)
                pickupGamesFollowingTabCache[pickupGameId] = orig
            }
            await loadMyPickupGameJoinRequestsForFollowing(
                forceRefresh: true,
                reason: "pickupWithdrawRollback"
            )
#if DEBUG
            print("[PickupJoinWithdraw] gameId=\(pickupGameId.uuidString.lowercased())")
            print("[PickupJoinWithdraw] requestId=\(effectiveRequestId.uuidString.lowercased())")
            print("[PickupJoinWithdraw] oldStatus=\(oldLower)")
            print("[PickupJoinWithdraw] updatePayload=\(updatePayloadLog)")
            print("[PickupJoinWithdraw] updateSucceeded=false")
            print("[PickupJoinWithdraw] error=\(lastErrorDescription)")
#endif
            throw error
        }

        try await refreshPickupGameRowFromServerAndMerge(id: pickupGameId)
        await loadMyLatestJoinRequestForPickupGame(pickupGameId: pickupGameId)
        await loadOrganizerPickupRequestSummaries(gameIds: [pickupGameId])
        await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
        await loadMyPickupGameJoinRequestsForFollowing(
            forceRefresh: true,
            reason: "pickupWithdrawSucceeded"
        )
        refreshPickupJoinCachesAfterMutation()
        invalidateCalendarTabEventsListCache()
        await refreshPickupGamesForDiscoverMap(force: true, preservePickupCalendarDotDatesCache: true)
        recomputeCalendarDotDates()
        pickupJoinRequestUiRevision &+= 1
        pickupOrganizerRequestsSyncGeneration &+= 1

        let gameAfter = resolvedPickupGameRow(for: pickupGameId)
        let approvedCountAfter = gameAfter?.approved_join_count ?? -1
        let spotsOpenAfter = gameAfter.map { $0.pickupOpenSlotsRemaining } ?? -1
        let playersNeededAfter = gameAfter?.playersNeededClamped ?? -1

        var organizerWithdrawnListCount = -1
        var refreshedOrganizerGames = false
        if let g = gameBefore, let uid = currentUserAuthId, g.creator_user_id == uid {
            await loadOrganizerWithdrawnPickupRequestsForSettings(gameIds: [pickupGameId])
            await loadOrganizerApprovedPickupJoinersForSettings(gameIds: [pickupGameId])
            organizerWithdrawnListCount = pickupOrganizerWithdrawnRequestsByGameId[pickupGameId]?.count ?? 0
            refreshedOrganizerGames = true
        }

#if DEBUG
        print("[PickupJoinWithdraw] gameId=\(pickupGameId.uuidString.lowercased())")
        print("[PickupJoinWithdraw] requestId=\(effectiveRequestId.uuidString.lowercased())")
        print("[PickupJoinWithdraw] oldStatus=\(oldLower)")
        print("[PickupJoinWithdraw] updatePayload=\(updatePayloadLog)")
        print("[PickupJoinWithdraw] updateSucceeded=\(updateSucceeded)")
        print("[PickupJoinWithdraw] newStatus=\(newStatusLog)")
        print("[PickupJoinWithdraw] approvedCountBefore=\(approvedCountBefore)")
        print("[PickupJoinWithdraw] approvedCountAfter=\(approvedCountAfter)")
        print("[PickupJoinWithdraw] spotsOpenBefore=\(spotsOpenBefore)")
        print("[PickupJoinWithdraw] spotsOpenAfter=\(spotsOpenAfter)")
        print("[PickupJoinWithdraw] playersNeededBefore=\(playersNeededBefore)")
        print("[PickupJoinWithdraw] playersNeededAfter=\(playersNeededAfter)")
        print("[PickupJoinWithdraw] organizerWithdrawnListCount=\(organizerWithdrawnListCount)")
        print("[PickupJoinWithdraw] refreshedFollowing=true")
        print("[PickupJoinWithdraw] refreshedCalendar=true")
        print("[PickupJoinWithdraw] refreshedOrganizerGames=\(refreshedOrganizerGames)")
        print("[PickupJoinWithdraw] refreshedDetail=true")
        print("[PickupJoinWithdraw] refreshedMapPreview=true")
        print("[PickupJoinWithdraw] organizerActivityCreated=\(organizerActivityCreated)")
        print("[PickupJoinWithdraw] error=")
#endif
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
            let requestRows: [PickupGameRequestRow] = try await supabase
                .from("pickup_game_requests")
                .select("id,requester_user_id")
                .eq("id", value: requestId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            let requesterId = requestRows.first?.requester_user_id

            try await supabase
                .from("pickup_game_requests")
                .update(PickupJoinRequestStatusUpdate(status: "approved"))
                .eq("id", value: requestId.uuidString.lowercased())
                .execute()
            try await refreshPickupGameRowFromServerAndMerge(id: pickupGameId)
#if DEBUG
            print("[PickupRequest] approve completed id=\(requestId.uuidString.lowercased())")
#endif
            if let requesterId {
                await awardFanXP(
                    userId: requesterId,
                    amount: 10,
                    source: FanXPSource.pickupJoinApproved,
                    sourceId: requestId,
                    showToast: false
                )
            }
            refreshPickupJoinCachesAfterMutation()
            await refreshPickupGamesForDiscoverMap(force: true)
            recomputeCalendarDotDates()
            await loadOrganizerPickupRequestSummaries(gameIds: [pickupGameId])
            await loadOrganizerWithdrawnPickupRequestsForSettings(gameIds: [pickupGameId])
            await loadOrganizerApprovedPickupJoinersForSettings(gameIds: [pickupGameId])
            await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
            pickupOrganizerRequestsSyncGeneration &+= 1
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
        await loadOrganizerWithdrawnPickupRequestsForSettings(gameIds: [pickupGameId])
        await loadOrganizerApprovedPickupJoinersForSettings(gameIds: [pickupGameId])
        await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
        pickupOrganizerRequestsSyncGeneration &+= 1
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
            let hostGameIds = await MainActor.run { self.myPickupGamesForSettings.map(\.id) }
            if !hostGameIds.isEmpty {
                await self.loadOrganizerPickupRequestSummaries(gameIds: hostGameIds)
                await self.loadOrganizerWithdrawnPickupRequestsForSettings(gameIds: hostGameIds)
                await self.loadOrganizerApprovedPickupJoinersForSettings(gameIds: hostGameIds)
            }
            await MainActor.run {
                self.pickupOrganizerRequestsSyncGeneration &+= 1
            }
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

    func loadMyPickupGameJoinRequestsForFollowing(
        forceRefresh: Bool = false,
        reason: String = "ordinary"
    ) async {
        guard canFanUsePickupGamesUI, let uid = currentUserAuthId else {
            myPickupGameJoinRequestCards = []
            pickupGamesFollowingTabCache.removeAll()
            pickupJoinRequestLatestByPickupGameIdForFan = [:]
            lastSuccessfulFollowingJoinRequestsRefreshAt = nil
            lastSuccessfulFollowingJoinRequestsRefreshUserId = nil
            resetPickupFollowingActivityStateForCacheClear()
#if DEBUG
            print("[GamesToPlayDebug] approvedRequestsCount=0 activeApprovedGamesCount=0 filteredExpiredGamesCount=0 finalGamesToPlayCount=0 reason=no_uid_or_pickup_gate")
#endif
            invalidateCalendarTabEventsListCache()
            logPickupActivityBadgeDebug()
            return
        }

        if !forceRefresh,
           let refreshedAt = freshFollowingJoinRequestsRefreshDate(for: uid) {
            let age = Date().timeIntervalSince(refreshedAt)
            if age < Self.followingJoinRequestsFreshnessInterval {
#if DEBUG
                print("[TabPerfDebug] followingJoinRequestsRefreshSkipped reason=fresh age=\(String(format: "%.1f", age))")
#endif
                return
            }
        }

#if DEBUG
        print("[TabPerfDebug] followingJoinRequestsRefreshStarted reason=\(reason)")
#endif

        let baseline = pickupFollowingCaptureActivityBaseline()
        let wasPrimed = pickupFollowingActivityPrimed

        let shouldShowGlobalRefresh = pickupFollowingCardRefreshSpinGameId == nil
        if shouldShowGlobalRefresh {
            isPickupFollowingJoinListRefreshing = true
        }
        defer {
            isPickupFollowingJoinListRefreshing = false
        }

        let priorJoinCardsSnapshot = myPickupGameJoinRequestCards

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
                pickupJoinRequestLatestByPickupGameIdForFan = [:]
                pickupFollowingApplyActivityAfterJoinListLoad(
                    baseline: baseline,
                    wasPrimed: wasPrimed,
                    cards: [],
                    gameById: [:],
                    statusByGameId: [:]
                )
                await stopFollowingPickupRealtime()
#if DEBUG
                print("[GamesToPlayDebug] approvedRequestsCount=0 activeApprovedGamesCount=0 filteredExpiredGamesCount=0 finalGamesToPlayCount=0 reason=no_requests")
#endif
                invalidateCalendarTabEventsListCache()
                logPickupActivityBadgeDebug()
                lastSuccessfulFollowingJoinRequestsRefreshAt = Date()
                lastSuccessfulFollowingJoinRequestsRefreshUserId = uid
#if DEBUG
                print("[TabPerfDebug] followingJoinRequestsRefreshSucceeded count=0")
#endif
                return
            }

            let priorFollowingPickupGamesCache = pickupGamesFollowingTabCache

            let latestJoinByPickupGameId = PickupGameRequestRow.pickupLatestRequestByGameId(requests)
            pickupJoinRequestLatestByPickupGameIdForFan = latestJoinByPickupGameId

            let gameIds = Array(Set(latestJoinByPickupGameId.keys))
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

            var mergedGameRowById: [UUID: PickupGameRow] = priorFollowingPickupGamesCache
            for (k, v) in gameById {
                mergedGameRowById[k] = v
            }

            let sortedLatestEntries = latestJoinByPickupGameId.values.sorted { a, b in
                let ga = mergedGameRowById[a.pickup_game_id]
                let gb = mergedGameRowById[b.pickup_game_id]
                let ta = ga.flatMap { PickupGameModels.parseSupabaseTimestamptz($0.game_start_at) } ?? .distantFuture
                let tb = gb.flatMap { PickupGameModels.parseSupabaseTimestamptz($0.game_start_at) } ?? .distantFuture
                if ta != tb { return ta < tb }
                return a.pickup_game_id.uuidString < b.pickup_game_id.uuidString
            }

            var approvedRequestsCount = 0
            var activeApprovedGamesCount = 0
            var filteredExpiredGamesCount = 0

            for (_, req) in latestJoinByPickupGameId {
                let st = req.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if st == "approved" { approvedRequestsCount += 1 }
            }

            var statusByGameId: [UUID: String] = [:]
            var cards: [PickupGameJoinRequestCardDisplay] = []
            cards.reserveCapacity(latestJoinByPickupGameId.count)

            for req in sortedLatestEntries {
                let st = req.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if st == "rejected" || st == "cancelled" || st == "withdrawn" { continue }

                statusByGameId[req.pickup_game_id] = st

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
                        // Keep expired-but-approved games on the list so joiners can post organizer ratings.
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
                        game_start_at: game.game_start_at,
                        dateTimeLine: dateTimeLineForFollowingPickupCard(game: game),
                        locationLine: locationLineForFollowingPickupCard(game: game),
                        organizerUserId: game.creator_user_id,
                        organizerName: resolvedOrg,
                        pill: pill,
                        spotsRemainingSummary: spotsSummaryForFollowingPickupCard(game: game)
                    )
                )
            }

            let userClearedOrganizerCanceled = Self.readPickupFollowingOrganizerCanceledUserClearedSet(userId: uid)
            let now = Date()

            for req in sortedLatestEntries {
                let stRaw = req.status.trimmingCharacters(in: .whitespacesAndNewlines)
                let st = stRaw.lowercased()
                guard st == "cancelled" else { continue }
                let gid = req.pickup_game_id
                let userCleared = userClearedOrganizerCanceled.contains(gid)
                let resolvedGame = gameById[gid] ?? mergedGameRowById[gid]
                let priorCard = priorJoinCardsSnapshot.first(where: { $0.pickupGameId == gid })
                let isOrgCancel = isPickupJoinRequestOrganizerCanceledFollowingFanView(request: req, resolvedGame: resolvedGame)
                let cleanupAt = followingGamesToPlayOrganizerCanceledCleanupInstant(
                    resolvedGame: resolvedGame,
                    priorCard: priorCard,
                    request: req
                )
                let visible = isOrgCancel && !userCleared && (cleanupAt.map { now < $0 } ?? false)
                logPickupCanceledVisibilityDebug(
                    gameId: gid,
                    requestStatus: stRaw,
                    gameStatus: resolvedGame?.status,
                    cleanupAt: cleanupAt,
                    userCleared: userCleared,
                    visible: visible
                )
                guard visible else { continue }
                if cards.contains(where: { $0.pickupGameId == gid }) { continue }

                guard let organizerUserId = resolvedGame?.creator_user_id ?? priorCard?.organizerUserId else { continue }

                let gForLines = resolvedGame
                let title = gForLines?.title ?? priorCard?.title ?? "Pickup game"
                let sport = gForLines?.sport ?? priorCard?.sport ?? "soccer"
                let gameStartAt: String = {
                    if let s = gForLines?.game_start_at, !s.isEmpty { return s }
                    if let s = priorCard?.game_start_at, !s.isEmpty { return s }
                    return req.updated_at ?? ""
                }()
                let dtLine: String = {
                    if let g = gForLines { return dateTimeLineForFollowingPickupCard(game: g) }
                    if let d = PickupGameModels.parseSupabaseTimestamptz(gameStartAt) {
                        return Self.followingPickupCardDateFormatter.string(from: d)
                    }
                    return priorCard?.dateTimeLine ?? ""
                }()
                let locLine = gForLines.map { locationLineForFollowingPickupCard(game: $0) } ?? (priorCard?.locationLine ?? "")

                statusByGameId[gid] = "cancelled"

                let rawName = pickupCreatorDisplayLabel(for: organizerUserId)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let resolvedOrg = rawName.isEmpty ? (priorCard?.organizerName ?? "Organizer") : rawName

                cards.append(
                    PickupGameJoinRequestCardDisplay(
                        id: req.id,
                        pickupGameId: gid,
                        title: title,
                        sport: sport,
                        game_start_at: gameStartAt,
                        dateTimeLine: dtLine,
                        locationLine: locLine,
                        organizerUserId: organizerUserId,
                        organizerName: resolvedOrg,
                        pill: .canceledByOrganizer,
                        spotsRemainingSummary: nil
                    )
                )
            }

            cards.sort {
                let ta = PickupGameModels.parseSupabaseTimestamptz($0.game_start_at) ?? .distantFuture
                let tb = PickupGameModels.parseSupabaseTimestamptz($1.game_start_at) ?? .distantFuture
                if ta != tb { return ta < tb }
                return $0.pickupGameId.uuidString < $1.pickupGameId.uuidString
            }

            await loadPickupCreatorProfilesIfNeeded(creatorUserIds: Set(cards.map(\.organizerUserId)))

#if DEBUG
            let activeGamesToPlayCount = cards.filter { $0.pill != .canceledByOrganizer }.count
            let organizerCanceledVisibleCount = cards.filter { $0.pill == .canceledByOrganizer }.count
            print("[GamesToPlayDebug] approvedRequestsCount=\(approvedRequestsCount)")
            print("[GamesToPlayDebug] activeApprovedGamesCount=\(activeApprovedGamesCount)")
            print("[GamesToPlayDebug] filteredExpiredGamesCount=\(filteredExpiredGamesCount)")
            print("[GamesToPlayDebug] finalActiveGamesToPlayCount=\(activeGamesToPlayCount)")
            print("[GamesToPlayDebug] finalOrganizerCanceledVisibleCount=\(organizerCanceledVisibleCount)")
#endif

            pickupGamesFollowingTabCache = mergedGameRowById
            myPickupGameJoinRequestCards = cards
            pickupFollowingApplyActivityAfterJoinListLoad(
                baseline: baseline,
                wasPrimed: wasPrimed,
                cards: cards,
                gameById: mergedGameRowById,
                statusByGameId: statusByGameId
            )

            let activeCards = cards.filter { $0.pill != .canceledByOrganizer }
            let ratingOrganizerIds = Array(Set(activeCards.map(\.organizerUserId)))
            let ratingPickupGameIds = Array(Set(activeCards.map(\.pickupGameId)))
            await refreshPickupCreatorPublicRatingStats(creatorUserIds: ratingOrganizerIds)
            await refreshMyPickupCreatorRatingsForPickupGames(pickupGameIds: ratingPickupGameIds)

            await syncFollowingPickupRealtimeSubscriptionIfNeeded(gameIds: Array(Set(cards.map(\.pickupGameId))))

            invalidateCalendarTabEventsListCache()
            logPickupActivityBadgeDebug()
            lastSuccessfulFollowingJoinRequestsRefreshAt = Date()
            lastSuccessfulFollowingJoinRequestsRefreshUserId = uid
#if DEBUG
            print("[TabPerfDebug] followingJoinRequestsRefreshSucceeded count=\(cards.count)")
#endif
        } catch {
#if DEBUG
            print("[FollowingPickup] load join cards failed:", error)
#endif
        }
    }

    private func freshFollowingJoinRequestsRefreshDate(for uid: UUID) -> Date? {
        if lastSuccessfulFollowingJoinRequestsRefreshUserId == uid,
           let refreshedAt = lastSuccessfulFollowingJoinRequestsRefreshAt {
            return refreshedAt
        }

        guard pickupFollowingActivityPrimed else { return nil }
        return lastJoinStatusRefreshAt
    }

    private func pillKindForFollowingPickupRequest(status: String) -> PickupFollowingJoinRequestPillKind {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending": return .pending
        case "approved": return .approved
        case "rejected": return .declined
        case "cancelled", "withdrawn": return .cancelled
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

    func pickupGameCalendarAddressLine(_ game: PickupGameRow) -> String {
        locationLineForFollowingPickupCard(game: game)
    }

    func pickupGameCalendarDateTimeLine(_ game: PickupGameRow) -> String {
        dateTimeLineForFollowingPickupCard(game: game)
    }

    func pickupGameCalendarSpotsLine(_ game: PickupGameRow) -> String? {
        spotsSummaryForFollowingPickupCard(game: game)
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
