import Combine
import PhotosUI
import SwiftUI

// MARK: - Bottom spacing (floating tab bar + sheets)

/// Scroll tail insets for the Account tab and settings-presented sheets.
/// `floatingTabBarStackHeight` must stay aligned with ``MainTabView/floatingTabBarStackHeight``.
enum SettingsScrollBottomLayout {
    static let floatingTabBarStackHeight: CGFloat = 92
    static let breathingRoomBelowLastCard: CGFloat = 22
    static var accountTabScrollBottomInset: CGFloat {
        floatingTabBarStackHeight + breathingRoomBelowLastCard
    }

    /// Sheets are not under the main floating tab; use for scrollable tails above the home indicator / drag handle.
    static let sheetScrollComfortInset: CGFloat = 32
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

private struct PickupGamesListPresentation: Identifiable {
    var id: String { "pickup-games-list" }
}

/// Account tab: end-user and venue-owner auth, profile, notifications, Apple Calendar sync, and entry to venue dashboard flows.
struct SettingsScreen: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var email = ""
    @State private var password = ""
    @State private var venuePassword = ""
    @State private var showRegisterMode = false
    @State private var venueOwnerDashboardSheet: VenueOwnerDashboardSheetRoute?
    @State private var showVenueRegisterMode = false
    @State private var showProfileScreen = false
    @State private var showUserAuthSheet = false
    @State private var showVenueAuthSheet = false
    @State private var showNotificationsSheet = false
    @State private var showTimeZoneSheet = false
    @State private var showResetPasswordSheet = false
    @State private var showDeleteAccountSheet = false
    @State private var showDeleteVenueOwnerSheet = false
    @State private var showReportedCommentsSheet = false
    @State private var showVenueOwnerPasswordResetSheet = false
    @State private var legalDocumentSheet: SettingsLegalDocumentKind?
    @State private var showContactSupportSheet = false
    @State private var showAddLocationSheet = false
    @State private var addLocationSubmitBanner: String?
    /// Holds Add-location draft fields across ``MapViewModel`` publishes (e.g. after photo upload) so the sheet does not reset.
    @StateObject private var addLocationSheetFormState = AddLocationSheetFormState()
    /// Which pending claim row is running ``performPendingClaimRefresh(claimId:)`` (nil = idle).
    @State private var pendingRefreshingClaimId: UUID?
    @State private var pickupGamesListPresentation: PickupGamesListPresentation?
    @State private var pickupGameFormMode: PickupGameFormMode?

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
                    if viewModel.isLoggedIn || viewModel.isVenueOwnerLoggedIn {
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

                    if viewModel.isLoggedIn {
                        settingsSectionCard {
                            Button { showProfileScreen = true } label: {
                                settingsRow(
                                    title: "Edit Profile",
                                    subtitle: "Update your display name, photo, and sports.",
                                    systemImage: "person.crop.circle"
                                )
                            }
                            .buttonStyle(.plain)

                            settingsRowDivider()

                            Button { showResetPasswordSheet = true } label: {
                                settingsRow(title: "Reset Password", subtitle: "Send a reset email.", systemImage: "key")
                            }
                            .buttonStyle(.plain)

                            settingsRowDivider()

                            Button {
                                Task { await viewModel.logoutUser() }
                            } label: {
                                settingsRow(title: "Logout", subtitle: nil, systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            .buttonStyle(.plain)

                            settingsRowDivider()

                            Button { showDeleteAccountSheet = true } label: {
                                settingsRow(title: "Delete Account", subtitle: "Permanently remove your data.", systemImage: "trash", tint: .red)
                            }
                            .buttonStyle(.plain)

                            if viewModel.isVenueOwnerLoggedIn {
                                settingsRowDivider()

                                Button { showDeleteVenueOwnerSheet = true } label: {
                                    settingsRow(
                                        title: "Delete venue owner access",
                                        subtitle: "Remove venue owner profile, listings, and uploads.",
                                        systemImage: "trash",
                                        tint: .red
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                    } else if viewModel.isVenueOwnerLoggedIn {
                        settingsSectionCard {
                            Button { showDeleteVenueOwnerSheet = true } label: {
                                settingsRow(
                                    title: "Delete Account",
                                    subtitle: "Permanently remove your venue owner profile and data.",
                                    systemImage: "trash",
                                    tint: .red
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)

                        settingsSectionCard {
                            Button {
                                performBusinessAccountLogout()
                            } label: {
                                settingsRow(
                                    title: "Log out",
                                    subtitle: "Sign out of this business account.",
                                    systemImage: "rectangle.portrait.and.arrow.right"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    settingsSectionHeader("Account")
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
                                            subtitle: "Photos, menu, amenities, and venue profile.",
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

                Section {
                    settingsSectionCard {
                        Button { showNotificationsSheet = true } label: {
                            settingsRow(title: "Notifications", subtitle: viewModel.notifyBeforeGame ? "On" : "Off", systemImage: "bell.badge")
                        }
                        .buttonStyle(.plain)

                        settingsRowDivider()

                        Button { showTimeZoneSheet = true } label: {
                            settingsRow(title: "Game Time Zone", subtitle: viewModel.selectedTimeZone.rawValue, systemImage: "clock")
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                } header: {
                    settingsSectionHeader("Preferences")
                }

                Section {
                    if viewModel.hasAuthenticatedVenueOwnerSession {
                        settingsSectionCard {
                            settingsInlineNote(
                                "Pickup games are for fan accounts only.",
                                systemImage: "info.circle"
                            )
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                    } else if viewModel.canFanUsePickupGamesUI {
                        settingsSectionCard {
                            Button {
                                pickupGamesListPresentation = PickupGamesListPresentation()
                            } label: {
                                settingsRow(
                                    title: "My pickup games",
                                    subtitle: "View, edit, or remove games you posted.",
                                    systemImage: "list.bullet.rectangle"
                                )
                            }
                            .buttonStyle(.plain)

                            settingsRowDivider()

                            Button {
                                pickupGameFormMode = .add
                            } label: {
                                settingsRow(
                                    title: "Add pickup game",
                                    subtitle: "Post a casual game and optional map pin.",
                                    systemImage: "figure.run"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    settingsSectionHeader("Pickup Games")
                }

                Section {
                    settingsSectionCard {
                        Button { showContactSupportSheet = true } label: {
                            settingsRow(
                                title: "Contact FanGeo Support",
                                subtitle: "Message the team",
                                systemImage: "envelope.open.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                } header: {
                    settingsSectionHeader("Help")
                }

                Section {
                    settingsSectionCard {
                        Button { legalDocumentSheet = .privacyPolicy } label: {
                            settingsRow(
                                title: SettingsLegalDocumentKind.privacyPolicy.title,
                                subtitle: SettingsLegalDocumentKind.privacyPolicy.rowSubtitle,
                                systemImage: SettingsLegalDocumentKind.privacyPolicy.systemImage
                            )
                        }
                        .buttonStyle(.plain)

                        settingsRowDivider()

                        Button { legalDocumentSheet = .termsOfService } label: {
                            settingsRow(
                                title: SettingsLegalDocumentKind.termsOfService.title,
                                subtitle: SettingsLegalDocumentKind.termsOfService.rowSubtitle,
                                systemImage: SettingsLegalDocumentKind.termsOfService.systemImage
                            )
                        }
                        .buttonStyle(.plain)

                        settingsRowDivider()

                        Button { legalDocumentSheet = .communityGuidelines } label: {
                            settingsRow(
                                title: SettingsLegalDocumentKind.communityGuidelines.title,
                                subtitle: SettingsLegalDocumentKind.communityGuidelines.rowSubtitle,
                                systemImage: SettingsLegalDocumentKind.communityGuidelines.systemImage
                            )
                        }
                        .buttonStyle(.plain)

                        settingsRowDivider()

                        Button { legalDocumentSheet = .safetyReporting } label: {
                            settingsRow(
                                title: SettingsLegalDocumentKind.safetyReporting.title,
                                subtitle: SettingsLegalDocumentKind.safetyReporting.rowSubtitle,
                                systemImage: SettingsLegalDocumentKind.safetyReporting.systemImage
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                } header: {
                    settingsSectionHeader("Legal")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: SettingsScrollBottomLayout.accountTabScrollBottomInset)
            }
            .listStyle(.plain)
            .listSectionSpacing(18)
            .scrollContentBackground(.hidden)
            .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                logSettingsBusinessVenueSectionVisibilityForFanAccount()
            }
        }
        .onChange(of: viewModel.openVenueOwnerAuthSheetFromClaimFlow) { _, shouldPresent in
            guard shouldPresent else { return }
            showVenueAuthSheet = true
            viewModel.openVenueOwnerAuthSheetFromClaimFlow = false
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
        .onChange(of: viewModel.canFanUsePickupGamesUI) { _, canUse in
            if !canUse {
                pickupGamesListPresentation = nil
                pickupGameFormMode = nil
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
        .sheet(isPresented: $showNotificationsSheet) {
            NavigationStack {
                Form { SettingsGameNotificationsCard(viewModel: viewModel) }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
                    }
                    .navigationTitle("Notifications")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showNotificationsSheet = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showTimeZoneSheet) {
            NavigationStack {
                Form { SettingsTimeZoneCard(viewModel: viewModel) }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
                    }
                    .navigationTitle("Game Time Zone")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showTimeZoneSheet = false }
                        }
                    }
            }
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
        .sheet(item: $pickupGamesListPresentation) { _ in
            NavigationStack {
                SettingsPickupGamesListSheet(viewModel: viewModel)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
            .onAppear {
                if !viewModel.canFanUsePickupGamesUI {
                    pickupGamesListPresentation = nil
                }
            }
        }
        .sheet(item: $pickupGameFormMode) { mode in
            NavigationStack {
                SettingsPickupGameFormView(viewModel: viewModel, mode: mode) {
                    pickupGameFormMode = nil
                    Task {
                        await viewModel.loadMyPickupGamesForSettings()
                        await viewModel.refreshPickupGamesForDiscoverMap(force: true)
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
            .onAppear {
                if !viewModel.canFanUsePickupGamesUI {
                    pickupGameFormMode = nil
                }
            }
        }
        .sheet(item: $legalDocumentSheet) { document in
            SettingsLegalDocumentSheet(document: document)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showContactSupportSheet) {
            ContactGameOnSupportSheet(
                viewModel: viewModel,
                onRequestSignIn: {
                    showContactSupportSheet = false
                    showUserAuthSheet = true
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func settingsSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(FGTypography.metadata.weight(.semibold))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .textCase(nil)
            .padding(.top, FGSpacing.lg)
            .padding(.bottom, FGSpacing.sm)
    }



    private func settingsSectionCard<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        SettingsSectionCardContainer(content: content)
    }

    private struct SettingsSectionCardContainer<Content: View>: View {
        let content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(1)
        }
    }

    @ViewBuilder
    private func settingsRowDivider() -> some View {
        Divider()
            .overlay(FGColor.divider(colorScheme))
            .padding(.leading, 68)
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
                .font(FGTypography.caption)
                .foregroundStyle(tint ?? FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.md)
    }

    @ViewBuilder
    private func settingsRow(title: String, subtitle: String?, systemImage: String, tint: Color = .primary) -> some View {
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

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .frame(width: 14, height: 14, alignment: .center)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 13)
        .frame(minHeight: 66, alignment: .center)
        .contentShape(Rectangle())
    }

    /// Non-interactive settings row (no chevron) for read-only info such as venue claim status.
    @ViewBuilder
    private func settingsInfoRow(title: String, subtitle: String?, systemImage: String, tint: Color = .primary) -> some View {
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

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 13)
        .frame(minHeight: 66, alignment: .center)
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
    @State private var showVenueOwnerHeroActions = false

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
                Button {
                    showVenueOwnerHeroActions = true
                } label: {
                    heroCard
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    "Business owner",
                    isPresented: $showVenueOwnerHeroActions,
                    titleVisibility: .hidden
                ) {
                    Button("Reset venue password") {
                        venueOwnerOnResetPassword()
                    }
                    Button("Log Out Business Owner", role: .destructive) {
                        Task { @MainActor in
                            await viewModel.logoutUser()
                            venueOwnerOnDismissSheetsAfterLogout()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
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
            Text("Game Time Zone")
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
                SettingsGameNotificationsCard(viewModel: viewModel)
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

private struct SettingsGameNotificationsCard: View {
    @ObservedObject var viewModel: MapViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Game Notifications")
                .font(.title2)
                .fontWeight(.bold)

            Toggle("Notify me before games I’m going to", isOn: $viewModel.notifyBeforeGame)
                .fontWeight(.semibold)

            

            if viewModel.notifyBeforeGame {
                Picker("Remind me before", selection: $viewModel.reminderMinutesBefore) {
                    Text("15 minutes before").tag(15)
                    Text("30 minutes before").tag(30)
                    Text("1 hour before").tag(60)
                    Text("2 hours before").tag(120)
                    Text("3 hours before").tag(180)
                    Text("1 day before").tag(1440)
                }
                .pickerStyle(.menu)

                Toggle("Repeat reminder until game starts", isOn: $viewModel.repeatGameReminder)
                    .fontWeight(.semibold)

                if viewModel.repeatGameReminder {
                    Picker("Repeat every", selection: $viewModel.repeatEveryMinutes) {
                        Text("Every 15 minutes").tag(15)
                        Text("Every 30 minutes").tag(30)
                        Text("Every hour").tag(60)
                        Text("Every 2 hours").tag(120)
                    }
                    .pickerStyle(.menu)
                }
            }
            
            Toggle("Sync games I’m going to with Apple Calendar", isOn: $viewModel.syncGoingGamesToAppleCalendar)
                .fontWeight(.semibold)
            
            Text("When enabled, games marked as Going will be added to your Apple Calendar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 18))
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
                    title: "Menu Photo",
                    subtitle: "Food or drink menu photo",
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
