import CoreLocation
import Foundation
import Supabase

let pickupGamesSelectColumns =
    "id,creator_user_id,creator_email,title,sport,description,skill_level,game_start_at,address,city,state,latitude,longitude,is_visible,players_needed,play_environment,participant_preference,is_free,entry_fee_amount,max_players,status,approved_join_count,cleanup_delay_hours,remove_after_at,created_at,updated_at"

private struct PickupGameCalendarRow: Decodable {
    let id: UUID?
    let title: String?
    let sport: String?
    let game_start_at: String
    let remove_after_at: String?
    let status: String?
    let is_visible: Bool?
}

/// DEBUG-only: minimal columns for ``logPickupGamesAnonDiagnosticProbeUnfiltered`` (not used for UI).
private struct PickupGameAnonDiagnosticProbeRow: Decodable {
    let id: UUID?
    let title: String?
    let sport: String?
    let game_start_at: String?
    let status: String?
    let is_visible: Bool?
    let remove_after_at: String?
}

private func pickupDebugYMD(_ d: Date) -> String {
    let c = Calendar.current
    let y = c.component(.year, from: d)
    let m = c.component(.month, from: d)
    let day = c.component(.day, from: d)
    return String(format: "%04d-%02d-%02d", y, m, day)
}

/// PostgREST `or` filter: public pickup reads include rows with no `remove_after_at` or a future cleanup timestamp.
private func pickupGamesDiscoverRemoveAfterOrFilter(nowISO: String) -> String {
    "remove_after_at.is.null,remove_after_at.gt.\(nowISO)"
}

extension MapViewModel {

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
        let cal = Calendar.current
        let rangeStart = cal.startOfDay(for: dateMin)
        let lastDayStart = cal.startOfDay(for: dateMax)
        guard let endExclusive = cal.date(byAdding: .day, value: 1, to: lastDayStart) else { return [] }
        let now = Date()
        let nowISO = PickupGameModels.encodeSupabaseTimestamptz(now)
        let guestRecentFloor = cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: now) ?? now)
        let rangeQueryStart = isGuestDiscoverMode ? max(rangeStart, guestRecentFloor) : rangeStart
        let startISO = PickupGameModels.encodeSupabaseTimestamptz(rangeQueryStart)
        let endISO = PickupGameModels.encodeSupabaseTimestamptz(endExclusive)

        var query = supabase
            .from("pickup_games")
            .select("id,title,sport,game_start_at,remove_after_at,status,is_visible")
            .gte("game_start_at", value: startISO)
            .lt("game_start_at", value: endISO)
            .or(pickupGamesDiscoverRemoveAfterOrFilter(nowISO: nowISO))
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
        var droppedClientRemNotFuture = 0
        for row in rows {
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { continue }
            if let remStr = row.remove_after_at,
               let rem = PickupGameModels.parseSupabaseTimestamptz(remStr),
               rem <= now {
                droppedClientRemNotFuture += 1
                continue
            }
            dates.insert(cal.startOfDay(for: start))
        }
#if DEBUG
        let sportFilter = selectedSport == "All" ? "(none)" : selectedSport
        print(
            "[DiscoverPickupDiag] op=calendarDotMonth table=pickup_games dateMin=\(pickupDebugYMD(rangeStart)) dateMax=\(pickupDebugYMD(lastDayStart)) rangeStartISO=\(startISO) rangeEndExclusiveISO=\(endISO) nowISO=\(nowISO) selectedSport=\(selectedSport) sqlFilters=status:active is_visible:true game_start_at:[\(startISO),\(endISO)) remove_after_at:(is.null OR gt(\(nowISO))) sport:\(sportFilter) rawRowCount=\(rows.count) dotDatesAfterClientFilter=\(dates.count) droppedByClientRemoveAfterPast=\(droppedClientRemNotFuture)"
        )
        print("[DiscoverPickupDiag] NOTE remove_after_at uses PostgREST or(remove_after_at.is.null,remove_after_at.gt.now).")
        for (i, row) in rows.prefix(5).enumerated() {
            let tid = row.id?.uuidString ?? "nil"
            let tit = (row.title ?? "?").replacingOccurrences(of: "\n", with: " ")
            let sp = row.sport ?? "?"
            print("[DiscoverPickupDiag] rawRow[\(i)] id=\(tid) title=\(tit) sport=\(sp) game_start_at=\(row.game_start_at) status=\(row.status ?? "nil") is_visible=\(row.is_visible.map(String.init(describing:)) ?? "nil") remove_after_at=\(row.remove_after_at ?? "nil")")
        }
        if rows.isEmpty {
            await logPickupDiagnosticProbeUnfiltered(context: "calendarDotMonth_emptyWindow")
        }
        print("[DiscoverPickupPublic] monthWindowPickupDotDateCount=\(dates.count) sport=\(selectedSport) rangeStartISO=\(startISO)")
#endif
        return dates
    }

    /// Coalesces concurrent refresh calls onto one in-flight task (later callers await the same work).
    func refreshPickupGamesForDiscoverMap(force: Bool = false, preservePickupCalendarDotDatesCache: Bool = false) async {
        if let existing = refreshPickupGamesForDiscoverMapCoalescingTask {
            await existing.value
            return
        }
        let capturedForce = force
        let capturedPreserve = preservePickupCalendarDotDatesCache
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefreshPickupGamesForDiscoverMap(
                force: capturedForce,
                preservePickupCalendarDotDatesCache: capturedPreserve
            )
        }
        refreshPickupGamesForDiscoverMapCoalescingTask = work
        await work.value
        refreshPickupGamesForDiscoverMapCoalescingTask = nil
    }

    private func performRefreshPickupGamesForDiscoverMap(force: Bool, preservePickupCalendarDotDatesCache: Bool) async {
        if !force && discoverMapContentMode != .pickupGames {
#if DEBUG
            print(
                "[DiscoverPickupDiag] op=mapRefresh SKIP earlyExit force=\(force) discoverMapContentMode=\(discoverMapContentMode.rawValue) reason=refreshOnlyRunsForPickupModeUnlessForced"
            )
#endif
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
        let rawRecentFloor = cal.date(byAdding: .day, value: -1, to: now) ?? now
        let recentFloor = cal.startOfDay(for: rawRecentFloor)
        let effectiveLower = isGuestDiscoverMode ? max(dayStart, recentFloor) : dayStart
        let startISO = PickupGameModels.encodeSupabaseTimestamptz(effectiveLower)
        let endISO = PickupGameModels.encodeSupabaseTimestamptz(dayEnd)
        let nowISO = PickupGameModels.encodeSupabaseTimestamptz(now)

        do {
            var query = supabase
                .from("pickup_games")
                .select(pickupGamesSelectColumns)
                .gte("game_start_at", value: startISO)
                .lt("game_start_at", value: endISO)
                .or(pickupGamesDiscoverRemoveAfterOrFilter(nowISO: nowISO))
                .eq("status", value: "active")
                .eq("is_visible", value: true)

            if selectedSport != "All" {
                query = query.eq("sport", value: selectedSport)
            }

            let rows: [PickupGameRow] = try await query
                .limit(400)
                .execute()
                .value

            var dropParseStart = 0
            var dropWrongDay = 0
            var dropRemoveAfterPast = 0
            var dropNotVisible = 0
            var dropFull = 0
            var filtered: [PickupGameRow] = []
            filtered.reserveCapacity(rows.count)
            for row in rows {
                guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else {
                    dropParseStart += 1
                    continue
                }
                if !cal.isDate(start, inSameDayAs: selectedDate) {
                    dropWrongDay += 1
                    continue
                }
                if let rem = row.remove_after_at,
                   let remd = PickupGameModels.parseSupabaseTimestamptz(rem),
                   remd <= now {
                    dropRemoveAfterPast += 1
                    continue
                }
                if !row.is_visible {
                    dropNotVisible += 1
                    continue
                }
                if row.isPickupFullForDiscover {
                    dropFull += 1
                    continue
                }
                filtered.append(row)
            }

#if DEBUG
            let sportFilter = selectedSport == "All" ? "(none)" : selectedSport
            print(
                "[DiscoverPickupDiag] op=mapRefreshDay table=pickup_games selectedCalendarDay=\(pickupDebugYMD(selectedDate)) dayStartISO=\(startISO) dayEndExclusiveISO=\(endISO) nowISO=\(nowISO) selectedSport=\(selectedSport) sqlFilters=status:active is_visible:true game_start_at:[\(startISO),\(endISO)) remove_after_at:(is.null OR gt(\(nowISO))) sport:\(sportFilter) rawRowCount=\(rows.count) afterClientFilterCount=\(filtered.count) clientDrop_parseStart=\(dropParseStart) wrongDay=\(dropWrongDay) removeAfterPast=\(dropRemoveAfterPast) notVisible=\(dropNotVisible) full=\(dropFull)"
            )
            print("[DiscoverPickupDiag] NOTE map query uses same remove_after_at OR-null filter as calendar dots.")
            for (i, row) in rows.prefix(5).enumerated() {
                let tit = row.title.replacingOccurrences(of: "\n", with: " ")
                print("[DiscoverPickupDiag] mapRawRow[\(i)] id=\(row.id.uuidString) title=\(tit) sport=\(row.sport) game_start_at=\(row.game_start_at) status=\(row.status) is_visible=\(row.is_visible) remove_after_at=\(row.remove_after_at ?? "nil")")
            }
            print("[DiscoverPickupPublic] selectedDayRawPickupRows=\(rows.count) sport=\(selectedSport) dayStartISO=\(startISO)")
            if rows.isEmpty {
                do {
                    let probe = try await supabase
                        .from("pickup_games")
                        .select("id", head: true, count: .exact)
                        .eq("status", value: "active")
                        .eq("is_visible", value: true)
                        .execute()
                    let total = probe.count ?? -1
                    print("[DiscoverPickupPublic] dayQueryEmpty activeVisiblePickupGamesVisibleToClientTotal=\(total) (if 0 likely no data or RLS blocks anon reads)")
                } catch {
                    print("[DiscoverPickupPublic] dayQueryEmpty anonCountProbeFailed error=\(error)")
                }
                await logPickupDiagnosticProbeUnfiltered(context: "mapRefresh_selectedDay_emptyWindow")
            }
            print("[DiscoverPickupPublic] pickupMapRowsFiltered=\(filtered.count) forSelectedCalendarDay")
#endif

            pickupGamesForDiscoverMap = filtered
            pickupDiscoverCoordinatorDirty = false
            if !preservePickupCalendarDotDatesCache {
                pickupGameCalendarDotDatesCache.removeAll()
            }
            invalidatePickupGameClusterAnnotationCache()
            if let sel = selectedPickupGameForMap, !filtered.contains(where: { $0.id == sel.id }) {
                clearPickupMapSelection()
            }
            if isAuthenticatedForSocialFeatures {
                await refreshPickupMyJoinRequestsForDiscoverGames(gameIds: filtered.map(\.id))
                await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
            }
            if isGuestDiscoverMode, filtered.isEmpty {
                loadDiscoverCalendarDots(around: selectedDate, reason: "pickup_map_refresh_guest_empty_day")
            }
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
        maxPlayers: Int?
    ) async throws -> PickupGameRow {
        guard let uid = currentUserAuthId else {
            throw PickupGameClientError.notSignedIn
        }
        guard canJoinPickupGames else {
            logBusinessUserGateBlocked(action: "createPickupGame")
            throw PickupGameClientError.businessAccountsCannotUsePickupGames
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
            cleanup_delay_hours: PickupGameAutoRemoval.hoursAfterGameStart
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
#if DEBUG
        print(
            "[DiscoverDotsSave] table=pickup_games op=insert id=\(row.id.uuidString.lowercased()) game_start_at=\(row.game_start_at) sport=\(row.sport) status=\(row.status) is_visible=\(row.is_visible) remove_after_at=\(row.remove_after_at ?? "nil")"
        )
#endif
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
#if DEBUG
        print(
            "[DiscoverDotsSave] table=pickup_games op=update id=\(row.id.uuidString.lowercased()) game_start_at=\(row.game_start_at) sport=\(row.sport) status=\(row.status) is_visible=\(row.is_visible) remove_after_at=\(row.remove_after_at ?? "nil")"
        )
#endif
        mergePickupInsertedLocally(row)
    }

    func logPickupGamesEditRequested(id: UUID) {
#if DEBUG
        print("[PickupGames] edit requested id=\(id.uuidString.lowercased())")
#endif
    }

    /// Permanently deletes the pickup game row (join requests cascade). Organizer-only via RLS.
    func deletePickupGame(id: UUID) async throws {
#if DEBUG
        print("[PickupGames] delete requested id=\(id.uuidString.lowercased())")
#endif
        do {
            try await supabase
                .from("pickup_games")
                .delete()
                .eq("id", value: id.uuidString.lowercased())
                .execute()
#if DEBUG
            print("[PickupGames] delete completed id=\(id.uuidString.lowercased())")
#endif
            applySoftRemovedPickupGameLocally(id: id)
            recomputeCalendarDotDates()
            refreshPickupJoinCachesAfterMutation()
            await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
            await loadMyPickupGameJoinRequestsForFollowing()
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
        pickupMyLatestJoinRequestByGameId.removeValue(forKey: id)
        pickupOrganizerJoinStatsByGameId.removeValue(forKey: id)
        pickupGamesFollowingTabCache.removeValue(forKey: id)
    }

    private func logPickupDiagnosticProbeUnfiltered(context: String) async {
#if DEBUG
        do {
            let probe: [PickupGameAnonDiagnosticProbeRow] = try await supabase
                .from("pickup_games")
                .select("id,title,sport,game_start_at,status,is_visible,remove_after_at")
                .limit(10)
                .execute()
                .value
            print(
                "[DiscoverPickupDiag] op=anonTableProbe context=\(context) table=pickup_games NO_date_NO_sport_filters diagnosticUnfilteredLimit10_count=\(probe.count) hint=0=>empty_table_or_RLS_blocks_all_reads;>0_but_window_queries_0=>date_or_remove_after_or_status_or_sport_or_visibility_filters"
            )
            for (i, r) in probe.prefix(5).enumerated() {
                let tid = r.id?.uuidString ?? "nil"
                let tit = (r.title ?? "?").replacingOccurrences(of: "\n", with: " ")
                let sp = r.sport ?? "?"
                let gst = r.game_start_at ?? "nil"
                let st = r.status ?? "nil"
                let vis = r.is_visible.map(String.init(describing:)) ?? "nil"
                let rem = r.remove_after_at ?? "nil"
                print("[DiscoverPickupDiag] probeRow[\(i)] id=\(tid) title=\(tit) sport=\(sp) game_start_at=\(gst) status=\(st) is_visible=\(vis) remove_after_at=\(rem)")
            }
        } catch {
            print("[DiscoverPickupDiag] op=anonTableProbe context=\(context) FAILED error=\(error)")
        }
#endif
    }
}
