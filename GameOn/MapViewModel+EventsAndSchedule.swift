import Foundation

extension MapViewModel {

    /// Debounced Discover search string; avoids recomputing pins/events on every keystroke (see ``scheduleDiscoverSearchDebounce()``).
    var effectiveDiscoverSearchQuery: String {
        debouncedDiscoverSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Events shown on Discover map pins and venue cards: selected day + sport + search (event text or venue name/address).
    var eventsForSelectedDate: [SportsEvent] {
        events.filter { event in
            Calendar.current.isDate(event.date, inSameDayAs: selectedDate) &&
            (selectedSport == "All" || event.sport == selectedSport) &&
            matchesSearch(event)
        }
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

    func recomputeCalendarDotDates() {
        #if DEBUG
        let t0 = Date()
        #endif
        let cal = Calendar.current
        calendarDotDates = Set(eventsForCalendarDots.map { cal.startOfDay(for: $0.date) })
        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[DiscoverPerf] calendar dots recompute ms=\(ms) n=\(calendarDotDates.count) regionOnly=\(calendarUsesVisibleMapRegionOnly) sport=\(selectedSport)")
        #endif
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
            selectedBar = nil
            selectedEvent = nil
        }
    }

    func clearSelectedEvent() {
        selectedEvent = nil
        selectedBar = nil
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

            } else {

                events = onlineEvents

            }

        } catch {

            print(error)
            eventLoadError = "Could not load events from internet."
            events = []
        }
        isLoadingEvents = false

    }

    func dateChanged() {
        selectedEvent = nil
        selectedBar = nil
        loadGamesFromSupabase()
    }

    func sportChanged(to sport: String) {

        selectedSport = sport
        selectedEvent = nil
        selectedBar = nil

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
            guard let vn = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  vn.caseInsensitiveCompare(barName) == .orderedSame,
                  let ed = row.event_date,
                  ed == dayStr else { continue }
            if sportFilter != "All" {
                guard let rs = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines), rs == sportFilter else { continue }
            }
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
