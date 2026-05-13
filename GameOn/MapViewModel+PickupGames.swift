import CoreLocation
import Foundation
import Supabase

private let pickupGamesSelectColumns =
    "id,creator_user_id,creator_email,title,sport,description,skill_level,game_start_at,address,city,state,latitude,longitude,is_visible,players_needed,play_environment,participant_preference,is_free,entry_fee_amount,max_players,status,cleanup_delay_hours,remove_after_at,created_at,updated_at"

extension MapViewModel {

    /// Pickup CRUD and Settings entry are for authenticated users who are not in a venue-owner/business session.
    var canFanUsePickupGamesUI: Bool {
        isAuthenticatedForSocialFeatures && !hasAuthenticatedVenueOwnerSession
    }

    func clearPickupMapSelection() {
        selectedPickupGameForMap = nil
    }

    func selectPickupGameOnMap(_ row: PickupGameRow) {
        selectedBar = nil
        selectedEvent = nil
        discoverRemotePreviewHoldVenueId = nil
        selectedPickupGameForMap = row
    }

    /// Pickup pins require latitude/longitude; games are created only with resolved coordinates.
    func pickupGamesVisibleAsMapPins(for bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?) -> [PickupGameRow] {
        let rows = pickupGamesForDiscoverMap.filter { $0.latitude != nil && $0.longitude != nil }
        guard let bounds else { return rows }
        return rows.filter { row in
            guard let lat = row.latitude, let lon = row.longitude else { return false }
            return lat >= bounds.minLat && lat <= bounds.maxLat && lon >= bounds.minLon && lon <= bounds.maxLon
        }
    }

    func refreshPickupGamesForDiscoverMap() async {
        guard isAuthenticatedForSocialFeatures else {
            pickupGamesForDiscoverMap = []
            clearPickupMapSelection()
            return
        }

        isLoadingPickupGamesForMap = true
        defer { isLoadingPickupGamesForMap = false }

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedDate)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else {
            pickupGamesForDiscoverMap = []
            return
        }
        let now = Date()
        let startISO = PickupGameModels.encodeSupabaseTimestamptz(dayStart)
        let endISO = PickupGameModels.encodeSupabaseTimestamptz(dayEnd)
        let nowISO = PickupGameModels.encodeSupabaseTimestamptz(now)

        do {
            var query = supabase
                .from("pickup_games")
                .select(pickupGamesSelectColumns)
                .gte("game_start_at", value: startISO)
                .lt("game_start_at", value: endISO)
                .gt("remove_after_at", value: nowISO)
                .eq("status", value: "active")
                .eq("is_visible", value: true)

            if selectedSport != "All" {
                query = query.eq("sport", value: selectedSport)
            }

            let rows: [PickupGameRow] = try await query
                .limit(400)
                .execute()
                .value

            let filtered = rows.filter { row in
                guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return false }
                guard cal.isDate(start, inSameDayAs: selectedDate) else { return false }
                if let rem = row.remove_after_at,
                   let remd = PickupGameModels.parseSupabaseTimestamptz(rem),
                   remd <= now {
                    return false
                }
                guard row.is_visible else { return false }
                return true
            }

            pickupGamesForDiscoverMap = filtered
            if let sel = selectedPickupGameForMap, !filtered.contains(where: { $0.id == sel.id }) {
                clearPickupMapSelection()
            }
        } catch {
#if DEBUG
            print("[PickupGames] refreshDiscover failed:", error)
#endif
        }
    }

    func loadMyPickupGamesForSettings() async {
        guard canFanUsePickupGamesUI, let uid = currentUserAuthId else {
            myPickupGamesForSettings = []
            return
        }

        do {
            let rows: [PickupGameRow] = try await supabase
                .from("pickup_games")
                .select(pickupGamesSelectColumns)
                .eq("creator_user_id", value: uid.uuidString.lowercased())
                .order("game_start_at", ascending: false)
                .limit(200)
                .execute()
                .value
            myPickupGamesForSettings = rows
        } catch {
#if DEBUG
            print("[PickupGames] loadMine failed:", error)
#endif
        }
    }

    func insertPickupGame(
        title: String,
        sport: String,
        description: String?,
        skillLevel: String,
        gameStartAt: Date,
        address: String?,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?,
        isVisible: Bool,
        playersNeeded: Int,
        playEnvironment: String,
        participantPreference: String,
        isFree: Bool,
        entryFeeAmount: Double?,
        maxPlayers: Int?,
        cleanupDelayHours: Int
    ) async throws -> PickupGameRow {
        guard let uid = currentUserAuthId else {
            throw PickupGameClientError.notSignedIn
        }
        let playersNeededClamped = min(20, max(1, playersNeeded))
        let maxPlayersClamped: Int? = {
            guard let m = maxPlayers else { return nil }
            let c = min(100, max(1, m))
            guard c >= playersNeededClamped else { return playersNeededClamped }
            return c
        }()
        let feePayload: Double? = isFree ? nil : entryFeeAmount.map { Self.roundMoney($0) }
        let payload = PickupGameInsert(
            creator_user_id: uid,
            creator_email: normalizedFanEmailForPickup(),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            sport: sport.trimmingCharacters(in: .whitespacesAndNewlines),
            description: emptyStringToNil(description),
            skill_level: skillLevel,
            game_start_at: PickupGameModels.encodeSupabaseTimestamptz(gameStartAt),
            address: emptyStringToNil(address),
            city: emptyStringToNil(city),
            state: emptyStringToNil(state),
            latitude: latitude,
            longitude: longitude,
            is_visible: isVisible,
            players_needed: playersNeededClamped,
            play_environment: playEnvironment,
            participant_preference: participantPreference,
            is_free: isFree,
            entry_fee_amount: feePayload,
            max_players: maxPlayersClamped,
            cleanup_delay_hours: cleanupDelayHours
        )

        let inserted: [PickupGameRow] = try await supabase
            .from("pickup_games")
            .insert(payload)
            .select(pickupGamesSelectColumns)
            .execute()
            .value

        guard let row = inserted.first else {
            throw PickupGameClientError.missingRowAfterWrite
        }
        mergePickupInsertedLocally(row)
        return row
    }

    func updatePickupGame(id: UUID, full: PickupGameFullUpdate) async throws {
        let updated: [PickupGameRow] = try await supabase
            .from("pickup_games")
            .update(full)
            .eq("id", value: id.uuidString.lowercased())
            .select(pickupGamesSelectColumns)
            .execute()
            .value

        guard let row = updated.first else {
            throw PickupGameClientError.missingRowAfterWrite
        }
        mergePickupInsertedLocally(row)
    }

    func softRemovePickupGame(id: UUID) async throws {
        try await supabase
            .from("pickup_games")
            .update(PickupGameStatusPatch(status: "removed"))
            .eq("id", value: id.uuidString.lowercased())
            .execute()
        applySoftRemovedPickupGameLocally(id: id)
    }

    private static func roundMoney(_ x: Double) -> Double {
        (x * 100.0).rounded() / 100.0
    }

    private func normalizedFanEmailForPickup() -> String? {
        let e = OwnerBusinessEmail.normalized(currentUserEmail)
        return e.isEmpty ? nil : e
    }

    private func emptyStringToNil(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private func mergePickupInsertedLocally(_ row: PickupGameRow) {
        if let i = myPickupGamesForSettings.firstIndex(where: { $0.id == row.id }) {
            myPickupGamesForSettings[i] = row
        } else {
            myPickupGamesForSettings.insert(row, at: 0)
        }
        myPickupGamesForSettings.sort { a, b in
            let da = PickupGameModels.parseSupabaseTimestamptz(a.game_start_at) ?? .distantPast
            let db = PickupGameModels.parseSupabaseTimestamptz(b.game_start_at) ?? .distantPast
            return da > db
        }

        if shouldIncludePickupRowOnDiscoverMap(row) {
            if let i = pickupGamesForDiscoverMap.firstIndex(where: { $0.id == row.id }) {
                pickupGamesForDiscoverMap[i] = row
            } else {
                pickupGamesForDiscoverMap.append(row)
            }
        } else {
            pickupGamesForDiscoverMap.removeAll { $0.id == row.id }
        }
    }

    private func shouldIncludePickupRowOnDiscoverMap(_ row: PickupGameRow) -> Bool {
        guard row.status == "active", row.is_visible else { return false }
        let now = Date()
        if let rem = row.remove_after_at,
           let remd = PickupGameModels.parseSupabaseTimestamptz(rem),
           remd <= now {
            return false
        }
        let cal = Calendar.current
        guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return false }
        guard cal.isDate(start, inSameDayAs: selectedDate) else { return false }
        if selectedSport != "All", row.sport != selectedSport { return false }
        return true
    }

    private func applySoftRemovedPickupGameLocally(id: UUID) {
        myPickupGamesForSettings.removeAll { $0.id == id }
        pickupGamesForDiscoverMap.removeAll { $0.id == id }
        if selectedPickupGameForMap?.id == id {
            clearPickupMapSelection()
        }
    }
}
