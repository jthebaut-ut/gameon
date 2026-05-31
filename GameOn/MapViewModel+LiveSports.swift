import Foundation
import MapKit

extension MapViewModel {
    @discardableResult
    func openLiveGameVenueOnDiscover(_ match: LiveMatch) -> Bool {
        guard LiveVenueNavigationFeatureFlags.liveVenueDiscoverNavigationEnabled else {
#if DEBUG
            print("[LiveVenueNavigationDebug] disabledDueToDiscoverStability=true")
#endif
            return false
        }
        guard let coordinate = match.venueCoordinate else { return false }
        let venueName = match.venueName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !venueName.isEmpty else { return false }
#if DEBUG
        print("[LiveVenueDebug] openDiscoverVenue=\(venueName)")
        print("[LiveVenueDebug] openDiscoverCoordinate=\(coordinate.latitude),\(coordinate.longitude)")
#endif
        return true
    }

    func refreshLiveMatchesForLiveTab(forceRefresh: Bool = false) async {
        await refreshLiveMatchesForCalendar(forceRefresh: forceRefresh)
    }

    @MainActor
    func refreshLiveMatchesForCalendar(selectedDate: Date? = nil, forceRefresh: Bool = false) async {
        if let inFlight = liveMatchesRefreshTask {
            await inFlight.value
        }

        let task = Task { @MainActor [weak self] () -> Void in
            if let selectedDate {
                await self?.runCalendarProGamesRefresh(selectedDate: selectedDate, forceRefresh: forceRefresh)
            } else {
                await self?.runLiveMatchesRefresh(forceRefresh: forceRefresh)
            }
        }
        liveMatchesRefreshTask = task
        await task.value
        liveMatchesRefreshTask = nil
    }

    @MainActor
    private func runLiveMatchesRefresh(forceRefresh: Bool) async {
        isLoadingLiveMatches = true
        defer { isLoadingLiveMatches = false }

#if DEBUG
        print("[LiveDebug] refreshStarted forceRefresh=\(forceRefresh)")
        print("[LiveDebug] timezone=\(TimeZone.current.identifier)")
        print("[LiveDebug] provider=\(LiveSportsService.providerDescription)")
#endif
        let featuredEventsTask = Task {
            await LiveSportsService.shared.fetchActiveFeaturedEvents(forceRefresh: forceRefresh)
        }
        do {
            let matches = try await LiveSportsService.shared.fetchLiveMatches(forceRefresh: forceRefresh)
            activeFeaturedEvents = await featuredEventsTask.value
            let diagnostics = await LiveSportsService.shared.lastFetchDiagnostics
#if DEBUG
            print("[LiveRefreshDebug] replace_not_append=true previous_count=\(liveMatches.count) incoming_count=\(matches.count)")
#endif
            liveMatches = matches
            liveMatchesLoadError = nil
            liveMatchesEmptyDebugHint = Self.makeLiveMatchesEmptyDebugHint(
                matches: matches,
                diagnostics: diagnostics
            )
            invalidateCalendarTabEventsListCache()
#if DEBUG
            logLiveTabAssignment(matches: matches)
#endif
        } catch {
#if DEBUG
            print("[LiveDebug] ui_assignment_failed error=\(error)")
            print("[LiveDebug] apiError=\(error.localizedDescription)")
            print("[LiveSports] failed to refresh live matches:", error)
#endif
            liveMatchesLoadError = "Couldn't refresh live games. Showing the latest available results."
            liveMatchesEmptyDebugHint = "Live provider error: \(error.localizedDescription)"
            activeFeaturedEvents = await featuredEventsTask.value
        }
    }

    @MainActor
    private func runCalendarProGamesRefresh(selectedDate: Date, forceRefresh: Bool) async {
        isLoadingLiveMatches = true
        defer { isLoadingLiveMatches = false }

#if DEBUG
        print("[CalendarProGamesDebug] selectedDateFetchStarted forceRefresh=\(forceRefresh)")
#endif
        let featuredEventsTask = Task {
            await LiveSportsService.shared.fetchActiveFeaturedEvents(forceRefresh: forceRefresh)
        }
        do {
            let matches = try await LiveSportsService.shared.fetchLiveMatches(on: selectedDate, forceRefresh: forceRefresh)
            activeFeaturedEvents = await featuredEventsTask.value
            mergeCalendarProGameMatches(matches, for: selectedDate)
            liveMatchesLoadError = nil
            invalidateCalendarTabEventsListCache()
#if DEBUG
            print("[CalendarProGamesDebug] selectedDateFetchCount=\(matches.count)")
#endif
        } catch {
#if DEBUG
            print("[CalendarProGamesDebug] selectedDateFetchFailed error=\(error.localizedDescription)")
#endif
            liveMatchesLoadError = "Couldn't refresh pro games. Showing the latest available results."
            activeFeaturedEvents = await featuredEventsTask.value
        }
    }

    @MainActor
    private func mergeCalendarProGameMatches(_ matches: [LiveMatch], for selectedDate: Date) {
        let cal = Calendar.current
        let day = cal.startOfDay(for: selectedDate)
        var mergedByID: [String: LiveMatch] = [:]

        for match in liveMatches where !cal.isDate(match.startTime, inSameDayAs: day) {
            mergedByID[match.id] = match
        }
        for match in matches {
            mergedByID[match.id] = match
        }

        liveMatches = mergedByID.values.sorted { lhs, rhs in
            if lhs.matchStatus.isHappeningNow != rhs.matchStatus.isHappeningNow {
                return lhs.matchStatus.isHappeningNow && !rhs.matchStatus.isHappeningNow
            }
            if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
            return lhs.league.localizedCaseInsensitiveCompare(rhs.league) == .orderedAscending
        }
    }

    private static func makeLiveMatchesEmptyDebugHint(
        matches: [LiveMatch],
        diagnostics: LiveMatchesFetchDiagnostics?
    ) -> String? {
        guard matches.filter(\.matchStatus.isHappeningNow).isEmpty else { return nil }
        if let apiError = diagnostics?.apiError, !apiError.isEmpty {
            return "Live provider error: \(apiError)"
        }
        if let diagnostics, diagnostics.rawCount == 0 {
            return "No live games returned by provider (cache empty after sync)."
        }
        if let diagnostics, diagnostics.liveCount == 0, diagnostics.rawCount > 0 {
            return "Provider returned \(diagnostics.rawCount) games but none are LIVE/HT right now."
        }
        return "No live games returned by provider."
    }

#if DEBUG
    private func logLiveTabAssignment(matches: [LiveMatch]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let liveCount = matches.filter(\.matchStatus.isHappeningNow).count
        let todayScheduledCount = matches.filter {
            $0.matchStatus == .scheduled && cal.isDate($0.startTime, inSameDayAs: today)
        }.count
        let displayed = liveTabLiveMatchesDisplayed(searchQuery: "")
        let hiddenByCalendar = matches.filter(\.matchStatus.isHappeningNow).count - displayed.count
        if hiddenByCalendar > 0 {
            print("[LiveDebug] filteredOut reason=calendar_day_mismatch count=\(hiddenByCalendar)")
        }
        print("[LiveDebug] ui_assignment liveMatches_count=\(liveMatches.count) live=\(liveCount) todayScheduled=\(todayScheduledCount) displayedLive=\(displayed.count)")
        print("[LiveSports] calendar live matches refreshed total=\(matches.count) live=\(liveCount) upcoming=\(todayScheduledCount)")
    }
#endif

    func liveTabLiveMatchesDisplayed(
        searchQuery: String,
        sportFilter: LiveSportVisualType? = nil,
        calendarDay: Date = Calendar.current.startOfDay(for: Date())
    ) -> [LiveMatch] {
        // In-progress pro games are not restricted to start calendar day (late games / timezone skew).
        _ = calendarDay
        return liveMatchesDisplayed(
            searchQuery: searchQuery,
            sportFilter: sportFilter,
            calendarDay: nil,
            statuses: [.live, .halfTime]
        )
    }

    func calendarLiveMatchesDisplayed(searchQuery: String) -> [LiveMatch] {
        liveMatchesDisplayed(searchQuery: searchQuery, statuses: [.live, .halfTime])
    }

    func calendarProGamesDisplayed(
        selectedDate: Date,
        searchQuery: String,
        sportFilter: String,
        worldCupOnly: Bool,
        selectedLeagueCountries: Set<String> = [],
        featuredEvent: FeaturedEvent? = nil
    ) -> [LiveMatch] {
        let cal = Calendar.current
        let day = cal.startOfDay(for: selectedDate)
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let sport = sportFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = liveMatches
            .filter { cal.isDate($0.startTime, inSameDayAs: day) }
            .filter { match in
                guard featuredEvent == nil else { return true }
                return sport.isEmpty
                    || sport.localizedCaseInsensitiveCompare("All") == .orderedSame
                    || match.sport.localizedCaseInsensitiveCompare(sport) == .orderedSame
                    || SportFilterCatalog.storedSport(match.sport, matchesSearchQuery: sport)
            }
            .filter { query.isEmpty || Self.liveMatch($0, matchesSearchQuery: query) }
            .filter { match in
                if let featuredEvent {
                    return LiveMatchFilters.matchesFeaturedEvent(match, featuredEvent: featuredEvent)
                }
                return !worldCupOnly || LiveMatchFilters.isFifaWorldCupMatch(match)
            }
            .filter { match in
                guard featuredEvent == nil else { return true }
                return LiveMatchFilters.matchesLeagueCountry(match, selectedCountries: selectedLeagueCountries)
            }
            .sorted { lhs, rhs in
                if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
                if lhs.league != rhs.league {
                    return lhs.league.localizedCaseInsensitiveCompare(rhs.league) == .orderedAscending
                }
                return "\(lhs.awayTeam) \(lhs.homeTeam)".localizedCaseInsensitiveCompare("\(rhs.awayTeam) \(rhs.homeTeam)") == .orderedAscending
            }
#if DEBUG
        print("[CalendarProGamesDebug] selectedDate=\(Self.calendarProGamesDebugDateFormatter.string(from: day))")
        print("[CalendarProGamesDebug] sportFilter=\(sport.isEmpty ? "All" : sport)")
        print("[CalendarProGamesDebug] worldCupOnly=\(worldCupOnly)")
        print("[CalendarProGamesDebug] featuredEvent=\(featuredEvent?.slug ?? "nil")")
        print("[CalendarProGamesDebug] selectedLeagueCountries=\(selectedLeagueCountries.sorted().joined(separator: ","))")
        print("[CalendarProGamesDebug] filteredCount=\(matches.count)")
#endif
        return matches
    }

    func calendarProGameDotDates() -> Set<Date> {
        let cal = Calendar.current
        return proGameCalendarDotDates.union(liveMatches.map { cal.startOfDay(for: $0.startTime) })
    }

    @MainActor
    func loadCalendarProGameDotDatesAroundMonth(_ month: Date, reason: String) {
        let cacheKey = Self.calendarProGameDotCacheKey(for: month)
        if let cached = proGameCalendarDotDatesCache[cacheKey],
           Date().timeIntervalSince(cached.fetchedAt) < 5 * 60 {
            proGameCalendarDotDates = cached.dates
            return
        }

        isLoadingProGameCalendarDots = true
#if DEBUG
        print("[CalendarProGamesDebug] dotFetchStarted reason=\(reason)")
#endif
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLoadingProGameCalendarDots = false }
            do {
                let dates = try await LiveSportsService.shared.fetchLiveMatchDateDots(around: month)
                self.proGameCalendarDotDatesCache[cacheKey] = (dates: dates, fetchedAt: Date())
                self.proGameCalendarDotDates = dates
#if DEBUG
                print("[CalendarProGamesDebug] dotFetchCount=\(dates.count)")
#endif
            } catch {
#if DEBUG
                print("[CalendarProGamesDebug] dotFetchFailed error=\(error.localizedDescription)")
#endif
                self.proGameCalendarDotDates = self.calendarProGameDotDates()
            }
        }
    }

    private static func calendarProGameDotCacheKey(for month: Date) -> String {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? calendar.startOfDay(for: month)
        return Self.calendarProGamesDebugDateFormatter.string(from: monthStart)
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

    private static let calendarProGamesDebugDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

}
