import Foundation

extension MapViewModel {

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
            let venueGameTitles = Set(bars.flatMap(\.games))
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

    func sportChanged(to sport: String) {

        selectedSport = sport
        selectedEvent = nil
        selectedBar = nil
        discoverRemotePreviewHoldVenueId = nil

        loadGamesFromSupabase()
    }

    func matchesSearch(_ event: SportsEvent) -> Bool {
        effectiveDiscoverSearchQuery.isEmpty ||
        event.title.localizedCaseInsensitiveContains(effectiveDiscoverSearchQuery) ||
        event.sport.localizedCaseInsensitiveContains(effectiveDiscoverSearchQuery) ||
        event.league.localizedCaseInsensitiveContains(effectiveDiscoverSearchQuery)
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
