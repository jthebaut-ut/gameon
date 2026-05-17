import SwiftUI

private enum LiveRefreshSource {
    case auto
    case manual

    var displayText: String {
        switch self {
        case .auto:
            return "Auto"
        case .manual:
            return "Manual refresh"
        }
    }
}

struct CalendarScreen: View {
    /// Minimum height for the scrollable events region so empty vs populated lists do not resize the header stack.
    private static let eventsListMinHeight: CGFloat = 320
    private static let liveAutoRefreshIntervalNanoseconds: UInt64 = 15_000_000_000

    @ObservedObject var viewModel: MapViewModel
    @Binding var selectedTab: MainTabView.AppTab
    @Environment(\.colorScheme) private var calendarColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDatePicker = false
    @State private var showCalendarSportMoreSheet = false
    @State private var calendarDatePickerDetent: PresentationDetent = .large
    @State private var gameSearchText = ""
    @State private var calendarPickupDetailToken: PickupDetailNavigationToken?
    @State private var liveIndicatorPulse = false
    @State private var liveRefreshRotation: Double = 0
    @State private var liveAutoRefreshTask: Task<Void, Never>?
    @State private var isLiveAutoRefreshActive = false
    @State private var liveAutoRefreshPulse = false
    @State private var liveLastRefreshDate = Date()
    @State private var liveRefreshSource: LiveRefreshSource = .auto
    @FocusState private var isGameSearchFocused: Bool

    private var displayedEvents: [SportsEvent] {
        viewModel.calendarScreenDisplayedEvents(
            selectedDate: viewModel.calendarTabSelectedDate,
            searchQuery: gameSearchText,
            filter: viewModel.calendarTabGameFilter
        )
    }

    private var displayedLiveMatches: [LiveMatch] {
        viewModel.calendarLiveMatchesDisplayed(
            searchQuery: gameSearchText
        )
    }

    private var isLiveMode: Bool {
        viewModel.calendarTabGameFilter == .live
    }

    private var shouldAutoRefreshLiveMatches: Bool {
        selectedTab == .calendar && isLiveMode && scenePhase == .active
    }

    private var liveRefreshStatusText: String {
        "Updated \(formattedLiveRefreshDate(liveLastRefreshDate)) • \(liveRefreshSource.displayText)"
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

                if !isLiveMode {
                    dateButton
                }

                gameSearchBar

                if !isLiveMode {
                    sportFilterBar
                }

                eventsHeader

                eventsList
            }
            .padding(.top, 18)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissCalendarSearchKeyboard()
            }
        )
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    dismissCalendarSearchKeyboard()
                }
            }
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
            updateLiveAutoRefreshForCurrentState(immediatelyRefresh: true)
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
            updateLiveAutoRefreshForCurrentState(immediatelyRefresh: true)
            guard viewModel.canFanUsePickupGamesUI else { return }
            Task {
                await viewModel.refreshCalendarTabPickupSources()
            }
        }
        .onDisappear {
            stopLiveAutoRefresh()
        }
        .onChange(of: selectedTab) { _, _ in
            updateLiveAutoRefreshForCurrentState(immediatelyRefresh: true)
        }
        .onChange(of: scenePhase) { _, phase in
            updateLiveAutoRefreshForCurrentState(immediatelyRefresh: phase == .active)
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
        let track = RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.primary.opacity(calendarColorScheme == .dark ? 0.14 : 0.07))
        return HStack(spacing: 0) {
            ForEach(CalendarTabGameFilter.allCases) { filter in
                Button {
                    viewModel.calendarTabGameFilter = filter
                } label: {
                    Text(filter.segmentTitle)
                        .font(.subheadline.weight(viewModel.calendarTabGameFilter == filter ? .semibold : .medium))
                        .foregroundStyle(viewModel.calendarTabGameFilter == filter ? Color.white : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                        .background {
                            if viewModel.calendarTabGameFilter == filter {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(calendarFilterSelectedColor(filter).opacity(calendarColorScheme == .dark ? 0.72 : 0.92))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(filter.segmentTitle)
            }
        }
        .padding(3)
        .background(track)
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(calendarColorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
        }
        .padding(.horizontal)
    }

    private func calendarFilterSelectedColor(_ filter: CalendarTabGameFilter) -> Color {
        switch filter {
        case .live:
            return .red
        case .venueGames, .pickupGames:
            return Color.accentColor
        }
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
            VStack(alignment: .leading, spacing: isLiveMode ? 3 : 0) {
                HStack(spacing: 8) {
                    Text(eventsHeaderTitle)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)

                    if isLiveMode && isLiveAutoRefreshActive {
                        liveAutoRefreshIndicator
                    }
                }

                if isLiveMode {
                    Text(liveRefreshStatusText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel(liveRefreshStatusText)
                }
            }

            Spacer()

            if isLiveMode {
                liveRefreshButton
            } else if viewModel.isLoadingEvents {
                ProgressView()
            } else if viewModel.isRefreshingDiscoverEvents && !displayedEvents.isEmpty {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal)
    }

    private var liveRefreshButton: some View {
        Button {
            manuallyRefreshLiveMatches()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(viewModel.isLoadingLiveMatches ? .secondary : Color.red)
                .rotationEffect(.degrees(liveRefreshRotation))
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.red.opacity(calendarColorScheme == .dark ? 0.32 : 0.18), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoadingLiveMatches)
        .accessibilityLabel("Refresh live games")
        .onAppear {
            guard viewModel.isLoadingLiveMatches else { return }
            startLiveRefreshSpin()
        }
        .onChange(of: viewModel.isLoadingLiveMatches) { _, isLoading in
            if isLoading {
                startLiveRefreshSpin()
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    liveRefreshRotation = 0
                }
            }
        }
    }

    private var liveAutoRefreshIndicator: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 8, height: 8)
            .scaleEffect(viewModel.isLoadingLiveMatches && liveAutoRefreshPulse ? 1.45 : 1.0)
            .opacity(viewModel.isLoadingLiveMatches && liveAutoRefreshPulse ? 0.55 : 1.0)
            .shadow(color: Color.green.opacity(viewModel.isLoadingLiveMatches ? 0.28 : 0), radius: 4)
            .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: liveAutoRefreshPulse)
            .animation(.easeOut(duration: 0.18), value: viewModel.isLoadingLiveMatches)
            .accessibilityLabel("Live games updating")
    }

    private func startLiveRefreshSpin() {
        withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
            liveRefreshRotation += 360
        }
    }

    private func manuallyRefreshLiveMatches() {
        recordLiveRefresh(source: .manual)
        viewModel.refreshLiveMatchesForCalendar(forceRefresh: true)
        updateLiveAutoRefreshForCurrentState(immediatelyRefresh: false)
    }

    private func updateLiveAutoRefreshForCurrentState(immediatelyRefresh: Bool) {
        if shouldAutoRefreshLiveMatches {
            startLiveAutoRefresh(immediatelyRefresh: immediatelyRefresh)
        } else {
            stopLiveAutoRefresh()
        }
    }

    private func startLiveAutoRefresh(immediatelyRefresh: Bool) {
        if liveAutoRefreshTask != nil {
            if immediatelyRefresh {
                return
            }
            stopLiveAutoRefresh()
        }

        isLiveAutoRefreshActive = true
        liveAutoRefreshPulse = true

        if immediatelyRefresh {
            logLiveAutoRefresh(reason: "immediate")
            recordLiveRefresh(source: .auto)
            viewModel.refreshLiveMatchesForCalendar(forceRefresh: true)
        }

        liveAutoRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.liveAutoRefreshIntervalNanoseconds)
                } catch {
                    break
                }

                guard !Task.isCancelled else { break }
                guard shouldAutoRefreshLiveMatches else {
                    stopLiveAutoRefresh()
                    break
                }
                guard !viewModel.isLoadingLiveMatches else { continue }

                logLiveAutoRefresh(reason: "scheduled")
                recordLiveRefresh(source: .auto)
                viewModel.refreshLiveMatchesForCalendar(forceRefresh: true)
            }
        }
    }

    private func stopLiveAutoRefresh() {
        liveAutoRefreshTask?.cancel()
        liveAutoRefreshTask = nil
        isLiveAutoRefreshActive = false
        liveAutoRefreshPulse = false
    }

    private var eventsHeaderTitle: String {
        if isLiveMode { return "Live Games" }
        switch viewModel.calendarTabGameFilter {
        case .venueGames:
            return "Venue Games"
        case .pickupGames:
            return "Pickup Games"
        case .live:
            return "Live Games"
        }
    }

    private func recordLiveRefresh(source: LiveRefreshSource) {
        let timestamp = Date()
        liveLastRefreshDate = timestamp
        liveRefreshSource = source
#if DEBUG
        print("[LiveRefreshTimestamp] \(timestamp.formatted(date: .omitted, time: .standard))")
        print("[LiveRefreshSource] \(source.displayText)")
#endif
    }

    private func logLiveAutoRefresh(reason: String) {
#if DEBUG
        print("[LiveAutoRefresh] reason=\(reason)")
#endif
    }

    private func formattedLiveRefreshDate(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 {
            return "just now"
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var gameSearchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search game, team, league, or sport", text: $gameSearchText)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($isGameSearchFocused)
                .onSubmit {
                    dismissCalendarSearchKeyboard()
                }

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

    private func dismissCalendarSearchKeyboard() {
        guard isGameSearchFocused else { return }
        isGameSearchFocused = false
    }

    private var eventsList: some View {
        Group {
            if isLiveMode {
                liveMatchesList
            } else if !calendarTabSelectedDayIsTodayOrFuture {
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

    private var liveMatchesList: some View {
        ScrollView {
            Group {
                if displayedLiveMatches.isEmpty {
                    calendarEmptyState("No live games right now")
                } else {
                    VStack(spacing: 12) {
                        ForEach(displayedLiveMatches) { match in
                            liveMatchCard(match)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: Self.eventsListMinHeight, alignment: .top)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 100)
        }
        .refreshable {
            await MainActor.run {
                manuallyRefreshLiveMatches()
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

    private func liveMatchCard(_ match: LiveMatch) -> some View {
        let sportType = match.liveSportVisualType
        let accent = liveSportAccent(sportType)
        let artworkSportKey = sportType.artworkSportKey
        return HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(calendarColorScheme == .dark ? 0.24 : 0.13))
                SportArtworkIconView(sport: artworkSportKey, diameter: 48)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    liveStatusPill(match, accent: accent)

                    Text(sportType.displayLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(accent.opacity(calendarColorScheme == .dark ? 0.18 : 0.10))
                        )

                    Text(match.league)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    liveTeamScoreLine(team: match.awayTeam, score: match.scoreAway)
                    liveTeamScoreLine(team: match.homeTeam, score: match.scoreHome)
                }

                Text("\(sportType.displayLabel) • Started \(match.startTime.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(accent.opacity(calendarColorScheme == .dark ? 0.46 : 0.28), lineWidth: 1)
        )
        .onAppear {
#if DEBUG
            let visual = SportFilterCatalog.resolve(artworkSportKey)
            print("[LiveSportIconMapping] id=\(match.id) normalized=\(match.sport) artworkKey=\(artworkSportKey) systemImage=\(visual.systemImage) label=\(sportType.displayLabel)")
            print("[LiveSportDetected] id=\(match.id) presentationType=\(sportType.rawValue) accent=\(accent)")
#endif
        }
    }

    private func liveStatusPill(_ match: LiveMatch, accent: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.white)
                .frame(width: 5, height: 5)
                .scaleEffect(match.matchStatus.isHappeningNow && liveIndicatorPulse ? 1.45 : 0.9)
                .opacity(match.matchStatus.isHappeningNow && liveIndicatorPulse ? 0.45 : 1.0)
                .animation(
                    match.matchStatus.isHappeningNow
                        ? .easeInOut(duration: 0.95).repeatForever(autoreverses: true)
                        : .default,
                    value: liveIndicatorPulse
                )

            Text(liveStatusText(match))
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(accent))
        .accessibilityLabel(liveStatusText(match))
        .onAppear {
            guard match.matchStatus.isHappeningNow else { return }
            liveIndicatorPulse = true
        }
    }

    private func liveSportAccent(_ sportType: LiveSportVisualType) -> Color {
        switch sportType {
        case .soccer:
            return Color(red: 0.05, green: 0.55, blue: 0.28)
        case .basketball:
            return Color(red: 0.95, green: 0.45, blue: 0.12)
        case .hockey:
            return Color(red: 0.12, green: 0.45, blue: 0.92)
        case .baseball:
            return Color(red: 0.85, green: 0.15, blue: 0.18)
        case .nfl:
            return Color(red: 0.45, green: 0.32, blue: 0.18)
        case .tennis:
            return Color(red: 0.78, green: 0.68, blue: 0.06)
        case .golf:
            return Color(red: 0.18, green: 0.62, blue: 0.32)
        case .formula1:
            return Color(red: 0.92, green: 0.2, blue: 0.22)
        case .other:
            return Color.accentColor
        }
    }

    private func liveStatusText(_ match: LiveMatch) -> String {
        if match.matchStatus == .halfTime {
            return "HT"
        }
        if let minute = match.minute {
            return "LIVE \(minute)'"
        }
        return "LIVE"
    }

    private func liveTeamScoreLine(team: String, score: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(team)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(score)")
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(.primary)
        }
    }

    private func venueEventSubtitle(_ event: SportsEvent) -> String {
        "\(event.league) • \(event.sport) • \(viewModel.displayTime(for: event))"
    }
}
