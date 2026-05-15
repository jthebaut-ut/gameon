import SwiftUI

struct CalendarScreen: View {
    /// Minimum height for the scrollable events region so empty vs populated lists do not resize the header stack.
    private static let eventsListMinHeight: CGFloat = 320

    @ObservedObject var viewModel: MapViewModel
    @Binding var selectedTab: MainTabView.AppTab
    @Environment(\.colorScheme) private var calendarColorScheme
    @State private var showDatePicker = false
    @State private var showCalendarSportMoreSheet = false
    @State private var calendarDatePickerDetent: PresentationDetent = .large
    @State private var gameSearchText = ""

    private var displayedEvents: [SportsEvent] {
        viewModel.calendarScreenDisplayedEvents(
            selectedDate: viewModel.calendarTabSelectedDate,
            searchQuery: gameSearchText,
            filter: viewModel.calendarTabGameFilter
        )
    }

    private var calendarTabSelectedDayIsTodayOrFuture: Bool {
        let cal = Calendar.current
        return cal.startOfDay(for: viewModel.calendarTabSelectedDate) >= cal.startOfDay(for: Date())
    }

    /// Same business-session gate as ``FollowingScreen`` (`hasAuthenticatedVenueOwnerSession`).
    private var businessCalendarLockedContent: some View {
        ZStack {
            Color.clear
                .fanGeoScreenBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                VStack(spacing: 18) {
                    Image(systemName: "calendar")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(FGColor.accentBlue)

                    Text("Business accounts can't use Calendar")
                        .font(FGTypography.screenTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(FGColor.primaryText(calendarColorScheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Calendar is a fan-only feature. Sign in with a regular FanGeo account to view venue games, pickup games, and saved plans.")
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(calendarColorScheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, FGSpacing.xxl)
                .padding(.horizontal, FGSpacing.xxl)
                .frame(maxWidth: 420)
                .background(
                    RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                        .fill(FGColor.cardBackground(calendarColorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                        .strokeBorder(FGColor.divider(calendarColorScheme), lineWidth: 1)
                )
                .shadow(color: .black.opacity(calendarColorScheme == .dark ? 0.35 : 0.08), radius: 24, y: 14)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, FGSpacing.lg)
            .padding(.bottom, 110)
        }
        .onAppear {
            viewModel.logBusinessUserGateBlocked(action: "calendarTab")
        }
    }

    var body: some View {
        Group {
            if viewModel.hasAuthenticatedVenueOwnerSession {
                businessCalendarLockedContent
            } else {
                fanCalendarRoot
            }
        }
    }

    private var fanCalendarRoot: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                header

                gameTypeFilter

                dateButton

                gameSearchBar

                sportFilterBar

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
                        viewModel.loadCalendarTabCalendarDotsAroundMonth(
                            viewModel.calendarTabSelectedDate,
                            reason: "calendar_tab_sheet_done"
                        )
                        viewModel.loadGamesFromSupabase()
                        Task {
                            await viewModel.refreshPickupGamesForDiscoverMap()
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
            viewModel.calendarEventsListCache.removeAll()
            viewModel.recomputeCalendarDotDates()
            viewModel.loadCalendarTabCalendarDotsAroundMonth(
                viewModel.calendarTabSelectedDate,
                reason: "calendar_tab_region_mode_change"
            )
        }
        .onChange(of: viewModel.selectedSport) { _, _ in
            viewModel.calendarEventsListCache.removeAll()
            viewModel.recomputeCalendarDotDates()
            viewModel.loadCalendarTabCalendarDotsAroundMonth(
                viewModel.calendarTabSelectedDate,
                reason: "calendar_tab_sport_change"
            )
        }
        .onChange(of: viewModel.calendarTabGameFilter) { _, _ in
            viewModel.calendarEventsListCache.removeAll()
            viewModel.loadCalendarTabCalendarDotsAroundMonth(
                viewModel.calendarTabSelectedDate,
                reason: "calendar_tab_filter_change"
            )
        }
        .sheet(isPresented: $showCalendarSportMoreSheet) {
            DiscoverSportFilterMoreSheet(selectedSport: viewModel.selectedSport) { sport in
                showCalendarSportMoreSheet = false
                withAnimation(.spring()) {
                    viewModel.sportChanged(to: sport)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Calendar")
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
        Picker("Game type", selection: $viewModel.calendarTabGameFilter) {
            ForEach(CalendarTabGameFilter.allCases) { filter in
                Text(filter.segmentTitle)
                    .tag(filter)
            }
        }
        .pickerStyle(.segmented)
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
            Text("Events")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.primary)

            Spacer()

            if viewModel.isLoadingEvents {
                ProgressView()
            } else if viewModel.isRefreshingDiscoverEvents && !displayedEvents.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal)
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
                        if displayedEvents.isEmpty {
                            Text("No events found for this date or search.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .center)
                        } else {
                            VStack(spacing: 12) {
                                ForEach(displayedEvents) { event in
                                    Button {
                                        handleEventTap(event)
                                    } label: {
                                        eventRow(event)
                                    }
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

    private var sportFilterBar: some View {
        ScalableSportFilterChipRow(
            viewModel: viewModel,
            showMoreSheet: $showCalendarSportMoreSheet,
            rowSpacing: 10,
            isCompact: true
        )
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
            if let row = viewModel.pickupGamesForDiscoverMap.first(where: { $0.id == event.id }) {
                viewModel.selectPickupGameOnMap(row)
            } else {
                viewModel.clearPickupMapSelection()
            }
        } else {
            viewModel.selectEvent(event)
        }
        selectedTab = .discover
    }

    private func eventRow(_ event: SportsEvent) -> some View {
        HStack(spacing: 14) {
            SportArtworkIconView(sport: event.sport, diameter: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                Text(eventSubtitle(event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func eventSubtitle(_ event: SportsEvent) -> String {
        if event.league == MapViewModel.calendarTabPickupLeagueMarker {
            return "\(event.sport) • Pickup • \(event.time)"
        }
        return "\(event.league) • \(event.sport) • \(viewModel.displayTime(for: event))"
    }
}
