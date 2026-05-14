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
        return myPickupGamesForSettings.first(where: { $0.id == id })
    }

    func refreshPickupJoinCachesAfterMutation() {
#if DEBUG
        print("[PickupRequest] caches refreshed")
#endif
        pickupGameCalendarDotDatesCache.removeAll()
        invalidatePickupGameClusterAnnotationCache()
    }

    /// Loads `user_profiles.display_name` for pickup detail (no email in UI).
    func loadPickupCreatorDisplayNameIfNeeded(creatorUserId: UUID) async {
        if pickupCreatorDisplayNameByUserId[creatorUserId] != nil { return }
        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select("id,display_name")
                .eq("id", value: creatorUserId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            let name = rows.first?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty {
                pickupCreatorDisplayNameByUserId[creatorUserId] = name
            } else {
                pickupCreatorDisplayNameByUserId[creatorUserId] = ""
            }
        } catch {
            pickupCreatorDisplayNameByUserId[creatorUserId] = ""
        }
    }

    func pickupCreatorDisplayLabel(for userId: UUID) -> String? {
        guard let v = pickupCreatorDisplayNameByUserId[userId] else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
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
        guard canFanUsePickupGamesUI, !gameIds.isEmpty else {
            pickupOrganizerJoinStatsByGameId = [:]
            return
        }
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
        pickupOrganizerJoinStatsByGameId = next
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

    func createPickupJoinRequest(pickupGameId: UUID, requesterSkillLevel: String, message: String?) async throws {
        guard let uid = currentUserAuthId else {
            throw PickupGameClientError.notSignedIn
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
        } catch {
#if DEBUG
            print("[PickupRequest] request failed game=\(pickupGameId.uuidString.lowercased()) error=\(error)")
#endif
            throw error
        }
    }

    func cancelMyPickupJoinRequest(requestId: UUID, pickupGameId: UUID) async throws {
        try await supabase
            .from("pickup_game_requests")
            .update(PickupJoinRequestStatusUpdate(status: "cancelled"))
            .eq("id", value: requestId.uuidString.lowercased())
            .execute()
        await loadMyLatestJoinRequestForPickupGame(pickupGameId: pickupGameId)
        refreshPickupJoinCachesAfterMutation()
        await refreshPickupGamesForDiscoverMap(force: true)
        recomputeCalendarDotDates()
    }

    func approvePickupJoinRequest(requestId: UUID, pickupGameId: UUID) async throws {
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
}
