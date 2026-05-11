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

/// Account tab: end-user and venue-owner auth, profile, notifications, Apple Calendar sync, and entry to venue dashboard flows.
struct SettingsScreen: View {
    @ObservedObject var viewModel: MapViewModel

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

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isLoggedIn || viewModel.isVenueOwnerLoggedIn {
                    Section {
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
                    }
                } else {
                    Section {
                        Button {
                            showUserAuthSheet = true
                        } label: {
                            settingsRow(
                                title: "Sign in or create account",
                                subtitle: "Sync your profile and activity.",
                                systemImage: "person.crop.circle.badge.plus"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("GENERAL") {
                    Button { showNotificationsSheet = true } label: {
                        settingsRow(title: "Notifications", subtitle: viewModel.notifyBeforeGame ? "On" : "Off", systemImage: "bell.badge")
                    }
                    .buttonStyle(.plain)

                    Button { showTimeZoneSheet = true } label: {
                        settingsRow(title: "Game Time Zone", subtitle: viewModel.selectedTimeZone.rawValue, systemImage: "clock")
                    }
                    .buttonStyle(.plain)
                }

                Section("LEGAL & SAFETY") {
                    Button { legalDocumentSheet = .privacyPolicy } label: {
                        settingsRow(
                            title: SettingsLegalDocumentKind.privacyPolicy.title,
                            subtitle: SettingsLegalDocumentKind.privacyPolicy.rowSubtitle,
                            systemImage: SettingsLegalDocumentKind.privacyPolicy.systemImage
                        )
                    }
                    .buttonStyle(.plain)

                    Button { legalDocumentSheet = .termsOfService } label: {
                        settingsRow(
                            title: SettingsLegalDocumentKind.termsOfService.title,
                            subtitle: SettingsLegalDocumentKind.termsOfService.rowSubtitle,
                            systemImage: SettingsLegalDocumentKind.termsOfService.systemImage
                        )
                    }
                    .buttonStyle(.plain)

                    Button { legalDocumentSheet = .communityGuidelines } label: {
                        settingsRow(
                            title: SettingsLegalDocumentKind.communityGuidelines.title,
                            subtitle: SettingsLegalDocumentKind.communityGuidelines.rowSubtitle,
                            systemImage: SettingsLegalDocumentKind.communityGuidelines.systemImage
                        )
                    }
                    .buttonStyle(.plain)

                    Button { legalDocumentSheet = .safetyReporting } label: {
                        settingsRow(
                            title: SettingsLegalDocumentKind.safetyReporting.title,
                            subtitle: SettingsLegalDocumentKind.safetyReporting.rowSubtitle,
                            systemImage: SettingsLegalDocumentKind.safetyReporting.systemImage
                        )
                    }
                    .buttonStyle(.plain)
                }

                Section("HELP & SUPPORT") {
                    Button { showContactSupportSheet = true } label: {
                        settingsRow(
                            title: "Contact GameOn Support",
                            subtitle: "Message the team",
                            systemImage: "envelope.open.fill"
                        )
                    }
                    .buttonStyle(.plain)
                }

                if viewModel.isLoggedIn {
                    Section("ACCOUNT") {
                        Button { showResetPasswordSheet = true } label: {
                            settingsRow(title: "Reset Password", subtitle: "Send a reset email.", systemImage: "key")
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await viewModel.logoutUser() }
                        } label: {
                            settingsRow(title: "Logout", subtitle: nil, systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(.plain)

                        Button { showDeleteAccountSheet = true } label: {
                            settingsRow(title: "Delete Account", subtitle: "Permanently remove your data.", systemImage: "trash", tint: .red)
                        }
                        .buttonStyle(.plain)

                        if viewModel.isVenueOwnerLoggedIn {
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
                } else if viewModel.isVenueOwnerLoggedIn {
                    Section("ACCOUNT") {
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
                }

                Section("Business") {
                    if viewModel.isVenueOwnerLoggedIn {
                        Group {
                            if viewModel.isVenueOwnerBusinessDataLoading {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Loading business data…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            } else if !viewModel.hasBusinessAccountForOwner() {
                                settingsInfoRow(
                                    title: "Business account",
                                    subtitle: settingsBusinessAccountSubtitle(),
                                    systemImage: viewModel.businessAccountStatusIconName(),
                                    tint: viewModel.businessAccountStatusTint()
                                )

                                Text("Add a businesses record for this sign-in email before locations can be linked or approved.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))

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

                                settingsInfoRow(
                                    title: "Location status",
                                    subtitle: viewModel.businessSettingsLocationStatusSubtitle(),
                                    systemImage: viewModel.businessSettingsLocationStatusSystemImage(),
                                    tint: settingsLocationStatusTint()
                                )

                                if !viewModel.pendingVenueClaimsForSettings.isEmpty {
                                    pendingVenueClaimsList()
                                }
                                if !viewModel.rejectedVenueClaimsForSettings.isEmpty {
                                    rejectedVenueClaimsList()
                                }
                            } else if viewModel.managedVenuesForOwner().isEmpty {
                                Text("New location requests are reviewed before you can manage games and analytics.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))

                                settingsInfoRow(
                                    title: "Business account",
                                    subtitle: settingsBusinessAccountSubtitle(),
                                    systemImage: viewModel.businessAccountStatusIconName(),
                                    tint: viewModel.businessAccountStatusTint()
                                )

                                settingsInfoRow(
                                    title: "Location status",
                                    subtitle: viewModel.businessSettingsLocationStatusSubtitle(),
                                    systemImage: viewModel.businessSettingsLocationStatusSystemImage(),
                                    tint: settingsLocationStatusTint()
                                )

                                if let bannerText = addLocationSubmitBannerDisplayText(), !bannerText.isEmpty {
                                    Text(bannerText)
                                        .font(.caption)
                                        .foregroundStyle(addLocationSubmitBannerForegroundStyle())
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
                                }

                                if !viewModel.pendingVenueClaimsForSettings.isEmpty {
                                    pendingVenueClaimsList()
                                }
                                if !viewModel.rejectedVenueClaimsForSettings.isEmpty {
                                    rejectedVenueClaimsList()
                                }

                                BusinessLocationVenuePicker(
                                    viewModel: viewModel,
                                    chrome: .settings,
                                    onRequestAddNewLocation: { openAddLocationFromPicker() }
                                )
                            } else {
                                settingsInfoRow(
                                    title: "Business account",
                                    subtitle: settingsBusinessAccountSubtitle(),
                                    systemImage: viewModel.businessAccountStatusIconName(),
                                    tint: viewModel.businessAccountStatusTint()
                                )

                                if let bannerText = addLocationSubmitBannerDisplayText(), !bannerText.isEmpty {
                                    Text(bannerText)
                                        .font(.caption)
                                        .foregroundStyle(addLocationSubmitBannerForegroundStyle())
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
                                }

                                if !viewModel.pendingVenueClaimsForSettings.isEmpty {
                                    pendingVenueClaimsList()
                                }
                                if !viewModel.rejectedVenueClaimsForSettings.isEmpty {
                                    rejectedVenueClaimsList()
                                }

                                BusinessLocationVenuePicker(
                                    viewModel: viewModel,
                                    chrome: .settings,
                                    onRequestAddNewLocation: { openAddLocationFromPicker() }
                                )

                                Button { venueOwnerDashboardSheet = .manageVenue } label: {
                                    settingsRow(
                                        title: "Manage listing",
                                        subtitle: "Photos, address, TVs, seating for this location.",
                                        systemImage: "building.2"
                                    )
                                }
                                .buttonStyle(.plain)

                                if settingsVenueClaimApprovedForStatusRow() {
                                    Button { venueOwnerDashboardSheet = .manageGames } label: {
                                        settingsRow(
                                            title: "Manage Games",
                                            subtitle: "Add, edit, or cancel games.",
                                            systemImage: "sportscourt"
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    Button { venueOwnerDashboardSheet = .statistics } label: {
                                        settingsRow(
                                            title: "Statistics",
                                            subtitle: "Live game analytics.",
                                            systemImage: "chart.bar"
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Button { showReportedCommentsSheet = true } label: {
                                settingsRow(
                                    title: "Flagged Comments",
                                    subtitle: "Review reported venue activity.",
                                    systemImage: "exclamationmark.bubble"
                                )
                            }
                            .buttonStyle(.plain)
                        }
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
                    } else {
                        Button { showVenueAuthSheet = true } label: {
                            settingsRow(title: "Business owner sign in", subtitle: "Manage your locations and listings.", systemImage: "building.2.crop.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: SettingsScrollBottomLayout.accountTabScrollBottomInset)
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.92), Color.gray.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
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
        }
        .onChange(of: viewModel.isVenueOwnerLoggedIn) { _, _ in
            venuePassword = ""
        }
        .sheet(item: $venueOwnerDashboardSheet) { route in
            VenueOwnerDashboardView(viewModel: viewModel, entryPoint: route.entryPoint)
                .id(route.id)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
    private func settingsRow(title: String, subtitle: String?, systemImage: String, tint: Color = .primary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Non-interactive settings row (no chevron) for read-only info such as venue claim status.
    @ViewBuilder
    private func settingsInfoRow(title: String, subtitle: String?, systemImage: String, tint: Color = .primary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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

    /// Presents add-location sheet with a blank form (used from Managing location menu / Add first location).
    private func openAddLocationFromPicker() {
#if DEBUG
        print("[AddLocationForm] initialized fresh")
        print("[AddLocationForm] opened from picker")
#endif
        addLocationSubmitBanner = nil
        addLocationSheetFormState.reset(reason: "open")
        showAddLocationSheet = true
    }

    @ViewBuilder
    private func pendingVenueClaimsList() -> some View {
        Group {
            Text("Pending locations")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 2, trailing: 16))

            ForEach(viewModel.pendingVenueClaimsForSettings) { claim in
                let rowBusy = pendingRefreshingClaimId == claim.id
                let anyRowRefreshing = pendingRefreshingClaimId != nil
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settingsPendingClaimTitle(claim))
                            .font(.body.weight(.semibold))
                        if let line = settingsPendingClaimCityStateLine(claim) {
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Pending review")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                    }
                    .buttonStyle(.plain)
                    .disabled(anyRowRefreshing || viewModel.isVenueOwnerBusinessDataLoading)
                    .accessibilityLabel("Refresh status for this location")
                }
                .padding(.vertical, 4)
            }
        }
    }

    private static let rejectedVenueClaimMessage =
        "This location request was rejected. Please submit a new venue request."

    @ViewBuilder
    private func rejectedVenueClaimsList() -> some View {
        Group {
            Text("Rejected locations")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 2, trailing: 16))

            ForEach(viewModel.rejectedVenueClaimsForSettings) { claim in
                let rowBusy = pendingRefreshingClaimId == claim.id
                let anyRowRefreshing = pendingRefreshingClaimId != nil
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settingsPendingClaimTitle(claim))
                            .font(.body.weight(.semibold))
                        if let line = settingsPendingClaimCityStateLine(claim) {
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Rejected")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                        Text(Self.rejectedVenueClaimMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
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
                        }
                        .buttonStyle(.plain)
                        .disabled(anyRowRefreshing || viewModel.isVenueOwnerBusinessDataLoading)
                        .accessibilityLabel("Refresh status for this location")
                    }
                }
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
        }
        .animation(.easeOut(duration: 0.22), value: viewModel.rejectedVenueClaimsForSettings.map(\.id))
    }

    private func settingsBusinessAccountSubtitle() -> String {
        guard viewModel.hasBusinessAccountForOwner() else {
            return "Not set up — no businesses row for this email yet."
        }
        if let member = settingsBusinessMemberSinceLine() {
            return "Active\n\(member)"
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

    private func addLocationSubmitBannerForegroundStyle() -> Color {
        if viewModel.hasActiveVenueClaimRejectionForBusinessUI { return .red }
        if viewModel.businessSettingsLocationChrome() == .rejected { return .red }
        return .green
    }

    /// After Add Location succeeds we set ``addLocationSubmitBanner``; copy tracks ``approval_status`` via pending rows + location chrome.
    private func addLocationSubmitBannerDisplayText() -> String? {
        guard addLocationSubmitBanner != nil else { return nil }
        if !viewModel.pendingVenueClaimsForSettings.isEmpty {
            return "Location request submitted. GameOn will review it before this location can manage games."
        }
        if viewModel.hasActiveVenueClaimRejectionForBusinessUI {
            return Self.rejectedVenueClaimMessage
        }
        switch viewModel.businessSettingsLocationChrome() {
        case .approved:
            return "Your location is approved and can now manage listings, games, and venue activity."
        case .pendingReview:
            return "Location request submitted. GameOn will review it before this location can manage games."
        case .rejected:
            return Self.rejectedVenueClaimMessage
        case .noLocationsYet, .needsBusinessAccountFirst:
            return "Location request submitted. GameOn will review it before this location can manage games."
        }
    }
}

// MARK: - Add location (Phase C1)

/// Parent-owned draft so ``MapViewModel`` updates after photo upload do not drop ``@State`` inside the sheet.
final class AddLocationSheetFormState: ObservableObject {
    @Published var locationName = ""
    @Published var streetAddress = ""
    @Published var city = ""
    @Published var state = "UT"
    @Published var country = BusinessLocationCountryPolicy.defaultCountryCode
    @Published var zip = ""
    @Published var phone = ""
    @Published var website = ""
    @Published var description = ""
    @Published var proofNote = ""
    @Published var screenCount = 1
    @Published var servesFood = false
    @Published var hasWifi = false
    @Published var hasGarden = false
    @Published var hasProjector = false
    @Published var petFriendly = false
    @Published var familyFriendly = false
    @Published var parkingAvailable = false
    @Published var coverPhotoURL = ""
    @Published var menuPhotoURL = ""
    @Published var displayedCoverPhotoURL = ""
    @Published var displayedMenuPhotoURL = ""
    @Published var errorMessage = ""
    @Published var isSubmitting = false

    func reset(reason: String) {
#if DEBUG
        print("[AddLocationForm] reset reason=\(reason)")
#endif
        locationName = ""
        streetAddress = ""
        city = ""
        state = "UT"
        country = BusinessLocationCountryPolicy.defaultCountryCode
        zip = ""
        phone = ""
        website = ""
        description = ""
        proofNote = ""
        screenCount = 1
        servesFood = false
        hasWifi = false
        hasGarden = false
        hasProjector = false
        petFriendly = false
        familyFriendly = false
        parkingAvailable = false
        coverPhotoURL = ""
        menuPhotoURL = ""
        displayedCoverPhotoURL = ""
        displayedMenuPhotoURL = ""
        errorMessage = ""
        isSubmitting = false
    }
}

private struct AddBusinessLocationRequestSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var form: AddLocationSheetFormState
    @Binding var submitBanner: String?
    @Binding var isPresented: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var selectedCoverPicker: PhotosPickerItem?
    @State private var selectedMenuPicker: PhotosPickerItem?

    /// Non-nil ``submitBanner`` only flags success; Settings parent maps status to user-facing copy.
    private static let successCopy = "submitted"

    /// Only URLs/uploads from this sheet — never fall back to managed-venue / signup state on ``MapViewModel``.
    private var coverPickerRemotePreview: String {
        form.displayedCoverPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var menuPickerRemotePreview: String {
        form.displayedMenuPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasMainVenuePhoto: Bool {
        !form.coverPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasMenuVenuePhoto: Bool {
        !form.menuPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var missingSubmitRequirements: [String] {
        var m: [String] = []
        if !viewModel.hasBusinessAccountForOwner() {
            m.append("Business account required")
        }
        if viewModel.currentBusinessIdForAddLocation() == nil {
            m.append("Could not resolve business for this request")
        }
        if form.locationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing location name")
        }
        if form.streetAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing address")
        }
        if form.city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing city")
        }
        if form.state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing state")
        }
        if form.zip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing ZIP code")
        }
        if form.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing phone")
        }
        if form.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing description")
        }
        if form.proofNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.append("Missing proof note")
        }
        if !hasMainVenuePhoto {
            m.append("Missing main venue photo")
        }
        return m
    }

    private var canSubmitLocationRequest: Bool {
        !form.isSubmitting && missingSubmitRequirements.isEmpty
    }

#if DEBUG
    private func logAddLocationFormState() {
        let bid = viewModel.currentBusinessIdForAddLocation()?.uuidString ?? "nil"
        print("[AddLocationForm] hasMainPhoto=\(hasMainVenuePhoto)")
        print("[AddLocationForm] hasMenuPhoto=\(hasMenuVenuePhoto)")
        print("[AddLocationForm] canSubmit=\(canSubmitLocationRequest)")
        print("[AddLocationForm] businessId=\(bid)")
    }
#endif

    var body: some View {
        let missing = missingSubmitRequirements
        NavigationStack {
            Form {
                Section("Location") {
                    TextField("Location name", text: $form.locationName)
                        .textInputAutocapitalization(.words)
                    TextField("Street address", text: $form.streetAddress)
                    TextField("City", text: $form.city)
                    BusinessLocationUSStatePicker(stateCode: $form.state)
                    TextField("ZIP", text: $form.zip)
                        .textInputAutocapitalization(.never)
                    BusinessLocationCountryField(countryCode: $form.country)
                    TextField("Phone", text: $form.phone)
                        .keyboardType(.phonePad)
                    TextField("Website (optional)", text: $form.website)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section {
                    AddLocationVenueFeaturesGrid(
                        screenCount: $form.screenCount,
                        servesFood: $form.servesFood,
                        hasWifi: $form.hasWifi,
                        hasGarden: $form.hasGarden,
                        hasProjector: $form.hasProjector,
                        petFriendly: $form.petFriendly,
                        parkingAvailable: $form.parkingAvailable,
                        familyFriendly: $form.familyFriendly,
                        maxScreenCount: 40
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                }

                Section("Details") {
                    TextField("Description", text: $form.description, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Proof note (how you operate this location)", text: $form.proofNote, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section("Photos") {
                    VenueOwnerListingPhotoPickerCard(
                        title: "Business Photo",
                        subtitle: "Main photo of your business",
                        pickerSelection: $selectedCoverPicker,
                        remotePreviewURL: coverPickerRemotePreview,
                        localPreviewData: nil
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)

                    VenueOwnerListingPhotoPickerCard(
                        title: "Menu Photo",
                        subtitle: "Food or drink menu photo",
                        pickerSelection: $selectedMenuPicker,
                        remotePreviewURL: menuPickerRemotePreview,
                        localPreviewData: nil
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                }

                Section {
                    if missing.isEmpty {
                        Text("All required fields are complete.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(missing, id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Required to submit")
                }

                if !form.errorMessage.isEmpty {
                    Section {
                        Text(form.errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add location")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                form.errorMessage = ""
#if DEBUG
                logAddLocationFormState()
#endif
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        form.reset(reason: "cancel")
                        dismiss()
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(form.isSubmitting ? "Submitting…" : "Submit location request") {
                        Task { await submit() }
                    }
                    .disabled(!canSubmitLocationRequest)
                }
            }
            .onChange(of: form.coverPhotoURL) { _, _ in
#if DEBUG
                logAddLocationFormState()
#endif
            }
            .onChange(of: form.menuPhotoURL) { _, _ in
#if DEBUG
                logAddLocationFormState()
#endif
            }
            .onChange(of: form.locationName) { _, _ in
#if DEBUG
                logAddLocationFormState()
#endif
            }
            .onChange(of: form.proofNote) { _, _ in
#if DEBUG
                logAddLocationFormState()
#endif
            }
            .onChange(of: selectedCoverPicker) { _, item in
                Task {
                    guard let item else { return }
#if DEBUG
                    print("[AddLocationForm] photo selected type=bar")
#endif
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let url = await viewModel.uploadVenuePhoto(data: data, fileName: "cover.jpg") {
                        await MainActor.run {
                            form.coverPhotoURL = url
                            form.displayedCoverPhotoURL = VenueOwnerPhotoPickerCopy.urlWithCacheBust(url)
                            selectedCoverPicker = nil
                            form.errorMessage = ""
#if DEBUG
                            print("[AddLocationForm] preserving form venueName=\(form.locationName)")
                            logAddLocationFormState()
#endif
                        }
                    } else {
                        await MainActor.run {
                            form.errorMessage = VenueOwnerPhotoPickerCopy.pickFailureUserHint()
                            selectedCoverPicker = nil
                        }
                    }
                }
            }
            .onChange(of: selectedMenuPicker) { _, item in
                Task {
                    guard let item else { return }
#if DEBUG
                    print("[AddLocationForm] photo selected type=menu")
#endif
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let url = await viewModel.uploadVenuePhoto(data: data, fileName: "menu.jpg") {
                        await MainActor.run {
                            form.menuPhotoURL = url
                            form.displayedMenuPhotoURL = VenueOwnerPhotoPickerCopy.urlWithCacheBust(url)
                            selectedMenuPicker = nil
                            form.errorMessage = ""
#if DEBUG
                            print("[AddLocationForm] preserving form venueName=\(form.locationName)")
                            logAddLocationFormState()
#endif
                        }
                    } else {
                        await MainActor.run {
                            form.errorMessage = VenueOwnerPhotoPickerCopy.pickFailureUserHint()
                            selectedMenuPicker = nil
                        }
                    }
                }
            }
        }
    }

    private func submit() async {
        await MainActor.run {
            form.errorMessage = ""
            form.isSubmitting = true
        }

        if viewModel.currentBusinessIdForAddLocation() == nil || !viewModel.hasBusinessAccountForOwner() {
#if DEBUG
            print("[AddLocation] blocked no business id")
#endif
            await MainActor.run {
                form.isSubmitting = false
                form.errorMessage = "Could not find a business account for this request."
            }
            return
        }

        let claim = AddLocationClaimForm(
            venueName: form.locationName,
            address: form.streetAddress,
            city: form.city,
            state: form.state,
            country: form.country,
            zip: form.zip,
            phone: form.phone,
            website: form.website,
            description: form.description,
            proofNote: form.proofNote,
            screenCount: form.screenCount,
            servesFood: form.servesFood,
            hasWifi: form.hasWifi,
            hasGarden: form.hasGarden,
            hasProjector: form.hasProjector,
            petFriendly: form.petFriendly,
            familyFriendly: form.familyFriendly,
            parkingAvailable: form.parkingAvailable,
            coverPhotoURL: form.coverPhotoURL,
            menuPhotoURL: form.menuPhotoURL
        )

        let err = await viewModel.submitAddLocationClaim(form: claim)

        await MainActor.run {
            form.isSubmitting = false
            if let err {
                form.errorMessage = err
            } else {
                submitBanner = Self.successCopy
                form.reset(reason: "success")
                dismiss()
                isPresented = false
            }
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
                    Text("Deleting your account permanently removes your profile and associated data from GameOn.")
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

private struct SettingsUserAuthSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var email: String
    @Binding var password: String
    @Binding var showRegisterMode: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Account")
                    .font(.largeTitle.weight(.bold))
                    .padding(.top, 10)

                Text("Sign in to sync your profile and activity.")
                    .foregroundStyle(.secondary)

                SettingsAccountCard(
                    viewModel: viewModel,
                    email: $email,
                    password: $password,
                    showRegisterMode: $showRegisterMode
                )
                .padding()
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                SettingsFanPasswordResetCard(viewModel: viewModel, loginEmail: $email)
                    .padding()
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
        }
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.92), Color.gray.opacity(0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
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
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.isVenueOwnerBusinessDataLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading your venues…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else if viewModel.venueOwnerJustCompletedRegistration {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Business account created")
                        .font(.headline)
                        .fontWeight(.bold)

                    Text("Your first location request has been submitted for review.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        viewModel.venueOwnerJustCompletedRegistration = false
                        dismissAuthSheet()
                    } label: {
                        Text("Close")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.black)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 16))
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Business")
                    .font(.largeTitle.weight(.bold))
                    .padding(.top, 10)

                Text("Sign in as a business owner to manage your locations and listings.")
                    .foregroundStyle(.secondary)

                if !viewModel.isVenueOwnerLoggedIn {
                    Text("Claim requests are reviewed before owner tools are enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if viewModel.isVenueOwnerLoggedIn {
                    SettingsVenueAuthSheetSignedInBody(
                        viewModel: viewModel,
                        onRequestVenueProfileDashboard: onRequestVenueProfileDashboard,
                        dismissAuthSheet: { dismiss() }
                    )
                    .padding()
                    .background(Color.white.opacity(0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                } else {
                    SettingsVenueOwnerCard(
                        viewModel: viewModel,
                        venuePassword: $venuePassword,
                        showVenueRegisterMode: $showVenueRegisterMode
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
        }
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.92), Color.gray.opacity(0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
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

    private var accountTypeCapsule: some View {
        Text(accountTypeBadgeText)
            .font(.caption2.weight(.semibold))
            .tracking(0.2)
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    )
            }
            .padding(.top, 4)
            .accessibilityLabel(accountTypeBadgeText)
    }

    private var heroCard: some View {
        HStack(spacing: 14) {
            UserAvatarView(
                avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
                avatarURL: viewModel.currentUserAvatarURL,
                avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
                displayName: resolvedDisplayName,
                email: heroEmailLine,
                size: 64,
                fallbackStyle: .darkCardTranslucent,
                imagePlaceholderTint: .white
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(resolvedDisplayName.isEmpty ? "My profile" : resolvedDisplayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                if !heroEmailLine.isEmpty {
                    Text(heroEmailLine)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                accountTypeCapsule
            }

            Spacer(minLength: 0)

            if viewModel.isLoggedIn {
                Text("Edit")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            } else if viewModel.isVenueOwnerLoggedIn {
                Text("Account")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
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
                        viewModel.venueOwnerLocalSignOutPreservingSupabaseSession()
                        venueOwnerOnDismissSheetsAfterLogout()
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

            Text("When on, GameOn asks for Face ID, Touch ID, or your device passcode before opening the Chat tab. This stays on your device only.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(showRegisterMode ? "Register" : "Login")
                .font(.headline)
                .fontWeight(.bold)
            
            if viewModel.isLoggedIn {
                HStack {
                    Image(systemName: "person.circle.fill")
                        .font(.title)
                    
                    VStack(alignment: .leading) {
                        Text("Signed in")
                            .fontWeight(.bold)
                        Text(viewModel.currentUserEmail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                
                Button {
                    Task {
                        await viewModel.logoutUser()
                        email = ""
                        password = ""
                    }
                } label: {
                    Text("Log Out")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.12))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            } else {
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                
                SecureField("Password", text: $password)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if showRegisterMode {
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            fanSignupPoliciesAccepted.toggle()
                        } label: {
                            Image(systemName: fanSignupPoliciesAccepted ? "checkmark.square.fill" : "square")
                                .font(.title3)
                                .foregroundStyle(fanSignupPoliciesAccepted ? Color.blue : Color.secondary)
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
                            .foregroundStyle(.primary)
                            .tint(.blue)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Button {
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
                } label: {
                    Text(showRegisterMode ? "Create Account" : "Login")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.black)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .disabled(showRegisterMode && !fanSignupPoliciesAccepted)

                
                if !viewModel.authErrorMessage.isEmpty {
                    Text(viewModel.authErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                
                Button {
                    showRegisterMode.toggle()
                } label: {
                    Text(showRegisterMode ? "Already have an account? Login" : "New user? Register")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
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

    private var emailForReset: String {
        if viewModel.isLoggedIn {
            return viewModel.currentUserEmail
        }
        return loginEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reset password")
                .font(.headline)
                .fontWeight(.bold)

            Text("We’ll email you a secure link to choose a new password. Use the same email as your fan account.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.isLoggedIn {
                HStack(spacing: 8) {
                    Image(systemName: "envelope.fill")
                        .foregroundStyle(.secondary)
                    Text(viewModel.currentUserEmail)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                TextField("Email for password reset", text: $loginEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            Button {
                Task {
                    isSending = true
                    await viewModel.sendPasswordResetEmail(emailForReset, accountKind: .fan)
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

            if !viewModel.userPasswordResetMessage.isEmpty {
                Text(viewModel.userPasswordResetMessage)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.green)
            }

            if !viewModel.userPasswordResetError.isEmpty {
                Text(viewModel.userPasswordResetError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
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
    @State private var signupPhone = ""
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

    private var registrationFormComplete: Bool {
        let email = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        let biz = signupBusinessName.trimmingCharacters(in: .whitespacesAndNewlines)
        let loc = signupLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let st = signupStreet.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = signupCity.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = signupState.trimmingCharacters(in: .whitespacesAndNewlines)
        let zip = signupZip.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = signupPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = signupDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let proof = signupProof.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMain = signupCoverData.map { !$0.isEmpty } ?? false
        guard email.contains("@"), !venuePassword.isEmpty else { return false }
        return !biz.isEmpty && !loc.isEmpty && !st.isEmpty && !city.isEmpty && !state.isEmpty && !zip.isEmpty && !phone.isEmpty && !desc.isEmpty && !proof.isEmpty && hasMain
    }

    private var signupPrimarySubmitDisabled: Bool {
        isSignupSubmitting
            || (showVenueRegisterMode && (!venueSignupPoliciesAccepted || !registrationFormComplete))
    }

#if DEBUG
    /// Why `registrationFormComplete` is false (does not duplicate password-in-email checks beyond `emailOk`).
    private func signupFormIncompleteReasons() -> [String] {
        var reasons: [String] = []
        let email = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        if !email.contains("@") { reasons.append("email_invalid_or_missing_@") }
        if venuePassword.isEmpty { reasons.append("password_empty") }
        if signupBusinessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append("business_name_empty") }
        if signupLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append("location_name_empty") }
        if signupStreet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append("street_empty") }
        if signupCity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append("city_empty") }
        if signupState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append("state_empty") }
        if signupZip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append("zip_empty") }
        if signupPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append("phone_empty") }
        if signupDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append("description_empty") }
        if signupProof.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append("proof_empty") }
        let hasMain = signupCoverData.map { !$0.isEmpty } ?? false
        if !hasMain { reasons.append("main_venue_photo_missing") }
        return reasons
    }

    private func logSignupSubmitGates(reason: String) {
        print(
            "[BusinessSignup] gateCheck reason=\(reason) registerMode=\(showVenueRegisterMode) submitDisabled=\(signupPrimarySubmitDisabled) isSignupSubmitting=\(isSignupSubmitting) policiesAccepted=\(venueSignupPoliciesAccepted) registrationFormComplete=\(registrationFormComplete) incomplete=[\(signupFormIncompleteReasons().joined(separator: ","))] coverPhotoBytes=\(signupCoverData?.count ?? 0) menuPhotoBytes=\(signupMenuData?.count ?? 0)"
        )
    }
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Business owner")
                .font(.headline)
                .fontWeight(.bold)

            Text(
                showVenueRegisterMode
                    ? "Create your business account and submit your first location in one step. Owner tools unlock after GameON reviews and approves the location."
                    : "Sign in to manage listings after your business and location are set up."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            TextField("Business email", text: $viewModel.venueOwnerEmail)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            SecureField("Business owner password", text: $venuePassword)
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            if showVenueRegisterMode {
                Text("Business")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("Business / brand name", text: $signupBusinessName)
                    .textInputAutocapitalization(.words)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text("First location")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("Location name", text: $signupLocationName)
                    .textInputAutocapitalization(.words)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                TextField("Street address", text: $signupStreet)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                TextField("City", text: $signupCity)
                    .textInputAutocapitalization(.words)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    BusinessLocationUSStatePicker(title: "State", stateCode: $signupState)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("ZIP", text: $signupZip)
                        .textInputAutocapitalization(.never)
                        .frame(minWidth: 88, maxWidth: 120, alignment: .leading)
                }
                .padding()
                .background(Color.gray.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                BusinessLocationCountryField(countryCode: $signupCountry)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                TextField("Phone", text: $signupPhone)
                    .keyboardType(.phonePad)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                TextField("Website (optional)", text: $signupWebsite)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                TextField("Description", text: $signupDescription, axis: .vertical)
                    .lineLimit(3...8)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                TextField("Proof note (how you operate this location)", text: $signupProof, axis: .vertical)
                    .lineLimit(2...6)
                    .padding()
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

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

                Text("Photos")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VenueOwnerListingPhotoPickerCard(
                    title: "Business Photo",
                    subtitle: "Main photo of your business",
                    pickerSelection: $signupCoverPicker,
                    remotePreviewURL: "",
                    localPreviewData: signupCoverData
                )

                if !(signupCoverData.map { !$0.isEmpty } ?? false) {
                    Text("Main venue photo is required.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                VenueOwnerListingPhotoPickerCard(
                    title: "Menu Photo",
                    subtitle: "Food or drink menu photo",
                    pickerSelection: $signupMenuPicker,
                    remotePreviewURL: "",
                    localPreviewData: signupMenuData
                )

                HStack(alignment: .top, spacing: 10) {
                    Button {
                        venueSignupPoliciesAccepted.toggle()
                    } label: {
                        Image(systemName: venueSignupPoliciesAccepted ? "checkmark.square.fill" : "square")
                            .font(.title3)
                            .foregroundStyle(venueSignupPoliciesAccepted ? Color.blue : Color.secondary)
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
                        .foregroundStyle(.primary)
                        .tint(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button {
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
                            phone: signupPhone,
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
            } label: {
                Text(showVenueRegisterMode ? "Create account & submit location" : "Sign In as Business Owner")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(signupPrimarySubmitDisabled ? Color(white: 0.88) : Color.black)
                    .foregroundStyle(signupPrimarySubmitDisabled ? Color.primary.opacity(0.42) : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(signupPrimarySubmitDisabled)
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
#endif

            Button {
                showVenueRegisterMode.toggle()
            } label: {
                Text(showVenueRegisterMode ? "Already have an account? Sign in" : "New business owner? Register")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.blue)
            }

            if !viewModel.venueAuthErrorMessage.isEmpty {
                Text(viewModel.venueAuthErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 22))
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
                signupPhone = ""
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

/// Dropdown for **approved** managed venues only (see ``MapViewModel/managedVenuesForOwner()``). Pending claims stay in their own list.
struct BusinessLocationVenuePicker: View {
    enum Chrome {
        case settings
        case dashboard
    }

    @ObservedObject var viewModel: MapViewModel
    var chrome: Chrome = .settings
    /// When set (Settings → Business), menu includes **+ Add new location** and zero-venue state shows **Add first location**.
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

    private func invokeAddNewLocation() {
#if DEBUG
        print("[BusinessLocationPicker] add new location selected")
#endif
        onRequestAddNewLocation?()
    }

    /// Managed venues in this list are approved for owner tools; shown in Settings + dashboard pickers.
    @ViewBuilder
    private func managedVenueApprovedBadge() -> some View {
        Text("Approved")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.2))
            .clipShape(Capsule())
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
                if chrome == .settings, onRequestAddNewLocation != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Managing location")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            invokeAddNewLocation()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 26)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add first location")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Request your first venue for this business.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 0)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .onAppear { viewModel.logBusinessSwitcherDebug() }
                } else {
                    EmptyView()
                }
            } else {
                switch chrome {
                case .settings:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Managing location")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if onRequestAddNewLocation != nil {
                            Menu {
                                ForEach(venuePairs, id: \.0) { pair in
                                    Button {
                                        Task {
                                            await viewModel.selectManagedVenue(id: pair.0)
                                        }
                                    } label: {
                                        HStack {
                                            Text(pair.1)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                            Spacer(minLength: 8)
                                            managedVenueApprovedBadge()
                                        }
                                    }
                                }
                                Divider()
                                Button("+ Add new location") {
                                    invokeAddNewLocation()
                                }
                            } label: {
                                HStack(alignment: .center, spacing: 8) {
                                    HStack(spacing: 6) {
                                        Text(selectedVenueLabel)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        managedVenueApprovedBadge()
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                        } else {
                            Picker("Managing location", selection: pickerSelection) {
                                ForEach(venuePairs, id: \.0) { pair in
                                    HStack {
                                        Text(pair.1)
                                        Spacer(minLength: 6)
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }
                                    .tag(Optional(pair.0))
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .onAppear { viewModel.logBusinessSwitcherDebug() }

                case .dashboard:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Managing location")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.78))
                        Picker("Managing location", selection: pickerSelection) {
                            ForEach(venuePairs, id: \.0) { pair in
                                HStack {
                                    Text(pair.1)
                                        .foregroundStyle(.white)
                                    Spacer(minLength: 6)
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                                .tag(Optional(pair.0))
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.12))
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
// See ``MapViewModel/venueOwnerLocalSignOutPreservingSupabaseSession()`` (persists fan mode for cold-start restore).
