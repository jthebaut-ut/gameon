import SwiftUI

struct CalendarScreen: View {
    /// Minimum height for the scrollable events region so empty vs populated lists do not resize the header stack.
    private static let eventsListMinHeight: CGFloat = 220
    private static let calendarSearchDebounceMilliseconds: UInt64 = 350
    private static let calendarSearchResultLimit = 50
    private static let teamScheduleRecentSearchesKey = "gameon.schedule.teamSchedule.recentSearches.v1"
    private static let teamScheduleCacheDuration: TimeInterval = 20 * 60
    private static let teamScheduleResultLimit = 50

    @ObservedObject var viewModel: MapViewModel
    @Binding var selectedTab: MainTabView.AppTab
    /// False while Calendar is preserved off-screen (defers tab-only pickup refresh at launch).
    var isCalendarTabSelected: Bool = false
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage(LiveLeagueCountryFilterPreference.appStorageKey) private var calendarLeagueCountryFilterRaw: String = ""
    @Environment(\.colorScheme) private var calendarColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDatePicker = false
    @State private var showTeamScheduleSheet = false
    @State private var showCalendarSportMoreSheet = false
    @State private var showCalendarLeagueCountryFilterSheet = false
    @State private var calendarDatePickerDetent: PresentationDetent = .large
    @State private var gameSearchText = ""
    @State private var calendarProGamesSportFilter = "All"
    @State private var calendarFeaturedEventFilterSlug: String?
    @State private var calendarPickupDetailToken: PickupDetailNavigationToken?
    @State private var debouncedGameSearchText = ""
    @State private var gameSearchDebounceTask: Task<Void, Never>?
    @State private var calendarSearchFilteredEvents: [SportsEvent] = []
    @State private var calendarSearchFilteredProMatches: [LiveMatch] = []
    @State private var calendarSearchResultGroups: [CalendarSearchDateGroup] = []
    @State private var calendarSearchSuggestions: [CalendarSearchSuggestion] = []
    @State private var calendarSearchIndex: [CalendarSearchIndexEntry] = []
    @State private var calendarSearchIndexFingerprint = ""
    @State private var teamScheduleSearchText = ""
    @State private var teamScheduleSelectedSport: TeamScheduleSport = .soccer
    @State private var teamScheduleSubmittedQuery = ""
    @State private var teamScheduleResults: [LiveMatch] = []
    @State private var teamScheduleIsLoading = false
    @State private var teamScheduleErrorMessage: String?
    @State private var teamScheduleRecentSearches: [String] = []
    @State private var teamScheduleLookupCache: [String: TeamScheduleCacheEntry] = [:]
    @FocusState private var isGameSearchFocused: Bool
    @FocusState private var isTeamScheduleSearchFocused: Bool

    private var isBusinessCalendarAccess: Bool {
        viewModel.currentUserIsBusinessAccount || viewModel.isVenueOwnerLoggedIn || viewModel.hasAuthenticatedVenueOwnerSession
    }

    private var calendarVisibleGameFilters: [CalendarTabGameFilter] {
        isBusinessCalendarAccess ? [.venueGames, .proGames] : [.venueGames, .pickupGames, .proGames]
    }

    private var effectiveCalendarGameFilter: CalendarTabGameFilter {
        isBusinessCalendarAccess && viewModel.calendarTabGameFilter == .pickupGames
            ? .venueGames
            : viewModel.calendarTabGameFilter
    }

    private var calendarGameFilterBinding: Binding<CalendarTabGameFilter> {
        Binding(
            get: { effectiveCalendarGameFilter },
            set: { newValue in
                viewModel.calendarTabGameFilter = isBusinessCalendarAccess && newValue == .pickupGames
                    ? .venueGames
                    : newValue
            }
        )
    }

    private let calendarProVisibleSportFilters: [(selection: String, display: String?)] = [
        ("All", nil),
        ("Soccer", nil),
        ("Basketball", nil),
        ("Football", nil),
        ("Baseball", nil),
        ("Hockey", nil),
        ("MMA", "Combat"),
        ("Racing", nil),
        ("Golf", nil),
        ("Tennis", nil),
        ("badminton", "Badminton")
    ]

    private var displayedEvents: [SportsEvent] {
        if isCalendarSearchModeActive {
            return calendarSearchFilteredEvents
        }
        return calendarBaseDisplayedEvents()
    }

    private func calendarBaseDisplayedEvents() -> [SportsEvent] {
        viewModel.calendarScreenDisplayedEvents(
            selectedDate: viewModel.calendarTabSelectedDate,
            searchQuery: "",
            filter: effectiveCalendarGameFilter
        )
    }

    private var venueEventsForSelectedDateNoSearch: [SportsEvent] {
        viewModel.calendarScreenDisplayedEvents(
            selectedDate: viewModel.calendarTabSelectedDate,
            searchQuery: "",
            filter: .venueGames
        )
    }

    private var pickupEventsForSelectedDateNoSearch: [SportsEvent] {
        viewModel.calendarScreenDisplayedEvents(
            selectedDate: viewModel.calendarTabSelectedDate,
            searchQuery: "",
            filter: .pickupGames
        )
    }

    private var displayedProMatches: [LiveMatch] {
        if isCalendarSearchModeActive {
            return calendarSearchFilteredProMatches
        }
        return calendarBaseDisplayedProMatches()
    }

    private func calendarBaseDisplayedProMatches() -> [LiveMatch] {
        viewModel.calendarProGamesDisplayed(
            selectedDate: viewModel.calendarTabSelectedDate,
            searchQuery: "",
            sportFilter: calendarProGamesSportFilter,
            worldCupOnly: false,
            selectedLeagueCountries: selectedCalendarFeaturedEvent == nil ? selectedCalendarLeagueCountries : [],
            featuredEvent: selectedCalendarFeaturedEvent
        )
    }

    private var proMatchesForSelectedDateNoSearch: [LiveMatch] {
        viewModel.calendarProGamesDisplayed(
            selectedDate: viewModel.calendarTabSelectedDate,
            searchQuery: "",
            sportFilter: "All",
            worldCupOnly: false,
            selectedLeagueCountries: [],
            featuredEvent: nil
        )
    }

    private var selectedCalendarLeagueCountries: Set<String> {
        LiveLeagueCountryFilterPreference.decode(from: calendarLeagueCountryFilterRaw)
    }

    private var calendarLeagueCountryFilterCount: Int {
        selectedCalendarLeagueCountries.count
    }

    private var calendarLeagueCountryFilterIsActive: Bool {
        !selectedCalendarLeagueCountries.isEmpty
    }

    private var calendarLeagueCountryChipTitle: String {
        calendarLeagueCountryFilterCount == 0 ? "Countries" : "Countries \(calendarLeagueCountryFilterCount)"
    }

    private var calendarLeagueCountryOptions: [String] {
        let cal = Calendar.current
        let detected = viewModel.liveMatches
            .filter { cal.isDate($0.startTime, inSameDayAs: viewModel.calendarTabSelectedDate) }
            .compactMap(\.leagueCountry)
        return Array(Set(LiveLeagueCountryResolver.presetCountries + detected + Array(selectedCalendarLeagueCountries))).sorted()
    }

    private var calendarFeaturedEvents: [FeaturedEvent] {
        viewModel.activeFeaturedEvents
    }

    private var selectedCalendarFeaturedEvent: FeaturedEvent? {
        guard let calendarFeaturedEventFilterSlug else { return nil }
        return calendarFeaturedEvents.first { $0.slug == calendarFeaturedEventFilterSlug }
    }

    private var isProGamesSelected: Bool {
        effectiveCalendarGameFilter == .proGames
    }

    private var immediateCalendarSearchQuery: String {
        gameSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var debouncedCalendarSearchQuery: String {
        debouncedGameSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isCalendarSearchModeActive: Bool {
        !immediateCalendarSearchQuery.isEmpty
    }

    private var shouldShowCalendarSearchSuggestions: Bool {
        false
    }

    private var calendarSearchResultCount: Int {
        isProGamesSelected ? calendarSearchFilteredProMatches.count : calendarSearchFilteredEvents.count
    }

    private var calendarTabSelectedDayIsTodayOrFuture: Bool {
        let cal = Calendar.current
        return cal.startOfDay(for: viewModel.calendarTabSelectedDate) >= cal.startOfDay(for: Date())
    }

    var body: some View {
        fanCalendarRoot
    }

    private var fanCalendarRoot: some View {
        calendarNavigationRoot
    }

    private var calendarSheetRoot: some View {
        fanCalendarContent
            .sheet(isPresented: $showDatePicker) {
                calendarDatePickerSheet
            }
            .sheet(isPresented: $showTeamScheduleSheet) {
                teamScheduleSheet
            }
            .onChange(of: showDatePicker) { _, isPresented in
                if isPresented {
                    calendarDatePickerDetent = .large
                }
            }
    }

    private var calendarFilterRoot: some View {
        calendarSheetRoot
            .onChange(of: viewModel.calendarUsesVisibleMapRegionOnly) { _, _ in
                handleCalendarRegionModeChange()
            }
            .onChange(of: viewModel.selectedSport) { _, _ in
                handleCalendarSelectedSportChange()
            }
            .onChange(of: viewModel.calendarTabGameFilter) { _, _ in
                handleCalendarGameFilterChange()
            }
            .sheet(isPresented: $showCalendarSportMoreSheet) {
                DiscoverSportFilterMoreSheet(selectedSport: isProGamesSelected ? calendarProGamesSportFilter : viewModel.selectedSport) { sport in
                    showCalendarSportMoreSheet = false
                    withAnimation(.spring()) {
                        if isProGamesSelected {
                            calendarProGamesSportFilter = sport
                        } else {
                            viewModel.sportChanged(to: sport)
                        }
                    }
                }
            }
            .sheet(isPresented: $showCalendarLeagueCountryFilterSheet) {
                CalendarLeagueCountryFilterSheet(
                    countries: calendarLeagueCountryOptions,
                    selectedCountries: Binding(
                        get: { selectedCalendarLeagueCountries },
                        set: { updateSelectedCalendarLeagueCountries($0) }
                    )
                )
            }
    }

    private var calendarSearchStateRoot: some View {
        calendarFilterRoot
            .onAppear(perform: handleCalendarAppear)
            .onDisappear(perform: cancelCalendarSearchDebounce)
            .onChange(of: gameSearchText) { _, _ in
                handleCalendarSearchTextChange()
            }
            .onChange(of: viewModel.events.count) { _, _ in
                refreshCurrentDayCalendarSearchForLoadedDataChange()
            }
            .onChange(of: viewModel.liveMatches.count) { _, _ in
                refreshCurrentDayCalendarSearchForLoadedDataChange()
            }
            .onChange(of: viewModel.pickupGamesForDiscoverMap.count) { _, _ in
                refreshCurrentDayCalendarSearchForLoadedDataChange()
            }
            .onChange(of: viewModel.venueEventRows.count) { _, _ in
                refreshCurrentDayCalendarSearchForLoadedDataChange()
            }
            .onChange(of: viewModel.activeFeaturedEvents.count) { _, _ in
                refreshCurrentDayCalendarSearchForLoadedDataChange()
            }
            .onChange(of: calendarProGamesSportFilter) { _, _ in
                refreshCurrentDayCalendarSearchForLoadedDataChange()
            }
            .onChange(of: calendarLeagueCountryFilterRaw) { _, _ in
                refreshCurrentDayCalendarSearchForLoadedDataChange()
            }
            .onChange(of: calendarFeaturedEventFilterSlug) { _, _ in
                refreshCurrentDayCalendarSearchForLoadedDataChange()
            }
    }

    private var calendarLifecycleRoot: some View {
        calendarSearchStateRoot
            .onChange(of: isCalendarTabSelected) { _, active in
                handleCalendarTabSelectionChange(active: active)
            }
            .onChange(of: scenePhase) { _, phase in
                handleCalendarScenePhaseChange(phase)
            }
            .onChange(of: viewModel.calendarTabSelectedDate) { _, _ in
                handleCalendarSelectedDateChange()
            }
            .onChange(of: isBusinessCalendarAccess) { _, _ in
                sanitizeBusinessCalendarFilterIfNeeded()
            }
    }

    private var calendarNavigationRoot: some View {
        calendarLifecycleRoot
            .sheet(item: $calendarPickupDetailToken) { token in
                DiscoverPickupGameDetailSheet(viewModel: viewModel, gameId: token.id)
            }
    }

    private var fanCalendarContent: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            fanCalendarContentStack
        }
    }

    private var fanCalendarContentStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            gameTypeFilter
            calendarTopControls
            calendarSearchSuggestionsSlot
            eventsHeader
            eventsList
        }
        .padding(.top, 14)
    }

    @ViewBuilder
    private var calendarTopControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            calendarSearchRow
            calendarSecondaryFilterBar
            calendarDateStrip
        }
    }

    @ViewBuilder
    private var calendarSearchSuggestionsSlot: some View {
        if shouldShowCalendarSearchSuggestions {
            calendarSearchSuggestionsPanel
        }
    }

    private var calendarDatePickerSheet: some View {
        LiquidGlassCalendarPicker(
            events: viewModel.events,
            bars: viewModel.filteredBars,
            useVisibleMapRegionOnly: viewModel.calendarUsesVisibleMapRegionOnly,
            eventDotDates: viewModel.calendarTabEventDotDatesForPicker(),
            dotsLoading: viewModel.calendarTabCalendarDotsLoading,
            dotStatusText: nil,
            selectedDate: $viewModel.calendarTabSelectedDate,
            minimumSelectableDay: Calendar.current.startOfDay(for: Date()),
            chrome: .calendarTab,
            calendarDotPalette: viewModel.calendarTabCalendarDotPaletteForFilter(),
            onDone: handleCalendarDatePickerDone,
            onDisplayedMonthChange: handleCalendarDisplayedMonthChange
        )
        .liquidGlassCalendarSheetPresentation(selection: $calendarDatePickerDetent, backdrop: .frostedDim)
    }

    private var teamScheduleSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    teamScheduleSearchField
                    teamScheduleSportSelector

                    if teamScheduleSubmittedQuery.isEmpty {
                        teamScheduleSuggestionsSection
                    } else {
                        teamScheduleResultsSection
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Find Team Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showTeamScheduleSheet = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(Color(.secondarySystemGroupedBackground), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Team Schedule")
                }
            }
            .onAppear {
                teamScheduleRecentSearches = Self.loadTeamScheduleRecentSearches()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var teamScheduleSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search team, country, or club", text: $teamScheduleSearchText)
                .textInputAutocapitalization(.words)
                .font(.subheadline)
                .focused($isTeamScheduleSearchFocused)
                .submitLabel(.search)
                .onSubmit {
                    submitTeamScheduleLookup(teamScheduleSearchText)
                }

            if !teamScheduleSearchText.isEmpty {
                Button {
                    teamScheduleSearchText = ""
                    teamScheduleSubmittedQuery = ""
                    teamScheduleResults = []
                    teamScheduleErrorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear team search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(calendarColorScheme).opacity(0.55), lineWidth: 1)
        }
    }

    private var teamScheduleSportSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(TeamScheduleSport.allCases) { sport in
                    Button {
                        teamScheduleSelectedSport = sport
                        teamScheduleSubmittedQuery = ""
                        teamScheduleResults = []
                        teamScheduleErrorMessage = nil
                        teamScheduleIsLoading = false
                    } label: {
                        HStack(spacing: 6) {
                            Text(sport.emoji)
                            Text(sport.title)
                                .font(.caption.weight(.heavy))
                        }
                        .foregroundStyle(teamScheduleSelectedSport == sport ? FGColor.accentGreen : FGColor.secondaryText(calendarColorScheme))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(
                            Capsule(style: .continuous)
                                .fill(teamScheduleSelectedSport == sport ? FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.20 : 0.12) : Color(.secondarySystemGroupedBackground))
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    teamScheduleSelectedSport == sport
                                        ? FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.48 : 0.34)
                                        : FGColor.divider(calendarColorScheme).opacity(0.55),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var teamScheduleSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            teamScheduleSuggestionGroup(title: "Popular Teams", items: teamSchedulePopularTeams)

            if !teamScheduleRecentSearches.isEmpty {
                teamScheduleSuggestionGroup(title: "Recent Searches", items: teamScheduleRecentSearches)
            }
        }
    }

    private func teamScheduleSuggestionGroup(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(calendarColorScheme))

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    Button {
                        submitTeamScheduleLookup(item)
                    } label: {
                        HStack(spacing: 12) {
                            Text(teamScheduleLeadingSymbol(for: item))
                                .font(.title3)
                                .frame(width: 28)
                            Text(item)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(FGColor.primaryText(calendarColorScheme))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < items.count - 1 {
                        Divider()
                            .padding(.leading, 52)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(FGColor.divider(calendarColorScheme).opacity(0.55), lineWidth: 1)
            }
        }
    }

    private var teamScheduleResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            teamScheduleResultsHeader

            if teamScheduleIsLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding upcoming games…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if let teamScheduleErrorMessage {
                calendarEmptyState(teamScheduleErrorMessage)
            } else if teamScheduleResults.isEmpty {
                calendarEmptyState("No upcoming games found for \(teamScheduleSubmittedQuery) \(teamScheduleSelectedSport.title).\nTry another team, sport, or date range.")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(teamScheduleResults) { match in
                        teamScheduleResultRow(match)
                    }
                }
            }
        }
    }

    private var teamScheduleResultsHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(teamScheduleSubmittedQuery) \(teamScheduleSelectedSport.title)")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(FGColor.primaryText(calendarColorScheme))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Label(teamScheduleDateRangeText, systemImage: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                    .lineLimit(1)
            }

            Text("Next 30 Days")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
        }
    }

    private func teamScheduleResultRow(_ match: LiveMatch) -> some View {
        let isSaved = viewModel.isProGameSaved(match)
        let savedGame = teamScheduleSavedGame(for: match)
        let accent = match.matchStatus.isHappeningNow ? FGColor.dangerRed : viewModel.colorForSport(match.liveSportVisualType.sportFilterCatalogKey)

        return HStack(alignment: .center, spacing: 12) {
            teamScheduleDateTile(match.startTime)

            VStack(alignment: .leading, spacing: 5) {
                Text("\(match.awayTeam) vs \(match.homeTeam)")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(FGColor.primaryText(calendarColorScheme))
                    .lineLimit(1)

                Text(calendarProGameStartTimeText(match))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(calendarColorScheme))

                HStack(spacing: 5) {
                    Text(match.league)
                    if let eventName = match.eventName?.trimmingCharacters(in: .whitespacesAndNewlines), !eventName.isEmpty {
                        Text("·")
                        Text(eventName)
                    }
                    Text("·")
                    Text(calendarProGameStatusText(match))
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(spacing: 8) {
                calendarProGameSaveButton(match, isSaved: isSaved, accent: accent)

                if let savedGame, !savedGame.isFinal {
                    teamScheduleScoreUpdateButton(savedGame, accent: accent)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(calendarColorScheme).opacity(0.55), lineWidth: 1)
        }
    }

    private func teamScheduleDateTile(_ date: Date) -> some View {
        VStack(spacing: 3) {
            Text(teamScheduleRowWeekdayFormatter.string(from: date))
                .font(.caption2.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
            Text(teamScheduleRowDayFormatter.string(from: date))
                .font(.caption.weight(.black))
                .foregroundStyle(FGColor.primaryText(calendarColorScheme))
        }
        .frame(width: 54, height: 54)
        .background(Color(.systemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func teamScheduleScoreUpdateButton(_ game: SavedProGame, accent: Color) -> some View {
        let isEnabled = viewModel.savedProGameScoreUpdatesEnabled(for: game)
        return Button {
            viewModel.setSavedProGameScoreUpdatesEnabled(!isEnabled, for: game)
        } label: {
            Image(systemName: isEnabled ? "bell.fill" : "bell.slash")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isEnabled ? accent : FGColor.mutedText(calendarColorScheme))
                .frame(width: 34, height: 30)
                .background(
                    Capsule(style: .continuous)
                        .fill((isEnabled ? accent : FGColor.mutedText(calendarColorScheme)).opacity(calendarColorScheme == .dark ? 0.16 : 0.09))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Score updates \(isEnabled ? "on" : "off")")
    }

    private func presentTeamScheduleSheet() {
        teamScheduleSelectedSport = TeamScheduleSport.resolved(from: selectedCalendarFeaturedEvent?.sport)
            ?? TeamScheduleSport.resolved(from: calendarProGamesSportFilter)
            ?? .soccer
        teamScheduleRecentSearches = Self.loadTeamScheduleRecentSearches()
        showTeamScheduleSheet = true
    }

    private func submitTeamScheduleLookup(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        teamScheduleSearchText = query
        teamScheduleSubmittedQuery = query
        teamScheduleErrorMessage = nil
        isTeamScheduleSearchFocused = false
        persistTeamScheduleRecentSearch(query)

        let selectedSport = teamScheduleSelectedSport
        let cacheKey = teamScheduleCacheKey(query: query, sport: selectedSport)
        if let cached = teamScheduleLookupCache[cacheKey],
           Date().timeIntervalSince(cached.fetchedAt) < Self.teamScheduleCacheDuration {
            teamScheduleResults = cached.results
            teamScheduleIsLoading = false
#if DEBUG
            print("[TeamScheduleDebug] cacheHit key=\(cacheKey) count=\(cached.results.count)")
#endif
            return
        }

        teamScheduleResults = []
        teamScheduleIsLoading = true
#if DEBUG
        print("[TeamScheduleDebug] lookupStarted key=\(cacheKey)")
#endif
        Task { @MainActor in
            do {
                let fetched = try await LiveSportsService.shared.fetchLiveMatches(
                    windowDays: 31,
                    sportFilter: selectedSport.lookupSportFilter
                )
                let results = teamScheduleFilteredResults(
                    from: fetched,
                    query: query
                )
                teamScheduleLookupCache[cacheKey] = TeamScheduleCacheEntry(fetchedAt: Date(), results: results)
                guard teamScheduleSubmittedQuery == query, teamScheduleSelectedSport == selectedSport else { return }
                teamScheduleResults = results
                teamScheduleErrorMessage = nil
#if DEBUG
                print("[TeamScheduleDebug] lookupFinished key=\(cacheKey) fetched=\(fetched.count) results=\(results.count)")
#endif
            } catch {
                guard teamScheduleSubmittedQuery == query, teamScheduleSelectedSport == selectedSport else { return }
                teamScheduleResults = []
                teamScheduleErrorMessage = "Couldn’t load upcoming games for \(query) \(selectedSport.title).\nTry again in a moment."
#if DEBUG
                print("[TeamScheduleDebug] lookupFailed key=\(cacheKey) error=\(error.localizedDescription)")
#endif
            }
            guard teamScheduleSubmittedQuery == query, teamScheduleSelectedSport == selectedSport else { return }
            teamScheduleIsLoading = false
        }
    }

    private func teamScheduleFilteredResults(
        from matches: [LiveMatch],
        query: String
    ) -> [LiveMatch] {
        let normalizedQuery = calendarNormalizedSearchText(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let start = teamScheduleRangeStart
        let end = teamScheduleRangeEndExclusive
        return matches
            .filter { match in
                match.startTime >= start
                    && match.startTime < end
                    && teamScheduleMatch(match, matchesNormalizedQuery: normalizedQuery)
            }
            .sorted { lhs, rhs in
                if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
                return "\(lhs.awayTeam) \(lhs.homeTeam)".localizedCaseInsensitiveCompare("\(rhs.awayTeam) \(rhs.homeTeam)") == .orderedAscending
            }
            .prefix(Self.teamScheduleResultLimit)
            .map { $0 }
    }

    private func teamScheduleMatch(_ match: LiveMatch, matchesNormalizedQuery normalizedQuery: String) -> Bool {
        let fields = [
            match.homeTeam,
            match.awayTeam,
            "\(match.awayTeam) vs \(match.homeTeam)",
            "\(match.homeTeam) vs \(match.awayTeam)",
            match.league,
            match.sourceLeagueName,
            match.leagueAlternate,
            match.eventName,
            match.leagueCountry
        ]
        let searchableText = fields
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(calendarNormalizedSearchText)
            .joined(separator: " ")
        if searchableText.contains(normalizedQuery) { return true }
        let tokens = normalizedQuery.split(separator: " ").map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy { searchableText.contains($0) }
    }

    private func teamScheduleSavedGame(for match: LiveMatch) -> SavedProGame? {
        let key = SavedProGame.stableKey(for: match)
        return viewModel.savedProGames.first { $0.stableKey == key }
    }

    private var teamSchedulePopularTeams: [String] {
        teamScheduleSelectedSport.popularTeams
    }

    private var teamScheduleRangeStart: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var teamScheduleRangeEndExclusive: Date {
        Calendar.current.date(byAdding: .day, value: 31, to: teamScheduleRangeStart)
            ?? teamScheduleRangeStart.addingTimeInterval(31 * 24 * 60 * 60)
    }

    private var teamScheduleDateRangeText: String {
        let endInclusive = Calendar.current.date(byAdding: .day, value: 30, to: teamScheduleRangeStart)
            ?? teamScheduleRangeEndExclusive
        return "\(teamScheduleRangeFormatter.string(from: teamScheduleRangeStart)) – \(teamScheduleRangeFormatter.string(from: endInclusive))"
    }

    private func teamScheduleCacheKey(query: String, sport: TeamScheduleSport) -> String {
        let day = calendarSearchDayFormatter.string(from: teamScheduleRangeStart)
        return [
            "teamSchedule",
            sport.cacheKey,
            calendarNormalizedSearchText(query),
            day,
            "30"
        ].joined(separator: "|")
    }

    private func persistTeamScheduleRecentSearch(_ query: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var recent = Self.loadTeamScheduleRecentSearches()
        recent.removeAll { calendarNormalizedSearchText($0) == calendarNormalizedSearchText(clean) }
        recent.insert(clean, at: 0)
        recent = Array(recent.prefix(5))
        UserDefaults.standard.set(recent, forKey: Self.teamScheduleRecentSearchesKey)
        teamScheduleRecentSearches = recent
    }

    private static func loadTeamScheduleRecentSearches() -> [String] {
        UserDefaults.standard.stringArray(forKey: teamScheduleRecentSearchesKey) ?? []
    }

    private func teamScheduleLeadingSymbol(for item: String) -> String {
        CountryFlagHelper.flag(for: item) ?? teamScheduleSelectedSport.emoji
    }

    private func sanitizeBusinessCalendarFilterIfNeeded() {
        guard isBusinessCalendarAccess, viewModel.calendarTabGameFilter == .pickupGames else { return }
        viewModel.calendarTabGameFilter = .venueGames
        viewModel.calendarEventsListCache.removeAll()
    }

    private func handleCalendarAppear() {
        sanitizeBusinessCalendarFilterIfNeeded()
        refreshCurrentDayCalendarSearchForLoadedDataChange()
        guard isCalendarTabSelected else {
#if DEBUG
            print("[PerfPhase1D] deferredCalendarWork reason=calendarScreenOnAppearPickupRefresh")
#endif
            return
        }
        refreshCalendarProGamesIfNeeded(reason: "calendar_tab_appear")
        guard viewModel.canFanUsePickupGamesUI else { return }
        Task {
            await viewModel.refreshCalendarTabPickupSources()
        }
    }

    private func cancelCalendarSearchDebounce() {
        gameSearchDebounceTask?.cancel()
        gameSearchDebounceTask = nil
    }

    private func handleCalendarSearchTextChange() {
        scheduleCalendarSearchRefresh()
    }

    private func handleCalendarRegionModeChange() {
        guard isCalendarTabSelected else { return }
        viewModel.calendarEventsListCache.removeAll()
        viewModel.recomputeCalendarDotDates(force: true)
        viewModel.loadCalendarTabCalendarDotsAroundMonth(
            viewModel.calendarTabSelectedDate,
            reason: "calendar_tab_region_mode_change"
        )
    }

    private func handleCalendarSelectedSportChange() {
        refreshCurrentDayCalendarSearchForLoadedDataChange()
        guard isCalendarTabSelected else { return }
        viewModel.calendarEventsListCache.removeAll()
        viewModel.recomputeCalendarDotDates(force: true)
        viewModel.loadCalendarTabCalendarDotsAroundMonth(
            viewModel.calendarTabSelectedDate,
            reason: "calendar_tab_sport_change"
        )
    }

    private func handleCalendarGameFilterChange() {
        refreshCurrentDayCalendarSearchForLoadedDataChange()
        guard isCalendarTabSelected else { return }
        sanitizeBusinessCalendarFilterIfNeeded()
        viewModel.calendarEventsListCache.removeAll()
        viewModel.loadCalendarTabCalendarDotsAroundMonth(
            viewModel.calendarTabSelectedDate,
            reason: "calendar_tab_filter_change"
        )
        refreshCalendarProGamesIfNeeded(reason: "calendar_tab_filter_change")
    }

    private func handleCalendarTabSelectionChange(active: Bool) {
        guard active else { return }
        sanitizeBusinessCalendarFilterIfNeeded()
        refreshCalendarProGamesIfNeeded(reason: "calendar_tab_selected")
        refreshCalendarPickupSourcesIfNeeded()
    }

    private func handleCalendarScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .active else { return }
        guard isCalendarTabSelected else { return }
        sanitizeBusinessCalendarFilterIfNeeded()
        refreshCalendarProGamesIfNeeded(reason: "calendar_scene_active")
        refreshCalendarPickupSourcesIfNeeded()
    }

    private func handleCalendarSelectedDateChange() {
        refreshCurrentDayCalendarSearchForLoadedDataChange()
        guard isCalendarTabSelected else { return }
        sanitizeBusinessCalendarFilterIfNeeded()
        refreshCalendarProGamesIfNeeded(reason: "calendar_selected_date_change")
        refreshCalendarPickupSourcesIfNeeded()
    }

    private func refreshCalendarPickupSourcesIfNeeded() {
        guard viewModel.canFanUsePickupGamesUI else { return }
        Task {
            await viewModel.refreshCalendarTabPickupSources()
        }
    }

    private func handleCalendarDatePickerDone() {
        withAnimation(.spring()) {
            viewModel.selectedBar = nil
            viewModel.selectedEvent = nil
            viewModel.calendarEventsListCache.removeAll()
            sanitizeBusinessCalendarFilterIfNeeded()
            viewModel.loadCalendarTabCalendarDotsAroundMonth(
                viewModel.calendarTabSelectedDate,
                reason: "calendar_tab_sheet_done"
            )
            viewModel.loadGamesFromSupabase()
            Task {
                await viewModel.refreshCalendarTabPickupSources()
            }
            showDatePicker = false
        }
    }

    private func handleCalendarDisplayedMonthChange(_ month: Date) {
        Task { @MainActor in
            viewModel.loadCalendarTabCalendarDotsAroundMonth(month, reason: "calendar_tab_month_change")
        }
    }

    private var header: some View {
        FanGeoPagePurposeHeader(
            title: "Schedule",
            subtitle: "Find games, watch parties, and pickup games."
        )
        .padding(.horizontal)
    }

    private var gameTypeFilter: some View {
        GameOnSegmentedControl(
            tabs: calendarVisibleGameFilters.map { filter in
                GameOnSegmentedTab(
                    id: filter,
                    title: filter.segmentTitle,
                    systemImage: calendarSegmentSystemImage(for: filter),
                    badge: calendarSegmentBadge(for: filter),
                    tint: FGColor.accentGreen,
                    accessibilityLabel: "Show \(filter.segmentTitle)"
                )
            },
            selection: calendarGameFilterBinding
        )
        .padding(.horizontal)
    }

    private func calendarSegmentSystemImage(for filter: CalendarTabGameFilter) -> String {
        switch filter {
        case .venueGames:
            return "storefront.fill"
        case .pickupGames:
            return "person.3.fill"
        case .proGames:
            return "trophy.fill"
        }
    }

    private func calendarSegmentBadge(for filter: CalendarTabGameFilter) -> String? {
        let count: Int
        switch filter {
        case .venueGames:
            count = venueEventsForSelectedDateNoSearch.count
        case .pickupGames:
            count = pickupEventsForSelectedDateNoSearch.count
        case .proGames:
            count = proMatchesForSelectedDateNoSearch.count
        }
        return count > 0 ? "\(count)" : nil
    }

    private var calendarSearchRow: some View {
        HStack(spacing: 10) {
            gameSearchBar
                .frame(maxWidth: .infinity)

            if isProGamesSelected {
                teamScheduleButton
            }
        }
        .padding(.horizontal)
    }

    private var teamScheduleButton: some View {
        Button {
            presentTeamScheduleSheet()
        } label: {
            Label("Team Schedule", systemImage: "magnifyingglass")
                .font(.caption.weight(.heavy))
                .lineLimit(1)
                .foregroundStyle(FGColor.accentGreen)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.44 : 0.28), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Team Schedule")
    }

    private var calendarDateStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    showDatePicker = true
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(FGColor.accentGreen)
                        .frame(width: 44, height: 52)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(FGColor.divider(calendarColorScheme).opacity(0.55), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open calendar picker")

                ForEach(calendarDateStripDates, id: \.timeIntervalSince1970) { date in
                    calendarDateStripButton(date)
                }
            }
            .padding(.horizontal)
        }
    }

    private var calendarDateStripDates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let selectedDay = calendar.startOfDay(for: viewModel.calendarTabSelectedDate)
        let sixDaysFromToday = calendar.date(byAdding: .day, value: 6, to: today) ?? today
        let startDay = (today...sixDaysFromToday).contains(selectedDay)
            ? today
            : selectedDay

        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: startDay)
        }
    }

    private func calendarDateStripButton(_ date: Date) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(date, inSameDayAs: viewModel.calendarTabSelectedDate)
        let isToday = calendar.isDateInToday(date)
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                viewModel.calendarTabSelectedDate = date
            }
        } label: {
            VStack(spacing: 4) {
                Text(isToday ? "Today" : calendarDateStripWeekdayFormatter.string(from: date))
                    .font(.caption.weight(.heavy))
                    .lineLimit(1)
                Text(calendarDateStripDayFormatter.string(from: date))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.secondaryText(calendarColorScheme))
            .frame(width: 68, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.20 : 0.12) : Color(.secondarySystemGroupedBackground))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.48 : 0.34)
                            : FGColor.divider(calendarColorScheme).opacity(0.55),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calendarDateStripAccessibilityFormatter.string(from: date))
    }

    private var compactCalendarDateTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: viewModel.calendarTabSelectedDate)
    }

    private var eventsHeader: some View {
        HStack {
            Text(eventsHeaderTitle)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.primary)

            Spacer()

            if isProGamesSelected {
                if viewModel.isLoadingLiveMatches {
                    ProgressView()
                        .controlSize(displayedProMatches.isEmpty ? .regular : .small)
                }
            } else if viewModel.isLoadingEvents {
                ProgressView()
            } else if viewModel.isRefreshingDiscoverEvents && !displayedEvents.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal)
    }

    private var eventsHeaderTitle: String {
        if isCalendarSearchModeActive {
            return "Search Results"
        }

        return calendarSelectedDateMatchesTitle
    }

    private var calendarSelectedDateMatchesTitle: String {
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: viewModel.calendarTabSelectedDate)
        let today = calendar.startOfDay(for: Date())
        let noun = calendarSectionTitleNoun
        if selectedDay == today {
            return "Today’s \(noun)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           selectedDay == tomorrow {
            return "Tomorrow’s \(noun)"
        }
        return "\(compactCalendarDateTitle) \(noun)"
    }

    private var calendarSectionTitleNoun: String {
        switch effectiveCalendarGameFilter {
        case .venueGames:
            return "Watch Parties"
        case .pickupGames:
            return "Pickup Games"
        case .proGames:
            return "Matches"
        }
    }

    private func refreshCalendarProGamesIfNeeded(reason: String) {
        guard isProGamesSelected else { return }
#if DEBUG
        print("[CalendarProGamesDebug] refreshReason=\(reason)")
#endif
        Task {
            await viewModel.refreshLiveMatchesForCalendar(selectedDate: viewModel.calendarTabSelectedDate, forceRefresh: false)
        }
    }

    private var calendarProGamesEmptyStateMessage: String {
        if selectedCalendarFeaturedEvent != nil {
            return "📅 No games found for this date.\nTry another date."
        }
        if calendarLeagueCountryFilterIsActive {
            return "📅 No games found for this date.\nTry another date."
        }
        return "📅 No games found for this date.\nTry another date."
    }

    private var calendarEventsEmptyStateMessage: String {
        switch effectiveCalendarGameFilter {
        case .venueGames:
            return "🏟 No watch parties scheduled.\nExplore nearby venues or host one."
        case .pickupGames:
            return "⚽ No pickup games scheduled.\nCreate the first game."
        case .proGames:
            return calendarProGamesEmptyStateMessage
        }
    }

    private func updateSelectedCalendarLeagueCountries(_ countries: Set<String>) {
        calendarLeagueCountryFilterRaw = LiveLeagueCountryFilterPreference.encode(countries)
    }

    private var gameSearchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search teams, leagues, or games…", text: $gameSearchText)
                .textInputAutocapitalization(.words)
                .font(.subheadline)
                .focused($isGameSearchFocused)
                .submitLabel(.search)
                .onSubmit {
                    applyCalendarSearchText(gameSearchText)
                }

            if !gameSearchText.isEmpty {
                Button {
                    clearCalendarSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(calendarColorScheme).opacity(0.55), lineWidth: 1)
        }
    }

    private var calendarSearchSuggestionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggestions")
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                .textCase(.uppercase)
                .tracking(0.5)

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(calendarSearchSuggestions) { suggestion in
                    Button {
                        applyCalendarSearchText(suggestion.title)
                    } label: {
                        calendarSearchSuggestionRow(suggestion)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(calendarColorScheme).opacity(0.55), lineWidth: 1)
        }
        .padding(.horizontal)
    }

    private func calendarSearchSuggestionRow(_ suggestion: CalendarSearchSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: suggestion.kind.systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(suggestion.kind.tint)
                .frame(width: 28, height: 28)
                .background(suggestion.kind.tint.opacity(calendarColorScheme == .dark ? 0.18 : 0.10), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(calendarColorScheme))
                    .lineLimit(1)

                if let subtitle = suggestion.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var eventsList: some View {
        Group {
            if !calendarTabSelectedDayIsTodayOrFuture {
                Text("Past dates are not available. Choose today or a future day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .top)
            } else {
                ScrollView {
                    Group {
                        if isProGamesSelected {
                            let proMatches = displayedProMatches
                            if proMatches.isEmpty {
                                calendarEmptyState(calendarProGamesEmptyStateMessage)
                            } else {
                                VStack(spacing: 12) {
                                    ForEach(proMatches) { match in
                                        calendarProGameCard(match)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .top)
                            }
                        } else if displayedEvents.isEmpty {
                            calendarEmptyState(calendarEventsEmptyStateMessage)
                        } else {
                            VStack(spacing: 12) {
                                ForEach(displayedEvents) { event in
                                    calendarEventCard(event)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .top)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 100)
                }
            }
        }
    }

    private var calendarSearchResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if calendarSearchResultGroups.isEmpty {
                    calendarEmptyState(calendarSearchEmptyStateText)
                } else {
                    ForEach(calendarSearchResultGroups) { group in
                        calendarSearchDateSection(group)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 100)
            .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .top)
        }
    }

    private func calendarSearchDateSection(_ group: CalendarSearchDateGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(calendarSearchDateHeader(for: group.date))
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                .textCase(.uppercase)
                .tracking(0.55)
                .padding(.horizontal, 2)

            LazyVStack(spacing: 12) {
                ForEach(group.items) { item in
                    calendarSearchResultCard(item)
                }
            }
        }
    }

    @ViewBuilder
    private func calendarSearchResultCard(_ item: CalendarSearchResultItem) -> some View {
        switch item {
        case .venue(let event), .pickup(let event):
            calendarEventCard(event)
        case .pro(let match):
            calendarProGameCard(match)
        }
    }

    private var calendarSearchEmptyStateText: String {
        if debouncedCalendarSearchQuery.isEmpty {
            return "Search loaded games by team, country, league, competition, or matchup."
        }
        return "No loaded games match “\(debouncedCalendarSearchQuery)” yet."
    }

    private func calendarEmptyState(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .center)
    }

    @ViewBuilder
    private var calendarSecondaryFilterBar: some View {
        if isProGamesSelected {
            proGamesFilterStack
        } else {
            sportFilterBar
        }
    }

    private var proGamesFilterStack: some View {
        proGamesSportFilterBar
    }

    private var proGamesSportFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(calendarProVisibleSportFilters, id: \.selection) { item in
                    proGamesSportChip(selection: item.selection, displayTitle: item.display)
                    if item.selection == "All" {
                        ForEach(calendarFeaturedEvents) { featuredEvent in
                            calendarFeaturedEventChip(featuredEvent)
                        }
                    }
                }

                proGamesLeagueCountryChip

                SportFilterChip(sport: "More", isSelected: false, isCompact: true) {
                    showCalendarSportMoreSheet = true
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal)
    }

    private var proGamesWorldCupFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                proGamesLeagueCountryChip
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal)
    }

    private var proGamesLeagueCountryChip: some View {
        Button {
            showCalendarLeagueCountryFilterSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 13, weight: .semibold))

                Text(calendarLeagueCountryChipTitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .foregroundStyle(calendarLeagueCountryFilterIsActive ? Color.white : FGColor.accentGreen)
            .background {
                Capsule(style: .continuous)
                    .fill(calendarLeagueCountryFilterIsActive ? FGColor.accentGreen : FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.18 : 0.10))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.44 : 0.28), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(calendarLeagueCountryFilterCount == 0 ? "Countries" : "Countries, \(calendarLeagueCountryFilterCount) selected")
    }

    private var sportFilterBar: some View {
        ScalableSportFilterChipRow(
            viewModel: viewModel,
            showMoreSheet: $showCalendarSportMoreSheet,
            rowSpacing: 10,
            isCompact: true
        )
    }

    private func proGamesSportChip(selection: String, displayTitle: String? = nil) -> some View {
        SportFilterChip(
            sport: selection,
            displayTitle: displayTitle,
            isSelected: selectedCalendarFeaturedEvent == nil && DiscoverSportFilterRowLayout.selectionTokensMatch(calendarProGamesSportFilter, selection),
            isCompact: true
        ) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                calendarFeaturedEventFilterSlug = nil
                calendarProGamesSportFilter = selection
            }
        }
    }

    private func calendarFeaturedEventChip(_ featuredEvent: FeaturedEvent) -> some View {
        SportFilterChip(
            sport: featuredEvent.sport ?? "Soccer",
            displayTitle: featuredEvent.chipTitle,
            isSelected: selectedCalendarFeaturedEvent?.slug == featuredEvent.slug,
            isCompact: true
        ) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                calendarProGamesSportFilter = "All"
                updateSelectedCalendarLeagueCountries([])
                calendarFeaturedEventFilterSlug = selectedCalendarFeaturedEvent?.slug == featuredEvent.slug ? nil : featuredEvent.slug
            }
        }
    }

    private func handleEventTap(_ event: SportsEvent) {
        if viewModel.isGuestDiscoverMode {
            viewModel.discoverNavigateToAccountForUserAuth = true
            return
        }
        openSelectionInDiscover(event)
    }

    private func openSelectionInDiscover(_ event: SportsEvent) {
        let isPickup = event.league == MapViewModel.calendarTabPickupLeagueMarker
        let targetMode: DiscoverMapContentMode = isPickup ? .pickupGames : .venues
        if viewModel.discoverMapContentMode != targetMode {
            viewModel.clearDiscoverMapContentSelectionsWhenSwitching(to: targetMode)
            viewModel.discoverMapContentMode = targetMode
        }
        let requestID = viewModel.beginDiscoverDateChange(to: event.date)
        viewModel.scheduleDiscoverSelectedDayRefresh(requestID: requestID)
        if isPickup {
            if let row = viewModel.resolvedPickupGameRow(for: event.id) {
                viewModel.selectPickupGameOnMap(row)
            } else {
                viewModel.clearPickupMapSelection()
            }
        } else {
            viewModel.selectEvent(event)
        }
        selectedTab = .discover
    }

    @ViewBuilder
    private func calendarEventCard(_ event: SportsEvent) -> some View {
        if event.league == MapViewModel.calendarTabPickupLeagueMarker {
            if !isBusinessCalendarAccess {
                pickupCalendarEventCard(event)
            }
        } else {
            venueCalendarEventCard(event)
        }
    }

    private func calendarProGameCard(_ match: LiveMatch) -> some View {
        let sportKey = match.liveSportVisualType.sportFilterCatalogKey
        let accent = match.matchStatus.isHappeningNow ? FGColor.dangerRed : viewModel.colorForSport(sportKey)
        let featuredEvent = calendarFeaturedEvent(for: match)
        let isSaved = viewModel.isProGameSaved(match)
        let watchPartyCount = watchPartyCount(for: match)
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(calendarProGameStartTimeText(match))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)

                VStack(alignment: .leading, spacing: 7) {
                    calendarTeamLine(match.awayTeam, score: match.matchStatus.isHappeningNow || match.matchStatus == .fullTime ? match.scoreAway : nil)
                    calendarTeamLine(match.homeTeam, score: match.matchStatus.isHappeningNow || match.matchStatus == .fullTime ? match.scoreHome : nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(featuredEvent?.emptyStateTitle ?? match.league)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(calendarColorScheme))
                    .lineLimit(2)
                Text(match.league)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if watchPartyCount > 0 {
                    Text(watchPartyCount == 1 ? "1 watch party" : "\(watchPartyCount) watch parties")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(FGColor.accentGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.18 : 0.10), in: Capsule())
                }
            }
            .frame(width: 112, alignment: .leading)

            ZStack(alignment: .topTrailing) {
                ProGameSportBadgeView(
                    sportType: match.liveSportVisualType,
                    diameter: 64,
                    featuredEvent: featuredEvent,
                    featuredEventSlug: match.featuredEventSlug
                )
                calendarProGameSaveButton(match, isSaved: isSaved, accent: accent)
                    .offset(x: 8, y: -8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(calendarColorScheme == .dark ? 0.16 : 0.045), radius: 8, y: 3)
    }

    private func calendarTeamLine(_ team: String, score: Int?) -> some View {
        HStack(spacing: 8) {
            Text(calendarTeamFlagOrBall(team))
                .font(.title3)
                .frame(width: 24)
            Text(team.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let score {
                Spacer(minLength: 4)
                Text("\(score)")
                    .font(.headline.weight(.black).monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
    }

    private func calendarTeamFlagOrBall(_ team: String) -> String {
        let trimmed = team.trimmingCharacters(in: .whitespacesAndNewlines)
        return CountryFlagHelper.flag(for: trimmed) ?? "•"
    }

    private func calendarProGameSaveButton(_ match: LiveMatch, isSaved: Bool, accent: Color) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                viewModel.toggleSavedProGame(match)
            }
        } label: {
            Image(systemName: isSaved ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isSaved ? Color.red.opacity(0.95) : accent)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill((isSaved ? Color.red : accent).opacity(calendarColorScheme == .dark ? 0.18 : 0.10))
                )
                .overlay {
                    Circle()
                        .strokeBorder((isSaved ? Color.red : accent).opacity(calendarColorScheme == .dark ? 0.40 : 0.24), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSaved ? "Unsave pro game" : "Save pro game")
    }

    private func calendarFeaturedEvent(for match: LiveMatch) -> FeaturedEvent? {
        if let featuredEventSlug = match.featuredEventSlug {
            let normalizedSlug = LiveMatchFilters.normalizedSearchText(featuredEventSlug)
            if let direct = calendarFeaturedEvents.first(where: { LiveMatchFilters.normalizedSearchText($0.slug) == normalizedSlug }) {
                return direct
            }
        }
        return calendarFeaturedEvents.first {
            LiveMatchFilters.matchesFeaturedEvent(match, featuredEvent: $0)
        }
    }

    private func calendarFeaturedEventBadge(_ featuredEvent: FeaturedEvent, accent: Color) -> some View {
        Text(featuredEvent.chipTitle)
            .font(.caption2.weight(.bold))
            .foregroundStyle(accent)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(calendarColorScheme == .dark ? 0.18 : 0.10))
            )
    }

    private func calendarProGameTitle(_ match: LiveMatch) -> String {
        "\(calendarTeamDisplayName(match.awayTeam)) at \(calendarTeamDisplayName(match.homeTeam))"
    }

    private func calendarTeamDisplayName(_ teamName: String) -> String {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              CountryFlagHelper.isCountry(trimmed),
              let flag = CountryFlagHelper.flag(for: trimmed),
              !flag.isEmpty else {
            return trimmed
        }
        return "\(flag) \(trimmed)"
    }

    private func calendarProGameStartTimeText(_ match: LiveMatch) -> String {
        CompactGameTimeFormatter.timeWithZone(
            for: match.startTime,
            timeZoneOption: viewModel.selectedTimeZone
        )
    }

    private func calendarProGameStatusText(_ match: LiveMatch) -> String {
        switch match.matchStatus {
        case .live:
            if let minute = match.minute {
                return "LIVE \(minute)'"
            }
            return "LIVE"
        case .halfTime:
            return "HT"
        case .fullTime:
            return "Final"
        case .scheduled:
            return "Scheduled"
        }
    }

    private func pickupCalendarCapacityPillText(for row: PickupGameRow?) -> String {
        guard let row else { return "Open" }
        return row.isPickupFullForDiscover ? "Full" : "Open"
    }

    private func pickupCalendarEventCard(_ event: SportsEvent) -> some View {
        let now = Date()
        let pickupRow = viewModel.resolvedPickupGameRow(for: event.id)
        let pickupStarted = pickupRow?.hasPickupGameStarted(now: now) ?? false
        let addressLine = pickupRow.map { viewModel.pickupGameCalendarAddressLine($0) } ?? ""
        let spotsLine = pickupRow.flatMap { viewModel.pickupGameCalendarSpotsLine($0) }
        let capacityMeta = pickupCalendarCapacityPillText(for: pickupRow)
        let rosterState = pickupRow.map { $0.isPickupFullForDiscover ? "full" : "open" } ?? "unknown"

        return Button {
            if viewModel.isGuestDiscoverMode {
                viewModel.discoverNavigateToAccountForUserAuth = true
                return
            }
            calendarPickupDetailToken = PickupDetailNavigationToken(id: event.id)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                PickupGameStartedSportGlyphFrame(showStarted: pickupStarted) {
                    SportArtworkIconView(sport: event.sport, diameter: 46)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)

                    if let row = pickupRow {
                        Text(viewModel.pickupGameCalendarDateTimeLine(row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if !addressLine.isEmpty {
                            Text(addressLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let spots = spotsLine {
                            Text(spots)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                    } else {
                        Text("Pickup details loading…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if pickupStarted {
                        PickupGameStartedLineCaption()
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 8) {
                    Text(capacityMeta)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(capacityMeta == "Full" ? FGColor.secondaryText(calendarColorScheme) : FGColor.accentGreen)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill((capacityMeta == "Full" ? Color.primary : FGColor.accentGreen).opacity(calendarColorScheme == .dark ? 0.16 : 0.10))
                        )
                        .accessibilityLabel(capacityMeta == "Full" ? "Roster full" : "Spots available")

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(calendarColorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(calendarColorScheme == .dark ? 0.14 : 0.04), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .onAppear {
#if DEBUG
            print("[CalendarPickupPublicMode] personalStateHidden=true")
            print("[CalendarPickupPublicMode] badgeRemoved=true")
            print("[CalendarPickupPublicMode] gameId=\(event.id.uuidString.lowercased())")
            print("[CalendarPickupPublicMode] rosterState=\(rosterState)")
#endif
            if let r = pickupRow {
                PickupGameStartedStateDebug.log(row: r, now: now, allowedActions: "calendar_tab_public_row")
            }
            if let row = pickupRow {
                Task {
                    await viewModel.loadPickupCreatorDisplayNameIfNeeded(creatorUserId: row.creator_user_id)
                }
            }
        }
    }

    private func venueCalendarEventCard(_ event: SportsEvent) -> some View {
        let isVenueEvent = event.league == "Venue Event"
        let venueBar = isVenueEvent ? viewModel.barVenueForCalendarVenueEvent(event) : nil
        let venueBizEmail = venueBar.flatMap { VenueGameBusinessEmail.resolvedDisplayEmail(for: $0) }
        let watchPartyCount = watchPartyCount(forVenueEventTitle: event.title)

        return Button {
            handleEventTap(event)
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(viewModel.displayTime(for: event))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(FGColor.accentGreen)
                        Spacer(minLength: 0)
                        Text(watchPartyCount == 1 ? "1 watch party" : "\(watchPartyCount) watch parties")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.accentGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.18 : 0.10), in: Capsule())
                    }

                    Text(event.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text(venueEventSubtitle(event))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let venueBizEmail {
                        VenueGameBusinessContactEmailRow(email: venueBizEmail)
                            .padding(.top, 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                calendarVenueThumbnail(venueBar, sport: event.sport)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.black.opacity(calendarColorScheme == .dark ? 0.14 : 0.04), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .onAppear {
            if isVenueEvent, let b = venueBar {
                VenueGameBusinessEmail.logDebug(bar: b)
            }
        }
    }

    private func venueEventSubtitle(_ event: SportsEvent) -> String {
        let venue = event.venueName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let city = event.venueCity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = [venue, city].filter { !$0.isEmpty }.joined(separator: " • ")
        let sport = AppSportCatalog.displayLabel(forSportToken: event.sport)
        return location.isEmpty ? "\(sport) watch party" : "\(sport) • \(location)"
    }

    private func watchPartyCount(forVenueEventTitle title: String) -> Int {
        let key = normalizedCalendarMatchText(title)
        guard !key.isEmpty else { return 0 }
        return max(
            1,
            venueEventsForSelectedDateNoSearch.filter {
                normalizedCalendarMatchText($0.title) == key
            }.count
        )
    }

    private func watchPartyCount(for match: LiveMatch) -> Int {
        let away = normalizedCalendarMatchText(match.awayTeam)
        let home = normalizedCalendarMatchText(match.homeTeam)
        let title = normalizedCalendarMatchText("\(match.awayTeam) \(match.homeTeam)")
        guard !away.isEmpty || !home.isEmpty else { return 0 }

        return venueEventsForSelectedDateNoSearch.filter { event in
            let eventText = normalizedCalendarMatchText(event.title)
            if !away.isEmpty, !home.isEmpty, eventText.contains(away), eventText.contains(home) {
                return true
            }
            return !title.isEmpty && eventText.contains(title)
        }.count
    }

    private func normalizedCalendarMatchText(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    @ViewBuilder
    private func calendarVenueThumbnail(_ venue: BarVenue?, sport: String) -> some View {
        let imageURL = venue?.coverPhotoThumbnailURL ?? venue?.coverPhotoURL
        if let imageURL, let url = URL(string: imageURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    calendarVenueThumbnailFallback(sport)
                }
            }
            .frame(width: 88, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            calendarVenueThumbnailFallback(sport)
                .frame(width: 88, height: 76)
        }
    }

    private func calendarVenueThumbnailFallback(_ sport: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    viewModel.colorForSport(sport).opacity(calendarColorScheme == .dark ? 0.35 : 0.20),
                    FGColor.accentGreen.opacity(calendarColorScheme == .dark ? 0.24 : 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            SportArtworkIconView(sport: sport, diameter: 38)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func scheduleCalendarSearchRefresh() {
        gameSearchDebounceTask?.cancel()
        gameSearchDebounceTask = nil
        refreshCurrentDayCalendarSearchResults(reason: "typing")
    }

    private func refreshCurrentDayCalendarSearchForLoadedDataChange() {
        guard isCalendarSearchModeActive else { return }
        refreshCurrentDayCalendarSearchResults(reason: "loadedDataChange")
    }

    private func refreshCurrentDayCalendarSearchResults(reason: String) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let query = immediateCalendarSearchQuery
        debouncedGameSearchText = query
        calendarSearchResultGroups = []
        calendarSearchSuggestions = []
        guard !query.isEmpty else {
            calendarSearchFilteredEvents = []
            calendarSearchFilteredProMatches = []
            logScheduleSearchPerf(
                query: query,
                mode: effectiveCalendarGameFilter,
                beforeCount: 0,
                resultCount: 0,
                startedAt: startedAt,
                reason: reason
            )
            return
        }

        let normalizedQuery = calendarNormalizedSearchText(query)
        if isProGamesSelected {
            let baseMatches = calendarBaseDisplayedProMatches()
            calendarSearchFilteredProMatches = baseMatches.filter {
                calendarCurrentDayProMatch($0, matchesNormalizedQuery: normalizedQuery)
            }
            calendarSearchFilteredEvents = []
            logScheduleSearchPerf(
                query: query,
                mode: effectiveCalendarGameFilter,
                beforeCount: baseMatches.count,
                resultCount: calendarSearchFilteredProMatches.count,
                startedAt: startedAt,
                reason: reason
            )
        } else {
            let baseEvents = calendarBaseDisplayedEvents()
            calendarSearchFilteredEvents = baseEvents.filter {
                calendarCurrentDayEvent($0, matchesNormalizedQuery: normalizedQuery)
            }
            calendarSearchFilteredProMatches = []
            logScheduleSearchPerf(
                query: query,
                mode: effectiveCalendarGameFilter,
                beforeCount: baseEvents.count,
                resultCount: calendarSearchFilteredEvents.count,
                startedAt: startedAt,
                reason: reason
            )
        }
    }

    private func applyCalendarSearchText(_ rawText: String) {
        let query = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        gameSearchDebounceTask?.cancel()
        gameSearchDebounceTask = nil
        gameSearchText = query
        debouncedGameSearchText = query
        calendarSearchSuggestions = []
        isGameSearchFocused = false
        refreshCurrentDayCalendarSearchResults(reason: "submit")
    }

    private func clearCalendarSearch() {
        gameSearchDebounceTask?.cancel()
        gameSearchDebounceTask = nil
        gameSearchText = ""
        debouncedGameSearchText = ""
        calendarSearchSuggestions = []
        calendarSearchResultGroups = []
        calendarSearchFilteredEvents = []
        calendarSearchFilteredProMatches = []
    }

    private func calendarCurrentDayEvent(_ event: SportsEvent, matchesNormalizedQuery normalizedQuery: String) -> Bool {
        calendarCurrentDaySearchTextMatches(
            fields: [
                event.title,
                event.sport,
                event.league,
                event.country,
                event.venueName,
                event.venueCity
            ],
            normalizedQuery: normalizedQuery
        )
    }

    private func calendarCurrentDayProMatch(_ match: LiveMatch, matchesNormalizedQuery normalizedQuery: String) -> Bool {
        calendarCurrentDaySearchTextMatches(
            fields: [
                match.homeTeam,
                match.awayTeam,
                "\(match.awayTeam) vs \(match.homeTeam)",
                "\(match.homeTeam) vs \(match.awayTeam)",
                "\(match.awayTeam) at \(match.homeTeam)",
                match.sport,
                match.league,
                match.sourceLeagueName,
                match.leagueAlternate,
                match.eventName,
                match.leagueCountry
            ],
            normalizedQuery: normalizedQuery
        )
    }

    private func calendarCurrentDaySearchTextMatches(fields: [String?], normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        let searchableText = fields
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(calendarNormalizedSearchText)
            .joined(separator: " ")
        guard !searchableText.isEmpty else { return false }
        if searchableText.contains(normalizedQuery) { return true }
        let tokens = normalizedQuery.split(separator: " ").map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy { searchableText.contains($0) }
    }

    private func logScheduleSearchPerf(
        query: String,
        mode: CalendarTabGameFilter,
        beforeCount: Int,
        resultCount: Int,
        startedAt: CFAbsoluteTime,
        reason: String
    ) {
#if DEBUG
        let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        let selectedDate = calendarSearchDayFormatter.string(from: viewModel.calendarTabSelectedDate)
        print(
            "[ScheduleSearchPerf] " +
            "reason=\(reason) " +
            "searchText=\"\(query)\" " +
            "selectedDate=\(selectedDate) " +
            "mode=\(calendarSearchModeLabel(mode)) " +
            "beforeCount=\(beforeCount) " +
            "resultCount=\(resultCount) " +
            "durationMs=\(durationMs)"
        )
#endif
    }

    private func calendarSearchModeLabel(_ mode: CalendarTabGameFilter) -> String {
        switch mode {
        case .venueGames:
            return "Venues"
        case .pickupGames:
            return "Pickup"
        case .proGames:
            return "Pro"
        }
    }

    private func rebuildCalendarSearchIndexIfNeeded(force: Bool = false) {
        calendarSearchIndex = []
        calendarSearchIndexFingerprint = ""
    }

    private func calendarSearchIndexCurrentFingerprint() -> String {
        ""
    }

    private func buildCalendarSearchIndex() -> [CalendarSearchIndexEntry] {
        []
    }

    private func buildCalendarSearchResultGroups(query: String) -> [CalendarSearchDateGroup] {
        let normalizedQuery = calendarNormalizedSearchText(query)
        guard !normalizedQuery.isEmpty else { return [] }

        let sortedItems = calendarSearchIndex
            .filter { entry in
                calendarSearchItemPassesActiveFilters(entry.item)
                    && calendarSearchTextMatches(entry.searchableText, normalizedQuery: normalizedQuery)
            }
            .map(\.item)
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                if lhs.sortTitle != rhs.sortTitle {
                    return lhs.sortTitle.localizedCaseInsensitiveCompare(rhs.sortTitle) == .orderedAscending
                }
                return lhs.id < rhs.id
            }
            .prefix(Self.calendarSearchResultLimit)
            .map { $0 }

        let calendar = Calendar.current
        return Dictionary(grouping: sortedItems) { item in
            calendar.startOfDay(for: item.date)
        }
        .map { CalendarSearchDateGroup(date: $0.key, items: $0.value) }
        .sorted { $0.date < $1.date }
    }

    private func loadedVenueSearchEvents() -> [SportsEvent] {
        viewModel.events.filter { event in
            event.league == "Venue Event"
        }
    }

    private func loadedPickupSearchEvents() -> [SportsEvent] {
        guard !isBusinessCalendarAccess, viewModel.canFanUsePickupGamesUI else { return [] }
        let calendar = Calendar.current
        return viewModel.pickupGamesForDiscoverMap.compactMap { row in
            guard calendarSearchPickupRowPassesListingFilters(row),
                  let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else {
                return nil
            }
            return SportsEvent(
                id: row.id,
                title: row.title,
                sport: row.sport,
                league: MapViewModel.calendarTabPickupLeagueMarker,
                date: calendar.startOfDay(for: start),
                time: calendarSearchTimeFormatter.string(from: start),
                country: "",
                calendarPickupJoinStatus: nil
            )
        }
    }

    private func calendarSearchItemPassesActiveFilters(_ item: CalendarSearchResultItem) -> Bool {
        switch item {
        case .venue(let event):
            guard effectiveCalendarGameFilter == .venueGames else { return false }
            return calendarSport(event.sport, matchesFilter: viewModel.selectedSport)
        case .pickup(let event):
            guard effectiveCalendarGameFilter == .pickupGames else { return false }
            return calendarSport(event.sport, matchesFilter: viewModel.selectedSport)
        case .pro(let match):
            guard effectiveCalendarGameFilter == .proGames else { return false }
            if let selectedCalendarFeaturedEvent {
                return LiveMatchFilters.matchesFeaturedEvent(match, featuredEvent: selectedCalendarFeaturedEvent)
            }
            guard calendarSport(match.sport, matchesFilter: calendarProGamesSportFilter) else { return false }
            return LiveMatchFilters.matchesLeagueCountry(match, selectedCountries: selectedCalendarLeagueCountries)
        }
    }

    private func calendarSport(_ sport: String, matchesFilter filter: String) -> Bool {
        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFilter.isEmpty,
              trimmedFilter.localizedCaseInsensitiveCompare("All") != .orderedSame else {
            return true
        }
        return sport.localizedCaseInsensitiveCompare(trimmedFilter) == .orderedSame
            || SportFilterCatalog.storedSport(sport, matchesSearchQuery: trimmedFilter)
    }

    private func calendarSearchPickupRowPassesListingFilters(_ row: PickupGameRow, now: Date = Date()) -> Bool {
        guard row.is_visible, row.status.lowercased() == "active" else { return false }
        if let removeAfterRaw = row.remove_after_at,
           let removeAfter = PickupGameModels.parseSupabaseTimestamptz(removeAfterRaw),
           removeAfter <= now {
            return false
        }
        return true
    }

    private func calendarVenueEvent(_ event: SportsEvent, matchesNormalizedQuery normalizedQuery: String) -> Bool {
        let row = calendarVenueEventRow(for: event)
        return calendarSearchFieldsMatch(
            [
                event.title,
                event.sport,
                event.league,
                event.country,
                event.venueName,
                event.venueCity,
                row?.event_title,
                row?.home_team,
                row?.away_team,
                row?.external_league,
                row?.venue_name,
                row.flatMap { calendarVenueMatchupTitle(for: $0) }
            ],
            normalizedQuery: normalizedQuery
        )
    }

    private func calendarPickupEvent(_ event: SportsEvent, matchesNormalizedQuery normalizedQuery: String) -> Bool {
        let row = viewModel.resolvedPickupGameRow(for: event.id)
        return calendarSearchFieldsMatch(
            [
                event.title,
                event.sport,
                event.league,
                row?.title,
                row?.description,
                row?.sport,
                row?.game_format,
                row?.skill_level,
                row?.address,
                row?.city,
                row?.state
            ],
            normalizedQuery: normalizedQuery
        )
    }

    private func calendarProMatch(_ match: LiveMatch, matchesNormalizedQuery normalizedQuery: String) -> Bool {
        let featuredEvent = calendarFeaturedEvent(for: match)
        return calendarSearchFieldsMatch(
            [
                match.homeTeam,
                match.awayTeam,
                "\(match.awayTeam) vs \(match.homeTeam)",
                "\(match.homeTeam) vs \(match.awayTeam)",
                "\(match.awayTeam) at \(match.homeTeam)",
                match.sport,
                match.sourceSportName,
                match.league,
                match.sourceLeagueName,
                match.leagueAlternate,
                match.eventName,
                match.leagueCountry,
                match.featuredEventSlug,
                featuredEvent?.title,
                featuredEvent?.shortTitle,
                featuredEvent?.slug,
                featuredEvent?.chipTitle
            ],
            normalizedQuery: normalizedQuery
        )
    }

    private func calendarSearchFieldsMatch(_ fields: [String?], normalizedQuery: String) -> Bool {
        let searchableText = calendarSearchableText(for: fields)
        return calendarSearchTextMatches(searchableText, normalizedQuery: normalizedQuery)
    }

    private func calendarSearchTextMatches(_ searchableText: String, normalizedQuery: String) -> Bool {
        guard !searchableText.isEmpty else { return false }
        if searchableText.contains(normalizedQuery) { return true }

        let queryTokens = normalizedQuery.split(separator: " ").map(String.init)
        return !queryTokens.isEmpty && queryTokens.allSatisfy { searchableText.contains($0) }
    }

    private func calendarSearchableText(for fields: [String?]) -> String {
        calendarExpandedSearchFields(fields)
            .map(calendarNormalizedSearchText)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func calendarExpandedSearchFields(_ fields: [String?]) -> [String] {
        var expanded: [String] = []
        for field in fields {
            guard let raw = field?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            expanded.append(raw)
            expanded.append(contentsOf: calendarCountryAliases(for: raw))
            expanded.append(contentsOf: calendarFavoriteTeamAliases(for: raw))
        }
        return expanded
    }

    private func calendarCountryAliases(for raw: String) -> [String] {
        let normalized = calendarNormalizedSearchText(raw)
        guard !normalized.isEmpty else { return [] }
        if ["usa", "us", "u s", "united states", "united states of america", "america"].contains(normalized) {
            return ["USA", "US", "United States", "United States of America", "America"]
        }
        guard CountryFlagHelper.isCountry(raw) else { return [] }
        return ["\(raw) National Team"]
    }

    private func calendarFavoriteTeamAliases(for raw: String) -> [String] {
        let normalized = calendarNormalizedSearchText(raw)
        guard !normalized.isEmpty else { return [] }
        guard let team = FavoriteTeamCatalog.all.first(where: { team in
            if calendarNormalizedSearchText(team.name) == normalized { return true }
            if calendarNormalizedSearchText(team.shortCode ?? "") == normalized { return true }
            return team.searchAliases.contains { calendarNormalizedSearchText($0) == normalized }
        }) else {
            return []
        }

        return ([team.name, team.shortCode, team.league].compactMap { $0 } + team.searchAliases)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func calendarVenueSuggestionCandidates(event: SportsEvent, row: VenueEventRow?) -> [CalendarSearchSuggestionCandidate] {
        var candidates: [CalendarSearchSuggestionCandidate] = []
        candidates += calendarSuggestionCandidates(title: row?.home_team, subtitle: "Team", kind: .team, rank: 0)
        candidates += calendarSuggestionCandidates(title: row?.away_team, subtitle: "Team", kind: .team, rank: 0)
        candidates += calendarSuggestionCandidates(title: event.title, subtitle: event.venueName ?? event.league, kind: .game, rank: 2)
        candidates += calendarSuggestionCandidates(title: event.league, subtitle: event.sport, kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: row?.external_league, subtitle: event.sport, kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: event.country, subtitle: "Country", kind: .team, rank: 0)
        return candidates
    }

    private func calendarPickupSuggestionCandidates(event: SportsEvent) -> [CalendarSearchSuggestionCandidate] {
        calendarSuggestionCandidates(title: event.title, subtitle: "Pickup game", kind: .game, rank: 3)
            + calendarSuggestionCandidates(title: event.sport, subtitle: "Sport", kind: .competition, rank: 4)
    }

    private func calendarProSuggestionCandidates(match: LiveMatch, featuredEvent: FeaturedEvent?) -> [CalendarSearchSuggestionCandidate] {
        var candidates: [CalendarSearchSuggestionCandidate] = []
        candidates += calendarSuggestionCandidates(title: match.homeTeam, subtitle: "Team", kind: .team, rank: 0)
        candidates += calendarSuggestionCandidates(title: match.awayTeam, subtitle: "Team", kind: .team, rank: 0)
        candidates += calendarSuggestionCandidates(title: "\(match.awayTeam) vs \(match.homeTeam)", subtitle: match.league, kind: .game, rank: 2)
        candidates += calendarSuggestionCandidates(title: match.league, subtitle: match.leagueCountry ?? match.sport, kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: match.sourceLeagueName, subtitle: match.sport, kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: match.leagueAlternate, subtitle: match.sport, kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: match.eventName, subtitle: match.league, kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: match.leagueCountry, subtitle: "Country", kind: .team, rank: 0)
        candidates += calendarSuggestionCandidates(title: featuredEvent?.title, subtitle: featuredEvent?.sport ?? "Competition", kind: .competition, rank: 1)
        candidates += calendarSuggestionCandidates(title: featuredEvent?.shortTitle, subtitle: featuredEvent?.title, kind: .competition, rank: 1)
        return candidates
    }

    private func calendarFeaturedEventSuggestionCandidates() -> [CalendarSearchSuggestionCandidate] {
        calendarFeaturedEvents.flatMap { featuredEvent in
            calendarSuggestionCandidates(title: featuredEvent.title, subtitle: featuredEvent.sport ?? "Competition", kind: .competition, rank: 1)
                + calendarSuggestionCandidates(title: featuredEvent.shortTitle, subtitle: featuredEvent.title, kind: .competition, rank: 1)
        }
    }

    private func calendarSuggestionCandidates(
        title: String?,
        subtitle: String?,
        kind: CalendarSearchSuggestionKind,
        rank: Int
    ) -> [CalendarSearchSuggestionCandidate] {
        guard let rawTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty else {
            return []
        }

        var candidates = [
            calendarSuggestionCandidate(title: rawTitle, subtitle: subtitle, kind: kind, rank: rank)
        ]

        let normalizedTitle = calendarNormalizedSearchText(rawTitle)
        let aliases = calendarCountryAliases(for: rawTitle) + calendarFavoriteTeamAliases(for: rawTitle)
        for alias in aliases {
            let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanAlias.isEmpty,
                  calendarNormalizedSearchText(cleanAlias) != normalizedTitle else {
                continue
            }
            candidates.append(calendarSuggestionCandidate(title: cleanAlias, subtitle: rawTitle, kind: kind, rank: rank))
        }

        return candidates.compactMap { $0 }
    }

    private func calendarSuggestionCandidate(
        title: String,
        subtitle: String?,
        kind: CalendarSearchSuggestionKind,
        rank: Int
    ) -> CalendarSearchSuggestionCandidate? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }
        let cleanSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchableText = calendarSearchableText(for: [cleanTitle, cleanSubtitle])
        guard !searchableText.isEmpty else { return nil }
        return CalendarSearchSuggestionCandidate(
            title: cleanTitle,
            subtitle: cleanSubtitle?.isEmpty == false ? cleanSubtitle : nil,
            kind: kind,
            rank: rank,
            searchableText: searchableText
        )
    }

    private func buildCalendarSearchSuggestions(query: String) -> [CalendarSearchSuggestion] {
        let normalizedQuery = calendarNormalizedSearchText(query)
        guard normalizedQuery.count >= 2 else { return [] }

        var suggestions: [CalendarSearchSuggestion] = []
        var seen = Set<String>()

        func add(_ candidate: CalendarSearchSuggestionCandidate) {
            guard calendarSearchTextMatches(candidate.searchableText, normalizedQuery: normalizedQuery) else { return }
            let key = "\(candidate.kind.rawValue):\(calendarNormalizedSearchText(candidate.title))"
            guard seen.insert(key).inserted else { return }
            suggestions.append(
                CalendarSearchSuggestion(
                    title: candidate.title,
                    subtitle: candidate.subtitle,
                    kind: candidate.kind,
                    rank: candidate.rank
                )
            )
        }

        calendarSearchIndex.flatMap(\.suggestions).forEach(add)
        calendarFeaturedEventSuggestionCandidates().forEach(add)

        return suggestions
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(8)
            .map { $0 }
    }

    private func loadedTeamNamesForSuggestions() -> [String] {
        var names: [String] = []
        for match in viewModel.liveMatches {
            names.append(match.homeTeam)
            names.append(match.awayTeam)
            if let country = match.leagueCountry {
                names.append(country)
            }
        }
        for event in loadedVenueSearchEvents() {
            if let row = calendarVenueEventRow(for: event) {
                names.append(row.home_team ?? "")
                names.append(row.away_team ?? "")
            } else {
                names.append(contentsOf: calendarTeamNames(fromMatchupTitle: event.title))
            }
        }
        return names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func calendarVenueEventRow(for event: SportsEvent) -> VenueEventRow? {
        let eventDay = calendarSearchDayFormatter.string(from: event.date)
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sport = event.sport.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.venueEventRows.first { row in
            guard row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(title) == .orderedSame else {
                return false
            }
            if let rowDay = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines), !rowDay.isEmpty, rowDay != eventDay {
                return false
            }
            let rowSport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return rowSport.isEmpty || sport.isEmpty || rowSport.caseInsensitiveCompare(sport) == .orderedSame
        }
    }

    private func calendarVenueMatchupTitle(for row: VenueEventRow) -> String? {
        let home = row.home_team?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let away = row.away_team?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !home.isEmpty, !away.isEmpty else { return nil }
        return "\(away) vs \(home)"
    }

    private func calendarTeamNames(fromMatchupTitle title: String) -> [String] {
        let separators = [" vs ", " at ", " @ ", " v "]
        for separator in separators {
            let parts = title.components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if parts.count == 2 {
                return parts
            }
        }
        return []
    }

    private func calendarSearchDateHeader(for date: Date) -> String {
        calendarSearchSectionDateFormatter.string(from: date)
    }

    private func calendarNormalizedSearchText(_ raw: String) -> String {
        LiveMatchFilters.normalizedSearchText(raw)
    }

    private var calendarSearchTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }

    private var calendarSearchDayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private var calendarSearchSectionDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }

    private var calendarDateStripWeekdayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter
    }

    private var calendarDateStripDayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }

    private var calendarDateStripAccessibilityFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }

    private var teamScheduleRowWeekdayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter
    }

    private var teamScheduleRowDayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }

    private var teamScheduleRangeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }
}

private enum TeamScheduleSport: String, CaseIterable, Identifiable {
    case soccer
    case basketball
    case football
    case baseball
    case hockey

    var id: String { rawValue }
    var cacheKey: String { rawValue }

    var title: String {
        switch self {
        case .soccer:
            return "Soccer"
        case .basketball:
            return "Basketball"
        case .football:
            return "Football"
        case .baseball:
            return "Baseball"
        case .hockey:
            return "Hockey"
        }
    }

    var emoji: String {
        switch self {
        case .soccer:
            return "⚽"
        case .basketball:
            return "🏀"
        case .football:
            return "🏈"
        case .baseball:
            return "⚾"
        case .hockey:
            return "🏒"
        }
    }

    var lookupSportFilter: String {
        switch self {
        case .soccer:
            return "Soccer"
        case .basketball:
            return "Basketball"
        case .football:
            return "Football"
        case .baseball:
            return "Baseball"
        case .hockey:
            return "Hockey"
        }
    }

    var popularTeams: [String] {
        switch self {
        case .soccer:
            return ["France", "PSG", "Argentina", "Real Madrid", "Mexico"]
        case .basketball:
            return ["Lakers", "Celtics", "Nuggets", "Heat", "Warriors"]
        case .football:
            return ["Chiefs", "Eagles", "Cowboys", "49ers", "Bills"]
        case .baseball:
            return ["Dodgers", "Yankees", "Mets", "Cubs", "Red Sox"]
        case .hockey:
            return ["Avalanche", "Rangers", "Maple Leafs", "Oilers", "Canadiens"]
        }
    }

    static func resolved(from raw: String?) -> TeamScheduleSport? {
        let normalized = LiveMatchFilters.normalizedSearchText(raw ?? "")
        guard !normalized.isEmpty, normalized != "all" else { return nil }
        if normalized.contains("soccer") { return .soccer }
        if normalized.contains("basketball") || normalized.contains("nba") { return .basketball }
        if normalized.contains("football") || normalized.contains("nfl") { return .football }
        if normalized.contains("baseball") || normalized.contains("mlb") { return .baseball }
        if normalized.contains("hockey") || normalized.contains("nhl") { return .hockey }
        return nil
    }
}

private struct TeamScheduleCacheEntry {
    let fetchedAt: Date
    let results: [LiveMatch]
}

private enum CalendarSearchResultItem: Identifiable {
    case venue(SportsEvent)
    case pickup(SportsEvent)
    case pro(LiveMatch)

    var id: String {
        switch self {
        case .venue(let event):
            return "venue-\(event.id.uuidString.lowercased())"
        case .pickup(let event):
            return "pickup-\(event.id.uuidString.lowercased())"
        case .pro(let match):
            return "pro-\(match.id)"
        }
    }

    var date: Date {
        switch self {
        case .venue(let event), .pickup(let event):
            return event.date
        case .pro(let match):
            return match.startTime
        }
    }

    var sortTitle: String {
        switch self {
        case .venue(let event), .pickup(let event):
            return event.title
        case .pro(let match):
            return "\(match.awayTeam) \(match.homeTeam)"
        }
    }
}

private struct CalendarSearchDateGroup: Identifiable {
    let date: Date
    let items: [CalendarSearchResultItem]

    var id: String {
        String(Int(date.timeIntervalSince1970))
    }
}

private struct CalendarSearchIndexEntry {
    let item: CalendarSearchResultItem
    let searchableText: String
    let suggestions: [CalendarSearchSuggestionCandidate]
}

private struct CalendarSearchSuggestionCandidate {
    let title: String
    let subtitle: String?
    let kind: CalendarSearchSuggestionKind
    let rank: Int
    let searchableText: String
}

private enum CalendarSearchSuggestionKind: String, Equatable {
    case team
    case competition
    case game

    var systemImage: String {
        switch self {
        case .team:
            return "person.2.fill"
        case .competition:
            return "trophy.fill"
        case .game:
            return "calendar.badge.clock"
        }
    }

    var tint: Color {
        switch self {
        case .team:
            return FGColor.accentBlue
        case .competition:
            return FGColor.accentGreen
        case .game:
            return Color.orange
        }
    }
}

private struct CalendarSearchSuggestion: Identifiable {
    let title: String
    let subtitle: String?
    let kind: CalendarSearchSuggestionKind
    let rank: Int

    var id: String {
        "\(kind.rawValue)-\(LiveMatchFilters.normalizedSearchText(title))"
    }
}

private struct CalendarLeagueCountryFilterSheet: View {
    let countries: [String]
    @Binding var selectedCountries: Set<String>

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let northAmericaPreset = ["United States", "Canada", "Mexico"]
    private let topEuropePreset = ["England", "France", "Spain", "Germany", "Italy"]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Calendar Countries")
                            .font(FGTypography.sectionTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text("Choose which league countries appear in Pro Games.")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    .padding(.vertical, 4)
                }

                Section("Quick Actions") {
                    quickAction("Select All") {
                        selectedCountries = Set(countries)
                    }
                    quickAction("Clear") {
                        selectedCountries = []
                    }
                    quickAction("North America") {
                        selectedCountries = Set(northAmericaPreset)
                    }
                    quickAction("Top European") {
                        selectedCountries = Set(topEuropePreset)
                    }
                }

                Section("Countries") {
                    ForEach(countries, id: \.self) { country in
                        Button {
                            toggle(country)
                        } label: {
                            HStack(spacing: 12) {
                                Text(country)
                                    .font(FGTypography.body)
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                Spacer()
                                if selectedCountries.contains(country) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(FGColor.accentGreen)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Calendar Countries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func quickAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(FGTypography.body.weight(.semibold))
        }
    }

    private func toggle(_ country: String) {
        if selectedCountries.contains(country) {
            selectedCountries.remove(country)
        } else {
            selectedCountries.insert(country)
        }
    }
}
