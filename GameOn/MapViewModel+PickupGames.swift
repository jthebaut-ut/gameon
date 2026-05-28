import CoreLocation
import Foundation
import Supabase

let pickupGamesSelectColumns =
    "id,creator_user_id,creator_email,title,sport,description,game_format,skill_level,game_start_at,end_time,address,city,state,latitude,longitude,is_visible,players_needed,play_environment,participant_preference,age_min,age_max,is_free,entry_fee_amount,max_players,status,approved_join_count,cleanup_delay_hours,remove_after_at,created_at,updated_at"

private let pickupOrganizerSettingsHistoryUserClearedIdsKeyPrefix = "gameon.settings.pickupOrganizerHistoryClearedIds."
private let pickupGamesDiscoverCacheTTL: TimeInterval = 150
private let pickupGamesDiscoverCacheMaxEntries = 16

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

private struct PickupDiscoverVisibilityEvaluation {
    let included: Bool
    let rejectionReason: String
    let gameDate: Date?
    let withinVisibleRegion: Bool
    let filteredByBounds: Bool
    let filteredByDate: Bool
    let filteredBySport: Bool
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

    private static let myPickupGamesForSettingsFreshnessInterval: TimeInterval = 60

    private static let pickupHistoryClearLogISO8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func pickupGamesDiscoverCacheKey(dayStart: Date, sport: String) -> String {
        let regionKey: String
        if let bounds = currentMapRegionBounds() {
            regionKey = [
                String(format: "%.3f", bounds.minLat),
                String(format: "%.3f", bounds.maxLat),
                String(format: "%.3f", bounds.minLon),
                String(format: "%.3f", bounds.maxLon)
            ].joined(separator: ",")
        } else {
            regionKey = "no-region"
        }
        return "pickupGames|\(pickupDebugYMD(dayStart))|\(sport)|\(regionKey)"
    }

    private func storePickupGamesDiscoverCache(_ rows: [PickupGameRow], cacheKey: String) {
        pickupGamesDiscoverCache[cacheKey] = (rows: rows, fetchedAt: Date())
        prunePickupGamesDiscoverCacheIfNeeded()
    }

    private func prunePickupGamesDiscoverCacheIfNeeded() {
        guard pickupGamesDiscoverCache.count > pickupGamesDiscoverCacheMaxEntries else { return }
        let sorted = pickupGamesDiscoverCache
            .map { ($0.key, $0.value.fetchedAt) }
            .sorted { $0.1 < $1.1 }
        let dropCount = pickupGamesDiscoverCache.count - pickupGamesDiscoverCacheMaxEntries
        for index in 0..<max(0, dropCount) {
            pickupGamesDiscoverCache.removeValue(forKey: sorted[index].0)
        }
    }

    private static func readPickupOrganizerSettingsHistoryUserClearedIds(userId: UUID) -> Set<UUID> {
        let raw = UserDefaults.standard.string(forKey: pickupOrganizerSettingsHistoryUserClearedIdsKeyPrefix + userId.uuidString.lowercased()) ?? ""
        return Set(
            raw.split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap { UUID(uuidString: $0) }
        )
    }

    private static func writePickupOrganizerSettingsHistoryUserClearedIds(userId: UUID, ids: Set<UUID>) {
        let capped = ids.sorted { $0.uuidString < $1.uuidString }.prefix(240)
        let raw = capped.map { $0.uuidString.lowercased() }.joined(separator: ",")
        UserDefaults.standard.set(raw, forKey: pickupOrganizerSettingsHistoryUserClearedIdsKeyPrefix + userId.uuidString.lowercased())
    }

    /// Fan Following card / organizer History: human-readable auto-clear line (matches ``PickupGameRow/pickupHistoryClientCleanupDeadline()``).
    func pickupHistoryAutoClearCaption(forPickupGameId id: UUID) -> String {
        guard let row = resolvedPickupGameRow(for: id),
              let deadline = row.pickupHistoryClientCleanupDeadline() else {
            return "Auto-clears 12h after start"
        }
        return "Auto-clears \(deadline.formatted(date: .abbreviated, time: .shortened))"
    }

    /// Organizer Settings → History: hide this removed game locally (does not delete ratings or server rows).
    func markPickupOrganizerSettingsHistoryUserCleared(pickupGameId: UUID) {
        guard let uid = currentUserAuthId else { return }
        let cleanupAt = myRemovedPickupGamesForSettings.first(where: { $0.id == pickupGameId })?.pickupHistoryClientCleanupDeadline()
        var s = Self.readPickupOrganizerSettingsHistoryUserClearedIds(userId: uid)
        s.insert(pickupGameId)
        Self.writePickupOrganizerSettingsHistoryUserClearedIds(userId: uid, ids: s)
        myRemovedPickupGamesForSettings.removeAll { $0.id == pickupGameId }
#if DEBUG
        let cleanupStr = cleanupAt.map { Self.pickupHistoryClearLogISO8601.string(from: $0) } ?? "nil"
        print("[PickupHistoryClear] gameId=\(pickupGameId.uuidString.lowercased())")
        print("[PickupHistoryClear] cleanupAt=\(cleanupStr)")
        print("[PickupHistoryClear] userTappedClear=true")
        print("[PickupHistoryClear] autoExpired=false")
        print("[PickupHistoryClear] visible=false")
#endif
        showSocialActionToast("Removed from history", isError: false)
    }

    private func shouldShowRemovedPickupInOrganizerHistory(row: PickupGameRow, now: Date, clearedIds: Set<UUID>) -> Bool {
        let gid = row.id
        let cleanupAt = row.pickupHistoryClientCleanupDeadline()
        let userCleared = clearedIds.contains(gid)
        let autoExpired = cleanupAt.map { now >= $0 } ?? false
        let visible = !userCleared && !autoExpired
#if DEBUG
        let cleanupStr = cleanupAt.map { Self.pickupHistoryClearLogISO8601.string(from: $0) } ?? "nil"
        print("[PickupHistoryClear] gameId=\(gid.uuidString.lowercased())")
        print("[PickupHistoryClear] cleanupAt=\(cleanupStr)")
        print("[PickupHistoryClear] userTappedClear=false")
        print("[PickupHistoryClear] autoExpired=\(autoExpired)")
        print("[PickupHistoryClear] visible=\(visible)")
#endif
        return visible
    }

    func findOverlappingPickupGameAtLocation(
        newStart: Date,
        newEnd: Date,
        latitude: Double?,
        longitude: Double?,
        address: String?,
        city: String?,
        state: String?,
        excluding excludedId: UUID? = nil
    ) async throws -> PickupGameRow? {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: newStart)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        let startISO = PickupGameModels.encodeSupabaseTimestamptz(dayStart)
        let endISO = PickupGameModels.encodeSupabaseTimestamptz(dayEnd)
        let nowISO = PickupGameModels.encodeSupabaseTimestamptz(Date())

        let rows: [PickupGameRow] = try await supabase
            .from("pickup_games")
            .select(pickupGamesSelectColumns)
            .gte("game_start_at", value: startISO)
            .lt("game_start_at", value: endISO)
            .or(pickupGamesDiscoverRemoveAfterOrFilter(nowISO: nowISO))
            .eq("status", value: "active")
            .eq("is_visible", value: true)
            .limit(300)
            .execute()
            .value

        return rows.first { row in
            if row.id == excludedId { return false }
            guard Self.pickupLocationMatches(
                row: row,
                latitude: latitude,
                longitude: longitude,
                address: address,
                city: city,
                state: state
            ) else {
                return false
            }
            guard let existingStart = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at),
                  let existingEnd = PickupGameModels.endDate(for: row) else {
                return false
            }
            return newStart < existingEnd && newEnd > existingStart
        }
    }

    private static func pickupLocationMatches(
        row: PickupGameRow,
        latitude: Double?,
        longitude: Double?,
        address: String?,
        city: String?,
        state: String?
    ) -> Bool {
        if let latitude,
           let longitude,
           let rowLat = row.latitude,
           let rowLon = row.longitude {
            let candidate = CLLocation(latitude: latitude, longitude: longitude)
            let existing = CLLocation(latitude: rowLat, longitude: rowLon)
            return candidate.distance(from: existing) <= 80
        }

        let lhs = [
            normalizedPickupLocationComponent(address),
            normalizedPickupLocationComponent(city),
            normalizedPickupLocationComponent(state)
        ].joined(separator: "|")
        let rhs = [
            normalizedPickupLocationComponent(row.address),
            normalizedPickupLocationComponent(row.city),
            normalizedPickupLocationComponent(row.state)
        ].joined(separator: "|")
        return !lhs.replacingOccurrences(of: "|", with: "").isEmpty && lhs == rhs
    }

    private static func normalizedPickupLocationComponent(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased() ?? ""
    }

    func clearPickupMapSelection() {
        selectedPickupGameForMap = nil
        selectedPickupPlaceForMap = nil
    }

    func selectPickupGameOnMap(_ row: PickupGameRow) {
        selectedBar = nil
        selectedEvent = nil
        selectedPickupPlaceForMap = nil
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
            selectedPickupPlaceForMap = nil
        case .pickupGames:
            selectedBar = nil
            selectedEvent = nil
            discoverRemotePreviewHoldVenueId = nil
        }
    }

    func onDiscoverMapBecamePickupGamesFromUserToggle() {
        Task { @MainActor in
            guard discoverMapContentMode == .pickupGames else { return }
            guard discoverPickupSubMode == .games else {
                await refreshPickupPlacesForDiscoverMap()
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
            print("[PickupGamesWarmCache] coalesced=true force=\(force)")
            await existing.value
            if !force { return }
            // A forced refresh usually follows a mutation. Do not let an older
            // in-flight read satisfy it, because that can republish stale rows.
            while refreshPickupGamesForDiscoverMapCoalescingTask != nil {
                await Task.yield()
            }
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

    func warmPreloadPickupGamesForCurrentContext() async {
        let dayStart = Calendar.current.startOfDay(for: selectedDate)
        let sport = selectedSport
        let cacheKey = pickupGamesDiscoverCacheKey(dayStart: dayStart, sport: sport)
        if let cached = pickupGamesDiscoverCache[cacheKey],
           Date().timeIntervalSince(cached.fetchedAt) < pickupGamesDiscoverCacheTTL {
            print("[PickupGamesWarmCache] warmCacheHit=true key=\(cacheKey) rows=\(cached.rows.count)")
            return
        }
        print("[PickupGamesWarmCache] warmFetchStarted key=\(cacheKey)")
        await refreshPickupGamesForDiscoverMap(force: true, preservePickupCalendarDotDatesCache: true)
    }

    func refreshPickupGameAfterDiscoverPickupPlaceCreate(_ row: PickupGameRow) async {
#if DEBUG
        print("[PickupCreateRefreshDebug] source=pickupPlaceCreate")
        print("[PickupCreateRefreshDebug] insertedGameId=\(row.id.uuidString.lowercased())")
#endif
        if let createdStart = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) {
            selectedDate = createdStart
        }

        discoverMapContentMode = .pickupGames
        discoverPickupSubMode = .games
        selectedBar = nil
        selectedPickupPlaceForMap = nil

        mergePickupInsertedLocally(row)
        let localMerge = pickupGamesForDiscoverMap.contains { $0.id == row.id }
        pickupGameCalendarDotDatesCache.removeAll()
        invalidatePickupGameClusterAnnotationCache()
        invalidateCalendarTabEventsListCache()
        markPickupDiscoverMapDataDirtyForNextRefresh()

#if DEBUG
        print("[PickupCreateRefreshDebug] localMerge=\(localMerge)")
        print("[PickupCreateRefreshDebug] cacheInvalidated=true")
        print("[PickupCreateRefreshDebug] selectedDate=\(pickupDebugYMD(Calendar.current.startOfDay(for: selectedDate)))")
        print("[PickupCreateRefreshDebug] mapRefreshStarted=true")
#endif
        await refreshPickupGamesForDiscoverMap(force: true, preservePickupCalendarDotDatesCache: false)

        // Keep the just-created game visible even if Supabase read-after-write
        // replication or an older refresh briefly misses it.
        mergePickupInsertedLocally(row)
        if let currentUserAuthId, row.creator_user_id == currentUserAuthId {
            await loadMyPickupGamesForSettings(forceRefresh: true, reason: "pickupPlaceCreate")
        }

        recomputeCalendarDotDates(force: true)
#if DEBUG
        print("[PickupCreateRefreshDebug] calendarRefreshStarted=true")
#endif
        loadDiscoverCalendarDots(around: selectedDate, reason: "pickup_place_create")

        let visibleRow = pickupGamesVisibleAsMapPins(for: currentMapRegionBounds())
            .first { $0.id == row.id }
        if let visibleRow {
            selectPickupGameOnMap(visibleRow)
        }
#if DEBUG
        print("[PickupCreateRefreshDebug] visibleOnMapAfterRefresh=\(visibleRow != nil)")
#endif
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

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedDate)
        let requestSport = selectedSport
        let requestID = UUID()
        let cacheKey = pickupGamesDiscoverCacheKey(dayStart: dayStart, sport: requestSport)
        pickupGamesDiscoverRequestID = requestID
        pickupDiscoverEnrichmentRequestID = requestID
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else {
            isLoadingPickupGamesForMap = false
            markPickupDiscoverMapDataDirtyForNextRefresh()
            print("[PickupGamesWarmCache] skipped reason=invalidDay preservedRows=\(pickupGamesForDiscoverMap.count)")
            return
        }
        let cached = pickupGamesDiscoverCache[cacheKey]
        let cachedIsFresh = cached.map { Date().timeIntervalSince($0.fetchedAt) < pickupGamesDiscoverCacheTTL } ?? false
        if !force, let cached {
            pickupGamesForDiscoverMap = cached.rows
            pickupDiscoverCoordinatorDirty = false
            isLoadingPickupGamesForMap = false
            invalidatePickupGameClusterAnnotationCache()
            print("[PickupGamesWarmCache] immediateCachePublish=true key=\(cacheKey) rows=\(cached.rows.count) fresh=\(cachedIsFresh)")
            if cachedIsFresh {
                if let sel = selectedPickupGameForMap, !cached.rows.contains(where: { $0.id == sel.id }) {
                    clearPickupMapSelection()
                }
                return
            }
        } else {
            print("[PickupGamesWarmCache] cacheHit=false key=\(cacheKey)")
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

            if requestSport != "All" {
                query = query.eq("sport", value: requestSport)
            }

            let rows: [PickupGameRow] = try await query
                .limit(400)
                .execute()
                .value

            var dropParseStart = 0
            var dropWrongDay = 0
            var dropRemoveAfterPast = 0
            var dropNotVisible = 0
            var fullRowsIncluded = 0
            var filtered: [PickupGameRow] = []
            filtered.reserveCapacity(rows.count)
            for row in rows {
                guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else {
                    dropParseStart += 1
                    continue
                }
                if !cal.isDate(start, inSameDayAs: dayStart) {
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
                    fullRowsIncluded += 1
                }
                filtered.append(row)
#if DEBUG
                logPickupVisibilityDebug(
                    row: row,
                    includedInDiscover: true,
                    excludedBecauseFull: false,
                    selectedDay: dayStart,
                    requestStatus: nil
                )
#endif
            }

#if DEBUG
            let sportFilter = requestSport == "All" ? "(none)" : requestSport
            print("[PickupVisibilityDebug] serverRowsLoaded=\(rows.count)")
            print(
                "[DiscoverPickupDiag] op=mapRefreshDay table=pickup_games selectedCalendarDay=\(pickupDebugYMD(dayStart)) dayStartISO=\(startISO) dayEndExclusiveISO=\(endISO) nowISO=\(nowISO) selectedSport=\(requestSport) sqlFilters=status:active is_visible:true game_start_at:[\(startISO),\(endISO)) remove_after_at:(is.null OR gt(\(nowISO))) sport:\(sportFilter) rawRowCount=\(rows.count) afterClientFilterCount=\(filtered.count) clientDrop_parseStart=\(dropParseStart) wrongDay=\(dropWrongDay) removeAfterPast=\(dropRemoveAfterPast) notVisible=\(dropNotVisible) fullIncluded=\(fullRowsIncluded)"
            )
            print("[DiscoverPickupDiag] NOTE map query uses same remove_after_at OR-null filter as calendar dots.")
            for (i, row) in rows.prefix(5).enumerated() {
                let tit = row.title.replacingOccurrences(of: "\n", with: " ")
                print("[DiscoverPickupDiag] mapRawRow[\(i)] id=\(row.id.uuidString) title=\(tit) sport=\(row.sport) game_start_at=\(row.game_start_at) status=\(row.status) is_visible=\(row.is_visible) remove_after_at=\(row.remove_after_at ?? "nil")")
            }
            print("[DiscoverPickupPublic] selectedDayRawPickupRows=\(rows.count) sport=\(requestSport) dayStartISO=\(startISO)")
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

            guard pickupGamesDiscoverRequestID == requestID else {
                print("[PickupGamesWarmCache] staleDiscard=true key=\(cacheKey)")
                return
            }
            storePickupGamesDiscoverCache(filtered, cacheKey: cacheKey)
            pickupGamesForDiscoverMap = filtered
            pickupDiscoverCoordinatorDirty = false
            isLoadingPickupGamesForMap = false
            print("[PickupGamesWarmCache] networkPublish=true key=\(cacheKey) rows=\(filtered.count)")
            print("[PickupPerf] coreRowsPublished count=\(filtered.count)")
            print("[PickupPerf] primaryLoadingClearedBeforeEnrichment=true")
            if !preservePickupCalendarDotDatesCache {
                pickupGameCalendarDotDatesCache.removeAll()
            }
            invalidatePickupGameClusterAnnotationCache()
            if let sel = selectedPickupGameForMap, !filtered.contains(where: { $0.id == sel.id }) {
                clearPickupMapSelection()
            }
            let gameIDs = filtered.map(\.id)
            let creatorIDs = Set(filtered.map(\.creator_user_id))
            Task { @MainActor [weak self] in
                await self?.runPickupDiscoverEnrichmentAfterCorePublish(
                    gameIDs: gameIDs,
                    creatorUserIDs: creatorIDs,
                    requestID: requestID,
                    selectedDay: dayStart,
                    selectedSport: requestSport
                )
            }
            if isGuestDiscoverMode, filtered.isEmpty {
                loadDiscoverCalendarDots(around: selectedDate, reason: "pickup_map_refresh_guest_empty_day")
            }
            invalidateCalendarTabEventsListCache()
        } catch {
            if pickupGamesDiscoverRequestID == requestID {
                isLoadingPickupGamesForMap = false
            }
            print("[PickupGamesWarmCache] networkFailedPreservedRows=\(pickupGamesForDiscoverMap.count) key=\(cacheKey)")
#if DEBUG
            print("[PickupGames] refreshDiscover failed:", error)
#endif
            markPickupDiscoverMapDataDirtyForNextRefresh()
        }
    }

    private func pickupDiscoverEnrichmentIsCurrent(
        requestID: UUID,
        selectedDay: Date,
        selectedSport: String
    ) -> Bool {
        pickupDiscoverEnrichmentRequestID == requestID &&
            Calendar.current.isDate(selectedDate, inSameDayAs: selectedDay) &&
            self.selectedSport == selectedSport
    }

    private func runPickupDiscoverEnrichmentAfterCorePublish(
        gameIDs: [UUID],
        creatorUserIDs: Set<UUID>,
        requestID: UUID,
        selectedDay: Date,
        selectedSport: String
    ) async {
        guard pickupDiscoverEnrichmentIsCurrent(
            requestID: requestID,
            selectedDay: selectedDay,
            selectedSport: selectedSport
        ) else {
            print("[PickupPerf] enrichmentDiscarded reason=staleRequest")
            return
        }

        print("[PickupPerf] enrichmentStarted count=\(gameIDs.count)")

        if isAuthenticatedForSocialFeatures {
            do {
                if let latest = try await fetchPickupMyJoinRequestsForDiscoverGames(gameIds: gameIDs) {
                    guard pickupDiscoverEnrichmentIsCurrent(
                        requestID: requestID,
                        selectedDay: selectedDay,
                        selectedSport: selectedSport
                    ) else {
                        print("[PickupPerf] enrichmentDiscarded reason=staleRequest")
                        return
                    }
                    applyPickupMyJoinRequestsForDiscoverGames(gameIds: gameIDs, latest: latest)
                }
            } catch {
                #if DEBUG
                print("[PickupGames] discover enrichment join requests failed:", error)
                #endif
            }

            guard pickupDiscoverEnrichmentIsCurrent(
                requestID: requestID,
                selectedDay: selectedDay,
                selectedSport: selectedSport
            ) else {
                print("[PickupPerf] enrichmentDiscarded reason=staleRequest")
                return
            }
            await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: false)
        }

        guard pickupDiscoverEnrichmentIsCurrent(
            requestID: requestID,
            selectedDay: selectedDay,
            selectedSport: selectedSport
        ) else {
            print("[PickupPerf] enrichmentDiscarded reason=staleRequest")
            return
        }
        if !isGuestDiscoverMode {
            await loadPickupCreatorProfilesIfNeeded(creatorUserIds: creatorUserIDs)
        }

        guard pickupDiscoverEnrichmentIsCurrent(
            requestID: requestID,
            selectedDay: selectedDay,
            selectedSport: selectedSport
        ) else {
            print("[PickupPerf] enrichmentDiscarded reason=staleRequest")
            return
        }
        print("[PickupPerf] enrichmentCompleted")
    }

    func loadMyPickupGamesForSettings(forceRefresh: Bool = false, reason: String = "ordinary") async {
        if let inFlight = myPickupGamesLightweightLoadTask {
#if DEBUG
            print("[StartupPrefetchDebug] pickupMine coalesced=true")
            print("[PickupPerf] screen=Going mode=Hosting rowCount=\(myPickupGamesForSettings.count + myRemovedPickupGamesForSettings.count) renderPath=loadMyPickupGamesForSettings freshnessSkip=false forcedReload=\(forceRefresh) reason=\(reason) coalesced=true")
#endif
            await inFlight.value
            if !forceRefresh { return }
        }

        if forceRefresh {
            lastMyPickupGamesLightweightLoadAt = nil
#if DEBUG
            print("[PickupPerf] screen=Going mode=Hosting rowCount=\(myPickupGamesForSettings.count + myRemovedPickupGamesForSettings.count) renderPath=loadMyPickupGamesForSettings freshnessSkip=false forcedReload=true reason=\(reason)")
#endif
        } else if let lastMyPickupGamesLightweightLoadAt {
            let age = Date().timeIntervalSince(lastMyPickupGamesLightweightLoadAt)
            if age < Self.myPickupGamesForSettingsFreshnessInterval {
#if DEBUG
                print("[PickupPerf] screen=Going mode=Hosting rowCount=\(myPickupGamesForSettings.count + myRemovedPickupGamesForSettings.count) renderPath=loadMyPickupGamesForSettings freshnessSkip=true forcedReload=false reason=\(reason) age=\(String(format: "%.1f", age))")
#endif
                return
            }
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.loadMyPickupGamesForSettingsNow(reason: reason)
        }
        myPickupGamesLightweightLoadTask = task
        await task.value
        myPickupGamesLightweightLoadTask = nil
    }

    private func loadMyPickupGamesForSettingsNow(reason: String) async {
        guard canFanUsePickupGamesUI, let uid = currentUserAuthId else {
            myPickupGamesForSettings = []
            myRemovedPickupGamesForSettings = []
            pendingPickupGameJoinRequestCount = 0
            await stopPickupJoinRequestBadgeRealtime()
#if DEBUG
            print("[PickupPerf] screen=Going mode=Hosting rowCount=0 renderPath=loadMyPickupGamesForSettings freshnessSkip=false forcedReload=false reason=\(reason) skipped=featureUnavailable")
#endif
            return
        }

        do {
            let rows: [PickupGameRow] = try await supabase
                .from("pickup_games")
                .select(pickupGamesSelectColumns)
                .eq("creator_user_id", value: uid.uuidString.lowercased())
                .in("status", values: ["active", "removed"])
                .order("game_start_at", ascending: false)
                .limit(400)
                .execute()
                .value
            let activeRows = rows.filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "active" }
            let removedRows = rows.filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "removed" }
                .sorted { a, b in
                    let ua = PickupGameModels.parseSupabaseTimestamptz(a.updated_at ?? "") ?? .distantPast
                    let ub = PickupGameModels.parseSupabaseTimestamptz(b.updated_at ?? "") ?? .distantPast
                    if ua != ub { return ua > ub }
                    return a.id.uuidString > b.id.uuidString
                }
            myPickupGamesForSettings = activeRows
            let clearedHistoryIds = Self.readPickupOrganizerSettingsHistoryUserClearedIds(userId: uid)
            let now = Date()
            myRemovedPickupGamesForSettings = removedRows.filter { row in
                shouldShowRemovedPickupInOrganizerHistory(row: row, now: now, clearedIds: clearedHistoryIds)
            }
            let ownedIds = Set(rows.map(\.id))
            pickupOrganizerWithdrawnRequestsByGameId = pickupOrganizerWithdrawnRequestsByGameId.filter { ownedIds.contains($0.key) }
            pickupOrganizerApprovedJoinerUserIdsByGameId = pickupOrganizerApprovedJoinerUserIdsByGameId.filter { ownedIds.contains($0.key) }
            await loadOrganizerPickupRequestSummaries(gameIds: rows.map(\.id))
            await loadOrganizerWithdrawnPickupRequestsForSettings(gameIds: rows.map(\.id))
            await loadOrganizerApprovedPickupJoinersForSettings(gameIds: rows.map(\.id))
            lastMyPickupGamesLightweightLoadAt = Date()
#if DEBUG
            print("[PickupPerf] screen=Going mode=Hosting rowCount=\(activeRows.count + myRemovedPickupGamesForSettings.count) renderPath=loadMyPickupGamesForSettings freshnessSkip=false forcedReload=false reason=\(reason)")
#endif
        } catch {
#if DEBUG
            print("[PickupGames] loadMine failed:", error)
#endif
        }
        await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
    }

    private func markMyPickupGamesForSettingsStaleAfterMutation(row: PickupGameRow, reason: String) {
        guard row.creator_user_id == currentUserAuthId else { return }
        lastMyPickupGamesLightweightLoadAt = nil
#if DEBUG
        print("[PickupPerf] screen=Going mode=Hosting rowCount=\(myPickupGamesForSettings.count + myRemovedPickupGamesForSettings.count) renderPath=loadMyPickupGamesForSettings freshnessSkip=false forcedReload=true reason=\(reason)")
#endif
    }

    func insertPickupGame(
        title: String,
        sport: String,
        description: String?,
        skillLevel: String,
        gameStartAt: Date,
        endTime: Date,
        address: String?,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?,
        playersNeeded: Int,
        playEnvironment: String,
        participantPreference: String,
        ageMin: Int? = nil,
        ageMax: Int? = nil,
        isFree: Bool,
        entryFeeAmount: Double?,
        maxPlayers: Int?,
        gameFormat: GameType = .pickup
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
        let gameStartISO = PickupGameModels.encodeSupabaseTimestamptz(gameStartAt)
        let endTimeISO = PickupGameModels.encodeSupabaseTimestamptz(endTime)
        let removeISO = PickupGameModels.encodedPickupRemoveAfterAt(forEncodedGameStart: gameStartISO)
        PickupExpirationEditDebug.log(
            oldGameStartAt: nil,
            newGameStartAt: gameStartISO,
            cleanupDelayHours: PickupGameAutoRemoval.hoursAfterGameStart,
            computedRemoveAfterAt: removeISO
        )
        let payload = PickupGameInsert(
            creator_user_id: uid,
            creator_email: normalizedFanEmailForPickup(),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            sport: sport.trimmingCharacters(in: .whitespacesAndNewlines),
            description: emptyStringToNil(description),
            game_format: gameFormat.rawValue,
            skill_level: skillLevel,
            game_start_at: gameStartISO,
            end_time: endTimeISO,
            address: emptyStringToNil(address),
            city: emptyStringToNil(city),
            state: emptyStringToNil(state),
            latitude: latitude,
            longitude: longitude,
            is_visible: true,
            players_needed: playersNeededClamped,
            play_environment: playEnvironment,
            participant_preference: participantPreference,
            age_min: ageMin,
            age_max: ageMax,
            is_free: isFree,
            entry_fee_amount: feePayload,
            max_players: maxPlayersClamped,
            cleanup_delay_hours: PickupGameAutoRemoval.hoursAfterGameStart,
            remove_after_at: removeISO
        ).withCanonicalPickupCleanupDelay()

#if DEBUG
        print("[PickupVisibilityDebug] discoverVisibilityForced=true")
#endif
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
        print("[PickupGameExpirationDebug] game_start_at=\(row.game_start_at)")
        print("[PickupGameExpirationDebug] remove_after_at=\(row.remove_after_at ?? "nil")")
        print("[PickupGameExpirationDebug] hoursAfterStart=\(PickupGameAutoRemoval.hoursAfterGameStart)")
        print(
            "[DiscoverDotsSave] table=pickup_games op=insert id=\(row.id.uuidString.lowercased()) game_start_at=\(row.game_start_at) sport=\(row.sport) status=\(row.status) is_visible=\(row.is_visible) remove_after_at=\(row.remove_after_at ?? "nil")"
        )
#endif
        mergePickupInsertedLocally(row)
        FanGeoAnalyticsService.recordGameCreated(
            gameId: row.id,
            city: row.city,
            region: row.state,
            country: nil,
            sport: row.sport
        )
        await awardFanXP(
            userId: uid,
            amount: 20,
            source: FanXPSource.pickupCreate,
            sourceId: row.id
        )
        return row
    }

    func updatePickupGame(id: UUID, full: PickupGameFullUpdate) async throws {
        let normalized = full.withCanonicalPickupCleanupDelay()
        let oldStart = resolvedPickupGameRow(for: id)?.game_start_at
        PickupExpirationEditDebug.log(
            oldGameStartAt: oldStart,
            newGameStartAt: normalized.game_start_at,
            cleanupDelayHours: PickupGameAutoRemoval.hoursAfterGameStart,
            computedRemoveAfterAt: normalized.remove_after_at
        )
#if DEBUG
        print("[PickupVisibilityDebug] discoverVisibilityForced=true")
#endif
        let updated: [PickupGameRow] = try await supabase
            .from("pickup_games")
            .update(normalized)
            .eq("id", value: id.uuidString.lowercased())
            .select(pickupGamesSelectColumns)
            .execute()
            .value

        guard let row = updated.first else {
            throw PickupGameClientError.missingRowAfterWrite
        }
#if DEBUG
        print("[PickupGameExpirationDebug] game_start_at=\(row.game_start_at)")
        print("[PickupGameExpirationDebug] remove_after_at=\(row.remove_after_at ?? "nil")")
        print("[PickupGameExpirationDebug] hoursAfterStart=\(PickupGameAutoRemoval.hoursAfterGameStart)")
        print(
            "[DiscoverDotsSave] table=pickup_games op=update id=\(row.id.uuidString.lowercased()) game_start_at=\(row.game_start_at) sport=\(row.sport) status=\(row.status) is_visible=\(row.is_visible) remove_after_at=\(row.remove_after_at ?? "nil")"
        )
#endif
        mergePickupInsertedLocally(row)
    }

    /// Updates `players_needed` / `max_players` after start; also re-sends `game_start_at` + expiration so `remove_after_at` stays `start + 12h`.
    func updatePickupGameRosterCapacity(id: UUID, playersNeeded: Int, maxPlayers: Int?) async throws {
        guard let existing = resolvedPickupGameRow(for: id) else {
            throw PickupGameClientError.pickupGameNotFound
        }
        let gameStartISO = existing.game_start_at
        let removeISO = PickupGameModels.encodedPickupRemoveAfterAt(forEncodedGameStart: gameStartISO)
        PickupExpirationEditDebug.log(
            oldGameStartAt: gameStartISO,
            newGameStartAt: gameStartISO,
            cleanupDelayHours: PickupGameAutoRemoval.hoursAfterGameStart,
            computedRemoveAfterAt: removeISO
        )
        let payload = PickupGameRosterCapacityUpdate(
            players_needed: min(20, max(1, playersNeeded)),
            max_players: maxPlayers,
            game_start_at: gameStartISO,
            cleanup_delay_hours: PickupGameAutoRemoval.hoursAfterGameStart,
            remove_after_at: removeISO
        )
        let updated: [PickupGameRow] = try await supabase
            .from("pickup_games")
            .update(payload)
            .eq("id", value: id.uuidString.lowercased())
            .select(pickupGamesSelectColumns)
            .execute()
            .value

        guard let row = updated.first else {
            throw PickupGameClientError.missingRowAfterWrite
        }
#if DEBUG
        print("[PickupGameExpirationDebug] game_start_at=\(row.game_start_at)")
        print("[PickupGameExpirationDebug] remove_after_at=\(row.remove_after_at ?? "nil")")
        print("[PickupGameExpirationDebug] hoursAfterStart=\(PickupGameAutoRemoval.hoursAfterGameStart)")
        print(
            "[DiscoverDotsSave] table=pickup_games op=roster_capacity id=\(row.id.uuidString.lowercased()) game_start_at=\(row.game_start_at) sport=\(row.sport) status=\(row.status) is_visible=\(row.is_visible) remove_after_at=\(row.remove_after_at ?? "nil")"
        )
#endif
        mergePickupInsertedLocally(row)
    }

    func logPickupGamesEditRequested(id: UUID) {
#if DEBUG
        print("[PickupGames] edit requested id=\(id.uuidString.lowercased())")
#endif
    }

    /// Organizer cancels the pickup (soft delete). Join requests are cancelled server-side; ratings/history rows are not deleted.
    func deletePickupGame(id: UUID) async throws {
        guard canJoinPickupGames else {
            logBusinessUserGateBlocked(action: "joinPickupGame")
            throw PickupGameClientError.businessAccountsCannotUsePickupGames
        }
        guard let uid = currentUserAuthId else {
            throw PickupGameClientError.notSignedIn
        }
        guard let existing = resolvedPickupGameRow(for: id) else {
            throw PickupGameClientError.pickupGameNotFound
        }
        guard existing.creator_user_id == uid else {
            throw PickupGameClientError.pickupGameNotOrganizer
        }

        let oldStatus = existing.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nowISO = PickupGameModels.encodeSupabaseTimestamptz(Date())

        let affectedResponse = try await supabase
            .from("pickup_game_requests")
            .select("id", count: .exact)
            .eq("pickup_game_id", value: id.uuidString.lowercased())
            .in("status", values: ["pending", "approved"])
            .limit(1)
            .execute()
        let affectedRequests = affectedResponse.count ?? 0

        let softPayload = PickupGameSoftRemoveUpdate(status: "removed", is_visible: false, remove_after_at: nowISO)
        let updatedRows: [PickupGameRow] = try await supabase
            .from("pickup_games")
            .update(softPayload)
            .eq("id", value: id.uuidString.lowercased())
            .eq("creator_user_id", value: uid.uuidString.lowercased())
            .select(pickupGamesSelectColumns)
            .execute()
            .value
        guard let updated = updatedRows.first else {
            throw PickupGameClientError.missingRowAfterWrite
        }

        do {
            try await supabase
                .from("pickup_game_requests")
                .update(PickupJoinRequestStatusUpdate(status: "cancelled"))
                .eq("pickup_game_id", value: id.uuidString.lowercased())
                .in("status", values: ["pending", "approved"])
                .execute()
        } catch {
#if DEBUG
            print("[PickupGames] soft delete join request bulk cancel failed id=\(id.uuidString.lowercased()) error=\(error)")
#endif
            throw error
        }

        mergePickupGameAfterOrganizerSoftDelete(updated)
        recomputeCalendarDotDates()
        refreshPickupJoinCachesAfterMutation()
        await loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
        await loadMyPickupGameJoinRequestsForFollowing(
            forceRefresh: true,
            reason: "pickupGameDeleted"
        )
        pickupOrganizerRequestsSyncGeneration &+= 1
        pickupJoinRequestUiRevision &+= 1
        await refreshPickupGamesForDiscoverMap(force: true, preservePickupCalendarDotDatesCache: true)

#if DEBUG
        let vis = updated.is_visible ? "true" : "false"
        let newSt = updated.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        print("[PickupGameDelete] gameId=\(id.uuidString.lowercased())")
        print("[PickupGameDelete] oldStatus=\(oldStatus)")
        print("[PickupGameDelete] newStatus=\(newSt)")
        print("[PickupGameDelete] affectedRequests=\(affectedRequests)")
        print("[PickupGameDelete] visibleAfter=\(vis)")
#endif
    }

    private func mergePickupGameAfterOrganizerSoftDelete(_ row: PickupGameRow) {
        markMyPickupGamesForSettingsStaleAfterMutation(row: row, reason: "mutationSoftDelete")
        myPickupGamesForSettings.removeAll { $0.id == row.id }
        guard let uid = currentUserAuthId else {
            myRemovedPickupGamesForSettings.removeAll { $0.id == row.id }
            pickupGamesForDiscoverMap.removeAll { $0.id == row.id }
            if selectedPickupGameForMap?.id == row.id {
                clearPickupMapSelection()
            }
            clearPickupGameLocalCachesAfterRemoval(id: row.id)
            return
        }
        let clearedHistoryIds = Self.readPickupOrganizerSettingsHistoryUserClearedIds(userId: uid)
        let now = Date()
        guard shouldShowRemovedPickupInOrganizerHistory(row: row, now: now, clearedIds: clearedHistoryIds) else {
            myRemovedPickupGamesForSettings.removeAll { $0.id == row.id }
            pickupGamesForDiscoverMap.removeAll { $0.id == row.id }
            if selectedPickupGameForMap?.id == row.id {
                clearPickupMapSelection()
            }
            clearPickupGameLocalCachesAfterRemoval(id: row.id)
            return
        }
        if let i = myRemovedPickupGamesForSettings.firstIndex(where: { $0.id == row.id }) {
            myRemovedPickupGamesForSettings[i] = row
        } else {
            myRemovedPickupGamesForSettings.insert(row, at: 0)
        }
        myRemovedPickupGamesForSettings.sort { a, b in
            let ua = PickupGameModels.parseSupabaseTimestamptz(a.updated_at ?? "") ?? .distantPast
            let ub = PickupGameModels.parseSupabaseTimestamptz(b.updated_at ?? "") ?? .distantPast
            if ua != ub { return ua > ub }
            return a.id.uuidString > b.id.uuidString
        }
        pickupGamesForDiscoverMap.removeAll { $0.id == row.id }
        if selectedPickupGameForMap?.id == row.id {
            clearPickupMapSelection()
        }
        clearPickupGameLocalCachesAfterRemoval(id: row.id)
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
        let st = row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if st == "removed" || st == "expired" {
            mergePickupGameAfterOrganizerSoftDelete(row)
            return
        }
        markMyPickupGamesForSettingsStaleAfterMutation(row: row, reason: "mutationUpsert")
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

        let visibility = pickupDiscoverVisibilityEvaluation(for: row)
#if DEBUG
        logPickupDiscoverVisibility(row: row, evaluation: visibility)
#endif
        if visibility.included {
            if let i = pickupGamesForDiscoverMap.firstIndex(where: { $0.id == row.id }) {
                pickupGamesForDiscoverMap[i] = row
            } else {
                pickupGamesForDiscoverMap.append(row)
            }
            invalidatePickupGameClusterAnnotationCache()
        } else {
            let previousCount = pickupGamesForDiscoverMap.count
            pickupGamesForDiscoverMap.removeAll { $0.id == row.id }
            if pickupGamesForDiscoverMap.count != previousCount {
                invalidatePickupGameClusterAnnotationCache()
            }
        }
    }

    private func shouldIncludePickupRowOnDiscoverMap(_ row: PickupGameRow) -> Bool {
        pickupDiscoverVisibilityEvaluation(for: row).included
    }

    private func pickupDiscoverVisibilityEvaluation(for row: PickupGameRow) -> PickupDiscoverVisibilityEvaluation {
        let bounds = currentMapRegionBounds()
        let withinVisibleRegion: Bool = {
            guard let bounds, let lat = row.latitude, let lon = row.longitude else { return false }
            return lat >= bounds.minLat && lat <= bounds.maxLat && lon >= bounds.minLon && lon <= bounds.maxLon
        }()
        let filteredByBounds = bounds != nil && !withinVisibleRegion
        let status = row.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard status == "active", row.is_visible else {
            return PickupDiscoverVisibilityEvaluation(
                included: false,
                rejectionReason: status == "active" ? "notVisible" : "status:\(status)",
                gameDate: PickupGameModels.parseSupabaseTimestamptz(row.game_start_at),
                withinVisibleRegion: withinVisibleRegion,
                filteredByBounds: filteredByBounds,
                filteredByDate: false,
                filteredBySport: false
            )
        }
        let now = Date()
        if let rem = row.remove_after_at,
           let remd = PickupGameModels.parseSupabaseTimestamptz(rem),
           remd <= now {
            return PickupDiscoverVisibilityEvaluation(
                included: false,
                rejectionReason: "removeAfterPast",
                gameDate: PickupGameModels.parseSupabaseTimestamptz(row.game_start_at),
                withinVisibleRegion: withinVisibleRegion,
                filteredByBounds: filteredByBounds,
                filteredByDate: false,
                filteredBySport: false
            )
        }
        let cal = Calendar.current
        guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else {
            return PickupDiscoverVisibilityEvaluation(
                included: false,
                rejectionReason: "invalidGameDate",
                gameDate: nil,
                withinVisibleRegion: withinVisibleRegion,
                filteredByBounds: filteredByBounds,
                filteredByDate: true,
                filteredBySport: false
            )
        }
        let filteredByDate = !cal.isDate(start, inSameDayAs: selectedDate)
        guard !filteredByDate else {
            return PickupDiscoverVisibilityEvaluation(
                included: false,
                rejectionReason: "date",
                gameDate: start,
                withinVisibleRegion: withinVisibleRegion,
                filteredByBounds: filteredByBounds,
                filteredByDate: true,
                filteredBySport: false
            )
        }
        let filteredBySport = !pickupDiscoverSport(row.sport, matchesSelectedSport: selectedSport)
        guard !filteredBySport else {
            return PickupDiscoverVisibilityEvaluation(
                included: false,
                rejectionReason: "sport",
                gameDate: start,
                withinVisibleRegion: withinVisibleRegion,
                filteredByBounds: filteredByBounds,
                filteredByDate: false,
                filteredBySport: true
            )
        }
        return PickupDiscoverVisibilityEvaluation(
            included: true,
            rejectionReason: "none",
            gameDate: start,
            withinVisibleRegion: withinVisibleRegion,
            filteredByBounds: filteredByBounds,
            filteredByDate: false,
            filteredBySport: false
        )
    }

    private func pickupDiscoverSport(_ gameSport: String, matchesSelectedSport selectedSport: String) -> Bool {
        let selected = selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selected.localizedCaseInsensitiveCompare("All") != .orderedSame else { return true }
        let sport = gameSport.trimmingCharacters(in: .whitespacesAndNewlines)
        return sport.localizedCaseInsensitiveCompare(selected) == .orderedSame
            || SportFilterCatalog.storedSport(sport, matchesSearchQuery: selected)
    }

    private func logPickupDiscoverVisibility(row: PickupGameRow, evaluation: PickupDiscoverVisibilityEvaluation) {
#if DEBUG
        print("[PickupDiscoverVisibilityDebug] insertedGameID=\(row.id.uuidString.lowercased())")
        print("[PickupDiscoverVisibilityDebug] included=\(evaluation.included)")
        print("[PickupDiscoverVisibilityDebug] rejectionReason=\(evaluation.rejectionReason)")
        print("[PickupDiscoverVisibilityDebug] selectedDate=\(pickupDebugYMD(Calendar.current.startOfDay(for: selectedDate)))")
        if let gameDate = evaluation.gameDate {
            print("[PickupDiscoverVisibilityDebug] gameDate=\(pickupDebugYMD(Calendar.current.startOfDay(for: gameDate)))")
        } else {
            print("[PickupDiscoverVisibilityDebug] gameDate=nil")
        }
        print("[PickupDiscoverVisibilityDebug] selectedSport=\(selectedSport)")
        print("[PickupDiscoverVisibilityDebug] gameSport=\(row.sport)")
        print("[PickupDiscoverVisibilityDebug] withinVisibleRegion=\(evaluation.withinVisibleRegion)")
        print("[PickupDiscoverVisibilityDebug] filteredByBounds=\(evaluation.filteredByBounds)")
        print("[PickupDiscoverVisibilityDebug] filteredByDate=\(evaluation.filteredByDate)")
        print("[PickupDiscoverVisibilityDebug] filteredBySport=\(evaluation.filteredBySport)")
        logPickupVisibilityDebug(
            row: row,
            includedInDiscover: evaluation.included,
            excludedBecauseFull: false,
            selectedDay: Calendar.current.startOfDay(for: selectedDate),
            requestStatus: nil
        )
#endif
    }

    private func logPickupVisibilityDebug(
        row: PickupGameRow,
        includedInDiscover: Bool,
        excludedBecauseFull: Bool,
        selectedDay: Date,
        requestStatus: String?
    ) {
#if DEBUG
        let gameDay = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at)
            .map { Calendar.current.startOfDay(for: $0) }
        print("[PickupVisibilityDebug] gameId=\(row.id.uuidString.lowercased())")
        print("[PickupVisibilityDebug] rosterFull=\(row.isPickupFullForDiscover)")
        print("[PickupVisibilityDebug] excludedBecauseFull=\(excludedBecauseFull)")
        print("[PickupVisibilityDebug] includedInDiscover=\(includedInDiscover)")
        print("[PickupVisibilityDebug] creatorCanReadGame=\(currentUserAuthId == row.creator_user_id)")
        print("[PickupVisibilityDebug] selectedDate=\(pickupDebugYMD(selectedDay))")
        print("[PickupVisibilityDebug] gameDate=\(gameDay.map(pickupDebugYMD) ?? "nil")")
        if let requestStatus {
            print("[PickupVisibilityDebug] requestStatus=\(requestStatus)")
        }
#endif
    }

    private func applySoftRemovedPickupGameLocally(id: UUID) {
        myPickupGamesForSettings.removeAll { $0.id == id }
        myRemovedPickupGamesForSettings.removeAll { $0.id == id }
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
        pickupOrganizerWithdrawnRequestsByGameId.removeValue(forKey: id)
        pickupOrganizerApprovedJoinerUserIdsByGameId.removeValue(forKey: id)
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
