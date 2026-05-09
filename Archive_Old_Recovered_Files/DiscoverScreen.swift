import SwiftUI
import MapKit

/// Primary map experience: search, date strip, clustered annotations, venue preview, and sheets for detail, comments, and vibes.
struct DiscoverScreen: View {

    @ObservedObject var viewModel: MapViewModel
    @State private var showVenueDetails = false
    @State private var showDatePicker = false
    @State private var selectedCommentsEventID: UUID?
    @State private var mapVenueReloadTask: Task<Void, Never>?
    @State private var lastMapVenueReloadRegion: MKCoordinateRegion?
    private let livePulseThreshold = 16

    
    
    var body: some View {
        ZStack {
            mapLayer
            
            VStack(spacing: 12) {
                adBanner
                topControlArea
                Spacer()
                
                if let selectedBar = viewModel.selectedBar {
                    venuePreviewCard(selectedBar)
                } else {
                    nearbySummaryCard
                }
            }
            .padding(.horizontal)
            .padding(.top, 14)
            .padding(.bottom, 85)
           
            
        }
    .task {
        await viewModel.loadVisibleVenueEventInterests()
    }
    .sheet(isPresented: $showVenueDetails) {
            if let selectedBar = viewModel.selectedBar {
                VenueDetailView(
                    bar: selectedBar,
                    selectedEvent: viewModel.selectedEvent,
                    isFavorite: viewModel.favoriteVenueIDs.contains(selectedBar.id),
                    goingCount: viewModel.displayedGoingCount(for: selectedBar),
                    iconForSport: viewModel.iconForSport,
                    onDirections: { viewModel.openDirections(to: selectedBar) },
                    onCall: { viewModel.callVenue(selectedBar) },
                    onFavorite: { viewModel.toggleFavorite(selectedBar) },
                    experience: viewModel.experience(for: selectedBar),
                    coverPhotoURL: selectedBar.coverPhotoURL,
                    menuPhotoURL: selectedBar.menuPhotoURL
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    .sheet(isPresented: Binding(
        get: { selectedCommentsEventID != nil },
        set: { if !$0 { selectedCommentsEventID = nil } }
    )) {
        if let eventID = selectedCommentsEventID {
            VenueEventCommentsSheet(
                viewModel: viewModel,
                venueEventID: eventID
            )
        }
    }
        .sheet(isPresented: $showDatePicker) {
            EventCalendarView(
                events: viewModel.events,
                bars: viewModel.bars,
                useVisibleMapRegionOnly: viewModel.calendarUsesVisibleMapRegionOnly,
                selectedDate: $viewModel.selectedDate
            ) {
                withAnimation(.spring()) {
                    viewModel.selectedBar = nil
                    viewModel.selectedEvent = nil
                    viewModel.selectedBar = nil
                    viewModel.selectedEvent = nil
                    viewModel.loadGamesFromSupabase()
                    showDatePicker = false
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(1000)
            .presentationDetents([.height(650)])
            .presentationDragIndicator(.visible)
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

    /// Events on `viewModel.selectedDate` only (same rules as `gamesForSelectedDate(at:)` date half — not `eventsForSelectedDate`).
    private var eventsOnSelectedDateForMap: [SportsEvent] {
        viewModel.events.filter {
            Calendar.current.isDate($0.date, inSameDayAs: viewModel.selectedDate)
        }
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

        Button {
            withAnimation(.spring()) {
                viewModel.centerMap(on: bar)
            }

            Task {
                if let firstGame = gamesToday.first,
                   let venueEventID = await viewModel.venueEventID(for: bar, gameTitle: firstGame.title) {
                    await viewModel.loadGoingUserProfiles(for: venueEventID)
                }
            }
        } label: {
            Group {
                switch viewModel.mapPinDisplayMode {
                case .simple:
                    simpleMapPin(bar: bar, gamesToday: gamesToday)

                case .compact:
                    compactMapPin(bar: bar, gamesToday: gamesToday, goingTotal: goingTotal)

                case .detailed:
                    detailedMapPin(bar: bar, gamesToday: gamesToday, goingTotal: goingTotal)
                }
            }
        }
    }

    private var mapLayer: some View {
        let dayEvents = eventsOnSelectedDateForMap
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
                        Button {
                            withAnimation(.spring()) {
                                viewModel.cameraPosition = .region(
                                    MKCoordinateRegion(
                                        center: cluster.coordinate,
                                        span: MKCoordinateSpan(
                                            latitudeDelta: max(viewModel.visibleLatitudeDelta / 2.5, 0.04),
                                            longitudeDelta: max(viewModel.visibleLatitudeDelta / 2.5, 0.04)
                                        )
                                    )
                                )
                            }
                        } label: {
                            clusterMapPin(cluster)
                        }
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
            
        
            if !viewModel.venueSearchResults.isEmpty {
                VStack(spacing: 8) {
                    ForEach(viewModel.venueSearchResults.prefix(4)) { bar in
                        Button {
                            withAnimation(.spring()) {
                                viewModel.centerMap(on: bar)
                                viewModel.selectedBar = bar
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
                        showDatePicker = true
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
                        Button {
                            withAnimation(.spring()) {
                                viewModel.sportChanged(to: sport)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if sport != "All" {
                                    Image(systemName: viewModel.iconForSport(sport))
                                }
                                Text(sport)
                            }
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .foregroundStyle(viewModel.selectedSport == sport ? Color.white : Color.primary)
                            .background(viewModel.selectedSport == sport ? AnyShapeStyle(Color.black) : AnyShapeStyle(.regularMaterial))
                            .clipShape(Capsule())
                        }
                    }
                }
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
                
                Text(viewModel.filteredBars.isEmpty ? "No venues match your selection" : "\(viewModel.filteredBars.count) venues match your selection")
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
    
    private func venuePreviewCard(_ bar: BarVenue) -> some View {
        let dayEvents = eventsOnSelectedDateForMap
        let gamesToday = dayEvents.filter { bar.games.contains($0.title) }
        let previewGoingTotal = goingInterestTotal(gamesToday: gamesToday, bar: bar)

        return VStack(alignment: .leading, spacing: 14) {

            HStack(alignment: .top, spacing: 12) {

                barThumbnail(bar)

                VStack(alignment: .leading, spacing: 5) {
                    Text(bar.name)
                        .font(.title3)
                        .fontWeight(.bold)

                    Button {
                        viewModel.openDirections(to: bar)
                    } label: {
                        HStack(spacing: 5) {
                            Text(bar.address)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Image(systemName: "location.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }

                Spacer()

                Button {
                    viewModel.toggleFavorite(bar)
                } label: {
                    Image(systemName: viewModel.favoriteVenueIDs.contains(bar.id) ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(viewModel.favoriteVenueIDs.contains(bar.id) ? .red : .secondary)
                }

                Button {
                    withAnimation(.spring()) {
                        viewModel.selectedBar = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Label(bar.distance, systemImage: "location.fill")
                Label(String(format: "%.1f", bar.rating), systemImage: "star.fill")
                Label(bar.primarySport, systemImage: viewModel.iconForSport(bar.primarySport))
            }
            .font(.caption)
            .fontWeight(.semibold)

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

            if let selectedEvent = viewModel.selectedEvent {
                selectedEventSection(bar: bar, selectedEvent: selectedEvent)
            } else {
                gamesListSection(bar: bar, gamesToday: gamesToday)
            }
            attendeePreviewRow(goingCount: previewGoingTotal)

            Button {
                showVenueDetails = true
            } label: {
                Text("Details")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.primary.opacity(0.10))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(radius: 10)
    }

    private func goingInterestTotal(gamesToday: [SportsEvent], bar: BarVenue) -> Int {
        gamesToday.reduce(0) { total, game in
            if let id = viewModel.cachedVenueEventID(for: bar, gameTitle: game.title) {
                return total + viewModel.interestCountForVenueEvent(id)
            }
            return total
        }
    }
    
    private func barThumbnail(_ bar: BarVenue) -> some View {
        Group {
            if let urlString = bar.coverPhotoURL,
               let url = URL(string: urlString),
               !urlString.isEmpty {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
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
    
    private func attendeeText(count: Int) -> String {
        if count <= 0 {
            return "Be the first"
        }

        let names = viewModel.goingUserProfiles
            .compactMap { $0.display_name }
            .filter { !$0.isEmpty }

        if names.count >= 2 {
            return "\(names[0]), \(names[1]) + \(max(count - 2, 0)) others"
        }

        if names.count == 1 {
            return count > 1 ? "\(names[0]) + \(count - 1) others" : names[0]
        }

        return "\(count) people"
    }
    
    private func attendeePreviewRow(goingCount: Int) -> some View {
        HStack(spacing: 12) {

            GoingAvatarStack(profiles: viewModel.goingUserProfiles)

            VStack(alignment: .leading, spacing: 2) {
                Text(attendeeText(count: goingCount))
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("are going")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color.white.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func latestCommentPreview(for venueEventID: UUID) -> some View {
        let comments = viewModel.venueEventComments[venueEventID] ?? []

        let latestComment = comments.last
        let latestText = latestComment?.comment ?? "No recent updates yet"

        let latestName: String = {
            guard let email = latestComment?.user_email else {
                return "Fan"
            }

            if let profile = viewModel.userProfilesByEmail[email],
               let name = profile.display_name,
               !name.isEmpty {
                return name
            }

            return "Fan"
        }()

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bubble.left.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text("🔥 \(comments.count) live updates")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)

                Text("\(latestName): “\(latestText)”")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
    
    private func selectedEventSection(bar: BarVenue, selectedEvent: SportsEvent) -> some View {
        let venueEventID = viewModel.cachedVenueEventID(
            for: bar,
            gameTitle: selectedEvent.title
        )

        let isInterested = venueEventID.map {
            viewModel.isInterestedInVenueEvent($0)
        } ?? false

        let count = venueEventID.map {
            viewModel.interestCountForVenueEvent($0)
        } ?? 0

        return VStack(alignment: .leading, spacing: 8) {
            Label("\(count) people interested / going", systemImage: "person.3.fill")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.green)

            Text("Showing: \(selectedEvent.title)")
                .font(.subheadline)
                .fontWeight(.bold)

            Button {
                toggleSupabaseInterest(for: bar, selectedEvent: selectedEvent)
            } label: {
                Label(
                    isInterested ? "Interested in this event" : "I’m interested in going",
                    systemImage: isInterested ? "checkmark.circle.fill" : "person.badge.plus"
                )
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .padding()
                .background(isInterested ? Color.green : Color.black)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .task {
            _ = await viewModel.venueEventID(
                for: bar,
                gameTitle: selectedEvent.title
            )

            await viewModel.loadVisibleVenueEventInterests()
        }
    }
    
    private func gamesListSection(bar: BarVenue, gamesToday: [SportsEvent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Showing")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.isLoadingEvents {
                loadingVenueGamesView
            } else if gamesToday.isEmpty {
                noVenueGamesView
            } else {
                ForEach(gamesToday.prefix(3), id: \.id) { game in
                    gameInterestRow(bar: bar, game: game.title)
                }
            }
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
    
    private func gameInterestRow(bar: BarVenue, game: String) -> some View {
        let venueEventID = viewModel.cachedVenueEventID(for: bar, gameTitle: game)

        let alreadyInterested = venueEventID.map {
            viewModel.isInterestedInVenueEvent($0)
        } ?? false

        let count = venueEventID.map {
            viewModel.interestCountForVenueEvent($0)
        } ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.blue)

                    Text("\(count) people interested / going")
                        .font(.caption)
                        .foregroundStyle(.green)
                    if let venueEventID,
                       let topVibe = topVibeText(for: venueEventID) {
                        Text(topVibe)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.orange)
                    }
                    if let venueEventID {
                        let score = trendingScore(for: venueEventID, goingCount: count)

                        if let label = trendingLabel(for: score) {
                            Text(label)
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(
                                    score >= 40 ? .purple :
                                    score >= 16 ? .orange :
                                    score >= 6 ? .red :
                                    .green
                                )
                        }
                    }
                }

                Spacer()

                Button {
                    guard viewModel.canMarkInterest else { return }

                    if let matchingEvent = viewModel.events.first(where: { $0.title == game }) {
                        toggleSupabaseInterest(for: bar, selectedEvent: matchingEvent)
                    }
                } label: {
                    Text(!viewModel.canMarkInterest ? "Login required" : (alreadyInterested ? "Going" : "I’m going"))
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

            if let venueEventID {
                VenueEventVibeMeterView(
                    viewModel: viewModel,
                    venueEventID: venueEventID
                )

                Button {
                    selectedCommentsEventID = venueEventID
                } label: {
                    latestCommentPreview(for: venueEventID)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task {
            if let id = await viewModel.venueEventID(for: bar, gameTitle: game) {
                await viewModel.loadComments(for: id)
                await viewModel.loadVibes(for: id)

                let emails = (viewModel.venueEventComments[id] ?? [])
                    .compactMap { $0.user_email }

                await viewModel.loadUserProfilesForEmails(emails)
            }

            await viewModel.loadVisibleVenueEventInterests()
        }
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
    
    private var noVenueGamesView: some View {
        Text("No games scheduled for this day")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14))
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
        gamesToday.reduce(0) { total, game in
            guard let id = viewModel.cachedVenueEventID(for: bar, gameTitle: game.title) else {
                return total
            }

            let going = viewModel.interestCountForVenueEvent(id)
            let comments = viewModel.venueEventComments[id]?.count ?? 0
            let vibes = viewModel.venueEventVibeCounts[id]?.values.reduce(0, +) ?? 0

            return total + going + comments + vibes
        }
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
        
    
    private func clusterMapPin(_ cluster: VenueCluster) -> some View {
        VStack(spacing: 3) {
            Text("\(cluster.count)")
                .font(.headline)
                .fontWeight(.bold)

            Text("venues")
                .font(.caption2)
                .fontWeight(.bold)
        }
        .foregroundStyle(.white)
        .frame(width: 58, height: 58)
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
        default:
            return nil
        }
    }
    
}
