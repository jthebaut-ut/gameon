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

    /// Calendar green dots: sport-filtered; when ``calendarUsesVisibleMapRegionOnly`` is on, only venue-backed games on currently loaded map bars.
    var eventsForCalendarDots: [SportsEvent] {
        var list = events
        if selectedSport != "All" {
            list = list.filter { $0.sport == selectedSport }
        }
        if calendarUsesVisibleMapRegionOnly {
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
            list = list.filter { event in
                event.league == "Venue Event" && venueGameTitles.contains(event.title)
            }
        }
        return list
    }

    /// Fingerprint for ``eventsForCalendarDots`` inputs so we can skip full-array rescans when unchanged.
    func calendarDotRecomputeCacheKey() -> String {
        let regionOnly = calendarUsesVisibleMapRegionOnly
        let titlesTag: Int = {
            guard regionOnly else { return 0 }
            return Set(bars.flatMap(\.games)).hashValue
        }()
        return "\(selectedSport)|\(regionOnly)|\(events.count)|\(bars.count)|\(titlesTag)|\(scheduleDataGeneration)"
    }

    func recomputeCalendarDotDates() {
        let key = calendarDotRecomputeCacheKey()
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
        calendarDotDates = Set(eventsForCalendarDots.map { cal.startOfDay(for: $0.date) })
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

    private func calendarEventsListCacheKey(selectedDay: Date, searchQuery: String) -> String {
        let cal = Calendar.current
        let day = cal.startOfDay(for: selectedDay)
        let y = cal.component(.year, from: selectedDay)
        let m = cal.component(.month, from: selectedDay)
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let discoverQ = effectiveDiscoverSearchQuery
        return "\(y)-\(m)|\(Int(day.timeIntervalSince1970))|\(selectedSport)|\(calendarUsesVisibleMapRegionOnly)|\(scheduleDataGeneration)|\(discoverQ)|\(q)"
    }

    private func pruneCalendarEventsListCacheIfNeeded() {
        guard calendarEventsListCache.count > Self.calendarEventsListCacheMaxKeys else { return }
        let pairs = calendarEventsListCache.map { ($0.key, $0.value.storedAt) }.sorted { $0.1 < $1.1 }
        let drop = max(0, pairs.count - Self.calendarEventsListCacheMaxKeys)
        for i in 0..<drop {
            calendarEventsListCache.removeValue(forKey: pairs[i].0)
        }
    }

    /// Calendar tab list: cached by selected month/day, sport, map-region mode, discover search, and local search query.
    func calendarScreenDisplayedEvents(selectedDate: Date, searchQuery: String) -> [SportsEvent] {
        let key = calendarEventsListCacheKey(selectedDay: selectedDate, searchQuery: searchQuery)
        if let entry = calendarEventsListCache[key],
           Date().timeIntervalSince(entry.storedAt) < Self.calendarEventsListCacheTTL {
            return entry.events
        }

        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let built: [SportsEvent]
        if q.isEmpty {
            built = computeEventsForSelectedDateUncached()
        } else {
            built = events.filter { event in
                event.title.localizedCaseInsensitiveContains(q)
                    || event.league.localizedCaseInsensitiveContains(q)
                    || event.sport.localizedCaseInsensitiveContains(q)
                    || SportFilterCatalog.storedSport(event.sport, matchesSearchQuery: q)
            }
        }

        calendarEventsListCache[key] = (storedAt: Date(), events: built)
        pruneCalendarEventsListCacheIfNeeded()
        return built
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
        if discoverCurrentVisibleVenueRows.isEmpty {
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

    func sportChanged(to sport: String) {

        selectedSport = sport
        selectedEvent = nil
        selectedBar = nil
        discoverRemotePreviewHoldVenueId = nil

        loadGamesFromSupabase()
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
}
