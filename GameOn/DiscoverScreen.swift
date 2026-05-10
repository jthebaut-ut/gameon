import SwiftUI
import MapKit

/// Primary map experience: search, date strip, clustered annotations, venue preview, and sheets for detail, comments, and vibes.
struct DiscoverScreen: View {

    @ObservedObject var viewModel: MapViewModel
    @State private var showVenueDetails = false
    @State private var showDatePicker = false
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
    private let livePulseThreshold = 16

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
            
            VStack(spacing: 12) {
                adBanner
                topControlArea
                if let mapHint = viewModel.followingMapNavigationMessage, !mapHint.isEmpty {
                    Text(mapHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer()
                
                if let selectedBar = viewModel.selectedBar {
                    if viewModel.isLoggedIn {
                        venuePreviewCard(selectedBar)
                    } else {
                        loggedOutVenueTeaserCard(selectedBar)
                    }
                } else {
                    nearbySummaryCard
                }
            }
            .padding(.horizontal)
            .padding(.top, 14)
            .padding(.bottom, 85)

            if showDatePicker {
                discoverMapDatePickerOverlay
            }
        }
    .task {
        viewModel.reloadVenueUserRatingsFromStorage()
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
    .onChange(of: viewModel.pendingFollowingMapVenueID) { _, id in
        guard id != nil else { return }
        Task {
            await viewModel.consumeFollowingVenueNavigationIfPending()
        }
    }
    .onChange(of: viewModel.isLoggedIn) { wasLoggedIn, isLoggedIn in
        if !isLoggedIn {
            showVenueDetails = false
            showVenueRatingSheet = false
            selectedCommentsEventID = nil
            pendingResumeVenueIDAfterLogin = nil
        } else if !wasLoggedIn, isLoggedIn, let venueID = pendingResumeVenueIDAfterLogin {
            pendingResumeVenueIDAfterLogin = nil
            if let bar = viewModel.bars.first(where: { $0.id == venueID })
                ?? viewModel.filteredBars.first(where: { $0.id == venueID }) {
                withAnimation(.spring()) {
                    venuePreviewGameFilter = .all
                    viewModel.selectedBar = bar
                }
            }
        }
    }
    .sheet(isPresented: Binding(
        get: { showVenueDetails && viewModel.isLoggedIn && viewModel.selectedBar != nil },
        set: { if !$0 { showVenueDetails = false } }
    )) {
            if let selectedBar = viewModel.selectedBar {
                VenueDetailView(
                    bar: selectedBar,
                    selectedEvent: viewModel.selectedEvent,
                    isFavorite: viewModel.favoriteVenueIDs.contains(selectedBar.id),
                    goingCount: viewModel.displayedGoingCount(for: selectedBar),
                    iconForSport: viewModel.iconForSport,
                    mergedRating: viewModel.mergedDisplayRating(for: selectedBar),
                    reviewCountText: "\(viewModel.reviewCountDisplay(for: selectedBar)) reviews",
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
                    menuPhotoURL: selectedBar.menuPhotoURL
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    .sheet(isPresented: Binding(
        get: { viewModel.isLoggedIn && selectedCommentsEventID != nil },
        set: { if !$0 { selectedCommentsEventID = nil } }
    )) {
        if viewModel.isLoggedIn, let eventID = selectedCommentsEventID {
            VenueEventCommentsSheet(
                viewModel: viewModel,
                venueEventID: eventID
            )
        }
    }
        .sheet(isPresented: Binding(
            get: { showVenueRatingSheet && viewModel.isLoggedIn && viewModel.selectedBar != nil },
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
                    }
                }
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// Discover date chip opens this overlay (not a sheet) so the map stays visible—no UIKit sheet white chrome or Calendar tab behind it.
    private var discoverMapDatePickerOverlay: some View {
        ZStack {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        showDatePicker = false
                    }
                }

            VStack {
                Spacer(minLength: 0)
                LiquidGlassCalendarPicker(
                    events: viewModel.events,
                    bars: viewModel.bars,
                    useVisibleMapRegionOnly: viewModel.calendarUsesVisibleMapRegionOnly,
                    eventDotDates: viewModel.calendarDotDates,
                    dotsLoading: viewModel.isLoadingMapVenues && viewModel.calendarUsesVisibleMapRegionOnly,
                    selectedDate: $viewModel.selectedDate
                ) {
                    withAnimation(.spring()) {
                        viewModel.dateChanged()
                    }
                    showDatePicker = false
                }
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

    /// Map pins and venue cards use the same day + sport + search rules as the bottom summary (`filteredBars`).
    private var discoverMapDayEvents: [SportsEvent] {
        viewModel.eventsForSelectedDate
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
    private func singleVenueMapPinButton(bar: BarVenue, dayEvents: [SportsEvent]) -> some View {
        let gamesToday = dayEvents.filter { bar.games.contains($0.title) }
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
                switch effectiveMode {
                case .simple:
                    simpleMapPin(bar: bar, gamesToday: gamesToday)

                case .compact:
                    compactMapPin(bar: bar, gamesToday: gamesToday, goingTotal: goingTotal)

                case .detailed:
                    detailedMapPin(bar: bar, gamesToday: gamesToday, goingTotal: goingTotal)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func multiVenueClusterAnnotation(cluster: VenueCluster, dayEvents: [SportsEvent]) -> some View {
        let energy = viewModel.clusterVenueAnnotationEnergy(cluster: cluster, dayEvents: dayEvents)
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
                dominantSport: energy.dominantSport
            )
        }
        .buttonStyle(.plain)
    }

    private var mapLayer: some View {
        let dayEvents = discoverMapDayEvents
        return Map(position: $viewModel.cameraPosition) {
            UserAnnotation()

            ForEach(viewModel.clusteredBars()) { cluster in
                Annotation(
                    cluster.count == 1 ? cluster.bars.first?.name ?? "Venue" : "\(cluster.count) venues",
                    coordinate: cluster.coordinate
                ) {
                    if cluster.count == 1, let bar = cluster.bars.first {
                        singleVenueMapPinButton(bar: bar, dayEvents: dayEvents)
                    } else {
                        multiVenueClusterAnnotation(cluster: cluster, dayEvents: dayEvents)
                    }
                }
            }
        }
        .mapControls {
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
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
            && viewModel.visibleBarCountInCurrentMapRegion() > 0
    }

    private var topControlArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                
                TextField("Search venue, city, state, or country", text: $viewModel.searchText)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit {
                        viewModel.searchMapLocation()
                    }
                
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    viewModel.cameraPosition = .userLocation(
                        followsHeading: false,
                        fallback: .region(
                            MKCoordinateRegion(
                                center: CLLocationCoordinate2D(latitude: 40.3916, longitude: -111.8508),
                                span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
                            )
                        )
                    )
                } label: {
                    Image(systemName: "location.fill")
                        .foregroundStyle(.blue)
                }
            }
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            if showDiscoverVisibleSearchEmptyHint {
                Text("No visible venues match. Zoom out or search this area.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            if !viewModel.venueSearchResults.isEmpty {
                VStack(spacing: 8) {
                    ForEach(viewModel.venueSearchResults.prefix(4)) { bar in
                        Button {
                            withAnimation(.spring()) {
                                venuePreviewGameFilter = .all
                                viewModel.selectVenueFromDiscoverSearchResult(bar)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundStyle(.red)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bar.name)
                                        .font(.subheadline)
                                        .fontWeight(.bold)
                                        .foregroundStyle(.black)

                                    Text(bar.address)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {

                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                            showDatePicker = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                            Text(viewModel.formattedSelectedDate)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.regularMaterial)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                    }
                    ForEach(viewModel.sports, id: \.self) { sport in
                        SportFilterChip(
                            sport: sport,
                            isSelected: viewModel.selectedSport == sport
                        ) {
                            withAnimation(.spring()) {
                                viewModel.sportChanged(to: sport)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
    
    private var adBanner: some View {
        HStack(spacing: 10) {
            Text("Ad")
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black)
                .foregroundStyle(.white)
                .clipShape(Capsule())

            Text("Game-night specials from NBA, NFL, Microsoft or local venues")
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)

            Spacer()


            Image(systemName: "megaphone.fill")
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private var nearbySummaryCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(viewModel.selectedEvent?.title ?? "GameON")
                    .font(.headline)
                
                Text(
                    viewModel.filteredBars.isEmpty
                        ? ((viewModel.isLoadingMapVenues || viewModel.isLoadingEvents) && !viewModel.discoverSnapshotRestoredThisLaunch
                            ? "Loading venues…"
                            : "0 venues match your selection")
                        : "\(viewModel.filteredBars.count) venues match your selection"
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Image(systemName: viewModel.filteredBars.isEmpty ? "exclamationmark.circle.fill" : "map.fill")
                .font(.title2)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22))
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in to see what's happening")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)

                    Text("Create a free account to view games, fan updates, ratings, and live venue details.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.spring()) {
                        viewModel.selectedBar = nil
                        pendingResumeVenueIDAfterLogin = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 4) {
                Text(bar.name)
                    .font(.headline)
                    .fontWeight(.bold)
                Text(teaserAreaDescription(for: bar))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Button {
                    pendingResumeVenueIDAfterLogin = bar.id
                    viewModel.discoverNavigateToAccountForUserAuth = true
                } label: {
                    Text("Sign in or create account")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.black.opacity(0.9))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring()) {
                        viewModel.selectedBar = nil
                        pendingResumeVenueIDAfterLogin = nil
                    }
                } label: {
                    Text("Not now")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(maxHeight: 360)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 10)
    }
    
    /// Venue image, name, address, actions, rating, and experience — stays fixed while games scroll (sports are per game card only).
    @ViewBuilder
    private func venuePreviewCardStaticHeader(bar: BarVenue) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {

                barThumbnail(bar)

                VStack(alignment: .leading, spacing: 5) {
                    Text(bar.name)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)

                    Button {
                        viewModel.openDirections(to: bar)
                    } label: {
                        HStack(spacing: 5) {
                            Text(bar.address)
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Image(systemName: "location.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
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
                        .foregroundStyle(viewModel.favoriteVenueIDs.contains(bar.id) ? .red : .secondary)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring()) {
                        viewModel.selectedBar = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                if !bar.distance.isEmpty {
                    Label(bar.distance, systemImage: "location.fill")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showVenueRatingSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        Text(String(format: "%.1f", viewModel.mergedDisplayRating(for: bar)))
                            .fontWeight(.bold)
                        Text("(\(viewModel.reviewCountDisplay(for: bar)))")
                            .foregroundStyle(.secondary)
                            .fontWeight(.medium)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }

            if let experience = viewModel.experience(for: bar) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(experience.atmosphere)
                        .font(.subheadline)
                        .fontWeight(.bold)

                    Text(experience.teamFanbases.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Label(
                            experience.hasAudio ? "Game audio" : "No audio",
                            systemImage: experience.hasAudio ? "speaker.wave.2.fill" : "speaker.slash.fill"
                        )
                        Label(experience.liveOccupancy, systemImage: "person.3.fill")
                        Text(experience.coverCharge)
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
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

        return VStack(alignment: .leading, spacing: 12) {
            venuePreviewCardStaticHeader(bar: resolved)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if let selectedEvent = viewModel.selectedEvent {
                        selectedEventSection(bar: resolved, selectedEvent: selectedEvent)
                    } else {
                        gamesListSection(bar: resolved, gamesToday: gamesToday)
                    }

                    Button {
                        showVenueDetails = true
                    } label: {
                        Text("Details")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.black.opacity(0.88))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 248)
            .clipped()
        }
        .padding()
        .frame(maxHeight: 420)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 10)
        .onChange(of: viewModel.selectedBar?.id) { oldId, newId in
            guard oldId != newId else { return }
            venuePreviewGameFilter = .all
        }
        .task(id: resolved.id) {
            await viewModel.prefetchDiscoverVenueImages(for: resolved, includeMenu: false)
            guard viewModel.isLoggedIn else { return }
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
                if viewModel.isInterestedInVenueEvent(venueEventID) {
                    await viewModel.removeInterestInVenueEvent(venueEventID: venueEventID)

                    await MainActor.run {
                        viewModel.removeInterested(in: bar, gameTitle: selectedEvent.title)
                    }
                } else {
                    await viewModel.markInterestedInVenueEvent(venueEventID: venueEventID)

                    await MainActor.run {
                        viewModel.markInterested(in: bar, gameTitle: selectedEvent.title)
                    }

                    await viewModel.addGameToCalendar(
                        title: selectedEvent.title,
                        date: selectedEvent.date,
                        location: bar.address
                    )
                }
                await viewModel.loadVisibleVenueEventInterests()
            }
        }
    }
    
    private func selectedEventSection(bar: BarVenue, selectedEvent: SportsEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Showing")
                .font(.caption)
                .foregroundStyle(.secondary)
            gameInterestRow(bar: bar, event: selectedEvent)
        }
    }
    
    private func gamesListSection(bar: BarVenue, gamesToday: [SportsEvent]) -> some View {
        let filtered = gamesFilteredForVenuePreview(bar: bar, gamesToday: gamesToday, filter: venuePreviewGameFilter)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Showing")
                .font(.caption)
                .foregroundStyle(.secondary)

            venuePreviewGameFilterPicker

            if viewModel.isLoadingEvents {
                loadingVenueGamesView
            } else if gamesToday.isEmpty {
                venuePreviewNoGamesForDateView
            } else if filtered.isEmpty {
                venueGameFilterEmptyView()
            } else {
                ForEach(Array(filtered.prefix(12)), id: \.id) { event in
                    gameInterestRow(bar: bar, event: event)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: venuePreviewGameFilter)
    }

    private var venuePreviewGameFilterPicker: some View {
        HStack(spacing: 2) {
            ForEach(VenuePreviewGameFilter.allCases) { mode in
                let isOn = venuePreviewGameFilter == mode
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        venuePreviewGameFilter = mode
                    }
                } label: {
                    Text(mode.segmentTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.88))
                        .background(
                            Capsule(style: .continuous)
                                .fill(isOn ? Color.black : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
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
        Text("No games match this filter.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var venuePreviewNoGamesForDateView: some View {
        Text("No games scheduled for this date.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
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
    
    private func sportIconCircle(sport: String) -> some View {
        let color = viewModel.colorForSport(sport)
        return Image(systemName: viewModel.iconForSport(sport))
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(Circle().fill(color))
            .accessibilityLabel(sport)
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
                sportIconCircle(sport: event.sport)

                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)

                    Text("\(event.date.formatted(date: .abbreviated, time: .omitted)) · \(viewModel.displayTime(for: event))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("\(count) interested / going")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)

                    if let venueEventID,
                       let topVibe = topVibeText(for: venueEventID) {
                        Text(topVibe)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.orange)
                    }

                    if let label = trendingLabel(for: score) {
                        HStack(spacing: 8) {
                            Text(label)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(score >= 40 ? Color.purple.opacity(0.15) : Color.orange.opacity(0.12))
                                )
                            Text("Score \(score)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 8)

                Button {
                    guard viewModel.canMarkInterest else { return }
                    toggleSupabaseInterest(for: bar, selectedEvent: event)
                } label: {
                    Text(!viewModel.canMarkInterest ? "Login" : (alreadyInterested ? "Going" : "I’m going"))
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(!viewModel.canMarkInterest ? Color.gray.opacity(0.35) : (alreadyInterested ? Color.green : Color.black))
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
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
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
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.85)

            Text("Loading venue games...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
        
    
    private func clusterMapPin(cluster: VenueCluster, maxEnergy: Int, dominantSport: String?) -> some View {
        let caption = viewModel.mapClusterEnergyCaption(maxScore: maxEnergy)
        return VStack(spacing: 3) {
            if let sport = dominantSport, maxEnergy > 0 {
                Image(systemName: viewModel.iconForSport(sport))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(viewModel.colorForSport(sport))
                    .padding(5)
                    .background(Circle().fill(Color.white.opacity(0.95)))
            }

            Text("\(cluster.count)")
                .font(.headline)
                .fontWeight(.bold)

            Text("venues")
                .font(.caption2)
                .fontWeight(.bold)

            if maxEnergy > 0 {
                Text("\(maxEnergy)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.yellow.opacity(0.95))
            }

            if let caption {
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
        .background(Circle().fill(Color.black).shadow(radius: 7))
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
