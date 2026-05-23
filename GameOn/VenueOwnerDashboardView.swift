import CoreLocation
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
    /// Settings → Business Dashboard: premium venue hub overview first, with quick actions into existing flows.
    case overviewDashboard
    /// Settings → Manage Venue: venue profile, address, photos, features only.
    case profileEditor
    /// Settings → Manage Games: add / edit / cancel venue games.
    case gamesManager
    /// Settings → Statistics: engagement analytics only.
    case analyticsViewer
}

struct VenueOwnerDashboardView: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject private var fanUpdatesStore: FanUpdatesRealtimeStore
    var entryPoint: VenueOwnerDashboardEntryPoint = .allTabs
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSection: VenueDashboardSection = .overview

    @State private var gameTitle = ""
    @State private var gameTeam1 = ""
    @State private var gameTeam2 = ""
    @State private var gameTeam1Selection = ManualVenueTeamSelection(name: "", type: .custom, countryCode: nil)
    @State private var gameTeam2Selection = ManualVenueTeamSelection(name: "", type: .custom, countryCode: nil)
    @State private var lastGeneratedGameTitle = ""
    @State private var titleManuallyEdited = false
    @State private var gameLeague = ""
    @State private var seating = ""
    @State private var socialCoordination = ""
    @State private var gameDate = Date()
    @State private var gameStartTime = Date()
    @State private var hasFood = false
    @State private var hasWifi = false
    @State private var hasGarden = false
    @State private var hasProjector = false
    @State private var isPetFriendly = false
    /// Local-only until Supabase venue profile exposes matching columns (not sent in ``saveVenueProfile``).
    @State private var hasParkingAvailable = false
    @State private var hasEasyParking = false
    @State private var isFamilyFriendly = false
    @State private var hasHandicapParking = false
    @State private var hasLiveMusic = false
    @State private var hasPoolTables = false
    @State private var hasRooftop = false
    @State private var hasDJNights = false
    @State private var hasKaraoke = false
    @State private var hasCocktails = false
    @State private var hasCraftBeer = false
    @State private var totalScreens = 1
    @State private var profileSaveMessage = ""
    @State private var venueStreetAddress = ""
    @State private var venueAddressLine2 = ""
    @State private var venueCity = ""
    @State private var venueState = ""
    @State private var venueZipCode = ""
    @State private var venueCountry = BusinessLocationCountryPolicy.defaultCountryCode
    @State private var venueLatitude: Double?
    @State private var venueLongitude: Double?
    @State private var venueFormattedAddress = ""
    @State private var selectedCoverPhoto: PhotosPickerItem?
    @State private var selectedMenuPhoto: PhotosPickerItem?
    @State private var showVenuePinPicker = false
    @State private var showVenueSupporterPicker = false
    @State private var showDeleteVenueConfirmation = false
    @State private var isDeletingVenue = false
    @State private var venueDeleteError = ""
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

    private enum BusinessGameCreationMode: String, CaseIterable {
        case manual = "Manual Entry"
        case importLive = "Import From Live Games"
    }

    private enum DashboardScrollTarget {
        static let addGameFormFields = "venue-owner-add-game-form-fields"
    }

    private var manualPredictionTeamValidationMessage: String {
        L10n.t("add_both_teams_predictions", languageCode: appLanguageRaw)
    }

    @State private var manageGamesListTab: ManageGamesListTab = .scheduled
    @State private var gameCreationMode: BusinessGameCreationMode = .manual
    @State private var didPickInitialManageGamesTab = false
    @State private var myVenueGamesForManage: [VenueEventRow] = []
    @State private var manageGamesListLoading = false
    /// Prevents stacked ``refreshManageGamesList`` runs (e.g. profile `.task` + games `.task` churn) from freezing UI.
    @State private var manageGamesRefreshInFlight = false
    @State private var manageGamesFeedback = ""
    @State private var manageGamesError = ""
    @State private var isSavingNewGame = false
    @State private var titleEditTarget: VenueOwnerGameTitleEditTarget?
    @State private var titleEditDraft = ""
    @State private var showCancelGameDialog = false
    @State private var cancelGameRowSnapshot: VenueEventRow?
    @State private var cleanupDelayHours: Int = VenueOwnerGameDataRetentionHours.defaultPickerHours
    @State private var showVenueOwnerContactSupport = false
    @State private var showAddLocationSheet = false
    @State private var addLocationSubmitBanner: String?
    @StateObject private var addLocationSheetFormState = AddLocationSheetFormState()
    @State private var showSchedulePicker = false
    @State private var schedulePickerDate = Date()
    @State private var importGamesDate = Date()
    @State private var importGamesBrowserExpanded = true
    @State private var importGamesCalendarExpanded = false
    @State private var addGameFormScrollRequestID = 0
    @State private var importGamesSportFilter = "All"
    @State private var importGamesMatches: [LiveMatch] = []
    @State private var isLoadingImportGames = false
    @State private var importGamesError = ""
    @State private var importedExternalGameID: String?
    @State private var importedExternalSource: String?
    @State private var importedExternalLeague: String?
    @State private var importedHomeTeam: String?
    @State private var importedAwayTeam: String?
    @State private var importedFromAPI = false

    init(
        viewModel: MapViewModel,
        entryPoint: VenueOwnerDashboardEntryPoint = .allTabs
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _fanUpdatesStore = ObservedObject(wrappedValue: viewModel.fanUpdatesStore)
        self.entryPoint = entryPoint
    }

    enum VenueDashboardSection: String, CaseIterable {
        case overview = "Overview"
        case profile = "Profile"
        case games = "Games"
        case analytics = "Analytics"

        /// Shown in the segmented control (may differ from ``rawValue`` for clarity).
        var pickerLabel: String {
            switch self {
            case .overview: rawValue
            case .profile, .games: rawValue
            case .analytics: "Analytics"
            }
        }
    }

    private var effectiveSection: VenueDashboardSection {
        switch entryPoint {
        case .allTabs:
            return selectedSection
        case .overviewDashboard:
            return .overview
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

    private func logFanUpdatesStoreMigrationDebug() {
#if DEBUG
        print("[FanUpdatesStoreMigrationDebug] VenueOwnerReadsStore=true")
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
        let _: Void = logFanUpdatesStoreMigrationDebug()

        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    if effectiveSection != .overview {
                        header
                    }

                    if entryPoint == .allTabs {
                        sectionPicker
                    }

                    Group {
                        switch effectiveSection {
                        case .overview:
                            businessDashboardOverviewSection
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
        .onChange(of: addGameFormScrollRequestID) { _, _ in
            guard effectiveSection == .games, manageGamesListTab == .add else { return }
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.28)) {
                    scrollProxy.scrollTo(DashboardScrollTarget.addGameFormFields, anchor: .top)
                }
            }
        }
        .onChange(of: viewModel.ownerVenueDatabaseId) { _, newId in
#if DEBUG
            print("[ManageGamesDebug] ownerVenueDatabaseId changed → \(newId?.uuidString ?? "nil")")
#endif
            clearManageGamesTransientStateForVenueSwitch()
            clearAnalyticsGameHistoryState()
        }
        .onAppear {
            logBusinessDashboardRouteDebug()
            if entryPoint == .overviewDashboard {
                selectedSection = .overview
#if DEBUG
                print("[BusinessDashboardRouteDebug] forcedOverview")
#endif
            }
            if entryPoint != .analyticsViewer {
                Task {
                    await viewModel.stopVenueOwnerAnalyticsRealtime()
                }
            }
            switch effectiveSection {
            case .overview:
                logBusinessDashboardDebug()
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
            case .overview:
                logBusinessDashboardDebug()
            case .games:
                logVenueOwnerToolsGate(screen: "ManageGames")
            case .analytics:
                logVenueOwnerToolsGate(screen: "Analytics")
            case .profile:
                break
            }
        }
        .onChange(of: selectedSection) { _, newValue in
            guard entryPoint == .allTabs || entryPoint == .overviewDashboard else { return }
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
            if effectiveSection == .overview {
                await refreshBusinessDashboardOverview()
            } else if effectiveSection == .analytics {
                await loadVenueAnalytics()
            }
        }
        .onChange(of: viewModel.ownerVenueDatabaseId) { _, _ in
            guard effectiveSection == .analytics else { return }
            Task { await loadVenueAnalytics() }
        }
        .task(id: viewModel.ownerVenueDatabaseId) {
            let managed = await MainActor.run { viewModel.managedVenuesForOwner() }
            guard !managed.isEmpty else {
                await MainActor.run {
#if DEBUG
                    print("[VenueOwnerEmptyStateDebug] noManagedVenues=true")
#endif
                    viewModel.clearSelectedVenueProfileForEmptyState(deletedSelectedVenue: viewModel.ownerVenueDatabaseId)
                    clearLocalVenueProfileFieldsForEmptyState()
                }
                return
            }

            guard let selectedVenueID = await MainActor.run(body: { viewModel.ownerVenueDatabaseId }),
                  managed.contains(where: { $0.id == selectedVenueID }) else {
                await MainActor.run {
                    let stale = viewModel.ownerVenueDatabaseId
                    viewModel.clearSelectedVenueProfileForEmptyState(deletedSelectedVenue: stale)
                    clearLocalVenueProfileFieldsForEmptyState()
                }
                return
            }

            if let saved = await viewModel.loadVenueProfile() {
                await MainActor.run {
                    viewModel.applyVenueProfileRowToOwnerState(saved)
                    applyVenueProfileToLocalEditorFields(saved)
                }
            } else {
                await MainActor.run {
                    viewModel.clearSelectedVenueProfileForEmptyState(deletedSelectedVenue: selectedVenueID)
                    clearLocalVenueProfileFieldsForEmptyState()
                    if viewModel.pendingClaimVenueID != nil {
                        let street = viewModel.ownerVenueAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                        if venueStreetAddress.isEmpty, !street.isEmpty {
                            venueStreetAddress = street
                        }
                        let line2 = viewModel.ownerVenueAddressLine2.trimmingCharacters(in: .whitespacesAndNewlines)
                        if venueAddressLine2.isEmpty, !line2.isEmpty {
                            venueAddressLine2 = line2
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
                        let country = viewModel.ownerVenueCountry.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !country.isEmpty {
                            venueCountry = country
                        }
                    }
                }
            }
            syncDisplayedVenuePhotoURLsFromViewModel()
        }
        
        .onChange(of: selectedCoverPhoto) { _, newItem in
            Task {
                guard let newItem else { return }
                print("[VenuePhotoSaveDebug] pickedImage=true")
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
        .onChange(of: venueCountry) { _, newCountry in
            BusinessLocationCountryPolicy.clearDefaultRegionIfNeeded(&venueState, whenCountryChangesTo: newCountry)
#if DEBUG
            print("[InternationalAddressDebug] selectedCountry=\(BusinessLocationCountryPolicy.normalizedStoredCountryCode(newCountry))")
#endif
        }
        .alert(venueRemovalConfirmationTitle, isPresented: $showDeleteVenueConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(venueRemovalActionTitle, role: .destructive) {
                Task {
                    await performDeleteSelectedVenue()
                }
            }
        } message: {
            Text(venueRemovalConfirmationMessage)
        }
        .sheet(isPresented: $showVenuePinPicker) {
            BusinessVenueLocationPinPickerView(
                viewModel: viewModel,
                initialDraft: venueLocationDraft,
                fallbackCoordinate: viewModel.currentUserLocation ?? CLLocationCoordinate2D(latitude: 40.3916, longitude: -111.8508),
                onCancel: {},
                onConfirm: applyVenueLocationDraft
            )
        }
        .sheet(isPresented: $showVenueSupporterPicker) {
            VenueSupporterCountryPickerSheet(
                currentCountry: viewModel.ownerVenueSupporterCountry,
                onSelect: { country in
                    Task {
                        let success = await viewModel.updateVenueSupporterCountry(country)
                        await MainActor.run {
                            profileSaveMessage = success ? "Fan Zone Identity updated" : "Unable to update Fan Zone Identity"
                        }
                    }
                },
                onClear: {
                    Task {
                        let success = await viewModel.updateVenueSupporterCountry(nil)
                        await MainActor.run {
                            profileSaveMessage = success ? "Fan Zone Identity cleared" : "Unable to clear Fan Zone Identity"
                        }
                    }
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .onChange(of: selectedMenuPhoto) { _, newItem in
            Task {
                guard let newItem else { return }
                print("[VenuePhotoSaveDebug] pickedImage=true")
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let url = await viewModel.uploadVenuePhoto(data: data, fileName: "menu.jpg") {
                    await MainActor.run {
                        viewModel.venueMenuPhotoURL = url
                        displayedMenuPhotoURL = VenueOwnerPhotoPickerCopy.urlWithCacheBust(url)
                        profileSaveMessage = "Photo uploaded. Tap Save Profile to save changes."
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
        .sheet(isPresented: $showAddLocationSheet) {
            AddBusinessLocationRequestSheet(
                viewModel: viewModel,
                form: addLocationSheetFormState,
                submitBanner: $addLocationSubmitBanner,
                isPresented: $showAddLocationSheet
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
            .onAppear {
                if !viewModel.hasAuthenticatedVenueOwnerSession {
                    showAddLocationSheet = false
                }
            }
        }
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
        BusinessLocationVenuePicker(
            viewModel: viewModel,
            chrome: .dashboard,
            onRequestAddNewLocation: { openAddLocationFromBusinessDashboard() }
        )
    }

    private var headerTitle: String {
        switch entryPoint {
        case .profileEditor:
            return "Venue Details"
        case .gamesManager:
            return "Manage games"
        case .analyticsViewer:
            return "Analytics"
        case .overviewDashboard:
            return "Business Dashboard"
        case .allTabs:
            return effectiveSection == .overview ? "Overview" : "Business dashboard"
        }
    }

    private var headerSubtitle: String {
        switch entryPoint {
        case .profileEditor:
            return "Photos, amenities, and venue profile for the selected location."
        case .gamesManager:
            return "Add, edit, or cancel games for the selected location."
        case .analyticsViewer:
            return "Live engagement by game for the selected location."
        case .overviewDashboard:
            return "Live venue energy, games, fans, and performance."
        case .allTabs:
            return effectiveSection == .overview
                ? "Live venue energy, games, fans, and performance."
                : "Manage your locations, schedule, and game-day experience."
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

    private var businessDashboardOverviewSection: some View {
        BusinessVenueDashboardOverviewView(
            data: businessDashboardData,
            onNotifications: {
                withAnimation(.spring()) {
                    selectedSection = .analytics
                }
            },
            onMenu: {
                openBusinessDashboardVenueDetailsOrAddVenue()
            },
            onAddGame: {
                openBusinessDashboardVenueDetailsOrAddVenue()
            },
            onAddVenue: {
                openAddLocationFromBusinessDashboard()
            },
            onTonightGames: {
                openBusinessDashboardGames(tab: .scheduled)
            },
            onPredictions: {
                openBusinessDashboardAnalytics()
            },
            onAnalytics: {
                openBusinessDashboardAnalytics()
            },
            onCommentsReports: {
                openBusinessDashboardAnalytics()
            },
            onViewAllGames: {
                openBusinessDashboardGames(tab: .scheduled)
            },
            onRefreshVenues: {},
            showsManagedVenuesSection: false
        )
        .onAppear {
            logBusinessDashboardDebug()
        }
    }

    private var businessDashboardData: BusinessVenueDashboardData {
        BusinessVenueDashboardData(
            venueName: businessDashboardVenueName,
            locationLine: businessDashboardLocationLine,
            isVerified: viewModel.venueCoreIdentityLockedForSelectedVenue() || viewModel.venueIsApproved,
            managedVenueCount: viewModel.managedVenuesForOwner().count,
            venuePhotoURL: nil,
            venuePhotoThumbnailURL: nil,
            fansGoing: businessDashboardFansGoing,
            activeChats: businessDashboardActiveChats,
            predictions: businessDashboardPredictions,
            atmosphereRating: businessDashboardAtmosphereRating,
            gameSectionContext: businessDashboardGameSectionContext,
            games: businessDashboardGameItems,
            approvedVenues: [],
            pendingVenues: []
        )
    }

    private var businessDashboardVenueName: String {
        let name = viewModel.ownerVenueName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Your venue" : name
    }

    private var businessDashboardLocationLine: String {
        let city = venueCity.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = venueState.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerCity = viewModel.ownerVenueCity.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerState = viewModel.ownerVenueState.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCity = city.isEmpty ? ownerCity : city
        let resolvedState = state.isEmpty ? ownerState : state
        let parts = [resolvedCity, resolvedState].filter { !$0.isEmpty }
        return parts.isEmpty ? "Venue dashboard" : parts.joined(separator: ", ")
    }

    private var venueAddressLabels: BusinessLocationAddressLabels {
        BusinessLocationCountryPolicy.labels(for: venueCountry)
    }

    private var venueLocationDraft: BusinessVenueLocationDraft {
        BusinessVenueLocationDraft(
            addressLine1: venueStreetAddress,
            addressLine2: venueAddressLine2,
            locality: venueCity,
            region: venueState,
            postalCode: venueZipCode,
            countryCode: venueCountry,
            latitude: venueLatitude,
            longitude: venueLongitude,
            formattedAddress: venueFormattedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : venueFormattedAddress
        )
    }

    private var businessDashboardEventIDs: [UUID] {
        myVenueGamesForManage.compactMap(\.id)
    }

    private var businessDashboardFansGoing: Int {
        businessDashboardEventIDs.reduce(0) { $0 + viewModel.interestCountForVenueEvent($1) }
    }

    private var businessDashboardActiveChats: Int {
        businessDashboardEventIDs.reduce(0) { total, id in
            total + (fanUpdatesStore.venueEventComments[id]?.count ?? 0)
        }
    }

    private var businessDashboardPredictions: Int {
        businessDashboardEventIDs.reduce(0) { total, id in
            total + (viewModel.venueEventPredictionSummaries[id]?.totalCount ?? 0)
        }
    }

    private var businessDashboardTodayGamesCount: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return myVenueGamesForManage.reduce(0) { total, row in
            guard let day = venueOwnerGameDay(row),
                  calendar.isDate(day, inSameDayAs: today) else {
                return total
            }
            return total + 1
        }
    }

    private var businessDashboardAtmosphereRating: String {
        guard let venueID = viewModel.ownerVenueDatabaseId,
              let bar = viewModel.bars.first(where: { $0.id == venueID }),
              viewModel.reviewCountDisplay(for: bar) > 0,
              let rating = viewModel.mergedDisplayRating(for: bar) else {
            return "New"
        }
        return String(format: "%.1f", rating)
    }

    private var businessDashboardGameSectionContext: BusinessVenueDashboardGameSectionContext {
        BusinessVenueDashboardGameSectionResolver.resolve(
            gameDates: businessDashboardUpcomingRows.map(\.start),
            calendar: Calendar.current
        )
    }

    private var businessDashboardUpcomingRows: [(row: VenueEventRow, start: Date)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return myVenueGamesForManage.compactMap { row in
            guard let start = businessDashboardGameStartDate(row),
                  calendar.startOfDay(for: start) >= today else {
                return nil
            }
            return (row, start)
        }
        .sorted { $0.start < $1.start }
    }

    private var businessDashboardGameItems: [BusinessVenueDashboardGameItem] {
        let sourceRows = Array(businessDashboardUpcomingRows.prefix(3).map(\.row))

        return sourceRows.compactMap { row in
            guard let id = row.id else { return nil }
            let score = viewModel.venueOwnerEngagementScore(venueEventID: id)
            let energy = businessDashboardEnergy(score: score)
            return BusinessVenueDashboardGameItem(
                id: id,
                title: row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (row.event_title ?? "Game") : "Game",
                subtitle: businessDashboardGameSubtitle(row),
                timeText: businessDashboardGameTimeText(row),
                sportIconName: viewModel.iconForSport(row.sport ?? ""),
                goingCount: viewModel.interestCountForVenueEvent(id),
                energyLabel: energy.label,
                energyTint: energy.tint
            )
        }
    }

    private func businessDashboardGameSubtitle(_ row: VenueEventRow) -> String {
        let league = row.external_league?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let league, !league.isEmpty { return league }
        let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines)
        return sport?.isEmpty == false ? (sport ?? "Venue game") : "Venue game"
    }

    private func businessDashboardGameTimeText(_ row: VenueEventRow) -> String {
        BusinessVenueDashboardGameDateTimeFormatter.compactLabel(
            startDate: FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at),
            eventDateRaw: row.event_date,
            eventTimeRaw: row.event_time,
            timeZoneOption: viewModel.selectedTimeZone,
            calendar: Calendar.current
        )
    }

    private func businessDashboardGameStartDate(_ row: VenueEventRow) -> Date? {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at) {
            return start
        }
        return venueOwnerGameDay(row)
    }

    private func businessDashboardEnergy(score: Int) -> (label: String, tint: Color) {
        if score >= 30 { return ("High energy", FGColor.accentGreen) }
        if score >= 8 { return ("Building", FGColor.accentYellow) }
        return (L10n.t("normal", languageCode: appLanguageRaw), FGColor.accentBlue)
    }

    private func openBusinessDashboardGames(tab: ManageGamesListTab) {
        guard !viewModel.managedVenuesForOwner().isEmpty else {
#if DEBUG
            print("[VenueOwnerEmptyStateDebug] noManagedVenues=true")
#endif
            openAddLocationFromBusinessDashboard()
            return
        }
        guard !venueOwnerGamesAndAnalyticsLocked else { return }
        clearManageGamesBanners()
        manageGamesListTab = tab
        if tab == .add {
            initializeAddGameScheduleFromDefaults()
        }
        withAnimation(.spring()) {
            selectedSection = .games
        }
    }

    private func openBusinessDashboardVenueDetailsOrAddVenue() {
        guard !viewModel.managedVenuesForOwner().isEmpty else {
#if DEBUG
            print("[VenueOwnerEmptyStateDebug] noManagedVenues=true")
#endif
            openAddLocationFromBusinessDashboard()
            return
        }
        withAnimation(.spring()) {
            selectedSection = .profile
        }
    }

    private func openBusinessDashboardAnalytics() {
        guard !venueOwnerGamesAndAnalyticsLocked else { return }
        businessVenueAnalyticsTab = .venueAnalytics
        withAnimation(.spring()) {
            selectedSection = .analytics
        }
    }

    private func refreshBusinessDashboardOverview() async {
        guard !venueOwnerGamesAndAnalyticsLocked else {
            logBusinessDashboardDebug()
            return
        }
        await refreshManageGamesList(isInitialPick: false)
        let ids = await MainActor.run { businessDashboardEventIDs }
        await viewModel.loadVenueEventPredictionSummaries(eventIDs: ids)
        await MainActor.run {
            logBusinessDashboardDebug()
        }
    }

    private func logBusinessDashboardDebug() {
#if DEBUG
        print("[BusinessDashboardDebug] openedOverview")
        print("[BusinessDashboardDebug] venueLoaded=\(!businessDashboardVenueName.isEmpty)")
        print("[BusinessDashboardDebug] todayGamesCount=\(businessDashboardTodayGamesCount)")
        print("[BusinessDashboardDebug] fansGoingTotal=\(businessDashboardFansGoing)")
        print("[BusinessDashboardDebug] activeChatsTotal=\(businessDashboardActiveChats)")
        print("[BusinessDashboardDebug] predictionsTotal=\(businessDashboardPredictions)")
#endif
    }

    private func openAddLocationFromBusinessDashboard() {
#if DEBUG
        print("[AddLocationForm] initialized fresh")
        print("[AddLocationForm] opened from businessDashboard")
#endif
        addLocationSubmitBanner = nil
        addLocationSheetFormState.reset(reason: "businessDashboard")
        showAddLocationSheet = true
    }

    private func logBusinessDashboardRouteDebug() {
#if DEBUG
        print("[BusinessDashboardRouteDebug] entryPoint=\(String(describing: entryPoint))")
        print("[BusinessDashboardRouteDebug] effectiveSection=\(effectiveSection.rawValue)")
#endif
    }

    private func applyVenueLocationDraft(_ draft: BusinessVenueLocationDraft) {
        guard !venueCoreIdentityLocked else { return }
        venueStreetAddress = draft.addressLine1
        venueAddressLine2 = draft.addressLine2
        venueCity = draft.locality
        venueState = draft.region
        venueZipCode = draft.postalCode
        venueCountry = BusinessLocationCountryPolicy.normalizedStoredCountryCode(draft.countryCode)
        venueLatitude = draft.latitude
        venueLongitude = draft.longitude
        venueFormattedAddress = draft.formattedAddress ?? draft.displayAddress
    }

    @MainActor
    private func applyVenueProfileToLocalEditorFields(_ saved: VenueProfileRow) {
        venueStreetAddress = saved.address ?? ""
        venueAddressLine2 = saved.address_line2 ?? ""
        venueCity = saved.city ?? ""
        venueState = saved.state ?? ""
        venueZipCode = saved.zip_code ?? ""
        venueCountry = saved.country ?? BusinessLocationCountryPolicy.defaultCountryCode
        venueLatitude = saved.latitude
        venueLongitude = saved.longitude
        venueFormattedAddress = saved.formatted_address ?? ""

        totalScreens = saved.screen_count ?? 1
        hasFood = saved.serves_food ?? false
        hasWifi = saved.has_wifi ?? false
        hasGarden = saved.has_garden ?? false
        hasProjector = saved.has_projector ?? false
        isPetFriendly = saved.pet_friendly ?? false
        syncModernFeatureToggles(from: saved.features ?? "")
        syncDisplayedVenuePhotoURLsFromViewModel()
    }

    @MainActor
    private func clearLocalVenueProfileFieldsForEmptyState() {
        venueStreetAddress = ""
        venueAddressLine2 = ""
        venueCity = ""
        venueState = ""
        venueZipCode = ""
        venueCountry = BusinessLocationCountryPolicy.defaultCountryCode
        venueLatitude = nil
        venueLongitude = nil
        venueFormattedAddress = ""
        totalScreens = 1
        hasFood = false
        hasWifi = false
        hasGarden = false
        hasProjector = false
        isPetFriendly = false
        displayedCoverPhotoURL = ""
        displayedMenuPhotoURL = ""
        selectedCoverPhoto = nil
        selectedMenuPhoto = nil
        myVenueGamesForManage = []
        manageGamesListLoading = false
        manageGamesRefreshInFlight = false
        clearManageGamesBanners()
    }
    
    private var profileSection: some View {
        dashboardCard(
            title: entryPoint == .profileEditor ? "Venue listing" : "Location profile",
            subtitle: entryPoint == .profileEditor
                ? "Editable items save to the venue selected above."
                : "Basic listing information"
        ) {
            if shouldShowVenueDetailsEmptyState {
                noVenueYetEmptyState
            } else {
            if venueCoreIdentityLocked {
                venueFanGeoVerifiedExplainerCard()
            }

            field("Bar / Pub / Restaurant Name", text: $viewModel.ownerVenueName, locked: venueCoreIdentityLocked)
            BusinessLocationCountryField(countryCode: $venueCountry)
                .disabled(venueCoreIdentityLocked)
                .fanGeoInputFieldStyle()
                .opacity(venueCoreIdentityLocked ? 0.78 : 1)
            field("Address Line 1", text: $venueStreetAddress, locked: venueCoreIdentityLocked)
            field("Address Line 2 (optional)", text: $venueAddressLine2, locked: venueCoreIdentityLocked)
            field(venueAddressLabels.locality, text: $venueCity, locked: venueCoreIdentityLocked)

            HStack(alignment: .center, spacing: 10) {
                BusinessLocationRegionField(countryCode: venueCountry, labels: venueAddressLabels, region: $venueState)
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

            field(venueAddressLabels.postalCode, text: $venueZipCode, locked: venueCoreIdentityLocked)
            BusinessVenueLocationPinPreview(
                draft: venueLocationDraft,
                isLocked: venueCoreIdentityLocked,
                onAdjust: { showVenuePinPicker = true }
            )
            BusinessPhoneNumberField(dialISO: $viewModel.ownerVenuePhoneDialISO, localNumber: $viewModel.ownerVenuePhone)
            field("Website", text: $viewModel.ownerVenueWebsite)
            field("Short Description", text: $viewModel.ownerVenueDescription)
            field("Features: Big Screens, Terrace, Sound On", text: $viewModel.ownerVenueFeatures)
            venueSupporterCountryEditor()

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
                    title: "Others",
                    subtitle: "Examples: menu, gym, patio, bar, seating, entrance",
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

                    viewModel.ownerVenueAddress = venueStreetAddress
                    viewModel.ownerVenueAddressLine2 = venueAddressLine2
                    viewModel.ownerVenueCountry = venueCountry
                    viewModel.ownerVenueFeatures = selectedVenueFeaturesLine()
#if DEBUG
                    print("[VenueFeatureDebug] selectedFeatures=\(viewModel.ownerVenueFeatures)")
#endif
                    Task {
                        let success = await viewModel.saveVenueProfile(
                            streetAddress: venueStreetAddress,
                            addressLine2: venueAddressLine2,
                            city: venueCity,
                            state: venueState,
                            zipCode: venueZipCode,
                            country: venueCountry,
                            pinnedLatitude: venueLatitude,
                            pinnedLongitude: venueLongitude,
                            pinnedFormattedAddress: venueFormattedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : venueFormattedAddress,
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
                                venueAddressLine2 = saved.address_line2 ?? ""
                                venueCity = saved.city ?? ""
                                venueState = saved.state ?? ""
                                venueZipCode = saved.zip_code ?? ""
                                venueCountry = saved.country ?? BusinessLocationCountryPolicy.defaultCountryCode
                                venueLatitude = saved.latitude
                                venueLongitude = saved.longitude
                                venueFormattedAddress = saved.formatted_address ?? ""
                                totalScreens = saved.screen_count ?? 1
                                hasFood = saved.serves_food ?? false
                                hasWifi = saved.has_wifi ?? false
                                hasGarden = saved.has_garden ?? false
                                hasProjector = saved.has_projector ?? false
                                isPetFriendly = saved.pet_friendly ?? false
                                syncModernFeatureToggles(from: saved.features ?? "")
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

            if !venueDeleteError.isEmpty {
                Text(venueDeleteError)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.dangerRed)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            deleteVenueDangerZone
            }
        }
    }

    private var shouldShowVenueDetailsEmptyState: Bool {
        guard let selectedVenueID = viewModel.ownerVenueDatabaseId else { return true }
        return !viewModel.managedVenuesForOwner().contains { $0.id == selectedVenueID }
    }

    private var selectedManagedVenueForRemoval: VenueProfileRow? {
        guard let selectedVenueID = viewModel.ownerVenueDatabaseId else { return nil }
        return viewModel.managedVenuesForOwner().first { $0.id == selectedVenueID }
    }

    private var selectedVenueIsCommunityClaim: Bool {
        selectedManagedVenueForRemoval?.origin_type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "community"
    }

    private var venueRemovalActionTitle: String {
        selectedVenueIsCommunityClaim ? "Remove From My Business" : "Delete Venue"
    }

    private var venueRemovalProgressTitle: String {
        selectedVenueIsCommunityClaim ? "Removing From My Business..." : "Deleting Venue..."
    }

    private var venueRemovalConfirmationTitle: String {
        selectedVenueIsCommunityClaim ? "Remove venue from your business?" : "Delete Venue?"
    }

    private var venueRemovalTint: Color {
        selectedVenueIsCommunityClaim ? .orange : FGColor.dangerRed
    }

    private var noVenueYetEmptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Circle()
                    .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.20 : 0.12))
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(FGColor.accentGreen)
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("No venue yet")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(.primary)
                Text("Add your first venue to manage details and games.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                openAddLocationFromBusinessDashboard()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.subheadline.weight(.bold))
                    Text("Add Venue")
                        .font(.subheadline.weight(.heavy))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(FGColor.accentGreen)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
        )
        .onAppear {
            if viewModel.managedVenuesForOwner().isEmpty {
#if DEBUG
                print("[VenueOwnerEmptyStateDebug] noManagedVenues=true")
#endif
            }
        }
    }

    private var deleteVenueDangerZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(venueRemovalActionTitle)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(venueRemovalTint)
                Text(selectedVenueIsCommunityClaim
                    ? "Remove your ownership, photos, games, and business details from this venue."
                    : "Permanently remove this venue, its games, fan chats, attendance, reactions, saved-venue links, stats, and uploaded venue photos. This does not delete the business account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                venueDeleteError = ""
                showDeleteVenueConfirmation = true
            } label: {
                HStack(spacing: 8) {
                    if isDeletingVenue {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: selectedVenueIsCommunityClaim ? "arrow.uturn.left.circle.fill" : "trash.fill")
                            .font(.caption.weight(.heavy))
                    }
                    Text(isDeletingVenue ? venueRemovalProgressTitle : venueRemovalActionTitle)
                        .font(.subheadline.weight(.heavy))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(venueRemovalTint)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: venueRemovalTint.opacity(colorScheme == .dark ? 0.24 : 0.18), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(isDeletingVenue || viewModel.ownerVenueDatabaseId == nil)
            .opacity(viewModel.ownerVenueDatabaseId == nil ? 0.55 : 1)
            .accessibilityHint(selectedVenueIsCommunityClaim
                ? "Releases this venue back to the community marketplace."
                : "Permanently deletes only this venue and linked venue data.")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(venueRemovalTint.opacity(0.24), lineWidth: 1)
        )
    }

    private var venueRemovalConfirmationMessage: String {
        if selectedVenueIsCommunityClaim {
            return "This removes your ownership, photos, games, and business details from this venue and returns it to the FanGeo community marketplace so another business can claim it."
        }
        return "This permanently deletes the venue and all linked content."
    }

    @MainActor
    private func performDeleteSelectedVenue() async {
        guard let venueId = viewModel.ownerVenueDatabaseId else {
            venueDeleteError = "Select a venue first."
            return
        }

        isDeletingVenue = true
        venueDeleteError = ""
        profileSaveMessage = ""

        do {
            let result = try await viewModel.releaseOrDeleteBusinessVenue(venueId: venueId)
            profileSaveMessage = result.releasedCommunityVenue ? "Venue released successfully." : "Venue deleted successfully."
            syncDisplayedVenuePhotoURLsFromViewModel()
            selectedCoverPhoto = nil
            selectedMenuPhoto = nil

            if entryPoint == .profileEditor {
                try? await Task.sleep(nanoseconds: 450_000_000)
                dismiss()
            } else if effectiveSection == .profile {
                selectedSection = .overview
            }
        } catch {
            venueDeleteError = error.localizedDescription
        }

        isDeletingVenue = false
    }

    private func venueSupporterCountryEditor() -> some View {
        let display = VenueSupporterCountryMode.display(
            for: viewModel.ownerVenueSupporterCountry,
            languageCode: appLanguageRaw
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(display?.flag ?? "🏆")
                    .font(.system(size: 30))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.13)))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Fan Zone Identity")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(.primary)
                    Text(display?.title ?? "Choose a watch-spot country or clear this any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    showVenueSupporterPicker = true
                } label: {
                    Text(display == nil ? "Select country" : "Change country")
                        .font(.caption.weight(.heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.12))
                        .foregroundStyle(FGColor.accentBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)

                if display != nil {
                    Button {
                        Task {
                            let success = await viewModel.updateVenueSupporterCountry(nil)
                            await MainActor.run {
                                profileSaveMessage = success ? "Fan Zone Identity cleared" : "Unable to clear Fan Zone Identity"
                            }
                        }
                    } label: {
                        Text("Clear")
                            .font(.caption.weight(.heavy))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(Color.red.opacity(colorScheme == .dark ? 0.16 : 0.10))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.24 : 0.14), lineWidth: 1)
        }
        .onAppear {
#if DEBUG
            print("[VenueSupporterIdentityDebug] load venueId=\(viewModel.ownerVenueDatabaseId?.uuidString.lowercased() ?? "nil") supporterCountry=\(viewModel.ownerVenueSupporterCountry.isEmpty ? "nil" : viewModel.ownerVenueSupporterCountry)")
#endif
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
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.foodDrinks.iconName, label: VenueFeatureDefinitions.foodDrinks.label, isOn: $hasFood)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.wifi.iconName, label: VenueFeatureDefinitions.wifi.label, isOn: $hasWifi)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.projector.iconName, label: VenueFeatureDefinitions.projector.label, isOn: $hasProjector)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.patio.iconName, label: VenueFeatureDefinitions.patio.label, isOn: $hasGarden)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.rooftop.iconName, label: VenueFeatureDefinitions.rooftop.label, isOn: $hasRooftop)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.liveMusic.iconName, label: VenueFeatureDefinitions.liveMusic.label, isOn: $hasLiveMusic)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.djNights.iconName, label: VenueFeatureDefinitions.djNights.label, isOn: $hasDJNights)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.karaoke.iconName, label: VenueFeatureDefinitions.karaoke.label, isOn: $hasKaraoke)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.poolTables.iconName, label: VenueFeatureDefinitions.poolTables.label, isOn: $hasPoolTables)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.craftBeer.iconName, label: VenueFeatureDefinitions.craftBeer.label, isOn: $hasCraftBeer)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.cocktails.iconName, label: VenueFeatureDefinitions.cocktails.label, isOn: $hasCocktails)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.familyFriendly.iconName, label: VenueFeatureDefinitions.familyFriendly.label, isOn: $isFamilyFriendly)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.petFriendly.iconName, label: VenueFeatureDefinitions.petFriendly.label, isOn: $isPetFriendly)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.easyParking.iconName, label: VenueFeatureDefinitions.easyParking.label, isOn: $hasEasyParking)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.handicapParking.iconName, label: VenueFeatureDefinitions.handicapParking.label, isOn: $hasHandicapParking)
            }
        }
        .padding(12)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func syncModernFeatureToggles(from rawFeatures: String) {
        hasRooftop = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.rooftop)
        hasLiveMusic = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.liveMusic)
        hasDJNights = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.djNights)
        hasKaraoke = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.karaoke)
        hasPoolTables = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.poolTables)
        hasCocktails = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.cocktails)
        hasCraftBeer = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.craftBeer)
        hasHandicapParking = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.handicapParking)
        hasParkingAvailable = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.parkingAvailable)
        hasEasyParking = hasParkingAvailable || venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.easyParking)
        isFamilyFriendly = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.familyFriendly)
    }

    private func selectedVenueFeaturesLine() -> String {
        venueMergedRawFeaturesLine(
            existingRawFeatures: viewModel.ownerVenueFeatures,
            familyFriendly: isFamilyFriendly,
            parkingAvailable: hasParkingAvailable,
            easyParking: hasEasyParking,
            handicapParking: hasHandicapParking,
            liveMusic: hasLiveMusic,
            poolTables: hasPoolTables,
            rooftop: hasRooftop,
            djNights: hasDJNights,
            karaoke: hasKaraoke,
            cocktails: hasCocktails,
            craftBeer: hasCraftBeer
        )
    }

    private let usStates = [
        "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA",
        "HI","ID","IL","IN","IA","KS","KY","LA","ME","MD",
        "MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ",
        "NM","NY","NC","ND","OH","OK","OR","PA","RI","SC",
        "SD","TN","TX","UT","VT","VA","WA","WV","WI","WY"
    ]

    private var analyticsSportFilterOptions: [String] {
        ["All"] + AppSportCatalog.sportsExcludingAll
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
                                fanUpdatesStore: fanUpdatesStore,
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
                                        fanUpdatesStore: fanUpdatesStore,
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
            let m = fanUpdatesStore.venueEventVibeCounts[id] ?? [:]
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
            .onChange(of: manageGamesListTab) { oldTab, newTab in
#if DEBUG
                print("[ManageGamesDebug] manageGamesListTab changed \(oldTab.rawValue) → \(newTab.rawValue)")
#endif
                guard newTab == .add, oldTab != .add else { return }
                initializeAddGameScheduleFromDefaults()
            }

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
                addGamePane
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
#if DEBUG
            print("[ManageGamesDebug] manageGames .task fired ownerVenueId=\(viewModel.ownerVenueDatabaseId?.uuidString ?? "nil")")
#endif
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
        .sheet(isPresented: $showSchedulePicker) {
            VenueOwnerSchedulePickerSheet(
                matches: viewModel.liveMatches,
                isLoading: viewModel.isLoadingLiveMatches,
                selectedDate: $schedulePickerDate,
                onSelect: { choice in
                    applyScheduledGameChoice(choice)
                }
            )
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

            if let bizEmail = resolvedManageGamesBusinessContactEmail() {
                VenueGameBusinessContactEmailRow(email: bizEmail)
                    .padding(.top, 2)
                    .onAppear {
                        let src = myVenueGamesForManage.contains(where: { VenueGameBusinessEmail.resolvedDisplayEmail(forEvent: $0) != nil })
                            ? "venue_events.owner_email"
                            : "session_venue_owner_email"
                        VenueGameBusinessEmail.logDebug(
                            venueId: viewModel.ownerVenueDatabaseId,
                            venueName: viewModel.ownerVenueName.trimmingCharacters(in: .whitespacesAndNewlines),
                            resolvedBusinessEmail: bizEmail,
                            source: src
                        )
                    }
            }

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
                            viewModel: viewModel,
                            row: item.row,
                            eventID: item.id,
                            formattedDateTime: formattedManageGameDateTime(row: item.row),
                            statusLabel: derivedManageGameStatus(row: item.row),
                            goingCount: viewModel.interestCountForVenueEvent(item.id),
                            commentCount: fanUpdatesStore.venueEventComments[item.id]?.count ?? 0,
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
        .onAppear {
#if DEBUG
            print("[ManageGamesDebug] scheduled games list pane appear rows=\(myVenueGamesForManage.count) loading=\(manageGamesListLoading)")
#endif
        }
        .onDisappear {
#if DEBUG
            print("[ManageGamesDebug] scheduled games list pane disappear")
#endif
        }
    }

    private var addGamePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Game")
                .font(.title2)
                .fontWeight(.bold)

            Text("Tell fans what you’re showing. Same details as before — saved to your venue listing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            gameCreationModePicker

            if gameCreationMode == .importLive {
                importFromLiveGamesPane
            }

            addGameFormFields
        }
        .onAppear {
            clearManageGamesErrorIfAddGameScheduleIsFutureValid()
            if Calendar.current.startOfDay(for: importGamesDate) != Calendar.current.startOfDay(for: gameDate) {
                importGamesDate = gameDate
            }
#if DEBUG
            print("[ManageGamesAddPane] render")
            print("[BusinessGameImportDebug] selectedMode=\(gameCreationMode.rawValue)")
#endif
        }
        .onDisappear {
#if DEBUG
            print("[ManageGamesAddPane] disappear")
#endif
        }
    }

    private var manualGameRequiresStructuredTeams: Bool {
        gameCreationMode == .manual && Self.predictionSupportedManualGameSport(viewModel.ownerVenuePrimarySport)
    }

    private var trimmedManualTeam1: String {
        gameTeam1.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedManualTeam2: String {
        gameTeam2.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var manualStructuredTeamsHaveBothTeams: Bool {
        !trimmedManualTeam1.isEmpty
            && !trimmedManualTeam2.isEmpty
    }

    private var manualStructuredTeamsAreDuplicate: Bool {
        manualStructuredTeamsHaveBothTeams
            && trimmedManualTeam1.localizedCaseInsensitiveCompare(trimmedManualTeam2) == .orderedSame
    }

    private var manualStructuredTeamsAreValid: Bool {
        manualStructuredTeamsHaveBothTeams && !manualStructuredTeamsAreDuplicate
    }

    private var saveGameListingDisabled: Bool {
        isSavingNewGame || (manualGameRequiresStructuredTeams && !manualStructuredTeamsAreValid)
    }

    private var gameTitleBinding: Binding<String> {
        Binding(
            get: { gameTitle },
            set: { newValue in
                updateGameTitleFromManualEdit(newValue)
            }
        )
    }

    private static func predictionSupportedManualGameSport(_ sport: String) -> Bool {
        switch normalizedPredictionManualGameSport(sport) {
        case "soccer", "basketball", "baseball", "football", "hockey":
            return true
        default:
            return false
        }
    }

    private static func normalizedPredictionManualGameSport(_ sport: String) -> String {
        let lowered = sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.contains("soccer") { return "soccer" }
        if lowered.contains("basketball") || lowered == "nba" { return "basketball" }
        if lowered.contains("baseball") || lowered == "mlb" { return "baseball" }
        if lowered.contains("football") || lowered == "nfl" { return "football" }
        if lowered.contains("hockey") || lowered == "nhl" { return "hockey" }
        return lowered
    }

    private var gameCreationModePicker: some View {
        Picker("Game creation mode", selection: $gameCreationMode) {
            ForEach(BusinessGameCreationMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: gameCreationMode) { _, newValue in
#if DEBUG
            print("[BusinessGameImportDebug] selectedMode=\(newValue.rawValue)")
#endif
            if newValue == .importLive {
                importGamesDate = gameDate
                importGamesBrowserExpanded = !importedFromAPI
                if importGamesBrowserExpanded {
                    Task { await fetchImportGames(forceRefresh: false) }
                }
            } else {
                clearImportedGameMetadata()
            }
        }
    }

    private var importFromLiveGamesPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import From Live Games")
                        .font(.subheadline.weight(.bold))
                    Text("Pick a real game, then review and save it as a venue listing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if importedFromAPI && !importGamesBrowserExpanded {
                importedLiveGameSummaryCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                importLiveGamesBrowser
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.24), value: importGamesBrowserExpanded)
        .padding()
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.20), lineWidth: 1)
        )
        .task {
            if importGamesBrowserExpanded {
                await fetchImportGames(forceRefresh: false)
            }
        }
    }

    private var importLiveGamesBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            importGamesDateSelector

            importSportFilterChips

            if isLoadingImportGames {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading live/API games...")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !importGamesError.isEmpty {
                importMessageCard(
                    icon: "wifi.exclamationmark",
                    title: "Couldn’t load games",
                    message: "\(importGamesError) Manual Entry is still available."
                )
            } else if filteredImportMatches.isEmpty {
                importMessageCard(
                    icon: "calendar.badge.exclamationmark",
                    title: "No games found for this day.",
                    message: "You can still add one manually."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(filteredImportMatches) { match in
                        Button {
                            Task { await selectImportedLiveGame(match) }
                        } label: {
                            importedGameCard(match)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var importGamesDateSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.20)) {
                    importGamesCalendarExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .accessibilityHidden(true)

                    Text("Game day")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    Text(Self.dateFormatter.string(from: importGamesDate))
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule(style: .continuous))

                    Image(systemName: importGamesCalendarExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(FGAdaptiveSurface.sheetRoot.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select import game day")

            if importGamesCalendarExpanded {
                DatePicker(
                    "Game day",
                    selection: $importGamesDate,
                    in: minimumSelectableGameCalendarDate...Date.distantFuture,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .background(FGAdaptiveSurface.sheetRoot.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: importGamesDate) { _, newDate in
#if DEBUG
            print("[BusinessGameImportDebug] selectedDate=\(Self.debugDateFormatter.string(from: newDate))")
#endif
            withAnimation(.easeInOut(duration: 0.20)) {
                importGamesCalendarExpanded = false
            }
            Task { await fetchImportGames(forceRefresh: true) }
        }
    }

    private var importedLiveGameSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.16))
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.green)
                }
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Imported Game")
                        .font(.caption.weight(.heavy))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.green)

                    Text(importedLiveGameSummaryTitle)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text(importedLiveGameSummaryCompetitionLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("\(Self.dateFormatter.string(from: gameStartTime)) • \(Self.timeFormatter.string(from: gameStartTime))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.24)) {
                    importGamesBrowserExpanded = true
                }
                if importGamesMatches.isEmpty {
                    Task { await fetchImportGames(forceRefresh: false) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.bold))
                    Text("Change Game")
                        .font(.caption.weight(.heavy))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.14))
                .foregroundStyle(Color.orange)
                .clipShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.sheetRoot.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.green.opacity(0.24), lineWidth: 1)
        )
    }

    private var importedLiveGameSummaryTitle: String {
        let title = gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }

        let teams = [
            importedHomeTeam?.trimmingCharacters(in: .whitespacesAndNewlines),
            importedAwayTeam?.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }

        return teams.isEmpty ? "Imported game" : teams.joined(separator: " vs ")
    }

    private var importedLiveGameSummaryCompetitionLine: String {
        let sport = viewModel.ownerVenuePrimarySport.trimmingCharacters(in: .whitespacesAndNewlines)
        let league = gameLeague.trimmingCharacters(in: .whitespacesAndNewlines)
        let importedLeague = importedExternalLeague?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = [
            sport.isEmpty ? "Sports" : sport,
            !league.isEmpty ? league : importedLeague
        ].filter { !$0.isEmpty }

        return parts.joined(separator: " • ")
    }

    private var availableImportSports: [String] {
        var seen = Set<String>()
        return importGamesMatches.compactMap { match in
            let sport = Self.mappedVenueSport(for: match).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sport.isEmpty, seen.insert(sport.lowercased()).inserted else { return nil }
            return sport
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filteredImportMatches: [LiveMatch] {
        importGamesMatches.filter { match in
            guard importGamesSportFilter != "All" else { return true }
            let mapped = Self.mappedVenueSport(for: match)
            return mapped.localizedCaseInsensitiveCompare(importGamesSportFilter) == .orderedSame
                || SportFilterCatalog.storedSport(mapped, matchesSearchQuery: importGamesSportFilter)
        }
    }

    private var importSportFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                importSportChip("All")
                ForEach(availableImportSports, id: \.self) { sport in
                    importSportChip(sport)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func importSportChip(_ sport: String) -> some View {
        let isSelected = importGamesSportFilter == sport
        return Button {
            importGamesSportFilter = sport
#if DEBUG
            print("[BusinessGameImportDebug] apiFetchStarted sport=\(sport)")
#endif
            Task { await fetchImportGames(forceRefresh: false) }
        } label: {
            Text(sport)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.orange : FGAdaptiveSurface.sheetRoot.opacity(0.72))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func importMessageCard(icon: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.bold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.sheetRoot.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func importedGameCard(_ match: LiveMatch) -> some View {
        let sport = Self.mappedVenueSport(for: match)
        let status = VenueOwnerScheduledGameChoice(match: match).statusLabel
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.importedGameTitle(for: match))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(status)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(match.matchStatus.isHappeningNow ? Color.green : Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((match.matchStatus.isHappeningNow ? Color.green : Color.orange).opacity(0.14))
                    .clipShape(Capsule(style: .continuous))
            }

            HStack(spacing: 6) {
                Text(sport)
                    .font(.caption.weight(.semibold))
                Text("/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(match.league)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text("\(Self.dateFormatter.string(from: match.startTime)) at \(Self.timeFormatter.string(from: match.startTime))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Imported game")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule(style: .continuous))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.sheetRoot.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.34), lineWidth: 1)
        )
    }

    private var pickFromSportsScheduleCard: some View {
        Button {
            schedulePickerDate = gameDate
            showSchedulePicker = true
#if DEBUG
            print("[BusinessAddGameDebug] openSchedulePicker=true")
#endif
            Task { await viewModel.refreshLiveMatchesForCalendar(forceRefresh: false) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Pick from sports schedule")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("Search upcoming and live games.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(FGAdaptiveSurface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var manageGamesIdentifiedRows: [VenueOwnerIdentifiedVenueEvent] {
        myVenueGamesForManage.compactMap { row in
            guard let id = row.id else { return nil }
            return VenueOwnerIdentifiedVenueEvent(id: id, row: row)
        }
    }

    /// Business contact for Manage Games list: prefer `venue_events.owner_email`, else signed-in owner email.
    private func resolvedManageGamesBusinessContactEmail() -> String? {
        if let fromRow = myVenueGamesForManage.compactMap({ VenueGameBusinessEmail.resolvedDisplayEmail(forEvent: $0) }).first {
            return fromRow
        }
        let fb = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        return OwnerBusinessEmail.isValidStrict(fb) ? fb : nil
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

    private var addGameFormFields: some View {
        Group {
            field("Game title, example: France vs Brazil", text: gameTitleBinding)
                .id(DashboardScrollTarget.addGameFormFields)
                .onAppear {
#if DEBUG
                    print("[ManageGamesAddPane] title appear")
#endif
                }

            Group {
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
            }
            .onChange(of: gameDate) { oldDate, newDate in
                let cal = Calendar.current
                let sodOld = cal.startOfDay(for: oldDate)
                let sodNew = cal.startOfDay(for: newDate)
                guard sodOld != sodNew else { return }
                let before = gameStartTime
                let now = Date()
                let after = VenueOwnerGameScheduleValidation.recommendedStartTimeAfterGameDateChange(
                    newGameDate: newDate,
                    now: now,
                    calendar: cal
                )
                gameStartTime = after
                manageGamesError = ""
#if DEBUG
                VenueOwnerGameScheduleValidation.logBusinessAddGameTimeDateChange(
                    oldGameDate: oldDate,
                    newGameDate: newDate,
                    startTimeBefore: before,
                    startTimeAfter: after,
                    now: now,
                    calendar: cal
                )
#endif
            }
            .onChange(of: gameStartTime) { _, _ in
                clearManageGamesErrorIfAddGameScheduleIsFutureValid()
            }
            .onAppear {
#if DEBUG
                print("[ManageGamesAddPane] date picker appear")
#endif
            }

            GameSportSearchablePickerDashboardCard(selection: $viewModel.ownerVenuePrimarySport)
                .onAppear {
#if DEBUG
                    print("[ManageGamesAddPane] sport appear")
#endif
                    logBusinessManualGameTeamDebug()
                }
                .onChange(of: viewModel.ownerVenuePrimarySport) { _, _ in
                    handleManualGamePredictionSportChanged()
                }

            if manualGameRequiresStructuredTeams {
                manualStructuredTeamsFields
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if manualGameRequiresStructuredTeams && !manualStructuredTeamsHaveBothTeams {
                Text(manualPredictionTeamValidationMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.dangerRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }

            if manualGameRequiresStructuredTeams && manualStructuredTeamsAreDuplicate {
                Text("Team 1 and Team 2 must be different.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.dangerRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            field("League / competition (optional)", text: $gameLeague)

            addGameCleanupDelayCard

            Button {
#if DEBUG
                print("[ManageGamesAddPane] save tapped")
#endif
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
            .disabled(saveGameListingDisabled)
        }
    }

    private var addGameCleanupDelayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remove game data after")
                .font(.subheadline.weight(.semibold))
            Text("Fan comments, vibes, and attendance rows are deleted; you keep a short summary in History.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("Retention hours", selection: $cleanupDelayHours) {
                ForEach(VenueOwnerGameDataRetentionHours.standardOptions, id: \.self) { h in
                    Text(VenueOwnerGameDataRetentionHours.longLabel(for: h)).tag(h)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding()
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
#if DEBUG
            print("[ManageGamesAddPane] cleanup appear")
#endif
        }
    }

    private var manualStructuredTeamsFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            ManualTeamAutocompleteView(
                title: L10n.t("team_1", languageCode: appLanguageRaw),
                text: Binding(
                get: { gameTeam1 },
                set: { updateManualGameTeam1($0) }
                ),
                sportName: viewModel.ownerVenuePrimarySport,
                unavailableTeamName: trimmedManualTeam2,
                onTextChanged: { query in
                    updateManualGameTeam1(query)
                    logManualTeamAutocompleteQuery(query)
                },
                onSelection: { selection in
                    applyManualGameTeamSelection(selection, teamIndex: 1)
                }
            )

            ManualTeamAutocompleteView(
                title: L10n.t("team_2", languageCode: appLanguageRaw),
                text: Binding(
                get: { gameTeam2 },
                set: { updateManualGameTeam2($0) }
                ),
                sportName: viewModel.ownerVenuePrimarySport,
                unavailableTeamName: trimmedManualTeam1,
                onTextChanged: { query in
                    updateManualGameTeam2(query)
                    logManualTeamAutocompleteQuery(query)
                },
                onSelection: { selection in
                    applyManualGameTeamSelection(selection, teamIndex: 2)
                }
            )
        }
        .onAppear {
            synchronizeManualGameTitleWithTeams()
            logBusinessManualGameTeamDebug()
        }
    }

    private func updateGameTitleFromManualEdit(_ newValue: String) {
        gameTitle = newValue
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let generated = lastGeneratedGameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        titleManuallyEdited = generated.isEmpty ? !trimmed.isEmpty : trimmed != generated
        logBusinessManualGameTeamDebug()
    }

    private func updateManualGameTeam1(_ newValue: String) {
        gameTeam1 = newValue
        gameTeam1Selection = ManualVenueTeamResolver.resolve(newValue)
        logManualGameCountryDetection(gameTeam1Selection)
        synchronizeManualGameTitleWithTeams()
    }

    private func updateManualGameTeam2(_ newValue: String) {
        gameTeam2 = newValue
        gameTeam2Selection = ManualVenueTeamResolver.resolve(newValue)
        logManualGameCountryDetection(gameTeam2Selection)
        synchronizeManualGameTitleWithTeams()
    }

    private func applyManualGameTeamSelection(_ selection: ManualVenueTeamSelection, teamIndex: Int) {
        let otherTeam = teamIndex == 1 ? trimmedManualTeam2 : trimmedManualTeam1
        guard otherTeam.isEmpty || selection.name.localizedCaseInsensitiveCompare(otherTeam) != .orderedSame else { return }
        if teamIndex == 1 {
            gameTeam1 = selection.name
            gameTeam1Selection = selection
        } else {
            gameTeam2 = selection.name
            gameTeam2Selection = selection
        }
#if DEBUG
        print("[BusinessManualGameDebug] teamSuggestionSelected name=\(selection.name) type=\(selection.type.rawValue)")
        if selection.type == .custom {
            print("[BusinessManualGameDebug] customTeamUsed=\(selection.name)")
        }
#endif
        logManualGameCountryDetection(selection)
        synchronizeManualGameTitleWithTeams()
    }

    private func logManualTeamAutocompleteQuery(_ query: String) {
#if DEBUG
        print("[BusinessManualGameDebug] teamAutocompleteQuery=\(query)")
#endif
    }

    private func logManualGameCountryDetection(_ selection: ManualVenueTeamSelection) {
#if DEBUG
        guard selection.type == .country, let code = selection.countryCode else { return }
        print("[BusinessManualGameDebug] countryDetected code=\(code)")
#endif
    }

    private func handleManualGamePredictionSportChanged() {
        synchronizeManualGameTitleWithTeams()
        logBusinessManualGameTeamDebug()
    }

    private func synchronizeManualGameTitleWithTeams() {
        let team1 = trimmedManualTeam1
        let team2 = trimmedManualTeam2
        let previousGenerated = lastGeneratedGameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard manualGameRequiresStructuredTeams, !team1.isEmpty, !team2.isEmpty else {
            logBusinessManualGameTeamDebug(generatedTitle: previousGenerated)
            return
        }

        let generated = "\(team1) vs \(team2)"
        let currentTitle = gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldSyncTitle = currentTitle.isEmpty
            || !titleManuallyEdited
            || (!previousGenerated.isEmpty && currentTitle == previousGenerated)

        lastGeneratedGameTitle = generated
        if shouldSyncTitle {
            gameTitle = generated
            titleManuallyEdited = false
        }

        logBusinessManualGameTeamDebug(generatedTitle: generated)
    }

    private func logBusinessManualGameTeamDebug(generatedTitle: String? = nil) {
#if DEBUG
        let generated = generatedTitle ?? lastGeneratedGameTitle
        print("[BusinessManualGameDebug] selectedSport=\(viewModel.ownerVenuePrimarySport)")
        print("[BusinessManualGameDebug] requiresTeams=\(manualGameRequiresStructuredTeams)")
        print("[BusinessManualGameDebug] team1=\(trimmedManualTeam1)")
        print("[BusinessManualGameDebug] team2=\(trimmedManualTeam2)")
        print("[BusinessManualGameDebug] team1Type=\(gameTeam1Selection.type.rawValue) countryCode=\(gameTeam1Selection.countryCode ?? "none")")
        print("[BusinessManualGameDebug] team2Type=\(gameTeam2Selection.type.rawValue) countryCode=\(gameTeam2Selection.countryCode ?? "none")")
        if gameTeam1Selection.type == .custom, !trimmedManualTeam1.isEmpty {
            print("[BusinessManualGameDebug] customTeamUsed=\(trimmedManualTeam1)")
        }
        if gameTeam2Selection.type == .custom, !trimmedManualTeam2.isEmpty {
            print("[BusinessManualGameDebug] customTeamUsed=\(trimmedManualTeam2)")
        }
        print("[BusinessManualGameDebug] generatedTitle=\(generated)")
        print("[BusinessManualGameDebug] titleManuallyEdited=\(titleManuallyEdited)")
#endif
    }

    private func clearManageGamesBanners() {
        manageGamesFeedback = ""
        manageGamesError = ""
    }

    /// Add Game tab: today at start-of-day + default start time; clears schedule error.
    private func initializeAddGameScheduleFromDefaults() {
        let cal = Calendar.current
        let now = Date()
        gameDate = cal.startOfDay(for: now)
        gameStartTime = VenueOwnerGameScheduleValidation.recommendedStartTimeAfterGameDateChange(
            newGameDate: gameDate,
            now: now,
            calendar: cal
        )
        manageGamesError = ""
    }

    /// Clears the red schedule banner when the combined date+time is valid (not strictly before `now`).
    private func clearManageGamesErrorIfAddGameScheduleIsFutureValid() {
        let cal = Calendar.current
        let now = Date()
        if !VenueOwnerGameScheduleValidation.isPastSchedule(
            gameDate: gameDate,
            gameStartTime: gameStartTime,
            now: now,
            calendar: cal
        ) {
            manageGamesError = ""
        }
    }

    private func applyScheduledGameChoice(_ choice: VenueOwnerScheduledGameChoice) {
        gameTitle = choice.title
        gameTeam1 = choice.homeTeam
        gameTeam2 = choice.awayTeam
        gameTeam1Selection = ManualVenueTeamResolver.resolve(choice.homeTeam)
        gameTeam2Selection = ManualVenueTeamResolver.resolve(choice.awayTeam)
        lastGeneratedGameTitle = choice.title
        titleManuallyEdited = false
        viewModel.ownerVenuePrimarySport = choice.sport
        gameDate = Calendar.current.startOfDay(for: choice.startTime)
        gameStartTime = choice.startTime
        manageGamesError = ""
        showSchedulePicker = false
        synchronizeManualGameTitleWithTeams()
#if DEBUG
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        print("[BusinessAddGameDebug] selectedScheduledGameId=\(choice.id)")
        print("[BusinessAddGameDebug] autopopulatedTitle=\(choice.title)")
        print("[BusinessAddGameDebug] autopopulatedSport=\(choice.sport)")
        print("[BusinessAddGameDebug] autopopulatedStartTime=\(f.string(from: choice.startTime))")
        logBusinessManualGameTeamDebug(generatedTitle: choice.title)
#endif
    }

    private func fetchImportGames(forceRefresh: Bool) async {
        let snapshot = await MainActor.run {
            (
                date: importGamesDate,
                sport: importGamesSportFilter
            )
        }

#if DEBUG
        print("[BusinessGameImportDebug] selectedDate=\(Self.debugDateFormatter.string(from: snapshot.date))")
        print("[BusinessGameImportDebug] apiFetchStarted sport=\(snapshot.sport)")
#endif

        await MainActor.run {
            isLoadingImportGames = true
            importGamesError = ""
        }

        do {
            let matches = try await LiveSportsService.shared.fetchLiveMatches(
                on: snapshot.date,
                sportFilter: nil,
                forceRefresh: forceRefresh
            )
            await MainActor.run {
                importGamesMatches = matches
                if importGamesSportFilter != "All",
                   !availableImportSports.contains(where: { $0.localizedCaseInsensitiveCompare(importGamesSportFilter) == .orderedSame }) {
                    importGamesSportFilter = "All"
                }
                isLoadingImportGames = false
            }
#if DEBUG
            print("[BusinessGameImportDebug] apiFetchResult count=\(matches.count)")
#endif
        } catch {
            await MainActor.run {
                importGamesMatches = []
                importGamesError = error.localizedDescription
                isLoadingImportGames = false
            }
#if DEBUG
            print("[BusinessGameImportDebug] apiFetchResult count=0 error=\(error.localizedDescription)")
#endif
        }
    }

    private func selectImportedLiveGame(_ match: LiveMatch) async {
        let title = Self.importedGameTitle(for: match)
        let mappedSport = Self.mappedVenueSport(for: match)
        let externalSource = LiveSportsService.providerDescription
        let venueId = await MainActor.run { viewModel.ownerVenueDatabaseId }

#if DEBUG
        print("[BusinessGameImportDebug] selectedExternalGame id=\(match.id)")
#endif

        let duplicate = await viewModel.venueGameImportDuplicateExists(
            externalGameID: match.id,
            externalSource: externalSource,
            venueId: venueId,
            gameDate: match.startTime
        )
        guard !duplicate else {
            await MainActor.run {
                manageGamesError = "This game already exists for this venue."
                manageGamesFeedback = ""
            }
            return
        }

        await MainActor.run {
            gameTitle = title
            lastGeneratedGameTitle = title
            titleManuallyEdited = false
            viewModel.ownerVenuePrimarySport = mappedSport
            gameDate = Calendar.current.startOfDay(for: match.startTime)
            gameStartTime = match.startTime
            gameLeague = match.league
            gameTeam1 = match.homeTeam
            gameTeam2 = match.awayTeam
            gameTeam1Selection = ManualVenueTeamResolver.resolve(match.homeTeam)
            gameTeam2Selection = ManualVenueTeamResolver.resolve(match.awayTeam)
            importedExternalGameID = match.id
            importedExternalSource = externalSource
            importedExternalLeague = match.league.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : match.league
            importedHomeTeam = match.homeTeam
            importedAwayTeam = match.awayTeam
            importedFromAPI = true
            importGamesBrowserExpanded = false
            importGamesCalendarExpanded = false
            addGameFormScrollRequestID += 1
            manageGamesError = ""
            manageGamesFeedback = "Game details imported — review and save."
        }

#if DEBUG
        print("[BusinessGameImportDebug] populatedTitle=\(title)")
#endif
    }

    nonisolated fileprivate static func importedGameTitle(for match: LiveMatch) -> String {
        let home = match.homeTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = match.awayTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty, !away.isEmpty { return "\(home) vs \(away)" }
        return [home, away].filter { !$0.isEmpty }.joined(separator: " vs ")
    }

    nonisolated fileprivate static func mappedVenueSport(for match: LiveMatch) -> String {
        let direct = match.sport.trimmingCharacters(in: .whitespacesAndNewlines)
        let visual = LiveSportVisualType.normalize(direct)
        switch visual {
        case .basketball:
            return "NBA"
        case .nfl:
            return "NFL"
        case .hockey:
            return "NHL"
        case .baseball:
            return "Baseball"
        case .soccer:
            return "Soccer"
        case .tennis:
            return "Tennis"
        case .golf:
            return "Golf"
        case .formula1:
            return "Formula 1"
        case .other:
            return direct.isEmpty ? "Sports" : direct
        }
    }

    /// Clears add/list transient UI when the owner switches managed location (see ``MapViewModel/ownerVenueDatabaseId``).
    private func clearManageGamesTransientStateForVenueSwitch() {
        clearManageGamesBanners()
        isSavingNewGame = false
        titleEditTarget = nil
        showCancelGameDialog = false
        cancelGameRowSnapshot = nil
        didPickInitialManageGamesTab = false
        manageGamesRefreshInFlight = false
        manageGamesListLoading = false
        gameCreationMode = .manual
        importGamesMatches = []
        importGamesError = ""
        clearImportedGameMetadata()
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let debugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

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
        let entered = await MainActor.run { () -> Bool in
            guard !manageGamesRefreshInFlight else { return false }
            manageGamesRefreshInFlight = true
            manageGamesListLoading = true
            return true
        }
        guard entered else {
#if DEBUG
            print("[ManageGamesDebug] refreshManageGamesList skipped (already in flight) isInitialPick=\(isInitialPick)")
#endif
            return
        }

#if DEBUG
        print("[ManageGamesDebug] refreshManageGamesList begin isInitialPick=\(isInitialPick)")
#endif

        let rows = await viewModel.loadMyVenueScheduledGames()
#if DEBUG
        print("[ManageGamesDebug] loadMyVenueScheduledGames returned count=\(rows.count)")
#endif
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
            manageGamesRefreshInFlight = false

            if isInitialPick, !didPickInitialManageGamesTab {
                didPickInitialManageGamesTab = true
                let nextTab: ManageGamesListTab = rows.isEmpty ? .add : .scheduled
                if manageGamesListTab != nextTab {
                    manageGamesListTab = nextTab
                }
            }
#if DEBUG
            print("[ManageGamesDebug] refreshManageGamesList end rows=\(rows.count) tab=\(manageGamesListTab.rawValue)")
#endif
        }
    }

    private func saveNewVenueGameFromForm() async {
        let trimmedTitle: String
        let scheduleStillPast: Bool
        let requiresStructuredTeams: Bool
        let manualTeam1: String
        let manualTeam2: String
        (trimmedTitle, scheduleStillPast, requiresStructuredTeams, manualTeam1, manualTeam2) = await MainActor.run {
            let cal = Calendar.current
            let now = Date()
            let clamped = VenueOwnerGameScheduleValidation.clampGameDateAndTimeToMinimumNow(
                gameDate: gameDate,
                gameStartTime: gameStartTime,
                now: now,
                calendar: cal
            )
            gameDate = clamped.0
            gameStartTime = clamped.1
            VenueOwnerGameScheduleValidation.logBusinessAddGameSaveDebug(
                gameDate: gameDate,
                gameStartTime: gameStartTime,
                now: now,
                calendar: cal
            )
            let t = gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let past = VenueOwnerGameScheduleValidation.isPastSchedule(
                gameDate: gameDate,
                gameStartTime: gameStartTime,
                now: now,
                calendar: cal
            )
            logBusinessManualGameTeamDebug()
            return (t, past, manualGameRequiresStructuredTeams, trimmedManualTeam1, trimmedManualTeam2)
        }

        if requiresStructuredTeams, manualTeam1.isEmpty || manualTeam2.isEmpty {
            await MainActor.run {
                manageGamesError = manualPredictionTeamValidationMessage
                manageGamesFeedback = ""
                logBusinessManualGameTeamDebug()
            }
            return
        }

        if requiresStructuredTeams,
           manualTeam1.localizedCaseInsensitiveCompare(manualTeam2) == .orderedSame {
            await MainActor.run {
                manageGamesError = "Team 1 and Team 2 must be different."
                manageGamesFeedback = ""
                logBusinessManualGameTeamDebug()
            }
            return
        }

        guard !trimmedTitle.isEmpty else {
            await MainActor.run {
                manageGamesError = "Enter a game title before saving."
                manageGamesFeedback = ""
            }
            return
        }

        if scheduleStillPast {
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

        let snapshot = await MainActor.run {
            (
                sport: viewModel.ownerVenuePrimarySport,
                gameDate: gameDate,
                gameStartTime: gameStartTime,
                soundOn: true,
                teamFanbase: "",
                gameLeague: gameLeague,
                crowdLevel: "Moderate",
                liveOccupancy: "Open seats",
                seating: seating,
                numberOfTVs: 1,
                gameSpecial: "",
                coverCharge: "",
                reservationsAvailable: false,
                waitlistAvailable: false,
                cleanupDelayHours: cleanupDelayHours,
                externalGameID: importedFromAPI ? importedExternalGameID : nil,
                externalSource: importedFromAPI ? importedExternalSource : nil,
                externalLeague: { () -> String? in
                    let manualLeague = gameLeague.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !manualLeague.isEmpty { return manualLeague }
                    return importedFromAPI ? importedExternalLeague : nil
                }(),
                importedFromAPI: importedFromAPI,
                homeTeam: importedFromAPI ? importedHomeTeam : (manualGameRequiresStructuredTeams ? trimmedManualTeam1 : nil),
                awayTeam: importedFromAPI ? importedAwayTeam : (manualGameRequiresStructuredTeams ? trimmedManualTeam2 : nil)
            )
        }

        if snapshot.importedFromAPI {
            let duplicate = await viewModel.venueGameImportDuplicateExists(
                externalGameID: snapshot.externalGameID,
                externalSource: snapshot.externalSource,
                venueId: viewModel.ownerVenueDatabaseId,
                gameDate: snapshot.gameDate
            )
            if duplicate {
                await MainActor.run {
                    isSavingNewGame = false
                    manageGamesError = "This game already exists for this venue."
                    manageGamesFeedback = ""
                }
                return
            }
        }

        let result = await viewModel.saveVenueGameListingAsync(
            gameTitle: trimmedTitle,
            sport: snapshot.sport,
            gameDate: snapshot.gameDate,
            gameStartTime: snapshot.gameStartTime,
            soundOn: snapshot.soundOn,
            audioType: snapshot.soundOn ? .full : .none,
            teamFanbase: snapshot.teamFanbase,
            atmosphere: "",
            crowdLevel: snapshot.crowdLevel,
            liveOccupancy: snapshot.liveOccupancy,
            seating: snapshot.seating,
            numberOfTVs: "\(snapshot.numberOfTVs)",
            drinkSpecial: snapshot.gameSpecial,
            coverCharge: snapshot.coverCharge,
            reservationInfo: snapshot.reservationsAvailable ? "Reservations available" : "",
            socialCoordination: snapshot.waitlistAvailable ? "Waitlist available" : "",
            cleanupDelayHours: snapshot.cleanupDelayHours,
            externalGameID: snapshot.externalGameID,
            externalSource: snapshot.externalSource,
            importedFromAPI: snapshot.importedFromAPI,
            externalLeague: snapshot.externalLeague,
            homeTeam: snapshot.homeTeam,
            awayTeam: snapshot.awayTeam
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
        gameTeam1 = ""
        gameTeam2 = ""
        gameTeam1Selection = ManualVenueTeamSelection(name: "", type: .custom, countryCode: nil)
        gameTeam2Selection = ManualVenueTeamSelection(name: "", type: .custom, countryCode: nil)
        lastGeneratedGameTitle = ""
        titleManuallyEdited = false
        gameLeague = ""
        seating = ""
        socialCoordination = ""
        initializeAddGameScheduleFromDefaults()
        cleanupDelayHours = VenueOwnerGameDataRetentionHours.defaultPickerHours
        clearImportedGameMetadata()
    }

    private func clearImportedGameMetadata() {
        importedExternalGameID = nil
        importedExternalSource = nil
        importedExternalLeague = nil
        importedHomeTeam = nil
        importedAwayTeam = nil
        importedFromAPI = false
        importGamesBrowserExpanded = true
        importGamesCalendarExpanded = false
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
        let dict = fanUpdatesStore.venueEventVibeCounts[eventID] ?? [:]
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

private struct VenueSupporterCountryPickerSheet: View {
    let currentCountry: String
    let onSelect: (String) -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var searchText = ""

    private var options: [NationalTeamCountryOption] {
        VenueSupporterCountryMode.allowedOptions(matching: searchText, languageCode: appLanguageRaw)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Fan Zone Identity")
                            .font(.title2.weight(.heavy))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text("Show fans your watch-spot country on venue cards.")
                            .font(.subheadline)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }

                    Button {
                        onClear()
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "xmark.circle")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("None")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                Text("Clear the watch-spot banner identity")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                            }
                            Spacer()
                            if VenueSupporterCountryMode.normalizedStorageValue(currentCountry) == nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(FGColor.accentGreen)
                            }
                        }
                        .padding(12)
                        .background(FGAdaptiveSurface.controlFill)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        TextField("Search countries", text: $searchText)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }
                    .padding()
                    .background(FGAdaptiveSurface.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Allowed countries" : "Matching countries")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .textCase(.uppercase)
                        ForEach(options) { option in
                            countryRow(option)
                        }
                    }
                }
                .padding(18)
            }
            .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("cancel", languageCode: appLanguageRaw)) { dismiss() }
                }
            }
        }
    }

    private func countryRow(_ option: NationalTeamCountryOption) -> some View {
        let isSelected = currentCountry.caseInsensitiveCompare(option.name) == .orderedSame
            || VenueSupporterCountryMode.display(for: currentCountry, languageCode: appLanguageRaw)?.countryCode == option.code

        return Button {
#if DEBUG
            print("[VenueSupporterIdentityDebug] save venueId=ownerToolsPicker supporterCountry=\(option.name)")
#endif
            onSelect(option.name)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(option.flag)
                    .font(.title2)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(VenueSupporterCountryMode.display(for: option.name, languageCode: appLanguageRaw)?.title ?? option.code)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FGColor.accentGreen)
                }
            }
            .padding(12)
            .background(FGAdaptiveSurface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private nonisolated struct VenueOwnerScheduledGameChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let sport: String
    let league: String?
    let homeTeam: String
    let awayTeam: String
    let startTime: Date
    let status: MatchStatus
    let externalProviderId: String?

    init(match: LiveMatch) {
        id = match.id
        title = VenueOwnerDashboardView.importedGameTitle(for: match)
        sport = VenueOwnerDashboardView.mappedVenueSport(for: match)
        league = match.league.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : match.league
        homeTeam = match.homeTeam
        awayTeam = match.awayTeam
        startTime = match.startTime
        status = match.matchStatus
        externalProviderId = match.id
    }

    var isLive: Bool {
        status.isHappeningNow
    }

    var statusLabel: String {
        switch status {
        case .live:
            return "Live"
        case .halfTime:
            return "Halftime"
        case .scheduled:
            return "Upcoming"
        case .fullTime:
            return "Final"
        }
    }
}

private struct VenueOwnerSchedulePickerSheet: View {
    let matches: [LiveMatch]
    let isLoading: Bool
    @Binding var selectedDate: Date
    let onSelect: (VenueOwnerScheduledGameChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery = ""
    @State private var selectedSport = "All"

    private var allChoices: [VenueOwnerScheduledGameChoice] {
        let now = Date()
        return matches
            .filter { match in
                switch match.matchStatus {
                case .live, .halfTime:
                    return true
                case .scheduled:
                    return match.startTime >= now
                case .fullTime:
                    return false
                }
            }
            .map(VenueOwnerScheduledGameChoice.init(match:))
            .sorted { lhs, rhs in
                if lhs.isLive != rhs.isLive {
                    return lhs.isLive && !rhs.isLive
                }
                if lhs.startTime != rhs.startTime {
                    return lhs.startTime < rhs.startTime
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private var availableSports: [String] {
        let sports = allChoices.map(\.sport)
        var seen = Set<String>()
        return sports.filter { sport in
            let key = sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private var filteredChoices: [VenueOwnerScheduledGameChoice] {
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: selectedDate)

        return allChoices.filter { choice in
            let choiceDay = calendar.startOfDay(for: choice.startTime)
            let dateMatches = choiceDay == selectedDay || (choice.isLive && calendar.isDateInToday(selectedDay))
            guard dateMatches else { return false }

            return choiceMatchesActiveFilters(choice)
        }
    }

    private var gamesFoundForSelectedDate: Int {
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: selectedDate)
        return allChoices.filter { choice in
            let choiceDay = calendar.startOfDay(for: choice.startTime)
            return choiceDay == selectedDay || (choice.isLive && calendar.isDateInToday(selectedDay))
        }.count
    }

    private var nextAvailableGames: [VenueOwnerScheduledGameChoice] {
        let now = Date()
        return allChoices.filter { choice in
            guard choice.startTime >= now else { return false }
            return choiceMatchesActiveFilters(choice)
        }
    }

    private var visibleNextAvailableGames: [VenueOwnerScheduledGameChoice] {
        Array(nextAvailableGames.prefix(3))
    }

    private var showingUpcomingFallback: Bool {
        filteredChoices.isEmpty && !visibleNextAvailableGames.isEmpty
    }

    private func choiceMatchesActiveFilters(_ choice: VenueOwnerScheduledGameChoice) -> Bool {
        if selectedSport != "All",
           choice.sport.localizedCaseInsensitiveCompare(selectedSport) != .orderedSame {
            return false
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return choice.title.localizedCaseInsensitiveContains(query)
            || choice.sport.localizedCaseInsensitiveContains(query)
            || (choice.league?.localizedCaseInsensitiveContains(query) ?? false)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                searchField
                dateSelector
                sportFilterChips

                if isLoading && allChoices.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading games...")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                } else if filteredChoices.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredChoices) { choice in
                                Button {
                                    onSelect(choice)
                                } label: {
                                    scheduleRow(choice)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 10)
                    }
                }
            }
            .padding()
            .background(FGAdaptiveSurface.sheetRoot)
            .navigationTitle("Choose Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: searchQuery) { _, newValue in
#if DEBUG
            print("[BusinessAddGameDebug] scheduleSearchQuery=\(newValue)")
#endif
            logScheduleDebug()
        }
        .onAppear {
            logScheduleDebug()
        }
        .onChange(of: selectedDate) { _, _ in
            logScheduleDebug()
        }
        .onChange(of: selectedSport) { _, _ in
            logScheduleDebug()
        }
        .onChange(of: matches) { _, _ in
            logScheduleDebug()
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Search teams, league, sport", text: $searchQuery)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
        }
        .padding()
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var dateSelector: some View {
        DatePicker(
            "Date",
            selection: $selectedDate,
            in: Calendar.current.startOfDay(for: Date())...Date.distantFuture,
            displayedComponents: .date
        )
        .font(.subheadline.weight(.semibold))
        .padding()
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var sportFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sportChip("All")
                ForEach(availableSports, id: \.self) { sport in
                    sportChip(sport)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func sportChip(_ sport: String) -> some View {
        let isSelected = selectedSport == sport
        return Button {
            selectedSport = sport
        } label: {
            Text(sport)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : FGAdaptiveSurface.controlFill)
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: emptyStateIconName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(emptyStateTitle)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(emptyStateSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !visibleNextAvailableGames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next major games")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ForEach(visibleNextAvailableGames) { choice in
                        Button {
                            onSelect(choice)
                        } label: {
                            nextAvailableGameRow(choice)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
        )
    }

    private var emptyStateTitle: String {
        if allChoices.isEmpty {
            return "No sports schedule available right now."
        }

        if gamesFoundForSelectedDate > 0 {
            return "No games match these filters."
        }

        if let next = nextAvailableGames.first, Calendar.current.isDateInToday(next.startTime) {
            return "Next games begin later today."
        }

        if Calendar.current.isDateInToday(selectedDate) {
            return "No live games available right now."
        }

        return "No nearby games for this date."
    }

    private var emptyStateSubtitle: String {
        allChoices.isEmpty
            ? "You can still add a game manually."
            : "Try another date or add a game manually."
    }

    private var emptyStateIconName: String {
        if Calendar.current.isDateInToday(selectedDate) {
            return "dot.radiowaves.left.and.right"
        }
        return "calendar.badge.clock"
    }

    private func nextAvailableGameRow(_ choice: VenueOwnerScheduledGameChoice) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(nextAvailableTimeLabel(for: choice.startTime))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "plus.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(FGAdaptiveSurface.sheetRoot.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func nextAvailableTimeLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let prefix: String
        if calendar.isDateInToday(date) {
            let hour = calendar.component(.hour, from: date)
            prefix = hour >= 17 ? "Tonight" : "Today"
        } else if calendar.isDateInTomorrow(date) {
            prefix = "Tomorrow"
        } else {
            prefix = Self.shortDateFormatter.string(from: date)
        }
        return "\(prefix) \(Self.timeFormatter.string(from: date))"
    }

    private func logScheduleDebug() {
#if DEBUG
        print("[BusinessScheduleDebug] selectedDate=\(Self.debugDateFormatter.string(from: selectedDate))")
        print("[BusinessScheduleDebug] gamesFoundForDate=\(gamesFoundForSelectedDate)")
        print("[BusinessScheduleDebug] nextAvailableGamesCount=\(nextAvailableGames.count)")
        print("[BusinessScheduleDebug] showingUpcomingFallback=\(showingUpcomingFallback)")
#endif
    }

    private func scheduleRow(_ choice: VenueOwnerScheduledGameChoice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(choice.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 6)
                Text(choice.statusLabel)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(choice.isLive ? Color.green : Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((choice.isLive ? Color.green : Color.accentColor).opacity(0.14))
                    .clipShape(Capsule(style: .continuous))
            }

            HStack(spacing: 6) {
                Text(choice.sport)
                    .font(.caption.weight(.semibold))
                if let league = choice.league {
                    Text("/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(league)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text("\(Self.dateFormatter.string(from: choice.startTime)) at \(Self.timeFormatter.string(from: choice.startTime))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.4), lineWidth: 1)
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let debugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct VenueOwnerManageGameRow: View {
    @ObservedObject var viewModel: MapViewModel
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

    @State private var retentionPickerHours: Int = VenueOwnerGameDataRetentionHours.defaultPickerHours

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.event_title ?? "Game")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.primary)

            Text(formattedDateTime)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 8) {
                let sportRaw = (row.sport ?? "—").trimmingCharacters(in: .whitespacesAndNewlines)
                let sportDisplay = sportRaw.isEmpty ? "—" : sportRaw
                let sportEmoji = viewModel.emojiForSport(sportDisplay)
                let sportIcon = viewModel.iconForSport(sportDisplay)
                let sportTint = viewModel.colorForSport(sportDisplay)

                HStack(spacing: 6) {
                    if !sportEmoji.isEmpty {
                        Text(sportEmoji)
                            .font(.system(size: 15))
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: sportIcon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(sportTint)
                            .accessibilityHidden(true)
                    }
                    Text(sportDisplay)
                        .font(.caption.weight(.semibold))
                }
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

                if row.imported_from_api == true {
                    Text("Imported")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            if let league = row.external_league?.trimmingCharacters(in: .whitespacesAndNewlines),
               !league.isEmpty {
                Text(league)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text("\(goingCount) going · \(commentCount) comments · \(vibeTotal) vibes")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Remove game data after")
                    .font(.caption2.weight(.semibold))
                Picker("Retention hours", selection: $retentionPickerHours) {
                    ForEach(VenueOwnerGameDataRetentionHours.segmentedPickerHours(currentSaved: row.cleanup_delay_hours), id: \.self) { h in
                        Text(VenueOwnerGameDataRetentionHours.segmentedLabel(for: h)).tag(h)
                    }
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
            retentionPickerHours = row.cleanup_delay_hours ?? VenueOwnerGameDataRetentionHours.defaultPickerHours
        }
        .onChange(of: eventID) { _, _ in
            retentionPickerHours = row.cleanup_delay_hours ?? VenueOwnerGameDataRetentionHours.defaultPickerHours
        }
        .onChange(of: row.cleanup_delay_hours) { _, newHours in
            retentionPickerHours = newHours ?? VenueOwnerGameDataRetentionHours.defaultPickerHours
        }
        .onChange(of: retentionPickerHours) { _, newVal in
            let cur = row.cleanup_delay_hours ?? VenueOwnerGameDataRetentionHours.defaultPickerHours
            if newVal != cur {
                onCleanupDelayChange(newVal)
            }
        }
    }
}

// MARK: - Venue owner compact analytics row

private struct VenueOwnerCompactAnalyticsRow: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var fanUpdatesStore: FanUpdatesRealtimeStore
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
        fanUpdatesStore.venueEventComments[eventID]?.count ?? 0
    }

    private var audioCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["audio_on"] ?? 0
    }

    private var packedCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["packed"] ?? 0
    }

    private var seatsOpenCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["seats_open"] ?? 0
    }

    private var specialsCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["specials"] ?? 0
    }

    private var tvVisibleCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["tv_visible"] ?? 0
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
        let m = fanUpdatesStore.venueEventVibeCounts[eventID] ?? [:]
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
    @ObservedObject var fanUpdatesStore: FanUpdatesRealtimeStore
    let row: VenueEventRow
    let eventID: UUID
    let isLiveToday: Bool

    private var goingCount: Int {
        viewModel.interestCountForVenueEvent(eventID)
    }

    private var commentCount: Int {
        fanUpdatesStore.venueEventComments[eventID]?.count ?? 0
    }

    private var audioCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["audio_on"] ?? 0
    }

    private var packedCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["packed"] ?? 0
    }

    private var seatsOpenCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["seats_open"] ?? 0
    }

    private var specialsCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["specials"] ?? 0
    }

    private var tvVisibleCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["tv_visible"] ?? 0
    }

    private var score: Int {
        viewModel.venueOwnerEngagementScore(venueEventID: eventID)
    }

    private var topVibeLine: String? {
        let m = fanUpdatesStore.venueEventVibeCounts[eventID] ?? [:]
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

