import Combine
import PhotosUI
import SwiftUI

// MARK: - Bottom spacing (floating tab bar + sheets)

/// Scroll tail insets for the Account tab and settings-presented sheets.
/// `floatingTabBarStackHeight` must stay aligned with ``MainTabView/floatingTabBarStackHeight``.
enum SettingsScrollBottomLayout {
    static let floatingTabBarStackHeight: CGFloat = 78
    static let breathingRoomBelowLastCard: CGFloat = 72
    static var accountTabScrollBottomInset: CGFloat {
        floatingTabBarStackHeight + breathingRoomBelowLastCard
    }

    /// Sheets are not under the main floating tab; use for scrollable tails above the home indicator / drag handle.
    static let sheetScrollComfortInset: CGFloat = 32
}

private enum SettingsPremiumChrome {
    static let cardRadius: CGFloat = 20
    static let rowIconSize: CGFloat = 34
    static let rowMinHeight: CGFloat = 58

    static func cardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.085, green: 0.105, blue: 0.115).opacity(0.72)
            : Color(.secondarySystemGroupedBackground).opacity(0.96)
    }

    static func cardHighlight(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.56)
    }

    static func cardStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.07)
    }

    static func divider(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.065) : Color.black.opacity(0.08)
    }

    static func primaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.92) : Color(red: 0.10, green: 0.12, blue: 0.15)
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.60) : Color(red: 0.38, green: 0.42, blue: 0.50)
    }

    static func mutedText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.36) : Color(red: 0.58, green: 0.62, blue: 0.68)
    }

    static func iconSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.045)
    }

    static func screenBackground(_ scheme: ColorScheme) -> some View {
        ZStack {
            scheme == .dark
                ? Color(red: 0.025, green: 0.032, blue: 0.04)
                : Color(.systemGroupedBackground)
            LinearGradient(
                colors: [
                    Color.white.opacity(scheme == .dark ? 0.035 : 0.56),
                    Color.clear,
                    Color.black.opacity(scheme == .dark ? 0.20 : 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    FGColor.accentGreen.opacity(scheme == .dark ? 0.10 : 0.08),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 12,
                endRadius: 320
            )
        }
    }
}

/// One ``Identifiable`` sheet route for ``VenueOwnerDashboardView`` so only one venue-owner dashboard
/// presentation exists at a time (avoids SwiftUI reusing or stacking multiple ``VenueOwnerDashboardView`` hierarchies
/// across the previous three independent ``.sheet(isPresented:)`` booleans).
private enum VenueOwnerDashboardSheetRoute: String, Identifiable {
    case manageVenue
    case manageGames
    case statistics

    var id: String { rawValue }

    var entryPoint: VenueOwnerDashboardEntryPoint {
        switch self {
        case .manageVenue:
            return .profileEditor
        case .manageGames:
            return .gamesManager
        case .statistics:
            return .analyticsViewer
        }
    }
}

private enum ProfileSettingsRoute: Hashable {
    case liveActivitySharing
    case notifications
    case timeZone
    case appearance
    case support
    case communityGuidelines
    case trustSafety
    case privacyPolicy
    case termsOfService
}

/// Account tab: end-user and venue-owner auth, profile, notifications, Apple Calendar sync, and entry to venue dashboard flows.
struct SettingsScreen: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject private var notificationSettingsStore: NotificationSettingsStore
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme

    init(viewModel: MapViewModel) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._notificationSettingsStore = ObservedObject(wrappedValue: viewModel.notificationSettingsStore)
    }

    @State private var email = ""
    @State private var password = ""
    @State private var venuePassword = ""
    @State private var showRegisterMode = false
    @State private var venueOwnerDashboardSheet: VenueOwnerDashboardSheetRoute?
    @State private var showVenueRegisterMode = false
    @State private var showProfileScreen = false
    @State private var showProfileSettingsSheet = false
    @State private var profileSettingsPath = NavigationPath()
    @State private var showUserAuthSheet = false
    @State private var showVenueAuthSheet = false
    @State private var showLiveSharingModeDialog = false
    @State private var showResetPasswordSheet = false
    @State private var showDeleteAccountSheet = false
    @State private var showDeleteVenueOwnerSheet = false
    @State private var showReportedCommentsSheet = false
    @State private var showVenueOwnerPasswordResetSheet = false
    @State private var showAddLocationSheet = false
    @State private var addLocationSubmitBanner: String?
    /// Holds Add-location draft fields across ``MapViewModel`` publishes (e.g. after photo upload) so the sheet does not reset.
    @StateObject private var addLocationSheetFormState = AddLocationSheetFormState()
    /// Which pending claim row is running ``performPendingClaimRefresh(claimId:)`` (nil = idle).
    @State private var pendingRefreshingClaimId: UUID?
    @AppStorage(FanGeoAppearancePreference.appStorageKey) private var appearancePreferenceRaw = FanGeoAppearancePreference.system.rawValue

    private var appearancePreference: FanGeoAppearancePreference {
        FanGeoAppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    private var liveVisibilityBinding: Binding<Bool> {
        Binding(
            get: { viewModel.currentUserLiveVisibilityEnabled },
            set: { newValue in
                Task { await viewModel.setLiveVisibilityEnabled(newValue) }
            }
        )
    }

    private var liveSharingModeSubtitle: String {
        guard viewModel.currentUserLiveVisibilityEnabled else { return "Hidden from Friends" }
        switch viewModel.currentUserLiveVisibilityMode {
        case .allFriends:
            return "Visible to All Friends"
        case .selectedFriends:
            return "Visible to Selected Friends"
        }
    }

    private var isBusinessAccountForLiveSharing: Bool {
        viewModel.currentUserIsBusinessAccount || viewModel.isVenueOwnerLoggedIn || viewModel.hasAuthenticatedVenueOwnerSession
    }

    private var canShowLiveActivitySharing: Bool {
        viewModel.canUseFanSocialFeatures && !isBusinessAccountForLiveSharing
    }

    /// Full Supabase sign-out for business sessions (same pipeline as fan logout: clears tokens, explicit-logout marker, and owner UI state).
    private func performBusinessAccountLogout() {
        Task { @MainActor in
            await viewModel.logoutUser()
            venueOwnerDashboardSheet = nil
            showVenueOwnerPasswordResetSheet = false
            showReportedCommentsSheet = false
            showDeleteVenueOwnerSheet = false
        }
    }

    private func logSettingsBusinessVenueSectionVisibilityForFanAccount() {
        guard viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn else { return }
        print("[SettingsVisibility] hiding business venue section for fan account")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if viewModel.isLoggedIn {
                        ProfileIdentityCard(
                            viewModel: viewModel,
                            showProfileScreen: $showProfileScreen
                        )
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                    } else if viewModel.isVenueOwnerLoggedIn {
                        SettingsProfileHero(
                            viewModel: viewModel,
                            showProfileScreen: $showProfileScreen,
                            venueOwnerOnResetPassword: { showVenueOwnerPasswordResetSheet = true },
                            venueOwnerOnDismissSheetsAfterLogout: {
                                venueOwnerDashboardSheet = nil
                                showVenueOwnerPasswordResetSheet = false
                                showReportedCommentsSheet = false
                                showDeleteVenueOwnerSheet = false
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                    } else {
                        SettingsUnifiedAccountEntryCard(
                            onSignIn: {
                                showRegisterMode = false
                                showUserAuthSheet = true
                            },
                            onCreateAccount: {
                                showRegisterMode = true
                                showUserAuthSheet = true
                            },
                            onVenueOwnerTools: nil
                        )
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                    }

                } header: {
                    settingsSectionHeader("Profile")
                }

                if viewModel.isVenueOwnerLoggedIn || !viewModel.isLoggedIn {
                    Section {
                        settingsSectionCard {
                            let hasArchivedBusinessAccount = viewModel.hasArchivedBusinessAccountForOwner()
                            let hasActiveBusinessAccount = viewModel.hasBusinessAccountForOwner()

                            if viewModel.isVenueOwnerLoggedIn {
                                if viewModel.isVenueOwnerBusinessDataLoading {
                                    HStack(spacing: 10) {
                                        ProgressView()
                                        Text("Loading business data…")
                                            .font(FGTypography.caption)
                                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    }
                                    .padding(.horizontal, FGSpacing.md)
                                    .padding(.vertical, FGSpacing.md)
                                } else if hasArchivedBusinessAccount {
                                    settingsInfoRow(
                                        title: "Business account",
                                        subtitle: settingsBusinessAccountSubtitle(),
                                        systemImage: viewModel.businessAccountStatusIconName(),
                                        tint: viewModel.businessAccountStatusTint()
                                    )

                                    settingsRowDivider()

                                    settingsInfoRow(
                                        title: "Location status",
                                        subtitle: viewModel.businessSettingsLocationStatusSubtitle(),
                                        systemImage: viewModel.businessSettingsLocationStatusSystemImage(),
                                        tint: settingsLocationStatusTint()
                                    )
                                } else if !hasActiveBusinessAccount && !hasArchivedBusinessAccount {
                                    settingsInfoRow(
                                        title: "Business account",
                                        subtitle: settingsBusinessAccountSubtitle(),
                                        systemImage: viewModel.businessAccountStatusIconName(),
                                        tint: viewModel.businessAccountStatusTint()
                                    )

                                    settingsRowDivider()

                                    settingsInlineNote(
                                        "Add a businesses record for this sign-in email before locations can be linked or approved.",
                                        systemImage: "info.circle"
                                    )

                                    settingsRowDivider()

                                    Button {
                                        venueOwnerDashboardSheet = .manageVenue
                                    } label: {
                                        settingsRow(
                                            title: "Set up business account",
                                            subtitle: "Open the business dashboard to finish account and listing details.",
                                            systemImage: "rectangle.and.pencil.and.ellipsis"
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    settingsRowDivider()

                                    settingsInfoRow(
                                        title: "Location status",
                                        subtitle: viewModel.businessSettingsLocationStatusSubtitle(),
                                        systemImage: viewModel.businessSettingsLocationStatusSystemImage(),
                                        tint: settingsLocationStatusTint()
                                    )

                                } else if viewModel.managedVenuesForOwner().isEmpty {
                                    settingsInfoRow(
                                        title: "Business account",
                                        subtitle: settingsBusinessAccountSubtitle(),
                                        systemImage: viewModel.businessAccountStatusIconName(),
                                        tint: viewModel.businessAccountStatusTint()
                                    )

                                    settingsRowDivider()

                                    settingsInfoRow(
                                        title: "Location status",
                                        subtitle: viewModel.businessSettingsLocationStatusSubtitle(),
                                        systemImage: viewModel.businessSettingsLocationStatusSystemImage(),
                                        tint: settingsLocationStatusTint()
                                    )

                                    settingsRowDivider()

                                    BusinessLocationVenuePicker(
                                        viewModel: viewModel,
                                        chrome: .settings,
                                        onRequestAddNewLocation: { openAddLocationFromPicker() }
                                    )

                                    if let bannerText = addLocationSubmitBannerDisplayText(), !bannerText.isEmpty {
                                        settingsRowDivider()
                                        settingsInlineNote(
                                            bannerText,
                                            tint: addLocationSubmitBannerForegroundColor(),
                                            systemImage: "info.circle"
                                        )
                                    }

                                    settingsRowDivider()

                                    settingsVenueReviewSections()
                                } else {
                                    settingsInfoRow(
                                        title: "Business account",
                                        subtitle: settingsBusinessAccountSubtitle(),
                                        systemImage: viewModel.businessAccountStatusIconName(),
                                        tint: viewModel.businessAccountStatusTint()
                                    )

                                    if let bannerText = addLocationSubmitBannerDisplayText(), !bannerText.isEmpty {
                                        settingsRowDivider()
                                        settingsInlineNote(
                                            bannerText,
                                            tint: addLocationSubmitBannerForegroundColor(),
                                            systemImage: "info.circle"
                                        )
                                    }

                                    settingsRowDivider()

                                    BusinessLocationVenuePicker(
                                        viewModel: viewModel,
                                        chrome: .settings,
                                        onRequestAddNewLocation: { openAddLocationFromPicker() }
                                    )

                                    settingsRowDivider()

                                    settingsVenueReviewSections()

                                    settingsRowDivider()

                                    Button { venueOwnerDashboardSheet = .manageVenue } label: {
                                        settingsRow(
                                            title: "Venue Details",
                                            subtitle: "Photos, amenities, and venue profile.",
                                            systemImage: "photo.on.rectangle.angled"
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    if settingsVenueClaimApprovedForStatusRow() {
                                        settingsRowDivider()

                                        Button { venueOwnerDashboardSheet = .manageGames } label: {
                                            settingsRow(
                                                title: "Manage Games",
                                                subtitle: "Schedule or cancel games.",
                                                systemImage: "sportscourt"
                                            )
                                        }
                                        .buttonStyle(.plain)

                                        settingsRowDivider()

                                        Button { venueOwnerDashboardSheet = .statistics } label: {
                                            settingsRow(
                                                title: "Statistics",
                                                subtitle: "Analytics and game history.",
                                                systemImage: "chart.bar"
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                settingsRowDivider()

                                Button { showReportedCommentsSheet = true } label: {
                                    settingsRow(
                                        title: "Flagged Comments",
                                        subtitle: "Review reported venue activity.",
                                        systemImage: "exclamationmark.bubble"
                                    )
                                }
                                .buttonStyle(.plain)
                            } else {
                                Button {
                                    showVenueRegisterMode = false
                                    showVenueAuthSheet = true
                                } label: {
                                    settingsRow(
                                        title: "Venue owner tools",
                                        subtitle: "Sign in to manage claims, listings, games, and business tools.",
                                        systemImage: "building.2.crop.circle"
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                        .task(id: viewModel.isVenueOwnerLoggedIn) {
                            if viewModel.isVenueOwnerLoggedIn {
                                await viewModel.refreshPendingVenueClaimsForSettings()
                            }
                        }
#if DEBUG
                        .onAppear {
                            viewModel.logBusinessAccountStateDebug()
                        }
#endif
                    } header: {
                        settingsSectionHeader("Business & Venue")
                    }
                }

            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: SettingsScrollBottomLayout.accountTabScrollBottomInset)
            }
            .listStyle(.plain)
            .listSectionSpacing(10)
            .scrollContentBackground(.hidden)
            .background(SettingsPremiumChrome.screenBackground(colorScheme).ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showProfileSettingsSheet = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel("Open settings")
                }
            }
            .onAppear {
                logSettingsBusinessVenueSectionVisibilityForFanAccount()
                Task {
                    await viewModel.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
                    if viewModel.canFanUsePickupGamesUI {
                        await viewModel.loadMyPickupGamesForSettings()
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let toast = viewModel.socialActionToastText, !toast.isEmpty {
                settingsSocialToastBanner(
                    text: toast,
                    isError: viewModel.socialActionToastIsError
                )
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .onChange(of: viewModel.openVenueOwnerAuthSheetFromClaimFlow) { _, shouldPresent in
            guard shouldPresent else { return }
            showVenueAuthSheet = true
            viewModel.openVenueOwnerAuthSheetFromClaimFlow = false
        }
        .onChange(of: viewModel.presentFanUserAuthSheetFromDiscover) { _, shouldPresent in
            guard shouldPresent else { return }
            showRegisterMode = viewModel.fanUserAuthSheetOpenInRegisterMode
            showUserAuthSheet = true
            viewModel.presentFanUserAuthSheetFromDiscover = false
            viewModel.fanUserAuthSheetOpenInRegisterMode = false
        }
        .onChange(of: showUserAuthSheet) { _, isPresented in
            password = ""
            if isPresented {
                venuePassword = ""
            }
        }
        .onChange(of: showVenueAuthSheet) { _, isPresented in
            venuePassword = ""
            if isPresented {
                password = ""
            }
        }
        .onChange(of: showProfileSettingsSheet) { _, isPresented in
            if !isPresented {
                profileSettingsPath = NavigationPath()
            }
        }
        .onChange(of: viewModel.isLoggedIn) { _, _ in
            password = ""
            logSettingsBusinessVenueSectionVisibilityForFanAccount()
        }
        .onChange(of: viewModel.isVenueOwnerLoggedIn) { _, _ in
            venuePassword = ""
            logSettingsBusinessVenueSectionVisibilityForFanAccount()
        }
        .onChange(of: viewModel.hasAuthenticatedVenueOwnerSession) { _, isBusiness in
            if !isBusiness {
                venueOwnerDashboardSheet = nil
                showReportedCommentsSheet = false
                showAddLocationSheet = false
            }
        }
        .sheet(item: $venueOwnerDashboardSheet) { route in
            VenueOwnerDashboardView(viewModel: viewModel, entryPoint: route.entryPoint)
                .id(route.id)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(isPresented: $showUserAuthSheet) {
            SettingsUserAuthSheet(
                viewModel: viewModel,
                email: $email,
                password: $password,
                showRegisterMode: $showRegisterMode
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showVenueAuthSheet) {
            SettingsVenueAuthSheet(
                viewModel: viewModel,
                venuePassword: $venuePassword,
                showVenueRegisterMode: $showVenueRegisterMode,
                onRequestVenueProfileDashboard: { venueOwnerDashboardSheet = .manageVenue }
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
        .sheet(isPresented: $showProfileSettingsSheet) {
            profileSettingsSheet
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(isPresented: Binding(
            get: { showLiveSharingModeDialog && canShowLiveActivitySharing },
            set: { if !$0 { showLiveSharingModeDialog = false } }
        )) {
            LiveActivitySharingOptionsSheet(
                isEnabled: viewModel.currentUserLiveVisibilityEnabled,
                mode: viewModel.currentUserLiveVisibilityMode,
                friends: chatViewModel.friends.filter { !$0.preview.isBusinessAccount },
                selectedFriendIDs: viewModel.currentUserSelectedLiveVisibilityFriendIDs,
                isSaving: viewModel.isUpdatingLiveVisibilitySetting,
                onChooseOff: {
                    Task {
                        await viewModel.setLiveVisibilitySettings(
                            enabled: false,
                            mode: viewModel.currentUserLiveVisibilityMode,
                            selectedFriendIDs: viewModel.currentUserSelectedLiveVisibilityFriendIDs
                        )
                        showLiveSharingModeDialog = false
                    }
                },
                onChooseAllFriends: {
                    Task {
                        await viewModel.setLiveVisibilitySettings(
                            enabled: true,
                            mode: .allFriends,
                            selectedFriendIDs: viewModel.currentUserSelectedLiveVisibilityFriendIDs
                        )
                        showLiveSharingModeDialog = false
                    }
                },
                onChooseSelectedFriends: {
                    Task {
                        await chatViewModel.loadIfNeeded()
                        await viewModel.setLiveVisibilitySettings(
                            enabled: true,
                            mode: .selectedFriends,
                            selectedFriendIDs: viewModel.currentUserSelectedLiveVisibilityFriendIDs
                        )
                    }
                },
                onLoadFriends: {
                    Task { await chatViewModel.loadIfNeeded() }
                },
                onToggleFriend: { friendID in
                    var selectedIDs = viewModel.currentUserSelectedLiveVisibilityFriendIDs
                    if selectedIDs.contains(friendID) {
                        selectedIDs.remove(friendID)
                    } else {
                        selectedIDs.insert(friendID)
                    }
                    guard selectedIDs != viewModel.currentUserSelectedLiveVisibilityFriendIDs else { return }
                    Task {
                        await viewModel.setLiveVisibilitySettings(
                            enabled: true,
                            mode: .selectedFriends,
                            selectedFriendIDs: selectedIDs
                        )
                    }
                },
                onClose: { showLiveSharingModeDialog = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(isPresented: $showResetPasswordSheet) {
            NavigationStack {
                Form { SettingsFanPasswordResetCard(viewModel: viewModel, loginEmail: $email) }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
                    }
                    .navigationTitle("Reset Password")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showResetPasswordSheet = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showVenueOwnerPasswordResetSheet) {
            NavigationStack {
                Form { SettingsVenuePasswordResetCard(viewModel: viewModel) }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
                    }
                    .navigationTitle("Reset venue password")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showVenueOwnerPasswordResetSheet = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showDeleteAccountSheet) {
            SettingsAccountDeletionSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showDeleteVenueOwnerSheet) {
            SettingsVenueOwnerDeletionSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showReportedCommentsSheet) {
            NavigationStack {
                ScrollView {
                    SettingsReportedCommentsAdminCard(viewModel: viewModel)
                        .padding()
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
                }
                .navigationTitle("Flagged Comments")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showReportedCommentsSheet = false }
                    }
                }
            }
            .onAppear {
                if !viewModel.hasAuthenticatedVenueOwnerSession {
                    showReportedCommentsSheet = false
                }
            }
        }
    }

    private var profileSettingsSheet: some View {
        NavigationStack(path: $profileSettingsPath) {
            List {
                profileSettingsPrivacySection()
                profileSettingsNotificationsSection()
                profileSettingsExperienceSection()
                profileSettingsHelpSafetySection()
                profileSettingsLegalSection()
                profileSettingsAccountSection()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .listStyle(.plain)
            .listSectionSpacing(10)
            .scrollContentBackground(.hidden)
            .background(SettingsPremiumChrome.screenBackground(colorScheme).ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: ProfileSettingsRoute.self) { route in
                profileSettingsDestination(route)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showProfileSettingsSheet = false }
                }
            }
        }
        .tint(FGColor.accentGreen)
    }

    @ViewBuilder
    private func profileSettingsDestination(_ route: ProfileSettingsRoute) -> some View {
        switch route {
        case .liveActivitySharing:
            liveActivitySharingDestination

        case .notifications:
            ScrollView {
                SettingsGameNotificationsCard(viewModel: viewModel, notificationSettingsStore: notificationSettingsStore)
                    .padding(.horizontal, FGSpacing.lg)
                    .padding(.top, FGSpacing.lg)
            }
            .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)

        case .timeZone:
            Form { SettingsTimeZoneCard(viewModel: viewModel) }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
                }
                .navigationTitle("Time Zone")
                .navigationBarTitleDisplayMode(.inline)

        case .appearance:
            FanGeoAppearanceSelectionView(selectionRaw: $appearancePreferenceRaw)
                .navigationTitle("Appearance")
                .navigationBarTitleDisplayMode(.inline)

        case .support:
            ContactGameOnSupportSheet(
                viewModel: viewModel,
                onRequestSignIn: {
                    showProfileSettingsSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showUserAuthSheet = true
                    }
                },
                embedsInNavigationStack: false,
                showsCloseButton: false
            )

        case .communityGuidelines:
            SettingsLegalDocumentSheet(
                document: .communityGuidelines,
                embedsInNavigationStack: false,
                showsCloseButton: false
            )

        case .trustSafety:
            SettingsLegalDocumentSheet(
                document: .safetyReporting,
                embedsInNavigationStack: false,
                showsCloseButton: false
            )

        case .privacyPolicy:
            SettingsLegalDocumentSheet(
                document: .privacyPolicy,
                embedsInNavigationStack: false,
                showsCloseButton: false
            )

        case .termsOfService:
            SettingsLegalDocumentSheet(
                document: .termsOfService,
                embedsInNavigationStack: false,
                showsCloseButton: false
            )
        }
    }

    private var liveActivitySharingDestination: some View {
        LiveActivitySharingOptionsSheet(
            isEnabled: viewModel.currentUserLiveVisibilityEnabled,
            mode: viewModel.currentUserLiveVisibilityMode,
            friends: chatViewModel.friends.filter { !$0.preview.isBusinessAccount },
            selectedFriendIDs: viewModel.currentUserSelectedLiveVisibilityFriendIDs,
            isSaving: viewModel.isUpdatingLiveVisibilitySetting,
            onChooseOff: {
                Task {
                    await viewModel.setLiveVisibilitySettings(
                        enabled: false,
                        mode: viewModel.currentUserLiveVisibilityMode,
                        selectedFriendIDs: viewModel.currentUserSelectedLiveVisibilityFriendIDs
                    )
                }
            },
            onChooseAllFriends: {
                Task {
                    await viewModel.setLiveVisibilitySettings(
                        enabled: true,
                        mode: .allFriends,
                        selectedFriendIDs: viewModel.currentUserSelectedLiveVisibilityFriendIDs
                    )
                }
            },
            onChooseSelectedFriends: {
                Task {
                    await chatViewModel.loadIfNeeded()
                    await viewModel.setLiveVisibilitySettings(
                        enabled: true,
                        mode: .selectedFriends,
                        selectedFriendIDs: viewModel.currentUserSelectedLiveVisibilityFriendIDs
                    )
                }
            },
            onLoadFriends: {
                Task { await chatViewModel.loadIfNeeded() }
            },
            onToggleFriend: { friendID in
                var selectedIDs = viewModel.currentUserSelectedLiveVisibilityFriendIDs
                if selectedIDs.contains(friendID) {
                    selectedIDs.remove(friendID)
                } else {
                    selectedIDs.insert(friendID)
                }
                guard selectedIDs != viewModel.currentUserSelectedLiveVisibilityFriendIDs else { return }
                Task {
                    await viewModel.setLiveVisibilitySettings(
                        enabled: true,
                        mode: .selectedFriends,
                        selectedFriendIDs: selectedIDs
                    )
                }
            },
            onClose: {},
            embedsInNavigationStack: false,
            showsCloseButton: false
        )
    }

    private func presentFromProfileSettings(_ present: @escaping () -> Void) {
        showProfileSettingsSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            present()
        }
    }

    @ViewBuilder
    private func profileSettingsAccountSection() -> some View {
        if viewModel.isLoggedIn || viewModel.isVenueOwnerLoggedIn {
            Section {
                settingsSectionCard {
                    if viewModel.isLoggedIn {
                        Button {
                            presentFromProfileSettings { showResetPasswordSheet = true }
                        } label: {
                            settingsRow(title: "Reset Password", subtitle: "Send a reset email.", systemImage: "key")
                        }
                        .buttonStyle(.plain)

                        if viewModel.isVenueOwnerLoggedIn {
                            settingsRowDivider()

                            Button {
                                presentFromProfileSettings { showVenueOwnerPasswordResetSheet = true }
                            } label: {
                                settingsRow(title: "Reset venue password", subtitle: "Send a venue owner reset email.", systemImage: "key")
                            }
                            .buttonStyle(.plain)
                        }
                    } else if viewModel.isVenueOwnerLoggedIn {
                        Button {
                            presentFromProfileSettings { showVenueOwnerPasswordResetSheet = true }
                        } label: {
                            settingsRow(title: "Reset venue password", subtitle: "Send a venue owner reset email.", systemImage: "key")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)

                settingsSectionCard {
                    if viewModel.isLoggedIn {
                        Button {
                            showProfileSettingsSheet = false
                            Task { await viewModel.logoutUser() }
                        } label: {
                            settingsRow(title: "Logout", subtitle: nil, systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(.plain)

                        settingsRowDivider()

                        Button {
                            presentFromProfileSettings { showDeleteAccountSheet = true }
                        } label: {
                            settingsRow(
                                title: "Delete account",
                                subtitle: "Permanent removal.",
                                systemImage: "trash",
                                tint: FGColor.dangerRed.opacity(0.82)
                            )
                        }
                        .buttonStyle(.plain)

                        if viewModel.isVenueOwnerLoggedIn {
                            settingsRowDivider()

                            Button {
                                presentFromProfileSettings { showDeleteVenueOwnerSheet = true }
                            } label: {
                                settingsRow(
                                    title: "Delete venue access",
                                    subtitle: "Remove owner profile, listings, and uploads.",
                                    systemImage: "trash",
                                    tint: FGColor.dangerRed.opacity(0.82)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    } else if viewModel.isVenueOwnerLoggedIn {
                        Button {
                            showProfileSettingsSheet = false
                            performBusinessAccountLogout()
                        } label: {
                            settingsRow(
                                title: "Logout",
                                subtitle: "Sign out of this business account.",
                                systemImage: "rectangle.portrait.and.arrow.right"
                            )
                        }
                        .buttonStyle(.plain)

                        settingsRowDivider()

                        Button {
                            presentFromProfileSettings { showDeleteVenueOwnerSheet = true }
                        } label: {
                            settingsRow(
                                title: "Delete account",
                                subtitle: "Permanent owner profile removal.",
                                systemImage: "trash",
                                tint: FGColor.dangerRed.opacity(0.82)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            } header: {
                settingsSectionHeader("Account")
            }
        }
    }

    @ViewBuilder
    private func profileSettingsPrivacySection() -> some View {
        if canShowLiveActivitySharing {
            Section {
                settingsSectionCard {
                    Button {
                        profileSettingsPath.append(ProfileSettingsRoute.liveActivitySharing)
                    } label: {
                        settingsRow(title: "Live Activity Sharing", subtitle: liveSharingModeSubtitle, systemImage: "person.2.wave.2.fill", showsChevron: true)
                    }
                    .buttonStyle(.plain)
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            } header: {
                settingsSectionHeader("Privacy & Social")
            }
        }
    }

    private func profileSettingsNotificationsSection() -> some View {
        Section {
            settingsSectionCard {
                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.notifications)
                } label: {
                    settingsRow(title: "Notifications", subtitle: notificationSettingsStore.notifyBeforeGame ? "On" : "Off", systemImage: "bell.badge", showsChevron: true)
                }
                .buttonStyle(.plain)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            settingsSectionHeader("Notifications")
        }
    }

    private func profileSettingsExperienceSection() -> some View {
        Section {
            settingsSectionCard {
                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.timeZone)
                } label: {
                    settingsRow(title: "Time Zone", subtitle: viewModel.selectedTimeZone.rawValue, systemImage: "clock", showsChevron: true)
                }
                .buttonStyle(.plain)

                settingsRowDivider()

                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.appearance)
                } label: {
                    settingsRow(
                        title: "Appearance",
                        subtitle: appearancePreference.displayName,
                        systemImage: "circle.lefthalf.filled",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            settingsSectionHeader("Experience")
        }
    }

    private func profileSettingsHelpSafetySection() -> some View {
        Section {
            settingsSectionCard {
                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.support)
                } label: {
                    settingsRow(
                        title: "Support",
                        subtitle: "Message the FanGeo team.",
                        systemImage: "envelope.open.fill",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)

                settingsRowDivider()

                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.communityGuidelines)
                } label: {
                    settingsRow(
                        title: SettingsLegalDocumentKind.communityGuidelines.title,
                        subtitle: SettingsLegalDocumentKind.communityGuidelines.rowSubtitle,
                        systemImage: SettingsLegalDocumentKind.communityGuidelines.systemImage,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)

                settingsRowDivider()

                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.trustSafety)
                } label: {
                    settingsRow(
                        title: SettingsLegalDocumentKind.safetyReporting.title,
                        subtitle: SettingsLegalDocumentKind.safetyReporting.rowSubtitle,
                        systemImage: SettingsLegalDocumentKind.safetyReporting.systemImage,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            settingsSectionHeader("Help & Safety")
        }
    }

    private func profileSettingsLegalSection() -> some View {
        Section {
            settingsSectionCard {
                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.privacyPolicy)
                } label: {
                    settingsRow(
                        title: SettingsLegalDocumentKind.privacyPolicy.title,
                        subtitle: SettingsLegalDocumentKind.privacyPolicy.rowSubtitle,
                        systemImage: SettingsLegalDocumentKind.privacyPolicy.systemImage,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)

                settingsRowDivider()

                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.termsOfService)
                } label: {
                    settingsRow(
                        title: SettingsLegalDocumentKind.termsOfService.title,
                        subtitle: SettingsLegalDocumentKind.termsOfService.rowSubtitle,
                        systemImage: SettingsLegalDocumentKind.termsOfService.systemImage,
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            settingsSectionHeader("Legal")
        }
    }

    @ViewBuilder
    private func settingsSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme).opacity(0.72))
            .tracking(0.8)
            .textCase(nil)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }



    private func settingsSectionCard<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        SettingsSectionCardContainer(content: content)
    }

    private struct SettingsSectionCardContainer<Content: View>: View {
        let content: () -> Content
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .fill(SettingsPremiumChrome.cardFill(colorScheme))
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    SettingsPremiumChrome.cardHighlight(colorScheme),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.20 : 0.08), radius: 14, y: 7)
        }
    }

    @ViewBuilder
    private func settingsRowDivider() -> some View {
        Divider()
            .overlay(SettingsPremiumChrome.divider(colorScheme))
            .opacity(0.42)
            .padding(.leading, 58)
            .padding(.trailing, FGSpacing.md)
    }

    @ViewBuilder
    private func settingsDestructiveSpacer() -> some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(SettingsPremiumChrome.divider(colorScheme))
                .opacity(0.22)
                .padding(.leading, 58)
                .padding(.trailing, FGSpacing.md)
            Color.clear
                .frame(height: 6)
        }
    }

    @ViewBuilder
    private func settingsInlineNote(
        _ text: String,
        tint: Color? = nil,
        systemImage: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            if let systemImage, !systemImage.isEmpty {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint ?? FGColor.mutedText(colorScheme))
                    .padding(.top, 2)
            }

            Text(text)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(tint ?? SettingsPremiumChrome.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func settingsRow(title: String, subtitle: String?, systemImage: String, tint: Color = FGColor.accentGreen, showsChevron: Bool = true) -> some View {
        settingsRow(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint, showsChevron: showsChevron) {
            EmptyView()
        }
    }

    @ViewBuilder
    private func settingsRow<Trailing: View>(
        title: String,
        subtitle: String?,
        systemImage: String,
        tint: Color = FGColor.accentGreen,
        showsChevron: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            trailing()

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                    .frame(width: 14, height: 14, alignment: .center)
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func liveActivitySharingRow() -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            HStack(alignment: .center, spacing: FGSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(FGColor.accentBlue)
                }
                .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Live Activity Sharing")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                        .lineLimit(2)
                    Text(liveSharingModeSubtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !viewModel.isUpdatingLiveVisibilitySetting else { return }
                showLiveSharingModeDialog = true
            }

            Spacer(minLength: 0)

            if viewModel.isUpdatingLiveVisibilitySetting {
                ProgressView()
                    .controlSize(.small)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                .frame(width: 14, height: 14, alignment: .center)

            Toggle("Live Activity Sharing", isOn: liveVisibilityBinding)
                .labelsHidden()
                .disabled(viewModel.isUpdatingLiveVisibilitySetting)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !viewModel.isUpdatingLiveVisibilitySetting else { return }
            showLiveSharingModeDialog = true
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func settingsToggleRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Binding<Bool>,
        isUpdating: Bool,
        tint: Color = FGColor.accentBlue
    ) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isUpdating {
                ProgressView()
                    .controlSize(.small)
            }

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .disabled(isUpdating)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    /// Non-interactive settings row (no chevron) for read-only info such as venue claim status.
    @ViewBuilder
    private func settingsInfoRow(title: String, subtitle: String?, systemImage: String, tint: Color = FGColor.accentGreen) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func settingsVenueClaimApprovedForStatusRow() -> Bool {
        viewModel.venueOwnerToolsUnlockedForUI()
    }

    /// Reloads businesses, managed venues, pending claims, and selected venue (via ``MapViewModel/refreshOwnedBusinessesAndVenuesAfterOwnerLogin()``), then claim status line.
    private func performPendingClaimRefresh(claimId: UUID) async {
#if DEBUG
        print("[PendingLocationRefresh] tapped claim_id=\(claimId.uuidString)")
#endif
        await MainActor.run { pendingRefreshingClaimId = claimId }
        defer {
            Task { @MainActor in
                if pendingRefreshingClaimId == claimId {
                    pendingRefreshingClaimId = nil
                }
            }
        }
        await viewModel.refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        await viewModel.refreshPendingVenueClaimsForSettings()
        await viewModel.refreshVenueClaimStatusLineFromDatabase()
#if DEBUG
        let pendingCount = await MainActor.run { viewModel.pendingVenueClaimsForSettings.count }
        let rejectedCount = await MainActor.run { viewModel.rejectedVenueClaimsForSettings.count }
        let managedCount = await MainActor.run { viewModel.managedVenuesForOwner().count }
        print("[PendingLocationRefresh] complete pendingClaims=\(pendingCount) rejectedClaims=\(rejectedCount) managedVenues=\(managedCount)")
#endif
    }

    private func settingsApprovedVenueRows() -> [VenueProfileRow] {
        viewModel.managedVenuesForOwner()
            .sorted {
                let lhs = $0.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let rhs = $1.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    @ViewBuilder
    private func settingsVenueReviewSections() -> some View {
        let approvedCount = settingsApprovedVenueRows().count
        let pendingCount = viewModel.pendingVenueClaimsForSettings.count
        let rejectedCount = viewModel.rejectedVenueClaimsForSettings.count

        VStack(alignment: .leading, spacing: 0) {
            Text("Venue portfolio")
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, FGSpacing.md)
                .padding(.bottom, FGSpacing.sm)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FGSpacing.sm) {
                    settingsVenueStatusSummaryPill(
                        title: "\(approvedCount) Approved",
                        tint: approvedCount > 0 ? FGColor.accentGreen : FGColor.mutedText(colorScheme)
                    )
                    settingsVenueStatusSummaryPill(
                        title: "\(pendingCount) Pending",
                        tint: pendingCount > 0 ? FGColor.accentYellow : FGColor.mutedText(colorScheme)
                    )
                    settingsVenueStatusSummaryPill(
                        title: "\(rejectedCount) Rejected",
                        tint: rejectedCount > 0 ? FGColor.dangerRed : FGColor.mutedText(colorScheme)
                    )
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.bottom, FGSpacing.md)
            }

            if rejectedCount > 0 {
                settingsBlockDivider()
                rejectedVenueClaimsList()
            }
        }
    }

    @ViewBuilder
    private func settingsVenueStatusSummaryPill(title: String, tint: Color) -> some View {
        FGStatusPill(title: title, kind: .custom(tint: tint))
    }

    @ViewBuilder
    private func settingsBlockDivider() -> some View {
        Divider()
            .overlay(FGColor.divider(colorScheme))
            .padding(.horizontal, FGSpacing.md)
    }

    private static let rejectedVenueClaimMessage =
        "This location request was rejected. Please submit a new venue request."

    @ViewBuilder
    private func rejectedVenueClaimsList() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rejected locations")
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, FGSpacing.md)
                .padding(.bottom, FGSpacing.xs)

            ForEach(Array(viewModel.rejectedVenueClaimsForSettings.enumerated()), id: \.element.id) { index, claim in
                let rowBusy = pendingRefreshingClaimId == claim.id
                let anyRowRefreshing = pendingRefreshingClaimId != nil
                if index > 0 {
                    settingsRowDivider()
                }
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settingsPendingClaimTitle(claim))
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        if let line = settingsPendingClaimCityStateLine(claim) {
                            Text(line)
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                        FGStatusPill(title: "Rejected", kind: .custom(tint: FGColor.dangerRed))
                        Text(Self.rejectedVenueClaimMessage)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.dangerRed)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 2) {
                        Button {
                            Task {
                                await viewModel.acknowledgeRejectedVenueClaim(claimId: claim.id)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(Color.secondary)
                                Text("Dismiss")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                            .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.58 : 0.96))
                            .clipShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss rejected location message")

                        Button {
                            Task { await performPendingClaimRefresh(claimId: claim.id) }
                        } label: {
                            Group {
                                if rowBusy {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 15, weight: .semibold))
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(anyRowRefreshing ? Color.secondary.opacity(0.45) : Color.secondary)
                                }
                            }
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                            .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.58 : 0.96))
                            .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(anyRowRefreshing || viewModel.isVenueOwnerBusinessDataLoading)
                        .accessibilityLabel("Refresh status for this location")
                    }
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, FGSpacing.md)
                .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: viewModel.rejectedVenueClaimsForSettings.map(\.id))
    }

    private func settingsBusinessAccountSubtitle() -> String {
        if viewModel.hasArchivedBusinessAccountForOwner() {
            return "Business account archived"
        }
        guard viewModel.hasBusinessAccountForOwner() else {
            return "Not set up — no businesses row for this email yet."
        }
        if let member = settingsBusinessMemberSinceLine() {
            return "Active • \(member)"
        }
        return "Active"
    }

    private func settingsBusinessMemberSinceLine() -> String? {
        let raws = viewModel.ownedBusinesses
            .compactMap(\.created_at)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let raw = raws.sorted().first else { return nil }
        guard let date = settingsParseSupabaseTimestamptz(raw) else {
            return "Member since \(raw)"
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return "Member since \(f.string(from: date))"
    }

    private func settingsSocialToastBanner(text: String, isError: Bool) -> some View {
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

    private func settingsParseSupabaseTimestamptz(_ raw: String) -> Date? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: t) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: t)
    }

    private func settingsLocationStatusTint() -> Color {
        switch viewModel.businessSettingsLocationChrome() {
        case .approved:
            return .green
        case .pendingReview:
            return .orange
        case .rejected:
            return .red
        case .archivedBusinessAccount:
            return .red
        case .noLocationsYet, .needsBusinessAccountFirst:
            return .secondary
        }
    }

    private func settingsPendingClaimTitle(_ claim: VenueClaimPendingSettingsRow) -> String {
        let n = claim.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? "Location request" : n
    }

    private func settingsPendingClaimCityStateLine(_ claim: VenueClaimPendingSettingsRow) -> String? {
        let city = claim.venue_city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let st = claim.venue_state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let line = [city, st].filter { !$0.isEmpty }.joined(separator: ", ")
        return line.isEmpty ? nil : line
    }

    /// Presents add-location sheet with a blank form (used from Current managed venue menu).
    private func openAddLocationFromPicker() {
#if DEBUG
        print("[AddLocationForm] initialized fresh")
        print("[AddLocationForm] opened from picker")
#endif
        addLocationSubmitBanner = nil
        addLocationSheetFormState.reset(reason: "open")
        showAddLocationSheet = true
    }

    private func addLocationSubmitBannerForegroundStyle() -> Color {
        if viewModel.hasActiveVenueClaimRejectionForBusinessUI { return .red }
        if viewModel.businessSettingsLocationChrome() == .rejected { return .red }
        return .green
    }

    private func addLocationSubmitBannerForegroundColor() -> Color {
        addLocationSubmitBannerForegroundStyle()
    }

    /// After Add Location succeeds we set ``addLocationSubmitBanner``; copy tracks ``approval_status`` via pending rows + location chrome.
    private func addLocationSubmitBannerDisplayText() -> String? {
        guard addLocationSubmitBanner != nil else { return nil }
        if !viewModel.pendingVenueClaimsForSettings.isEmpty {
            return "Location request submitted. FanGeo will review it before this location can manage games."
        }
        if viewModel.hasActiveVenueClaimRejectionForBusinessUI {
            return Self.rejectedVenueClaimMessage
        }
        switch viewModel.businessSettingsLocationChrome() {
        case .approved:
            return "Your location is approved and can now manage listings, games, and venue activity."
        case .pendingReview:
            return "Location request submitted. FanGeo will review it before this location can manage games."
        case .rejected:
            return Self.rejectedVenueClaimMessage
        case .archivedBusinessAccount:
            return nil
        case .noLocationsYet, .needsBusinessAccountFirst:
            return "Location request submitted. FanGeo will review it before this location can manage games."
        }
    }
}

// MARK: - Phase 4: account deletion (Apple-compliant confirmation sheets)

private struct SettingsAccountDeletionSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmationText: String = ""
    @State private var confirmPassword: String = ""
    @State private var isDeleting: Bool = false
    @State private var errorMessage: String = ""
    @State private var successMessage: String = ""
    @State private var didSucceed: Bool = false

    private var canDelete: Bool {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DELETE"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Deleting your account permanently removes your profile and associated data from FanGeo.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("What will be deleted") {
                    deletionRow("Profile (display name + email reference)")
                    deletionRow("Avatar photo in storage")
                    deletionRow("Comments and activity linked to your user")
                    deletionRow("Chats and friend relationships where applicable")
                    deletionRow("Reports and blocks where applicable")
                }

                Section("Confirm") {
                    TextField("Type DELETE to confirm", text: $confirmationText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    SecureField("Confirm password (optional)", text: $confirmPassword)

                    Text("Password re-auth is not currently enforced in-app. TODO: add re-auth via Supabase if required by policy changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if !successMessage.isEmpty {
                    Section {
                        Text(successMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task { await runDelete() }
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting { ProgressView() }
                            Text(isDeleting ? "Deleting..." : "Delete Account Permanently")
                            Spacer()
                        }
                    }
                    .disabled(!canDelete || isDeleting || didSucceed)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSucceed ? "Done" : "Close") { dismiss() }
                        .disabled(isDeleting)
                }
            }
        }
    }

    @ViewBuilder
    private func deletionRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "minus.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    private func runDelete() async {
        isDeleting = true
        defer { isDeleting = false }
        errorMessage = ""
        successMessage = ""

        do {
            try await viewModel.requestPermanentAccountDeletion()
            await MainActor.run {
                successMessage = "Your account was deleted and you have been signed out."
                didSucceed = true
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct SettingsVenueOwnerDeletionSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmationText: String = ""
    @State private var confirmPassword: String = ""
    @State private var isDeleting: Bool = false
    @State private var errorMessage: String = ""
    @State private var successMessage: String = ""
    @State private var didSucceed: Bool = false

    private var canDelete: Bool {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DELETE"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Deleting your venue owner account permanently removes your venue owner access and associated venue-owner data.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("What will be deleted") {
                    deletionRow("Venue owner profile + access")
                    deletionRow("Venue photos/menu uploads owned by this account")
                    deletionRow("Venue events/listings owned by this account where applicable")
                    deletionRow("Venue claims and pending reviews linked to this owner")
                }

                Section("Confirm") {
                    TextField("Type DELETE to confirm", text: $confirmationText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    SecureField("Confirm password (optional)", text: $confirmPassword)

                    Text("Password re-auth is not currently enforced in-app. TODO: add re-auth via Supabase if required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if !successMessage.isEmpty {
                    Section {
                        Text(successMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task { await runDelete() }
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting { ProgressView() }
                            Text(isDeleting ? "Deleting..." : "Delete Venue Owner Account")
                            Spacer()
                        }
                    }
                    .disabled(!canDelete || isDeleting || didSucceed)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .navigationTitle("Delete Venue Owner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSucceed ? "Done" : "Close") { dismiss() }
                        .disabled(isDeleting)
                }
            }
        }
    }

    @ViewBuilder
    private func deletionRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "minus.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    private func runDelete() async {
        isDeleting = true
        defer { isDeleting = false }
        errorMessage = ""
        successMessage = ""

        do {
            try await viewModel.requestPermanentVenueOwnerAccountDeletion()
            await MainActor.run {
                successMessage = "Your venue owner account was deleted and you have been signed out."
                didSucceed = true
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Auth sheets + profile hero

struct SettingsSheetStatusBanner: View {
    let title: String?
    let message: String
    let tint: Color
    var systemImage: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                }
                Text(message)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(FGSpacing.md)
        .background(FGColor.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.34 : 0.22), lineWidth: 1)
        }
    }
}

private struct SettingsSheetSectionLabel: View {
    let title: String
    var subtitle: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
        }
    }
}

private struct SettingsUnifiedAccountEntryCard: View {
    let onSignIn: () -> Void
    let onCreateAccount: () -> Void
    let onVenueOwnerTools: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        FGCard {
            FGSectionHeader(
                "FanGeo Account",
                subtitle: "Access your profile, favorites, chats, venues, and business tools."
            )

            Text("Sign in once to move through FanGeo as one connected account experience, then unlock venue-owner tools as needed.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            FGPrimaryButton(title: "Sign In", systemImage: "person.fill") {
                onSignIn()
            }

            FGSecondaryButton(title: "Create Account", systemImage: "person.badge.plus") {
                onCreateAccount()
            }

            if let onVenueOwnerTools {
                Button(action: onVenueOwnerTools) {
                    HStack(spacing: FGSpacing.sm) {
                        Image(systemName: "building.2.crop.circle")
                        Text("Venue owner tools")
                            .font(FGTypography.cardTitle)
                    }
                    .foregroundStyle(FGColor.accentBlue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FGSpacing.sm)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SettingsUserAuthSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var email: String
    @Binding var password: String
    @Binding var showRegisterMode: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    Text("Account")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Sign in to sync your profile and activity.")
                        .font(.subheadline)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .padding(.top, 2)

                SettingsAccountCard(
                    viewModel: viewModel,
                    email: $email,
                    password: $password,
                    showRegisterMode: $showRegisterMode
                )

                SettingsFanPasswordResetCard(viewModel: viewModel, loginEmail: $email)
            }
            .padding(.horizontal, FGSpacing.lg)
            .padding(.bottom, FGSpacing.md)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
        }
        .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onChange(of: viewModel.isLoggedIn) { wasLoggedIn, isLoggedIn in
            // Dismiss only after a successful fan sign-in while the sheet is open (not if already logged in on appear).
            if !wasLoggedIn && isLoggedIn {
                dismiss()
            }
        }
    }
}

/// Signed-in body for ``SettingsVenueAuthSheet`` only.
/// Intentionally excludes verification rows, claim forms, password reset, logout, and deletion UI.
private struct SettingsVenueAuthSheetSignedInBody: View {
    @ObservedObject var viewModel: MapViewModel
    var onRequestVenueProfileDashboard: () -> Void
    var dismissAuthSheet: () -> Void

    /// Claim workflow approved (not venue-linked fallback).
    private var claimLineShowsApprovedMessage: Bool {
        if viewModel.venueIsApproved { return true }
        let s = viewModel.venueClaimStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "approved"
    }

    private var claimShowsRejected: Bool {
        viewModel.hasActiveVenueClaimRejectionForBusinessUI
    }

    private var venueToolsUnlocked: Bool {
        viewModel.venueOwnerToolsUnlockedForUI()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            if viewModel.isVenueOwnerBusinessDataLoading {
                SettingsSheetStatusBanner(
                    title: "Loading business account",
                    message: "Loading your venues…",
                    tint: FGColor.accentBlue,
                    systemImage: "building.2.crop.circle"
                )
            } else if viewModel.venueOwnerJustCompletedRegistration {
                FGCard {
                    FGSectionHeader(
                        "Business account created",
                        subtitle: "Your first location request has been submitted for review."
                    ) {
                        FGStatusPill(title: "Pending review", kind: .pending)
                    }

                    SettingsSheetStatusBanner(
                        title: nil,
                        message: "FanGeo reviews new business location submissions before owner tools are unlocked.",
                        tint: FGColor.accentYellow,
                        systemImage: "clock.badge.checkmark"
                    )

                    FGPrimaryButton(title: "Close") {
                        viewModel.venueOwnerJustCompletedRegistration = false
                        dismissAuthSheet()
                    }
                }
#if DEBUG
                .onAppear {
                    print("[BusinessSignup] final success modal shown (Business account created card)")
                }
#endif
            } else {
                // After business-owner sign-in, close this auth sheet instead of showing
                // any claim-status card. Settings remains the single source of truth.
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
                    .task {
#if DEBUG
                        let status = viewModel.venueClaimStatus.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("[BusinessLogin] signed-in sheet auto-dismissed status=\(status) submitted=\(viewModel.venueClaimSubmitted) unlocked=\(venueToolsUnlocked) hasBusiness=\(viewModel.hasBusinessAccountForOwner()) rejected=\(claimShowsRejected)")
#endif
                        dismissAuthSheet()
                    }
            }
        }
        .onAppear {
            viewModel.checkVenueApprovalStatus()
#if DEBUG
            print("[VenueOwnerLoginDebug] sheet state=appear unlocked=\(viewModel.venueOwnerToolsUnlockedForUI()) loading=\(viewModel.isVenueOwnerBusinessDataLoading) claimSubmitted=\(viewModel.venueClaimSubmitted)")
#endif
        }
    }

}

private struct SettingsVenueAuthSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var venuePassword: String
    @Binding var showVenueRegisterMode: Bool
    var onRequestVenueProfileDashboard: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                VStack(alignment: .leading, spacing: FGSpacing.sm) {
                    Text("Business")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.primary)

                    Text("Sign in as a business owner to manage your locations and listings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)

                if !viewModel.isVenueOwnerLoggedIn {
                    SettingsSheetStatusBanner(
                        title: "Approval required",
                        message: "Claim requests are reviewed before owner tools are enabled.",
                        tint: FGColor.accentYellow,
                        systemImage: "clock.badge.exclamationmark"
                    )
                }

                if viewModel.isVenueOwnerLoggedIn {
                    SettingsVenueAuthSheetSignedInBody(
                        viewModel: viewModel,
                        onRequestVenueProfileDashboard: onRequestVenueProfileDashboard,
                        dismissAuthSheet: { dismiss() }
                    )
                } else {
                    SettingsVenueOwnerCard(
                        viewModel: viewModel,
                        venuePassword: $venuePassword,
                        showVenueRegisterMode: $showVenueRegisterMode
                    )
                }
            }
            .padding(.horizontal, FGSpacing.lg)
            .padding(.bottom, FGSpacing.md)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
        }
        .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onDisappear {
            viewModel.venueOwnerJustCompletedRegistration = false
        }
    }
}

private struct SettingsProfileHero: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var showProfileScreen: Bool
    var venueOwnerOnResetPassword: () -> Void
    var venueOwnerOnDismissSheetsAfterLogout: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// Email shown in the hero: fan session vs venue-owner session (existing ``MapViewModel`` flags; no auth changes).
    private var heroEmailLine: String {
        if viewModel.isLoggedIn {
            return viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
    }

    private func trimmedNonEmpty(_ raw: String?) -> String? {
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    private func businessOwnerEmailPrefixTitle() -> String {
        let email = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        guard !local.isEmpty else { return "" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    /// Business-account title for the hero (never the selected venue name; venue stays in the Business section).
    private var venueOwnerBusinessHeroTitle: String {
        let businesses = viewModel.ownedBusinesses
        if businesses.count == 1 {
            if let name = trimmedNonEmpty(businesses.first?.display_name) {
                return name
            }
            let prefix = businessOwnerEmailPrefixTitle()
            return prefix.isEmpty ? "Business account" : prefix
        }
        if businesses.count > 1 {
            if let vid = viewModel.ownerVenueDatabaseId {
                let managed = viewModel.managedVenuesForOwner()
                if let row = managed.first(where: { $0.id == vid }),
                   let bid = row.business_id,
                   let biz = businesses.first(where: { $0.id == bid }),
                   let name = trimmedNonEmpty(biz.display_name) {
                    return name
                }
            }
            return "Business account"
        }
        let prefix = businessOwnerEmailPrefixTitle()
        return prefix.isEmpty ? "Business account" : prefix
    }

    private var resolvedDisplayName: String {
        if viewModel.isVenueOwnerLoggedIn && !viewModel.isLoggedIn {
            return venueOwnerBusinessHeroTitle
        }
        let current = viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
        let email = heroEmailLine
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        guard !local.isEmpty else { return "" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    /// Prefer venue-owner label when both flags are true (defensive; login paths normally keep them exclusive).
    private var accountTypeBadgeText: String {
        viewModel.isVenueOwnerLoggedIn ? "Business owner account" : "User account"
    }

    private var activityBadgeText: String {
        if viewModel.isVenueOwnerLoggedIn {
            let managedCount = viewModel.managedVenuesForOwner().count
            return managedCount == 1 ? "1 managed venue" : "\(managedCount) managed venues"
        }
        let favoritesCount = viewModel.favoriteVenueIDs.count
        return favoritesCount == 1 ? "1 saved venue" : "\(favoritesCount) saved venues"
    }

    private var activityBadgeTint: Color {
        viewModel.isVenueOwnerLoggedIn ? FGColor.accentGreen : FGColor.accentYellow
    }

    private var accountTypeCapsule: some View {
        heroGlassPill(title: accountTypeBadgeText)
            .accessibilityLabel(accountTypeBadgeText)
    }

    private var activityCapsule: some View {
        heroGlassPill(title: activityBadgeText, accent: activityBadgeTint)
            .accessibilityLabel(activityBadgeText)
    }

    private var heroBackgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.05, blue: 0.07).opacity(colorScheme == .dark ? 0.96 : 0.90),
                Color(red: 0.09, green: 0.12, blue: 0.17).opacity(colorScheme == .dark ? 0.98 : 0.93),
                Color(red: 0.16, green: 0.22, blue: 0.30).opacity(colorScheme == .dark ? 0.92 : 0.86)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var heroBlueHighlight: some View {
        RadialGradient(
            colors: [
                Color(red: 0.74, green: 0.88, blue: 0.99).opacity(colorScheme == .dark ? 0.12 : 0.08),
                Color.clear
            ],
            center: .topTrailing,
            startRadius: 8,
            endRadius: 220
        )
    }

    private func heroGlassPill(title: String, accent: Color? = nil) -> some View {
        HStack(spacing: 6) {
            if let accent {
                Circle()
                    .fill(accent.opacity(0.95))
                    .frame(width: 6, height: 6)
                    .shadow(color: accent.opacity(0.28), radius: 4, y: 0)
            }

            Text(title)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(.white.opacity(accent == nil ? 0.78 : 0.90))
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background {
            Capsule(style: .continuous)
                .fill(Color(red: 0.82, green: 0.90, blue: 1.0).opacity(colorScheme == .dark ? 0.08 : 0.10))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.15), lineWidth: 1)
                }
        }
    }

    private var heroCard: some View {
        ZStack(alignment: .bottomTrailing) {
            heroBackgroundGradient
            heroBlueHighlight

            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    UserAvatarView(
                        avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
                        avatarURL: viewModel.currentUserAvatarURL,
                        avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
                        displayName: resolvedDisplayName,
                        email: heroEmailLine,
                        size: 72,
                        fallbackStyle: .darkCardTranslucent,
                        imagePlaceholderTint: .white
                    )

                    VStack(alignment: .leading, spacing: FGSpacing.xs) {
                        Text(viewModel.isVenueOwnerLoggedIn ? "Business account" : "FanGeo profile")
                            .font(FGTypography.metadata.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))

                        Text(resolvedDisplayName.isEmpty ? "My profile" : resolvedDisplayName)
                            .font(FGTypography.sectionTitle)
                            .foregroundStyle(.white)

                        if !heroEmailLine.isEmpty {
                            Text(heroEmailLine)
                                .font(FGTypography.caption)
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(width: 34, height: 34)
                        .background(Color(red: 0.82, green: 0.90, blue: 1.0).opacity(colorScheme == .dark ? 0.08 : 0.10))
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.15), lineWidth: 1)
                        }
                }

                HStack(spacing: FGSpacing.sm) {
                    accountTypeCapsule
                    activityCapsule
                }
            }
            .padding(FGSpacing.xl)

            FanGeoLogoWatermark(variant: .white, width: 62, opacity: 0.055)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.11 : 0.14), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.14), radius: 16, y: 9)
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.04), radius: 12, y: 2)
    }

    var body: some View {
        Group {
            if viewModel.isLoggedIn {
                Button {
                    showProfileScreen = true
                } label: {
                    heroCard
                }
                .buttonStyle(.plain)
            } else if viewModel.isVenueOwnerLoggedIn {
                heroCard
            } else {
                heroCard
            }
        }
        .sheet(isPresented: $showProfileScreen) {
            UserProfileScreen(viewModel: viewModel) {
                showProfileScreen = false
            }
        }
    }
}

// MARK: - General tab

private struct SettingsGeneralSection: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            
            SettingsTimeZoneCard(viewModel: viewModel)
                .padding()
                .background(Color.white.opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 22))
            
            SettingsCalendarDisplayCard(viewModel: viewModel)
                .padding()
                .background(Color.white.opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 22))

            //if viewModel.isAdminLoggedIn {
             //   reportedCommentsAdminCard
            //}
            SettingsReportedCommentsAdminCard(viewModel: viewModel)
        }
    }
}

private struct SettingsTimeZoneCard: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Time Zone")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Choose how game times should appear.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Time Zone", selection: $viewModel.selectedTimeZone) {
                ForEach(TimeZoneOption.allCases) { option in
                    Text("\(option.rawValue) (\(option.abbreviation))")
                        .tag(option)
                }
            }
            .pickerStyle(.menu)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct SettingsCalendarDisplayCard: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Calendar Display")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Choose how green calendar dots are shown.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Only show games in visible map area",
                   isOn: $viewModel.calendarUsesVisibleMapRegionOnly)
                .font(.subheadline)
                .fontWeight(.semibold)

            Text(viewModel.calendarUsesVisibleMapRegionOnly
                 ? "Matches games to the current map region. Zoom out to discover more."
                 : "Shows all available games regardless of map view.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsReportedCommentsAdminCard: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reported Comments")
                .font(.headline)
                .fontWeight(.bold)

            Button {
                Task {
                    await viewModel.loadReportedComments()
                }
            } label: {
                Text("Refresh Reports")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.black)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if viewModel.reportedCommentDisplays.isEmpty {
                Text("No reported comments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.reportedCommentDisplays) { report in
                    VStack(alignment: .leading, spacing: 12) {

                        HStack(alignment: .top, spacing: 12) {

                            if let url = URL(string: report.commenterAvatarURL),
                               !report.commenterAvatarURL.isEmpty {

                                AsyncImage(url: url) { image in
                                    image
                                        .resizable()
                                        .scaledToFill()
                                } placeholder: {
                                    Circle()
                                        .fill(Color.gray.opacity(0.20))
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())

                            } else {

                                Circle()
                                    .fill(Color.orange.opacity(0.15))
                                    .frame(width: 44, height: 44)
                                    .overlay {
                                        Text(String(report.commenterName.prefix(1)).uppercased())
                                            .fontWeight(.bold)
                                            .foregroundStyle(.orange)
                                    }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(report.commenterName)
                                    .font(.headline)
                                    .fontWeight(.bold)

                                Text("“\(report.commentText)”")
                                    .font(.subheadline)

                                Text("\(report.venueName) • \(report.eventTitle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text("Reported: \(formattedReportDate(report.reportedAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text("Reported by: \(report.reporterName)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                
                                HStack(spacing: 10) {

                                    Button {
                                        Task {
                                            await viewModel.deleteReportedComment(report)
                                            await viewModel.loadReportedComments()
                                        }
                                    } label: {
                                        Label("Delete Comment", systemImage: "xmark.circle.fill")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(Color.red.opacity(0.14))
                                            .foregroundStyle(.red)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }

                                    Button {
                                        Task {
                                            await viewModel.dismissCommentReport(report)
                                        }
                                    } label: {
                                        Label("Dismiss Report", systemImage: "checkmark.circle.fill")
                                            .font(.caption)
                                            .fontWeight(.bold)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(Color.green.opacity(0.14))
                                            .foregroundStyle(.green)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func formattedReportDate(_ rawDate: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]

        guard let date = isoFormatter.date(from: rawDate) else {
            return rawDate
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd h:mm a 'MT'"
        formatter.timeZone = TimeZone(identifier: "America/Denver")

        return formatter.string(from: date)
    }
}

// MARK: - User tab

private struct SettingsUserSection: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var email: String
    @Binding var password: String
    @Binding var showRegisterMode: Bool
    @Binding var showProfileScreen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if viewModel.isLoggedIn {
                SettingsProfileButton(viewModel: viewModel, showProfileScreen: $showProfileScreen)
                SettingsGameNotificationsCard(viewModel: viewModel, notificationSettingsStore: viewModel.notificationSettingsStore)
                SettingsSavedGamesCard()
            }

            SettingsAccountCard(
                viewModel: viewModel,
                email: $email,
                password: $password,
                showRegisterMode: $showRegisterMode
            )

            SettingsFanPasswordResetCard(viewModel: viewModel, loginEmail: $email)

            if viewModel.isLoggedIn {
                SettingsPrivateChatDeviceAuthCard()
                SettingsFanAccountSecurityCard(viewModel: viewModel)
            }
        }
    }
}

// MARK: - Private chat (local device lock)

private struct SettingsPrivateChatDeviceAuthCard: View {
    @AppStorage("gameon.require_device_auth_for_private_chat") private var requireDeviceAuthForPrivateChat = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Private messages")
                .font(.headline)
                .fontWeight(.bold)

            Toggle("Require Face ID / passcode for private messages", isOn: $requireDeviceAuthForPrivateChat)
                .font(.subheadline)

            Text("When on, FanGeo asks for Face ID, Touch ID, or your device passcode before opening the Chat tab. This stays on your device only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

// MARK: - Account security (fan)

private struct SettingsFanAccountSecurityCard: View {
    @ObservedObject var viewModel: MapViewModel
    @State private var isShowingDeleteSheet = false
    @State private var deleteConfirmationText = ""
    @State private var isDeleting = false
    @State private var deletionErrorMessage = ""
    @State private var deletionSuccessMessage = ""

    private var trimmedConfirmation: String {
        deleteConfirmationText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var deletionEnabled: Bool {
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return false }
        return trimmedConfirmation.caseInsensitiveCompare("DELETE") == .orderedSame ||
            trimmedConfirmation.caseInsensitiveCompare(email) == .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Account security")
                .font(.headline)
                .fontWeight(.bold)

            Text("Manage sensitive account actions. For permanent deletion, you’ll be asked to confirm before anything is removed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                deletionErrorMessage = ""
                deletionSuccessMessage = ""
                deleteConfirmationText = ""
                isShowingDeleteSheet = true
            } label: {
                Label("Delete account permanently", systemImage: "trash")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.12))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if !deletionSuccessMessage.isEmpty {
                Text(deletionSuccessMessage)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            }

            if !deletionErrorMessage.isEmpty {
                Text(deletionErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .sheet(isPresented: $isShowingDeleteSheet) {
            deleteAccountSheet
        }
    }

    private var deleteAccountSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Delete account permanently")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("This will permanently delete your fan account and remove your profile, favorites, and activity. This cannot be undone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("To confirm, type your email or the word DELETE:")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    TextField("Type email or DELETE", text: $deleteConfirmationText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .padding()
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    HStack(spacing: 10) {
                        Button {
                            isShowingDeleteSheet = false
                        } label: {
                            Text("Cancel")
                                .fontWeight(.bold)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.gray.opacity(0.14))
                                .foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .disabled(isDeleting)

                        Button {
                            Task {
                                isDeleting = true
                                deletionErrorMessage = ""
                                deletionSuccessMessage = ""

                                do {
                                    try await viewModel.requestPermanentAccountDeletion()
                                    deletionSuccessMessage = "Account deleted. You’ve been signed out."
                                    isShowingDeleteSheet = false
                                } catch {
                                    deletionErrorMessage = error.localizedDescription
                                }

                                isDeleting = false
                            }
                        } label: {
                            HStack {
                                if isDeleting {
                                    ProgressView()
                                        .tint(.red)
                                }
                                Text(isDeleting ? "Deleting..." : "Delete permanently")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.opacity(0.12))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .disabled(!deletionEnabled || isDeleting)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SettingsAccountCard: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var email: String
    @Binding var password: String
    @Binding var showRegisterMode: Bool
    @State private var fanSignupPoliciesAccepted = false
    @State private var fanSignupLegalDocument: SettingsLegalDocumentKind?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        FGCard {
            FGSectionHeader(
                showRegisterMode ? "Create your fan account" : "Fan account access",
                subtitle: showRegisterMode
                    ? "Join FanGeo to save venues, chat, and sync your activity."
                    : "Sign in to sync your profile and activity."
            )

            if viewModel.isLoggedIn {
                HStack(spacing: FGSpacing.md) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(FGColor.accentBlue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in")
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text(viewModel.currentUserEmail)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    Spacer(minLength: 0)
                }
                .padding(FGSpacing.md)
                .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.76 : 0.97))
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }

                FGSecondaryButton(title: "Log Out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task {
                        await viewModel.logoutUser()
                        email = ""
                        password = ""
                    }
                }
            } else {
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .fanGeoInputFieldStyle()

                SecureField("Password", text: $password)
                    .fanGeoInputFieldStyle()

                if showRegisterMode {
                    VStack(alignment: .leading, spacing: FGSpacing.sm) {
                        SettingsSheetSectionLabel(
                            title: "Guidelines",
                            subtitle: "Accept the FanGeo terms before creating your account."
                        )

                        HStack(alignment: .top, spacing: 10) {
                        Button {
                            fanSignupPoliciesAccepted.toggle()
                        } label: {
                            Image(systemName: fanSignupPoliciesAccepted ? "checkmark.square.fill" : "square")
                                .font(.title3)
                                .foregroundStyle(fanSignupPoliciesAccepted ? FGColor.accentBlue : FGColor.mutedText(colorScheme))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("I agree to the Terms of Service, Privacy Policy, and Community Guidelines.")
                        .accessibilityAddTraits(fanSignupPoliciesAccepted ? .isSelected : [])

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 0) {
                                Text("I agree to the ")
                                Button {
                                    fanSignupLegalDocument = .termsOfService
                                } label: {
                                    Text("Terms of Service")
                                        .underline()
                                }
                                .buttonStyle(.plain)
                                Text(", ")
                                Button {
                                    fanSignupLegalDocument = .privacyPolicy
                                } label: {
                                    Text("Privacy Policy")
                                        .underline()
                                }
                                .buttonStyle(.plain)
                                Text(", and ")
                                Button {
                                    fanSignupLegalDocument = .communityGuidelines
                                } label: {
                                    Text("Community Guidelines")
                                        .underline()
                                }
                                .buttonStyle(.plain)
                                Text(".")
                            }
                            .font(.footnote)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .tint(FGColor.accentBlue)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    }
                    .padding(FGSpacing.md)
                    .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.97))
                    .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                    }
                }

                FGPrimaryButton(
                    title: showRegisterMode ? "Create Account" : "Login",
                    isDisabled: showRegisterMode && !fanSignupPoliciesAccepted
                ) {
                    Task {
                        if showRegisterMode {
                            await viewModel.registerUser(
                                email: email,
                                password: password,
                                recordFanGuidelinesAcceptance: fanSignupPoliciesAccepted
                            )
                        } else {
                            await viewModel.loginUser(email: email, password: password)
                        }
                        await MainActor.run {
                            password = ""
                        }
                    }
                }

                if !viewModel.authErrorMessage.isEmpty {
                    SettingsSheetStatusBanner(
                        title: "Couldn’t sign in",
                        message: viewModel.authErrorMessage,
                        tint: FGColor.dangerRed,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }

                Button {
                    showRegisterMode.toggle()
                } label: {
                    Text(showRegisterMode ? "Already have an account? Login" : "New user? Register")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.accentBlue)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: showRegisterMode) { _, isRegister in
            password = ""
            if !isRegister {
                fanSignupPoliciesAccepted = false
            }
        }
        .sheet(item: $fanSignupLegalDocument) { document in
            SettingsLegalDocumentSheet(document: document)
        }
    }
}

// MARK: - Fan password reset

/// Password recovery email for the fan account; reuses the login email field when signed out.
private struct SettingsFanPasswordResetCard: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var loginEmail: String
    @State private var isSending = false
    @Environment(\.colorScheme) private var colorScheme

    private var emailForReset: String {
        if viewModel.isLoggedIn {
            return viewModel.currentUserEmail
        }
        return loginEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        FGCard {
            FGSectionHeader(
                "Reset password",
                subtitle: "We’ll email you a secure link to choose a new password. Use the same email as your fan account."
            )

            if viewModel.isLoggedIn {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill")
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Text(viewModel.currentUserEmail)
                        .font(FGTypography.body.weight(.medium))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                }
                .padding(FGSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.76 : 0.97))
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }
            } else {
                TextField("Email for password reset", text: $loginEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .fanGeoInputFieldStyle()
            }

            FGPrimaryButton(title: "Send reset link", isDisabled: isSending) {
                Task {
                    isSending = true
                    await viewModel.sendPasswordResetEmail(emailForReset, accountKind: .fan)
                    isSending = false
                }
            }

            if !viewModel.userPasswordResetMessage.isEmpty {
                SettingsSheetStatusBanner(
                    title: "Reset link sent",
                    message: viewModel.userPasswordResetMessage,
                    tint: FGColor.accentGreen,
                    systemImage: "checkmark.circle.fill"
                )
            }

            if !viewModel.userPasswordResetError.isEmpty {
                SettingsSheetStatusBanner(
                    title: "Reset unavailable",
                    message: viewModel.userPasswordResetError,
                    tint: FGColor.dangerRed,
                    systemImage: "xmark.circle.fill"
                )
            }
        }
    }
}

// MARK: - Venue owner password reset

/// Password recovery for the venue-owner Supabase account (same Auth table as fans; uses the venue business email field when present).
private struct SettingsVenuePasswordResetCard: View {
    @ObservedObject var viewModel: MapViewModel
    @State private var isSending = false
    @State private var emailIfMissing = ""

    private var emailForReset: String {
        let fromProfile = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        if !fromProfile.isEmpty { return fromProfile }
        return emailIfMissing.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reset venue password")
                .font(.headline)
                .fontWeight(.bold)

            Text("We’ll email a link to reset the password for your venue owner login.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.isVenueOwnerLoggedIn {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill")
                        .foregroundStyle(.secondary)
                    Text(viewModel.venueOwnerEmail)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail).isEmpty {
                TextField("Venue owner email for reset", text: $emailIfMissing)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                Text("Uses the business email you entered above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    isSending = true
                    await viewModel.sendPasswordResetEmail(emailForReset, accountKind: .venueOwner)
                    isSending = false
                }
            } label: {
                HStack {
                    if isSending {
                        ProgressView()
                            .tint(.white)
                    }
                    Text("Send reset link")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.black.opacity(isSending ? 0.45 : 1))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .disabled(isSending)

            if !viewModel.venuePasswordResetMessage.isEmpty {
                Text(viewModel.venuePasswordResetMessage)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            }

            if !viewModel.venuePasswordResetError.isEmpty {
                Text(viewModel.venuePasswordResetError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

private struct FanGeoAppearanceSelectionView: View {
    @Binding var selectionRaw: String
    @Environment(\.colorScheme) private var colorScheme

    private var selection: FanGeoAppearancePreference {
        FanGeoAppearancePreference(rawValue: selectionRaw) ?? .system
    }

    var body: some View {
        List {
            Section {
                ForEach(FanGeoAppearancePreference.allCases) { preference in
                    Button {
                        selectionRaw = preference.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Text(preference.displayName)
                                .font(FGTypography.body.weight(.semibold))
                                .foregroundStyle(FGColor.primaryText(colorScheme))

                            Spacer(minLength: 0)

                            if preference == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(FGColor.accentGreen)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(FGAdaptiveSurface.cardElevated)
                }
            } footer: {
                Text("System Default follows your iPhone appearance. Light and Dark override FanGeo locally on this device.")
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .scrollContentBackground(.hidden)
        .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
        .tint(FGColor.accentGreen)
    }
}

private struct SettingsGameNotificationsCard: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var notificationSettingsStore: NotificationSettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("venueFavoriteTeamNearbyNotifications") private var venueFavoriteTeamNearbyNotifications = true
    @AppStorage("venueFriendsGoingNotifications") private var venueFriendsGoingNotifications = true
    @AppStorage("pickupGameReminderNotifications") private var pickupGameReminderNotifications = true
    @AppStorage("pickupJoinRequestUpdateNotifications") private var pickupJoinRequestUpdateNotifications = true
    @AppStorage("pickupPlayerJoinedNotifications") private var pickupPlayerJoinedNotifications = true
    @AppStorage("pickupGameChangeNotifications") private var pickupGameChangeNotifications = true

    private enum RepeatReminderOption: Int, CaseIterable, Identifiable {
        case never = 0
        case every15Minutes = 15
        case every30Minutes = 30
        case everyHour = 60

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .never:
                "Never"
            case .every15Minutes:
                "Every 15 minutes"
            case .every30Minutes:
                "Every 30 minutes"
            case .everyHour:
                "Every hour"
            }
        }

        var minutes: Int? {
            self == .never ? nil : rawValue
        }

        static func current(isEnabled: Bool, minutes: Int) -> RepeatReminderOption {
            guard isEnabled else { return .never }
            return RepeatReminderOption(rawValue: minutes) ?? .every30Minutes
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FGSpacing.lg) {
            notificationIntro

            notificationSection(
                title: "Venue Games",
                subtitle: "Watch parties, sports bars, and venue events.",
                systemImage: "sportscourt.fill",
                tint: FGColor.accentGreen
            ) {
                notificationToggle(
                    title: "Game reminders",
                    subtitle: "Kickoff reminders for venue games you mark Going.",
                    isOn: gameNotificationsEnabledBinding
                )

                notificationToggle(
                    title: "Favorite team nearby",
                    subtitle: "A nearby venue is showing one of your teams.",
                    isOn: loggingBinding(
                        key: "venueFavoriteTeamNearbyNotifications",
                        title: "Favorite team nearby",
                        value: $venueFavoriteTeamNearbyNotifications
                    )
                )

                notificationToggle(
                    title: "Friends going to same venue",
                    subtitle: "Friends are planning around the same sports bar.",
                    isOn: loggingBinding(
                        key: "venueFriendsGoingNotifications",
                        title: "Friends going to same venue",
                        value: $venueFriendsGoingNotifications
                    )
                )

                permissionMessage
            }

            notificationSection(
                title: "Pickup Games",
                subtitle: "Games you host, join, or request to join.",
                systemImage: "figure.basketball",
                tint: FGColor.accentBlue
            ) {
                notificationToggle(
                    title: "Pickup game reminders",
                    subtitle: "A local reminder before a pickup game starts.",
                    isOn: loggingBinding(
                        key: "pickupGameReminderNotifications",
                        title: "Pickup game reminders",
                        value: $pickupGameReminderNotifications
                    )
                )

                notificationToggle(
                    title: "Join request updates",
                    subtitle: "Accepted, declined, or pending request changes.",
                    isOn: loggingBinding(
                        key: "pickupJoinRequestUpdateNotifications",
                        title: "Join request updates",
                        value: $pickupJoinRequestUpdateNotifications
                    )
                )

                notificationToggle(
                    title: "Player joined your game",
                    subtitle: "Someone joins a pickup game you are hosting.",
                    isOn: loggingBinding(
                        key: "pickupPlayerJoinedNotifications",
                        title: "Player joined your game",
                        value: $pickupPlayerJoinedNotifications
                    )
                )

                notificationToggle(
                    title: "Game changes/cancellations",
                    subtitle: "Time, location, capacity, or cancellation updates.",
                    isOn: loggingBinding(
                        key: "pickupGameChangeNotifications",
                        title: "Game changes/cancellations",
                        value: $pickupGameChangeNotifications
                    )
                )
            }

            notificationSection(
                title: "Calendar & Reminders",
                subtitle: "Timing and calendar controls for your saved games.",
                systemImage: "calendar.badge.clock",
                tint: FGColor.accentGreen
            ) {
                notificationPicker(title: "Reminder timing", selection: reminderMinutesBinding) {
                    Text("15 minutes before").tag(15)
                    Text("30 minutes before").tag(30)
                    Text("1 hour before").tag(60)
                    Text("2 hours before").tag(120)
                    Text("3 hours before").tag(180)
                    Text("1 day before").tag(1440)
                }

                repeatReminderMenuRow

                notificationToggle(
                    title: "Apple Calendar sync",
                    subtitle: "Add games marked Going to your Apple Calendar.",
                    isOn: calendarSyncBinding
                )
            }
        }
        .tint(FGColor.accentGreen)
        .task {
            print("[NotificationSettingsDebug] removedSocialFanSection=true")
            print("[NotificationSettingsDebug] appear notifyBeforeGame=\(notificationSettingsStore.notifyBeforeGame) reminderMinutesBefore=\(notificationSettingsStore.reminderMinutesBefore) repeatGameReminder=\(notificationSettingsStore.repeatGameReminder) repeatEveryMinutes=\(notificationSettingsStore.repeatEveryMinutes) calendarSync=\(notificationSettingsStore.syncGoingGamesToAppleCalendar)")
            await viewModel.refreshGameNotificationAuthorizationState()
            if normalizeInvalidRepeatReminderIntervalIfNeeded() {
                await viewModel.gameReminderPreferenceDidChange()
            }
        }
    }

    private var notificationIntro: some View {
        VStack(alignment: .leading, spacing: FGSpacing.xs) {
            Text("Stay close to the action")
                .font(FGTypography.sectionTitle)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text("Important game and pickup updates stay on by default. Social nudges are optional so FanGeo does not over-notify you.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, FGSpacing.xs)
    }

    private var gameNotificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { notificationSettingsStore.notifyBeforeGame },
            set: { enabled in
                print("[NotificationSettingsDebug] save key=notifyBeforeGame value=\(enabled)")
                Task { await viewModel.setGameNotificationsEnabled(enabled) }
            }
        )
    }

    private var reminderMinutesBinding: Binding<Int> {
        Binding(
            get: { notificationSettingsStore.reminderMinutesBefore },
            set: { minutes in
                print("[NotificationSettingsDebug] save key=reminderMinutesBefore value=\(minutes)")
                notificationSettingsStore.reminderMinutesBefore = minutes
                Task { await viewModel.gameReminderPreferenceDidChange() }
            }
        )
    }

    private var repeatReminderOptionBinding: Binding<RepeatReminderOption> {
        Binding(
            get: {
                RepeatReminderOption.current(
                    isEnabled: notificationSettingsStore.repeatGameReminder,
                    minutes: notificationSettingsStore.repeatEveryMinutes
                )
            },
            set: { option in
                applyRepeatReminderOption(option)
            }
        )
    }

    private var repeatReminderMenuRow: some View {
        let selectedOption = repeatReminderOptionBinding.wrappedValue

        return Menu {
            ForEach(RepeatReminderOption.allCases) { option in
                Button {
                    repeatReminderOptionBinding.wrappedValue = option
                } label: {
                    if option == selectedOption {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(alignment: .center, spacing: FGSpacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Repeat")
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Additional reminders before kickoff.")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: FGSpacing.sm)

                HStack(spacing: 6) {
                    Text(selectedOption.title)
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .tint(FGColor.accentGreen)
    }

    private func applyRepeatReminderOption(_ option: RepeatReminderOption) {
        switch option {
        case .never:
            print("[NotificationSettingsDebug] save key=repeatGameReminder value=false repeatEveryMinutes=\(notificationSettingsStore.repeatEveryMinutes)")
            notificationSettingsStore.repeatGameReminder = false
        case .every15Minutes, .every30Minutes, .everyHour:
            let minutes = option.minutes ?? 30
            print("[NotificationSettingsDebug] save key=repeatGameReminder value=true repeatEveryMinutes=\(minutes)")
            notificationSettingsStore.repeatGameReminder = true
            notificationSettingsStore.repeatEveryMinutes = minutes
        }

        Task { await viewModel.gameReminderPreferenceDidChange() }
    }

    private func normalizeInvalidRepeatReminderIntervalIfNeeded() -> Bool {
        guard notificationSettingsStore.repeatGameReminder,
              RepeatReminderOption(rawValue: notificationSettingsStore.repeatEveryMinutes)?.minutes == nil
        else {
            return false
        }

        print("[NotificationSettingsDebug] normalize repeatEveryMinutes invalid=\(notificationSettingsStore.repeatEveryMinutes) fallback=30")
        notificationSettingsStore.repeatEveryMinutes = RepeatReminderOption.every30Minutes.rawValue
        return true
    }

    private var calendarSyncBinding: Binding<Bool> {
        Binding(
            get: { notificationSettingsStore.syncGoingGamesToAppleCalendar },
            set: { enabled in
                print("[NotificationSettingsDebug] save key=syncGoingGamesToAppleCalendar value=\(enabled)")
                notificationSettingsStore.syncGoingGamesToAppleCalendar = enabled
            }
        )
    }

    @ViewBuilder
    private var permissionMessage: some View {
        if !notificationSettingsStore.notificationPermissionMessage.isEmpty {
            Text(notificationSettingsStore.notificationPermissionMessage)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, FGSpacing.md)
                .padding(.bottom, FGSpacing.xs)
        }
    }

    private func loggingBinding(key: String, title: String, value: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue },
            set: { enabled in
                print("[NotificationSettingsDebug] save key=\(key) title=\"\(title)\" value=\(enabled)")
                value.wrappedValue = enabled
            }
        )
    }

    private func notificationSection<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        FGCard {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: FGRadius.small, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(subtitle)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                content()
            }
            .background(FGAdaptiveSurface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
        }
    }

    private func notificationToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(subtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
    }

    private func notificationPicker<Content: View>(
        title: String,
        selection: Binding<Int>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            Text(title)
                .font(FGTypography.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Spacer(minLength: FGSpacing.sm)
            Picker(title, selection: selection, content: content)
                .pickerStyle(.menu)
                .tint(FGColor.accentGreen)
                .foregroundStyle(FGColor.primaryText(colorScheme))
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
    }
}

private struct SettingsSavedGamesCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saved Games")
                .font(.headline)
                .fontWeight(.bold)

            Text("Manage reminders and saved games for your account.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Saved games are available only when logged in as a user.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

private struct SettingsProfileButton: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var showProfileScreen: Bool

    var body: some View {
        Button {
            showProfileScreen = true
        } label: {
            HStack {
                SettingsAccountProfileImage(viewModel: viewModel)

                VStack(alignment: .leading, spacing: 4) {
                    Text("My Profile")
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)

                    Text("Change display name and profile photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.white.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 22))
        }
        .sheet(isPresented: $showProfileScreen) {
            UserProfileScreen(viewModel: viewModel) {
                showProfileScreen = false
            }
        }
    }
}

private struct SettingsAccountProfileImage: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        UserAvatarView(
            avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
            avatarURL: viewModel.currentUserAvatarURL,
            avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
            displayName: UserAvatarView.accountResolvedDisplayName(
                isLoggedIn: viewModel.isLoggedIn,
                currentUserDisplayName: viewModel.currentUserDisplayName,
                isVenueOwnerLoggedIn: viewModel.isVenueOwnerLoggedIn,
                ownerVenueName: viewModel.ownerVenueName,
                userEmail: viewModel.currentUserEmail,
                venueOwnerEmail: viewModel.venueOwnerEmail
            ),
            email: UserAvatarView.accountEmailLine(
                isLoggedIn: viewModel.isLoggedIn,
                userEmail: viewModel.currentUserEmail,
                venueOwnerEmail: viewModel.venueOwnerEmail
            ),
            size: 44,
            fallbackStyle: .lightOnWhiteChrome
        )
    }
}

// MARK: - Venue tab

/// Venue owner sign-in or combined business + first-location signup (inside ``SettingsVenueAuthSheet`` while logged out).
private struct SettingsVenueOwnerCard: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var venuePassword: String
    @Binding var showVenueRegisterMode: Bool
    @State private var venueSignupPoliciesAccepted = false
    @State private var venueSignupLegalDocument: SettingsLegalDocumentKind?
    @State private var isSignupSubmitting = false

    @State private var signupBusinessName = ""
    @State private var signupLocationName = ""
    @State private var signupStreet = ""
    @State private var signupCity = ""
    @State private var signupState = "UT"
    @State private var signupCountry = BusinessLocationCountryPolicy.defaultCountryCode
    @State private var signupZip = ""
    @State private var signupPhoneDialISO = BusinessPhoneFields.defaultISO
    @State private var signupPhoneLocal = ""
    @State private var signupWebsite = ""
    @State private var signupDescription = ""
    @State private var signupProof = ""
    @State private var signupScreenCount = 1
    @State private var signupServesFood = false
    @State private var signupHasWifi = false
    @State private var signupHasGarden = false
    @State private var signupHasProjector = false
    @State private var signupPetFriendly = false
    @State private var signupFamilyFriendly = false
    @State private var signupParking = false
    @State private var signupCoverPicker: PhotosPickerItem?
    @State private var signupMenuPicker: PhotosPickerItem?
    @State private var signupCoverData: Data?
    @State private var signupMenuData: Data?
    @Environment(\.colorScheme) private var colorScheme

    private var businessSignupMissingRequirementMessage: String? {
        BusinessCreationFormValidation.businessCreationMissingRequirementMessage(
            isRegisterMode: showVenueRegisterMode,
            venueOwnerEmail: viewModel.venueOwnerEmail,
            venuePassword: venuePassword,
            policiesAccepted: venueSignupPoliciesAccepted,
            businessName: signupBusinessName,
            locationName: signupLocationName,
            streetAddress: signupStreet,
            city: signupCity,
            state: signupState,
            zip: signupZip,
            phoneDialISO: signupPhoneDialISO,
            phoneLocal: signupPhoneLocal,
            description: signupDescription,
            proofNote: signupProof,
            coverPhotoData: signupCoverData
        )
    }

    /// Same gate as ``businessSignupMissingRequirementMessage`` == nil (registration mode only).
    private var registrationFormComplete: Bool {
        businessSignupMissingRequirementMessage == nil
    }

    private var signupPrimarySubmitDisabled: Bool {
        isSignupSubmitting || (showVenueRegisterMode && businessSignupMissingRequirementMessage != nil)
    }

#if DEBUG
    /// Why `registrationFormComplete` is false (does not duplicate password-in-email checks beyond `emailOk`).
    private func signupFormIncompleteReasons() -> [String] {
        if let m = businessSignupMissingRequirementMessage { return [m] }
        return []
    }

    private func logSignupSubmitGates(reason: String) {
        print(
            "[BusinessSignup] gateCheck reason=\(reason) registerMode=\(showVenueRegisterMode) submitDisabled=\(signupPrimarySubmitDisabled) isSignupSubmitting=\(isSignupSubmitting) policiesAccepted=\(venueSignupPoliciesAccepted) registrationFormComplete=\(registrationFormComplete) incomplete=[\(signupFormIncompleteReasons().joined(separator: ","))] coverPhotoBytes=\(signupCoverData?.count ?? 0) menuPhotoBytes=\(signupMenuData?.count ?? 0)"
        )
    }
#endif

    var body: some View {
        FGCard {
            FGSectionHeader(
                showVenueRegisterMode ? "Create business owner account" : "Business owner access",
                subtitle: showVenueRegisterMode
                    ? "Create your business account and submit your first location in one step. Owner tools unlock after FanGeo reviews and approves the location."
                    : "Sign in to manage listings after your business and location are set up."
            ) {
                FGStatusPill(
                    title: showVenueRegisterMode ? "Review required" : "Owner tools",
                    kind: .custom(tint: showVenueRegisterMode ? FGColor.accentYellow : FGColor.accentBlue)
                )
            }

            TextField("Business email", text: $viewModel.venueOwnerEmail)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .fanGeoInputFieldStyle()

            SecureField("Business owner password", text: $venuePassword)
                .fanGeoInputFieldStyle()

            if showVenueRegisterMode {
                SettingsSheetSectionLabel(title: "Business")
                TextField("Business / brand name", text: $signupBusinessName)
                    .textInputAutocapitalization(.words)
                    .fanGeoInputFieldStyle()

                SettingsSheetSectionLabel(title: "First location")
                TextField("Location name", text: $signupLocationName)
                    .textInputAutocapitalization(.words)
                    .fanGeoInputFieldStyle()

                TextField("Street address", text: $signupStreet)
                    .fanGeoInputFieldStyle()

                TextField("City", text: $signupCity)
                    .textInputAutocapitalization(.words)
                    .fanGeoInputFieldStyle()

                HStack(alignment: .center, spacing: FGSpacing.md) {
                    BusinessLocationUSStatePicker(title: "State", stateCode: $signupState)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("ZIP", text: $signupZip)
                        .textInputAutocapitalization(.never)
                        .frame(minWidth: 88, maxWidth: 120, alignment: .leading)
                }
                .fanGeoInputFieldStyle()

                BusinessLocationCountryField(countryCode: $signupCountry)
                    .fanGeoInputFieldStyle()

                BusinessPhoneNumberField(dialISO: $signupPhoneDialISO, localNumber: $signupPhoneLocal)

                TextField("Website (optional)", text: $signupWebsite)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .fanGeoInputFieldStyle()

                TextField("Description", text: $signupDescription, axis: .vertical)
                    .lineLimit(3...8)
                    .fanGeoInputFieldStyle()

                TextField("Proof note (how you operate this location)", text: $signupProof, axis: .vertical)
                    .lineLimit(2...6)
                    .fanGeoInputFieldStyle()

                AddLocationVenueFeaturesGrid(
                    screenCount: $signupScreenCount,
                    servesFood: $signupServesFood,
                    hasWifi: $signupHasWifi,
                    hasGarden: $signupHasGarden,
                    hasProjector: $signupHasProjector,
                    petFriendly: $signupPetFriendly,
                    parkingAvailable: $signupParking,
                    familyFriendly: $signupFamilyFriendly,
                    maxScreenCount: 40
                )

                SettingsSheetSectionLabel(title: "Photos", subtitle: "A main business photo is required.")

                VenueOwnerListingPhotoPickerCard(
                    title: "Business Photo",
                    subtitle: "Main photo of your business",
                    pickerSelection: $signupCoverPicker,
                    remotePreviewURL: "",
                    localPreviewData: signupCoverData,
                    usesFanGeoSheetChrome: true
                )

                VenueOwnerListingPhotoPickerCard(
                    title: "Others",
                    subtitle: "Examples: menu, gym, patio, bar, seating, entrance",
                    pickerSelection: $signupMenuPicker,
                    remotePreviewURL: "",
                    localPreviewData: signupMenuData,
                    usesFanGeoSheetChrome: true
                )

                HStack(alignment: .top, spacing: 10) {
                    Button {
                        venueSignupPoliciesAccepted.toggle()
                    } label: {
                        Image(systemName: venueSignupPoliciesAccepted ? "checkmark.square.fill" : "square")
                            .font(.title3)
                            .foregroundStyle(venueSignupPoliciesAccepted ? FGColor.accentBlue : FGColor.mutedText(colorScheme))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("I agree to the Terms of Service, Privacy Policy, and Community Guidelines.")
                    .accessibilityAddTraits(venueSignupPoliciesAccepted ? .isSelected : [])

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 0) {
                            Text("I agree to the ")
                            Button {
                                venueSignupLegalDocument = .termsOfService
                            } label: {
                                Text("Terms of Service")
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            Text(", ")
                            Button {
                                venueSignupLegalDocument = .privacyPolicy
                            } label: {
                                Text("Privacy Policy")
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            Text(", and ")
                            Button {
                                venueSignupLegalDocument = .communityGuidelines
                            } label: {
                                Text("Community Guidelines")
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            Text(".")
                        }
                        .font(.footnote)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .tint(FGColor.accentBlue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(FGSpacing.md)
                .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.97))
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }
            }

            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                FGPrimaryButton(
                    title: showVenueRegisterMode ? "Create account & submit location" : "Sign In as Business Owner",
                    isDisabled: signupPrimarySubmitDisabled
                ) {
#if DEBUG
                    print("[BusinessSignup] button tapped primaryAction registerMode=\(showVenueRegisterMode)")
                    logSignupSubmitGates(reason: "immediate_after_tap")
#endif
                    Task {
#if DEBUG
                        print("[BusinessSignup] async Task entered registerMode=\(showVenueRegisterMode)")
#endif
                        if showVenueRegisterMode {
#if DEBUG
                            logSignupSubmitGates(reason: "register_branch_before_flags")
#endif
                            isSignupSubmitting = true
#if DEBUG
                            print("[BusinessSignup] set isSignupSubmitting=true")
#endif
                            let form = AddLocationClaimForm(
                                venueName: signupLocationName,
                                address: signupStreet,
                                city: signupCity,
                                state: signupState,
                                country: signupCountry,
                                zip: signupZip,
                                phone: BusinessPhoneFields.combinedStorage(iso: signupPhoneDialISO, local: signupPhoneLocal)
                                    .trimmingCharacters(in: .whitespacesAndNewlines),
                                website: signupWebsite,
                                description: signupDescription,
                                proofNote: signupProof,
                                screenCount: signupScreenCount,
                                servesFood: signupServesFood,
                                hasWifi: signupHasWifi,
                                hasGarden: signupHasGarden,
                                hasProjector: signupHasProjector,
                                petFriendly: signupPetFriendly,
                                familyFriendly: signupFamilyFriendly,
                                parkingAvailable: signupParking,
                                coverPhotoURL: "",
                                menuPhotoURL: ""
                            )
                            let payload = BusinessOwnerSignupPayload(
                                businessDisplayName: signupBusinessName,
                                firstLocation: form
                            )
#if DEBUG
                            print("[BusinessSignup] calling registerVenueOwner coverBytes=\(signupCoverData?.count ?? 0) menuBytes=\(signupMenuData?.count ?? 0)")
#endif
                            await viewModel.registerVenueOwner(
                                email: viewModel.venueOwnerEmail,
                                password: venuePassword,
                                signup: payload,
                                coverPhotoJPEGData: signupCoverData,
                                menuPhotoJPEGData: signupMenuData,
                                recordVenueGuidelinesAcceptance: venueSignupPoliciesAccepted
                            )
#if DEBUG
                            print("[BusinessSignup] registerVenueOwner returned isSignupSubmitting clearing")
#endif
                            await MainActor.run {
                                isSignupSubmitting = false
                                venuePassword = ""
                            }
                        } else {
                            await viewModel.loginVenueOwner(
                                email: viewModel.venueOwnerEmail,
                                password: venuePassword
                            )
                            await MainActor.run {
                                venuePassword = ""
                            }
                        }
                    }
                }

                if showVenueRegisterMode, !isSignupSubmitting, let hint = businessSignupMissingRequirementMessage {
                    SettingsSheetStatusBanner(
                        title: nil,
                        message: hint,
                        tint: FGColor.accentYellow,
                        systemImage: "info.circle"
                    )
                }
            }
#if DEBUG
            .onAppear {
                logSignupSubmitGates(reason: "submit_button_onAppear")
            }
            .onChange(of: venueSignupPoliciesAccepted) { _, _ in
                logSignupSubmitGates(reason: "policies_changed")
            }
            .onChange(of: signupCoverData?.count) { _, _ in
                logSignupSubmitGates(reason: "cover_data_changed")
            }
            .onChange(of: isSignupSubmitting) { _, v in
                print("[BusinessSignup] isSignupSubmitting -> \(v)")
            }
            .onChange(of: businessSignupMissingRequirementMessage) { _, new in
                if showVenueRegisterMode, !isSignupSubmitting {
                    if let m = new {
                        print("[BusinessValidation] missing requirement=\(m)")
                    } else {
                        print("[BusinessValidation] submit enabled")
                    }
                }
            }
#endif

            Button {
                showVenueRegisterMode.toggle()
            } label: {
                Text(showVenueRegisterMode ? "Already have an account? Sign in" : "New business owner? Register")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.accentBlue)
            }
            .buttonStyle(.plain)

            if !viewModel.venueAuthErrorMessage.isEmpty {
                SettingsSheetStatusBanner(
                    title: "Couldn’t continue",
                    message: viewModel.venueAuthErrorMessage,
                    tint: FGColor.dangerRed,
                    systemImage: "exclamationmark.triangle.fill"
                )
            }
        }
        .onChange(of: showVenueRegisterMode) { _, isRegister in
            venuePassword = ""
            viewModel.venueAuthErrorMessage = ""
            if !isRegister {
                venueSignupPoliciesAccepted = false
                signupBusinessName = ""
                signupLocationName = ""
                signupStreet = ""
                signupCity = ""
                signupState = "UT"
                signupCountry = BusinessLocationCountryPolicy.defaultCountryCode
                signupZip = ""
                signupPhoneDialISO = BusinessPhoneFields.defaultISO
                signupPhoneLocal = ""
                signupWebsite = ""
                signupDescription = ""
                signupProof = ""
                signupScreenCount = 1
                signupServesFood = false
                signupHasWifi = false
                signupHasGarden = false
                signupHasProjector = false
                signupPetFriendly = false
                signupFamilyFriendly = false
                signupParking = false
                signupCoverPicker = nil
                signupMenuPicker = nil
                signupCoverData = nil
                signupMenuData = nil
            }
        }
        .onChange(of: signupCoverPicker) { _, item in
            Task {
                guard let item else { return }
                if let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty {
                    await MainActor.run {
                        signupCoverData = data
                        signupCoverPicker = nil
                    }
                }
            }
        }
        .onChange(of: signupMenuPicker) { _, item in
            Task {
                guard let item else { return }
                if let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty {
                    await MainActor.run {
                        signupMenuData = data
                        signupMenuPicker = nil
                    }
                } else {
                    await MainActor.run { signupMenuPicker = nil }
                }
            }
        }
        .sheet(item: $venueSignupLegalDocument) { document in
            SettingsLegalDocumentSheet(document: document)
        }
    }
}

private struct LiveActivitySharingOptionsSheet: View {
    let isEnabled: Bool
    let mode: LiveVisibilityMode
    let friends: [ChatViewModel.FriendDisplay]
    let selectedFriendIDs: Set<UUID>
    let isSaving: Bool
    let onChooseOff: () -> Void
    let onChooseAllFriends: () -> Void
    let onChooseSelectedFriends: () -> Void
    let onLoadFriends: () -> Void
    let onToggleFriend: (UUID) -> Void
    let onClose: () -> Void
    var embedsInNavigationStack = true
    var showsCloseButton = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var isSelectedFriendsExpanded = false

    @ViewBuilder
    var body: some View {
        if embedsInNavigationStack {
            NavigationStack {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FGSpacing.md) {
                Text("Choose who can see your public Live activity.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .padding(.horizontal, FGSpacing.xs)

                VStack(alignment: .leading, spacing: 0) {
                    optionRow(
                        title: "Off",
                        subtitle: "Hide your Live activity from friend presence.",
                        systemImage: "eye.slash.fill",
                        isSelected: !isEnabled,
                        action: onChooseOff
                    )

                    optionDivider()

                    optionRow(
                        title: "All Friends",
                        subtitle: "All accepted friends can see when you join public activity.",
                        systemImage: "person.2.fill",
                        isSelected: isEnabled && mode == .allFriends,
                        action: onChooseAllFriends
                    )

                    optionDivider()

                    selectedFriendsSection()
                }
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                            .fill(SettingsPremiumChrome.cardFill(colorScheme))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                        .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
                }
            }
            .padding(FGSpacing.lg)
        }
        .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
        .navigationTitle("Live Activity Sharing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
        .tint(FGColor.accentGreen)
        .onAppear {
            isSelectedFriendsExpanded = isEnabled && mode == .selectedFriends
            if isSelectedFriendsExpanded {
                onLoadFriends()
            }
        }
        .onChange(of: mode) { _, newMode in
            guard newMode != .selectedFriends else { return }
            withAnimation(.snappy(duration: 0.22)) {
                isSelectedFriendsExpanded = false
            }
        }
    }

    private func optionDivider() -> some View {
        Divider()
            .overlay(SettingsPremiumChrome.divider(colorScheme))
            .opacity(0.42)
            .padding(.leading, 58)
            .padding(.trailing, FGSpacing.md)
    }

    private func optionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: FGSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(FGColor.accentBlue)
                }
                .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(FGColor.accentGreen)
                }
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, 12)
            .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    private func selectedFriendsSection() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.24)) {
                    isSelectedFriendsExpanded.toggle()
                }
                if isSelectedFriendsExpanded {
                    onLoadFriends()
                    onChooseSelectedFriends()
                }
            } label: {
                HStack(alignment: .center, spacing: FGSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(FGColor.accentBlue)
                    }
                    .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Selected Friends")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                        Text(selectedFriendsSubtitle)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else if isEnabled && mode == .selectedFriends {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(FGColor.accentGreen)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                        .rotationEffect(.degrees(isSelectedFriendsExpanded ? 0 : -90))
                        .frame(width: 16, height: 16)
                        .animation(.snappy(duration: 0.22), value: isSelectedFriendsExpanded)
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, 12)
                .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSaving && !(isEnabled && mode == .selectedFriends))

            if isSelectedFriendsExpanded {
                optionDivider()
                selectedFriendsList()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.24), value: isSelectedFriendsExpanded)
    }

    private var selectedFriendsSubtitle: String {
        guard isEnabled && mode == .selectedFriends else {
            return "Pick specific friends who can see your Live activity."
        }
        switch selectedFriendIDs.count {
        case 0:
            return "No friends selected yet."
        case 1:
            return "1 friend can see your Live activity."
        default:
            return "\(selectedFriendIDs.count) friends can see your Live activity."
        }
    }

    @ViewBuilder
    private func selectedFriendsList() -> some View {
        if friends.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                    .frame(width: 32, height: 32)
                Text("Accepted friends will appear here.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, 10)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(friends) { friend in
                    selectedFriendRow(friend)
                    if friend.id != friends.last?.id {
                        optionDivider()
                    }
                }
            }
        }
    }

    private func selectedFriendRow(_ friend: ChatViewModel.FriendDisplay) -> some View {
        Button {
            guard !isSaving else { return }
            onToggleFriend(friend.id)
        } label: {
            HStack(spacing: 10) {
                SocialAvatarRenderer.socialAvatarView(for: friend.preview, size: 34)
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.preview.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Friend" : friend.preview.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                        .lineLimit(1)
                    Text(friend.preview.publicHandleLine)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: selectedFriendIDs.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: selectedFriendIDs.contains(friend.id) ? .semibold : .regular))
                    .foregroundStyle(selectedFriendIDs.contains(friend.id) ? FGColor.accentGreen : SettingsPremiumChrome.mutedText(colorScheme))
            }
            .padding(.leading, FGSpacing.md)
            .padding(.trailing, FGSpacing.md)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }
}

// MARK: - Phase B2 (managed venue location picker — Settings + VenueOwnerDashboard)

/// Dropdown for **approved** managed venues (see ``MapViewModel/managedVenuesForOwner()``). Settings may also offer **Add venue**, which opens the same submit-new-location flow as before (distinct from Discover → Claim this venue on an existing listing).
struct BusinessLocationVenuePicker: View {
    enum Chrome {
        case settings
        case dashboard
    }

    @ObservedObject var viewModel: MapViewModel
    @Environment(\.colorScheme) private var colorScheme
    var chrome: Chrome = .settings
    /// When set (Settings), shown as the last menu action to submit a new business location for review.
    var onRequestAddNewLocation: (() -> Void)?

    init(viewModel: MapViewModel, chrome: Chrome = .settings, onRequestAddNewLocation: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.chrome = chrome
        self.onRequestAddNewLocation = onRequestAddNewLocation
    }

    private var venuePairs: [(UUID, String)] {
        viewModel.managedVenuesForOwner().compactMap { row in
            guard let id = row.id else { return nil }
            let raw = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let label = raw.isEmpty ? "Location" : raw
            return (id, label)
        }
    }

    private var selectedVenueRow: VenueProfileRow? {
        let selectedId = viewModel.ownerVenueDatabaseId ?? venuePairs.first?.0
        guard let selectedId else { return viewModel.managedVenuesForOwner().first }
        return viewModel.managedVenuesForOwner().first(where: { $0.id == selectedId }) ?? viewModel.managedVenuesForOwner().first
    }

    private var pickerSelection: Binding<UUID?> {
        Binding(
            get: { viewModel.ownerVenueDatabaseId ?? venuePairs.first?.0 },
            set: { newId in
                guard let newId else { return }
                Task {
                    await viewModel.selectManagedVenue(id: newId)
                }
            }
        )
    }

    private var selectedVenueLabel: String {
        let id = viewModel.ownerVenueDatabaseId ?? venuePairs.first?.0
        if let id, let name = venuePairs.first(where: { $0.0 == id })?.1 {
            return name
        }
        return venuePairs.first?.1 ?? "Location"
    }

    private var selectedVenueSubtitle: String {
        if let row = selectedVenueRow {
            let city = row.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let state = row.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let locationLine = [city, state].filter { !$0.isEmpty }.joined(separator: ", ")
            if !locationLine.isEmpty {
                return locationLine
            }
        }
        if venuePairs.count > 1 {
            return "\(venuePairs.count) approved locations available to manage."
        }
        return "Approved location for listings, games, and analytics."
    }

    private var settingsPickerLabel: String {
        switch chrome {
        case .settings:
            return "Current managed venue"
        case .dashboard:
            return "Managing location"
        }
    }

    @ViewBuilder
    private func settingsPickerRowLabel(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        showsApprovedBadge: Bool,
        chevronSystemName: String
    ) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: FGSpacing.xs + 2) {
                    Text(title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if showsApprovedBadge {
                        managedVenueApprovedBadge()
                    }
                }

                Text(subtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: chevronSystemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .frame(width: 16, height: 16, alignment: .center)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 13)
        .frame(minHeight: 70, alignment: .center)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func addVenueMenuButton() -> some View {
        Button {
            onRequestAddNewLocation?()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FGColor.accentBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add venue")
                        .foregroundStyle(.primary)
                    Text("Submit a new location for review")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func settingsChromeMenuContent() -> some View {
        ForEach(venuePairs, id: \.0) { pair in
            Button {
                Task {
                    await viewModel.selectManagedVenue(id: pair.0)
                }
            } label: {
                Text(pair.1)
            }
        }
        if onRequestAddNewLocation != nil {
            if !venuePairs.isEmpty {
                Divider()
            }
            addVenueMenuButton()
        }
    }

    @ViewBuilder
    private func settingsChromeMenuLabel() -> some View {
        let isEmpty = venuePairs.isEmpty
        settingsPickerRowLabel(
            title: isEmpty ? "No approved venues yet" : selectedVenueLabel,
            subtitle: isEmpty
                ? "Add a location for review, or claim an existing venue from the map (Discover → venue → Claim this venue)."
                : selectedVenueSubtitle,
            systemImage: isEmpty ? "mappin.and.ellipse" : "building.2",
            tint: isEmpty ? FGColor.mutedText(colorScheme) : FGColor.accentBlue,
            showsApprovedBadge: !isEmpty,
            chevronSystemName: "chevron.up.chevron.down"
        )
    }

    @ViewBuilder
    private func settingsChromePickerStack() -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.xs) {
            Text(settingsPickerLabel)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            if venuePairs.isEmpty, onRequestAddNewLocation == nil {
                settingsPickerRowLabel(
                    title: "No approved venues yet",
                    subtitle: "Claim a venue from the map: Discover → venue → Claim this venue.",
                    systemImage: "mappin.and.ellipse",
                    tint: FGColor.mutedText(colorScheme),
                    showsApprovedBadge: false,
                    chevronSystemName: "chevron.right"
                )
                .opacity(0.88)
                .allowsHitTesting(false)
            } else {
                Menu {
                    settingsChromeMenuContent()
                } label: {
                    settingsChromeMenuLabel()
                }
            }
        }
        .onAppear { viewModel.logBusinessSwitcherDebug() }
    }

    /// Managed venues in this list are approved for owner tools; shown in Settings + dashboard pickers.
    @ViewBuilder
    private func managedVenueApprovedBadge() -> some View {
        Text("Approved")
            .font(FGTypography.metadata.weight(.semibold))
            .foregroundStyle(FGColor.accentGreen)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.12))
            .clipShape(Capsule(style: .continuous))
    }

    private func logPickerDebug() {
#if DEBUG
        let n = venuePairs.count
        let sid = viewModel.ownerVenueDatabaseId?.uuidString ?? "nil"
        let sname = venuePairs.first(where: { $0.0 == viewModel.ownerVenueDatabaseId })?.1
            ?? venuePairs.first?.1
            ?? "nil"
        print("[BusinessLocationPicker] venues count=\(n)")
        print("[BusinessLocationPicker] selected id=\(sid)")
        print("[BusinessLocationPicker] selected name=\(sname)")
#endif
    }

    var body: some View {
        Group {
            if venuePairs.isEmpty {
                switch chrome {
                case .settings:
                    settingsChromePickerStack()
                case .dashboard:
                    EmptyView()
                }
            } else {
                switch chrome {
                case .settings:
                    settingsChromePickerStack()

                case .dashboard:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Managing location")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Managing location", selection: pickerSelection) {
                            ForEach(venuePairs, id: \.0) { pair in
                                HStack {
                                    Text(pair.1)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 6)
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                                .tag(Optional(pair.0))
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(FGAdaptiveSurface.controlFill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .onAppear { logPickerDebug() }
        .onChange(of: viewModel.ownerVenueDatabaseId) { _, _ in
            logPickerDebug()
        }
    }
}

// MARK: - Venue owner sign-out
// Account-tab business log out uses ``MapViewModel/logoutUser()`` (full Supabase sign-out + session cleanup).
// ``MapViewModel/venueOwnerLocalSignOutPreservingSupabaseSession()`` remains for flows that must keep the auth session while clearing owner UI.
