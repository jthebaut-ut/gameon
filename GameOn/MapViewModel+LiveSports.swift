import Foundation
import MapKit

private enum LiveMatchesRefreshState {
    static var generation: UInt = 0
}

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
            TabPerf.duplicateRefreshCoalesced(name: "liveMatches")
            Perf.duplicateTaskCoalesced(name: "liveMatches")
#if DEBUG
            print("[TabPerfDebug] refreshCoalesced=true source=liveMatches force=\(forceRefresh)")
#endif
            await inFlight.value
            if !forceRefresh { return }
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
        LiveMatchesRefreshState.generation &+= 1
        let refreshGeneration = LiveMatchesRefreshState.generation

        let showBlockingLoader = liveMatches.isEmpty
        if showBlockingLoader || forceRefresh {
            isLoadingLiveMatches = true
        }

#if DEBUG
        print("[LiveDebug] refreshStarted forceRefresh=\(forceRefresh) showBlockingLoader=\(showBlockingLoader) generation=\(refreshGeneration)")
        print("[LiveDebug] timezone=\(TimeZone.current.identifier)")
        print("[LiveDebug] provider=\(LiveSportsService.providerDescription)")
#endif
        let featuredEventsTask = Task {
            await LiveSportsService.shared.fetchActiveFeaturedEvents(forceRefresh: forceRefresh)
        }
        do {
            let matches = try await LiveSportsService.shared.fetchLiveMatches(forceRefresh: forceRefresh)
            activeFeaturedEvents = await featuredEventsTask.value
            await applyLiveMatchesFromLiveRefresh(matches)

            if !forceRefresh {
                if !matches.isEmpty {
                    isLoadingLiveMatches = false
                }
                scheduleLiveMatchesBackgroundSyncIfNeeded(refreshGeneration: refreshGeneration)
            }
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

        if isLoadingLiveMatches {
            isLoadingLiveMatches = false
        }
    }

    @MainActor
    private func scheduleLiveMatchesBackgroundSyncIfNeeded(refreshGeneration: UInt) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let refreshed = try await LiveSportsService.shared.fetchLiveMatchesAfterBackgroundSyncIfNeeded() else {
                    return
                }
                guard refreshGeneration == LiveMatchesRefreshState.generation else {
#if DEBUG
                    print("[LiveDebug] backgroundSyncApplySkipped reason=staleGeneration expected=\(refreshGeneration) current=\(LiveMatchesRefreshState.generation)")
#endif
                    return
                }
#if DEBUG
                print("[LiveDebug] backgroundSyncApplyStarted generation=\(refreshGeneration) count=\(refreshed.count)")
#endif
                await applyLiveMatchesFromLiveRefresh(refreshed)
            } catch {
#if DEBUG
                print("[LiveDebug] backgroundSyncApplyFailed error=\(error.localizedDescription)")
#endif
            }
        }
    }

    @MainActor
    private func applyLiveMatchesFromLiveRefresh(_ matches: [LiveMatch]) async {
        let diagnostics = await LiveSportsService.shared.lastFetchDiagnostics
#if DEBUG
        print("[LiveRefreshDebug] replace_not_append=true previous_count=\(liveMatches.count) incoming_count=\(matches.count)")
#endif
        handleSavedProGameStatusUpdates(from: matches, reason: "liveRefresh")
        let previousIDs = liveMatches.map(\.id)
        let incomingIDs = matches.map(\.id)
        if previousIDs != incomingIDs {
            liveMatches = matches
        } else {
            Perf.publishedWriteSkipped(name: "liveMatches", reason: "unchanged")
        }
        lastLiveMatchesRefreshAt = Date()
        liveMatchesLoadError = nil
        liveMatchesEmptyDebugHint = Self.makeLiveMatchesEmptyDebugHint(
            matches: matches,
            diagnostics: diagnostics
        )
        invalidateCalendarTabEventsListCache()
#if DEBUG
        logLiveTabAssignment(matches: matches)
#endif
    }

    @MainActor
    private func runCalendarProGamesRefresh(selectedDate: Date, forceRefresh: Bool) async {
        let day = Calendar.current.startOfDay(for: selectedDate)
        let dayKey = String(Int(day.timeIntervalSince1970 / 86_400))
        if !forceRefresh,
           let lastRefresh = calendarProGamesRefreshAtByDay[dayKey] {
            let age = Date().timeIntervalSince(lastRefresh)
            if age < 90, !calendarSelectedDayHasHappeningNowProGame(day) {
#if DEBUG
                print("[TabPerfDebug] cacheAge=\(String(format: "%.1f", age)) tab=calendar source=proGames")
                print("[TabPerfDebug] usedCachedData=true tab=calendar source=proGames")
                print("[TabPerfDebug] refreshSkippedReason=fresh tab=calendar source=proGames")
#endif
                return
            }
        }
        isLoadingLiveMatches = true
        defer { isLoadingLiveMatches = false }

#if DEBUG
        print("[TabPerfDebug] refreshStarted=calendar source=proGames force=\(forceRefresh)")
        print("[CalendarProGamesDebug] selectedDateFetchStarted forceRefresh=\(forceRefresh)")
#endif
        let startedAt = Date()
        let featuredEventsTask = Task {
            await LiveSportsService.shared.fetchActiveFeaturedEvents(forceRefresh: forceRefresh)
        }
        do {
            let matches = try await LiveSportsService.shared.fetchLiveMatches(on: selectedDate, forceRefresh: forceRefresh)
            activeFeaturedEvents = await featuredEventsTask.value
            mergeCalendarProGameMatches(matches, for: selectedDate)
            liveMatchesLoadError = nil
            invalidateCalendarTabEventsListCache()
            calendarProGamesRefreshAtByDay[dayKey] = Date()
#if DEBUG
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("[TabPerfDebug] refreshDurationMs=\(ms) tab=calendar source=proGames")
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

    private func calendarSelectedDayHasHappeningNowProGame(_ day: Date) -> Bool {
        let cal = Calendar.current
        return liveMatches.contains { match in
            match.matchStatus.isHappeningNow && cal.isDate(match.startTime, inSameDayAs: day)
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

        let mergedMatches = mergedByID.values.sorted { lhs, rhs in
            if lhs.matchStatus.isHappeningNow != rhs.matchStatus.isHappeningNow {
                return lhs.matchStatus.isHappeningNow && !rhs.matchStatus.isHappeningNow
            }
            if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
            return lhs.league.localizedCaseInsensitiveCompare(rhs.league) == .orderedAscending
        }
        handleSavedProGameStatusUpdates(from: matches, reason: "calendarProGamesRefresh")
        liveMatches = mergedMatches
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

    func liveTabTodayMatchesDisplayed(
        searchQuery: String,
        sportFilter: LiveSportVisualType? = nil,
        calendarDay: Date = Calendar.current.startOfDay(for: Date())
    ) -> [LiveMatch] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let cal = Calendar.current
        return liveMatches
            .filter { match in
                if match.matchStatus.isHappeningNow { return true }
                guard match.matchStatus == .scheduled || match.matchStatus == .fullTime else { return false }
                return cal.isDate(match.startTime, inSameDayAs: calendarDay)
            }
            .filter { sportFilter == nil || $0.liveSportVisualType == sportFilter }
            .filter { query.isEmpty || Self.liveMatch($0, matchesSearchQuery: query) }
            .sorted { lhs, rhs in
                if lhs.matchStatus.isHappeningNow != rhs.matchStatus.isHappeningNow {
                    return lhs.matchStatus.isHappeningNow && !rhs.matchStatus.isHappeningNow
                }
                if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
                return "\(lhs.awayTeam) \(lhs.homeTeam)".localizedCaseInsensitiveCompare("\(rhs.awayTeam) \(rhs.homeTeam)") == .orderedAscending
            }
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
