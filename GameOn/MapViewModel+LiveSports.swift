import Foundation

extension MapViewModel {
    func refreshLiveMatchesForLiveTab(forceRefresh: Bool = false) {
        refreshLiveMatchesForCalendar(forceRefresh: forceRefresh)
    }

    func refreshLiveMatchesForCalendar(forceRefresh: Bool = false) {
        guard liveMatchesRefreshTask == nil else { return }

        liveMatchesRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isLoadingLiveMatches = true
            defer {
                self.isLoadingLiveMatches = false
                self.liveMatchesRefreshTask = nil
            }

            do {
                let matches = try await LiveSportsService.shared.fetchLiveMatches(forceRefresh: forceRefresh)
#if DEBUG
                print("[LiveRefreshDebug] replace_not_append=true previous_count=\(self.liveMatches.count) incoming_count=\(matches.count)")
#endif
                self.liveMatches = matches
                self.liveMatchesLoadError = nil
                self.invalidateCalendarTabEventsListCache()
#if DEBUG
                let liveCount = matches.filter { $0.matchStatus == .live }.count
                let upcomingCount = matches.filter { $0.matchStatus == .scheduled && $0.startTime > Date() }.count
                print("[LiveDebug] ui_assignment liveMatches_count=\(self.liveMatches.count) live=\(liveCount) upcoming=\(upcomingCount)")
                print("[LiveSports] calendar live matches refreshed total=\(matches.count) live=\(liveCount) upcoming=\(upcomingCount)")
#endif
            } catch {
#if DEBUG
                print("[LiveDebug] ui_assignment_failed error=\(error)")
                print("[LiveSports] failed to refresh live matches:", error)
#endif
                self.liveMatchesLoadError = "Couldn't refresh live games. Showing the latest available results."
            }
        }
    }

    func liveTabLiveMatchesDisplayed(
        searchQuery: String,
        sportFilter: LiveSportVisualType? = nil,
        calendarDay: Date = Calendar.current.startOfDay(for: Date())
    ) -> [LiveMatch] {
        liveMatchesDisplayed(
            searchQuery: searchQuery,
            sportFilter: sportFilter,
            calendarDay: calendarDay,
            statuses: [.live, .halfTime]
        )
    }

    func calendarLiveMatchesDisplayed(searchQuery: String) -> [LiveMatch] {
        liveMatchesDisplayed(searchQuery: searchQuery, statuses: [.live, .halfTime])
    }

    private func liveMatchesDisplayed(
        searchQuery: String,
        sportFilter: LiveSportVisualType? = nil,
        calendarDay: Date? = nil,
        statuses: Set<MatchStatus> = [.live, .halfTime]
    ) -> [LiveMatch] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let cal = Calendar.current
        return liveMatches
            .filter { statuses.contains($0.matchStatus) }
            .filter { match in
                guard let calendarDay else { return true }
                return cal.isDate(match.startTime, inSameDayAs: calendarDay)
            }
            .filter { sportFilter == nil || $0.liveSportVisualType == sportFilter }
            .filter { query.isEmpty || Self.liveMatch($0, matchesSearchQuery: query) }
            .sorted { lhs, rhs in
                if lhs.league != rhs.league {
                    return lhs.league.localizedCaseInsensitiveCompare(rhs.league) == .orderedAscending
                }
                if lhs.minute != rhs.minute {
                    return (lhs.minute ?? -1) > (rhs.minute ?? -1)
                }
                return lhs.startTime < rhs.startTime
            }
    }

    private static func liveMatch(_ match: LiveMatch, matchesSearchQuery query: String) -> Bool {
        match.homeTeam.localizedCaseInsensitiveContains(query)
            || match.awayTeam.localizedCaseInsensitiveContains(query)
            || match.league.localizedCaseInsensitiveContains(query)
            || match.sport.localizedCaseInsensitiveContains(query)
            || SportFilterCatalog.storedSport(match.sport, matchesSearchQuery: query)
    }
}
