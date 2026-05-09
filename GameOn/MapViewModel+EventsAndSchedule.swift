import Foundation

extension MapViewModel {

    var eventsForSelectedDate: [SportsEvent] {
        events.filter { event in
            Calendar.current.isDate(event.date, inSameDayAs: selectedDate) &&
            (selectedSport == "All" || event.sport == selectedSport) &&
            matchesSearch(event)
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
        events.filter { event in
            Calendar.current.isDate(event.date, inSameDayAs: selectedDate) &&
            bar.games.contains(event.title)
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
