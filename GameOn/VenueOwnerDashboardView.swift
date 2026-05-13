import Photos
import SwiftUI
import PhotosUI

// MARK: - Venue analytics locally hidden events
//
// TODO: Persist hides in Supabase with `venue_hidden_analytics_events` (venue_owner_id, venue_event_id,
// created_at) and RLS so owners can manage their own rows. Until then, hides survive relaunch via UserDefaults.

private enum VenueOwnerAnalyticsHiddenEventsLocalStore {
    private static let defaultsKeyPrefix = "VenueOwnerAnalyticsHiddenEventIDs."

    /// Per-owner; when ``venueDatabaseId`` is set, hides are scoped to that location (Phase B3.1).
    private static func storageKey(ownerEmail: String, venueDatabaseId: UUID?) -> String {
        let email = ownerEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let vid = venueDatabaseId {
            let vidKey = vid.uuidString.lowercased()
            if !email.isEmpty {
                return defaultsKeyPrefix + email + "." + vidKey
            }
            return defaultsKeyPrefix + "venue_id." + vidKey
        }
        return defaultsKeyPrefix + email
    }

    static func load(ownerEmail: String, venueDatabaseId: UUID?) -> Set<UUID> {
        let key = storageKey(ownerEmail: ownerEmail, venueDatabaseId: venueDatabaseId)
        guard let arr = UserDefaults.standard.array(forKey: key) as? [String] else { return [] }
        return Set(arr.compactMap(UUID.init))
    }

    static func save(ownerEmail: String, venueDatabaseId: UUID?, ids: Set<UUID>) {
        let key = storageKey(ownerEmail: ownerEmail, venueDatabaseId: venueDatabaseId)
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
    @State private var analyticsGameHistoryForYear: [BusinessGameHistoryRow] = []
    @State private var analyticsGameHistoryYear: Int = Calendar.current.component(.year, from: Date())
    @State private var analyticsGameHistoryMonth: Int = 0
    @State private var analyticsGameHistoryLoading = false
    @State private var analyticsGameHistoryError = ""

    private enum VenueAnalyticsDatePreset: String, CaseIterable {
        case today = "Today"
        case thisWeek = "This week"
        case thisMonth = "This month"
        case all = "All"
        case custom = "Custom"
    }

    /// Top-level tabs inside the business **Analytics** card (keeps heavy game history off the engagement screen).
    private enum BusinessVenueAnalyticsTab: Int, CaseIterable {
        case venueAnalytics = 0
        case gameHistory = 1
    }

    @State private var businessVenueAnalyticsTab: BusinessVenueAnalyticsTab = .venueAnalytics

    /// Caps how many event cards render at once when the date filter is **All** (newest first).
    private enum VenueAnalyticsEngagementDisplay {
        static let maxCardRowsWhenAllDatesPreset = 500
    }

    private enum ManageGamesListTab: Int, CaseIterable {
        case scheduled = 0
        case add = 1
    }

    @State private var manageGamesListTab: ManageGamesListTab = .scheduled
    @State private var didPickInitialManageGamesTab = false
    @State private var myVenueGamesForManage: [VenueEventRow] = []
    @State private var manageGamesListLoading = false
    @State private var manageGamesFeedback = ""
    @State private var manageGamesError = ""
    @State private var isSavingNewGame = false
    @State private var titleEditTarget: VenueOwnerGameTitleEditTarget?
    @State private var titleEditDraft = ""
    @State private var showCancelGameDialog = false
    @State private var cancelGameRowSnapshot: VenueEventRow?
    @State private var cleanupDelayHours: Int = 48
    @State private var showVenueOwnerContactSupport = false

    enum VenueDashboardSection: String, CaseIterable {
        case profile = "Profile"
        case games = "Games"
        case analytics = "Analytics"

        /// Shown in the segmented control (may differ from ``rawValue`` for clarity).
        var pickerLabel: String {
            switch self {
            case .profile, .games: rawValue
            case .analytics: "Analytics"
            }
        }
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

    /// When true, venue name, address, region, and coordinates are read-only (FanGeo-approved active managed venue).
    private var venueCoreIdentityLocked: Bool {
        viewModel.venueCoreIdentityLockedForSelectedVenue()
    }

    /// Games / analytics require ``MapViewModel/venueOwnerToolsUnlockedForUI()`` (at least one linked or legacy venue row).
    private var venueOwnerGamesAndAnalyticsLocked: Bool {
        !viewModel.venueOwnerToolsUnlockedForUI()
    }

    private func logVenueOwnerToolsGate(screen: String) {
#if DEBUG
        print("[VenueOwnerToolsGate] unlocked=\(viewModel.venueOwnerToolsUnlockedForUI())")
        print("[VenueOwnerToolsGate] managedVenuesCount=\(viewModel.managedVenuesForOwner().count)")
        print("[VenueOwnerToolsGate] screen=\(screen)")
#endif
    }

    private var venueOwnerPendingApprovalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pending approval")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Claim requests are reviewed before owner tools are enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 1)
        )
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
                        if venueOwnerGamesAndAnalyticsLocked {
                            venueOwnerPendingApprovalCard
                        } else {
                            gamesSection
                        }
                    case .analytics:
                        if venueOwnerGamesAndAnalyticsLocked {
                            venueOwnerPendingApprovalCard
                        } else {
                            venueAnalyticsSection
                        }
                    }
                }
                // Force a fresh subtree when the entry point or active tab changes so a prior section’s
                // SwiftUI state cannot remain mounted under the venue profile editor sheet.
                .id("\(String(describing: entryPoint))-\(effectiveSection.rawValue)")
            }
            .padding()
        }
        .background(FGAdaptiveSurface.sheetRoot)
        .onChange(of: viewModel.ownerVenueDatabaseId) { _, _ in
            clearManageGamesTransientStateForVenueSwitch()
            clearAnalyticsGameHistoryState()
        }
        .onAppear {
            if entryPoint != .analyticsViewer {
                Task {
                    await viewModel.stopVenueOwnerAnalyticsRealtime()
                }
            }
            switch effectiveSection {
            case .games:
                logVenueOwnerToolsGate(screen: "ManageGames")
            case .analytics:
                logVenueOwnerToolsGate(screen: "Analytics")
            case .profile:
                break
            }
        }
        .onChange(of: effectiveSection) { _, newSection in
            switch newSection {
            case .games:
                logVenueOwnerToolsGate(screen: "ManageGames")
            case .analytics:
                logVenueOwnerToolsGate(screen: "Analytics")
            case .profile:
                break
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
        .onChange(of: viewModel.ownerVenueDatabaseId) { _, _ in
            guard effectiveSection == .analytics else { return }
            Task { await loadVenueAnalytics() }
        }
        .task(id: viewModel.ownerVenueDatabaseId) {
            if let saved = await viewModel.loadVenueProfile() {
                await MainActor.run {
                    viewModel.applyVenueProfileRowToOwnerState(saved)

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
                }
            } else {
                await MainActor.run {
                    if viewModel.managedVenuesForOwner().isEmpty {
                        viewModel.ownerVenueDatabaseId = nil
                    }
                    if viewModel.pendingClaimVenueID != nil {
                        let street = viewModel.ownerVenueAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                        if venueStreetAddress.isEmpty, !street.isEmpty {
                            venueStreetAddress = street
                        }
                        let city = viewModel.ownerVenueCity.trimmingCharacters(in: .whitespacesAndNewlines)
                        if venueCity.isEmpty, !city.isEmpty {
                            venueCity = city
                        }
                        let zip = viewModel.ownerVenueZipCode.trimmingCharacters(in: .whitespacesAndNewlines)
                        if venueZipCode.isEmpty, !zip.isEmpty {
                            venueZipCode = zip
                        }
                        let st = viewModel.ownerVenueState.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !st.isEmpty {
                            venueState = st
                        }
                    }
                }
            }
            syncDisplayedVenuePhotoURLsFromViewModel()
        }
        
        .onChange(of: selectedCoverPhoto) { _, newItem in
            Task {
                guard let newItem else { return }
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let url = await viewModel.uploadVenuePhoto(data: data, fileName: "cover.jpg") {
                    await MainActor.run {
                        viewModel.venueCoverPhotoURL = url
                        displayedCoverPhotoURL = VenueOwnerPhotoPickerCopy.urlWithCacheBust(url)
                        profileSaveMessage = "Cover photo uploaded. Tap Save Profile to save changes."
                    }
                } else {
                    await MainActor.run {
                        profileSaveMessage = VenueOwnerPhotoPickerCopy.pickFailureUserHint()
                    }
                }
            }
        }
        .onChange(of: selectedMenuPhoto) { _, newItem in
            Task {
                guard let newItem else { return }
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let url = await viewModel.uploadVenuePhoto(data: data, fileName: "menu.jpg") {
                    await MainActor.run {
                        viewModel.venueMenuPhotoURL = url
                        displayedMenuPhotoURL = VenueOwnerPhotoPickerCopy.urlWithCacheBust(url)
                        profileSaveMessage = "Menu photo uploaded. Tap Save Profile to save changes."
                    }
                } else {
                    await MainActor.run {
                        profileSaveMessage = VenueOwnerPhotoPickerCopy.pickFailureUserHint()
                    }
                }
            }
        }
        .sheet(isPresented: $showVenueOwnerContactSupport) {
            ContactGameOnSupportSheet(
                viewModel: viewModel,
                onRequestSignIn: {
                    showVenueOwnerContactSupport = false
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            managingVenueHeaderRow

            Text(headerTitle)
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(.primary)

            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if viewModel.isVenueOwnerLoggedIn {
                viewModel.logBusinessSwitcherDebug()
            }
        }
    }

    @ViewBuilder
    private var managingVenueHeaderRow: some View {
        BusinessLocationVenuePicker(viewModel: viewModel, chrome: .dashboard)
    }

    private var headerTitle: String {
        switch entryPoint {
        case .profileEditor:
            return "Venue Details"
        case .gamesManager:
            return "Manage games"
        case .analyticsViewer:
            return "Analytics"
        case .allTabs:
            return "Business dashboard"
        }
    }

    private var headerSubtitle: String {
        switch entryPoint {
        case .profileEditor:
            return "Photos, menu, amenities, and venue profile for the selected location."
        case .gamesManager:
            return "Add, edit, or cancel games for the selected location."
        case .analyticsViewer:
            return "Live engagement by game for the selected location."
        case .allTabs:
            return "Manage your locations, schedule, and game-day experience."
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
                        Text(section.pickerLabel)
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                selectedSection == section
                                    ? AnyShapeStyle(Color.accentColor)
                                    : AnyShapeStyle(FGAdaptiveSurface.capsuleUnselected)
                            )
                            .foregroundStyle(selectedSection == section ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                    .disabled(
                        venueOwnerGamesAndAnalyticsLocked
                            && (section == .games || section == .analytics)
                    )
                }
            }
        }
    }
    
    private var profileSection: some View {
        dashboardCard(
            title: entryPoint == .profileEditor ? "Venue listing" : "Location profile",
            subtitle: entryPoint == .profileEditor
                ? "Editable items save to the venue selected above."
                : "Basic listing information"
        ) {
            if venueCoreIdentityLocked {
                venueFanGeoVerifiedExplainerCard()
            }

            field("Bar / Pub / Restaurant Name", text: $viewModel.ownerVenueName, locked: venueCoreIdentityLocked)
            field("Street Address", text: $venueStreetAddress, locked: venueCoreIdentityLocked)
            field("City", text: $venueCity, locked: venueCoreIdentityLocked)

            HStack(alignment: .center, spacing: 10) {
                Picker("State", selection: $venueState) {
                    ForEach(usStates, id: \.self) { state in
                        Text(state).tag(state)
                    }
                }
                .pickerStyle(.menu)
                .disabled(venueCoreIdentityLocked)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FGAdaptiveSurface.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                if venueCoreIdentityLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Locked")
                }
            }
            .opacity(venueCoreIdentityLocked ? 0.78 : 1)

            field("ZIP Code", text: $venueZipCode, locked: venueCoreIdentityLocked)
            BusinessPhoneNumberField(dialISO: $viewModel.ownerVenuePhoneDialISO, localNumber: $viewModel.ownerVenuePhone)
            field("Website", text: $viewModel.ownerVenueWebsite)
            field("Short Description", text: $viewModel.ownerVenueDescription)
            field("Features: Big Screens, Patio, Sound On", text: $viewModel.ownerVenueFeatures)

            VStack(alignment: .leading, spacing: 28) {
                venueOwnerVenueFeaturesCard()

                venueProfilePhotoEditor(
                    title: "Business Photo",
                    subtitle: "Main photo of your business",
                    fullImageURL: displayedCoverPhotoURL,
                    thumbnailURL: VenueOwnerPhotoPickerCopy.thumbnailURLAlignedWithDisplay(
                        storageURL: viewModel.venueCoverPhotoThumbnailURL,
                        displayTemplateURL: displayedCoverPhotoURL
                    ),
                    selection: $selectedCoverPhoto
                )

                venueProfilePhotoEditor(
                    title: "Menu Photo",
                    subtitle: "Food or drink menu photo",
                    fullImageURL: displayedMenuPhotoURL,
                    thumbnailURL: VenueOwnerPhotoPickerCopy.thumbnailURLAlignedWithDisplay(
                        storageURL: viewModel.venueMenuPhotoThumbnailURL,
                        displayTemplateURL: displayedMenuPhotoURL
                    ),
                    selection: $selectedMenuPhoto
                )

                Button {
                    let nameBad = ModerationService.containsProfanity(viewModel.ownerVenueName)
                    let descBad = ModerationService.containsProfanity(viewModel.ownerVenueDescription)
                    if descBad || (!venueCoreIdentityLocked && nameBad) {
                        profileSaveMessage = ModerationService.profanityRejectionUserMessage()
                        return
                    }

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

                        if success, let saved = await viewModel.loadVenueProfile() {
                            await MainActor.run {
                                viewModel.applyVenueProfileRowToOwnerState(saved)
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
                                syncDisplayedVenuePhotoURLsFromViewModel()
                            }
                        }

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

    private func venueFanGeoVerifiedExplainerCard() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Venue information verified by FanGeo.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("To change the venue name, address, or core business information, please contact FanGeo Support.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
#if DEBUG
                print("[VenueDetailsLock] support contact opened")
#endif
                showVenueOwnerContactSupport = true
            } label: {
                Text("Contact FanGeo Support")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor.opacity(0.18))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the in-app FanGeo support form.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
        )
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
        .background(FGAdaptiveSurface.controlFill)
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
                                .background(
                                    analyticsDatePreset == preset
                                        ? AnyShapeStyle(Color.accentColor)
                                        : AnyShapeStyle(FGAdaptiveSurface.capsuleUnselected)
                                )
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
            .background(FGAdaptiveSurface.controlFill)
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
                .background(FGAdaptiveSurface.controlFill)
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
                .background(FGAdaptiveSurface.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var venueAnalyticsSection: some View {
        dashboardCard(
            title: "Analytics",
            subtitle: "Venue Analytics focuses on games still in your database—engagement for active, recent, and cancelled listings. Use the Game History tab for permanent lightweight summaries after a game is fully purged from venue events (fan comments and reactions are never stored there)."
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
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $businessVenueAnalyticsTab) {
                Text("Venue Analytics").tag(BusinessVenueAnalyticsTab.venueAnalytics)
                Text("Game History").tag(BusinessVenueAnalyticsTab.gameHistory)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch businessVenueAnalyticsTab {
            case .venueAnalytics:
                venueAnalyticsVenueEngagementTab()
            case .gameHistory:
                analyticsPurgedHistorySection
                    .task(id: analyticsGameHistoryTaskKey) {
                        await refreshAnalyticsGameHistory()
                    }
                    .refreshable {
                        await refreshAnalyticsGameHistory()
                    }
            }
        }
    }

    /// Engagement tab: only ``venue_events`` rows still in the database (purged games never appear here).
    private func venueAnalyticsVenueEngagementTab() -> some View {
        let pack = displayedVenueAnalyticsGamesForCards()
        let displayed = pack.rows
        let isCapped = pack.isCapped

        return VStack(alignment: .leading, spacing: 12) {
            venueAnalyticsFilterBar

            if isCapped {
                Text("Showing the \(VenueAnalyticsEngagementDisplay.maxCardRowsWhenAllDatesPreset) most recent games for this view. Purged games are removed from venue events entirely—they never appear here. Use a narrower date filter to browse older rows without loading everything at once.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Group {
                if analyticsIsLoading && analyticsGames.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading analytics…")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if analyticsGames.isEmpty {
                    Text("No games loaded for analytics yet. Add a game from the Games tab, or pull to refresh after cancellations.")
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
                            Text("No games match this filter.")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("Try another date range or sport, or choose “All” in the date presets to include past and cancelled listings.")
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
                    }
                }
            }
        }
        .refreshable {
            await loadVenueAnalytics()
        }
    }

    /// Lightweight rows after a game listing is cleared from the database (no fan chat text). Populated when server retention runs.
    private var analyticsPurgedHistorySection: some View {
        let currentYear = Calendar.current.component(.year, from: Date())
        return VStack(alignment: .leading, spacing: 10) {
            Text("Cleared listings (permanent summaries)")
                .font(.headline.weight(.bold))

            Text("When a game is fully purged from venue events, it no longer appears under Venue Analytics. Only these lightweight rows remain (title, schedule, venue, counts)—intentional for scale. Fan comments and reactions are not stored here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Picker("Year", selection: $analyticsGameHistoryYear) {
                    ForEach((currentYear - 5)...(currentYear + 1), id: \.self) { y in
                        Text(String(y)).tag(y)
                    }
                }
                .pickerStyle(.menu)

                Picker("Month", selection: $analyticsGameHistoryMonth) {
                    Text("All months").tag(0)
                    ForEach(1...12, id: \.self) { m in
                        Text(monthShortName(m)).tag(m)
                    }
                }
                .pickerStyle(.menu)

                Spacer(minLength: 0)
            }

            Text("Total cleared games (this year): \(totalAnalyticsGameHistoryInYear)")
                .font(.caption.weight(.semibold))
            if analyticsGameHistoryMonth != 0 {
                Text("In selected month: \(analyticsGameHistoryInSelectedMonthCount)")
                    .font(.caption.weight(.semibold))
            }

            if !analyticsGameHistoryError.isEmpty {
                Text(analyticsGameHistoryError)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }

            if analyticsGameHistoryLoading && analyticsGameHistoryForYear.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading cleared-game history…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.currentBusinessIdForAddLocation() == nil {
                Text("Link a business to this account to load cleared-game summaries.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if analyticsGameHistoryFiltered.isEmpty {
                Text("No cleared-game records for this year yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(analyticsGameHistoryFiltered) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.event_title ?? "Game")
                                .font(.headline.weight(.semibold))
                            Text(formatHistorySchedule(row.scheduled_start_at))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(row.sport ?? "—")
                                    .font(.caption2.weight(.semibold))
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(row.venue_name ?? "—")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(FGAdaptiveSurface.controlFill)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
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

    /// Rows shown as cards in **Venue Analytics**; when the date preset is **All**, caps count so the screen stays responsive with very large histories.
    private func displayedVenueAnalyticsGamesForCards() -> (rows: [VenueEventRow], isCapped: Bool) {
        let full = displayedVenueAnalyticsGames()
        let maxRows = VenueAnalyticsEngagementDisplay.maxCardRowsWhenAllDatesPreset
        if analyticsDatePreset == .all, full.count > maxRows {
            return (Array(full.prefix(maxRows)), true)
        }
        return (full, false)
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
        let email = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        if !email.isEmpty || viewModel.ownerVenueDatabaseId != nil {
            VenueOwnerAnalyticsHiddenEventsLocalStore.save(
                ownerEmail: email,
                venueDatabaseId: viewModel.ownerVenueDatabaseId,
                ids: analyticsHiddenEventIDs
            )
        }
        Task { await refreshVenueAnalyticsFilteredEngagementOnly() }
    }

    private func refreshVenueAnalyticsFilteredEngagementOnly() async {
        let displayed = await MainActor.run { displayedVenueAnalyticsGamesForCards().rows }
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

        let rows = await viewModel.loadMyVenueGamesForAnalytics()
        let pool = Self.venueAnalyticsGamesLoadingPool(rows)
        let sorted = Self.sortVenueAnalyticsEventsByDateDescending(pool)
        let capped = Array(sorted.prefix(1500))

        await MainActor.run {
            let email = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
            if !email.isEmpty || viewModel.ownerVenueDatabaseId != nil {
                analyticsHiddenEventIDs = VenueOwnerAnalyticsHiddenEventsLocalStore.load(
                    ownerEmail: email,
                    venueDatabaseId: viewModel.ownerVenueDatabaseId
                )
            }
            analyticsGames = capped
        }

        await refreshVenueAnalyticsFilteredEngagementOnly()

        await MainActor.run {
            analyticsIsLoading = false
        }
    }

    private var analyticsGameHistoryTaskKey: String {
        let bid = viewModel.currentBusinessIdForAddLocation()?.uuidString ?? ""
        return "\(analyticsGameHistoryYear)-\(bid)-\(viewModel.ownerVenueDatabaseId?.uuidString ?? "")"
    }

    private var analyticsGameHistoryFiltered: [BusinessGameHistoryRow] {
        guard analyticsGameHistoryMonth >= 1, analyticsGameHistoryMonth <= 12 else { return analyticsGameHistoryForYear }
        let p = String(format: "%04d-%02d-", analyticsGameHistoryYear, analyticsGameHistoryMonth)
        return analyticsGameHistoryForYear.filter { ($0.scheduled_start_at ?? "").hasPrefix(p) }
    }

    private var totalAnalyticsGameHistoryInYear: Int { analyticsGameHistoryForYear.count }

    private var analyticsGameHistoryInSelectedMonthCount: Int {
        guard analyticsGameHistoryMonth >= 1, analyticsGameHistoryMonth <= 12 else { return 0 }
        return analyticsGameHistoryFiltered.count
    }

    private var gamesSection: some View {
        manageGamesTabbedExperience
    }

    private var manageGamesTabbedExperience: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $manageGamesListTab) {
                Text("Scheduled").tag(ManageGamesListTab.scheduled)
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
            case .scheduled:
                manageGamesListPane
            case .add:
                manageGamesAddPane
            }
        }
        .padding()
        .background(FGAdaptiveSurface.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)
        )
        .task(id: viewModel.ownerVenueDatabaseId) {
            await refreshManageGamesList(isInitialPick: !didPickInitialManageGamesTab)
        }
        .confirmationDialog(
            "Cancel this game?",
            isPresented: $showCancelGameDialog,
            titleVisibility: .visible
        ) {
            Button("Remove Game", role: .destructive) {
                guard let snap = cancelGameRowSnapshot else { return }
                cancelGameRowSnapshot = nil
                Task {
                    await performManageGameCancel(rowSnapshot: snap)
                }
            }
            Button("Keep Game", role: .cancel) {
                cancelGameRowSnapshot = nil
            }
        } message: {
            Text("This will remove the game from your venue schedule and FanGeo discovery.")
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
            Text("Scheduled games")
                .font(.title2)
                .fontWeight(.bold)

            Text("Upcoming listings at your venue. Past starts drop from this list after the game time passes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if manageGamesListLoading && myVenueGamesForManage.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
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
                            .background(Color.accentColor)
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
                            onCleanupDelayChange: { hours in
                                Task {
                                    let err = await viewModel.updateVenueEventCleanupDelay(venueEventId: item.id, hours: hours)
                                    await MainActor.run {
                                        if let err {
                                            manageGamesError = err
                                            manageGamesFeedback = ""
                                        } else {
                                            manageGamesError = ""
                                            manageGamesFeedback = "Retention updated."
                                        }
                                    }
                                    await refreshManageGamesList(isInitialPick: false)
                                }
                            },
                            onCancel: {
                                clearManageGamesBanners()
                                guard item.row.id != nil else { return }
                                cancelGameRowSnapshot = item.row
                                showCancelGameDialog = true
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
        .onAppear {
            clampSchedulePickersToNow()
        }
    }

    private var manageGamesIdentifiedRows: [VenueOwnerIdentifiedVenueEvent] {
        myVenueGamesForManage.compactMap { row in
            guard let id = row.id else { return nil }
            return VenueOwnerIdentifiedVenueEvent(id: id, row: row)
        }
    }

    private var minimumSelectableGameCalendarDate: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var endOfSelectedGameDate: Date {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: gameDate)
        guard let nextDay = cal.date(byAdding: .day, value: 1, to: dayStart) else {
            return gameDate
        }
        return nextDay.addingTimeInterval(-1)
    }

    private var startTimeLowerBoundForPicker: Date {
        let cal = Calendar.current
        let now = Date()
        let dayStart = cal.startOfDay(for: gameDate)
        if cal.compare(dayStart, to: cal.startOfDay(for: now), toGranularity: .day) == .orderedDescending {
            return dayStart
        }
        if cal.isDate(gameDate, inSameDayAs: now) {
            return max(now, dayStart)
        }
        return max(now, dayStart)
    }

    private var gameStartTimePickerClosedRange: ClosedRange<Date> {
        let lo = startTimeLowerBoundForPicker
        let hi = endOfSelectedGameDate
        if lo <= hi { return lo...hi }
        return lo...lo.addingTimeInterval(60)
    }

    private func clampSchedulePickersToNow() {
        let clamped = VenueOwnerGameScheduleValidation.clampGameDateAndTimeToMinimumNow(
            gameDate: gameDate,
            gameStartTime: gameStartTime
        )
        if clamped.0 != gameDate { gameDate = clamped.0 }
        if clamped.1 != gameStartTime { gameStartTime = clamped.1 }
    }

    private var addGameFormFields: some View {
        Group {
            field("Game title, example: France vs Brazil", text: $gameTitle)
            DatePicker(
                "Game Date",
                selection: $gameDate,
                in: minimumSelectableGameCalendarDate...Date.distantFuture,
                displayedComponents: .date
            )
                .fontWeight(.semibold)
                .padding()
                .background(FGAdaptiveSurface.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            DatePicker(
                "Start Time",
                selection: $gameStartTime,
                in: gameStartTimePickerClosedRange,
                displayedComponents: .hourAndMinute
            )
                .fontWeight(.semibold)
                .padding()
                .background(FGAdaptiveSurface.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 8) {
                Text("Remove game data after")
                    .font(.subheadline.weight(.semibold))
                Text("Fan comments, vibes, and attendance rows are deleted; you keep a short summary in History.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("Retention hours", selection: $cleanupDelayHours) {
                    Text("24h after start").tag(24)
                    Text("48h after start").tag(48)
                    Text("72h after start").tag(72)
                }
                .pickerStyle(.segmented)
            }
            .padding()
            .background(FGAdaptiveSurface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Picker("Sport", selection: $viewModel.ownerVenuePrimarySport) {
                ForEach(viewModel.sports.filter { $0 != "All" }, id: \.self) { sport in
                    Text(sport).tag(sport)
                }
            }
            .pickerStyle(.menu)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FGAdaptiveSurface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Toggle("Audio / sound will be ON", isOn: $soundOn)
                .fontWeight(.semibold)
                .padding()
                .background(FGAdaptiveSurface.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            Stepper("TVs showing this game: \(numberOfTVs)", value: $numberOfTVs, in: 1...50)
                .fontWeight(.semibold)
                .padding()
                .background(FGAdaptiveSurface.controlFill)
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
                .background(FGAdaptiveSurface.controlFill)
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
                        .fill(FGAdaptiveSurface.sheetRoot.opacity(0.55))
                    ProgressView()
                        .tint(.primary)
                }
            }
            .disabled(isSavingNewGame)
        }
        .onChange(of: gameDate) { _, _ in clampSchedulePickersToNow() }
        .onChange(of: gameStartTime) { _, _ in clampSchedulePickersToNow() }
    }

    private func clearManageGamesBanners() {
        manageGamesFeedback = ""
        manageGamesError = ""
    }

    /// Clears add/list transient UI when the owner switches managed location (see ``MapViewModel/ownerVenueDatabaseId``).
    private func clearManageGamesTransientStateForVenueSwitch() {
        clearManageGamesBanners()
        isSavingNewGame = false
        titleEditTarget = nil
        showCancelGameDialog = false
        cancelGameRowSnapshot = nil
        didPickInitialManageGamesTab = false
#if DEBUG
        print("[BusinessGameState] cleared transient game state for venue switch")
#endif
    }

    private func clearAnalyticsGameHistoryState() {
        analyticsGameHistoryForYear = []
        analyticsGameHistoryError = ""
        analyticsGameHistoryLoading = false
        businessVenueAnalyticsTab = .venueAnalytics
    }

    private static func venueEventManageListSortKey(_ r: VenueEventRow) -> String {
        if let s = r.scheduled_start_at?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        let d = r.event_date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let t = r.event_time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = r.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(d)|\(t)|\(title)"
    }

    private func performManageGameCancel(rowSnapshot: VenueEventRow) async {
        await MainActor.run {
            myVenueGamesForManage.removeAll { $0.id == rowSnapshot.id }
            manageGamesFeedback = "Game cancelled"
            manageGamesError = ""
        }

        let err = await viewModel.deleteVenueGame(rowSnapshot)

        await MainActor.run {
            if let err {
                if !myVenueGamesForManage.contains(where: { $0.id == rowSnapshot.id }) {
                    myVenueGamesForManage.append(rowSnapshot)
                    myVenueGamesForManage.sort { Self.venueEventManageListSortKey($0) < Self.venueEventManageListSortKey($1) }
                }
                manageGamesError = err
                manageGamesFeedback = ""
            } else {
                manageGamesError = ""
                manageGamesFeedback = "Game cancelled."
                Task {
                    await refreshManageGamesList(isInitialPick: false)
                }
            }
        }
    }

    private func refreshManageGamesList(isInitialPick: Bool) async {
        await MainActor.run {
            manageGamesListLoading = true
        }

        let rows = await viewModel.loadMyVenueScheduledGames()
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
                manageGamesListTab = rows.isEmpty ? .add : .scheduled
            }
            if rows.isEmpty, manageGamesListTab == .scheduled {
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

        if VenueOwnerGameScheduleValidation.isPastSchedule(gameDate: gameDate, gameStartTime: gameStartTime) {
            await MainActor.run {
                manageGamesError = VenueOwnerGameScheduleValidation.futureDateTimeMessage
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
            socialCoordination: waitlistAvailable ? "Waitlist available" : "",
            cleanupDelayHours: cleanupDelayHours
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
#if DEBUG
                if let vid = viewModel.ownerVenueDatabaseId {
                    print("[BusinessGameState] success state set for venue_id=\(vid.uuidString)")
                } else {
                    print("[BusinessGameState] success state set for venue_id=nil")
                }
#endif
                resetAddGameFormAfterSave()
                manageGamesListTab = .scheduled
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
        let clamped = VenueOwnerGameScheduleValidation.clampGameDateAndTimeToMinimumNow(
            gameDate: Date(),
            gameStartTime: Date()
        )
        gameDate = clamped.0
        gameStartTime = clamped.1
        numberOfTVs = 1
        crowdLevel = "Moderate"
        liveOccupancy = "Open seats"
        reservationsAvailable = false
        waitlistAvailable = false
        showSpecialsFields = false
        cleanupDelayHours = 48
    }

    private func refreshAnalyticsGameHistory() async {
        await MainActor.run {
            analyticsGameHistoryLoading = true
            analyticsGameHistoryError = ""
        }
        guard let bid = viewModel.currentBusinessIdForAddLocation() else {
            await MainActor.run {
                analyticsGameHistoryForYear = []
                analyticsGameHistoryLoading = false
                analyticsGameHistoryError = ""
            }
            return
        }
        do {
            let rows = try await viewModel.loadBusinessGameHistory(businessId: bid, year: analyticsGameHistoryYear)
            await MainActor.run {
                analyticsGameHistoryForYear = rows
                analyticsGameHistoryLoading = false
            }
        } catch {
            await MainActor.run {
                analyticsGameHistoryForYear = []
                analyticsGameHistoryLoading = false
                analyticsGameHistoryError = error.localizedDescription
            }
        }
    }

    private func monthShortName(_ month: Int) -> String {
        let f = DateFormatter()
        f.locale = .current
        let idx = max(0, min(11, month - 1))
        guard idx < f.shortMonthSymbols.count else { return "\(month)" }
        return f.shortMonthSymbols[idx]
    }

    private func formatHistorySchedule(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        let fIn = ISO8601DateFormatter()
        fIn.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate, .withColonSeparatorInTime]
        var d = fIn.date(from: iso)
        if d == nil {
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            d = f2.date(from: iso)
        }
        guard let d else { return iso }
        let out = DateFormatter()
        out.locale = .current
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: d)
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
        .background(FGAdaptiveSurface.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)
        )
    }
    
    private func field(_ placeholder: String, text: Binding<String>, locked: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 10) {
            TextField(placeholder, text: text)
                .foregroundStyle(.primary)
                .disabled(locked)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FGAdaptiveSurface.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22)
                    .accessibilityLabel("Verified — locked")
            }
        }
        .opacity(locked ? 0.78 : 1)
    }

    private func syncDisplayedVenuePhotoURLsFromViewModel() {
        displayedCoverPhotoURL = viewModel.venueCoverPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        displayedMenuPhotoURL = viewModel.venueMenuPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
        return VenueOwnerListingPhotoPickerCard(
            title: title,
            subtitle: subtitle,
            pickerSelection: selection,
            remotePreviewURL: previewURL,
            localPreviewData: nil
        )
    }

    private func primaryButtonText(_ text: String) -> some View {
        Text(text)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
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
    let onCleanupDelayChange: (Int) -> Void
    let onCancel: () -> Void

    @State private var retentionPickerHours: Int = 48

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
                    .background(FGAdaptiveSurface.controlFill)
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Remove game data after")
                    .font(.caption2.weight(.semibold))
                Picker("Retention hours", selection: $retentionPickerHours) {
                    Text("24h").tag(24)
                    Text("48h").tag(48)
                    Text("72h").tag(72)
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 4)

            HStack(spacing: 10) {
                Button(action: onEditTitle) {
                    Text("Edit title")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(FGAdaptiveSurface.capsuleUnselected)
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
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            retentionPickerHours = row.cleanup_delay_hours ?? 48
        }
        .onChange(of: eventID) { _, _ in
            retentionPickerHours = row.cleanup_delay_hours ?? 48
        }
        .onChange(of: row.cleanup_delay_hours) { _, newHours in
            retentionPickerHours = newHours ?? 48
        }
        .onChange(of: retentionPickerHours) { _, newVal in
            let cur = row.cleanup_delay_hours ?? 48
            if newVal != cur {
                onCleanupDelayChange(newVal)
            }
        }
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
        let catalogEmoji = SportFilterCatalog.resolve(sport).emoji
        if !catalogEmoji.isEmpty { return catalogEmoji }
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
                    let listingStatus = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                    if listingStatus == "archived" {
                        Text("Cancelled")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.18))
                            .foregroundStyle(Color.orange)
                            .clipShape(Capsule())
                    } else if isLiveToday {
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
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(FGAdaptiveSurface.capsuleUnselected)
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
            .background(FGAdaptiveSurface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.55), lineWidth: 1)
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
                .background(FGAdaptiveSurface.capsuleUnselected)
                .foregroundStyle(.primary)
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
                .fill(FGAdaptiveSurface.cardElevated)
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.55), lineWidth: 1)
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
        .background(FGAdaptiveSurface.controlFill)
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

