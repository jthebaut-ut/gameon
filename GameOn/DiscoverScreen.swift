import CoreLocation
import SwiftUI
import MapKit

/// Primary map experience: search, date strip, clustered annotations, venue preview, and sheets for detail, comments, and vibes.
struct DiscoverScreen: View {

    @ObservedObject var viewModel: MapViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isSearchFocused: Bool
    @State private var showVenueDetails = false
    @State private var showDatePicker = false
    @State private var discoverDatePickerSelection: Date?
    @State private var selectedCommentsEventID: UUID?
    @State private var showVenueRatingSheet = false
    @State private var mapVenueReloadTask: Task<Void, Never>?
    @State private var lastMapVenueReloadRegion: MKCoordinateRegion?
    /// Multi-venue map cluster: sheet lists venues after tap (zoom runs first).
    @State private var clusterForSheet: VenueCluster?
    /// After opening Account from the Discover gate, restore this venue once fan login succeeds.
    @State private var pendingResumeVenueIDAfterLogin: UUID?
    /// Per-venue preview: local filter for the game list (does not change global map filters).
    @State private var venuePreviewGameFilter: VenuePreviewGameFilter = .all
    /// Bumps when returning to foreground so map user-dot visibility refreshes after Settings changes.
    @State private var discoverMapLocationAuthVersion = 0
    @State private var discoverLocationHint: String?
    @State private var showMapDisplayModePopup = false
    @State private var discoverTopAdLoadedSuccessfully = false
    @State private var discoverTopAdLoadFailed = false
    private let livePulseThreshold = 16
    private let discoverBottomOverlayPadding: CGFloat = 104
    private let primaryMapUtilityButtonSize: CGFloat = 38
    private let secondaryMapUtilityButtonSize: CGFloat = 36
    private let mapUtilityStackSpacing: CGFloat = 5
    private let mapUtilityStackVerticalOffset: CGFloat = -5
    private let discoverTopOverlaySpacing: CGFloat = 8
    private let discoverTopControlSpacing: CGFloat = 6
    private let discoverFilterRowSpacing: CGFloat = 6

    private enum VenuePreviewGameFilter: Int, CaseIterable, Identifiable {
        case all
        case imGoing
        case going

        var id: Int { rawValue }

        var segmentTitle: String {
            switch self {
            case .all: return "All"
            case .imGoing: return "I'm Going"
            case .going: return "Going"
            }
        }
    }

    var body: some View {
        ZStack {
            mapLayer

            if showMapDisplayModePopup {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                            showMapDisplayModePopup = false
                        }
                    }
                    .zIndex(1)
            }
            
            VStack(spacing: discoverTopOverlaySpacing) {
                adBanner
                topControlArea
                if let mapHint = viewModel.followingMapNavigationMessage, !mapHint.isEmpty {
                    HStack(alignment: .top, spacing: FGSpacing.sm) {
                        FGStatusPill(title: "Following", kind: .custom(tint: FGColor.accentBlue))
                        Text(mapHint)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fanGeoFloatingStyle()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer()
                
                VStack(alignment: .trailing, spacing: FGSpacing.sm) {
                    if let socialToastText = viewModel.socialActionToastText,
                       !socialToastText.isEmpty {
                        discoverMapToastBanner(
                            text: socialToastText,
                            isError: viewModel.socialActionToastIsError
                        )
                    }
                    if let mapStatusText = viewModel.mapStatusText,
                       !mapStatusText.isEmpty {
                        discoverMapStatusBanner(
                            text: mapStatusText,
                            isLoading: viewModel.isUpdatingMapGames
                        )
                    }
                    if let selectedBar = viewModel.selectedBar {
                        if viewModel.canViewDiscoverDetails() {
                            venuePreviewCard(selectedBar)
                        } else {
                            loggedOutVenueTeaserCard(selectedBar)
                        }
                    } else {
                        nearbySummaryCard
                    }
                }
            }
            .padding(.horizontal, FGSpacing.lg)
            .padding(.top, FGSpacing.lg)
            .padding(.bottom, discoverBottomOverlayPadding)

            if showDatePicker {
                discoverMapDatePickerOverlay
            }

            if showMapDisplayModePopup {
                VStack {
                    HStack {
                        Spacer()
                        discoverMapDisplayModePopup
                    }
                    .padding(.top, 72)
                    .padding(.horizontal, FGSpacing.lg + 2)
                    Spacer()
                }
                .zIndex(2)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
        .task {
            viewModel.reloadVenueUserRatingsFromStorage()
            viewModel.logDiscoverAuthGateDebug()
            await viewModel.ensureBusinessOwnerSessionFlagsIfPossible(context: "discover_enter")
            viewModel.logBusinessOwnerSessionFlags(context: "discover_enter")
        }
        .onAppear {
            Task {
                await viewModel.ensureBusinessOwnerSessionFlagsIfPossible(context: "discover_on_appear")
                viewModel.logBusinessOwnerSessionFlags(context: "discover_on_appear")
            }
        }
    .onChange(of: scenePhase) { _, phase in
        if phase == .active {
            discoverMapLocationAuthVersion += 1
        }
    }
    .onChange(of: viewModel.selectedDate) { _, _ in
        viewModel.pruneSelectionIfNeededAfterFilterChange()
    }
    .onChange(of: viewModel.searchText) { _, _ in
        viewModel.pruneSelectionIfNeededAfterFilterChange()
        viewModel.scheduleDiscoverSearchDebounce()
    }
    .onChange(of: viewModel.calendarUsesVisibleMapRegionOnly) { _, _ in
        viewModel.recomputeCalendarDotDates()
    }
    .onChange(of: viewModel.selectedSport) { _, _ in
        viewModel.recomputeCalendarDotDates()
    }
    .onChange(of: viewModel.mapDisplayMode) { _, _ in
        guard let selectedBar = viewModel.selectedBar else { return }
        let stillVisible = viewModel.mapVisibleBars.contains { $0.id == selectedBar.id }
        if !stillVisible {
            viewModel.clearSelectedEvent()
        }
    }
    .onChange(of: viewModel.pendingFollowingMapVenueID) { _, id in
        guard id != nil else { return }
        Task {
            await viewModel.consumeFollowingVenueNavigationIfPending()
        }
    }
    .onChange(of: viewModel.discoverAuthGateActive) { wasActive, isActive in
        viewModel.logDiscoverAuthGateDebug()
        if !isActive {
            showVenueDetails = false
            showVenueRatingSheet = false
            selectedCommentsEventID = nil
            pendingResumeVenueIDAfterLogin = nil
        } else {
            resumeDiscoverSelectionAfterFanLoginIfNeeded(wasActive: wasActive, isActive: isActive)
        }
    }
    .sheet(isPresented: Binding(
        get: { showVenueDetails && viewModel.canViewDiscoverDetails() && viewModel.selectedBar != nil },
        set: { if !$0 { showVenueDetails = false } }
    )) {
            discoverVenueDetailSheet()
        }
    .sheet(isPresented: Binding(
        get: { viewModel.isAuthenticatedForSocialFeatures && selectedCommentsEventID != nil },
        set: { if !$0 { selectedCommentsEventID = nil } }
    )) {
        if viewModel.isAuthenticatedForSocialFeatures, let eventID = selectedCommentsEventID {
            VenueEventCommentsSheet(
                viewModel: viewModel,
                venueEventID: eventID
            )
        }
    }
        .sheet(isPresented: Binding(
            get: { showVenueRatingSheet && viewModel.isAuthenticatedForSocialFeatures && viewModel.selectedBar != nil },
            set: { if !$0 { showVenueRatingSheet = false } }
        )) {
            if let bar = viewModel.selectedBar {
                VenueUserRatingSheet(viewModel: viewModel, bar: bar)
            }
        }
        .sheet(item: $clusterForSheet) { cluster in
            NavigationStack {
                List {
                    ForEach(cluster.bars.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { bar in
                        Button {
                            clusterForSheet = nil
                            venuePreviewGameFilter = .all
                            withAnimation(.spring()) {
                                viewModel.centerMap(on: bar)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(bar.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(bar.address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .listRowBackground(FGColor.cardBackground(colorScheme))
                    }
                }
                .scrollContentBackground(.hidden)
                .fanGeoScreenBackground()
                .navigationTitle("\(cluster.count) venues")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            clusterForSheet = nil
                        }
                    }
                }
            }
            .fanGeoScreenBackground()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    dismissDiscoverSearchKeyboard()
                }
            }
        }
    }

    /// Discover date chip opens this overlay (not a sheet) so the map stays visible—no UIKit sheet white chrome or Calendar tab behind it.
    private var discoverMapDatePickerOverlay: some View {
        ZStack {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissDiscoverDatePicker()
                }

            VStack {
                Spacer(minLength: 0)
                LiquidGlassCalendarPicker(
                    events: viewModel.events,
                    bars: viewModel.bars,
                    useVisibleMapRegionOnly: viewModel.calendarUsesVisibleMapRegionOnly,
                    eventDotDates: viewModel.discoverCalendarDotDates,
                    dotsLoading: viewModel.isLoadingCalendarDots,
                    dotStatusText: viewModel.calendarDotStatusText,
                    selectedDate: Binding(
                        get: { discoverDatePickerSelection ?? viewModel.selectedDate },
                        set: { discoverDatePickerSelection = $0 }
                    ),
                    onDone: {
                        applyDiscoverDatePickerSelection()
                    },
                    onDisplayedMonthChange: { month in
                        viewModel.loadDiscoverCalendarDots(around: month, reason: "month_change")
                    }
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 100)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .center)))
        .zIndex(900)
    }

    private func resumeDiscoverSelectionAfterFanLoginIfNeeded(wasActive: Bool, isActive: Bool) {
        guard !wasActive, isActive, viewModel.isAuthenticatedForSocialFeatures, let venueID = pendingResumeVenueIDAfterLogin else { return }
        pendingResumeVenueIDAfterLogin = nil
        let fromBars = viewModel.bars.first(where: { $0.id == venueID })
        let fromFiltered = viewModel.filteredBars.first(where: { $0.id == venueID })
        guard let bar = fromBars ?? fromFiltered else { return }
        withAnimation(.spring()) {
            venuePreviewGameFilter = .all
            viewModel.selectedBar = bar
        }
    }

    @ViewBuilder
    private func discoverVenueDetailSheet() -> some View {
        if let selectedBar = viewModel.selectedBar {
            let claimStatus = viewModel.venueOwnershipClaimStatus(for: selectedBar)
            let showsBusinessOwnershipSection = viewModel.shouldShowVenueOwnershipClaimSection(for: selectedBar)
            let selectedDayGames = viewModel.selectedDayEventsForMap(selectedBar)
            let selectedVenueEvent = selectedEventForVenue(gamesToday: selectedDayGames)
            let ratingCount = viewModel.reviewCountDisplay(for: selectedBar)
            let supportedSports = venueSupportedSports(from: selectedDayGames)
            let displaySport = venueSportLabel(sportsSupported: supportedSports)
            let isBusinessConfirmed = venueIsBusinessConfirmed(bar: selectedBar, claimStatus: claimStatus)
            VenueDetailView(
                bar: selectedBar,
                selectedEvent: selectedVenueEvent,
                isFavorite: viewModel.favoriteVenueIDs.contains(selectedBar.id),
                goingCount: viewModel.displayedGoingCount(for: selectedBar),
                iconForSport: viewModel.iconForSport,
                mergedRating: viewModel.mergedDisplayRating(for: selectedBar),
                ratingCount: ratingCount,
                displaySport: displaySport,
                sportsSupported: supportedSports,
                hasGamesScheduledToday: !selectedDayGames.isEmpty,
                isBusinessConfirmed: isBusinessConfirmed,
                onDirections: { viewModel.openDirections(to: selectedBar) },
                onCall: { viewModel.callVenue(selectedBar) },
                onFavorite: { viewModel.toggleFavorite(selectedBar) },
                onAddressTap: { viewModel.openDirections(to: selectedBar) },
                onRateVenue: {
                    showVenueDetails = false
                    showVenueRatingSheet = true
                },
                experience: viewModel.experience(for: selectedBar),
                coverPhotoURL: selectedBar.coverPhotoURL,
                menuPhotoURL: selectedBar.menuPhotoURL,
                onClaimThisBusiness: discoverVenueClaimAction(for: selectedBar),
                showsBusinessOwnershipSection: showsBusinessOwnershipSection,
                businessClaimStatus: claimStatus
            )
            .task {
                await viewModel.refreshApprovedVenueOwnershipState(for: selectedBar)
                await viewModel.ensureBusinessOwnerSessionFlagsIfPossible(context: "venue_detail_open")
                viewModel.logBusinessOwnerSessionFlags(context: "venue_detail_open")
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func venueIsBusinessConfirmed(bar: BarVenue, claimStatus: VenueOwnershipClaimStatus) -> Bool {
        guard bar.businessId != nil || bar.ownerEmail != nil else { return false }
        switch claimStatus {
        case .approved, .alreadyClaimedByOtherBusiness:
            return true
        case .unclaimed, .pendingReview, .rejected:
            return false
        }
    }

    private func venueSupportedSports(from gamesToday: [SportsEvent]) -> [String] {
        Array(Set(gamesToday.compactMap { trimmedSportLabel($0.sport) })).sorted()
    }

    private func venueSportLabel(sportsSupported: [String]) -> String? {
        if sportsSupported.count > 1 { return "Multi-sport" }
        if let sport = sportsSupported.first { return sport }
        return nil
    }

    private func trimmedSportLabel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func selectedEventForVenue(gamesToday: [SportsEvent]) -> SportsEvent? {
        guard let selectedEvent = viewModel.selectedEvent else { return nil }
        return gamesToday.first {
            $0.title == selectedEvent.title &&
            $0.sport == selectedEvent.sport &&
            Calendar.current.isDate($0.date, inSameDayAs: selectedEvent.date)
        }
    }

    private func discoverVenueClaimAction(for bar: BarVenue) -> ((BarVenue) async -> String?)? {
        guard viewModel.canSubmitVenueOwnershipClaim(for: bar) else { return nil }
        return { venue in
            await viewModel.submitVenueOwnershipClaimFromVenueDetail(bar: venue)
        }
    }

    /// Returns true when center or zoom changed enough to warrant another venue fetch.
    private func mapVenueRegionIsMeaningfullyDifferent(from previous: MKCoordinateRegion, to new: MKCoordinateRegion) -> Bool {
        let centerLatDiff = abs(previous.center.latitude - new.center.latitude)
        let centerLonDiff = abs(previous.center.longitude - new.center.longitude)
        let prevLatSpan = max(previous.span.latitudeDelta, 1e-9)
        let prevLonSpan = max(previous.span.longitudeDelta, 1e-9)
        let spanLatRatio = abs(previous.span.latitudeDelta - new.span.latitudeDelta) / prevLatSpan
        let spanLonRatio = abs(previous.span.longitudeDelta - new.span.longitudeDelta) / prevLonSpan
        let centerMoved = centerLatDiff > 0.0012 || centerLonDiff > 0.0012
        let zoomChanged = spanLatRatio > 0.08 || spanLonRatio > 0.08
        return centerMoved || zoomChanged
    }

    private enum VenuePinDisplayState {
        case gameScheduled
        case noGameScheduled
    }

    private enum ClusterDisplayState {
        case gameScheduled
        case noGameScheduled
    }

    /// Chooses pin chrome from **venue + cached engagement** first; map zoom (`mapPinDisplayMode`) only caps density. Multi-game / trending venues never stay on the tiny sport-only pin at wide zoom.
    private func venueMarkerPinPresentation(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        base: MapViewModel.MapPinDisplayMode
    ) -> (mode: MapViewModel.MapPinDisplayMode, energy: Int, wantsEnriched: Bool) {
        let energy = viewModel.mapPinEnergyScore(bar: bar, gamesOnMapDay: gamesToday)
        let gamesOnSelectedDay = gamesToday.count
        let scheduledVenueGames = bar.games.count
        let wantsEnriched = gamesOnSelectedDay >= 2 || scheduledVenueGames >= 2 || energy > 0

        guard wantsEnriched else { return (base, energy, false) }

        let mode: MapViewModel.MapPinDisplayMode
        switch base {
        case .simple:
            mode = .compact
        case .compact:
            mode = .compact
        case .detailed:
            mode = gamesToday.isEmpty ? .compact : .detailed
        }
        return (mode, energy, true)
    }

    @ViewBuilder
    private func singleVenueMapPinButton(bar: BarVenue) -> some View {
        let gamesToday = viewModel.selectedDayEventsForMap(bar)
        let goingTotal = gamesToday.reduce(0) { total, game in
            if let id = viewModel.cachedVenueEventID(for: bar, gameTitle: game.title) {
                return total + viewModel.interestCountForVenueEvent(id)
            }
            return total
        }

        let pin = venueMarkerPinPresentation(
            bar: bar,
            gamesToday: gamesToday,
            base: viewModel.mapPinDisplayMode
        )
        let effectiveMode = pin.mode

#if DEBUG
        let _: Void = {
            guard pin.wantsEnriched else { return }
            let style: String = {
                switch effectiveMode {
                case .simple: return "simple"
                case .compact: return "compact"
                case .detailed: return "detailed"
                }
            }()
            print("[MapMarker] venue=\(bar.name) games=\(gamesToday.count)/\(bar.games.count) score=\(pin.energy) style=\(style)")
        }()
#endif

        Button {
            venuePreviewGameFilter = .all
            withAnimation(.spring()) {
                viewModel.centerMap(on: bar)
            }
        } label: {
            Group {
                switch venuePinDisplayState(bar) {
                case .gameScheduled:
                    switch effectiveMode {
                    case .simple:
                        simpleMapPin(bar: bar, gamesToday: gamesToday)

                    case .compact:
                        compactMapPin(bar: bar, gamesToday: gamesToday, goingTotal: goingTotal)

                    case .detailed:
                        detailedMapPin(bar: bar, gamesToday: gamesToday, goingTotal: goingTotal)
                    }
                case .noGameScheduled:
                    noGameScheduledMapPin()
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func multiVenueClusterAnnotation(cluster: VenueCluster) -> some View {
        let energy = viewModel.clusterVenueAnnotationEnergy(cluster: cluster)
        let displayState = clusterDisplayState(cluster)
        Button {
            #if DEBUG
            print(
                "[DiscoverMap] cluster tap id=\(cluster.id) count=\(cluster.count) maxEnergy=\(energy.maxScore) center=(\(cluster.coordinate.latitude),\(cluster.coordinate.longitude))"
            )
            #endif
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                viewModel.zoomTowardCluster(center: cluster.coordinate)
            }
            clusterForSheet = cluster
        } label: {
            clusterMapPin(
                cluster: cluster,
                maxEnergy: energy.maxScore,
                dominantSport: energy.dominantSport,
                displayState: displayState
            )
        }
        .buttonStyle(.plain)
    }

    /// Shows the system user location dot only after access is granted, so the map does not imply tracking before the user allows it.
    private func discoverMapShowsUserAnnotation() -> Bool {
        _ = discoverMapLocationAuthVersion
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    private var mapLayer: some View {
        return Map(position: $viewModel.cameraPosition) {
            if discoverMapShowsUserAnnotation() {
                UserAnnotation()
            }

            ForEach(viewModel.clusteredBars()) { cluster in
                Annotation(
                    cluster.count == 1 ? cluster.bars.first?.name ?? "Venue" : "\(cluster.count) venues",
                    coordinate: cluster.coordinate
                ) {
                    if cluster.count == 1, let bar = cluster.bars.first {
                        singleVenueMapPinButton(bar: bar)
                    } else {
                        multiVenueClusterAnnotation(cluster: cluster)
                    }
                }
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissDiscoverSearchKeyboard()
            }
        )
        .onMapCameraChange(frequency: .continuous) { _ in
            if isSearchFocused {
                dismissDiscoverSearchKeyboard()
            }
        }
        .mapControls {
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            dismissDiscoverSearchKeyboard()
            viewModel.visibleLatitudeDelta = context.region.span.latitudeDelta
            viewModel.cameraPosition = .region(context.region)

            let region = context.region
            mapVenueReloadTask?.cancel()
            mapVenueReloadTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(400))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if let last = lastMapVenueReloadRegion,
                   !mapVenueRegionIsMeaningfullyDifferent(from: last, to: region) {
                    return
                }
                await viewModel.loadVenuesFromSupabase()
                lastMapVenueReloadRegion = region
            }
        }
        .ignoresSafeArea()
    }
    
    /// Shown after debounce when the current query has no in-map matches (live search only). Hidden when the map has no loaded pins here (e.g. user is about to geocode a distant city on **Go**).
    private var showDiscoverVisibleSearchEmptyHint: Bool {
        let t = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = viewModel.debouncedDiscoverSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t == d && viewModel.venueSearchResults.isEmpty
            && !viewModel.isDiscoverVenueSearchLoading
            && viewModel.visibleBarCountInCurrentMapRegion() > 0
    }

    private var topControlArea: some View {
        VStack(alignment: .leading, spacing: discoverTopControlSpacing) {
            if let discoverLocationHint {
                HStack(alignment: .top, spacing: FGSpacing.sm) {
                    Image(systemName: "location.slash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FGColor.accentYellow)

                    Text(discoverLocationHint)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fanGeoFloatingStyle()
            }

            HStack(alignment: .top, spacing: FGSpacing.sm) {
                discoverUnifiedToolbar
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: mapUtilityStackSpacing) {
                    Button {
                        dismissDiscoverSearchKeyboard()
                        let status = CLLocationManager().authorizationStatus
                        if status == .denied || status == .restricted {
                            discoverLocationHint = "Location is turned off. You can enable it in Settings ▸ Privacy & Security ▸ Location Services ▸ FanGeo. The map still shows a default area you can pan and search."
                        } else {
                            discoverLocationHint = nil
                        }
                        viewModel.cameraPosition = .userLocation(
                            followsHeading: false,
                            fallback: .region(
                                MKCoordinateRegion(
                                    center: CLLocationCoordinate2D(latitude: 40.3916, longitude: -111.8508),
                                    span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
                                )
                            )
                        )
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            discoverMapLocationAuthVersion += 1
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(FGColor.accentBlue)
                            .frame(width: primaryMapUtilityButtonSize, height: primaryMapUtilityButtonSize)
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.84 : 0.92))
                                    }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Center map on your location")

                    Button {
                        dismissDiscoverSearchKeyboard()
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                            showMapDisplayModePopup.toggle()
                        }
                    } label: {
                        Image(systemName: "square.3.layers.3d.top.filled")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(showMapDisplayModePopup ? Color.white : FGColor.secondaryText(colorScheme))
                            .frame(width: secondaryMapUtilityButtonSize, height: secondaryMapUtilityButtonSize)
                            .background {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .fill(
                                                showMapDisplayModePopup
                                                    ? AnyShapeStyle(FGColor.brandGradient)
                                                    : AnyShapeStyle(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.58 : 0.74))
                                            )
                                    }
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .strokeBorder(showMapDisplayModePopup ? Color.white.opacity(0.14) : FGColor.divider(colorScheme).opacity(0.82), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Map display mode")
                }
                .offset(y: mapUtilityStackVerticalOffset)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 10, y: 4)
            }

            if showDiscoverVisibleSearchEmptyHint {
                HStack(spacing: FGSpacing.sm) {
                    FGStatusPill(title: "No visible matches", kind: .custom(tint: FGColor.accentBlue))
                    Text("Zoom out or search this area.")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fanGeoFloatingStyle()
            }

            if !viewModel.venueSearchResults.isEmpty {
                VStack(spacing: FGSpacing.sm) {
                    ForEach(viewModel.venueSearchResults.prefix(4)) { bar in
                        Button {
                            dismissDiscoverSearchKeyboard()
                            withAnimation(.spring()) {
                                venuePreviewGameFilter = .all
                                viewModel.selectVenueFromDiscoverSearchResult(bar)
                            }
                        } label: {
                            HStack(spacing: FGSpacing.md) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(FGColor.accentBlue)

                                VStack(alignment: .leading, spacing: FGSpacing.xs) {
                                    Text(bar.name)
                                        .font(FGTypography.cardTitle)
                                        .foregroundStyle(FGColor.primaryText(colorScheme))

                                    Text(bar.address)
                                        .font(FGTypography.caption)
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                        .lineLimit(1)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(FGColor.mutedText(colorScheme))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fanGeoFloatingStyle()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
        }
    }

    private var discoverUnifiedToolbar: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .trailing) {
                FGSearchBar(
                    placeholder: "Search venue, city, state, or country",
                    text: $viewModel.searchText,
                    onClear: { dismissDiscoverSearchKeyboard() },
                    onSubmit: {
                        dismissDiscoverSearchKeyboard()
                        viewModel.searchMapLocation()
                    },
                    submitLabel: .search,
                    textInputAutocapitalization: .words,
                    isFocused: $isSearchFocused,
                    horizontalPadding: 2,
                    verticalPadding: 1,
                    cornerRadius: 12,
                    contentSpacing: 6,
                    textFont: .system(size: 15, weight: .regular, design: .default),
                    showsBackground: false
                )

                if viewModel.isDiscoverVenueSearchLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, viewModel.searchText.isEmpty ? 2 : 26)
                }
            }

            Rectangle()
                .fill(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.88))
                .frame(height: 1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: discoverFilterRowSpacing) {
                    discoverDateFilterChip
                    ForEach(viewModel.sports, id: \.self) { sport in
                        discoverSportFilterChip(sport)
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 12, y: 6)
    }

    private var discoverDateFilterChip: some View {
        Button {
            openDiscoverDatePicker()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(viewModel.formattedSelectedDate)
                if viewModel.isUpdatingMapGames {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .font(FGTypography.metadata)
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(FGColor.brandGradient)
            .clipShape(Capsule(style: .continuous))
            .glowShadow(FGColor.gradientEnd)
        }
        .buttonStyle(.plain)
    }

    private func discoverSportFilterChip(_ sport: String) -> some View {
        SportFilterChip(
            sport: sport,
            isSelected: viewModel.selectedSport == sport,
            isCompact: true
        ) {
            withAnimation(.spring()) {
                viewModel.sportChanged(to: sport)
            }
        }
    }

    private var discoverMapDisplayModePopup: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(DiscoverMapDisplayMode.allCases, id: \.rawValue) { mode in
                let isOn = viewModel.mapDisplayMode == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.mapDisplayMode = mode
                        showMapDisplayModePopup = false
                    }
                } label: {
                    HStack(spacing: FGSpacing.sm) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isOn ? FGColor.accentBlue : FGColor.mutedText(colorScheme))
                        Text(mode.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.sm + 1)
                    .frame(minWidth: 168, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                            .fill(isOn ? FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.10) : Color.clear)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .fill(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.74 : 0.76))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 16, y: 8)
    }

    private func dismissDiscoverSearchKeyboard() {
        isSearchFocused = false
    }

    private func openDiscoverDatePicker() {
        dismissDiscoverSearchKeyboard()
        discoverDatePickerSelection = viewModel.selectedDate
        viewModel.loadDiscoverCalendarDots(
            around: viewModel.selectedDate,
            reason: "calendar_open",
            logIfOpeningBeforeReady: true
        )
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            showDatePicker = true
        }
    }

    private func dismissDiscoverDatePicker() {
        discoverDatePickerSelection = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            showDatePicker = false
        }
    }

    private func applyDiscoverDatePickerSelection() {
        let appliedDate = discoverDatePickerSelection ?? viewModel.selectedDate
        #if DEBUG
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        let appliedDateString = fmt.string(from: appliedDate)
        print("[CalendarPerf] Done tapped date=\(appliedDateString)")
        #endif
        let requestID = viewModel.beginDiscoverDateChange(to: appliedDate)
        discoverDatePickerSelection = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            showDatePicker = false
        }
        #if DEBUG
        print("[CalendarPerf] Calendar dismissed date=\(appliedDateString)")
        #endif
        viewModel.scheduleDiscoverSelectedDayRefresh(requestID: requestID)
    }
    
    private var discoverAdvertisementBannerContentWidth: CGFloat {
        max(320, UIScreen.main.bounds.width - FGSpacing.lg * 2)
    }

    /// Test AdMob banner when available; keeps the prior Sponsored placeholder if load fails (async, off the map data path).
    private var adBanner: some View {
        ZStack(alignment: .leading) {
            discoverSponsoredBannerFallback
                .opacity(discoverTopAdLoadedSuccessfully ? 0 : 1)

            if !discoverTopAdLoadFailed {
                AdMobBannerView(
                    adUnitID: AdMobTestConfiguration.testBannerAdUnitID,
                    bannerWidth: discoverAdvertisementBannerContentWidth,
                    onAdLoaded: {
                        withAnimation(.easeOut(duration: 0.22)) {
                            discoverTopAdLoadedSuccessfully = true
                        }
                    },
                    onAdFailed: { _ in
                        discoverTopAdLoadFailed = true
                        discoverTopAdLoadedSuccessfully = false
                    }
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityElement(children: .contain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var discoverSponsoredBannerFallback: some View {
        HStack(spacing: 6) {
            FGStatusPill(title: "Sponsored", kind: .custom(tint: FGColor.accentYellow))

            VStack(alignment: .leading, spacing: 2) {
                Text("Game-night specials")
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text("From leagues, brands, and local venues")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }

            Spacer(minLength: FGSpacing.sm)

            Image(systemName: "megaphone.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 26, height: 26)
                .background(FGColor.accentBlue.opacity(0.09))
                .clipShape(Circle())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 12, y: 6)
    }

    /// Uses existing ``MapViewModel`` loading flags only (no extra fetches).
    private var discoverSummaryDataLoading: Bool {
        viewModel.isLoadingEvents
            || viewModel.isRefreshingDiscoverEvents
            || viewModel.isLoadingMapVenues
            || viewModel.isRefreshingMapVenues
    }

    private var discoverSummaryLoadingFeedbackVisible: Bool {
        discoverSummaryDataLoading
    }

    private var discoverSummaryVenueCount: Int {
        viewModel.mapVisibleBars.count
    }

    private var discoverAllFilterHasNoGamePins: Bool {
        guard viewModel.selectedSport == "All", viewModel.mapDisplayMode == .allSpots else { return false }
        return viewModel.mapVisibleBars.contains { !viewModel.venueHasVisibleGameToday($0) }
    }

    private var discoverAllFilterHasNoGamesToday: Bool {
        guard viewModel.selectedSport == "All", viewModel.mapDisplayMode == .allSpots else { return false }
        return !viewModel.mapVisibleBars.isEmpty && !viewModel.mapVisibleBars.contains { viewModel.venueHasVisibleGameToday($0) }
    }

    private var discoverNearbySummarySubtitle: String {
        if discoverSummaryLoadingFeedbackVisible {
            return "Updating venues…"
        }
        if viewModel.selectedSport == "All" {
            switch viewModel.mapDisplayMode {
            case .allSpots:
                return "Showing nearby watch spots"
            case .gamesOnly:
                return discoverSummaryVenueCount > 0 ? "Showing venues with games today" : "No games scheduled today."
            }
        }
        if discoverSummaryVenueCount > 0 {
            return "\(discoverSummaryVenueCount) venues match your selection"
        }
        if viewModel.mapDisplayMode == .gamesOnly {
            return "No games scheduled today."
        }
        return "0 venues match your selection"
    }
    
    private var nearbySummaryCard: some View {
        let refreshError = viewModel.eventLoadError?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRefreshError = !(refreshError ?? "").isEmpty && !discoverSummaryLoadingFeedbackVisible
        let hasNoVenues = !discoverSummaryLoadingFeedbackVisible && !hasRefreshError && discoverSummaryVenueCount == 0
        let summaryTint = hasRefreshError ? FGColor.accentYellow : (hasNoVenues ? FGColor.accentYellow : FGColor.accentBlue)
        let summaryTitle = viewModel.selectedSport == "All"
            ? (viewModel.mapDisplayMode == .allSpots ? "Showing nearby watch spots" : "Showing venues with games today")
            : (viewModel.selectedEvent?.title ?? "FanGeo")
        let summaryMessage: String = {
            if discoverSummaryLoadingFeedbackVisible {
                return discoverNearbySummarySubtitle
            }
            if let refreshError, !refreshError.isEmpty {
                return refreshError
            }
            if hasNoVenues {
                if viewModel.mapDisplayMode == .gamesOnly {
                    return "No games scheduled today."
                }
                return "Zoom out or search another area to uncover more watch spots."
            }
            if viewModel.selectedSport == "All" {
                switch viewModel.mapDisplayMode {
                case .allSpots:
                    if discoverAllFilterHasNoGamesToday {
                        return "No games scheduled today. Gray pins are venues without scheduled games."
                    }
                    if discoverAllFilterHasNoGamePins {
                        return "Gray pins are venues without scheduled games."
                    }
                    return "Showing nearby watch spots"
                case .gamesOnly:
                    return "Showing venues with games today"
                }
            }
            return discoverNearbySummarySubtitle
        }()

        return HStack(alignment: .center, spacing: FGSpacing.sm + 2) {
            Group {
                if discoverSummaryLoadingFeedbackVisible {
                    ProgressView()
                        .controlSize(.small)
                        .tint(FGColor.secondaryText(colorScheme))
                } else {
                    Image(systemName: hasRefreshError ? "exclamationmark.triangle.fill" : (hasNoVenues ? "exclamationmark.circle.fill" : "map.fill"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(summaryTint)
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: FGSpacing.xs + 2) {
                    Text(summaryTitle)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)

                    if !discoverSummaryLoadingFeedbackVisible {
                        FGStatusPill(
                            title: viewModel.selectedSport == "All"
                                ? (
                                    viewModel.mapDisplayMode == .allSpots
                                        ? (discoverSummaryVenueCount > 0 ? "\(discoverSummaryVenueCount) spots" : "Nearby")
                                        : (discoverSummaryVenueCount > 0 ? "\(discoverSummaryVenueCount) venues" : "Games")
                                )
                                : "\(discoverSummaryVenueCount) venues",
                            kind: .custom(tint: hasRefreshError ? FGColor.accentYellow : (hasNoVenues ? FGColor.accentYellow : FGColor.accentGreen))
                        )
                    }
                }

                Text(summaryMessage)
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm + 2)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.30))
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.14 : 0.08), radius: 12, y: 6)
    }

    private func discoverMapStatusBanner(text: String, isLoading: Bool) -> some View {
        HStack(spacing: FGSpacing.sm) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FGColor.accentGreen)
                }
            }
            Text(text)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm)
        .background(.ultraThinMaterial)
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 10, y: 4)
    }

    private func discoverMapToastBanner(text: String, isError: Bool) -> some View {
        HStack(spacing: FGSpacing.sm) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? FGColor.accentYellow : FGColor.accentGreen)
            Text(text)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm)
        .background(.ultraThinMaterial)
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 10, y: 4)
    }

    /// City / region line for logged-out teaser (no street-level detail).
    private func teaserAreaDescription(for bar: BarVenue) -> String {
        let parts = bar.address.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "Location on map" }
        if parts.count == 1 { return String(parts[0]) }
        return parts.suffix(2).joined(separator: ", ")
    }

    private func loggedOutVenueTeaserCard(_ bar: BarVenue) -> some View {
        FGCard {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                VStack(alignment: .leading, spacing: FGSpacing.xs) {
                    Text("Sign in to see what's happening")
                        .font(FGTypography.sectionTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))

                    Text("Sign in with a fan account to view games, fan updates, ratings, and live venue details.")
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.spring()) {
                        viewModel.selectedBar = nil
                        viewModel.clearDiscoverRemotePreviewHold()
                        pendingResumeVenueIDAfterLogin = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()
                .overlay(FGColor.divider(colorScheme))

            VStack(alignment: .leading, spacing: FGSpacing.xs) {
                Text(bar.name)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(teaserAreaDescription(for: bar))
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            VStack(spacing: FGSpacing.sm) {
                FGPrimaryButton(title: "Sign in or create account") {
                    pendingResumeVenueIDAfterLogin = bar.id
                    viewModel.discoverNavigateToAccountForUserAuth = true
                }

                FGSecondaryButton(title: "Not now") {
                    withAnimation(.spring()) {
                        viewModel.selectedBar = nil
                        viewModel.clearDiscoverRemotePreviewHold()
                        pendingResumeVenueIDAfterLogin = nil
                    }
                }
            }
        }
        .frame(maxHeight: 360)
    }

    private var discoverPreviewCardMaterial: Material {
        colorScheme == .dark ? .regularMaterial : .ultraThinMaterial
    }

    private var discoverPreviewCardTint: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.78)
            : Color.white.opacity(0.78)
    }

    private var discoverPreviewCardBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.15)
            : FGColor.divider(colorScheme)
    }

    private var discoverPreviewSecondaryTextColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.82)
            : FGColor.secondaryText(colorScheme)
    }

    private var discoverPreviewMutedIconColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.74)
            : .secondary
    }

    private var discoverPreviewControlBackground: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.56)
            : FGColor.cardBackground(colorScheme)
    }

    private var discoverPreviewControlBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : FGColor.divider(colorScheme)
    }

    private var discoverPreviewInnerSurface: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.54)
            : FGColor.background(colorScheme).opacity(0.90)
    }

    private var discoverPreviewAccentSurface: Color {
        colorScheme == .dark
            ? FGColor.accentGreen.opacity(0.18)
            : FGColor.accentGreen.opacity(0.09)
    }
    
    /// Venue image, name, address, actions, rating, and experience — stays fixed while games scroll (sports are per game card only).
    @ViewBuilder
    private func venuePreviewCardStaticHeader(bar: BarVenue) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.lg) {
            HStack(alignment: .top, spacing: FGSpacing.md) {

                barThumbnail(bar)

                VStack(alignment: .leading, spacing: FGSpacing.xs) {
                    Text(bar.name)
                        .font(FGTypography.sectionTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))

                    Button {
                        viewModel.openDirections(to: bar)
                    } label: {
                        HStack(spacing: FGSpacing.xs) {
                            Text(bar.address)
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.accentBlue)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Image(systemName: "location.fill")
                                .font(.caption)
                                .foregroundStyle(FGColor.accentBlue)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 8)

                Button {
                    viewModel.toggleFavorite(bar)
                } label: {
                    Image(systemName: viewModel.favoriteVenueIDs.contains(bar.id) ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(viewModel.favoriteVenueIDs.contains(bar.id) ? .red : discoverPreviewMutedIconColor)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring()) {
                        viewModel.selectedBar = nil
                        viewModel.clearDiscoverRemotePreviewHold()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(discoverPreviewMutedIconColor)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: FGSpacing.sm) {
                if !bar.distance.isEmpty {
                    FGStatusPill(title: bar.distance, kind: .custom(tint: FGColor.accentBlue))
                }

                Button {
                    showVenueRatingSheet = true
                } label: {
                    let rating = viewModel.mergedDisplayRating(for: bar)
                    let reviewCount = viewModel.reviewCountDisplay(for: bar)
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        if let rating, reviewCount > 0 {
                            Text(String(format: "%.1f", rating))
                                .fontWeight(.bold)
                            Text("(\(reviewCount))")
                                .foregroundStyle(discoverPreviewSecondaryTextColor)
                                .fontWeight(.medium)
                        } else {
                            Text("Rate")
                                .fontWeight(.semibold)
                        }
                    }
                    .font(FGTypography.metadata)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.xs + 2)
                    .background(discoverPreviewControlBackground)
                    .clipShape(Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(discoverPreviewControlBorder, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }

            if let experience = viewModel.experience(for: bar) {
                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    Text(experience.atmosphere)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))

                    Text(experience.teamFanbases.joined(separator: " • "))
                        .font(FGTypography.caption)
                        .foregroundStyle(discoverPreviewSecondaryTextColor)

                    HStack(spacing: FGSpacing.sm) {
                        Label(
                            experience.hasAudio ? "Game audio" : "No audio",
                            systemImage: experience.hasAudio ? "speaker.wave.2.fill" : "speaker.slash.fill"
                        )
                        Label(experience.liveOccupancy, systemImage: "person.3.fill")
                        Text(experience.coverCharge)
                    }
                    .font(FGTypography.metadata)
                    .fontWeight(.semibold)
                    .foregroundStyle(FGColor.accentGreen)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(discoverPreviewAccentSurface)
                    .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                }
            }
        }
    }

    private func venuePreviewCard(_ bar: BarVenue) -> some View {
        let resolved = viewModel.canonicalBarForDiscover(bar)
        let gamesToday = viewModel.gamesForVenuePreview(
            bar: resolved,
            date: viewModel.selectedDate,
            sportFilter: viewModel.selectedSport
        )
        let selectedVenueEvent = selectedEventForVenue(gamesToday: gamesToday)

        return VStack(alignment: .leading, spacing: 12) {
            venuePreviewCardStaticHeader(bar: resolved)

            Rectangle()
                .fill(FGColor.divider(colorScheme))
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if let selectedEvent = selectedVenueEvent {
                        selectedEventSection(bar: resolved, selectedEvent: selectedEvent)
                    } else {
                        gamesListSection(bar: resolved, gamesToday: gamesToday)
                    }

                    FGPrimaryButton(title: "Details") {
                        showVenueDetails = true
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 248)
            .clipped()
        }
        .padding(FGSpacing.lg)
        .frame(maxHeight: 420)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                    .fill(discoverPreviewCardMaterial)
                RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                    .fill(discoverPreviewCardTint)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                .strokeBorder(discoverPreviewCardBorder, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.34 : 0.14), radius: colorScheme == .dark ? 24 : 16, x: 0, y: colorScheme == .dark ? 14 : 9)
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.04), radius: 12, x: 0, y: 2)
        .onChange(of: viewModel.selectedBar?.id) { oldId, newId in
            guard oldId != newId else { return }
            venuePreviewGameFilter = .all
        }
        .task(id: resolved.id) {
            await viewModel.prefetchDiscoverVenueImages(for: resolved, includeMenu: false)
            guard viewModel.canViewDiscoverDetails() else { return }
            let dayEvents = viewModel.gamesForVenuePreview(
                bar: resolved,
                date: viewModel.selectedDate,
                sportFilter: viewModel.selectedSport
            )
            for game in dayEvents.prefix(5) {
                if let venueEventID = await viewModel.venueEventID(for: resolved, gameTitle: game.title) {
                    await viewModel.loadGoingUserProfiles(for: venueEventID)
                }
            }
        }
    }

    
    private func barThumbnail(_ bar: BarVenue) -> some View {
        Group {
            if let urlString = ImageDisplayURL.forList(thumbnail: bar.coverPhotoThumbnailURL, full: bar.coverPhotoURL),
               let url = URL(string: urlString) {
                DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.gray.opacity(0.18))
                }
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.gray.opacity(0.18))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 74, height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    
    private func toggleSupabaseInterest(for bar: BarVenue, selectedEvent: SportsEvent) {
        _ = _Concurrency.Task<Void, Never> {
            if let venueEventID = await viewModel.venueEventID(
                for: bar,
                gameTitle: selectedEvent.title
            ) {
                let wasInterested = await MainActor.run {
                    viewModel.isInterestedInVenueEvent(venueEventID)
                }

                await MainActor.run {
                    if wasInterested {
                        viewModel.removeInterested(in: bar, gameTitle: selectedEvent.title)
                    } else {
                        viewModel.markInterested(in: bar, gameTitle: selectedEvent.title)
                    }
                }

                let ok: Bool
                if wasInterested {
                    ok = await viewModel.removeInterestInVenueEvent(venueEventID: venueEventID)
                } else {
                    ok = await viewModel.markInterestedInVenueEvent(venueEventID: venueEventID)
                }

                if !ok {
                    await MainActor.run {
                        if wasInterested {
                            viewModel.markInterested(in: bar, gameTitle: selectedEvent.title)
                        } else {
                            viewModel.removeInterested(in: bar, gameTitle: selectedEvent.title)
                        }
                        viewModel.showSocialActionToast("Couldn't update your game plan.")
                    }
                    return
                }

                if !wasInterested {
                    await viewModel.addGameToCalendar(
                        title: selectedEvent.title,
                        date: selectedEvent.date,
                        location: bar.address
                    )
                }
            }
        }
    }
    
    private func selectedEventSection(bar: BarVenue, selectedEvent: SportsEvent) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            FGStatusPill(title: "Showing selected game", kind: .custom(tint: FGColor.accentBlue))
            gameInterestRow(bar: bar, event: selectedEvent)
        }
    }
    
    private func gamesListSection(bar: BarVenue, gamesToday: [SportsEvent]) -> some View {
        let filtered = gamesFilteredForVenuePreview(bar: bar, gamesToday: gamesToday, filter: venuePreviewGameFilter)

        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                FGStatusPill(title: "Game list", kind: .custom(tint: FGColor.accentBlue))

                venuePreviewGameFilterPicker

                if viewModel.isLoadingEvents && gamesToday.isEmpty {
                    loadingVenueGamesView
                } else if gamesToday.isEmpty {
                    if bar.games.isEmpty, !viewModel.isLoadingEvents {
                        Text("No games listed yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        venuePreviewNoGamesForDateView
                    }
                } else if filtered.isEmpty {
                    venueGameFilterEmptyView()
                } else {
                    ForEach(Array(filtered.prefix(12)), id: \.id) { event in
                        gameInterestRow(bar: bar, event: event)
                    }
                }
            }
            if viewModel.isRefreshingDiscoverEvents && !gamesToday.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 2)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: venuePreviewGameFilter)
    }

    private var venuePreviewGameFilterPicker: some View {
        HStack(spacing: FGSpacing.xs) {
            ForEach(VenuePreviewGameFilter.allCases) { mode in
                let isOn = venuePreviewGameFilter == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        venuePreviewGameFilter = mode
                    }
                } label: {
                    Text(mode.segmentTitle)
                        .font(FGTypography.metadata)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .padding(.horizontal, FGSpacing.sm + 2)
                        .padding(.vertical, FGSpacing.xs + 2)
                        .foregroundStyle(isOn ? Color.white : FGColor.primaryText(colorScheme))
                        .background {
                            Capsule(style: .continuous)
                                .fill(
                                    isOn
                                        ? AnyShapeStyle(FGColor.brandGradient)
                                        : AnyShapeStyle(Color.clear)
                                )
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, FGSpacing.xs)
        .padding(.vertical, FGSpacing.xs)
        .background {
            Capsule(style: .continuous)
                .fill(discoverPreviewControlBackground)
        }
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(discoverPreviewControlBorder, lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Same as ``gameInterestRow`` `alreadyInterested` (local key or ``isInterestedInVenueEvent``).
    private func venuePreviewCurrentUserIsGoing(bar: BarVenue, game: SportsEvent) -> Bool {
        if viewModel.isInterested(in: bar, gameTitle: game.title) { return true }
        guard let id = viewModel.cachedVenueEventID(for: bar, gameTitle: game.title) else { return false }
        return viewModel.isInterestedInVenueEvent(id)
    }

    private func gamesFilteredForVenuePreview(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        filter: VenuePreviewGameFilter
    ) -> [SportsEvent] {
        switch filter {
        case .all:
            return gamesToday

        case .imGoing:
            // Show rows with the black “I’m going” button:
            // current user is NOT already going, but there is activity/interest.
            return gamesToday.filter { game in
                guard let id = viewModel.cachedVenueEventID(for: bar, gameTitle: game.title) else { return false }
                guard viewModel.interestCountForVenueEvent(id) > 0 else { return false }
                return !venuePreviewCurrentUserIsGoing(bar: bar, game: game)
            }

        case .going:
            // Show rows with the green “Going” button:
            // current user IS already going.
            return gamesToday.filter {
                venuePreviewCurrentUserIsGoing(bar: bar, game: $0)
            }
        }
    }

    private func venueGameFilterEmptyView() -> some View {
        HStack(spacing: FGSpacing.sm) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(FGColor.mutedText(colorScheme))
            Text("No games match this filter.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(discoverPreviewInnerSurface)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(discoverPreviewControlBorder.opacity(colorScheme == .dark ? 0.9 : 0.7), lineWidth: 1)
        }
    }

    private var venuePreviewNoGamesForDateView: some View {
        HStack(spacing: FGSpacing.sm) {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(FGColor.mutedText(colorScheme))
            Text("No games scheduled for this date.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(discoverPreviewInnerSurface)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(discoverPreviewControlBorder.opacity(colorScheme == .dark ? 0.9 : 0.7), lineWidth: 1)
        }
    }
    
    private func trendingScore(for venueEventID: UUID, goingCount: Int) -> Int {
        let commentCount = viewModel.venueEventComments[venueEventID]?.count ?? 0

        let vibeCount = viewModel.venueEventVibeCounts[venueEventID]?
            .values
            .reduce(0, +) ?? 0

        return goingCount + commentCount + vibeCount
    }
    
    private func trendingLabel(for score: Int) -> String? {
        if score >= 40 {
            return "👑 Trending now"
        } else if score >= 16 {
            return "🚀 Hot"
        } else if score >= 6 {
            return "🔥 Active"
        } else if score >= 1 {
            return "✨ Starting up"
        }

        return nil
    }
    
    private func perGameGoingLine(venueEventID: UUID?, count: Int) -> String {
        guard let venueEventID else {
            return count > 0 ? "\(count) people are going" : "Be the first to go"
        }
        if count <= 0 { return "Be the first to go" }
        let im = viewModel.isInterestedInVenueEvent(venueEventID)
        if im {
            return count == 1 ? "You're going" : "You and \(count - 1) others are going"
        }
        return "\(count) people are going"
    }

    private func gameInterestRow(bar: BarVenue, event: SportsEvent) -> some View {
        let gameTitle = event.title
        let venueEventID = viewModel.cachedVenueEventID(for: bar, gameTitle: gameTitle)

        let alreadyInterested = venueEventID.map {
            viewModel.isInterestedInVenueEvent($0)
        } ?? false

        let count = venueEventID.map {
            viewModel.interestCountForVenueEvent($0)
        } ?? 0

        let score = venueEventID.map { trendingScore(for: $0, goingCount: count) } ?? count

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SportArtworkIconView(sport: event.sport, diameter: 60)

                VStack(alignment: .leading, spacing: FGSpacing.xs) {
                    Text(event.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))

                    Text("\(event.date.formatted(date: .abbreviated, time: .omitted)) · \(viewModel.displayTime(for: event))")
                        .font(FGTypography.caption)
                        .foregroundStyle(discoverPreviewSecondaryTextColor)

                    Text("\(count) interested / going")
                        .font(FGTypography.metadata)
                        .fontWeight(.semibold)
                        .foregroundStyle(FGColor.accentGreen)

                    if let venueEventID,
                       let topVibe = topVibeText(for: venueEventID) {
                        Text(topVibe)
                            .font(FGTypography.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(FGColor.accentYellow)
                    }

                    if let label = trendingLabel(for: score) {
                        HStack(spacing: 8) {
                            FGStatusPill(
                                title: label,
                                kind: .custom(tint: score >= 40 ? FGColor.gradientEnd : FGColor.accentYellow)
                            )
                            Text("Score \(score)")
                                .font(FGTypography.metadata)
                                .foregroundStyle(discoverPreviewSecondaryTextColor)
                        }
                    }
                }

                Spacer(minLength: 8)

                Button {
                    guard viewModel.canMarkInterest else { return }
                    toggleSupabaseInterest(for: bar, selectedEvent: event)
                } label: {
                    Text(!viewModel.canMarkInterest ? "Login" : (alreadyInterested ? "Going" : "I’m going"))
                        .font(FGTypography.metadata)
                        .fontWeight(.bold)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background {
                            Capsule(style: .continuous)
                                .fill(
                                    !viewModel.canMarkInterest
                                        ? AnyShapeStyle(Color.gray.opacity(0.22))
                                        : alreadyInterested
                                            ? AnyShapeStyle(FGColor.accentGreen)
                                            : AnyShapeStyle(FGColor.brandGradient)
                                )
                        }
                        .foregroundStyle(!viewModel.canMarkInterest ? Color.secondary : Color.white)
                        .clipShape(Capsule())
                }
                .disabled(!viewModel.canMarkInterest)
            }

            HStack(alignment: .center, spacing: 10) {
                if let venueEventID {
                    GoingAvatarStack(profiles: viewModel.goingProfiles(for: venueEventID))
                }
                Text(perGameGoingLine(venueEventID: venueEventID, count: count))
                    .font(FGTypography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer(minLength: 0)
            }

            if let venueEventID {
                VenueEventVibeMeterView(
                    viewModel: viewModel,
                    venueEventID: venueEventID
                )

                Button {
                    selectedCommentsEventID = venueEventID
                } label: {
                    fanUpdatesRowLabel(for: venueEventID)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .fill(discoverPreviewInnerSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .strokeBorder(discoverPreviewControlBorder, lineWidth: 1)
                )
        )
        .task(id: venueEventID ?? event.id) {
            guard let id = await viewModel.venueEventID(for: bar, gameTitle: gameTitle) else { return }
            async let comments: Void = viewModel.loadComments(for: id)
            async let vibes: Void = viewModel.loadVibes(for: id)
            async let going: Void = viewModel.loadGoingUserProfiles(for: id)
            _ = await (comments, vibes, going)

            let emails = (viewModel.venueEventComments[id] ?? [])
                .compactMap { $0.user_email }
            await viewModel.loadUserProfilesForEmails(emails)
        }
    }

    private func fanUpdatesRowLabel(for venueEventID: UUID) -> some View {
        let comments = viewModel.venueEventComments[venueEventID] ?? []
        return HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Fan updates")
                    .font(.caption.weight(.bold))
                Text(comments.isEmpty ? "Tap to join the conversation" : "\(comments.count) updates · tap to open")
                    .font(.caption2)
                    .foregroundStyle(discoverPreviewSecondaryTextColor)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(discoverPreviewMutedIconColor)
        }
        .padding(.horizontal, 4)
    }
    
    private func liveScoreEmoji(for score: Int) -> String {
        if score >= 40 {
            return "👑"
        } else if score >= 16 {
            return "🚀"
        } else if score >= 6 {
            return "🔥"
        } else if score >= 1 {
            return "✨"
        }

        return ""
    }
    
    
    private func simpleMapPin(bar: BarVenue, gamesToday: [SportsEvent]) -> some View {
        let sport = gamesToday.first?.sport ?? bar.primarySport

        return Image(systemName: viewModel.iconForSport(sport))
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Color.black).shadow(radius: 5))
    }

    private func noGameScheduledMapPin() -> some View {
        Image(systemName: "building.2.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.92))
            .frame(width: 38, height: 38)
            .background(
                Circle()
                    .fill(Color.gray.opacity(0.62))
                    .shadow(radius: 4)
            )
            .opacity(0.6)
    }

    private func compactMapPin(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        goingTotal: Int
    ) -> some View {
        let liveScore = liveActivityScore(for: bar, gamesToday: gamesToday)

        return HStack(spacing: 6) {
            Image(systemName: viewModel.iconForSport(gamesToday.first?.sport ?? bar.primarySport))
                .font(.system(size: 14, weight: .bold))

            if liveScore > 0 {
                Text("\(liveScoreEmoji(for: liveScore)) \(liveScore)")
                    .font(.caption2)
                    .fontWeight(.bold)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            ZStack {
                if liveScore >= livePulseThreshold {
                    LivePulseView(
                        isTrending: liveScore >= 40
                    )
                }

                Capsule()
                    .fill(Color.black)
                    .shadow(radius: 5)
            }
        }
    }
    
    private func liveActivityScore(for bar: BarVenue, gamesToday: [SportsEvent]) -> Int {
        viewModel.mapPinEnergyScore(bar: bar, gamesOnMapDay: gamesToday)
    }

    private func venuePinDisplayState(_ venue: BarVenue) -> VenuePinDisplayState {
        viewModel.venueHasVisibleGameToday(venue) ? .gameScheduled : .noGameScheduled
    }

    private func clusterDisplayState(_ cluster: VenueCluster) -> ClusterDisplayState {
        cluster.bars.contains { viewModel.venueHasVisibleGameToday($0) } ? .gameScheduled : .noGameScheduled
    }

    private func detailedMapPin(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        goingTotal: Int
    ) -> some View {
        
        VStack(spacing: 4) {
            HStack(spacing: -6) {
                ForEach(gamesToday.prefix(3), id: \.id) { game in
                    Image(systemName: viewModel.iconForSport(game.sport))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background {
                            ZStack {
                                let liveScore = liveActivityScore(for: bar, gamesToday: gamesToday)

                                if liveScore >= livePulseThreshold {
                                    LivePulseView(
                                        isTrending: liveScore >= 40
                                    )
                                }

                                Circle()
                                    .fill(Color.black)
                                    .shadow(radius: 5)
                            }
                        }
                }
            }
            let liveScore = liveActivityScore(for: bar, gamesToday: gamesToday)
            Text(gamesToday.count == 1 ? gamesToday.first?.sport ?? bar.primarySport : "\(gamesToday.count) games")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.75))
                .clipShape(Capsule())

            if liveScore > 0 {
                Text("🔥 \(liveScore) live")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.95))
                    .clipShape(Capsule())
            }

            Text(bar.name)
                .font(.caption2)
                .foregroundStyle(.primary)
        }
    }
    
    private var loadingVenueGamesView: some View {
        HStack(spacing: FGSpacing.sm) {
            ProgressView()
                .scaleEffect(0.85)

            Text("Loading venue games...")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.60 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
    }
        
    
    private func clusterMapPin(
        cluster: VenueCluster,
        maxEnergy: Int,
        dominantSport: String?,
        displayState: ClusterDisplayState
    ) -> some View {
        let caption = viewModel.mapClusterEnergyCaption(maxScore: maxEnergy)
        return VStack(spacing: 3) {
            if case .gameScheduled = displayState,
               let sport = dominantSport,
               maxEnergy > 0 {
                Image(systemName: viewModel.iconForSport(sport))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(viewModel.colorForSport(sport))
                    .padding(5)
                    .background(Circle().fill(Color.white.opacity(0.95)))
            } else if case .noGameScheduled = displayState {
                Image(systemName: "building.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(5)
                    .background(Circle().fill(Color.gray.opacity(0.8)))
            }

            Text("\(cluster.count)")
                .font(.headline)
                .fontWeight(.bold)

            Text("venues")
                .font(.caption2)
                .fontWeight(.bold)

            if case .gameScheduled = displayState, maxEnergy > 0 {
                Text("\(maxEnergy)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.yellow.opacity(0.95))
            }

            if case .gameScheduled = displayState, let caption {
                Text(caption)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .frame(minWidth: 58, minHeight: 58)
        .background(
            Circle()
                .fill(displayState == .gameScheduled ? Color.black : Color.gray.opacity(0.72))
                .shadow(radius: 7)
        )
        .opacity(displayState == .gameScheduled ? 1 : 0.62)
    }

    private func topVibeText(for venueEventID: UUID) -> String? {
        let counts = viewModel.venueEventVibeCounts[venueEventID] ?? [:]

        guard let top = counts.max(by: { $0.value < $1.value }),
              top.value > 0 else {
            return nil
        }

        switch top.key {
        case "audio_on":
            return "🔊 Audio confirmed · \(top.value)"
        case "packed":
            return "🔥 Packed · \(top.value)"
        case "seats_open":
            return "🪑 Seats open · \(top.value)"
        case "specials":
            return "🍺 Specials · \(top.value)"
        case "tv_visible":
            return "📺 TVs visible · \(top.value)"
        default:
            return nil
        }
    }
    
}
