import CoreLocation
import Foundation
import Supabase

let pickupGamesSelectColumns =
    "id,creator_user_id,creator_email,title,sport,description,skill_level,game_start_at,address,city,state,latitude,longitude,is_visible,players_needed,play_environment,participant_preference,is_free,entry_fee_amount,max_players,status,approved_join_count,cleanup_delay_hours,remove_after_at,created_at,updated_at"

private struct PickupGameCalendarRow: Decodable {
    let game_start_at: String
    let remove_after_at: String?
}

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

    /// Pickup pins in the current map bounds, filtered by the debounced Discover search (title, sport, address fields).
    func pickupGamesVisibleAsMapPinsWithDiscoverSearch(for bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)?) -> [PickupGameRow] {
        let inBounds = pickupGamesVisibleAsMapPins(for: bounds)
        let q = effectiveDiscoverSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return inBounds }
        return inBounds.filter { row in
            if row.title.localizedCaseInsensitiveContains(q) { return true }
            if row.sport.localizedCaseInsensitiveContains(q) { return true }
            if SportFilterCatalog.storedSport(row.sport, matchesSearchQuery: q) { return true }
            if (row.address ?? "").localizedCaseInsensitiveContains(q) { return true }
            if (row.city ?? "").localizedCaseInsensitiveContains(q) { return true }
            if (row.state ?? "").localizedCaseInsensitiveContains(q) { return true }
            return false
        }
    }

    func markPickupDiscoverMapDataDirtyForNextRefresh() {
        pickupDiscoverCoordinatorDirty = true
    }

    func clearDiscoverMapContentSelectionsWhenSwitching(to mode: DiscoverMapContentMode) {
        switch mode {
        case .venues:
            selectedPickupGameForMap = nil
        case .pickupGames:
            selectedBar = nil
            selectedEvent = nil
            discoverRemotePreviewHoldVenueId = nil
        }
    }

    func onDiscoverMapBecamePickupGamesFromUserToggle() {
        Task { @MainActor in
            guard discoverMapContentMode == .pickupGames else { return }
            guard isAuthenticatedForSocialFeatures else {
                pickupGamesForDiscoverMap = []
                return
            }
            guard pickupDiscoverCoordinatorDirty else { return }
            if pickupGamesForDiscoverMap.isEmpty {
                setDiscoverMapStatus("Updating map…", isLoading: true)
            }
            await refreshPickupGamesForDiscoverMap()
            if mapStatusText == "Updating map…" {
                setDiscoverMapStatus(nil, isLoading: false)
            }
        }
    }

    /// Distinct local calendar days with at least one visible pickup game in ``dateMin``…``dateMax`` (inclusive by day), respecting ``selectedSport``.
    func fetchPickupGameCalendarDotDatesForDiscoverRange(dateMin: Date, dateMax: Date) async throws -> Set<Date> {
        guard isAuthenticatedForSocialFeatures else { return [] }
        let cal = Calendar.current
        let rangeStart = cal.startOfDay(for: dateMin)
        let lastDayStart = cal.startOfDay(for: dateMax)
        guard let endExclusive = cal.date(byAdding: .day, value: 1, to: lastDayStart) else { return [] }
        let now = Date()
        let nowISO = PickupGameModels.encodeSupabaseTimestamptz(now)
        let startISO = PickupGameModels.encodeSupabaseTimestamptz(rangeStart)
        let endISO = PickupGameModels.encodeSupabaseTimestamptz(endExclusive)

        var query = supabase
            .from("pickup_games")
            .select("game_start_at,remove_after_at")
            .gte("game_start_at", value: startISO)
            .lt("game_start_at", value: endISO)
            .gt("remove_after_at", value: nowISO)
            .eq("status", value: "active")
            .eq("is_visible", value: true)

        if selectedSport != "All" {
            query = query.eq("sport", value: selectedSport)
        }

        let rows: [PickupGameCalendarRow] = try await query
            .limit(8000)
            .execute()
            .value

        var dates: Set<Date> = []
        dates.reserveCapacity(min(rows.count, 500))
        for row in rows {
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { continue }
            if let remStr = row.remove_after_at,
               let rem = PickupGameModels.parseSupabaseTimestamptz(remStr),
               rem <= now {
                continue
            }
            dates.insert(cal.startOfDay(for: start))
        }
        return dates
    }

    func refreshPickupGamesForDiscoverMap(force: Bool = false) async {
        guard isAuthenticatedForSocialFeatures else {
            pickupGamesForDiscoverMap = []
            clearPickupMapSelection()
            return
        }

        if !force && discoverMapContentMode != .pickupGames {
            return
        }

        isLoadingPickupGamesForMap = true
        defer { isLoadingPickupGamesForMap = false }

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedDate)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else {
            pickupGamesForDiscoverMap = []
            markPickupDiscoverMapDataDirtyForNextRefresh()
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
                guard !row.isPickupFullForDiscover else { return false }
                return true
            }

            pickupGamesForDiscoverMap = filtered
            pickupDiscoverCoordinatorDirty = false
            pickupGameCalendarDotDatesCache.removeAll()
            invalidatePickupGameClusterAnnotationCache()
            if let sel = selectedPickupGameForMap, !filtered.contains(where: { $0.id == sel.id }) {
                clearPickupMapSelection()
            }
            await refreshPickupMyJoinRequestsForDiscoverGames(gameIds: filtered.map(\.id))
            await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
        } catch {
#if DEBUG
            print("[PickupGames] refreshDiscover failed:", error)
#endif
            markPickupDiscoverMapDataDirtyForNextRefresh()
        }
    }

    func loadMyPickupGamesForSettings() async {
        guard canFanUsePickupGamesUI, let uid = currentUserAuthId else {
            myPickupGamesForSettings = []
            pendingPickupGameJoinRequestCount = 0
            await stopPickupJoinRequestBadgeRealtime()
            return
        }

        do {
            let rows: [PickupGameRow] = try await supabase
                .from("pickup_games")
                .select(pickupGamesSelectColumns)
                .eq("creator_user_id", value: uid.uuidString.lowercased())
                .eq("status", value: "active")
                .order("game_start_at", ascending: false)
                .limit(200)
                .execute()
                .value
            myPickupGamesForSettings = rows
            await loadOrganizerPickupRequestSummaries(gameIds: rows.map(\.id))
        } catch {
#if DEBUG
            print("[PickupGames] loadMine failed:", error)
#endif
        }
        await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
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

    func logPickupGamesEditRequested(id: UUID) {
#if DEBUG
        print("[PickupGames] edit requested id=\(id.uuidString.lowercased())")
#endif
    }

    func softRemovePickupGame(id: UUID) async throws {
#if DEBUG
        print("[PickupGames] delete requested id=\(id.uuidString.lowercased())")
#endif
        do {
            try await supabase
                .from("pickup_games")
                .update(PickupGameStatusPatch(status: "removed"))
                .eq("id", value: id.uuidString.lowercased())
                .execute()
#if DEBUG
            print("[PickupGames] delete completed id=\(id.uuidString.lowercased())")
#endif
            applySoftRemovedPickupGameLocally(id: id)
        } catch {
#if DEBUG
            print("[PickupGames] delete failed id=\(id.uuidString.lowercased())")
#endif
            throw error
        }
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

    func mergePickupInsertedLocally(_ row: PickupGameRow) {
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
        guard !row.isPickupFullForDiscover else { return false }
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
        clearPickupGameLocalCachesAfterRemoval(id: id)
    }

    private func clearPickupGameLocalCachesAfterRemoval(id: UUID) {
#if DEBUG
        print("[PickupGames] local caches cleared id=\(id.uuidString.lowercased())")
#endif
        invalidatePickupGameClusterAnnotationCache()
        pickupGameCalendarDotDatesCache.removeAll()
    }
}
