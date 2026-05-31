import SwiftUI

struct CalendarScreen: View {
    /// Minimum height for the scrollable events region so empty vs populated lists do not resize the header stack.
    private static let eventsListMinHeight: CGFloat = 320

    @ObservedObject var viewModel: MapViewModel
    @Binding var selectedTab: MainTabView.AppTab
    /// False while Calendar is preserved off-screen (defers tab-only pickup refresh at launch).
    var isCalendarTabSelected: Bool = false
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage(LiveLeagueCountryFilterPreference.appStorageKey) private var calendarLeagueCountryFilterRaw: String = ""
    @Environment(\.colorScheme) private var calendarColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDatePicker = false
    @State private var showCalendarSportMoreSheet = false
    @State private var showCalendarLeagueCountryFilterSheet = false
    @State private var calendarDatePickerDetent: PresentationDetent = .large
    @State private var gameSearchText = ""
    @State private var calendarProGamesSportFilter = "All"
    @State private var calendarFeaturedEventFilterSlug: String?
    @State private var calendarPickupDetailToken: PickupDetailNavigationToken?

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
        viewModel.calendarScreenDisplayedEvents(
            selectedDate: viewModel.calendarTabSelectedDate,
            searchQuery: gameSearchText,
            filter: effectiveCalendarGameFilter
        )
    }

    private var displayedProMatches: [LiveMatch] {
        viewModel.calendarProGamesDisplayed(
            selectedDate: viewModel.calendarTabSelectedDate,
            searchQuery: gameSearchText,
            sportFilter: calendarProGamesSportFilter,
            worldCupOnly: false,
            selectedLeagueCountries: selectedCalendarFeaturedEvent == nil ? selectedCalendarLeagueCountries : [],
            featuredEvent: selectedCalendarFeaturedEvent
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

    private var calendarTabSelectedDayIsTodayOrFuture: Bool {
        let cal = Calendar.current
        return cal.startOfDay(for: viewModel.calendarTabSelectedDate) >= cal.startOfDay(for: Date())
    }

    var body: some View {
        fanCalendarRoot
    }

    private var fanCalendarRoot: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                header

                gameTypeFilter

                dateButton

                gameSearchBar

                calendarSecondaryFilterBar

                eventsHeader

                eventsList
            }
            .padding(.top, 18)
        }
        .sheet(isPresented: $showDatePicker) {
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
                onDone: {
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
                },
                onDisplayedMonthChange: { month in
                    Task { @MainActor in
                        viewModel.loadCalendarTabCalendarDotsAroundMonth(month, reason: "calendar_tab_month_change")
                    }
                }
            )
            .liquidGlassCalendarSheetPresentation(selection: $calendarDatePickerDetent, backdrop: .frostedDim)
        }
        .onChange(of: showDatePicker) { _, isPresented in
            if isPresented {
                calendarDatePickerDetent = .large
            }
        }
        .onChange(of: viewModel.calendarUsesVisibleMapRegionOnly) { _, _ in
            guard isCalendarTabSelected else { return }
            viewModel.calendarEventsListCache.removeAll()
            viewModel.recomputeCalendarDotDates(force: true)
            viewModel.loadCalendarTabCalendarDotsAroundMonth(
                viewModel.calendarTabSelectedDate,
                reason: "calendar_tab_region_mode_change"
            )
        }
        .onChange(of: viewModel.selectedSport) { _, _ in
            guard isCalendarTabSelected else { return }
            viewModel.calendarEventsListCache.removeAll()
            viewModel.recomputeCalendarDotDates(force: true)
            viewModel.loadCalendarTabCalendarDotsAroundMonth(
                viewModel.calendarTabSelectedDate,
                reason: "calendar_tab_sport_change"
            )
        }
        .onChange(of: viewModel.calendarTabGameFilter) { _, _ in
            guard isCalendarTabSelected else { return }
            sanitizeBusinessCalendarFilterIfNeeded()
            viewModel.calendarEventsListCache.removeAll()
            viewModel.loadCalendarTabCalendarDotsAroundMonth(
                viewModel.calendarTabSelectedDate,
                reason: "calendar_tab_filter_change"
            )
            refreshCalendarProGamesIfNeeded(reason: "calendar_tab_filter_change")
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
        .onAppear {
            sanitizeBusinessCalendarFilterIfNeeded()
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
        .onChange(of: isCalendarTabSelected) { _, active in
            guard active else { return }
            sanitizeBusinessCalendarFilterIfNeeded()
            refreshCalendarProGamesIfNeeded(reason: "calendar_tab_selected")
            guard viewModel.canFanUsePickupGamesUI else { return }
            Task {
                await viewModel.refreshCalendarTabPickupSources()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            guard isCalendarTabSelected else { return }
            sanitizeBusinessCalendarFilterIfNeeded()
            refreshCalendarProGamesIfNeeded(reason: "calendar_scene_active")
            guard viewModel.canFanUsePickupGamesUI else { return }
            Task {
                await viewModel.refreshCalendarTabPickupSources()
            }
        }
        .onChange(of: viewModel.calendarTabSelectedDate) { _, _ in
            guard isCalendarTabSelected else { return }
            sanitizeBusinessCalendarFilterIfNeeded()
            refreshCalendarProGamesIfNeeded(reason: "calendar_selected_date_change")
            guard viewModel.canFanUsePickupGamesUI else { return }
            Task {
                await viewModel.refreshCalendarTabPickupSources()
            }
        }
        .onChange(of: isBusinessCalendarAccess) { _, _ in
            sanitizeBusinessCalendarFilterIfNeeded()
        }
        .sheet(item: $calendarPickupDetailToken) { token in
            DiscoverPickupGameDetailSheet(viewModel: viewModel, gameId: token.id)
        }
    }

    private func sanitizeBusinessCalendarFilterIfNeeded() {
        guard isBusinessCalendarAccess, viewModel.calendarTabGameFilter == .pickupGames else { return }
        viewModel.calendarTabGameFilter = .venueGames
        viewModel.calendarEventsListCache.removeAll()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("calendar", languageCode: appLanguageRaw))
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(.primary)

            Text("Choose a date, then find where to watch.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var gameTypeFilter: some View {
        GameOnSegmentedControl(
            tabs: calendarVisibleGameFilters.map { filter in
                GameOnSegmentedTab(
                    id: filter,
                    title: filter.segmentTitle,
                    tint: FGColor.accentGreen,
                    accessibilityLabel: "Show \(filter.segmentTitle)"
                )
            },
            selection: calendarGameFilterBinding
        )
        .padding(.horizontal)
    }

    private var dateButton: some View {
        Button {
            showDatePicker = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Selected date")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(viewModel.formattedCalendarTabSelectedDate)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                }

                Spacer()

                Image(systemName: "calendar")
                    .font(.title3)
                    .foregroundStyle(Color.white)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor)
                    .clipShape(Circle())
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .padding(.horizontal)
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
        switch effectiveCalendarGameFilter {
        case .venueGames:
            return "Venue Games"
        case .pickupGames:
            return "Community Games"
        case .proGames:
            return "Pro Games"
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
            return "No matches found for this featured event."
        }
        if calendarLeagueCountryFilterIsActive {
            return "No pro games for selected countries on this date."
        }
        return "No pro games found for this date or search."
    }

    private func updateSelectedCalendarLeagueCountries(_ countries: Set<String>) {
        calendarLeagueCountryFilterRaw = LiveLeagueCountryFilterPreference.encode(countries)
    }

    private var gameSearchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search game, team, league, or sport", text: $gameSearchText)
                .textInputAutocapitalization(.words)

            if !gameSearchText.isEmpty {
                Button {
                    gameSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal)
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
                            calendarEmptyState("No events found for this date or search.")
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

    private func calendarEmptyState(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding()
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
        VStack(alignment: .leading, spacing: 10) {
            proGamesSportFilterBar
            proGamesWorldCupFilterBar
        }
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
            .padding(.horizontal, 4)
        }
        .padding(.horizontal)
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
        return HStack(alignment: .top, spacing: 14) {
            ProGameSportBadgeView(
                sportType: match.liveSportVisualType,
                diameter: 56,
                featuredEvent: featuredEvent,
                featuredEventSlug: match.featuredEventSlug
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(calendarProGameStatusText(match))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(accent.opacity(calendarColorScheme == .dark ? 0.18 : 0.10))
                        )

                    if let featuredEvent {
                        calendarFeaturedEventBadge(featuredEvent, accent: accent)
                    }

                    Text("\(AppSportCatalog.displayLabel(forSportToken: match.sport)) • \(match.league)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(calendarProGameTitle(match))
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                Text(calendarProGameStartTimeText(match))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if match.matchStatus.isHappeningNow || match.matchStatus == .fullTime {
                    Text("\(match.awayTeam) \(match.scoreAway) · \(match.homeTeam) \(match.scoreHome)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            calendarProGameSaveButton(match, isSaved: isSaved, accent: accent)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
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
        let organizerRaw = pickupRow.flatMap { viewModel.pickupCreatorDisplayLabel(for: $0.creator_user_id) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let organizerLine = organizerRaw.isEmpty ? "Organizer" : "Organizer: \(organizerRaw)"
        let spotsLine = pickupRow.flatMap { viewModel.pickupGameCalendarSpotsLine($0) }
        let capacityMeta = pickupCalendarCapacityPillText(for: pickupRow)
        let rosterState = pickupRow.map { $0.isPickupFullForDiscover ? "full" : "open" } ?? "unknown"
        let metaLine: String? = pickupRow.map { row in
            [row.skillLevelEnum.displayTitle, row.playEnvironmentEnum.shortLabel, row.participantAudienceDisplayTitle, row.entryFeeDisplayLine]
                .joined(separator: " · ")
        }

        return Button {
            if viewModel.isGuestDiscoverMode {
                viewModel.discoverNavigateToAccountForUserAuth = true
                return
            }
            calendarPickupDetailToken = PickupDetailNavigationToken(id: event.id)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                PickupGameStartedSportGlyphFrame(showStarted: pickupStarted) {
                    SportArtworkIconView(sport: event.sport, diameter: 56)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(event.title)
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)

                        Text(capacityMeta)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(calendarColorScheme == .dark ? 0.14 : 0.08))
                            )
                            .accessibilityLabel(capacityMeta == "Full" ? "Roster full" : "Spots available")
                    }

                    if let row = pickupRow {
                        Text(viewModel.pickupGameCalendarDateTimeLine(row))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !addressLine.isEmpty {
                            Text(addressLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Text(organizerLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let spots = spotsLine {
                            Text(spots)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                        }

                        if let metaLine, !metaLine.isEmpty {
                            Text(metaLine)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
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

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(calendarColorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
            )
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

        return Button {
            handleEventTap(event)
        } label: {
            HStack(spacing: 14) {
                PickupGameStartedSportGlyphFrame(showStarted: false) {
                    SportArtworkIconView(sport: event.sport, diameter: 56)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)

                    Text(venueEventSubtitle(event))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let venueBizEmail {
                        VenueGameBusinessContactEmailRow(email: venueBizEmail)
                            .padding(.top, 2)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .onAppear {
            if isVenueEvent, let b = venueBar {
                VenueGameBusinessEmail.logDebug(bar: b)
            }
        }
    }

    private func venueEventSubtitle(_ event: SportsEvent) -> String {
        "\(event.league) • \(event.sport) • \(viewModel.displayTime(for: event))"
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
