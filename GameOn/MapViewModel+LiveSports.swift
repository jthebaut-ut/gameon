import Foundation

extension MapViewModel {
    func refreshLiveMatchesForLiveTab(forceRefresh: Bool = false) async {
        await refreshLiveMatchesForCalendar(forceRefresh: forceRefresh)
    }

    @MainActor
    func refreshLiveMatchesForCalendar(forceRefresh: Bool = false) async {
        if let inFlight = liveMatchesRefreshTask {
            await inFlight.value
            return
        }

        let task = Task { @MainActor [weak self] () -> Void in
            await self?.runLiveMatchesRefresh(forceRefresh: forceRefresh)
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
        do {
            let matches = try await LiveSportsService.shared.fetchLiveMatches(forceRefresh: forceRefresh)
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
