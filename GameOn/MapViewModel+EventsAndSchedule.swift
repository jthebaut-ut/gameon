import Foundation

extension MapViewModel {

    func showSocialActionToast(_ text: String, isError: Bool = true) {
        socialActionToastDismissTask?.cancel()
        socialActionToastText = text
        socialActionToastIsError = isError
        socialActionToastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard let self, !Task.isCancelled else { return }
            self.socialActionToastText = nil
            self.socialActionToastIsError = false
            self.socialActionToastDismissTask = nil
        }
    }

    private static let calendarEventsListCacheTTL: TimeInterval = 45
    private static let calendarEventsListCacheMaxKeys = 14

    /// Debounced Discover search string; avoids recomputing pins/events on every keystroke (see ``scheduleDiscoverSearchDebounce()``).
    var effectiveDiscoverSearchQuery: String {
        debouncedDiscoverSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func bumpScheduleDataGeneration() {
        scheduleDataGeneration &+= 1
        lastCalendarDotRecomputeKey = nil
        calendarEventsListCache.removeAll(keepingCapacity: true)
    }

    func invalidateCalendarTabEventsListCache() {
        calendarEventsListCache.removeAll(keepingCapacity: true)
    }

    /// Calendar tab + MainTabView: refresh **public** pickup discover rows only (no fan join-request loads).
    func refreshCalendarTabPickupSources() async {
        guard canFanUsePickupGamesUI else { return }
#if DEBUG
        print("[CalendarPickupPublicMode] personalStateHidden=true reason=refreshCalendarTabPickupSources")
#endif
        let cal = Calendar.current
        let calendarDay = cal.startOfDay(for: calendarTabSelectedDate)
        if cal.startOfDay(for: selectedDate) != calendarDay {
            selectedDate = calendarDay
        }
        await refreshPickupGamesForDiscoverMap(force: true, preservePickupCalendarDotDatesCache: true)
    }

#if DEBUG
    func logPickupActivityBadgeDebug() {
        print("[PickupActivityBadgeDebug] followingBadgeCount=\(pickupActivityCount)")
        print("[PickupActivityBadgeDebug] calendarPickupBadgeCount=0")
    }
#else
    @inline(__always)
    func logPickupActivityBadgeDebug() {}
#endif

    /// Uncached same-day list for Discover (and internal use).
    func computeEventsForSelectedDateUncached() -> [SportsEvent] {
        let cal = Calendar.current
        return events.filter { event in
            cal.isDate(event.date, inSameDayAs: selectedDate) &&
                (selectedSport == "All" || event.sport == selectedSport) &&
                matchesSearch(event)
        }
    }

    /// Events shown on Discover map pins and venue cards: selected day + sport + search (event text or venue name/address).
    var eventsForSelectedDate: [SportsEvent] {
        computeEventsForSelectedDateUncached()
    }

    /// Titles allowed for venue calendar dots when ``calendarUsesVisibleMapRegionOnly`` (map bar game titles plus owner-venue extras). Single shared construction for dot filtering and cache keys.
    private func venueGameTitleAllowlistForCalendarDotsWhenRegionOnly() -> Set<String> {
        var venueGameTitles = Set(bars.flatMap(\.games))
        if let ownerVid = ownerVenueDatabaseId, hasAuthenticatedVenueOwnerSession {
            let extra = venueEventRows.compactMap { row -> String? in
                guard row.venue_id == ownerVid, let t = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
                    return nil
                }
                return t
            }
            venueGameTitles.formUnion(extra)
        }
        return venueGameTitles
    }

    /// Sport-filtered events used for Discover calendar dots; when region-only, ``regionVenueGameTitles`` should be the precomputed allowlist (pass `nil` when not region-only, or omit and pass `nil` to build allowlist once in ``recomputeCalendarDotDates``).
    private func filteredEventsForCalendarDots(regionVenueGameTitles: Set<String>?) -> [SportsEvent] {
        var list = events
        if selectedSport != "All" {
            list = list.filter { $0.sport == selectedSport }
        }
        guard calendarUsesVisibleMapRegionOnly else { return list }
        let titles = regionVenueGameTitles ?? venueGameTitleAllowlistForCalendarDotsWhenRegionOnly()
        return list.filter { event in
            event.league == "Venue Event" && titles.contains(event.title)
        }
    }

    /// Calendar green dots: sport-filtered; when ``calendarUsesVisibleMapRegionOnly`` is on, only venue-backed games on currently loaded map bars.
    var eventsForCalendarDots: [SportsEvent] {
        let regionTitles = calendarUsesVisibleMapRegionOnly ? venueGameTitleAllowlistForCalendarDotsWhenRegionOnly() : nil
        return filteredEventsForCalendarDots(regionVenueGameTitles: regionTitles)
    }

    /// Fingerprint for ``eventsForCalendarDots`` inputs so we can skip full-array rescans when unchanged.
    /// - Parameter regionVenueGameTitles: When region-only, pass the same allowlist used for filtering so ``recomputeCalendarDotDates`` avoids building it twice.
    private func calendarDotRecomputeCacheKeyString(regionVenueGameTitles: Set<String>?) -> String {
        let regionOnly = calendarUsesVisibleMapRegionOnly
        let titlesTag: Int = {
            guard regionOnly else { return 0 }
            let titles = regionVenueGameTitles ?? venueGameTitleAllowlistForCalendarDotsWhenRegionOnly()
            return titles.hashValue
        }()
        return "\(selectedSport)|\(regionOnly)|\(events.count)|\(bars.count)|\(titlesTag)|\(scheduleDataGeneration)"
    }

    func calendarDotRecomputeCacheKey() -> String {
        let regionTitles = calendarUsesVisibleMapRegionOnly ? venueGameTitleAllowlistForCalendarDotsWhenRegionOnly() : nil
        return calendarDotRecomputeCacheKeyString(regionVenueGameTitles: regionTitles)
    }

    /// Legacy client-side dot set (DEBUG shadow only); skipped while Calendar tab is hidden unless `force`.
    func recomputeCalendarDotDates(force: Bool = false) {
        guard force || isCalendarTabSelected else {
#if DEBUG
            print("[PerfPhase1D] deferredCalendarWork reason=recomputeCalendarDotDates")
#endif
            return
        }
        let regionVenueGameTitles = calendarUsesVisibleMapRegionOnly ? venueGameTitleAllowlistForCalendarDotsWhenRegionOnly() : nil
        let key = calendarDotRecomputeCacheKeyString(regionVenueGameTitles: regionVenueGameTitles)
        if key == lastCalendarDotRecomputeKey {
            #if DEBUG
            print("[Phase1Perf] recomputeCalendarDotDates SKIP key=\(key)")
            #endif
            return
        }
        #if DEBUG
        let t0 = Date()
        #endif
        let cal = Calendar.current
        let dotSourceEvents = filteredEventsForCalendarDots(regionVenueGameTitles: regionVenueGameTitles)
        calendarDotDates = Set(dotSourceEvents.map { cal.startOfDay(for: $0.date) })
        lastCalendarDotRecomputeKey = key
        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[Phase1Perf] recomputeCalendarDotDates ms=\(ms) n=\(calendarDotDates.count) regionOnly=\(calendarUsesVisibleMapRegionOnly) sport=\(selectedSport)")
        print("[DiscoverPerf] calendar dots recompute ms=\(ms) n=\(calendarDotDates.count) regionOnly=\(calendarUsesVisibleMapRegionOnly) sport=\(selectedSport)")
        let clientDotsSnapshot = calendarDotDates
        let tokenGen = scheduleDataGeneration
        let venueIdsSnapshot = Array(Set(bars.map(\.id)))
        let ownerEmailsSnapshot = Array(
            Set(bars.compactMap { $0.ownerEmail?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        )
        let venueNamesSnapshot = Array(
            Set(bars.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        )
        scheduleCalendarDotRPCShadowCompareAfterRecompute(
            tokenKey: key,
            tokenGen: tokenGen,
            clientDots: clientDotsSnapshot,
            sport: selectedSport,
            regionOnly: calendarUsesVisibleMapRegionOnly,
            barsCount: bars.count,
            venueIds: venueIdsSnapshot,
            ownerEmails: ownerEmailsSnapshot,
            venueNames: venueNamesSnapshot
        )
        #endif
    }

    private func calendarEventsListCacheKey(selectedDay: Date, searchQuery: String, filter: CalendarTabGameFilter) -> String {
        let cal = Calendar.current
        let day = cal.startOfDay(for: selectedDay)
        let y = cal.component(.year, from: selectedDay)
        let m = cal.component(.month, from: selectedDay)
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let pd = pickupDiscoverCalendarDayPublicFingerprint(selectedDay: selectedDay, searchQuery: q, filter: filter)
        return "\(y)-\(m)|\(Int(day.timeIntervalSince1970))|\(selectedSport)|\(calendarUsesVisibleMapRegionOnly)|\(scheduleDataGeneration)|ctf:\(filter.rawValue)|q:\(q)|pd:\(pd)"
    }

    /// Fingerprint for **public** pickup rows shown on Calendar (Discover map list only; ignores personal join-request caches).
    private func pickupDiscoverCalendarDayPublicFingerprint(selectedDay: Date, searchQuery: String, filter: CalendarTabGameFilter) -> Int {
        guard filter == .pickupGames else { return 0 }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedDay)
        var h = Hasher()
        for row in pickupGamesForDiscoverMap {
            guard calendarTabPickupRowPassesListingFilters(row) else { continue }
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { continue }
            guard cal.isDate(start, inSameDayAs: dayStart) else { continue }
            guard selectedSport == "All" || row.sport == selectedSport else { continue }
            guard calendarTabLocalQueryMatchesPickupRow(row, query: searchQuery) else { continue }
            h.combine(row.id)
            h.combine(row.updated_at ?? "")
            h.combine(row.approved_join_count ?? -1)
            h.combine(row.players_needed)
            h.combine(row.status)
            h.combine(row.is_visible)
        }
        return h.finalize()
    }

    private func pruneCalendarEventsListCacheIfNeeded() {
        guard calendarEventsListCache.count > Self.calendarEventsListCacheMaxKeys else { return }
        let pairs = calendarEventsListCache.map { ($0.key, $0.value.storedAt) }.sorted { $0.1 < $1.1 }
        let drop = max(0, pairs.count - Self.calendarEventsListCacheMaxKeys)
        for i in 0..<drop {
            calendarEventsListCache.removeValue(forKey: pairs[i].0)
        }
    }

    /// Synthetic league label for pickup rows in the Calendar tab list.
    static let calendarTabPickupLeagueMarker = "Pickup Game"

    /// Bottom-tab Calendar: reset to today, refresh dots + schedule loads (does not mutate Discover ``selectedDate``).
    func noteCalendarTabBecameActive() {
#if DEBUG
        print("[PerfPhase1D] calendarWorkActivated")
#endif
        let cal = Calendar.current
        calendarTabSelectedDate = cal.startOfDay(for: Date())
        calendarEventsListCache.removeAll()
        loadCalendarTabCalendarDotsAroundMonth(calendarTabSelectedDate, reason: "calendar_tab_active")
        loadGamesFromSupabase()
        Task {
            await refreshCalendarTabPickupSources()
        }
    }

    /// Calendar tab list: venue (`Venue Event`) + optional pickup synthesis; never shows days before today.
    func calendarScreenDisplayedEvents(selectedDate: Date, searchQuery: String, filter: CalendarTabGameFilter) -> [SportsEvent] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedDate)
        let todayStart = cal.startOfDay(for: Date())
        guard dayStart >= todayStart else { return [] }

        let key = calendarEventsListCacheKey(selectedDay: selectedDate, searchQuery: searchQuery, filter: filter)
        if let entry = calendarEventsListCache[key],
           Date().timeIntervalSince(entry.storedAt) < Self.calendarEventsListCacheTTL {
            return entry.events
        }

        let built = buildCalendarTabDisplayedEvents(selectedDate: selectedDate, searchQuery: searchQuery, filter: filter)
        calendarEventsListCache[key] = (storedAt: Date(), events: built)
        pruneCalendarEventsListCacheIfNeeded()
        return built
    }

    private func buildCalendarTabDisplayedEvents(selectedDate: Date, searchQuery: String, filter: CalendarTabGameFilter) -> [SportsEvent] {
        switch filter {
        case .pickupGames:
            return calendarTabPickupSportsEvents(for: selectedDate, searchQuery: searchQuery).sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                if $0.time != $1.time { return $0.time < $1.time }
                return $0.title < $1.title
            }
        case .venueGames:
            return calendarTabVenueSportsEvents(for: selectedDate, searchQuery: searchQuery).sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                if $0.time != $1.time { return $0.time < $1.time }
                return $0.title < $1.title
            }
        case .live:
            return []
        }
    }

    private func calendarTabLocalQueryMatchesEvent(_ event: SportsEvent, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return event.title.localizedCaseInsensitiveContains(q)
            || event.league.localizedCaseInsensitiveContains(q)
            || event.sport.localizedCaseInsensitiveContains(q)
            || SportFilterCatalog.storedSport(event.sport, matchesSearchQuery: q)
    }

    private func calendarTabLocalQueryMatchesPickupRow(_ row: PickupGameRow, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if row.title.localizedCaseInsensitiveContains(q) { return true }
        if row.sport.localizedCaseInsensitiveContains(q) { return true }
        if SportFilterCatalog.storedSport(row.sport, matchesSearchQuery: q) { return true }
        if (row.address ?? "").localizedCaseInsensitiveContains(q) { return true }
        if (row.city ?? "").localizedCaseInsensitiveContains(q) { return true }
        if (row.state ?? "").localizedCaseInsensitiveContains(q) { return true }
        return false
    }

    private func calendarTabPickupRowPassesListingFilters(_ row: PickupGameRow, now: Date = Date()) -> Bool {
        guard row.is_visible, row.status.lowercased() == "active" else { return false }
        if let remStr = row.remove_after_at,
           let rem = PickupGameModels.parseSupabaseTimestamptz(remStr),
           rem <= now {
            return false
        }
        return true
    }

    /// Public Discover-map pickup rows for the Calendar tab (same-day, sport/search filters). No personal join-request merge.
    private func calendarTabPickupPublicRows(for selectedDate: Date, searchQuery: String, logDebug: Bool = false) -> [PickupGameRow] {
        let cal = Calendar.current
        let now = Date()
        var rows: [PickupGameRow] = []
        for row in pickupGamesForDiscoverMap {
            guard calendarTabPickupRowPassesListingFilters(row, now: now) else { continue }
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { continue }
            guard cal.isDate(start, inSameDayAs: selectedDate) else { continue }
            guard selectedSport == "All" || row.sport == selectedSport else { continue }
            guard calendarTabLocalQueryMatchesPickupRow(row, query: searchQuery) else { continue }
            rows.append(row)
        }
        rows.sort { a, b in
            let da = PickupGameModels.parseSupabaseTimestamptz(a.game_start_at) ?? .distantPast
            let db = PickupGameModels.parseSupabaseTimestamptz(b.game_start_at) ?? .distantPast
            if da != db { return da < db }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        if logDebug {
#if DEBUG
            let dayLabel = Self.calendarPickupDebugDayFormatter.string(from: selectedDate)
            print("[CalendarPickupRequestsDebug] selectedDate=\(dayLabel)")
            print("[CalendarPickupRequestsDebug] publicPickupListCount=\(rows.count)")
            print("[CalendarPickupPublicMode] personalStateHidden=true mode=publicCalendarList")
#endif
        }
        return rows
    }

    private static let calendarPickupDebugDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func calendarTabVenueSportsEvents(for selectedDate: Date, searchQuery: String) -> [SportsEvent] {
        let cal = Calendar.current
        let regionTitles = calendarUsesVisibleMapRegionOnly ? venueGameTitleAllowlistForCalendarDotsWhenRegionOnly() : nil
        let base = events.filter { event in
            guard cal.isDate(event.date, inSameDayAs: selectedDate) else { return false }
            guard event.league == "Venue Event" else { return false }
            guard selectedSport == "All" || event.sport == selectedSport else { return false }
            if calendarUsesVisibleMapRegionOnly, let titles = regionTitles {
                return titles.contains(event.title)
            }
            return true
        }
        return base.filter { calendarTabLocalQueryMatchesEvent($0, query: searchQuery) }
    }

    private static let calendarTabPickupListTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private func calendarTabPickupSportsEvents(for selectedDate: Date, searchQuery: String) -> [SportsEvent] {
        let cal = Calendar.current
        let rows = calendarTabPickupPublicRows(for: selectedDate, searchQuery: searchQuery, logDebug: true)
        let events: [SportsEvent] = rows.compactMap { row -> SportsEvent? in
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return nil }
            let day = cal.startOfDay(for: start)
            let timeLabel = Self.calendarTabPickupListTimeFormatter.string(from: start)
            return SportsEvent(
                id: row.id,
                title: row.title,
                sport: row.sport,
                league: MapViewModel.calendarTabPickupLeagueMarker,
                date: day,
                time: timeLabel,
                country: "",
                calendarPickupJoinStatus: nil
            )
        }
        return events.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.time != $1.time { return $0.time < $1.time }
            return $0.title < $1.title
        }
    }

    var datesWithEvents: Set<DateComponents> {
        Set(events.map {
            Calendar.current.dateComponents([.year, .month, .day], from: $0.date)
        })
    }

    func selectEvent(_ event: SportsEvent) {
        selectedEvent = event
        selectedSport = event.sport
        selectedBar = nil
    }

    func gamesForSelectedDate(at bar: BarVenue) -> [SportsEvent] {
        matchingEventsForDiscoverFilter(bar: bar)
    }

    /// Games at this venue that match the Discover date, sport chip, and search rules.
    func matchingEventsForDiscoverFilter(bar: BarVenue) -> [SportsEvent] {
        let q = effectiveDiscoverSearchQuery
        let daySportGames = events.filter { event in
            Calendar.current.isDate(event.date, inSameDayAs: selectedDate) &&
                bar.games.contains(event.title) &&
                (selectedSport == "All" || event.sport == selectedSport)
        }
        if q.isEmpty {
            return daySportGames
        }
        let byEventText = daySportGames.filter { matchesSearch($0) }
        if !byEventText.isEmpty { return byEventText }
        if bar.name.localizedCaseInsensitiveContains(q)
            || bar.address.localizedCaseInsensitiveContains(q) {
            return daySportGames
        }
        return []
    }

    func venueHasVisibleGameToday(_ venue: BarVenue) -> Bool {
        !selectedDayEventsForMap(venue).isEmpty
    }

    func shouldShowVenueOnMap(_ venue: BarVenue) -> Bool {
        guard venueIsActiveForMap(venue) else { return false }

        let sportScopedEvents = selectedDayEventsForMap(venue)
        let allSportEvents = selectedDayEventsForMap(venue, sportFilter: "All")
        let searchScopedEvents = selectedSport == "All"
            ? selectedDayEventsForMap(venue, sportFilter: "All")
            : sportScopedEvents

        guard venueMatchesMapSearch(venue, candidateEvents: searchScopedEvents) else { return false }

        if mapDisplayMode == .gamesOnly {
            return selectedSport == "All" ? !allSportEvents.isEmpty : !sportScopedEvents.isEmpty
        }

        if selectedSport == "All" {
            return true
        }
        return !sportScopedEvents.isEmpty
    }

    var mapVisibleBars: [BarVenue] {
        bars.filter { shouldShowVenueOnMap($0) }
    }

    /// Venues that host at least one matching event for the current Discover filters.
    var filteredBars: [BarVenue] {
        bars.filter { !matchingEventsForDiscoverFilter(bar: $0).isEmpty }
    }

    /// Clears map preview selection when the venue is no longer present in loaded map data (e.g. region reload).
    /// Keeps ``selectedBar`` when the venue still exists in ``bars`` but has no games for the current date/sport filter (e.g. Following → saved venue).
    func pruneSelectionIfNeededAfterFilterChange() {
        if discoverMapContentMode == .pickupGames, let row = selectedPickupGameForMap {
            let pins = pickupGamesVisibleAsMapPinsWithDiscoverSearch(for: currentMapRegionBounds())
            if !pins.contains(where: { $0.id == row.id }) {
                clearPickupMapSelection()
            }
            return
        }
        guard let bar = selectedBar else { return }
        if !bars.contains(where: { $0.id == bar.id }) {
            if discoverRemotePreviewHoldVenueId == bar.id {
                return
            }
            selectedBar = nil
            selectedEvent = nil
            discoverRemotePreviewHoldVenueId = nil
        }
    }

    func clearSelectedEvent() {
        selectedEvent = nil
        selectedBar = nil
        discoverRemotePreviewHoldVenueId = nil
        selectedPickupGameForMap = nil
    }

    func selectedDayEventsForMap(_ venue: BarVenue, sportFilter: String? = nil) -> [SportsEvent] {
        let effectiveSport = sportFilter ?? selectedSport
        let cal = Calendar.current
        return events.filter { event in
            cal.isDate(event.date, inSameDayAs: selectedDate) &&
                venue.games.contains(event.title) &&
                (effectiveSport == "All" || event.sport == effectiveSport)
        }
    }

    private func venueMatchesMapSearch(_ venue: BarVenue, candidateEvents: [SportsEvent]) -> Bool {
        let q = effectiveDiscoverSearchQuery
        guard !q.isEmpty else { return true }
        if venue.name.localizedCaseInsensitiveContains(q) || venue.address.localizedCaseInsensitiveContains(q) {
            return true
        }
        return candidateEvents.contains { matchesSearch($0) }
    }

    private func venueIsActiveForMap(_ venue: BarVenue) -> Bool {
        let normalized = venue.adminStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return normalized.isEmpty || normalized == "active"
    }

    func loadEventsFromInternet() async {

        isLoadingEvents = true

        eventLoadError = nil

        do {

            let onlineEvents = try await SportsAPIService.shared.fetchEvents(

                for: selectedDate,

                sport: selectedSport

            )

            if onlineEvents.isEmpty {
                events = []
                bumpScheduleDataGeneration()
            } else {
                events = onlineEvents
                bumpScheduleDataGeneration()
            }

        } catch {

            print(error)
            eventLoadError = "Could not load events from internet."
            events = []
            bumpScheduleDataGeneration()
        }
        isLoadingEvents = false

    }

    func dateChanged() {
        selectedEvent = nil
        selectedBar = nil
        discoverRemotePreviewHoldVenueId = nil
        loadGamesFromSupabase()
    }

    func setDiscoverMapStatus(
        _ text: String?,
        isLoading: Bool,
        autoClearAfter delay: TimeInterval? = nil
    ) {
        mapStatusDismissTask?.cancel()
        mapStatusDismissTask = nil
        isUpdatingMapGames = isLoading
        mapStatusText = text

        guard let delay, delay > 0, let text, !text.isEmpty else { return }
        mapStatusDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            guard self.mapStatusText == text, !self.isUpdatingMapGames else { return }
            self.mapStatusText = nil
            self.mapStatusDismissTask = nil
        }
    }

    /// Local start-of-day floor for Discover map date selection (Calendar tab uses its own picker without this floor).
    func discoverMapCalendarSelectionMinimumDayStart() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    @discardableResult
    func clampDiscoverMapSelectedDateToMinimumCalendarDayIfNeeded() -> Bool {
        let cal = Calendar.current
        let minDay = discoverMapCalendarSelectionMinimumDayStart()
        let cur = cal.startOfDay(for: selectedDate)
        guard cur < minDay else { return false }
        selectedDate = minDay
        #if DEBUG
        print("[DiscoverCalendar] selected date clamped to today")
        #endif
        return true
    }

    func beginDiscoverDateChange(to date: Date) -> UUID {
        let cal = Calendar.current
        let minDay = cal.startOfDay(for: Date())
        let requested = cal.startOfDay(for: date)
        let nextDate = max(requested, minDay)
        #if DEBUG
        if requested < minDay {
            print("[DiscoverCalendar] selected date clamped to today")
        }
        #endif
        selectedEvent = nil
        discoverRemotePreviewHoldVenueId = nil
        selectedDate = nextDate
        eventLoadError = nil
        discoverSelectedDayRefreshTask?.cancel()
        discoverSelectedDayRefreshTask = nil
        let requestID = UUID()
        discoverSelectedDayRefreshRequestID = requestID
        markPickupDiscoverMapDataDirtyForNextRefresh()
        if discoverMapContentMode == .pickupGames {
            setDiscoverMapStatus("Updating map…", isLoading: true)
        } else if discoverCurrentVisibleVenueRows.isEmpty {
            setDiscoverMapStatus("Refreshing nearby venues...", isLoading: true)
        } else {
            setDiscoverMapStatus("Updating games...", isLoading: true)
        }
        return requestID
    }

    func scheduleDiscoverSelectedDayRefresh(requestID: UUID) {
        discoverSelectedDayRefreshTask?.cancel()
        discoverSelectedDayRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshDiscoverSelectedDayVenueEventsForCurrentContext(requestID: requestID)
        }
    }

    func discoverDateChanged() {
        #if DEBUG
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let selectedDay = formatter.string(from: selectedDate)
        print("[DiscoverDatePerf] date selected=\(selectedDay)")
        #endif
        let requestID = beginDiscoverDateChange(to: selectedDate)
        scheduleDiscoverSelectedDayRefresh(requestID: requestID)
    }

    func noteDiscoverCalendarGuestDatePinnedByUser() {
        guard isGuestDiscoverMode else { return }
        discoverCalendarGuestUserPinnedDateThisSession = true
    }

    /// Guest Discover: when the map calendar has loaded dot dates, move off an empty selected day to the nearest upcoming day that has games (venues or pickup per current map mode).
    func applyDiscoverGuestNearestEventDateIfNeeded(reason: String) {
        guard isGuestDiscoverMode else { return }
        guard !discoverCalendarGuestUserPinnedDateThisSession else { return }
        let cal = Calendar.current
        let minDay = cal.startOfDay(for: Date())
        let sel = cal.startOfDay(for: selectedDate)
        let venueDots = venueGameCalendarDotDates
        let pickupDots = pickupGameCalendarDotDates
        let unionDots = venueDots.union(pickupDots)
        guard !unionDots.isEmpty else { return }
        let emptyForCurrentMode: Bool = {
            switch discoverMapContentMode {
            case .venues: return !venueDots.contains(sel)
            case .pickupGames: return !pickupDots.contains(sel)
            }
        }()
        guard emptyForCurrentMode else { return }
        let upcoming = unionDots.filter { $0 >= minDay }.sorted()
        guard let target = upcoming.first, target != sel else { return }
        let requestID = beginDiscoverDateChange(to: target)
        scheduleDiscoverSelectedDayRefresh(requestID: requestID)
        #if DEBUG
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        print("[DiscoverGuestCalendar] auto-selected=\(f.string(from: target)) was=\(f.string(from: sel)) reason=\(reason)")
        #endif
    }

    func sportChanged(to sport: String) {

        selectedSport = sport
        selectedEvent = nil
        selectedBar = nil
        selectedPickupGameForMap = nil
        discoverRemotePreviewHoldVenueId = nil

        markPickupDiscoverMapDataDirtyForNextRefresh()
        if discoverMapContentMode == .venues {
            let requestID = beginDiscoverDateChange(to: selectedDate)
            #if DEBUG
            print("[DiscoverNarrowRefreshDebug] sportChangedUsingSelectedDayRefresh=true")
            print("[DiscoverNarrowRefreshDebug] skippedBroadLoadGames=true")
            #endif
            scheduleDiscoverSelectedDayRefresh(requestID: requestID)
        }
        Task {
            if discoverMapContentMode == .pickupGames {
                await refreshPickupGamesForDiscoverMap()
            }
        }
    }

    func matchesSearch(_ event: SportsEvent) -> Bool {
        let q = effectiveDiscoverSearchQuery
        return q.isEmpty ||
            event.title.localizedCaseInsensitiveContains(q) ||
            event.sport.localizedCaseInsensitiveContains(q) ||
            SportFilterCatalog.storedSport(event.sport, matchesSearchQuery: q) ||
            event.league.localizedCaseInsensitiveContains(q)
    }

    private func discoverPreviewSQLDayString(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    /// Titles from ``venueEventRows`` for this venue on `date`, union ``BarVenue/games`` (sport chip applied to rows).
    private func venueGameTitleAllowlistForPreview(bar: BarVenue, date: Date, sportFilter: String) -> Set<String> {
        let dayStr = discoverPreviewSQLDayString(for: date)
        let barName = bar.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var titles = Set(bar.games)
        for row in venueEventRows {
            guard let ed = row.event_date, ed == dayStr else { continue }
            if sportFilter != "All" {
                guard let rs = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines), rs == sportFilter else { continue }
            }
            let matchesBar: Bool
            if let vid = row.venue_id {
                matchesBar = (vid == bar.id)
            } else if let vn = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) {
                matchesBar = vn.caseInsensitiveCompare(barName) == .orderedSame
            } else {
                matchesBar = false
            }
            guard matchesBar else { continue }
            if let t = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                titles.insert(t)
            }
        }
        return titles
    }

    /// Shared Discover venue preview game list: merged `events` for `date` + `sportFilter`, keyed by titles from ``venueEventRows`` and ``BarVenue/games``, then the same text-search rules as ``matchingEventsForDiscoverFilter``.
    func gamesForVenuePreview(bar: BarVenue, date: Date, sportFilter: String) -> [SportsEvent] {
        let cal = Calendar.current
        let q = effectiveDiscoverSearchQuery
        let titleAllowlist = venueGameTitleAllowlistForPreview(bar: bar, date: date, sportFilter: sportFilter)
        let daySportGames = events.filter { event in
            cal.isDate(event.date, inSameDayAs: date) &&
                (sportFilter == "All" || event.sport == sportFilter) &&
                titleAllowlist.contains(event.title)
        }
        if q.isEmpty {
            return daySportGames
        }
        let byEventText = daySportGames.filter { matchesSearch($0) }
        if !byEventText.isEmpty { return byEventText }
        if bar.name.localizedCaseInsensitiveContains(q)
            || bar.address.localizedCaseInsensitiveContains(q) {
            return daySportGames
        }
        return []
    }

    /// Calendar tab: resolve a ``BarVenue`` for a merged venue event (`SportsEvent` league `Venue Event`).
    func barVenueForCalendarVenueEvent(_ event: SportsEvent) -> BarVenue? {
        guard event.league == "Venue Event" else { return nil }
        let ymd = discoverPreviewSQLDayString(for: event.date)
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sport = event.sport.trimmingCharacters(in: .whitespacesAndNewlines)

        if let row = venueEventRows.first(where: { ev in
            guard ev.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) == title else { return false }
            guard ev.event_date?.trimmingCharacters(in: .whitespacesAndNewlines) == ymd else { return false }
            let rs = ev.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return rs.isEmpty || rs == sport
        }) {
            if let vid = row.venue_id, let b = bars.first(where: { $0.id == vid }) {
                return b
            }
            if let vn = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines), !vn.isEmpty,
               let b = bars.first(where: { $0.name.caseInsensitiveCompare(vn) == .orderedSame }) {
                return b
            }
        }

        return bars.first { bar in
            bar.games.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame })
        }
    }
}
