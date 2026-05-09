import SwiftUI
import PhotosUI

// MARK: - Venue analytics locally hidden events
//
// TODO: Persist hides in Supabase with `venue_hidden_analytics_events` (venue_owner_id, venue_event_id,
// created_at) and RLS so owners can manage their own rows. Until then, hides survive relaunch via UserDefaults.

private enum VenueOwnerAnalyticsHiddenEventsLocalStore {
    private static let defaultsKeyPrefix = "VenueOwnerAnalyticsHiddenEventIDs."

    static func load(ownerEmail: String) -> Set<UUID> {
        let key = defaultsKeyPrefix + ownerEmail.lowercased()
        guard let arr = UserDefaults.standard.array(forKey: key) as? [String] else { return [] }
        return Set(arr.compactMap(UUID.init))
    }

    static func save(ownerEmail: String, ids: Set<UUID>) {
        let key = defaultsKeyPrefix + ownerEmail.lowercased()
        UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: key)
    }
}

private struct VenueOwnerAnalyticsDetailSelection: Identifiable {
    let id: UUID
    let row: VenueEventRow
}

/// Which slice of the venue owner dashboard Settings (or other callers) presents.
enum VenueOwnerDashboardEntryPoint: Equatable {
    /// Profile, games, and analytics tabs (legacy / rare).
    case allTabs
    /// Settings → Manage Venue: venue profile, address, photos, features only.
    case profileEditor
    /// Settings → Manage Games: add / edit / cancel venue games.
    case gamesManager
    /// Settings → Statistics: engagement analytics only.
    case analyticsViewer
}

struct VenueOwnerDashboardView: View {
    @ObservedObject var viewModel: MapViewModel
    var entryPoint: VenueOwnerDashboardEntryPoint = .allTabs

    @State private var selectedSection: VenueDashboardSection = .profile

    @State private var gameTitle = ""
    @State private var gameSpecial = ""
    @State private var soundOn = true
    @State private var coverCharge = ""
    @State private var seating = ""
    @State private var teamFanbase = ""
    @State private var socialCoordination = ""
    @State private var gameDate = Date()
    @State private var gameStartTime = Date()
    @State private var numberOfTVs = 1
    @State private var crowdLevel = "Moderate"
    @State private var liveOccupancy = "Open seats"
    @State private var reservationsAvailable = false
    @State private var waitlistAvailable = false
    @State private var showSpecialsFields = false
    @State private var hasFood = false
    @State private var hasWifi = false
    @State private var hasGarden = false
    @State private var hasProjector = false
    @State private var isPetFriendly = false
    /// Local-only until Supabase venue profile exposes matching columns (not sent in ``saveVenueProfile``).
    @State private var hasParkingAvailable = false
    @State private var hasEasyParking = false
    @State private var isFamilyFriendly = false
    @State private var totalScreens = 1
    @State private var profileSaveMessage = ""
    @State private var venueStreetAddress = ""
    @State private var venueCity = ""
    @State private var venueState = "UT"
    @State private var venueZipCode = ""
    @State private var selectedCoverPhoto: PhotosPickerItem?
    @State private var selectedMenuPhoto: PhotosPickerItem?
    /// URLs used only for Bar/Menu previews (may include `?v=` / `&v=` cache bust). Supabase / viewModel URLs stay clean.
    @State private var displayedCoverPhotoURL = ""
    @State private var displayedMenuPhotoURL = ""
    @State private var analyticsGames: [VenueEventRow] = []
    @State private var analyticsIsLoading = false
    @State private var analyticsDatePreset: VenueAnalyticsDatePreset = .thisMonth
    @State private var analyticsSportFilter: String = "All"
    @State private var analyticsCustomStart = Date()
    @State private var analyticsCustomEnd = Date()
    @State private var analyticsHiddenEventIDs: Set<UUID> = []
    @State private var analyticsDetailSelection: VenueOwnerAnalyticsDetailSelection?

    private enum VenueAnalyticsDatePreset: String, CaseIterable {
        case today = "Today"
        case thisWeek = "This week"
        case thisMonth = "This month"
        case all = "All"
        case custom = "Custom"
    }

    private enum ManageGamesListTab: Int, CaseIterable {
        case games = 0
        case add = 1
    }

    @State private var manageGamesListTab: ManageGamesListTab = .games
    @State private var didPickInitialManageGamesTab = false
    @State private var myVenueGamesForManage: [VenueEventRow] = []
    @State private var manageGamesListLoading = false
    @State private var manageGamesFeedback = ""
    @State private var manageGamesError = ""
    @State private var isSavingNewGame = false
    @State private var titleEditTarget: VenueOwnerGameTitleEditTarget?
    @State private var titleEditDraft = ""
    @State private var pendingCancelGameID: UUID?
    @State private var pendingCancelGameTitle = ""

    enum VenueDashboardSection: String, CaseIterable {
        case profile = "Profile"
        case games = "Games"
        case analytics = "Analytics"
    }

    private var effectiveSection: VenueDashboardSection {
        switch entryPoint {
        case .allTabs:
            return selectedSection
        case .profileEditor:
            return .profile
        case .gamesManager:
            return .games
        case .analyticsViewer:
            return .analytics
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {

                header

                if entryPoint == .allTabs {
                    sectionPicker
                }

                Group {
                    switch effectiveSection {
                    case .profile:
                        profileSection
                    case .games:
                        gamesSection
                    case .analytics:
                        venueAnalyticsSection
                    }
                }
                // Force a fresh subtree when the entry point or active tab changes so a prior section’s
                // SwiftUI state cannot remain mounted under the venue profile editor sheet.
                .id("\(String(describing: entryPoint))-\(effectiveSection.rawValue)")
            }
            .padding()
        }
        .background(Color.black.opacity(0.94))
        .onAppear {
            if entryPoint != .analyticsViewer {
                Task {
                    await viewModel.stopVenueOwnerAnalyticsRealtime()
                }
            }
        }
        .onChange(of: selectedSection) { _, newValue in
            guard entryPoint == .allTabs else { return }
            if newValue != .analytics {
                Task {
                    await viewModel.stopVenueOwnerAnalyticsRealtime()
                }
            }
        }
        .onDisappear {
            Task {
                await viewModel.stopVenueOwnerAnalyticsRealtime()
            }
        }
        .task(id: effectiveSection) {
            if effectiveSection == .analytics {
                await loadVenueAnalytics()
            }
        }
        .task {
            if let saved = await viewModel.loadVenueProfile() {

                viewModel.ownerVenueName = saved.venue_name ?? ""
                viewModel.ownerVenuePhone = saved.phone ?? ""
                viewModel.ownerVenueWebsite = saved.website ?? ""

                venueStreetAddress = saved.address ?? ""
                venueCity = saved.city ?? ""
                venueState = saved.state ?? "UT"
                venueZipCode = saved.zip_code ?? ""

                totalScreens = saved.screen_count ?? 1
                hasFood = saved.serves_food ?? false
                hasWifi = saved.has_wifi ?? false
                hasGarden = saved.has_garden ?? false
                hasProjector = saved.has_projector ?? false
                isPetFriendly = saved.pet_friendly ?? false

                viewModel.venueCoverPhotoURL = saved.cover_photo_url ?? ""
                viewModel.venueMenuPhotoURL = saved.menu_photo_url ?? ""
                viewModel.venueCoverPhotoThumbnailURL = saved.cover_photo_thumbnail_url ?? ""
                viewModel.venueMenuPhotoThumbnailURL = saved.menu_photo_thumbnail_url ?? ""
            }
            syncDisplayedVenuePhotoURLsFromViewModel()
        }
        
        .onChange(of: selectedCoverPhoto) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let url = await viewModel.uploadVenuePhoto(data: data, fileName: "cover.jpg") {
                    await MainActor.run {
                        viewModel.venueCoverPhotoURL = url
                        displayedCoverPhotoURL = venuePhotoURLWithCacheBust(url)
                        profileSaveMessage = "Cover photo uploaded. Tap Save Profile to save changes."
                    }
                }
            }
        }
        .onChange(of: selectedMenuPhoto) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let url = await viewModel.uploadVenuePhoto(data: data, fileName: "menu.jpg") {
                    await MainActor.run {
                        viewModel.venueMenuPhotoURL = url
                        displayedMenuPhotoURL = venuePhotoURLWithCacheBust(url)
                        profileSaveMessage = "Menu photo uploaded. Tap Save Profile to save changes."
                    }
                }
            }
        }
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headerTitle)
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(.white)

            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var headerTitle: String {
        switch entryPoint {
        case .profileEditor:
            return "Venue details"
        case .gamesManager:
            return "Manage games"
        case .analyticsViewer:
            return "Venue Analytics"
        case .allTabs:
            return "Venue Dashboard"
        }
    }

    private var headerSubtitle: String {
        switch entryPoint {
        case .profileEditor:
            return "Address, photos, TVs, seating, and venue information."
        case .gamesManager:
            return "Add, edit, or cancel games shown at your venue."
        case .analyticsViewer:
            return "Live engagement by game."
        case .allTabs:
            return "Manage your bar profile, game schedule, specials, and game-day experience."
        }
    }
    
    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(VenueDashboardSection.allCases, id: \.self) { section in
                    Button {
                        withAnimation(.spring()) {
                            selectedSection = section
                        }
                    } label: {
                        Text(section.rawValue)
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(selectedSection == section ? Color.white : Color.white.opacity(0.15))
                            .foregroundStyle(selectedSection == section ? .black : .white)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }
    
    private var profileSection: some View {
        dashboardCard(title: "Venue Profile", subtitle: "Basic business information") {
            field("Bar / Pub / Restaurant Name", text: $viewModel.ownerVenueName)
            field("Street Address", text: $venueStreetAddress)
            field("City", text: $venueCity)

            Picker("State", selection: $venueState) {
                ForEach(usStates, id: \.self) { state in
                    Text(state).tag(state)
                }
            }
            .pickerStyle(.menu)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            field("ZIP Code", text: $venueZipCode)
            field("Phone", text: $viewModel.ownerVenuePhone)
            field("Website", text: $viewModel.ownerVenueWebsite)
            field("Short Description", text: $viewModel.ownerVenueDescription)
            field("Features: Big Screens, Patio, Sound On", text: $viewModel.ownerVenueFeatures)

            VStack(alignment: .leading, spacing: 28) {
                venueOwnerVenueFeaturesCard()

                venueProfilePhotoEditor(
                    title: "Bar Photo",
                    subtitle: "Main photo of your venue",
                    fullImageURL: displayedCoverPhotoURL,
                    thumbnailURL: venuePhotoPreviewURL(
                        storageURL: viewModel.venueCoverPhotoThumbnailURL,
                        displayTemplateURL: displayedCoverPhotoURL
                    ),
                    selection: $selectedCoverPhoto
                )

                venueProfilePhotoEditor(
                    title: "Menu Photo",
                    subtitle: "Food or drink menu photo",
                    fullImageURL: displayedMenuPhotoURL,
                    thumbnailURL: venuePhotoPreviewURL(
                        storageURL: viewModel.venueMenuPhotoThumbnailURL,
                        displayTemplateURL: displayedMenuPhotoURL
                    ),
                    selection: $selectedMenuPhoto
                )

                Button {
                    profileSaveMessage = "Saving..."

                    viewModel.ownerVenueAddress = "\(venueStreetAddress), \(venueCity), \(venueState) \(venueZipCode)"
                    Task {
                        let success = await viewModel.saveVenueProfile(
                            streetAddress: venueStreetAddress,
                            city: venueCity,
                            state: venueState,
                            zipCode: venueZipCode,
                            screenCount: totalScreens,
                            servesFood: hasFood,
                            hasWifi: hasWifi,
                            hasGarden: hasGarden,
                            hasProjector: hasProjector,
                            petFriendly: isPetFriendly
                        )

                        await MainActor.run {
                            profileSaveMessage = success ? "Profile saved successfully" : "Unable to save profile"
                        }
                    }
                } label: {
                    primaryButtonText("Save Profile")
                }
            }

            if !profileSaveMessage.isEmpty {
                Text(profileSaveMessage)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func venueOwnerVenueFeaturesCard() -> some View {
        let columns: [GridItem] = [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]

        return VStack(alignment: .leading, spacing: 10) {
            Text("Venue Features")
                .font(.headline)
                .fontWeight(.bold)

            LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
                VenueOwnerScreensFeatureTile(totalScreens: $totalScreens)
                VenueOwnerFeatureToggleTile(icon: "fork.knife", label: "Food / Drinks", isOn: $hasFood)
                VenueOwnerFeatureToggleTile(icon: "wifi", label: "WiFi", isOn: $hasWifi)
                VenueOwnerFeatureToggleTile(icon: "chair.lounge.fill", label: "Patio", isOn: $hasGarden)
                VenueOwnerFeatureToggleTile(icon: "video.fill", label: "Projector", isOn: $hasProjector)
                VenueOwnerFeatureToggleTile(icon: "pawprint.fill", label: "Pet Friendly", isOn: $isPetFriendly)
                VenueOwnerFeatureToggleTile(icon: "car.fill", label: "Parking Available", isOn: $hasParkingAvailable)
                VenueOwnerFeatureToggleTile(icon: "parkingsign.circle.fill", label: "Easy Parking", isOn: $hasEasyParking)
                VenueOwnerFeatureToggleTile(icon: "figure.2.and.child.holdinghands", label: "Family Friendly", isOn: $isFamilyFriendly)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private let usStates = [
        "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA",
        "HI","ID","IL","IN","IA","KS","KY","LA","ME","MD",
        "MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ",
        "NM","NY","NC","ND","OH","OK","OR","PA","RI","SC",
        "SD","TN","TX","UT","VT","VA","WA","WV","WI","WY"
    ]

    private var analyticsSportFilterOptions: [String] {
        ["All"] + viewModel.sports.filter { $0 != "All" }
    }

    private var venueAnalyticsFilterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filters")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(VenueAnalyticsDatePreset.allCases, id: \.rawValue) { preset in
                        Button {
                            if preset == .custom {
                                let cal = Calendar.current
                                if let interval = cal.dateInterval(of: .month, for: Date()) {
                                    analyticsCustomStart = interval.start
                                    analyticsCustomEnd = cal.date(byAdding: .second, value: -1, to: interval.end) ?? Date()
                                }
                            }
                            analyticsDatePreset = preset
                            Task { await refreshVenueAnalyticsFilteredEngagementOnly() }
                        } label: {
                            Text(preset.rawValue)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(analyticsDatePreset == preset ? Color.black : Color.black.opacity(0.06))
                                .foregroundStyle(analyticsDatePreset == preset ? Color.white : Color.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if analyticsDatePreset == .custom {
                HStack(spacing: 10) {
                    DatePicker("From", selection: $analyticsCustomStart, displayedComponents: .date)
                        .font(.caption)
                        .labelsHidden()
                    DatePicker("To", selection: $analyticsCustomEnd, displayedComponents: .date)
                        .font(.caption)
                        .labelsHidden()
                }
                .onChange(of: analyticsCustomStart) { _, _ in
                    guard analyticsDatePreset == .custom else { return }
                    Task { await refreshVenueAnalyticsFilteredEngagementOnly() }
                }
                .onChange(of: analyticsCustomEnd) { _, _ in
                    guard analyticsDatePreset == .custom else { return }
                    Task { await refreshVenueAnalyticsFilteredEngagementOnly() }
                }
            }

            Picker("Sport", selection: $analyticsSportFilter) {
                ForEach(analyticsSportFilterOptions, id: \.self) { sport in
                    Text(sport).tag(sport)
                }
            }
            .pickerStyle(.menu)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: analyticsSportFilter) { _, _ in
                Task { await refreshVenueAnalyticsFilteredEngagementOnly() }
            }
        }
    }

    @ViewBuilder
    private func venueAnalyticsSummaryStrip(displayed: [VenueEventRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let row = hottestAnalyticsGameRow(from: displayed) {
                HStack(spacing: 8) {
                    Text("Most active")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    Text(row.event_title ?? "Game")
                        .font(.caption)
                        .fontWeight(.bold)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let id = row.id {
                        Text("\(viewModel.venueOwnerEngagementScore(venueEventID: id))")
                            .font(.caption)
                            .fontWeight(.black)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.2), value: viewModel.venueOwnerEngagementScore(venueEventID: id))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let top = globalTopVibeSummary(from: displayed) {
                HStack(spacing: 8) {
                    Text("Top vibe")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    Text(top.label)
                        .font(.caption)
                        .fontWeight(.bold)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Text("\(top.total)")
                        .font(.caption)
                        .fontWeight(.black)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var venueAnalyticsSection: some View {
        dashboardCard(
            title: "Venue Analytics",
            subtitle: "Lightweight live engagement per game — same data fans see for going, fan updates, and vibes."
        ) {
            venueAnalyticsDashboardInner()
                .sheet(item: $analyticsDetailSelection) { selection in
                    NavigationStack {
                        ScrollView {
                            VenueOwnerGameAnalyticsCard(
                                viewModel: viewModel,
                                row: selection.row,
                                eventID: selection.id,
                                isLiveToday: isGameLiveToday(selection.row)
                            )
                            .padding(.vertical, 8)
                        }
                        .navigationTitle("Game analytics")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { analyticsDetailSelection = nil }
                            }
                        }
                    }
                }
        }
    }

    private func venueAnalyticsDashboardInner() -> some View {
        let displayed = displayedVenueAnalyticsGames()

        return VStack(alignment: .leading, spacing: 12) {
            venueAnalyticsFilterBar

            if analyticsIsLoading && analyticsGames.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.black)
                    Text("Loading analytics…")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if analyticsGames.isEmpty {
                Text("No active game analytics yet.")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if !displayed.isEmpty {
                    venueAnalyticsSummaryStrip(displayed: displayed)
                }

                if displayed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No analytics for this filter.")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("Try another date or sport.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(displayed.compactMap { row -> (UUID, VenueEventRow)? in
                                guard let id = row.id else { return nil }
                                return (id, row)
                            }, id: \.0) { pair in
                                VenueOwnerCompactAnalyticsRow(
                                    viewModel: viewModel,
                                    row: pair.1,
                                    eventID: pair.0,
                                    isLiveToday: isGameLiveToday(pair.1),
                                    onTapDetail: {
                                        analyticsDetailSelection = VenueOwnerAnalyticsDetailSelection(id: pair.0, row: pair.1)
                                    }
                                )
                                .contextMenu {
                                    Button("Details") {
                                        analyticsDetailSelection = VenueOwnerAnalyticsDetailSelection(id: pair.0, row: pair.1)
                                    }
                                    Button("Hide from analytics", role: .destructive) {
                                        hideVenueEventFromAnalytics(pair.0)
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("Hide") {
                                        hideVenueEventFromAnalytics(pair.0)
                                    }
                                    .tint(.orange)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxHeight: 520)
                    .refreshable {
                        await loadVenueAnalytics()
                    }
                }
            }
        }
    }

    private func hottestAnalyticsGameRow(from rows: [VenueEventRow]) -> VenueEventRow? {
        rows.max { a, b in
            let sa = a.id.map { viewModel.venueOwnerEngagementScore(venueEventID: $0) } ?? 0
            let sb = b.id.map { viewModel.venueOwnerEngagementScore(venueEventID: $0) } ?? 0
            return sa < sb
        }
    }

    private func globalTopVibeSummary(from rows: [VenueEventRow]) -> (label: String, total: Int)? {
        var totals: [String: Int] = [:]
        for row in rows {
            guard let id = row.id else { continue }
            let m = viewModel.venueEventVibeCounts[id] ?? [:]
            for (k, v) in m {
                totals[k, default: 0] += v
            }
        }
        guard let best = totals.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return (venueOwnerVibeMetricLabel(best.key), best.value)
    }

    private func venueOwnerVibeMetricLabel(_ key: String) -> String {
        switch key {
        case "audio_on": return "🔊 Audio confirmed"
        case "packed": return "🔥 Packed"
        case "seats_open": return "🪑 Seats open"
        case "specials": return "🍺 Specials / drinks"
        case "tv_visible": return "📺 TVs visible"
        default: return key.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func isGameLiveToday(_ row: VenueEventRow) -> Bool {
        guard let d = venueOwnerGameDay(row) else { return false }
        return Calendar.current.isDateInToday(d)
    }

    private func venueOwnerGameDay(_ row: VenueEventRow) -> Date? {
        guard let s = row.event_date else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    /// Wide date window for the analytics pool (client-side filters narrow further). Capped for performance.
    private static func venueAnalyticsGamesLoadingPool(_ rows: [VenueEventRow]) -> [VenueEventRow] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let windowStart = cal.date(byAdding: .day, value: -1095, to: today),
              let windowEnd = cal.date(byAdding: .day, value: 548, to: today)
        else {
            return rows.filter { $0.id != nil }
        }
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd"

        return rows.filter { row in
            guard row.id != nil else { return false }
            guard let ds = row.event_date, let d = fmt.date(from: ds) else { return true }
            let day = cal.startOfDay(for: d)
            return day >= windowStart && day <= windowEnd
        }
    }

    private static func sortVenueAnalyticsEventsByDateDescending(_ rows: [VenueEventRow]) -> [VenueEventRow] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd"
        return rows.sorted { a, b in
            let da: Date
            if let s = a.event_date, let d = fmt.date(from: s) { da = cal.startOfDay(for: d) } else { da = .distantPast }
            let db: Date
            if let s = b.event_date, let d = fmt.date(from: s) { db = cal.startOfDay(for: d) } else { db = .distantPast }
            if da != db { return da > db }
            return (a.event_title ?? "") < (b.event_title ?? "")
        }
    }

    private func displayedVenueAnalyticsGames() -> [VenueEventRow] {
        var rows = analyticsGames.filter { row in
            guard let id = row.id else { return false }
            return !analyticsHiddenEventIDs.contains(id)
        }

        let sport = analyticsSportFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if sport != "All" {
            rows = rows.filter { ($0.sport ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == sport }
        }

        switch analyticsDatePreset {
        case .today:
            rows = rows.filter { isGameLiveToday($0) }
        case .thisWeek:
            rows = rows.filter { gameDayMatchesThisWeek($0) }
        case .thisMonth:
            rows = rows.filter { gameDayMatchesThisMonth($0) }
        case .all:
            break
        case .custom:
            rows = rows.filter { gameDayMatchesCustomRange($0) }
        }

        return rows
    }

    private func gameDayMatchesThisWeek(_ row: VenueEventRow) -> Bool {
        guard let d = venueOwnerGameDay(row) else { return false }
        return Calendar.current.isDate(d, equalTo: Date(), toGranularity: .weekOfYear)
    }

    private func gameDayMatchesThisMonth(_ row: VenueEventRow) -> Bool {
        guard let d = venueOwnerGameDay(row) else { return false }
        return Calendar.current.isDate(d, equalTo: Date(), toGranularity: .month)
    }

    private func gameDayMatchesCustomRange(_ row: VenueEventRow) -> Bool {
        guard let d = venueOwnerGameDay(row) else { return false }
        let cal = Calendar.current
        let start = cal.startOfDay(for: analyticsCustomStart)
        let end = cal.startOfDay(for: analyticsCustomEnd)
        let day = cal.startOfDay(for: d)
        let rangeEnd = max(start, end)
        let rangeStart = min(start, end)
        return day >= rangeStart && day <= rangeEnd
    }

    private func hideVenueEventFromAnalytics(_ eventID: UUID) {
        analyticsHiddenEventIDs.insert(eventID)
        analyticsDetailSelection = nil
        let email = viewModel.venueOwnerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty {
            VenueOwnerAnalyticsHiddenEventsLocalStore.save(ownerEmail: email, ids: analyticsHiddenEventIDs)
        }
        Task { await refreshVenueAnalyticsFilteredEngagementOnly() }
    }

    private func refreshVenueAnalyticsFilteredEngagementOnly() async {
        let displayed = await MainActor.run { displayedVenueAnalyticsGames() }
        let ids = displayed.compactMap(\.id)

        await viewModel.stopVenueOwnerAnalyticsRealtime()

        guard !ids.isEmpty else {
            return
        }

        await viewModel.loadInterestCountsForVenueEventIDs(ids)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    await viewModel.loadComments(for: id)
                    await viewModel.loadVibes(for: id)
                }
            }
        }

        await viewModel.startVenueOwnerAnalyticsRealtime(trackedEventIDs: ids)
    }

    private func loadVenueAnalytics() async {
        await viewModel.stopVenueOwnerAnalyticsRealtime()
        await MainActor.run {
            analyticsIsLoading = true
        }

        let rows = await viewModel.loadMyVenueGames()
        let pool = Self.venueAnalyticsGamesLoadingPool(rows)
        let sorted = Self.sortVenueAnalyticsEventsByDateDescending(pool)
        let capped = Array(sorted.prefix(1500))

        await MainActor.run {
            let email = viewModel.venueOwnerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty {
                analyticsHiddenEventIDs = VenueOwnerAnalyticsHiddenEventsLocalStore.load(ownerEmail: email)
            }
            analyticsGames = capped
        }

        await refreshVenueAnalyticsFilteredEngagementOnly()

        await MainActor.run {
            analyticsIsLoading = false
        }
    }

    private var gamesSection: some View {
        manageGamesTabbedExperience
    }

    private var manageGamesTabbedExperience: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $manageGamesListTab) {
                Text("Games").tag(ManageGamesListTab.games)
                Text("Add Game").tag(ManageGamesListTab.add)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !manageGamesFeedback.isEmpty {
                Text(manageGamesFeedback)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            }
            if !manageGamesError.isEmpty {
                Text(manageGamesError)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
            }

            switch manageGamesListTab {
            case .games:
                manageGamesListPane
            case .add:
                manageGamesAddPane
            }
        }
        .padding()
        .background(Color.white.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .task {
            await refreshManageGamesList(isInitialPick: true)
        }
        .confirmationDialog(
            "Remove “\(pendingCancelGameTitle)”?",
            isPresented: Binding(
                get: { pendingCancelGameID != nil },
                set: { if !$0 { pendingCancelGameID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove listing", role: .destructive) {
                Task {
                    guard let id = pendingCancelGameID,
                          let row = myVenueGamesForManage.first(where: { $0.id == id }) else {
                        await MainActor.run { pendingCancelGameID = nil }
                        return
                    }
                    await MainActor.run { pendingCancelGameID = nil }
                    let err = await viewModel.deleteVenueGame(row)
                    await MainActor.run {
                        if let err {
                            manageGamesError = err
                            manageGamesFeedback = ""
                        } else {
                            manageGamesError = ""
                            manageGamesFeedback = "Game removed."
                        }
                    }
                    await refreshManageGamesList(isInitialPick: false)
                }
            }
            Button("Keep", role: .cancel) {
                pendingCancelGameID = nil
            }
        } message: {
            Text("Fans will no longer see this listing. This can’t be undone.")
        }
        .sheet(item: $titleEditTarget) { target in
            NavigationStack {
                Form {
                    Section {
                        TextField("Game title", text: $titleEditDraft)
                            .textInputAutocapitalization(.words)
                    }
                }
                .navigationTitle("Edit title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { titleEditTarget = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task {
                                let err = await viewModel.updateVenueGameEventTitle(id: target.id, newTitle: titleEditDraft)
                                await MainActor.run {
                                    if let err {
                                        manageGamesError = err
                                        manageGamesFeedback = ""
                                    } else {
                                        manageGamesError = ""
                                        manageGamesFeedback = "Title updated."
                                        titleEditTarget = nil
                                    }
                                }
                                if err == nil {
                                    await refreshManageGamesList(isInitialPick: false)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var manageGamesListPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Games")
                .font(.title2)
                .fontWeight(.bold)

            Text("Games you’ve published at your venue.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if manageGamesListLoading && myVenueGamesForManage.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.black)
                    Text("Loading games…")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if myVenueGamesForManage.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No games yet")
                        .font(.headline)
                        .fontWeight(.bold)
                    Text("Add your first game to let fans know what you’re showing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        manageGamesListTab = .add
                        clearManageGamesBanners()
                    } label: {
                        Text("Add Game")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.black)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 10) {
                    ForEach(manageGamesIdentifiedRows) { item in
                        VenueOwnerManageGameRow(
                            row: item.row,
                            eventID: item.id,
                            formattedDateTime: formattedManageGameDateTime(row: item.row),
                            statusLabel: derivedManageGameStatus(row: item.row),
                            goingCount: viewModel.interestCountForVenueEvent(item.id),
                            commentCount: viewModel.venueEventComments[item.id]?.count ?? 0,
                            vibeTotal: aggregateVibeTotal(eventID: item.id),
                            onEditTitle: {
                                clearManageGamesBanners()
                                titleEditDraft = item.row.event_title ?? ""
                                titleEditTarget = VenueOwnerGameTitleEditTarget(id: item.id)
                            },
                            onCancel: {
                                clearManageGamesBanners()
                                guard let gid = item.row.id else { return }
                                pendingCancelGameTitle = item.row.event_title ?? "Game"
                                pendingCancelGameID = gid
                            }
                        )
                    }
                }
            }
        }
    }

    private var manageGamesAddPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Game")
                .font(.title2)
                .fontWeight(.bold)

            Text("Tell fans what you’re showing. Same details as before — saved to your venue listing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            addGameFormFields
        }
    }

    private var manageGamesIdentifiedRows: [VenueOwnerIdentifiedVenueEvent] {
        myVenueGamesForManage.compactMap { row in
            guard let id = row.id else { return nil }
            return VenueOwnerIdentifiedVenueEvent(id: id, row: row)
        }
    }

    private var addGameFormFields: some View {
        Group {
            field("Game title, example: France vs Brazil", text: $gameTitle)
            DatePicker("Game Date", selection: $gameDate, displayedComponents: .date)
                .fontWeight(.semibold)
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            DatePicker("Start Time", selection: $gameStartTime, displayedComponents: .hourAndMinute)
                .fontWeight(.semibold)
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            Picker("Sport", selection: $viewModel.ownerVenuePrimarySport) {
                ForEach(viewModel.sports.filter { $0 != "All" }, id: \.self) { sport in
                    Text(sport).tag(sport)
                }
            }
            .pickerStyle(.menu)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Toggle("Audio / sound will be ON", isOn: $soundOn)
                .fontWeight(.semibold)
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            Stepper("TVs showing this game: \(numberOfTVs)", value: $numberOfTVs, in: 1...50)
                .fontWeight(.semibold)
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            field("Team fanbase, example: France fans, Brazil fans, Arsenal supporters", text: $teamFanbase)
            field("Cover charge, example: No cover, $10 after 7 PM", text: $coverCharge)

            Picker("Crowd Level", selection: $crowdLevel) {
                Text("Light").tag("Light")
                Text("Moderate").tag("Moderate")
                Text("Packed").tag("Packed")
            }
            .pickerStyle(.segmented)

            Picker("Live Occupancy", selection: $liveOccupancy) {
                Text("Open seats").tag("Open seats")
                Text("Filling up").tag("Filling up")
                Text("Standing room").tag("Standing room")
            }
            .pickerStyle(.segmented)

            Toggle("Reservations required", isOn: $reservationsAvailable)
                .fontWeight(.semibold)

            Toggle("Waitlist available", isOn: $waitlistAvailable)
                .fontWeight(.semibold)

            Button {
                withAnimation(.spring()) {
                    showSpecialsFields.toggle()
                }
            } label: {
                HStack {
                    Text(showSpecialsFields ? "Hide Specials" : "Add Drink/Food Specials")
                        .fontWeight(.bold)
                    Spacer()
                    Image(systemName: showSpecialsFields ? "chevron.up" : "chevron.down")
                }
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if showSpecialsFields {
                field("Drink special", text: $gameSpecial)
                field("Cover charge", text: $coverCharge)
            }

            Button {
                Task {
                    await saveNewVenueGameFromForm()
                }
            } label: {
                primaryButtonText("Save Game Listing")
            }
            .overlay {
                if isSavingNewGame {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.35))
                    ProgressView()
                        .tint(.white)
                }
            }
            .disabled(isSavingNewGame)
        }
    }

    private func clearManageGamesBanners() {
        manageGamesFeedback = ""
        manageGamesError = ""
    }

    private func refreshManageGamesList(isInitialPick: Bool) async {
        await MainActor.run {
            manageGamesListLoading = true
        }

        let rows = await viewModel.loadMyVenueGames()
        let ids = rows.compactMap(\.id)
        await viewModel.loadInterestCountsForVenueEventIDs(ids)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    await viewModel.loadComments(for: id)
                    await viewModel.loadVibes(for: id)
                }
            }
        }

        await MainActor.run {
            myVenueGamesForManage = rows
            manageGamesListLoading = false

            if isInitialPick, !didPickInitialManageGamesTab {
                didPickInitialManageGamesTab = true
                manageGamesListTab = rows.isEmpty ? .add : .games
            }
            if rows.isEmpty {
                manageGamesListTab = .add
            }
        }
    }

    private func saveNewVenueGameFromForm() async {
        let trimmedTitle = gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            await MainActor.run {
                manageGamesError = "Enter a game title before saving."
                manageGamesFeedback = ""
            }
            return
        }

        await MainActor.run {
            isSavingNewGame = true
            clearManageGamesBanners()
        }

        let result = await viewModel.saveVenueGameListingAsync(
            gameTitle: trimmedTitle,
            sport: viewModel.ownerVenuePrimarySport,
            gameDate: gameDate,
            gameStartTime: gameStartTime,
            soundOn: soundOn,
            audioType: soundOn ? .full : .none,
            teamFanbase: teamFanbase,
            atmosphere: "",
            crowdLevel: crowdLevel,
            liveOccupancy: liveOccupancy,
            seating: seating,
            numberOfTVs: "\(numberOfTVs)",
            drinkSpecial: gameSpecial,
            coverCharge: coverCharge,
            reservationInfo: reservationsAvailable ? "Reservations available" : "",
            socialCoordination: waitlistAvailable ? "Waitlist available" : ""
        )

        await MainActor.run {
            isSavingNewGame = false
            switch result {
            case .failure(let err):
                manageGamesError = err.localizedDescription
                manageGamesFeedback = ""
            case .success:
                manageGamesError = ""
                manageGamesFeedback = "Game created."
                resetAddGameFormAfterSave()
                manageGamesListTab = .games
            }
        }

        if case .success = result {
            await refreshManageGamesList(isInitialPick: false)
        }
    }

    private func resetAddGameFormAfterSave() {
        gameTitle = ""
        gameSpecial = ""
        soundOn = true
        coverCharge = ""
        seating = ""
        teamFanbase = ""
        socialCoordination = ""
        gameDate = Date()
        gameStartTime = Date()
        numberOfTVs = 1
        crowdLevel = "Moderate"
        liveOccupancy = "Open seats"
        reservationsAvailable = false
        waitlistAvailable = false
        showSpecialsFields = false
    }

    private func formattedManageGameDateTime(row: VenueEventRow) -> String {
        let d = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
        let t = row.event_time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty { return d }
        return "\(d) · \(t)"
    }

    private func derivedManageGameStatus(row: VenueEventRow) -> String? {
        guard let ds = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines), !ds.isEmpty else {
            return nil
        }
        let fmt = DateFormatter()
        fmt.calendar = Calendar.current
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd"
        guard let gameDay = fmt.date(from: ds) else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        let day = Calendar.current.startOfDay(for: gameDay)
        if day < today { return "Past" }
        if day == today { return "Today" }
        return "Scheduled"
    }

    private func aggregateVibeTotal(eventID: UUID) -> Int {
        let dict = viewModel.venueEventVibeCounts[eventID] ?? [:]
        return dict.values.reduce(0, +)
    }
    
    private func dashboardCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            content()
        }
        .padding()
        .background(Color.white.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
    
    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .padding()
            .background(Color.gray.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func syncDisplayedVenuePhotoURLsFromViewModel() {
        displayedCoverPhotoURL = viewModel.venueCoverPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        displayedMenuPhotoURL = viewModel.venueMenuPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Preview-only cache bust; `viewModel` / DB keep the clean URL from upload.
    private func venuePhotoURLWithCacheBust(_ cleanBase: String) -> String {
        let t = String(Date().timeIntervalSince1970)
        let trimmed = cleanBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let sep = trimmed.contains("?") ? "&" : "?"
        return "\(trimmed)\(sep)v=\(t)"
    }

    /// Uses the same `v` query as `displayTemplateURL` (when present) on `storageURL` so full + thumbnail previews refresh together.
    private func venuePhotoPreviewURL(storageURL: String, displayTemplateURL: String) -> String {
        let storage = storageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !storage.isEmpty else { return "" }
        let template = displayTemplateURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let templateComponents = URLComponents(string: template),
              let templateItems = templateComponents.queryItems,
              let vValue = templateItems.first(where: { $0.name == "v" })?.value,
              !vValue.isEmpty
        else {
            return storage
        }
        guard var storageComponents = URLComponents(string: storage) else {
            let sep = storage.contains("?") ? "&" : "?"
            return "\(storage)\(sep)v=\(vValue)"
        }
        var q = storageComponents.queryItems ?? []
        q.removeAll { $0.name == "v" }
        q.append(URLQueryItem(name: "v", value: vValue))
        storageComponents.queryItems = q
        return storageComponents.string ?? storage
    }
    
    /// Titles sit outside ``PhotosPicker``. The picker label is the preview plus a full-width black CTA under it (one tappable block, no second photo row).
    private func venueProfilePhotoEditor(
        title: String,
        subtitle: String,
        fullImageURL: String,
        thumbnailURL: String,
        selection: Binding<PhotosPickerItem?>
    ) -> some View {
        let full = fullImageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let thumb = thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewURL = !full.isEmpty ? full : thumb
        let hasPreview = !previewURL.isEmpty

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PhotosPicker(selection: selection, matching: .images) {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.gray.opacity(0.10))
                        .frame(height: 140)
                        .overlay {
                            Group {
                                if previewURL.isEmpty {
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                } else {
                                    AsyncImage(url: URL(string: previewURL)) { image in
                                        image
                                            .resizable()
                                            .scaledToFill()
                                    } placeholder: {
                                        ProgressView()
                                    }
                                    .id(previewURL)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                    primaryButtonText(hasPreview ? "Tap to replace photo" : "Tap to upload photo")
                }
            }
            .buttonStyle(.plain)
        }
    }
    
    private func primaryButtonText(_ text: String) -> some View {
        Text(text)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.black)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Venue owner venue features grid

private struct VenueOwnerScreensFeatureTile: View {
    @Binding var totalScreens: Int

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "display")
                .font(.title2)
                .foregroundStyle(Color.green)

            Text("\(totalScreens) Screens")
                .font(.caption)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.75)
                .lineLimit(2)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                Button {
                    if totalScreens > 1 { totalScreens -= 1 }
                } label: {
                    Image(systemName: "minus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(totalScreens > 1 ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(totalScreens <= 1)
                .accessibilityLabel("Decrease screen count")

                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 1, height: 14)

                Button {
                    if totalScreens < 100 { totalScreens += 1 }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(totalScreens < 100 ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(totalScreens >= 100)
                .accessibilityLabel("Increase screen count")
            }
            .frame(width: 104, height: 26)
            .frame(maxWidth: .infinity)
            .background(Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }
}

private struct VenueOwnerFeatureToggleTile: View {
    let icon: String
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(isOn ? Color.green : Color.gray.opacity(0.62))

                Text(label)
                    .font(.caption)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
                    .minimumScaleFactor(0.8)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Manage Games list helpers

private struct VenueOwnerGameTitleEditTarget: Identifiable {
    let id: UUID
}

private struct VenueOwnerIdentifiedVenueEvent: Identifiable {
    let id: UUID
    var row: VenueEventRow
}

private struct VenueOwnerManageGameRow: View {
    let row: VenueEventRow
    let eventID: UUID
    let formattedDateTime: String
    let statusLabel: String?
    let goingCount: Int
    let commentCount: Int
    let vibeTotal: Int
    let onEditTitle: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.event_title ?? "Game")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.primary)

            Text(formattedDateTime)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(row.sport ?? "—")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.12))
                    .clipShape(Capsule())

                if let statusLabel {
                    Text(statusLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(Capsule())
                }
            }

            Text("\(goingCount) going · \(commentCount) comments · \(vibeTotal) vibes")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(action: onEditTitle) {
                    Text("Edit title")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.08))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onCancel) {
                    Text("Cancel game")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.10))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Venue owner compact analytics row

private struct VenueOwnerCompactAnalyticsRow: View {
    @ObservedObject var viewModel: MapViewModel
    let row: VenueEventRow
    let eventID: UUID
    let isLiveToday: Bool
    let onTapDetail: () -> Void

    private var score: Int {
        viewModel.venueOwnerEngagementScore(venueEventID: eventID)
    }

    private var going: Int {
        viewModel.interestCountForVenueEvent(eventID)
    }

    private var comments: Int {
        viewModel.venueEventComments[eventID]?.count ?? 0
    }

    private var audioCount: Int {
        viewModel.venueEventVibeCounts[eventID]?["audio_on"] ?? 0
    }

    private var packedCount: Int {
        viewModel.venueEventVibeCounts[eventID]?["packed"] ?? 0
    }

    private var seatsOpenCount: Int {
        viewModel.venueEventVibeCounts[eventID]?["seats_open"] ?? 0
    }

    private var specialsCount: Int {
        viewModel.venueEventVibeCounts[eventID]?["specials"] ?? 0
    }

    private var tvVisibleCount: Int {
        viewModel.venueEventVibeCounts[eventID]?["tv_visible"] ?? 0
    }

    private var shortTitle: String {
        let t = (row.event_title ?? "Game").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 18 { return t }
        return String(t.prefix(16)) + "…"
    }

    private var dateTimeLine: String {
        let d = row.event_date ?? "—"
        let t = row.event_time ?? ""
        if t.isEmpty { return d }
        return "\(d) · \(t)"
    }

    private var sportLine: String {
        let s = row.sport ?? "—"
        return "\(Self.sportEmoji(for: s)) \(s)"
    }

    private var scoreCrownLine: String {
        if score >= 40 { return "👑 \(score)" }
        if score >= 16 { return "🚀 \(score)" }
        if score >= 6 { return "🔥 \(score)" }
        return "✨ \(score)"
    }

    private var topVibeSnippet: String? {
        let m = viewModel.venueEventVibeCounts[eventID] ?? [:]
        guard let best = m.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        let label: String
        switch best.key {
        case "audio_on": label = "Audio"
        case "packed": label = "Packed"
        case "seats_open": label = "Seats"
        case "specials": label = "Specials"
        case "tv_visible": label = "TVs"
        default: label = best.key.replacingOccurrences(of: "_", with: " ")
        }
        let emoji: String
        switch best.key {
        case "audio_on": emoji = "🎙"
        case "packed": emoji = "🔥"
        case "seats_open": emoji = "🪑"
        case "specials": emoji = "🍺"
        case "tv_visible": emoji = "📺"
        default: emoji = "⭐️"
        }
        return "\(emoji) \(label) \(best.value)"
    }

    private static func sportEmoji(for sport: String) -> String {
        let s = sport.lowercased()
        if s.contains("soccer") { return "⚽️" }
        if s.contains("nba") || s.contains("basket") { return "🏀" }
        if s.contains("nfl") || s.contains("football") { return "🏈" }
        if s.contains("baseball") || s.contains("mlb") { return "⚾️" }
        if s.contains("hockey") || s.contains("nhl") { return "🏒" }
        if s.contains("tennis") { return "🎾" }
        if s.contains("golf") { return "⛳️" }
        if s.contains("ping") || s.contains("table") { return "🏓" }
        return "🏟"
    }

    var body: some View {
        Button(action: onTapDetail) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(shortTitle)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(scoreCrownLine)
                        .font(.caption.weight(.black))
                        .foregroundStyle(.primary)
                    if isLiveToday {
                        Text("LIVE")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.22))
                            .foregroundStyle(Color.green)
                            .clipShape(Capsule())
                    }
                }

                Text(dateTimeLine)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(sportLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(viewModel.venueOwnerEngagementTrendLabel(score: score))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black)
                    .clipShape(Capsule())

                HStack(spacing: 10) {
                    Text("👥 \(going)")
                        .font(.caption2.weight(.semibold))
                    Text("💬 \(comments)")
                        .font(.caption2.weight(.semibold))
                    if let topVibeSnippet {
                        Text(topVibeSnippet)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text("🎙 \(audioCount)")
                        .font(.caption2.weight(.medium))
                    Text("🔥 \(packedCount)")
                        .font(.caption2.weight(.medium))
                    Text("🪑 \(seatsOpenCount)")
                        .font(.caption2.weight(.medium))
                    Text("🍺 \(specialsCount)")
                        .font(.caption2.weight(.medium))
                    Text("📺 \(tvVisibleCount)")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.secondary.opacity(0.9))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Venue owner game analytics card

private struct VenueOwnerGameAnalyticsCard: View {
    @ObservedObject var viewModel: MapViewModel
    let row: VenueEventRow
    let eventID: UUID
    let isLiveToday: Bool

    private var goingCount: Int {
        viewModel.interestCountForVenueEvent(eventID)
    }

    private var commentCount: Int {
        viewModel.venueEventComments[eventID]?.count ?? 0
    }

    private var audioCount: Int {
        viewModel.venueEventVibeCounts[eventID]?["audio_on"] ?? 0
    }

    private var packedCount: Int {
        viewModel.venueEventVibeCounts[eventID]?["packed"] ?? 0
    }

    private var seatsOpenCount: Int {
        viewModel.venueEventVibeCounts[eventID]?["seats_open"] ?? 0
    }

    private var specialsCount: Int {
        viewModel.venueEventVibeCounts[eventID]?["specials"] ?? 0
    }

    private var tvVisibleCount: Int {
        viewModel.venueEventVibeCounts[eventID]?["tv_visible"] ?? 0
    }

    private var score: Int {
        viewModel.venueOwnerEngagementScore(venueEventID: eventID)
    }

    private var topVibeLine: String? {
        let m = viewModel.venueEventVibeCounts[eventID] ?? [:]
        guard let best = m.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        switch best.key {
        case "audio_on": return "Top vibe: 🔊 Audio (\(best.value))"
        case "packed": return "Top vibe: 🔥 Packed (\(best.value))"
        case "seats_open": return "Top vibe: 🪑 Seats open (\(best.value))"
        case "specials": return "Top vibe: 🍺 Specials (\(best.value))"
        case "tv_visible": return "Top vibe: 📺 TVs (\(best.value))"
        default: return "Top vibe: \(best.key) (\(best.value))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.event_title ?? "Game")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text([row.event_date, row.event_time].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isLiveToday {
                    Text("Live now")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.2))
                        .foregroundStyle(Color.green)
                        .clipShape(Capsule())
                }
            }

            Text(viewModel.venueOwnerEngagementTrendLabel(score: score))
                .font(.caption)
                .fontWeight(.bold)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black)
                .foregroundStyle(.white)
                .clipShape(Capsule())

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                metricCell(title: "Interested / going", value: goingCount, accent: .primary)
                metricCell(title: "Fan updates", value: commentCount, accent: .blue)
            }

            metricCell(title: "Total engagement score", value: score, accent: .purple)
                .frame(maxWidth: .infinity, alignment: .leading)

            vibeBadgeRow

            if let topVibeLine {
                Text(topVibeLine)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func metricCell(title: String, value: Int, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text("\(value)")
                .font(.title3)
                .fontWeight(.black)
                .foregroundStyle(accent)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.22), value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var vibeBadgeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vibe taps")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    vibeChip("🔊 Audio", audioCount, Color.blue.opacity(0.22))
                    vibeChip("🔥 Packed", packedCount, Color.orange.opacity(0.25))
                    vibeChip("🪑 Seats open", seatsOpenCount, Color.green.opacity(0.22))
                    vibeChip("🍺 Specials", specialsCount, Color.purple.opacity(0.22))
                    vibeChip("📺 TVs", tvVisibleCount, Color.gray.opacity(0.2))
                }
            }
        }
    }

    private func vibeChip(_ title: String, _ count: Int, _ fill: Color) -> some View {
        Text("\(title) \(count)")
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(fill)
            .foregroundStyle(.primary)
            .clipShape(Capsule())
            .contentTransition(.numericText())
    }
}

