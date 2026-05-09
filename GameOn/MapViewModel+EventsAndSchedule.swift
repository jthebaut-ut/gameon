import Foundation

extension MapViewModel {

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
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Clears map preview selection when the venue no longer matches filters (date, sport, search).
    func pruneSelectionIfNeededAfterFilterChange() {
        guard let bar = selectedBar else { return }
        let stillVisible = filteredBars.contains { $0.id == bar.id }
        if !stillVisible {
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
        searchText.isEmpty ||
        event.title.localizedCaseInsensitiveContains(searchText) ||
        event.sport.localizedCaseInsensitiveContains(searchText) ||
        event.league.localizedCaseInsensitiveContains(searchText)
    }
}
