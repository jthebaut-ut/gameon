import SwiftUI

struct CalendarScreen: View {
    /// Minimum height for the scrollable events region so empty vs populated lists do not resize the header stack.
    private static let eventsListMinHeight: CGFloat = 320

    @ObservedObject var viewModel: MapViewModel
    @Binding var selectedTab: MainTabView.AppTab
    @Environment(\.colorScheme) private var calendarColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDatePicker = false
    @State private var showCalendarSportMoreSheet = false
    @State private var calendarDatePickerDetent: PresentationDetent = .large
    @State private var gameSearchText = ""
    @State private var calendarPickupDetailToken: PickupDetailNavigationToken?

    private let calendarVisibleGameFilters: [CalendarTabGameFilter] = [.venueGames, .pickupGames]

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
            normalizeCalendarGameFilter()
        }
        .sheet(isPresented: $showCalendarSportMoreSheet) {
            DiscoverSportFilterMoreSheet(selectedSport: viewModel.selectedSport) { sport in
                showCalendarSportMoreSheet = false
                withAnimation(.spring()) {
                    viewModel.sportChanged(to: sport)
                }
            }
        }
        .onAppear {
            normalizeCalendarGameFilter()
            guard viewModel.canFanUsePickupGamesUI else { return }
            Task {
                await viewModel.refreshCalendarTabPickupSources()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            guard viewModel.canFanUsePickupGamesUI else { return }
            Task {
                await viewModel.refreshCalendarTabPickupSources()
            }
        }
        .onChange(of: viewModel.calendarTabSelectedDate) { _, _ in
            guard viewModel.canFanUsePickupGamesUI else { return }
            Task {
                await viewModel.refreshCalendarTabPickupSources()
            }
        }
        .sheet(item: $calendarPickupDetailToken) { token in
            DiscoverPickupGameDetailSheet(viewModel: viewModel, gameId: token.id)
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
        GameOnSegmentedControl(
            tabs: calendarVisibleGameFilters.map { filter in
                GameOnSegmentedTab(
                    id: filter,
                    title: filter.segmentTitle,
                    tint: FGColor.accentGreen,
                    accessibilityLabel: "Show \(filter.segmentTitle)"
                )
            },
            selection: $viewModel.calendarTabGameFilter
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

            if viewModel.isLoadingEvents {
                ProgressView()
            } else if viewModel.isRefreshingDiscoverEvents && !displayedEvents.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal)
    }

    private var eventsHeaderTitle: String {
        switch viewModel.calendarTabGameFilter {
        case .venueGames:
            return "Venue Games"
        case .pickupGames:
            return "Pickup Games"
        case .live:
            return "Venue Games"
        }
    }

    private func normalizeCalendarGameFilter() {
        guard viewModel.calendarTabGameFilter == .live else { return }
        viewModel.calendarTabGameFilter = .venueGames
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
            pickupCalendarEventCard(event)
        } else {
            venueCalendarEventCard(event)
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
            [row.skillLevelEnum.displayTitle, row.playEnvironmentEnum.shortLabel, row.entryFeeDisplayLine]
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
