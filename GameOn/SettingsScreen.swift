import Combine
import CoreLocation
#if canImport(MessageUI)
import MessageUI
#endif
import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

    static func proGold(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.94, green: 0.73, blue: 0.34)
            : Color(red: 0.72, green: 0.50, blue: 0.16)
    }

    static func proGoldDeep(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.62, green: 0.42, blue: 0.14)
            : Color(red: 0.50, green: 0.33, blue: 0.10)
    }

    static func proBadgeText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.10, green: 0.07, blue: 0.02) : .white
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
    case businessDashboard
    case manageVenue
    case manageGames
    case statistics

    var id: String { rawValue }

    var entryPoint: VenueOwnerDashboardEntryPoint {
        switch self {
        case .businessDashboard:
            return .overviewDashboard
        case .manageVenue:
            return .profileEditor
        case .manageGames:
            return .gamesManager
        case .statistics:
            return .analyticsViewer
        }
    }
}

private struct BusinessProfileVenueHydrationState: Equatable {
    let isReady: Bool
    let reason: String
    let selectedVenueId: UUID?
    let managedCount: Int
}

private enum ProfileSettingsRoute: Hashable {
    case liveActivitySharing
    case notifications
    case timeZone
    case language
    case appearance
    case support
    case communityGuidelines
    case trustSafety
    case privacyPolicy
    case termsOfService
    case resetPassword
    case venueResetPassword
}

/// Account tab: end-user and venue-owner auth, profile, notifications, Apple Calendar sync, and entry to venue dashboard flows.
struct SettingsScreen: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject private var notificationSettingsStore: NotificationSettingsStore
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    /// False while Account tab is preserved off-screen (avoids Pokes / Suggested Fans network on launch).
    var isAccountTabSelected: Bool = true

    init(viewModel: MapViewModel, isAccountTabSelected: Bool = true) {
        self.isAccountTabSelected = isAccountTabSelected
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._notificationSettingsStore = ObservedObject(wrappedValue: viewModel.notificationSettingsStore)
    }

    @State private var email = ""
    @State private var password = ""
    @State private var venuePassword = ""
    @State private var showRegisterMode = false
    @State private var venueOwnerDashboardSheet: VenueOwnerDashboardSheetRoute?
    @State private var showVenueRegisterMode = false
    @State private var showProfileSettingsSheet = false
    @State private var showBusinessProSubscriptionSheet = false
    @State private var showBusinessUsageSheet = false
    @State private var showSponsorInquirySheet = false
    @State private var showBusinessActiveVenueSelectionSheet = false
    @State private var businessDashboardQuickActionNotice: String?
    @State private var activeVenueSelectionQuickActionNotice: String?
    @State private var settingsBusinessMembershipStatus: BusinessVenueGamePostingStatus?
    @State private var settingsBusinessHostedGameCycleAudit: BusinessHostedGameCycleAudit?
    @State private var settingsBusinessHostedGameCycleAuditLoading = false
    @State private var settingsBusinessHostedGameCycleAuditUnavailable = false
    @State private var profileSettingsPath = NavigationPath()
    @State private var showUserAuthSheet = false
    @State private var showVenueAuthSheet = false
    @State private var showLiveSharingModeDialog = false
    @State private var showDeleteAccountSheet = false
    @State private var showDeleteVenueOwnerSheet = false
    @State private var showReportedCommentsSheet = false
    @State private var showVenueOwnerPasswordResetSheet = false
    @State private var showAddLocationSheet = false
    @State private var inlineBusinessDashboardGames: [VenueEventRow] = []
    @State private var addLocationSubmitBanner: String?
    @State private var settingsBusinessProfileRefreshSequence = 0
    @State private var settingsBusinessProfileLatestRequestId = 0
    @State private var settingsBusinessProfileLastEntitlementSignature = ""
    @State private var settingsBusinessProfileHydrationInFlight = false
    @State private var settingsBusinessProfileLastPassiveRefreshAt: Date?
    /// Holds Add-location draft fields across ``MapViewModel`` publishes (e.g. after photo upload) so the sheet does not reset.
    @StateObject private var addLocationSheetFormState = AddLocationSheetFormState()
    /// Which pending claim row is running ``performPendingClaimRefresh(claimId:)`` (nil = idle).
    @State private var pendingRefreshingClaimId: UUID?
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage(FanGeoAppearancePreference.appStorageKey) private var appearancePreferenceRaw = FanGeoAppearancePreference.system.rawValue
    @AppStorage(PrivateChatSecuritySettings.requireFaceIDSettingKey) private var requireFaceIDForPrivateChat = false
    @AppStorage(ProGamesFavoriteTeamAutoFollowPreference.enabledKey) private var proGamesAutoFollowFavoriteTeams = false
    @AppStorage(ProGamesFavoriteTeamAutoFollowPreference.windowDaysKey) private var proGamesFavoriteTeamWindowDays = ProGamesFavoriteTeamAutoFollowPreference.Window.next30.rawValue

    private var appearancePreference: FanGeoAppearancePreference {
        FanGeoAppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    private var selectedAppLanguage: AppLanguage {
        L10n.language(for: appLanguageRaw)
    }

    private var privateChatFaceIDBinding: Binding<Bool> {
        Binding(
            get: { requireFaceIDForPrivateChat },
            set: { newValue in
                requireFaceIDForPrivateChat = newValue
                print("[PrivateChatSecurityDebug] settingChanged=\(newValue)")
                if isBusinessAccountProfileContext {
                    print("[BusinessPrivacySettingsDebug] faceIDToggleChanged=\(newValue)")
                }
            }
        )
    }

    private var liveVisibilityBinding: Binding<Bool> {
        Binding(
            get: { viewModel.currentUserLiveVisibilityEnabled },
            set: { newValue in
                Task { await viewModel.setLiveVisibilityEnabled(newValue) }
            }
        )
    }

    private var profileDiscoverabilityBinding: Binding<Bool> {
        Binding(
            get: { viewModel.currentUserDiscoverableByFans },
            set: { newValue in
                Task { await viewModel.setProfileDiscoverableByFans(newValue) }
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

    private var isBusinessAccountProfileContext: Bool {
        viewModel.venueOwnerMode || viewModel.isVenueOwnerLoggedIn || viewModel.currentUserIsBusinessAccount
    }

    private var settingsBusinessProfileHasCachedData: Bool {
        settingsBusinessMembershipStatus != nil
            && viewModel.hasBusinessAccountForOwner()
            && !viewModel.hasArchivedBusinessAccountForOwner()
            && !viewModel.managedVenuesForOwner().isEmpty
    }

    private var canShowLiveActivitySharing: Bool {
        viewModel.canUseFanSocialFeatures && !isBusinessAccountForLiveSharing
    }

    private var canShowPrivateChatFaceIDSetting: Bool {
        viewModel.isLoggedIn || viewModel.isVenueOwnerLoggedIn || viewModel.hasAuthenticatedVenueOwnerSession
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
                    if isBusinessAccountProfileContext {
                        SettingsProfileHero(
                            viewModel: viewModel,
                            businessMembershipStatus: settingsBusinessMembershipStatus,
                            venueOwnerOnNotifications: { showReportedCommentsSheet = true },
                            venueOwnerOnResetPassword: {
                                guard viewModel.canPresentPasswordResetRequestSheet() else {
                                    showVenueOwnerPasswordResetSheet = false
                                    return
                                }
                                showVenueOwnerPasswordResetSheet = true
                            },
                            venueOwnerOnDismissSheetsAfterLogout: {
                                venueOwnerDashboardSheet = nil
                                showVenueOwnerPasswordResetSheet = false
                                showReportedCommentsSheet = false
                                showDeleteVenueOwnerSheet = false
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                        .onAppear {
                            print("[SponsoredPlacementDebug] accountProfileBranch=businessHero profileIdentityCardRendered=false reason=businessAccountProfileContext isAccountTabSelected=\(isAccountTabSelected)")
#if DEBUG
                            print("[BusinessDashboardCleanup] blockedFanIdentityCardForBusiness=true")
#endif
                        }
                    } else if viewModel.isLoggedIn {
                        ProfileIdentityCard(
                            viewModel: viewModel,
                            isAccountTabActive: isAccountTabSelected
                        )
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                        .onAppear {
                            print("[SponsoredPlacementDebug] accountProfileBranch=fanIdentityCard profileIdentityCardRendered=true isAccountTabSelected=\(isAccountTabSelected) authId=\(viewModel.currentUserAuthId?.uuidString.lowercased() ?? "nil")")
                        }
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
                            onVenueOwnerTools: nil,
                            statusMessage: viewModel.authErrorMessage,
                            attemptedLoginEmail: email
                        )
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                        .onAppear {
                            print("[SponsoredPlacementDebug] accountProfileBranch=signedOut profileIdentityCardRendered=false reason=noAuthSession isAccountTabSelected=\(isAccountTabSelected)")
                        }
                    }
                }

                if isBusinessAccountProfileContext && !viewModel.isVenueOwnerLoggedIn {
                    Section {
                        settingsBusinessProRow
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .listRowBackground(Color.clear)

                        settingsBusinessActiveVenueSelectionCard
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
                            .listRowBackground(Color.clear)

                        settingsSponsorInquiryCard
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                }

                if shouldShowInlineBusinessDashboard {
                    Section {
                        BusinessLocationVenuePicker(
                            viewModel: viewModel,
                            chrome: .dashboard,
                            onRequestAddNewLocation: { openAddLocationFromPicker() },
                            isHydrating: businessProfileVenueSelectorIsHydrating,
                            hydrationReason: businessProfileVenueHydrationState.reason,
                            onBlockedEarlyTap: logBusinessProfileHydrationBlockedEarlyTap
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)

                        settingsBusinessProRow
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)

                        settingsBusinessActiveVenueSelectionCard
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)

                        settingsSponsorInquiryCard
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)

                        settingsInlineBusinessDashboard
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                }

                if !shouldShowInlineBusinessDashboard && (viewModel.isVenueOwnerLoggedIn || !viewModel.isLoggedIn) {
                    Section {
                        settingsSectionCard {
                            let hasArchivedBusinessAccount = viewModel.hasArchivedBusinessAccountForOwner()
                            let hasActiveBusinessAccount = viewModel.hasBusinessAccountForOwner()

                            if viewModel.isVenueOwnerLoggedIn {
                                settingsBusinessProButton()

                                settingsRowDivider()

                                if viewModel.isVenueOwnerBusinessDataLoading && !settingsBusinessProfileHasCachedData {
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
                                        openBusinessVenueToolRoute(.manageVenue)
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
                                        onRequestAddNewLocation: { openAddLocationFromPicker() },
                                        isHydrating: businessProfileVenueSelectorIsHydrating,
                                        hydrationReason: businessProfileVenueHydrationState.reason,
                                        onBlockedEarlyTap: logBusinessProfileHydrationBlockedEarlyTap
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
                                        onRequestAddNewLocation: { openAddLocationFromPicker() },
                                        isHydrating: businessProfileVenueSelectorIsHydrating,
                                        hydrationReason: businessProfileVenueHydrationState.reason,
                                        onBlockedEarlyTap: logBusinessProfileHydrationBlockedEarlyTap
                                    )

                                    settingsRowDivider()

                                    settingsVenueReviewSections()

                                    settingsRowDivider()

                                    Button { openBusinessVenueToolRoute(.manageVenue) } label: {
                                        settingsRow(
                                            title: L10n.t("venue_details", languageCode: appLanguageRaw),
                                            subtitle: "Photos, amenities, and venue profile.",
                                            systemImage: "photo.on.rectangle.angled"
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    if settingsVenueClaimApprovedForStatusRow() {
                                        settingsRowDivider()

                                        Button { openBusinessVenueToolRoute(.manageGames) } label: {
                                            settingsRow(
                                                title: L10n.t("manage_games", languageCode: appLanguageRaw),
                                                subtitle: "Schedule or cancel games.",
                                                systemImage: "sportscourt"
                                            )
                                        }
                                        .buttonStyle(.plain)

                                        settingsRowDivider()

                                        Button { openBusinessVenueToolRoute(.statistics) } label: {
                                            settingsRow(
                                                title: L10n.t("statistics", languageCode: appLanguageRaw),
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
            .navigationTitle(L10n.t("profile", languageCode: appLanguageRaw))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showProfileSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(FGColor.accentGreen)
                            .frame(width: 34, height: 34)
                            .background {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                Circle()
                                    .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.82))
                            }
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.70), lineWidth: 0.75)
                            }
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 10, y: 4)
                            .onAppear {
#if DEBUG
                                print("[ProfileMenuDebug] settingsGearIconApplied=true")
#endif
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open settings")
                }
            }
            .onAppear {
                print("[SponsoredPlacementDebug] accountScreenAppeared=true isAccountTabSelected=\(isAccountTabSelected) isLoggedIn=\(viewModel.isLoggedIn) authId=\(viewModel.currentUserAuthId?.uuidString.lowercased() ?? "nil") businessContext=\(isBusinessAccountProfileContext)")
                if isAccountTabSelected {
                    UIPerformanceDiagnostics.signpost("Profile tab open", "source=onAppear")
                    logBusinessProfilePerformance(event: "profileTabAppeared source=onAppear")
                    Task {
                        await refreshSettingsBusinessProfile(trigger: "accountTabAppears", refreshBusinessData: true, debounce: true)
                    }
                }
                print("[FaceIDSettingsDebug] defaultPrivateChatFaceID=false")
                logSettingsBusinessVenueSectionVisibilityForFanAccount()
                Task {
                    await viewModel.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
                    if viewModel.canFanUsePickupGamesUI {
                        await viewModel.loadMyPickupGamesForSettings()
                    }
                }
            }
        }
        .onChange(of: isAccountTabSelected) { _, isSelected in
            print("[SponsoredPlacementDebug] accountTabSelectionChanged isSelected=\(isSelected) isLoggedIn=\(viewModel.isLoggedIn) authId=\(viewModel.currentUserAuthId?.uuidString.lowercased() ?? "nil") businessContext=\(isBusinessAccountProfileContext)")
            if isSelected {
                UIPerformanceDiagnostics.signpost("Profile tab open", "source=tabSelected")
                logBusinessProfilePerformance(event: "profileTabAppeared source=tabSelected")
                Task {
                    await refreshSettingsBusinessProfile(trigger: "accountTabAppears", refreshBusinessData: true, debounce: true)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, isAccountTabSelected else { return }
            Task {
                await refreshSettingsBusinessProfile(trigger: "foreground", refreshBusinessData: true, debounce: true)
            }
        }
        .onChange(of: settingsBusinessEntitlementSignature) { _, newValue in
            guard isAccountTabSelected, isBusinessAccountProfileContext else { return }
            guard !settingsBusinessProfileLastEntitlementSignature.isEmpty else { return }
            guard newValue != settingsBusinessProfileLastEntitlementSignature else { return }
            Task {
                await refreshSettingsBusinessProfile(trigger: "businessRowEntitlementChanged", refreshBusinessData: false, debounce: true)
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
                showVenueOwnerPasswordResetSheet = false
                showReportedCommentsSheet = false
                showAddLocationSheet = false
                showDeleteVenueOwnerSheet = false
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
                onRequestVenueProfileDashboard: { openBusinessVenueToolRoute(.manageVenue) }
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
        .sheet(isPresented: $showBusinessProSubscriptionSheet) {
            BusinessProSubscriptionView(businessStatus: settingsBusinessMembershipStatus)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
                .task {
                    await refreshSettingsBusinessProfile(
                        trigger: "businessProSheet",
                        refreshBusinessData: true
                    )
                }
        }
        .sheet(isPresented: $showBusinessUsageSheet) {
            BusinessUsageCenterView(
                status: settingsBusinessMembershipStatus,
                hostedGameCycleAudit: settingsBusinessHostedGameCycleAudit,
                isHostedGameCycleLoading: settingsBusinessHostedGameCycleAuditLoading,
                hostedGameCycleAuditUnavailable: settingsBusinessHostedGameCycleAuditUnavailable
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
                .task {
                    await refreshSettingsBusinessHostedGameCycleAudit()
                }
        }
        .sheet(isPresented: $showSponsorInquirySheet) {
            BusinessSponsorInquirySheet(
                viewModel: viewModel,
                businessId: viewModel.currentBusinessIdForAddLocation(),
                businessName: settingsSponsorInquiryBusinessName,
                ownerEmail: OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail),
                selectedVenue: settingsSponsorInquirySelectedVenueLine
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(isPresented: $showBusinessActiveVenueSelectionSheet) {
            BusinessActiveVenueSelectionSheet(
                viewModel: viewModel,
                businessId: settingsBusinessActiveVenueSelectionBusinessId,
                venueLimit: settingsBusinessActiveVenueSelectionLimit,
                venues: settingsBusinessActiveVenueSelectionRows,
                approvedDateText: { row in settingsApprovedVenueDateInfo(for: row).displayText },
                onSaved: {
                    activeVenueSelectionQuickActionNotice = nil
                    Task { await refreshSettingsBusinessProfile(trigger: "activeVenueSelectionSaved", refreshBusinessData: true, debounce: false) }
                }
            )
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
        .sheet(isPresented: $showVenueOwnerPasswordResetSheet) {
            SettingsVenueOwnerPasswordResetSheet(
                viewModel: viewModel,
                isPresented: $showVenueOwnerPasswordResetSheet
            )
        }
        .sheet(isPresented: $showDeleteAccountSheet) {
            SettingsAccountDeletionSheet(
                viewModel: viewModel,
                onCloseAfterSuccess: {
                    profileSettingsPath = NavigationPath()
                    showProfileSettingsSheet = false
                    showDeleteAccountSheet = false
                }
            )
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
                profileSettingsProGamesSection()
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
            .navigationTitle(L10n.t("settings", languageCode: appLanguageRaw))
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: ProfileSettingsRoute.self) { route in
                profileSettingsDestination(route)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("close", languageCode: appLanguageRaw)) { showProfileSettingsSheet = false }
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
            .navigationTitle(L10n.t("notifications", languageCode: appLanguageRaw))
            .navigationBarTitleDisplayMode(.inline)

        case .timeZone:
            Form { SettingsTimeZoneCard(viewModel: viewModel) }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
                }
                .navigationTitle(L10n.t("time_zone", languageCode: appLanguageRaw))
                .navigationBarTitleDisplayMode(.inline)

        case .language:
            FanGeoLanguageSelectionView(selectionRaw: $appLanguageRaw)

        case .appearance:
            FanGeoAppearanceSelectionView(selectionRaw: $appearancePreferenceRaw)
                .navigationTitle(L10n.t("appearance", languageCode: appLanguageRaw))
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

        case .resetPassword:
            ScrollView {
                SettingsFanPasswordResetCard(viewModel: viewModel, loginEmail: $email)
                    .padding(.horizontal, FGSpacing.lg)
                    .padding(.top, FGSpacing.lg)
            }
            .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .navigationTitle("Reset Password")
            .navigationBarTitleDisplayMode(.inline)

        case .venueResetPassword:
            ScrollView {
                SettingsVenuePasswordResetCard(viewModel: viewModel)
                    .padding(.horizontal, FGSpacing.lg)
                    .padding(.top, FGSpacing.lg)
            }
            .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .navigationTitle("Reset venue password")
            .navigationBarTitleDisplayMode(.inline)
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

    @MainActor
    private func presentBusinessDashboardQuickAction(
        source: String,
        keepsVenueOwnerRoute: Bool = false,
        _ present: () -> Void
    ) {
        if !keepsVenueOwnerRoute {
            venueOwnerDashboardSheet = nil
        }
        showAddLocationSheet = false
        showBusinessProSubscriptionSheet = false
        showBusinessUsageSheet = false
        showBusinessActiveVenueSelectionSheet = false
        showReportedCommentsSheet = false
        businessDashboardQuickActionNotice = nil
        present()
    }

    private var settingsBusinessProRow: some View {
        let isPro = settingsBusinessMembershipStatus?.computedIsPro == true

        return settingsBusinessEntitlementCard(isPro: isPro) {
            settingsBusinessProButton(isProOverride: isPro)
        }
        .onAppear {
            logBusinessProVisibilityInBusinessSettings(rowRendered: true)
            logBusinessEntitlementStyleDebug(computedIsPro: isPro, appliedStyle: isPro ? "premiumGold" : "regularNeutral")
        }
        .onChange(of: isPro) { _, newValue in
            logBusinessEntitlementStyleDebug(computedIsPro: newValue, appliedStyle: newValue ? "premiumGold" : "regularNeutral")
        }
        .animation(.easeInOut(duration: 0.24), value: isPro)
    }

    private func settingsBusinessProButton(
        presentingFromProfileSettings: Bool = false,
        isProOverride: Bool? = nil
    ) -> some View {
        let isPro = isProOverride ?? (settingsBusinessMembershipStatus?.computedIsPro == true)

        return Button {
            logBusinessProVisibilityInBusinessSettings(rowRendered: true)
            if presentingFromProfileSettings {
                presentFromProfileSettings {
                    presentBusinessDashboardQuickAction(source: "businessPro") {
                        showBusinessProSubscriptionSheet = true
                    }
                }
            } else {
                presentBusinessDashboardQuickAction(source: "businessPro") {
                    showBusinessProSubscriptionSheet = true
                }
            }
        } label: {
            settingsRow(
                title: settingsBusinessMembershipStatus?.businessPlanDisplayTitle ?? (isPro ? "Business Pro active" : "Business Regular"),
                subtitle: settingsBusinessProRowSubtitle,
                systemImage: isPro ? "crown.fill" : "lock.shield.fill",
                tint: isPro ? SettingsPremiumChrome.proGold(colorScheme) : FGColor.accentGreen
            ) {
                if isPro {
                    settingsBusinessProBadge()
                }
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            logBusinessProVisibilityInBusinessSettings(rowRendered: true)
        }
    }

    @ViewBuilder
    private func settingsBusinessEntitlementCard<Content: View>(
        isPro: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if isPro {
            SettingsBusinessProEntitlementCardContainer(content: content)
        } else {
            settingsSectionCard(content: content)
        }
    }

    private struct SettingsBusinessProEntitlementCardContainer<Content: View>: View {
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
                                    SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.24 : 0.18),
                                    SettingsPremiumChrome.proGoldDeep(colorScheme).opacity(colorScheme == .dark ? 0.12 : 0.08),
                                    SettingsPremiumChrome.cardHighlight(colorScheme)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .strokeBorder(SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.52 : 0.42), lineWidth: 1)
            }
            .shadow(color: SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.14), radius: 18, y: 8)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 12, y: 6)
        }
    }

    private func settingsBusinessProBadge() -> some View {
        Text("PRO")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(SettingsPremiumChrome.proBadgeText(colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                LinearGradient(
                    colors: [
                        SettingsPremiumChrome.proGold(colorScheme),
                        SettingsPremiumChrome.proGoldDeep(colorScheme)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.20 : 0.46), lineWidth: 0.75)
            }
            .shadow(color: SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.16 : 0.12), radius: 6, y: 2)
    }

    private func logBusinessProVisibilityInBusinessSettings(rowRendered: Bool) {
#if DEBUG
        print("[BusinessProVisibilityDebug] rowRenderedInBusinessSettings=\(rowRendered)")
#endif
    }

    private func logBusinessEntitlementStyleDebug(computedIsPro: Bool, appliedStyle: String) {
#if DEBUG
        print("[BusinessEntitlementStyleDebug] computedIsPro=\(computedIsPro) appliedStyle=\(appliedStyle)")
#endif
    }

    @ViewBuilder
    private var settingsBusinessActiveVenueSelectionCard: some View {
        if settingsShouldShowBusinessActiveVenueSelection {
            Button {
                showBusinessActiveVenueSelectionSheet = true
            } label: {
                settingsBusinessActiveVenueSelectionCardBody
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsBusinessActiveVenueSelectionCardBody: some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.12))
                Image(systemName: "checklist.checked")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(SettingsPremiumChrome.proGold(colorScheme))
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 4) {
                Text("Choose active venues")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                Text("Pick which \(settingsBusinessActiveVenueSelectionLimit) approved venues stay visible and can host games on Regular.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text("1 opportunity remaining")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.proGold(colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 12)
        .background(SettingsPremiumChrome.cardFill(colorScheme), in: RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .strokeBorder(SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.30 : 0.22), lineWidth: 0.75)
        }
        .contentShape(RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous))
    }

    private var settingsShouldShowBusinessActiveVenueSelection: Bool {
        guard let business = settingsBusinessActiveVenueSelectionBusiness else {
#if DEBUG
            print("[BusinessActiveVenueSelectionDebug] ctaEligibility businessId=nil computedIsPro=unknown approvedCount=0 activeCount=0 lockedCount=0 venueLimit=\(settingsBusinessActiveVenueSelectionLimit) freeActiveVenuesSelectedAt=nil shouldShowCTA=false")
#endif
            return false
        }
        let status = settingsBusinessMembershipStatus
        let rows = settingsBusinessActiveVenueSelectionRows(for: business)
        let approvedCount = rows.count
        let activeCount = rows.filter { MapViewModel.venueIsActiveForBusinessLimit($0) }.compactMap(\.id).count
        let lockedCount = rows.filter { MapViewModel.venueIsPlanLocked($0) }.compactMap(\.id).count
        let venueLimit = settingsBusinessActiveVenueSelectionLimit
        let selectedAt = settingsNormalizedFreeActiveVenuesSelectedAt(for: business)
        let computedIsPro = status?.computedIsPro == true
        let shouldShow = !computedIsPro
            && approvedCount > venueLimit
            && selectedAt == nil
#if DEBUG
        print("[BusinessActiveVenueSelectionDebug] ctaEligibility businessId=\(business.id.uuidString.lowercased()) computedIsPro=\(computedIsPro) approvedCount=\(approvedCount) activeCount=\(activeCount) lockedCount=\(lockedCount) venueLimit=\(venueLimit) freeActiveVenuesSelectedAt=\(selectedAt ?? "nil") shouldShowCTA=\(shouldShow)")
#endif
        return shouldShow
    }

    private var settingsBusinessActiveVenueSelectionBusiness: BusinessRow? {
        if let businessId = viewModel.currentBusinessIdForAddLocation(),
           let business = viewModel.ownedBusinesses.first(where: { $0.id == businessId }) {
            return business
        }
        return viewModel.ownedBusinesses.first
    }

    private var settingsBusinessActiveVenueSelectionBusinessId: UUID {
        settingsBusinessActiveVenueSelectionBusiness?.id
            ?? viewModel.currentBusinessIdForAddLocation()
            ?? UUID()
    }

    private var settingsBusinessActiveVenueSelectionLimit: Int {
        max(1, settingsBusinessMembershipStatus?.venueLimit ?? BusinessMembershipPolicy.freeVenueListingLimit)
    }

    private var settingsBusinessActiveVenueSelectionRows: [VenueProfileRow] {
        guard let business = settingsBusinessActiveVenueSelectionBusiness else { return [] }
        return settingsBusinessActiveVenueSelectionRows(for: business)
    }

    private func settingsBusinessActiveVenueSelectionRows(for business: BusinessRow) -> [VenueProfileRow] {
        var seenVenueIDs = Set<UUID>()
        return viewModel.managedVenuesForOwner()
            .compactMap { row -> VenueProfileRow? in
                guard let id = row.id, seenVenueIDs.insert(id).inserted else { return nil }
                guard MapViewModel.venueIsOwnerVisibleManagedStatus(row) else { return nil }
                if row.business_id == business.id { return row }
                if let metadata = viewModel.approvedVenueClaimMetadataByVenueID[id] {
                    if metadata.businessId == business.id { return row }
                    let metadataOwner = OwnerBusinessEmail.normalized(metadata.ownerEmail ?? "")
                    let businessOwner = OwnerBusinessEmail.normalized(business.owner_email ?? "")
                    if metadata.businessId == nil,
                       !metadataOwner.isEmpty,
                       metadataOwner == businessOwner {
                        return row
                    }
                }
                if row.business_id == nil {
                    let rowOwner = OwnerBusinessEmail.normalized(row.owner_email ?? "")
                    let businessOwner = OwnerBusinessEmail.normalized(business.owner_email ?? "")
                    if !rowOwner.isEmpty, rowOwner == businessOwner { return row }
                    if viewModel.ownedBusinesses.count == 1 { return row }
                }
                return nil
            }
            .sorted {
                let lhsDate = settingsApprovedVenueDateInfo(for: $0).sortDate
                let rhsDate = settingsApprovedVenueDateInfo(for: $1).sortDate
                switch (lhsDate, rhsDate) {
                case let (left?, right?):
                    if left != right { return left > right }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                return ($0.venue_name ?? "").localizedCaseInsensitiveCompare($1.venue_name ?? "") == .orderedAscending
            }
    }

    private func settingsNormalizedFreeActiveVenuesSelectedAt(for business: BusinessRow) -> String? {
        let value = business.free_active_venues_selected_at?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty || value.lowercased() == "null" { return nil }
        return value
    }

    private var settingsCanOpenBusinessActiveVenueSelection: Bool {
        guard let status = settingsBusinessMembershipStatus,
              !status.computedIsPro,
              let business = settingsBusinessActiveVenueSelectionBusiness else {
            return false
        }
        return settingsBusinessActiveVenueSelectionRows(for: business).count > settingsBusinessActiveVenueSelectionLimit
            && settingsNormalizedFreeActiveVenuesSelectedAt(for: business) == nil
    }

    private var settingsActiveVenueSelectionQuickActionSubtitle: String? {
        if settingsBusinessMembershipStatus?.computedIsPro == true {
            return "All active"
        }
        if settingsCanOpenBusinessActiveVenueSelection {
            return "Choose \(settingsBusinessActiveVenueSelectionLimit)"
        }
        if let business = settingsBusinessActiveVenueSelectionBusiness,
           settingsNormalizedFreeActiveVenuesSelectedAt(for: business) != nil {
            return "Selection used"
        }
        return "Within limit"
    }

    private var settingsActiveVenueSelectionQuickActionFootnote: String? {
        guard settingsBusinessMembershipStatus?.computedIsPro != true else { return nil }
        return "Regular businesses can choose active venues once after moving from Pro to Regular."
    }

    private func handleActiveVenueSelectionQuickAction() {
        if settingsCanOpenBusinessActiveVenueSelection {
            activeVenueSelectionQuickActionNotice = nil
            presentBusinessDashboardQuickAction(source: "activeVenueSelectionQuickAction") {
                showBusinessActiveVenueSelectionSheet = true
            }
            return
        }

        if settingsBusinessMembershipStatus?.computedIsPro == true {
            activeVenueSelectionQuickActionNotice = "All approved venues are active on Business Pro."
            return
        }

        if let business = settingsBusinessActiveVenueSelectionBusiness,
           settingsNormalizedFreeActiveVenuesSelectedAt(for: business) != nil {
            activeVenueSelectionQuickActionNotice = "Your one-time active venue choice has already been saved. Contact FanGeo or upgrade to Pro to change it."
            return
        }

        activeVenueSelectionQuickActionNotice = "Active venue selection appears when a Regular business has more approved venues than its plan limit."
    }

    private var settingsSponsorInquiryCard: some View {
        Button {
            let businessId = viewModel.currentBusinessIdForAddLocation()
#if DEBUG
            print("[SponsorInquiryDebug] opened=true businessId=\(businessId?.uuidString.lowercased() ?? "nil")")
#endif
            showSponsorInquirySheet = true
        } label: {
            HStack(alignment: .center, spacing: FGSpacing.md) {
                ZStack {
                    Circle()
                        .fill(SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.20 : 0.13))
                    Circle()
                        .strokeBorder(SettingsPremiumChrome.proGold(colorScheme).opacity(0.26), lineWidth: 1)
                    Image(systemName: "megaphone.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(SettingsPremiumChrome.proGold(colorScheme))
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Advertise with FanGeo")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    Text("Reach more local fans and grow your venue.")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Learn About Sponsorships")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            LinearGradient(
                                colors: [
                                    SettingsPremiumChrome.proGold(colorScheme),
                                    Color(red: 0.62, green: 0.39, blue: 0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Capsule(style: .continuous)
                        )
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                    .frame(width: 14, height: 34, alignment: .center)
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, 12)
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
                                    SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.12 : 0.08),
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
                    .strokeBorder(SettingsPremiumChrome.proGold(colorScheme).opacity(colorScheme == .dark ? 0.28 : 0.20), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 12, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var settingsSponsorInquiryBusinessName: String {
        if let businessId = viewModel.currentBusinessIdForAddLocation(),
           let business = viewModel.ownedBusinesses.first(where: { $0.id == businessId }) {
            let name = business.display_name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        let ownedName = viewModel.ownedBusinesses.first?.display_name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ownedName.isEmpty { return ownedName }
        let venueName = settingsBusinessDashboardVenueName.trimmingCharacters(in: .whitespacesAndNewlines)
        return venueName.isEmpty ? "My business" : venueName
    }

    private var settingsSponsorInquirySelectedVenueLine: String {
        guard let venue = settingsBusinessDashboardSelectedVenue else {
            return "Not selected"
        }
        let name = venue.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let city = venue.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = venue.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = [city, state].filter { !$0.isEmpty }.joined(separator: ", ")
        if name.isEmpty { return location.isEmpty ? "Selected venue unavailable" : location }
        return location.isEmpty ? name : "\(name) • \(location)"
    }

    @ViewBuilder
    private func profileSettingsAccountSection() -> some View {
        if viewModel.isLoggedIn || viewModel.isVenueOwnerLoggedIn {
            Section {
                settingsSectionCard {
                    if viewModel.isLoggedIn {
                        if isBusinessAccountProfileContext {
                            settingsBusinessProButton(presentingFromProfileSettings: true)

                            settingsRowDivider()
                        }

                        Button {
                            profileSettingsPath.append(ProfileSettingsRoute.resetPassword)
                        } label: {
                            settingsRow(title: "Reset Password", subtitle: "Send a reset email.", systemImage: "key", showsChevron: true)
                        }
                        .buttonStyle(.plain)

                        if viewModel.isVenueOwnerLoggedIn {
                            settingsRowDivider()

                            Button {
                                profileSettingsPath.append(ProfileSettingsRoute.venueResetPassword)
                            } label: {
                                settingsRow(title: "Reset venue password", subtitle: "Send a venue owner reset email.", systemImage: "key", showsChevron: true)
                            }
                            .buttonStyle(.plain)
                        }
                    } else if viewModel.isVenueOwnerLoggedIn {
                        settingsBusinessProButton(presentingFromProfileSettings: true)

                        settingsRowDivider()

                        Button {
                            profileSettingsPath.append(ProfileSettingsRoute.venueResetPassword)
                        } label: {
                            settingsRow(title: "Reset venue password", subtitle: "Send a venue owner reset email.", systemImage: "key", showsChevron: true)
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
        if canShowPrivateChatFaceIDSetting || canShowLiveActivitySharing || canShowPrivacyAdChoices {
            Section {
                settingsSectionCard {
                    if canShowPrivateChatFaceIDSetting {
                        privateChatFaceIDSettingsRow
                    }

                    if canShowPrivateChatFaceIDSetting && (canShowLiveActivitySharing || canShowPrivacyAdChoices) {
                        settingsRowDivider()
                    }

                    if canShowLiveActivitySharing {
                        settingsToggleRow(
                            title: "Allow other fans to discover me",
                            subtitle: "Lets FanGeo suggest your profile to other fans with shared teams, venues, or games.",
                            systemImage: "person.crop.circle.badge.checkmark",
                            isOn: profileDiscoverabilityBinding,
                            isUpdating: viewModel.isUpdatingProfileDiscoverabilitySetting,
                            tint: FGColor.accentBlue
                        )

                        settingsRowDivider()

                        Button {
                            profileSettingsPath.append(ProfileSettingsRoute.liveActivitySharing)
                        } label: {
                            settingsRow(title: "Live Activity Sharing", subtitle: liveSharingModeSubtitle, systemImage: "person.2.wave.2.fill", showsChevron: true)
                        }
                        .buttonStyle(.plain)
                    }

                    if canShowLiveActivitySharing && canShowPrivacyAdChoices {
                        settingsRowDivider()
                    }

                    if canShowPrivacyAdChoices {
                        privacyAdChoicesSettingsRow
                    }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            } header: {
                settingsSectionHeader("Privacy & Security")
            }
        }
    }

    private var canShowPrivacyAdChoices: Bool {
        GoogleMobileAdsBootstrap.privacyOptionsRequired
    }

    private var privacyAdChoicesSettingsRow: some View {
        Button {
            Task {
                await GoogleMobileAdsBootstrap.presentPrivacyOptionsIfRequired()
            }
        } label: {
            settingsRow(
                title: "Privacy & Ad Choices",
                subtitle: "Manage ad consent choices.",
                systemImage: "hand.raised.fill",
                tint: FGColor.accentBlue,
                showsChevron: true
            )
        }
        .buttonStyle(.plain)
    }

    private var privateChatFaceIDSettingsRow: some View {
        settingsToggleRow(
            title: L10n.t("require_face_id_private_chat", languageCode: appLanguageRaw),
            subtitle: L10n.t("private_chat_face_id_description", languageCode: appLanguageRaw),
            systemImage: "faceid",
            isOn: privateChatFaceIDBinding,
            isUpdating: false,
            tint: FGColor.accentBlue
        )
        .onAppear {
            guard isBusinessAccountProfileContext else { return }
            print("[BusinessPrivacySettingsDebug] faceIDToggleVisible=true")
            print("[BusinessPrivacySettingsDebug] usingSharedFaceIDSetting=true")
        }
    }

    private func profileSettingsNotificationsSection() -> some View {
        Section {
            settingsSectionCard {
                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.notifications)
                } label: {
                    settingsRow(title: L10n.t("notifications", languageCode: appLanguageRaw), subtitle: notificationSettingsStore.notifyBeforeGame ? "On" : "Off", systemImage: "bell.badge", showsChevron: true)
                }
                .buttonStyle(.plain)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            settingsSectionHeader(L10n.t("notifications", languageCode: appLanguageRaw))
        }
    }

    private func profileSettingsExperienceSection() -> some View {
        Section {
            settingsSectionCard {
                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.timeZone)
                } label: {
                    settingsRow(title: L10n.t("time_zone", languageCode: appLanguageRaw), subtitle: viewModel.selectedTimeZone.rawValue, systemImage: "clock", showsChevron: true)
                }
                .buttonStyle(.plain)

                settingsRowDivider()

                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.language)
                } label: {
                    settingsRow(
                        title: L10n.t("language", languageCode: appLanguageRaw),
                        subtitle: selectedAppLanguage.nativeName,
                        systemImage: "globe.americas.fill",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .onAppear {
#if DEBUG
                    print("[LocalizationDebug] languageSettingVisible=true")
                    print("[LocalizationDebug] selectedLanguage=\(selectedAppLanguage.code)")
#endif
                }

                settingsRowDivider()

                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.appearance)
                } label: {
                    settingsRow(
                        title: L10n.t("appearance", languageCode: appLanguageRaw),
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

    private func profileSettingsProGamesSection() -> some View {
        Section {
            settingsSectionCard {
                settingsRow(
                    title: "Automatically follow Favorite Teams",
                    subtitle: "Show upcoming Pro Games involving your favorite teams in Going.",
                    systemImage: "star.circle.fill",
                    tint: FGColor.accentBlue,
                    showsChevron: false
                ) {
                    Toggle("Automatically follow games from my Favorite Teams", isOn: $proGamesAutoFollowFavoriteTeams)
                        .labelsHidden()
                }

                settingsRowDivider()

                proGamesFavoriteTeamWindowRow
                    .opacity(proGamesAutoFollowFavoriteTeams ? 1 : 0.48)
                    .disabled(!proGamesAutoFollowFavoriteTeams)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            settingsSectionHeader("Pro Games Preferences")
        }
    }

    private var proGamesFavoriteTeamWindowRow: some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FGColor.accentGreen)
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text("Favorite Team Game Window")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                Text("How far ahead Going should look for your teams.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Favorite Team Game Window", selection: $proGamesFavoriteTeamWindowDays) {
                ForEach(ProGamesFavoriteTeamAutoFollowPreference.Window.allCases) { window in
                    Text(window.title).tag(window.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
    }

    private func profileSettingsHelpSafetySection() -> some View {
        Section {
            settingsSectionCard {
                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.support)
                } label: {
                    settingsRow(
                        title: L10n.t("support", languageCode: appLanguageRaw),
                        subtitle: "Message the FanGeo team.",
                        systemImage: "envelope.open.fill",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)

                settingsRowDivider()

                Button {
                    openFanGeoInstagram()
                } label: {
                    settingsRow(
                        title: "Follow FanGeo on Instagram",
                        subtitle: "@fangeosports",
                        assetImage: "FanGeoInstagramLogo",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Follow FanGeo on Instagram")
                .accessibilityValue("@fangeosports")
                .accessibilityHint("Opens the FanGeo Sports Instagram profile.")

                settingsRowDivider()

                Button {
                    openFanGeoFacebook()
                } label: {
                    settingsRow(
                        title: "Follow FanGeo on Facebook",
                        subtitle: "FanGeo Sports",
                        assetImage: "FanGeoFacebookLogo",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Follow FanGeo on Facebook")
                .accessibilityValue("FanGeo Sports")
                .accessibilityHint("Opens the FanGeo Sports Facebook page.")

                settingsRowDivider()

                Button {
                    profileSettingsPath.append(ProfileSettingsRoute.communityGuidelines)
                } label: {
                    settingsRow(
                        title: L10n.t("community_guidelines", languageCode: appLanguageRaw),
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

    private func openFanGeoInstagram() {
        guard let url = URL(string: "https://www.instagram.com/fangeosports") else {
            return
        }
        UIApplication.shared.open(url)
    }

    private func openFanGeoFacebook() {
        guard let url = URL(string: "https://www.facebook.com/profile.php?id=61590196064767") else {
            return
        }
        UIApplication.shared.open(url)
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
    private func settingsRow(title: String, subtitle: String?, assetImage: String, showsChevron: Bool = true) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(assetImage)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
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

    private var shouldShowInlineBusinessDashboard: Bool {
        viewModel.isVenueOwnerLoggedIn
            && viewModel.hasBusinessAccountForOwner()
            && !viewModel.hasArchivedBusinessAccountForOwner()
            && !viewModel.managedVenuesForOwner().isEmpty
    }

    private var businessProfileVenueHydrationState: BusinessProfileVenueHydrationState {
        let managedVenues = viewModel.managedVenuesForOwner()
        let managedCount = managedVenues.count
        let selectedVenueId = viewModel.ownerVenueDatabaseId

        if viewModel.isVenueOwnerBusinessDataLoading && !settingsBusinessProfileHasCachedData {
            return BusinessProfileVenueHydrationState(isReady: false, reason: "businessDataLoading", selectedVenueId: selectedVenueId, managedCount: managedCount)
        }
        if settingsBusinessProfileHydrationInFlight && !settingsBusinessProfileHasCachedData {
            return BusinessProfileVenueHydrationState(isReady: false, reason: "businessProfileHydrationInFlight", selectedVenueId: selectedVenueId, managedCount: managedCount)
        }
        if settingsBusinessMembershipStatus == nil {
            return BusinessProfileVenueHydrationState(isReady: false, reason: "entitlementLoading", selectedVenueId: selectedVenueId, managedCount: managedCount)
        }
        guard !managedVenues.isEmpty else {
            return BusinessProfileVenueHydrationState(isReady: false, reason: "managedVenuesLoading", selectedVenueId: selectedVenueId, managedCount: managedCount)
        }
        guard let selectedVenueId else {
            return BusinessProfileVenueHydrationState(isReady: false, reason: "selectedVenueNil", selectedVenueId: nil, managedCount: managedCount)
        }
        guard let selectedVenue = managedVenues.first(where: { $0.id == selectedVenueId }) else {
            return BusinessProfileVenueHydrationState(isReady: false, reason: "selectedVenueStale", selectedVenueId: selectedVenueId, managedCount: managedCount)
        }
        guard MapViewModel.venueIsActiveForBusinessLimit(selectedVenue) else {
            return BusinessProfileVenueHydrationState(isReady: false, reason: "selectedVenueInactive", selectedVenueId: selectedVenueId, managedCount: managedCount)
        }
        return BusinessProfileVenueHydrationState(isReady: true, reason: "ready", selectedVenueId: selectedVenueId, managedCount: managedCount)
    }

    private var businessProfileVenueHydrationLogToken: String {
        let state = businessProfileVenueHydrationState
        return "\(state.isReady)|\(state.reason)|\(state.selectedVenueId?.uuidString.lowercased() ?? "nil")|\(state.managedCount)"
    }

    private var businessProfileVenueSelectorIsHydrating: Bool {
        let state = businessProfileVenueHydrationState
        return !state.isReady && state.reason != "managedVenuesLoading"
    }

    private func logBusinessProfileHydrationState() {
#if DEBUG
        let state = businessProfileVenueHydrationState
        if state.isReady {
            print("[BusinessProfileHydrationDebug] ready=true selectedVenueId=\(state.selectedVenueId?.uuidString.lowercased() ?? "nil") managedCount=\(state.managedCount)")
        } else {
            print("[BusinessProfileHydrationDebug] ready=false reason=\(state.reason)")
        }
#endif
    }

    private func logBusinessProfileHydrationBlockedEarlyTap(action: String, reason: String) {
#if DEBUG
        print("[BusinessProfileHydrationDebug] blockedEarlyTap action=\(action) reason=\(reason)")
#endif
    }

    @MainActor
    private func businessProfileVenueHydrationAllowsAction(_ action: String) -> Bool {
        let state = businessProfileVenueHydrationState
        guard state.isReady else {
            logBusinessProfileHydrationBlockedEarlyTap(action: action, reason: state.reason)
            return false
        }
        return true
    }

    private var settingsInlineBusinessDashboard: some View {
        BusinessVenueDashboardOverviewView(
            data: settingsBusinessDashboardData,
            businessId: viewModel.currentBusinessIdForAddLocation(),
            businessUsageStatus: settingsBusinessMembershipStatus,
            activeVenueSelectionSubtitle: settingsActiveVenueSelectionQuickActionSubtitle,
            activeVenueSelectionNotice: businessDashboardQuickActionNotice ?? activeVenueSelectionQuickActionNotice,
            activeVenueSelectionFootnote: settingsActiveVenueSelectionQuickActionFootnote,
            onNotifications: {
                presentBusinessDashboardQuickAction(source: "notifications") {
                    showReportedCommentsSheet = true
                }
            },
            onMenu: {
                openBusinessVenueToolRoute(.manageVenue)
            },
            onAddGame: {
                openBusinessVenueToolRoute(.manageVenue)
            },
            onAddVenue: {
                openAddLocationFromBusinessDashboard()
            },
            onTonightGames: {
                openBusinessVenueToolRoute(.manageGames)
            },
            onPredictions: {
                openBusinessVenueToolRoute(.statistics)
            },
            onAnalytics: {
                openBusinessVenueToolRoute(.statistics)
            },
            onUsage: {
                presentBusinessDashboardQuickAction(source: "usageQuickAction") {
                    showBusinessUsageSheet = true
                }
            },
            onActiveVenueSelection: {
                handleActiveVenueSelectionQuickAction()
            },
            onCommentsReports: {
                presentBusinessDashboardQuickAction(source: "commentsReportsQuickAction") {
                    showReportedCommentsSheet = true
                }
            },
            onViewAllGames: {
                openBusinessVenueToolRoute(.manageGames)
            },
            onRefreshVenues: {
                Task { await refreshSettingsManagedVenuesSection() }
            },
            onRefreshPendingVenue: { venue in
                await refreshPendingVenueClaimFromDashboard(venue)
            },
            onResendPendingVenue: { venue in
                await resendPendingVenueClaimFromDashboard(venue)
            },
            onCancelPendingVenue: { venue in
                await viewModel.cancelBusinessVenueClaim(claimId: venue.id)
            },
            showsManagedVenuesSection: true,
            isStatisticsProActive: settingsBusinessStatisticsAccessGranted,
            isAddVenueAllowed: settingsBusinessCanCreateVenueFromServer,
            isHostedGameAllowed: settingsBusinessCanHostGameFromServer,
            isVenueHydrationReady: businessProfileVenueHydrationState.isReady,
            venueHydrationReason: businessProfileVenueHydrationState.reason
        )
        .onAppear {
            logBusinessProfileHydrationState()
            logSettingsInlineBusinessDashboardDebug()
        }
        .onChange(of: businessProfileVenueHydrationLogToken) { _, _ in
            logBusinessProfileHydrationState()
        }
        .task(id: settingsInlineBusinessDashboardLoadToken) {
            await refreshSettingsInlineBusinessDashboard()
        }
    }

    private var settingsInlineBusinessDashboardLoadToken: String {
        if let venueID = viewModel.ownerVenueDatabaseId {
            return venueID.uuidString
        }
        return OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
    }

    private var settingsBusinessStatisticsAccessGranted: Bool {
        settingsBusinessMembershipStatus?.statisticsAccessGranted == true
    }

    private var settingsBusinessCanCreateVenueFromServer: Bool {
        guard let status = settingsBusinessMembershipStatus else { return true }
        return status.canAddVenue
    }

    private var settingsBusinessCanHostGameFromServer: Bool {
        guard let status = settingsBusinessMembershipStatus else { return true }
        return status.canAddHostedGame
    }

    private var settingsBusinessProRowSubtitle: String {
        guard let status = settingsBusinessMembershipStatus else {
            return "Checking server-controlled access..."
        }
        guard status.computedIsPro else {
            return "\(status.venueLimit) active venues • \(status.monthlyHostLimit) hosted games/month"
        }
        if let promoText = status.businessProPromoEndDateText {
            return promoText
        }
        if status.isBusinessSubscriptionPro {
            return [
                "Subscription Pro",
                status.businessProSubscriptionExpiryText
            ]
            .compactMap { $0 }
            .joined(separator: " • ")
        }
        return "Unlimited venues • Unlimited hosting"
    }

    private func refreshSettingsBusinessHostedGameCycleAudit() async {
        guard let businessId = settingsBusinessMembershipStatus?.businessId ?? viewModel.currentBusinessIdForAddLocation() else {
            settingsBusinessHostedGameCycleAudit = nil
            settingsBusinessHostedGameCycleAuditLoading = false
            return
        }

        settingsBusinessHostedGameCycleAudit = nil
        settingsBusinessHostedGameCycleAuditUnavailable = false
        settingsBusinessHostedGameCycleAuditLoading = true
        do {
            let audit = try await viewModel.loadBusinessHostedGamesThisCycle(businessId: businessId)
            settingsBusinessHostedGameCycleAudit = audit
        } catch {
            settingsBusinessHostedGameCycleAudit = nil
            settingsBusinessHostedGameCycleAuditUnavailable = true
        }
        settingsBusinessHostedGameCycleAuditLoading = false
    }

    private static let settingsApprovedVenueDateDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    private var settingsBusinessDashboardData: BusinessVenueDashboardData {
        BusinessVenueDashboardData(
            venueName: settingsBusinessDashboardVenueName,
            locationLine: settingsBusinessDashboardLocationLine,
            isVerified: viewModel.venueCoreIdentityLockedForSelectedVenue() || viewModel.venueIsApproved,
            managedVenueCount: viewModel.managedVenuesForOwner().count,
            venuePhotoURL: settingsBusinessDashboardVenuePhotoURL,
            venuePhotoThumbnailURL: settingsBusinessDashboardVenuePhotoThumbnailURL,
            fansGoing: settingsBusinessDashboardFansGoing,
            activeChats: settingsBusinessDashboardActiveChats,
            predictions: settingsBusinessDashboardPredictions,
            atmosphereRating: settingsBusinessDashboardAtmosphereRating,
            gameSectionContext: settingsBusinessDashboardGameSectionContext,
            games: settingsBusinessDashboardGameItems,
            approvedVenues: settingsBusinessDashboardApprovedVenueItems,
            pendingVenues: settingsBusinessDashboardPendingVenueItems
        )
    }

    private var settingsBusinessDashboardSelectedVenue: VenueProfileRow? {
        guard businessProfileVenueHydrationState.isReady else { return nil }
        let managedVenues = viewModel.managedVenuesForOwner()
        if let venueID = viewModel.ownerVenueDatabaseId,
           let selected = managedVenues.first(where: { $0.id == venueID }) {
            return selected
        }
        return nil
    }

    private var settingsBusinessDashboardApprovedVenueItems: [BusinessVenueDashboardApprovedVenueItem] {
        let pendingVenueIDs = Set(viewModel.pendingVenueClaimsForSettings.compactMap(\.venue_id))
        let rows = viewModel.managedVenuesForOwner()
            .compactMap { row -> (item: BusinessVenueDashboardApprovedVenueItem, approvedAt: Date?, approvedAtDebug: String)? in
                guard let id = row.id, !pendingVenueIDs.contains(id) else { return nil }
                let name = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let city = row.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let state = row.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let approvedDate = settingsApprovedVenueDateInfo(for: row)
                return (
                    BusinessVenueDashboardApprovedVenueItem(
                        id: id,
                        name: name.isEmpty ? "Approved venue" : name,
                        locationLine: [city, state].filter { !$0.isEmpty }.joined(separator: ", "),
                        approvedDateText: approvedDate.displayText,
                        venuePhotoURL: row.cover_photo_url?.trimmingCharacters(in: .whitespacesAndNewlines),
                        venuePhotoThumbnailURL: row.cover_photo_thumbnail_url?.trimmingCharacters(in: .whitespacesAndNewlines),
                        isPlanLocked: MapViewModel.venueIsPlanLocked(row)
                    ),
                    approvedDate.sortDate,
                    approvedDate.debugRaw
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.approvedAt, rhs.approvedAt) {
                case let (left?, right?):
                    if left != right { return left > right }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                return lhs.item.name.localizedCaseInsensitiveCompare(rhs.item.name) == .orderedAscending
            }

        return rows.enumerated().map { index, row in
#if DEBUG
            print("[BusinessApprovedVenuesDebug] venueId=\(row.item.id.uuidString.lowercased()) venueName=\(row.item.name) approvedAt=\(row.approvedAtDebug) sortIndex=\(index)")
#endif
            return row.item
        }
    }

    private func settingsApprovedVenueDateInfo(for row: VenueProfileRow) -> (displayText: String, sortDate: Date?, debugRaw: String) {
        let claimApprovedRaw = row.id.flatMap { venueId -> String? in
            guard let metadata = viewModel.approvedVenueClaimMetadataByVenueID[venueId] else { return nil }
            return metadata.approvedAtRaw ?? metadata.createdAtRaw
        }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !claimApprovedRaw.isEmpty {
            return settingsApprovedVenueDateInfo(raw: claimApprovedRaw)
        }

        let venueCreatedRaw = row.created_at?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !venueCreatedRaw.isEmpty {
            return settingsApprovedVenueDateInfo(raw: venueCreatedRaw)
        }

        return ("Approved date unavailable", nil, "nil")
    }

    private func settingsApprovedVenueDateInfo(raw: String) -> (displayText: String, sortDate: Date?, debugRaw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date = SupabaseTimestampParsing.parseTimestamptz(trimmed) ?? settingsParseSupabaseTimestamptz(trimmed) else {
            return ("Approved \(String(trimmed.prefix(10)))", nil, trimmed)
        }
        return (
            "Approved \(Self.settingsApprovedVenueDateDisplayFormatter.string(from: date))",
            date,
            trimmed
        )
    }

    private var settingsBusinessDashboardPendingVenueItems: [BusinessVenueDashboardPendingVenueItem] {
        viewModel.pendingVenueClaimsForSettings
            .map { claim in
                BusinessVenueDashboardPendingVenueItem(
                    id: claim.id,
                    name: settingsPendingClaimTitle(claim),
                    submittedDateText: settingsPendingClaimSubmittedDateText(claim)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var settingsBusinessDashboardVenueName: String {
        guard businessProfileVenueHydrationState.isReady else {
            return "Loading venues..."
        }
        let selectedName = settingsBusinessDashboardSelectedVenue?.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selectedName.isEmpty { return selectedName }

        let ownerName = viewModel.ownerVenueName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ownerName.isEmpty ? "Your venue" : ownerName
    }

    private var settingsBusinessDashboardLocationLine: String {
        let selectedCity = settingsBusinessDashboardSelectedVenue?.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedState = settingsBusinessDashboardSelectedVenue?.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ownerCity = viewModel.ownerVenueCity.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerState = viewModel.ownerVenueState.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = selectedCity.isEmpty ? ownerCity : selectedCity
        let state = selectedState.isEmpty ? ownerState : selectedState
        let parts = [city, state].filter { !$0.isEmpty }
        return parts.isEmpty ? "Venue dashboard" : parts.joined(separator: ", ")
    }

    private var settingsBusinessDashboardVenuePhotoURL: String? {
        let selected = settingsBusinessDashboardSelectedVenue?.cover_photo_url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selected.isEmpty { return selected }

        let owner = viewModel.venueCoverPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty ? nil : owner
    }

    private var settingsBusinessDashboardVenuePhotoThumbnailURL: String? {
        let selected = settingsBusinessDashboardSelectedVenue?.cover_photo_thumbnail_url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selected.isEmpty { return selected }

        let owner = viewModel.venueCoverPhotoThumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty ? nil : owner
    }

    private var settingsBusinessDashboardEventIDs: [UUID] {
        inlineBusinessDashboardGames.compactMap(\.id)
    }

    private var settingsBusinessDashboardFansGoing: Int {
        settingsBusinessDashboardEventIDs.reduce(0) { $0 + viewModel.interestCountForVenueEvent($1) }
    }

    private var settingsBusinessDashboardActiveChats: Int {
        settingsBusinessDashboardEventIDs.reduce(0) { total, id in
            total + (viewModel.fanUpdatesStore.venueEventComments[id]?.count ?? 0)
        }
    }

    private var settingsBusinessDashboardPredictions: Int {
        settingsBusinessDashboardEventIDs.reduce(0) { total, id in
            total + (viewModel.venueEventPredictionSummaries[id]?.totalCount ?? 0)
        }
    }

    private var settingsBusinessDashboardTodayGamesCount: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return inlineBusinessDashboardGames.reduce(0) { total, row in
            guard let day = settingsBusinessDashboardGameDay(row),
                  calendar.isDate(day, inSameDayAs: today) else {
                return total
            }
            return total + 1
        }
    }

    private var settingsBusinessDashboardAtmosphereRating: String {
        guard let venueID = viewModel.ownerVenueDatabaseId,
              let bar = viewModel.bars.first(where: { $0.id == venueID }),
              viewModel.reviewCountDisplay(for: bar) > 0,
              let rating = viewModel.mergedDisplayRating(for: bar) else {
            return "New"
        }
        return String(format: "%.1f", rating)
    }

    private var settingsBusinessDashboardGameSectionContext: BusinessVenueDashboardGameSectionContext {
        BusinessVenueDashboardGameSectionResolver.resolve(
            gameDates: settingsBusinessDashboardUpcomingRows.map(\.start),
            calendar: Calendar.current
        )
    }

    private var settingsBusinessDashboardUpcomingRows: [(row: VenueEventRow, start: Date)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return inlineBusinessDashboardGames.compactMap { row in
            guard let start = settingsBusinessDashboardGameStartDate(row),
                  calendar.startOfDay(for: start) >= today else {
                return nil
            }
            return (row, start)
        }
        .sorted { $0.start < $1.start }
    }

    private var settingsBusinessDashboardGameItems: [BusinessVenueDashboardGameItem] {
        let sourceRows = Array(settingsBusinessDashboardUpcomingRows.prefix(3).map(\.row))

        return sourceRows.compactMap { row in
            guard let id = row.id else { return nil }
            let score = viewModel.venueOwnerEngagementScore(venueEventID: id)
            let energy = settingsBusinessDashboardEnergy(score: score)
            return BusinessVenueDashboardGameItem(
                id: id,
                title: settingsBusinessDashboardGameTitle(row),
                subtitle: settingsBusinessDashboardGameSubtitle(row),
                timeText: settingsBusinessDashboardGameTimeText(row),
                sportIconName: viewModel.iconForSport(row.sport ?? ""),
                goingCount: viewModel.interestCountForVenueEvent(id),
                energyLabel: energy.label,
                energyTint: energy.tint
            )
        }
    }

    private func settingsBusinessDashboardGameTitle(_ row: VenueEventRow) -> String {
        let title = VenueGameCompetitorDisplay.publicTitle(
            eventTitle: row.event_title,
            sport: row.sport,
            homeTeam: row.home_team,
            awayTeam: row.away_team
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Game" : title
    }

    private func settingsBusinessDashboardGameSubtitle(_ row: VenueEventRow) -> String {
        let league = row.external_league?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let league, !league.isEmpty { return league }

        let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return sport.isEmpty ? "Venue game" : sport
    }

    private func settingsBusinessDashboardGameTimeText(_ row: VenueEventRow) -> String {
        BusinessVenueDashboardGameDateTimeFormatter.compactLabel(
            startDate: FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at),
            eventDateRaw: row.event_date,
            eventTimeRaw: row.event_time,
            timeZoneOption: viewModel.selectedTimeZone,
            calendar: Calendar.current
        )
    }

    private func settingsBusinessDashboardGameStartDate(_ row: VenueEventRow) -> Date? {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at) {
            return start
        }
        return settingsBusinessDashboardGameDay(row)
    }

    private func settingsBusinessDashboardGameDay(_ row: VenueEventRow) -> Date? {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at) {
            return start
        }

        let raw = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.date(from: raw)
    }

    private func settingsBusinessDashboardEnergy(score: Int) -> (label: String, tint: Color) {
        if score >= 30 { return ("High energy", FGColor.accentGreen) }
        if score >= 8 { return ("Building", FGColor.accentYellow) }
        return (L10n.t("normal", languageCode: appLanguageRaw), FGColor.accentBlue)
    }

    private func refreshSettingsInlineBusinessDashboard() async {
        guard shouldShowInlineBusinessDashboard else { return }
        let rows = await viewModel.loadMyVenueScheduledGames()
        let ids = rows.compactMap(\.id)

        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    await viewModel.loadComments(for: id)
                    await viewModel.loadVibes(for: id)
                }
            }
        }

        await viewModel.loadVenueEventPredictionSummaries(eventIDs: ids)
        await MainActor.run {
            inlineBusinessDashboardGames = rows
            logSettingsInlineBusinessDashboardDebug()
        }
    }

    private func refreshSettingsBusinessProfile(
        trigger: String,
        refreshBusinessData: Bool,
        debounce: Bool = false
    ) async {
        guard isBusinessAccountProfileContext || viewModel.isVenueOwnerLoggedIn else { return }
        let startedAt = Date()
        let cachedDataAvailableAtStart = settingsBusinessProfileHasCachedData
        let passiveRefresh = isPassiveSettingsBusinessProfileRefresh(trigger: trigger)
        if passiveRefresh {
            if settingsBusinessProfileHydrationInFlight {
                logBusinessProfilePerformance(
                    event: "refreshSkipped trigger=\(trigger) reason=inFlight cachedDataAvailable=\(cachedDataAvailableAtStart)"
                )
                return
            }
            if let lastRefresh = settingsBusinessProfileLastPassiveRefreshAt,
               startedAt.timeIntervalSince(lastRefresh) < settingsBusinessProfilePassiveRefreshTTL {
                let ageMs = Int(startedAt.timeIntervalSince(lastRefresh) * 1000)
                logBusinessProfilePerformance(
                    event: "refreshSkipped trigger=\(trigger) reason=ttl ageMs=\(ageMs) cachedDataAvailable=\(cachedDataAvailableAtStart)"
                )
                return
            }
            settingsBusinessProfileLastPassiveRefreshAt = startedAt
        }
        let requestId = nextSettingsBusinessProfileRefreshRequestId()
        settingsBusinessProfileHydrationInFlight = true
        logBusinessProfilePerformance(
            event: "refreshStarted trigger=\(trigger) requestId=\(requestId) cachedDataAvailable=\(cachedDataAvailableAtStart) refreshBusinessData=\(refreshBusinessData)"
        )
        logBusinessProfileHydrationState()
        defer {
            Task { @MainActor in
                guard requestId == settingsBusinessProfileLatestRequestId else { return }
                settingsBusinessProfileHydrationInFlight = false
                let finishedAt = Date()
                let durationMs = Int(finishedAt.timeIntervalSince(startedAt) * 1000)
                let didUIClearCachedState = cachedDataAvailableAtStart && !settingsBusinessProfileHasCachedData
                logBusinessProfilePerformance(
                    event: "refreshFinished trigger=\(trigger) requestId=\(requestId) durationMs=\(durationMs) cachedDataAvailable=\(settingsBusinessProfileHasCachedData) didUIClearCachedState=\(didUIClearCachedState)"
                )
                logBusinessProfileHydrationState()
            }
        }
        if debounce {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !Task.isCancelled else { return }

        if refreshBusinessData {
            await viewModel.refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        }

        if shouldShowInlineBusinessDashboard {
            await refreshSettingsInlineBusinessDashboard()
        }

        await refreshSettingsBusinessProStatus(trigger: trigger, requestId: requestId)
    }

    private var settingsBusinessProfilePassiveRefreshTTL: TimeInterval { 30 }

    private func isPassiveSettingsBusinessProfileRefresh(trigger: String) -> Bool {
        trigger == "accountTabAppears" || trigger == "foreground"
    }

    private func logBusinessProfilePerformance(event: String) {
#if DEBUG
        print("[BusinessProfilePerf] \(event) cachedDataAvailable=\(settingsBusinessProfileHasCachedData) businessDataLoading=\(viewModel.isVenueOwnerBusinessDataLoading) hydrationInFlight=\(settingsBusinessProfileHydrationInFlight)")
#endif
    }

    private func nextSettingsBusinessProfileRefreshRequestId() -> Int {
        settingsBusinessProfileRefreshSequence += 1
        settingsBusinessProfileLatestRequestId = settingsBusinessProfileRefreshSequence
        return settingsBusinessProfileLatestRequestId
    }

    private var settingsBusinessEntitlementSignature: String {
        let businessId = viewModel.currentBusinessIdForAddLocation()?.uuidString.lowercased() ?? "nil"
        let ownerEmail = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        let entitlementUpdatedAt = settingsBusinessEntitlementUpdatedAt(for: viewModel.currentBusinessIdForAddLocation()) ?? "nil"
        return "\(businessId)|\(ownerEmail)|\(entitlementUpdatedAt)"
    }

    private func settingsBusinessEntitlementUpdatedAt(for businessId: UUID?) -> String? {
        let rows = viewModel.ownedBusinesses
        guard let businessId else {
            return rows
                .compactMap { $0.entitlement_updated_at?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
                .last
        }
        return rows
            .first(where: { $0.id == businessId })?
            .entitlement_updated_at?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshSettingsBusinessProStatus(trigger: String, requestId: Int) async {
        guard viewModel.hasBusinessAccountForOwner() || viewModel.currentBusinessIdForAddLocation() != nil else { return }
        let previousStatus = settingsBusinessMembershipStatus
        let currentBusinessId = viewModel.currentBusinessIdForAddLocation()
        let businessId = trigger == "businessProSheet"
            ? (previousStatus?.businessId ?? currentBusinessId)
            : currentBusinessId
        let status = await viewModel.businessVenueGamePostingStatus(
            storeKitBusinessProActive: false,
            businessId: businessId
        )
        let ignoredStaleResponse = requestId != settingsBusinessProfileLatestRequestId
        guard !ignoredStaleResponse else { return }

        if previousStatus?.computedIsPro == true && !status.loadedFromServer {
            return
        }

        if settingsBusinessMembershipStatus != status {
            settingsBusinessMembershipStatus = status
        }
        settingsBusinessProfileLastEntitlementSignature = settingsBusinessEntitlementSignature
        logBusinessStatisticsGateDebug(status)
    }

    private func logBusinessStatisticsGateDebug(_ status: BusinessVenueGamePostingStatus) {
#if DEBUG
        print("[BusinessStatisticsGateDebug] businessId=\(status.businessId?.uuidString.lowercased() ?? "nil") planType=\(status.planType) planStatus=\(status.planStatus) statisticsEnabled=\(status.statisticsEnabled) computedIsPro=\(status.computedIsPro) isStatisticsLocked=\(status.isStatisticsLocked)")
#endif
    }

    private func refreshSettingsManagedVenuesSection() async {
        await refreshSettingsBusinessProfile(trigger: "manualRefresh", refreshBusinessData: true)
    }

    private func refreshPendingVenueClaimFromDashboard(_ venue: BusinessVenueDashboardPendingVenueItem) async -> Bool {
        let removed = await viewModel.refreshPendingVenueClaimDirectly(claimId: venue.id)
        await refreshSettingsInlineBusinessDashboard()
        return removed
    }

    private func resendPendingVenueClaimFromDashboard(_ venue: BusinessVenueDashboardPendingVenueItem) async -> Bool {
        let sent = await viewModel.resendPendingVenueClaimRequest(claimId: venue.id)
        await refreshSettingsInlineBusinessDashboard()
        return sent
    }

    private func logSettingsInlineBusinessDashboardDebug() {
#if DEBUG
        print("[BusinessDashboardDebug] inlineOverviewRendered")
        print("[BusinessDashboardDebug] venueLoaded=\(!settingsBusinessDashboardVenueName.isEmpty)")
        print("[BusinessDashboardDebug] gamesLoaded=\(inlineBusinessDashboardGames.count)")
        print("[BusinessDashboardDebug] crowdMetrics=\(settingsBusinessDashboardFansGoing)")
        print("[BusinessDashboardDebug] predictionsLoaded=\(settingsBusinessDashboardPredictions)")
        print("[BusinessDashboardCleanup] removedDuplicateIdentityRow=true")
#endif
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
                let lhsDate = settingsApprovedVenueDateInfo(for: $0).sortDate
                let rhsDate = settingsApprovedVenueDateInfo(for: $1).sortDate
                switch (lhsDate, rhsDate) {
                case let (left?, right?):
                    if left != right { return left > right }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
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
            return String(format: L10n.t("member_since_format", languageCode: appLanguageRaw), raw)
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return String(format: L10n.t("member_since_format", languageCode: appLanguageRaw), f.string(from: date))
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
        let country = claim.venue_country.map(BusinessLocationCountryPolicy.countryName(for:)) ?? ""
        let line = [city, st, country].filter { !$0.isEmpty }.joined(separator: ", ")
        return line.isEmpty ? nil : line
    }

    private func settingsPendingClaimSubmittedDateText(_ claim: VenueClaimPendingSettingsRow) -> String {
        guard let raw = claim.created_at?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "Submitted date unavailable"
        }
        guard let date = SupabaseTimestampParsing.parseTimestamptz(raw) ?? settingsParseSupabaseTimestamptz(raw) else {
            return "Submitted \(String(raw.prefix(10)))"
        }
        return "Submitted \(date.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    /// Presents add-location sheet with a blank form (used from Current managed venue menu).
    private func openAddLocationFromPicker() {
        openAddLocationIfAllowed(action: "picker")
    }

    private func openBusinessVenueToolRoute(_ route: VenueOwnerDashboardSheetRoute) {
        Task {
            switch route {
            case .manageVenue, .manageGames:
                let allowed = await MainActor.run {
                    businessProfileVenueHydrationAllowsAction(route.rawValue)
                }
                guard allowed else { return }
            case .businessDashboard, .statistics:
                break
            }

            if await viewModel.businessBanGuardBlocks(path: "businessDashboard", action: route.rawValue) {
                return
            }

            if route == .manageVenue {
                guard await prepareVenueDetailsPresentationFromSettings(source: route.rawValue) else {
                    return
                }
            }

            await MainActor.run {
                switch route {
                case .manageVenue:
                    setVenueOwnerDashboardRoute(route, source: "openBusinessVenueToolRoute")
                case .manageGames:
                    guard viewModel.ensureValidSelectedManagedVenueForPresentation(source: route.rawValue) else {
#if DEBUG
                        print("[VenueOwnerEmptyStateDebug] noManagedVenues=true")
#endif
                        logBusinessProfileHydrationBlockedEarlyTap(action: route.rawValue, reason: "noValidSelectedVenueAfterRepair")
                        presentAddLocationSheet(reason: "businessDashboard")
                        return
                    }
                    setVenueOwnerDashboardRoute(route, source: "openBusinessVenueToolRoute")
                case .businessDashboard, .statistics:
                    setVenueOwnerDashboardRoute(route, source: "openBusinessVenueToolRoute")
                }
            }
        }
    }

    private func prepareVenueDetailsPresentationFromSettings(source: String) async -> Bool {
        let hasValidatedSelection = await MainActor.run {
            viewModel.ensureValidSelectedManagedVenueForPresentation(source: source)
        }
        guard hasValidatedSelection else {
            showVenueDetailsUnavailableNotice(source: source, reason: "noValidSelectedVenue")
            return false
        }

        guard let selectedVenueId = await MainActor.run(body: { viewModel.ownerVenueDatabaseId }) else {
            showVenueDetailsUnavailableNotice(source: source, reason: "missingSelectedVenueId")
            return false
        }

        guard let row = await viewModel.loadVenueProfile(),
              row.id == selectedVenueId,
              venueDetailsRowIsActiveForPresentation(row) else {
            showVenueDetailsUnavailableNotice(source: source, reason: "profileLoadFailedOrInactive")
            return false
        }

        await MainActor.run {
            viewModel.applyVenueProfileRowToOwnerState(row)
            businessDashboardQuickActionNotice = nil
        }
        return true
    }

    @MainActor
    private func showVenueDetailsUnavailableNotice(source: String, reason: String) {
        venueOwnerDashboardSheet = nil
        businessDashboardQuickActionNotice = "Venue Details are unavailable until an active managed venue is ready."
        logBusinessProfileHydrationBlockedEarlyTap(action: source, reason: reason)
    }

    private func venueDetailsRowIsActiveForPresentation(_ row: VenueProfileRow) -> Bool {
        let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return status.isEmpty || status == "active"
    }

    @MainActor
    private func setVenueOwnerDashboardRoute(
        _ route: VenueOwnerDashboardSheetRoute,
        source: String
    ) {
        let oldRoute = venueOwnerDashboardSheet
        guard oldRoute != route else {
#if DEBUG
            print("[BusinessDashboardRouteDebug] preventedDuplicateRoute route=\(route.rawValue)")
#endif
            return
        }
#if DEBUG
        print("[BusinessDashboardRouteDebug] routeSet source=\(source) oldRoute=\(oldRoute?.rawValue ?? "nil") newRoute=\(route.rawValue) selectedVenueId=\(viewModel.ownerVenueDatabaseId?.uuidString.lowercased() ?? "nil")")
#endif
        presentBusinessDashboardQuickAction(source: source, keepsVenueOwnerRoute: true) {
            venueOwnerDashboardSheet = route
        }
    }

    private func openAddLocationFromBusinessDashboard() {
        openAddLocationIfAllowed(action: "businessDashboard")
    }

    private func openAddLocationIfAllowed(action: String) {
        Task {
            if await viewModel.businessBanGuardBlocks(path: "addLocationSheet", action: action) {
                return
            }

            await MainActor.run {
                guard settingsBusinessCanCreateVenueFromServer else {
                    addLocationSubmitBanner = BusinessLimitCopy.venueLimitReached
                    presentBusinessDashboardQuickAction(source: "\(action)LimitReached") {
                        showBusinessUsageSheet = true
                    }
                    return
                }
                presentAddLocationSheet(reason: action)
            }
        }
    }

    private func presentAddLocationSheet(reason: String) {
#if DEBUG
        print("[AddLocationForm] initialized fresh")
        print("[AddLocationForm] opened from \(reason)")
#endif
        addLocationSubmitBanner = nil
        addLocationSheetFormState.reset(reason: reason == "picker" ? "open" : reason)
        presentBusinessDashboardQuickAction(source: "addLocation.\(reason)") {
            showAddLocationSheet = true
        }
    }

    private func addLocationSubmitBannerForegroundStyle() -> Color {
        if addLocationSubmitBanner == BusinessLimitCopy.venueLimitReached { return .red }
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
        if addLocationSubmitBanner == BusinessLimitCopy.venueLimitReached {
            return BusinessLimitCopy.venueLimitReached
        }
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
    var onCloseAfterSuccess: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var confirmationText: String = ""
    @State private var isDeleting: Bool = false
    @State private var errorMessage: String = ""
    @State private var didSucceed: Bool = false
    @State private var showDeletionSuccessConfirmation: Bool = false
    @FocusState private var confirmationFieldFocused: Bool

    private var canDelete: Bool {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DELETE"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Deleting your account removes or anonymizes your FanGeo profile and personal preferences. Favorites, saved venues, teams, and saved activity are removed. Existing chats and Fan Chat comments may remain as Deleted User to preserve conversation integrity, safety, and legal/compliance records. Deleted accounts cannot log back in unless FanGeo support restores or reactivates them. This action cannot be undone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("What happens") {
                    deletionRow("Your profile identity and avatar are removed")
                    deletionRow("Favorite teams and saved venues are removed")
                    deletionRow("Going, Interested, and personal preference signals are removed")
                    deletionRow("Direct messages and Fan Chat threads remain readable as Deleted User")
                    deletionRow("Reports and moderation records stay available for safety review")
                    deletionRow("This account cannot log back in unless support restores it")
                }

                Section("Confirm") {
                    TextField("Type DELETE to confirm", text: $confirmationText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .focused($confirmationFieldFocused)
                        .disabled(isDeleting || didSucceed)

                    Text("Type DELETE, then tap Delete Account Permanently. You will be signed out after deletion succeeds.")
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
                    Button("Close") {
                        if didSucceed {
                            completeSuccessClose()
                        } else {
                            dismiss()
                        }
                    }
                        .disabled(isDeleting)
                }
            }
            .alert("Your account has been deleted.", isPresented: $showDeletionSuccessConfirmation) {
                Button("Close") {
                    completeSuccessClose()
                }
            } message: {
                Text("You have been signed out.")
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

        do {
            try await viewModel.requestPermanentAccountDeletion()
            await MainActor.run {
                didSucceed = true
                confirmationText = ""
                dismissKeyboard()
                showDeletionSuccessConfirmation = true
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func dismissKeyboard() {
        confirmationFieldFocused = false
#if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
#endif
    }

    @MainActor
    private func completeSuccessClose() {
        dismissKeyboard()
        onCloseAfterSuccess()
        dismiss()
    }
}

private struct SettingsVenueOwnerDeletionSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmationText: String = ""
    @State private var preview: BusinessAccountDeletionPreview?
    @State private var isLoadingPreview: Bool = false
    @State private var isDeleting: Bool = false
    @State private var errorMessage: String = ""
    @State private var successMessage: String = ""
    @State private var didSucceed: Bool = false

    private var targetBusinessId: UUID? {
        viewModel.currentBusinessIdForAddLocation() ?? viewModel.ownedBusinesses.first?.id
    }

    private var canDelete: Bool {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DELETE"
            && preview != nil
    }

    private var groupedPreviewEvents: [(venueName: String, events: [BusinessAccountDeletionPreviewEvent])] {
        guard let preview else { return [] }
        let grouped = Dictionary(grouping: preview.gamesEventsToRemove, by: \.displayVenueName)
        return grouped
            .map { venueName, events in
                (
                    venueName: venueName,
                    events: events.sorted { lhs, rhs in
                        let lhsStart = lhs.scheduledStartAt ?? ""
                        let rhsStart = rhs.scheduledStartAt ?? ""
                        if lhsStart != rhsStart { return lhsStart < rhsStart }
                        let lhsDate = lhs.eventDate ?? ""
                        let rhsDate = rhs.eventDate ?? ""
                        if lhsDate != rhsDate { return lhsDate < rhsDate }
                        let lhsTime = lhs.eventTime ?? ""
                        let rhsTime = rhs.eventTime ?? ""
                        if lhsTime != rhsTime { return lhsTime < rhsTime }
                        return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
                    }
                )
            }
            .sorted { $0.venueName.localizedCaseInsensitiveCompare($1.venueName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Business-created venues will be permanently deleted. Community venues you claimed will stay on the map but will be removed from your business and returned to the FanGeo community marketplace.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if isLoadingPreview {
                    Section("Deletion preview") {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading deletion preview...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let preview {
                    Section("Counts") {
                        countRow("Business venues to delete", preview.businessVenueCount)
                        countRow("Community venues to release", preview.communityVenueCount)
                        countRow("Games/events to remove", preview.eventCount)
                        countRow("Photos to remove", preview.photoCount)
                        countRow("Pending claims to cancel", preview.pendingClaimCount)
                    }

                    Section("Business-created venues") {
                        if preview.businessVenuesToDelete.isEmpty {
                            Text("No business-created venues will be deleted.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(preview.businessVenuesToDelete) { venue in
                                previewVenueRow(
                                    name: venue.displayName,
                                    label: venue.label ?? "Will be deleted",
                                    tint: FGColor.dangerRed
                                )
                            }
                        }
                    }

                    Section("Community venues") {
                        if preview.communityVenuesToRelease.isEmpty {
                            Text("No community venues will be released.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(preview.communityVenuesToRelease) { venue in
                                previewVenueRow(
                                    name: venue.displayName,
                                    label: venue.label ?? "Will be returned to FanGeo community",
                                    tint: .orange
                                )
                            }
                        }
                    }

                    Section("Games/events to remove") {
                        let groupedEvents = groupedPreviewEvents
                        if groupedEvents.isEmpty {
                            Text("No games or events will be removed.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(groupedEvents, id: \.venueName) { group in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(group.venueName)
                                        .font(.subheadline.weight(.bold))
                                    ForEach(group.events) { event in
                                        previewEventRow(event)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    Section("Pending venues/claims") {
                        if preview.pendingBusinessVenuesToDelete.isEmpty,
                           preview.pendingCommunityClaimsToCancel.isEmpty {
                            Text("No pending venues or claims will be cancelled.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            if !preview.pendingBusinessVenuesToDelete.isEmpty {
                                Text("Pending business venues to delete")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                ForEach(preview.pendingBusinessVenuesToDelete) { venue in
                                    previewVenueRow(
                                        name: venue.displayName,
                                        label: venue.label ?? "Pending business venue to delete",
                                        tint: FGColor.dangerRed.opacity(0.88)
                                    )
                                }
                            }

                            if !preview.pendingCommunityClaimsToCancel.isEmpty {
                                Text("Pending community claims to cancel")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                ForEach(preview.pendingCommunityClaimsToCancel) { venue in
                                    previewVenueRow(
                                        name: venue.displayName,
                                        label: venue.label ?? "Pending community claim to cancel",
                                        tint: .orange
                                    )
                                }
                            }
                        }
                    }
                } else {
                    Section("Deletion preview") {
                        Text("Preview unavailable. Close and try again.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Confirm") {
                    TextField("Type DELETE to confirm", text: $confirmationText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    Text("Actual deletion only happens after tapping Delete Business Account. Loading this preview does not delete anything.")
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
                            Text(isDeleting ? "Deleting..." : "Delete Business Account")
                            Spacer()
                        }
                    }
                    .disabled(!canDelete || isLoadingPreview || isDeleting || didSucceed)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
            }
            .navigationTitle("Delete business account?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSucceed ? "Done" : "Close") { dismiss() }
                        .disabled(isDeleting)
                }
            }
            .task(id: targetBusinessId) {
                await loadPreview()
            }
        }
    }

    @ViewBuilder
    private func countRow(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func previewVenueRow(name: String, label: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "building.2.crop.circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func previewEventRow(_ event: BusinessAccountDeletionPreviewEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.displayTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(previewEventMetadata(event))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 10)
        .padding(.vertical, 2)
    }

    private func previewEventMetadata(_ event: BusinessAccountDeletionPreviewEvent) -> String {
        let league = event.league?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sport = event.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let date = event.eventDate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let time = event.eventTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scheduled = event.scheduledStartAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let status = event.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dateTime = [date, time].filter { !$0.isEmpty }.joined(separator: " · ")
        var parts = [String]()
        if !sport.isEmpty { parts.append(sport) }
        if !league.isEmpty { parts.append(league) }
        if !dateTime.isEmpty {
            parts.append(dateTime)
        } else if !scheduled.isEmpty {
            parts.append(scheduled)
        }
        if !status.isEmpty { parts.append(status.capitalized) }
        return parts.isEmpty ? "Event details unavailable" : parts.joined(separator: " • ")
    }

    private func loadPreview() async {
        guard let businessId = targetBusinessId else {
            await MainActor.run {
                preview = nil
                errorMessage = "No active business account was found."
            }
            return
        }

        await MainActor.run {
            isLoadingPreview = true
            errorMessage = ""
            successMessage = ""
            preview = nil
        }
        defer {
            Task { @MainActor in isLoadingPreview = false }
        }

        do {
            let loaded = try await viewModel.businessAccountDeletionPreview(businessId: businessId)
            await MainActor.run {
                preview = loaded
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runDelete() async {
        guard let businessId = targetBusinessId else {
            errorMessage = "No active business account was found."
            return
        }

        isDeleting = true
        defer { isDeleting = false }
        errorMessage = ""
        successMessage = ""

        do {
            _ = try await viewModel.deleteBusinessAccountCascade(businessId: businessId)
            await MainActor.run {
                successMessage = "Business account deleted."
                didSucceed = true
                confirmationText = ""
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
    var actionTitle: String? = nil
    var actionSystemImage: String? = nil
    var action: (() -> Void)? = nil
    var footerMessage: String? = nil
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
                if let footerMessage,
                   !footerMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(footerMessage)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(action: action) {
                        Label(actionTitle, systemImage: actionSystemImage ?? "envelope.fill")
                            .font(FGTypography.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tint)
                    .padding(.top, 4)
                }
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

private enum DeletedAccountSupportContact {
    static let recipient = "support@fangeosports.com"
    static let subject = "Deleted account support request"

    static func body(attemptedLoginEmail: String) -> String {
        let normalized = OwnerBusinessEmail.normalized(attemptedLoginEmail)
        let emailLine = normalized.isEmpty ? "<enter your account email>" : normalized
        return """
        Email: \(emailLine)
        Reason: I believe my account was deleted by mistake.
        """
    }

    static func isDeletedAccountBlockMessage(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("account has been deleted")
    }
}

private struct DeletedAccountSupportStatusBanner: View {
    let title: String
    let message: String
    let attemptedLoginEmail: String
    @State private var showMailComposer = false
    @State private var fallbackMessage = ""

    var body: some View {
        SettingsSheetStatusBanner(
            title: title,
            message: message,
            tint: FGColor.dangerRed,
            systemImage: "exclamationmark.triangle.fill",
            actionTitle: "Contact Support",
            actionSystemImage: "envelope.fill",
            action: contactSupport,
            footerMessage: fallbackMessage
        )
#if canImport(MessageUI)
        .sheet(isPresented: $showMailComposer) {
            DeletedAccountSupportMailComposer(attemptedLoginEmail: attemptedLoginEmail)
        }
#endif
    }

    private func contactSupport() {
        fallbackMessage = ""
#if canImport(MessageUI)
        if MFMailComposeViewController.canSendMail() {
            showMailComposer = true
            return
        }
#endif
#if canImport(UIKit)
        UIPasteboard.general.string = DeletedAccountSupportContact.recipient
        fallbackMessage = "Support email copied: \(DeletedAccountSupportContact.recipient)"
#else
        fallbackMessage = "Contact support at \(DeletedAccountSupportContact.recipient)"
#endif
    }
}

#if canImport(MessageUI)
private struct DeletedAccountSupportMailComposer: UIViewControllerRepresentable {
    let attemptedLoginEmail: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([DeletedAccountSupportContact.recipient])
        composer.setSubject(DeletedAccountSupportContact.subject)
        composer.setMessageBody(
            DeletedAccountSupportContact.body(attemptedLoginEmail: attemptedLoginEmail),
            isHTML: false
        )
        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onFinish()
        }
    }
}
#endif

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
    var statusMessage: String = ""
    var attemptedLoginEmail: String = ""
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

            if !statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if DeletedAccountSupportContact.isDeletedAccountBlockMessage(statusMessage) {
                    DeletedAccountSupportStatusBanner(
                        title: "Account access blocked",
                        message: statusMessage,
                        attemptedLoginEmail: attemptedLoginEmail
                    )
                } else {
                    SettingsSheetStatusBanner(
                        title: "Account access blocked",
                        message: statusMessage,
                        tint: FGColor.dangerRed,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }
            }

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
        Group {
            if viewModel.pendingEmailVerificationKind == .fan {
                ScrollView {
                    EmailVerificationPendingView(
                        viewModel: viewModel,
                        kind: .fan,
                        email: viewModel.pendingEmailVerificationEmail,
                        onBackToSignIn: {
                            showRegisterMode = false
                            viewModel.authErrorMessage = ""
                        }
                    )
                    .padding(.horizontal, FGSpacing.lg)
                    .padding(.top, FGSpacing.lg)
                }
                .scrollIndicators(.hidden)
            } else if showRegisterMode {
                FanSignupView(
                    viewModel: viewModel,
                    prefilledEmail: email,
                    onSwitchToSignIn: {
                        showRegisterMode = false
                        viewModel.authErrorMessage = ""
                    },
                    onDismissAfterSuccess: { dismiss() }
                )
            } else {
                fanSignInScrollContent
            }
        }
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
            if !wasLoggedIn && isLoggedIn, !showRegisterMode {
                dismiss()
            }
        }
    }

    private var fanSignInScrollContent: some View {
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

                SettingsFanLoginCard(
                    viewModel: viewModel,
                    email: $email,
                    password: $password,
                    onCreateAccount: { showRegisterMode = true }
                )
            }
            .padding(.horizontal, FGSpacing.lg)
            .padding(.bottom, FGSpacing.md)
        }
        .scrollIndicators(.hidden)
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

                if viewModel.pendingEmailVerificationKind == .business {
                    EmailVerificationPendingView(
                        viewModel: viewModel,
                        kind: .business,
                        email: viewModel.pendingEmailVerificationEmail,
                        onBackToSignIn: {
                            showVenueRegisterMode = false
                            viewModel.venueAuthErrorMessage = ""
                        }
                    )
                } else if viewModel.isVenueOwnerLoggedIn {
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
    var businessMembershipStatus: BusinessVenueGamePostingStatus?
    var venueOwnerOnNotifications: () -> Void
    var venueOwnerOnResetPassword: () -> Void
    var venueOwnerOnDismissSheetsAfterLogout: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var isBusinessProfile: Bool {
        viewModel.venueOwnerMode || viewModel.isVenueOwnerLoggedIn || viewModel.currentUserIsBusinessAccount
    }

    private var managedVenueCount: Int {
        viewModel.managedVenuesForOwner().count
    }

    private var businessHasManagedVenues: Bool {
        managedVenueCount > 0
    }

    private var currentBusinessRow: BusinessRow? {
        if let businessId = viewModel.currentBusinessIdForAddLocation(),
           let business = viewModel.ownedBusinesses.first(where: { $0.id == businessId }) {
            return business
        }
        return viewModel.ownedBusinesses.first
    }

    private var businessHeaderName: String {
        if let name = trimmedNonEmpty(currentBusinessRow?.display_name) {
            return name
        }
        return venueOwnerBusinessHeroTitle
    }

    private var businessHeaderLocation: String {
        businessLocationLine ?? "Business dashboard"
    }

    private var businessHeaderMemberSince: String {
        guard let raw = trimmedNonEmpty(currentBusinessRow?.created_at),
              let date = SupabaseTimestampParsing.parseTimestamptz(raw) else {
            return "Member since FanGeo"
        }
        return "Member since \(Self.businessHeaderMemberSinceFormatter.string(from: date))"
    }

    private var businessHeaderIsPro: Bool {
        businessMembershipStatus?.computedIsPro == true
    }

    private var businessHeaderActiveVenueCount: Int {
        if let businessMembershipStatus {
            return businessMembershipStatus.activeVenueCount
        }
        var seen = Set<UUID>()
        return viewModel.managedVenuesForOwner().reduce(0) { count, row in
            guard let id = row.id, seen.insert(id).inserted else { return count }
            return MapViewModel.venueIsActiveForBusinessLimit(row) ? count + 1 : count
        }
    }

    private var businessHeaderActiveVenueValue: String {
        let total = max(managedVenueCount, businessHeaderActiveVenueCount)
        if total > businessHeaderActiveVenueCount {
            return "\(businessHeaderActiveVenueCount) / \(total)"
        }
        return "\(businessHeaderActiveVenueCount)"
    }

    private var businessHeaderHostedGamesValue: String {
        if let businessMembershipStatus {
            return "\(businessMembershipStatus.monthlyHostedGameCount)"
        }
        return "0"
    }

    private static let businessHeaderMemberSinceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    private var selectedVenueForHero: VenueProfileRow? {
        let managed = viewModel.managedVenuesForOwner()
        if let id = viewModel.ownerVenueDatabaseId,
           let selected = managed.first(where: { $0.id == id }) {
            return selected
        }
        return managed.first
    }

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
        if isBusinessProfile {
            if let venueName = trimmedNonEmpty(selectedVenueForHero?.venue_name) {
                return venueName
            }
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
        isBusinessProfile ? L10n.t("official_venue_dashboard", languageCode: appLanguageRaw) : "User account"
    }

    private var activityBadgeText: String {
        if isBusinessProfile {
            return managedVenueCount == 1 ? "1 managed venue" : "\(managedVenueCount) managed venues"
        }
        let favoritesCount = viewModel.favoriteVenueIDs.count
        return favoritesCount == 1 ? "1 saved venue" : "\(favoritesCount) saved venues"
    }

    private var activityBadgeTint: Color {
        if isBusinessProfile {
            return businessHasManagedVenues ? FGColor.accentGreen : FGColor.accentBlue
        }
        return FGColor.accentYellow
    }

    private var businessLocationLine: String? {
        guard isBusinessProfile else { return nil }
        guard let venue = selectedVenueForHero else { return nil }
        let city = venue.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = venue.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let country = venue.country.map(BusinessLocationCountryPolicy.countryName(for:)) ?? ""
        let parts = [city, state, country].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var businessHeroImageSource: String {
        isBusinessProfile ? "forcedBusinessIcon" : "fanAvatar"
    }

    private var businessStatusLabel: String {
        if businessHeroShowsVerifiedVenue {
            return L10n.t("verified_venue", languageCode: appLanguageRaw).uppercased()
        }
        return "BUSINESS ACCOUNT"
    }

    private var businessHeroShowsVerifiedVenue: Bool {
        isBusinessProfile
            && selectedVenueForHero != nil
            && viewModel.businessSettingsLocationChrome() == .approved
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
                    heroAvatar

                    VStack(alignment: .leading, spacing: FGSpacing.xs) {
                        if isBusinessProfile {
                            businessAccountLabel
                        } else {
                            Text("FanGeo profile")
                                .font(FGTypography.metadata.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.72))
                        }

                        HStack(spacing: 8) {
                            Text(resolvedDisplayName.isEmpty ? "My profile" : resolvedDisplayName)
                                .font(isBusinessProfile ? .title2.weight(.black) : FGTypography.sectionTitle)
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            if businessHeroShowsVerifiedVenue {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.headline.weight(.bold))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(FGColor.accentGreen)
                            }
                        }

                        if let location = businessLocationLine {
                            Label(location, systemImage: "mappin.and.ellipse")
                                .font(FGTypography.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.84))
                                .lineLimit(1)
                        } else if !heroEmailLine.isEmpty {
                            Text(heroEmailLine)
                                .font(FGTypography.caption)
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    if !isBusinessProfile {
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
                }

                HStack(spacing: FGSpacing.sm) {
                    accountTypeCapsule
                    activityCapsule
                    if isBusinessProfile {
                        heroGlassPill(title: L10n.t("venue_owner_account", languageCode: appLanguageRaw), accent: FGColor.accentBlue)
                    }
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

    private var businessDashboardHeaderCard: some View {
        ZStack(alignment: .bottomTrailing) {
            heroBackgroundGradient
            heroBlueHighlight

            VStack(alignment: .leading, spacing: FGSpacing.md) {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    businessHeaderAvatar

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            businessHeaderBadge(title: "Verified Business", systemImage: "shield.checkered", tint: FGColor.accentGreen)
                            if businessHeaderIsPro {
                                businessHeaderBadge(title: "Pro Business", systemImage: "crown.fill", tint: SettingsPremiumChrome.proGold(colorScheme))
                            }
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(businessHeaderName.isEmpty ? "Business profile" : businessHeaderName)
                                .font(.system(size: 26, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .minimumScaleFactor(0.82)

                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 15, weight: .bold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(FGColor.accentGreen)
                        }

                        Text("Business Account")
                            .font(FGTypography.caption.weight(.bold))
                            .foregroundStyle(FGColor.accentGreen)

                        Text("We bring fans together with the best sports atmosphere.")
                            .font(FGTypography.caption)
                            .foregroundStyle(.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(businessHeaderLocation, systemImage: "mappin.and.ellipse")
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(businessHeaderMemberSince, systemImage: "calendar")
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 9) {
                        businessHeaderMetric(
                            title: "Active Venues",
                            value: businessHeaderActiveVenueValue,
                            systemImage: "checkmark.seal.fill"
                        )
                        businessHeaderMetric(
                            title: "Hosted Games This Month",
                            value: businessHeaderHostedGamesValue,
                            systemImage: "sportscourt.fill"
                        )
                    }
                    .padding(.leading, FGSpacing.md)
                    .frame(minWidth: 118, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                            .frame(width: 1)
                    }
                }
            }
            .padding(.horizontal, FGSpacing.lg)
            .padding(.vertical, FGSpacing.lg)

            FanGeoLogoWatermark(variant: .white, width: 54, opacity: 0.045)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.11 : 0.14), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.14), radius: 16, y: 9)
        .shadow(color: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.10 : 0.06), radius: 14, y: 2)
    }

    private var businessHeaderAvatar: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            FGColor.accentGreen.opacity(0.98),
                            FGColor.businessGreen.opacity(0.82)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: "building.2.fill")
                .font(.system(size: 34, weight: .black))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)

            Image(systemName: "shield.checkered")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(FGColor.accentGreen)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.86), lineWidth: 1.5)
                }
                .offset(x: 5, y: 5)
        }
        .frame(width: 72, height: 72)
        .shadow(color: FGColor.accentGreen.opacity(0.25), radius: 12, y: 6)
    }

    private func businessHeaderBadge(title: String, systemImage: String, tint: Color) -> some View {
        Label(title.uppercased(), systemImage: systemImage)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.32 : 0.26))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    }
            )
    }

    private func businessHeaderMetric(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(FGColor.accentGreen)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var heroAvatar: some View {
        if isBusinessProfile {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.10))

                businessBuildingFallbackIcon
            }
            .frame(width: 78, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
            }
        } else {
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
        }
    }

    private var businessBuildingFallbackIcon: some View {
        ZStack {
            LinearGradient(
                colors: [
                    FGColor.accentGreen.opacity(0.95),
                    FGColor.businessGreen.opacity(0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "building.2.fill")
                .font(.system(size: 34, weight: .black))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
    }

    private var businessAccountLabel: some View {
        Label(businessStatusLabel, systemImage: businessHeroShowsVerifiedVenue ? "shield.checkered" : "building.2.fill")
            .font(.caption.weight(.black))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    colors: businessHeroShowsVerifiedVenue
                        ? [FGColor.accentGreen.opacity(0.95), FGColor.accentBlue.opacity(0.85)]
                        : [FGColor.accentBlue.opacity(0.86), Color.white.opacity(0.16)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
    }

    private func logBusinessProfileHeaderIfZeroVenues() {
#if DEBUG
        guard isBusinessProfile, managedVenueCount == 0 else { return }
        print("[BusinessProfileHeaderDebug] clearedStaleVenueHeader=true")
        print("[BusinessProfileHeaderDebug] managedVenueCount=0")
#endif
    }

    var body: some View {
        Group {
            if isBusinessProfile {
                businessDashboardHeaderCard
            } else {
                heroCard
            }
        }
            .onAppear {
#if DEBUG
                if isBusinessProfile {
                    print("[BusinessDashboardCleanup] removedLegacyFanLevel=true")
                    print("[BusinessDashboardCleanup] unifiedHeroCard=true")
                    print("[BusinessDashboardCleanup] businessIdentityEnhanced=true")
                    print("[BusinessDashboardCleanup] businessAccountStylingApplied=true")
                    print("[BusinessDashboardCleanup] businessHeroImageSource=\(businessHeroImageSource)")
                    print("[BusinessDashboardCleanup] blockedFanAvatarInBusinessHero=true")
                    print("[BusinessDashboardCleanup] forcedBusinessIconHero=true")
                }
#endif
                logBusinessProfileHeaderIfZeroVenues()
            }
            .onChange(of: managedVenueCount) { _, _ in
                logBusinessProfileHeaderIfZeroVenues()
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
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("time_zone", languageCode: appLanguageRaw))
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Choose how game times should appear.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(L10n.t("time_zone", languageCode: appLanguageRaw), selection: $viewModel.selectedTimeZone) {
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
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: MapViewModel

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.18, green: 0.05, blue: 0.06).opacity(0.72)
            : Color.red.opacity(0.08)
    }

    private var containerBackground: Color {
        colorScheme == .dark
            ? FGColor.cardBackground(colorScheme)
            : Color.white.opacity(0.95)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reported Comments")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(FGColor.primaryText(colorScheme))

            Button {
                Task {
                    await viewModel.loadReportedComments()
                }
            } label: {
                Label("Refresh Reports", systemImage: "arrow.clockwise")
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .foregroundStyle(.white)
                    .background(FGColor.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            if viewModel.reportedCommentDisplays.isEmpty {
                Text("No reported comments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.reportedCommentDisplays) { report in
                    let commentUnavailable = isCommentUnavailable(report)
                    VStack(alignment: .leading, spacing: 12) {

                        HStack(alignment: .top, spacing: 12) {

                            if !commentUnavailable,
                               let url = URL(string: report.commenterAvatarURL),
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

                                reportAvatarFallback(unavailable: commentUnavailable, name: report.commenterName)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(commentUnavailable ? "Comment unavailable" : report.commenterName)
                                    .font(.headline)
                                    .fontWeight(.bold)
                                    .foregroundStyle(FGColor.primaryText(colorScheme))

                                if !commentUnavailable {
                                    Text("“\(report.commentText)”")
                                        .font(.subheadline)
                                        .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.88))
                                }

                                Text("\(report.venueName) • \(report.eventTitle)")
                                    .font(.caption)
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))

                                Text("Reported: \(formattedReportDate(report.reportedAt))")
                                    .font(.caption)
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))

                                Text("Reported by: \(report.reporterName)")
                                    .font(.caption2)
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                
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
                                            .background(FGColor.dangerRed.opacity(colorScheme == .dark ? 0.24 : 0.14))
                                            .foregroundStyle(FGColor.dangerRed)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)

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
                                            .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.24 : 0.14))
                                            .foregroundStyle(FGColor.accentGreen)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(FGColor.dangerRed.opacity(colorScheme == .dark ? 0.38 : 0.18), lineWidth: 1)
                    }
                }
            }
        }
        .padding()
        .background(containerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
    }

    private func reportAvatarFallback(unavailable: Bool, name: String) -> some View {
        Circle()
            .fill(unavailable ? FGColor.secondaryText(colorScheme).opacity(0.14) : Color.orange.opacity(0.15))
            .frame(width: 44, height: 44)
            .overlay {
                Image(systemName: unavailable ? "text.bubble.fill" : "person.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(unavailable ? FGColor.secondaryText(colorScheme) : Color.orange)
            }
            .accessibilityHidden(true)
    }

    private func isCommentUnavailable(_ report: ReportedCommentDisplay) -> Bool {
        report.commentText.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Comment not found") == .orderedSame
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

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if viewModel.isLoggedIn {
                SettingsGameNotificationsCard(viewModel: viewModel, notificationSettingsStore: viewModel.notificationSettingsStore)
                SettingsSavedGamesCard()
            }

            SettingsFanLoginCard(
                viewModel: viewModel,
                email: $email,
                password: $password,
                onCreateAccount: { showRegisterMode = true }
            )

            if viewModel.isLoggedIn {
                SettingsPrivateChatDeviceAuthCard()
                SettingsFanAccountSecurityCard(viewModel: viewModel)
            }
        }
    }
}

// MARK: - Private chat (local device lock)

private struct SettingsPrivateChatDeviceAuthCard: View {
    @AppStorage(PrivateChatSecuritySettings.requireFaceIDSettingKey) private var requireDeviceAuthForPrivateChat = false
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var requireFaceIDBinding: Binding<Bool> {
        Binding(
            get: { requireDeviceAuthForPrivateChat },
            set: { newValue in
                requireDeviceAuthForPrivateChat = newValue
                print("[PrivateChatSecurityDebug] settingChanged=\(newValue)")
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Private messages")
                .font(.headline)
                .fontWeight(.bold)

            Toggle(L10n.t("require_face_id_private_chat", languageCode: appLanguageRaw), isOn: requireFaceIDBinding)
                .font(.subheadline)

            Text(L10n.t("private_chat_face_id_description", languageCode: appLanguageRaw))
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

                Text("Manage sensitive account actions. Deletion removes or anonymizes your profile and preferences, while chats, Fan Chat comments, reports, and moderation records may remain as Deleted User for safety and conversation integrity.")
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

                Text("This removes your profile, favorites, attendance, and preferences. Existing chats and Fan Chat comments stay readable for other users and show you as Deleted User. This cannot be undone.")
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

/// Fan sign-in only (registration uses ``FanSignupView``).
private struct SettingsFanLoginCard: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var email: String
    @Binding var password: String
    var onCreateAccount: () -> Void
    @State private var showFanPasswordResetSheet = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        FGCard {
            FGSectionHeader(
                "Fan account access",
                subtitle: "Sign in to sync your profile and activity."
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
                FanGeoAppleSignInButton(viewModel: viewModel, accountMode: .fan)

                if !viewModel.appleAuthFanMessage.isEmpty {
                    SettingsSheetStatusBanner(
                        title: viewModel.appleAuthFanMessageIsError ? "Apple Sign In" : nil,
                        message: viewModel.appleAuthFanMessage,
                        tint: viewModel.appleAuthFanMessageIsError ? FGColor.dangerRed : FGColor.accentBlue,
                        systemImage: viewModel.appleAuthFanMessageIsError ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.checkmark"
                    )
                }

                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .fanGeoInputFieldStyle()

                SecureField("Password", text: $password)
                    .fanGeoInputFieldStyle()

                Button {
#if DEBUG
                    print("[FanPasswordResetDebug] forgotPasswordTapped=true")
#endif
                    guard viewModel.canPresentPasswordResetRequestSheet() else {
                        showFanPasswordResetSheet = false
                        return
                    }
                    viewModel.userPasswordResetMessage = ""
                    viewModel.userPasswordResetError = ""
                    showFanPasswordResetSheet = true
                } label: {
                    Text("Forgot password?")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.accentBlue)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)

                FGPrimaryButton(title: "Login") {
                    Task {
                        await MainActor.run {
                            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "emailPasswordSignIn")
                        }
                        await viewModel.loginUser(email: email, password: password)
                        await MainActor.run {
                            password = ""
                        }
                    }
                }

                if !viewModel.passwordResetUpdateMessage.isEmpty {
                    SettingsSheetStatusBanner(
                        title: "Password updated",
                        message: viewModel.passwordResetUpdateMessage,
                        tint: FGColor.accentGreen,
                        systemImage: "checkmark.circle.fill"
                    )
                }

                if !viewModel.authErrorMessage.isEmpty {
                    if DeletedAccountSupportContact.isDeletedAccountBlockMessage(viewModel.authErrorMessage) {
                        DeletedAccountSupportStatusBanner(
                            title: "Couldn’t sign in",
                            message: viewModel.authErrorMessage,
                            attemptedLoginEmail: email
                        )
                    } else {
                        SettingsSheetStatusBanner(
                            title: "Couldn’t sign in",
                            message: viewModel.authErrorMessage,
                            tint: FGColor.dangerRed,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                }

                Button(action: onCreateAccount) {
                    Text("New user? Create account")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.accentBlue)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: email) { _, _ in
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "emailEdited")
        }
        .onChange(of: password) { _, _ in
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "passwordEdited")
        }
        .onDisappear {
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "sheetClosed")
        }
        .sheet(isPresented: $showFanPasswordResetSheet) {
            SettingsFanPasswordResetSheet(
                viewModel: viewModel,
                loginEmail: email,
                isPresented: $showFanPasswordResetSheet
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
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

private struct SettingsFanPasswordResetSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let loginEmail: String
    @Binding var isPresented: Bool
    @State private var resetEmail = ""
    @State private var isSending = false
    @State private var resetLinkAutoDismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if viewModel.passwordResetSheetMode == .createPassword || viewModel.isPasswordResetRecoverySessionActive {
                Color.clear.ignoresSafeArea()
            } else {
                NavigationStack {
                    VStack(alignment: .leading, spacing: FGSpacing.md) {
                        FGSectionHeader(
                            "Reset password",
                            subtitle: "We’ll email a secure link to reset your FanGeo fan account password."
                        )

                        TextField("Email", text: $resetEmail)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .fanGeoInputFieldStyle()

                        FGPrimaryButton(title: "Send reset link", isDisabled: isSending) {
                            Task {
                                isSending = true
                                await viewModel.sendPasswordResetEmail(resetEmail, accountKind: .fan)
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

                        Spacer(minLength: 0)
                    }
                    .padding(FGSpacing.lg)
                    .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
                    .navigationTitle("Reset password")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(viewModel.userPasswordResetMessage.isEmpty ? "Cancel" : "Done") {
                                isPresented = false
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            resetEmail = loginEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            viewModel.passwordResetRequestSheetDidAppear()
        }
        .onDisappear {
            cancelResetLinkAutoDismiss(log: true)
            viewModel.passwordResetRequestSheetDidDisappear()
        }
        .onChange(of: viewModel.userPasswordResetMessage) { _, message in
            scheduleResetLinkAutoDismissIfNeeded(message: message, error: viewModel.userPasswordResetError)
        }
        .onChange(of: viewModel.userPasswordResetError) { _, error in
            if !error.isEmpty {
                cancelResetLinkAutoDismiss(log: true)
            }
        }
        .onChange(of: viewModel.passwordResetSheetMode) { _, mode in
            if mode != .requestLink {
                cancelResetLinkAutoDismiss(log: true)
            }
        }
    }

    private func scheduleResetLinkAutoDismissIfNeeded(message: String, error: String) {
        guard !message.isEmpty,
              error.isEmpty,
              isPresented,
              viewModel.passwordResetSheetMode == .requestLink,
              !viewModel.isPasswordResetRecoverySessionActive
        else { return }

        cancelResetLinkAutoDismiss(log: false)
        print("[PasswordResetDebug] resetLinkSendSuccessAutoDismissScheduled=true")
        resetLinkAutoDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: PasswordResetRequestAutoDismiss.delayNanoseconds)
            } catch {
                print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
                return
            }

            guard isPresented,
                  viewModel.passwordResetSheetMode == .requestLink,
                  !viewModel.userPasswordResetMessage.isEmpty,
                  viewModel.userPasswordResetError.isEmpty
            else {
                print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
                return
            }

            resetLinkAutoDismissTask = nil
            isPresented = false
            print("[PasswordResetDebug] resetLinkRequestSheetAutoDismissed=true")
        }
    }

    private func cancelResetLinkAutoDismiss(log: Bool) {
        guard let task = resetLinkAutoDismissTask else { return }
        task.cancel()
        resetLinkAutoDismissTask = nil
        if log {
            print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
        }
    }
}

// MARK: - Venue owner password reset

private enum PasswordResetRequestAutoDismiss {
    static let delayNanoseconds: UInt64 = 4_500_000_000
}

private struct SettingsVenueOwnerPasswordResetSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var isPresented: Bool
    @State private var resetLinkAutoDismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if viewModel.passwordResetSheetMode == .createPassword || viewModel.isPasswordResetRecoverySessionActive {
                Color.clear.ignoresSafeArea()
            } else {
                NavigationStack {
                    Form { SettingsVenuePasswordResetCard(viewModel: viewModel) }
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
                        }
                        .navigationTitle("Reset venue password")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { isPresented = false }
                            }
                        }
                }
            }
        }
        .onAppear {
            viewModel.passwordResetRequestSheetDidAppear()
        }
        .onDisappear {
            cancelResetLinkAutoDismiss(log: true)
            viewModel.passwordResetRequestSheetDidDisappear()
        }
        .onChange(of: viewModel.venuePasswordResetMessage) { _, message in
            scheduleResetLinkAutoDismissIfNeeded(message: message, error: viewModel.venuePasswordResetError)
        }
        .onChange(of: viewModel.venuePasswordResetError) { _, error in
            if !error.isEmpty {
                cancelResetLinkAutoDismiss(log: true)
            }
        }
        .onChange(of: viewModel.passwordResetSheetMode) { _, mode in
            if mode != .requestLink {
                cancelResetLinkAutoDismiss(log: true)
            }
        }
    }

    private func scheduleResetLinkAutoDismissIfNeeded(message: String, error: String) {
        guard !message.isEmpty,
              error.isEmpty,
              isPresented,
              viewModel.passwordResetSheetMode == .requestLink,
              !viewModel.isPasswordResetRecoverySessionActive
        else { return }

        cancelResetLinkAutoDismiss(log: false)
        print("[PasswordResetDebug] resetLinkSendSuccessAutoDismissScheduled=true")
        resetLinkAutoDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: PasswordResetRequestAutoDismiss.delayNanoseconds)
            } catch {
                print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
                return
            }

            guard isPresented,
                  viewModel.passwordResetSheetMode == .requestLink,
                  !viewModel.venuePasswordResetMessage.isEmpty,
                  viewModel.venuePasswordResetError.isEmpty
            else {
                print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
                return
            }

            resetLinkAutoDismissTask = nil
            isPresented = false
            print("[PasswordResetDebug] resetLinkRequestSheetAutoDismissed=true")
        }
    }

    private func cancelResetLinkAutoDismiss(log: Bool) {
        guard let task = resetLinkAutoDismissTask else { return }
        task.cancel()
        resetLinkAutoDismissTask = nil
        if log {
            print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
        }
    }
}

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

private struct SettingsBusinessPasswordResetSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var isPresented: Bool
    @State private var resetEmail = ""
    @State private var isSending = false
    @State private var resetLinkAutoDismissTask: Task<Void, Never>?

    private var prefilledBusinessEmail: String {
        OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
    }

    var body: some View {
        Group {
            if viewModel.passwordResetSheetMode == .createPassword || viewModel.isPasswordResetRecoverySessionActive {
                Color.clear.ignoresSafeArea()
            } else {
                NavigationStack {
                    VStack(alignment: .leading, spacing: FGSpacing.md) {
                        FGSectionHeader(
                            "Reset business password",
                            subtitle: "We’ll email a secure link to reset the password for your business owner account."
                        )

                        TextField("Business email", text: $resetEmail)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .fanGeoInputFieldStyle()

                        FGPrimaryButton(title: "Send reset link", isDisabled: isSending) {
                            Task {
                                isSending = true
                                await viewModel.sendPasswordResetEmail(resetEmail, accountKind: .venueOwner)
                                isSending = false
                            }
                        }

                        if !viewModel.venuePasswordResetMessage.isEmpty {
                            SettingsSheetStatusBanner(
                                title: "Reset link sent",
                                message: viewModel.venuePasswordResetMessage,
                                tint: FGColor.accentGreen,
                                systemImage: "checkmark.circle.fill"
                            )
                        }

                        if !viewModel.venuePasswordResetError.isEmpty {
                            SettingsSheetStatusBanner(
                                title: "Reset unavailable",
                                message: viewModel.venuePasswordResetError,
                                tint: FGColor.dangerRed,
                                systemImage: "xmark.circle.fill"
                            )
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(FGSpacing.lg)
                    .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
                    .navigationTitle("Reset business password")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(viewModel.venuePasswordResetMessage.isEmpty ? "Cancel" : "Done") {
                                isPresented = false
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            resetEmail = prefilledBusinessEmail
            viewModel.passwordResetRequestSheetDidAppear()
        }
        .onDisappear {
            cancelResetLinkAutoDismiss(log: true)
            viewModel.passwordResetRequestSheetDidDisappear()
        }
        .onChange(of: viewModel.venuePasswordResetMessage) { _, message in
            scheduleResetLinkAutoDismissIfNeeded(message: message, error: viewModel.venuePasswordResetError)
        }
        .onChange(of: viewModel.venuePasswordResetError) { _, error in
            if !error.isEmpty {
                cancelResetLinkAutoDismiss(log: true)
            }
        }
        .onChange(of: viewModel.passwordResetSheetMode) { _, mode in
            if mode != .requestLink {
                cancelResetLinkAutoDismiss(log: true)
            }
        }
    }

    private func scheduleResetLinkAutoDismissIfNeeded(message: String, error: String) {
        guard !message.isEmpty,
              error.isEmpty,
              isPresented,
              viewModel.passwordResetSheetMode == .requestLink,
              !viewModel.isPasswordResetRecoverySessionActive
        else { return }

        cancelResetLinkAutoDismiss(log: false)
        print("[PasswordResetDebug] resetLinkSendSuccessAutoDismissScheduled=true")
        resetLinkAutoDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: PasswordResetRequestAutoDismiss.delayNanoseconds)
            } catch {
                print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
                return
            }

            guard isPresented,
                  viewModel.passwordResetSheetMode == .requestLink,
                  !viewModel.venuePasswordResetMessage.isEmpty,
                  viewModel.venuePasswordResetError.isEmpty
            else {
                print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
                return
            }

            resetLinkAutoDismissTask = nil
            isPresented = false
            print("[PasswordResetDebug] resetLinkRequestSheetAutoDismissed=true")
        }
    }

    private func cancelResetLinkAutoDismiss(log: Bool) {
        guard let task = resetLinkAutoDismissTask else { return }
        task.cancel()
        resetLinkAutoDismissTask = nil
        if log {
            print("[PasswordResetDebug] resetLinkAutoDismissCancelled=true")
        }
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
                title: "Community Games",
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
    @State private var showBusinessPasswordResetSheet = false

    @State private var signupBusinessName = ""
    @State private var signupLocationName = ""
    @State private var signupStreet = ""
    @State private var signupAddressLine2 = ""
    @State private var signupCity = ""
    @State private var signupState = ""
    @State private var signupCountry = BusinessLocationCountryPolicy.defaultCountryCode
    @State private var signupZip = ""
    @State private var signupLatitude: Double?
    @State private var signupLongitude: Double?
    @State private var signupFormattedAddress = ""
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
    @State private var signupEasyParking = false
    @State private var signupHandicapParking = false
    @State private var signupLiveMusic = false
    @State private var signupPoolTables = false
    @State private var signupRooftop = false
    @State private var signupDJNights = false
    @State private var signupKaraoke = false
    @State private var signupCocktails = false
    @State private var signupCraftBeer = false
    @State private var signupCoverPicker: PhotosPickerItem?
    @State private var signupMenuPicker: PhotosPickerItem?
    @State private var signupCoverData: Data?
    @State private var signupMenuData: Data?
    @State private var showSignupPinPicker = false
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
            country: signupCountry,
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

    private var signupAddressLabels: BusinessLocationAddressLabels {
        BusinessLocationCountryPolicy.labels(for: signupCountry)
    }

    private var signupLocationDraft: BusinessVenueLocationDraft {
        BusinessVenueLocationDraft(
            addressLine1: signupStreet,
            addressLine2: signupAddressLine2,
            locality: signupCity,
            region: signupState,
            postalCode: signupZip,
            countryCode: signupCountry,
            latitude: signupLatitude,
            longitude: signupLongitude,
            formattedAddress: signupFormattedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : signupFormattedAddress
        )
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

            FanGeoAppleSignInButton(viewModel: viewModel, accountMode: .business)

            if !viewModel.appleAuthBusinessMessage.isEmpty {
                SettingsSheetStatusBanner(
                    title: viewModel.appleAuthBusinessMessageIsError ? "Apple Sign In" : nil,
                    message: viewModel.appleAuthBusinessMessage,
                    tint: viewModel.appleAuthBusinessMessageIsError ? FGColor.dangerRed : FGColor.accentBlue,
                    systemImage: viewModel.appleAuthBusinessMessageIsError ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.checkmark"
                )
            }

            TextField("Business email", text: $viewModel.venueOwnerEmail)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .fanGeoInputFieldStyle()

            SecureField("Business owner password", text: $venuePassword)
                .fanGeoInputFieldStyle()

            if !showVenueRegisterMode {
                Button {
#if DEBUG
                    print("[BusinessPasswordResetDebug] forgotPasswordTapped=true")
#endif
                    guard viewModel.canPresentPasswordResetRequestSheet() else {
                        showBusinessPasswordResetSheet = false
                        return
                    }
                    viewModel.venuePasswordResetMessage = ""
                    viewModel.venuePasswordResetError = ""
                    showBusinessPasswordResetSheet = true
                } label: {
                    Text("Forgot password?")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.accentBlue)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if showVenueRegisterMode {
                signupRegistrationFields
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
                            await MainActor.run {
                                viewModel.clearAppleAuthMessage(accountMode: .business, reason: "emailPasswordSignUp")
                            }
                            isSignupSubmitting = true
#if DEBUG
                            print("[BusinessSignup] set isSignupSubmitting=true")
#endif
                            let form = AddLocationClaimForm(
                                venueName: signupLocationName,
                                address: signupStreet,
                                addressLine2: signupAddressLine2,
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
                                easyParking: signupEasyParking,
                                handicapParking: signupHandicapParking,
                                liveMusic: signupLiveMusic,
                                poolTables: signupPoolTables,
                                rooftop: signupRooftop,
                                djNights: signupDJNights,
                                karaoke: signupKaraoke,
                                cocktails: signupCocktails,
                                craftBeer: signupCraftBeer,
                                coverPhotoURL: "",
                                menuPhotoURL: "",
                                latitude: signupLatitude,
                                longitude: signupLongitude,
                                formattedAddress: signupFormattedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : signupFormattedAddress
                            )
#if DEBUG
                            print("[VenueFeatureDebug] selectedFeatures=\(form.mergedVenueFeaturesLine())")
#endif
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
                            await MainActor.run {
                                viewModel.clearAppleAuthMessage(accountMode: .business, reason: "emailPasswordSignIn")
                            }
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
            viewModel.clearAppleAuthMessage(accountMode: .business, reason: "accountModeChanged")
            viewModel.venueAuthErrorMessage = ""
            viewModel.venuePasswordResetMessage = ""
            viewModel.venuePasswordResetError = ""
            if !isRegister {
                venueSignupPoliciesAccepted = false
                signupBusinessName = ""
                signupLocationName = ""
                signupStreet = ""
                signupAddressLine2 = ""
                signupCity = ""
                signupState = ""
                signupCountry = BusinessLocationCountryPolicy.defaultCountryCode
                signupZip = ""
                signupLatitude = nil
                signupLongitude = nil
                signupFormattedAddress = ""
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
                signupEasyParking = false
                signupHandicapParking = false
                signupLiveMusic = false
                signupPoolTables = false
                signupRooftop = false
                signupDJNights = false
                signupKaraoke = false
                signupCocktails = false
                signupCraftBeer = false
                signupCoverPicker = nil
                signupMenuPicker = nil
                signupCoverData = nil
                signupMenuData = nil
            }
        }
        .onChange(of: viewModel.venueOwnerEmail) { _, _ in
            viewModel.clearAppleAuthMessage(accountMode: .business, reason: "emailEdited")
        }
        .onChange(of: venuePassword) { _, _ in
            viewModel.clearAppleAuthMessage(accountMode: .business, reason: "passwordEdited")
        }
        .onDisappear {
            viewModel.clearAppleAuthMessage(accountMode: .business, reason: "sheetClosed")
        }
        .onChange(of: signupCountry) { _, newCountry in
            BusinessLocationCountryPolicy.clearDefaultRegionIfNeeded(&signupState, whenCountryChangesTo: newCountry)
#if DEBUG
            print("[InternationalAddressDebug] selectedCountry=\(BusinessLocationCountryPolicy.normalizedStoredCountryCode(newCountry))")
#endif
        }
        .sheet(isPresented: $showSignupPinPicker) {
            BusinessVenueLocationPinPickerView(
                viewModel: viewModel,
                initialDraft: signupLocationDraft,
                fallbackCoordinate: viewModel.currentUserLocation ?? CLLocationCoordinate2D(latitude: 40.3916, longitude: -111.8508),
                onCancel: {},
                onConfirm: applySignupLocationDraft
            )
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
        .sheet(isPresented: $showBusinessPasswordResetSheet) {
            SettingsBusinessPasswordResetSheet(
                viewModel: viewModel,
                isPresented: $showBusinessPasswordResetSheet
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
    }

    @ViewBuilder
    private var signupRegistrationFields: some View {
        SettingsSheetSectionLabel(title: "Business")
        TextField("Business / brand name", text: $signupBusinessName)
            .textInputAutocapitalization(.words)
            .fanGeoInputFieldStyle()

        SettingsSheetSectionLabel(title: "First location")
        TextField("Location name", text: $signupLocationName)
            .textInputAutocapitalization(.words)
            .fanGeoInputFieldStyle()

        signupAddressFields

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
            easyParking: $signupEasyParking,
            familyFriendly: $signupFamilyFriendly,
            handicapParking: $signupHandicapParking,
            liveMusic: $signupLiveMusic,
            poolTables: $signupPoolTables,
            rooftop: $signupRooftop,
            djNights: $signupDJNights,
            karaoke: $signupKaraoke,
            cocktails: $signupCocktails,
            craftBeer: $signupCraftBeer,
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

        signupPolicyAgreement
    }

    @ViewBuilder
    private var signupAddressFields: some View {
        TextField("Street address", text: $signupStreet)
            .textContentType(.streetAddressLine1)
            .fanGeoInputFieldStyle()

        TextField("Address line 2 (optional)", text: $signupAddressLine2)
            .textContentType(.streetAddressLine2)
            .fanGeoInputFieldStyle()

        TextField(signupAddressLabels.locality, text: $signupCity)
            .textInputAutocapitalization(.words)
            .fanGeoInputFieldStyle()

        HStack(alignment: .center, spacing: FGSpacing.md) {
            BusinessLocationRegionField(countryCode: signupCountry, labels: signupAddressLabels, region: $signupState)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField(signupAddressLabels.postalCode, text: $signupZip)
                .textInputAutocapitalization(.never)
                .frame(minWidth: 88, maxWidth: 120, alignment: .leading)
        }
        .fanGeoInputFieldStyle()

        BusinessLocationCountryField(countryCode: $signupCountry)
            .fanGeoInputFieldStyle()

        BusinessVenueLocationPinPreview(
            draft: signupLocationDraft,
            isLocked: false,
            onAdjust: { showSignupPinPicker = true }
        )
    }

    private var signupPolicyAgreement: some View {
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

    private func applySignupLocationDraft(_ draft: BusinessVenueLocationDraft) {
        signupStreet = draft.addressLine1
        signupAddressLine2 = draft.addressLine2
        signupCity = draft.locality
        signupState = draft.region
        signupZip = draft.postalCode
        signupCountry = BusinessLocationCountryPolicy.normalizedStoredCountryCode(draft.countryCode)
        signupLatitude = draft.latitude
        signupLongitude = draft.longitude
        signupFormattedAddress = draft.formattedAddress ?? draft.displayAddress
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

    private enum ManagedVenueSelectorStatus {
        case approved
        case locked
        case pending
        case rejected
    }

    private struct ManagedVenueSelectorRow: Identifiable {
        let id: String
        let venueID: UUID?
        let claimID: UUID?
        let title: String
        let subtitle: String
        let statusNote: String?
        let status: ManagedVenueSelectorStatus
        let venueRow: VenueProfileRow?
    }

    private struct ManagedVenueListingCounts {
        let totalVenueCount: Int
        let approvedVenueCount: Int
        let lockedVenueCount: Int
        let pendingVenueCount: Int
    }

    @ObservedObject var viewModel: MapViewModel
    @Environment(\.colorScheme) private var colorScheme
    var chrome: Chrome = .settings
    /// When set (Settings), shown as the last menu action to submit a new business location for review.
    var onRequestAddNewLocation: (() -> Void)?
    var isHydrating = false
    var hydrationReason = "ready"
    var onBlockedEarlyTap: ((String, String) -> Void)?
    @State private var showVenueListSheet = false
    @State private var isRefreshingVenueSelector = false
    @State private var venueSelectorNotice: String?

    init(
        viewModel: MapViewModel,
        chrome: Chrome = .settings,
        onRequestAddNewLocation: (() -> Void)? = nil,
        isHydrating: Bool = false,
        hydrationReason: String = "ready",
        onBlockedEarlyTap: ((String, String) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.chrome = chrome
        self.onRequestAddNewLocation = onRequestAddNewLocation
        self.isHydrating = isHydrating
        self.hydrationReason = hydrationReason
        self.onBlockedEarlyTap = onBlockedEarlyTap
    }

    private var venuePairs: [(UUID, String)] {
        var seenVenueIDs = Set<UUID>()
        return viewModel.managedVenuesForOwner().compactMap { row in
            guard let id = row.id else { return nil }
            guard managedVenueStatus(for: row) == .approved else { return nil }
            guard seenVenueIDs.insert(id).inserted else { return nil }
            let raw = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let label = raw.isEmpty ? "Location" : raw
            return (id, label)
        }
    }

    private var managedVenueSelectorRows: [ManagedVenueSelectorRow] {
        var seenApprovedVenueIDs = Set<UUID>()
        let approvedRows = viewModel.managedVenuesForOwner().compactMap { row -> ManagedVenueSelectorRow? in
            guard let id = row.id else { return nil }
            guard seenApprovedVenueIDs.insert(id).inserted else { return nil }
            return ManagedVenueSelectorRow(
                id: "venue-\(id.uuidString)",
                venueID: id,
                claimID: nil,
                title: venueDisplayName(for: row),
                subtitle: MapViewModel.venueIsPlanLocked(row)
                    ? BusinessLimitCopy.planLockedVenueSubtitle
                    : (venueLocationSubtitle(for: row).isEmpty ? "Approved location for listings, games, and analytics." : venueLocationSubtitle(for: row)),
                statusNote: MapViewModel.venueIsPlanLocked(row) ? BusinessLimitCopy.planLockedVenueSubtitle : nil,
                status: managedVenueStatus(for: row),
                venueRow: row
            )
        }
        let approvedVenueIDs = Set(approvedRows.compactMap(\.venueID))
        var seenPendingVenueIDs = Set<UUID>()
        let pendingRows = viewModel.pendingVenueClaimsForSettings.compactMap { claim -> ManagedVenueSelectorRow? in
            if let venueID = claim.venue_id, approvedVenueIDs.contains(venueID) { return nil }
            if let venueID = claim.venue_id, !seenPendingVenueIDs.insert(venueID).inserted { return nil }
            return managedVenueSelectorClaimRow(claim, status: .pending)
        }
        let rejectedRows = viewModel.rejectedVenueClaimsForSettings.compactMap { claim -> ManagedVenueSelectorRow? in
            if let venueID = claim.venue_id, approvedVenueIDs.contains(venueID) { return nil }
            return managedVenueSelectorClaimRow(claim, status: .rejected)
        }
        return approvedRows + pendingRows + rejectedRows
    }

    private var selectedVenueRow: VenueProfileRow? {
        let selectedId = viewModel.ownerVenueDatabaseId ?? venuePairs.first?.0
        guard let selectedId else { return viewModel.managedVenuesForOwner().first }
        return viewModel.managedVenuesForOwner().first(where: { $0.id == selectedId }) ?? viewModel.managedVenuesForOwner().first
    }

    private var selectedManagedVenueSelectorRow: ManagedVenueSelectorRow? {
        if let selectedId = viewModel.ownerVenueDatabaseId,
           let selected = managedVenueSelectorRows.first(where: { $0.venueID == selectedId }),
           selected.status == .approved {
            return selected
        }
        return managedVenueSelectorRows.first(where: { $0.status == .approved })
            ?? managedVenueSelectorRows.first
    }

    private var selectedVenueLabel: String {
        if isHydrating {
            return "Loading venues..."
        }
        if let selected = selectedManagedVenueSelectorRow {
            return selected.title
        }
        let id = viewModel.ownerVenueDatabaseId ?? venuePairs.first?.0
        if let id, let name = venuePairs.first(where: { $0.0 == id })?.1 {
            return name
        }
        return venuePairs.first?.1 ?? "Location"
    }

    private var inactiveVenueSelectionNotice: String {
        "This venue is inactive on the Regular plan and cannot be managed until activated by FanGeo or Business Pro."
    }

    private var selectedVenueSubtitle: String {
        if isHydrating {
            return "Business profile is loading managed venues."
        }
        if let selected = selectedManagedVenueSelectorRow {
            return selected.statusNote ?? selected.subtitle
        }
        if let row = selectedVenueRow {
            let locationLine = venueLocationSubtitle(for: row)
            if !locationLine.isEmpty {
                return locationLine
            }
        }
        if venuePairs.count > 1 {
            return "\(venuePairs.count) approved locations available to manage."
        }
        return "Approved location for listings, games, and analytics."
    }

    private func venueDisplayName(for row: VenueProfileRow) -> String {
        let raw = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Location" : raw
    }

    private func venueLocationSubtitle(for row: VenueProfileRow) -> String {
        let city = row.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let region = (row.region ?? row.state)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let country = row.country?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let locationLine = [city, region, country].filter { !$0.isEmpty }.joined(separator: ", ")
        if !locationLine.isEmpty { return locationLine }
        let formatted = row.formatted_address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !formatted.isEmpty { return formatted }
        return row.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func managedVenueStatus(for row: VenueProfileRow) -> ManagedVenueSelectorStatus {
        let raw = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw.isEmpty || raw == "active" { return .approved }
        if raw == "plan_locked" { return .locked }
        if raw.contains("pending") || raw.contains("review") { return .pending }
        if raw.contains("reject") || raw.contains("archive") { return .rejected }
        return .approved
    }

    private var managedVenueListingCounts: ManagedVenueListingCounts {
        var approvedVenueIDs = Set<UUID>()
        var lockedVenueIDs = Set<UUID>()
        var pendingVenueIDs = Set<UUID>()

        for row in viewModel.managedVenuesForOwner() {
            guard let id = row.id else { continue }
            switch managedVenueStatus(for: row) {
            case .approved:
                approvedVenueIDs.insert(id)
            case .locked:
                lockedVenueIDs.insert(id)
            case .pending:
                pendingVenueIDs.insert(id)
            case .rejected:
                continue
            }
        }

        for claim in viewModel.pendingVenueClaimsForSettings {
            guard let venueID = claim.venue_id else { continue }
            guard !approvedVenueIDs.contains(venueID) else { continue }
            pendingVenueIDs.insert(venueID)
        }

        return ManagedVenueListingCounts(
            totalVenueCount: approvedVenueIDs.union(lockedVenueIDs).union(pendingVenueIDs).count,
            approvedVenueCount: approvedVenueIDs.count,
            lockedVenueCount: lockedVenueIDs.count,
            pendingVenueCount: pendingVenueIDs.count
        )
    }

    private var dashboardVenueListingCountLine: String {
        if isHydrating {
            return "Loading venues..."
        }
        let count = managedVenueListingCounts.totalVenueCount
        return "\(count) \(count == 1 ? "managed venue" : "managed venues")"
    }

    private var dashboardVenueListingStatusLine: String {
        if isHydrating {
            return "Please wait before managing venues"
        }
        let counts = managedVenueListingCounts
        if counts.lockedVenueCount > 0 {
            return "\(counts.approvedVenueCount) active • \(counts.lockedVenueCount) locked • \(counts.pendingVenueCount) pending"
        }
        return "\(counts.approvedVenueCount) active • \(counts.pendingVenueCount) pending"
    }

    private func venueClaimLocationSubtitle(for claim: VenueClaimPendingSettingsRow) -> String {
        let city = claim.venue_city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let region = claim.venue_state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let country = claim.venue_country?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let locationLine = [city, region, country].filter { !$0.isEmpty }.joined(separator: ", ")
        if !locationLine.isEmpty { return locationLine }
        return claim.venue_address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func managedVenueSelectorClaimRow(
        _ claim: VenueClaimPendingSettingsRow,
        status: ManagedVenueSelectorStatus
    ) -> ManagedVenueSelectorRow {
        let name = claim.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = venueClaimLocationSubtitle(for: claim)
        let title = name.isEmpty ? "Submitted location" : name
        return ManagedVenueSelectorRow(
            id: "claim-\(claim.id.uuidString)-\(statusTitle(for: status))",
            venueID: claim.venue_id,
            claimID: claim.id,
            title: title,
            subtitle: location.isEmpty ? "Business location" : location,
            statusNote: status == .pending ? "Waiting for admin approval" : "Review rejected",
            status: status,
            venueRow: nil
        )
    }

    private func venueStatusTitle(for row: VenueProfileRow?) -> String? {
        let raw = row?.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw.isEmpty || raw == "active" { return "Approved" }
        if raw == "plan_locked" { return BusinessLimitCopy.planLockedVenueBadge }
        if raw.contains("pending") || raw.contains("review") { return "Pending" }
        return raw.capitalized
    }

    private func venueStatusTint(for row: VenueProfileRow?) -> Color {
        let raw = row?.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw.isEmpty || raw == "active" { return FGColor.accentGreen }
        if raw == "plan_locked" { return .orange }
        if raw.contains("pending") || raw.contains("review") { return FGColor.accentYellow }
        if raw.contains("reject") || raw.contains("archive") { return FGColor.dangerRed }
        return FGColor.accentBlue
    }

    private func statusTitle(for status: ManagedVenueSelectorStatus) -> String {
        switch status {
        case .approved:
            return "Approved"
        case .locked:
            return BusinessLimitCopy.planLockedVenueBadge
        case .pending:
            return "Pending"
        case .rejected:
            return "Rejected"
        }
    }

    private func statusTint(for status: ManagedVenueSelectorStatus) -> Color {
        switch status {
        case .approved:
            return FGColor.accentGreen
        case .locked:
            return .orange
        case .pending:
            return .orange
        case .rejected:
            return FGColor.dangerRed
        }
    }

    private func blockHydratingTap(action: String) -> Bool {
        guard isHydrating else { return false }
        onBlockedEarlyTap?(action, hydrationReason)
        return true
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
                guard !blockHydratingTap(action: "viewingVenueSelector") else { return }
                Task {
                    await viewModel.selectManagedVenue(id: pair.0)
#if DEBUG
                    print("[BusinessManagedVenueTapDebug] selectedVenueUpdated venueId=\(pair.0.uuidString.lowercased())")
#endif
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
            showsApprovedBadge: selectedManagedVenueSelectorRow?.status == .approved,
            chevronSystemName: "chevron.up.chevron.down"
        )
    }

    @ViewBuilder
    private func settingsChromePickerStack() -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.xs) {
            Text(settingsPickerLabel)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            if isHydrating {
                settingsPickerRowLabel(
                    title: "Loading venues...",
                    subtitle: "Business profile is loading managed venues.",
                    systemImage: "hourglass",
                    tint: FGColor.mutedText(colorScheme),
                    showsApprovedBadge: false,
                    chevronSystemName: "chevron.right"
                )
                .opacity(0.72)
                .allowsHitTesting(false)
            } else if venuePairs.isEmpty, onRequestAddNewLocation == nil {
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

    private func managedVenueStatusBadge(row: VenueProfileRow?) -> some View {
        let tint = venueStatusTint(for: row)
        return Text(venueStatusTitle(for: row) ?? "Approved")
            .font(FGTypography.metadata.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            .clipShape(Capsule(style: .continuous))
    }

    private func managedVenueStatusBadge(status: ManagedVenueSelectorStatus) -> some View {
        let tint = statusTint(for: status)
        return Text(statusTitle(for: status))
            .font(FGTypography.metadata.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            .clipShape(Capsule(style: .continuous))
    }

    private var dashboardChromeSelectorButton: some View {
        Button {
            guard !blockHydratingTap(action: "viewingVenueSelector") else { return }
#if DEBUG
            print("[BusinessVenueSelectorDebug] selectorTapped=true")
#endif
            showVenueListSheet = true
        } label: {
            HStack(alignment: .center, spacing: FGSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.20 : 0.12))
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(FGColor.accentBlue)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Viewing venue")
                        .font(FGTypography.metadata.weight(.bold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .textCase(.uppercase)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(selectedVenueLabel)
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        managedVenueStatusBadge(status: selectedManagedVenueSelectorRow?.status ?? .approved)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(dashboardVenueListingCountLine)
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)

                        Text(dashboardVenueListingStatusLine)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isHydrating ? "hourglass" : "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
            .padding(FGSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(FGAdaptiveSurface.cardElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(FGColor.divider(colorScheme).opacity(0.65), lineWidth: 1)
                    }
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08), radius: 18, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .opacity(isHydrating ? 0.62 : 1)
        .onAppear {
#if DEBUG
            print("[BusinessVenueSelectorDebug] selectorVisible=true")
#endif
        }
    }

    private var dashboardVenueListSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let venueSelectorNotice {
                        managedVenueSelectorStatusBanner(venueSelectorNotice)
                    }
                    if viewModel.managedVenuesContainPlanLocked() {
                        managedVenueSelectorStatusBanner(BusinessLimitCopy.planLockedVenueBanner)
                    }

                    ForEach(managedVenueSelectorRows) { row in
                        managedVenueSheetRow(row)
                    }

                    if onRequestAddNewLocation != nil {
                        Divider()
                            .padding(.vertical, 4)
                        addNewVenueSheetButton
                    }
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, FGSpacing.md)
                .padding(.bottom, FGSpacing.xl)
            }
            .navigationTitle("Managed venues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task {
                            await refreshManagedVenueSelector()
                        }
                    } label: {
                        Label(isRefreshingVenueSelector ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshingVenueSelector)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showVenueListSheet = false
                    }
                }
            }
            .fanGeoScreenBackground()
            .onAppear {
#if DEBUG
                print("[BusinessVenueSelectorDebug] pendingVenuesVisible count=\(viewModel.pendingVenueClaimsForSettings.count)")
#endif
            }
        }
    }

    private func managedVenueSelectorStatusBanner(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isRefreshingVenueSelector ? "arrow.clockwise" : "info.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isRefreshingVenueSelector ? FGColor.accentBlue : .orange)
            Text(message)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .background((isRefreshingVenueSelector ? FGColor.accentBlue : Color.orange).opacity(colorScheme == .dark ? 0.14 : 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func managedVenueSheetRow(_ row: ManagedVenueSelectorRow) -> some View {
        let isSelected = row.status == .approved && row.venueID == viewModel.ownerVenueDatabaseId
        let tint = statusTint(for: row.status)
        return Button {
            guard !blockHydratingTap(action: "viewingVenueSelector") else { return }
            logBusinessManagedVenueTapDebug("tapped", row: row)
            guard let id = row.venueID else {
                if row.status == .pending {
                    venueSelectorNotice = "This venue is waiting for admin approval."
#if DEBUG
                    print("[BusinessVenueSelectorDebug] pendingVenueTapped id=\(row.claimID?.uuidString ?? row.venueID?.uuidString ?? "nil")")
#endif
                } else {
                    venueSelectorNotice = "This venue request was rejected."
                }
                return
            }

            if row.status == .locked {
                venueSelectorNotice = inactiveVenueSelectionNotice
                logBusinessManagedVenueTapDebug("ignoredInactiveVenue", row: row, venueId: id)
                return
            }

            guard row.status == .approved else {
                venueSelectorNotice = row.status == .pending
                    ? "This venue is waiting for admin approval."
                    : "This venue request was rejected."
                return
            }

            showVenueListSheet = false
            Task {
                await viewModel.selectManagedVenue(id: id)
#if DEBUG
                print("[BusinessManagedVenueTapDebug] selectedVenueUpdated venueId=\(id.uuidString.lowercased())")
#endif
            }
        } label: {
            HStack(spacing: FGSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                        .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    Image(systemName: "building.2")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.title)
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                        managedVenueStatusBadge(status: row.status)
                    }

                    Text(row.subtitle)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)

                    if let note = row.statusNote {
                        Text(note)
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(FGColor.accentGreen)
                }
            }
            .padding(FGSpacing.md)
            .background(FGAdaptiveSurface.cardElevated)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func logBusinessManagedVenueTapDebug(
        _ event: String,
        row: ManagedVenueSelectorRow,
        venueId explicitVenueId: UUID? = nil
    ) {
#if DEBUG
        let venueId = explicitVenueId ?? row.venueID
        let venueName = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = statusTitle(for: row.status)
        if event == "tapped" {
            print("[BusinessManagedVenueTapDebug] tapped venueId=\(venueId?.uuidString.lowercased() ?? "nil") venueName=\(venueName.isEmpty ? "nil" : venueName) status=\(status)")
        } else if event == "ignoredInactiveVenue" {
            print("[BusinessManagedVenueTapDebug] ignoredInactiveVenue venueId=\(venueId?.uuidString.lowercased() ?? "nil")")
        }
#endif
    }

    private func refreshManagedVenueSelector() async {
        let shouldRefresh = await MainActor.run { () -> Bool in
            guard !isRefreshingVenueSelector else { return false }
            isRefreshingVenueSelector = true
            venueSelectorNotice = "Refreshing managed venues..."
#if DEBUG
            print("[BusinessVenueSelectorDebug] refreshTapped=true")
#endif
            return true
        }
        guard shouldRefresh else { return }

        await viewModel.refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        await viewModel.refreshPendingVenueClaimsForSettings()
        await viewModel.refreshVenueClaimStatusLineFromDatabase()

        await MainActor.run {
            isRefreshingVenueSelector = false
            venueSelectorNotice = "Managed venues refreshed."
#if DEBUG
            print("[BusinessVenueSelectorDebug] refreshCompleted=true")
            print("[BusinessVenueSelectorDebug] pendingVenuesVisible count=\(viewModel.pendingVenueClaimsForSettings.count)")
#endif
        }
    }

    private var addNewVenueSheetButton: some View {
        Button {
#if DEBUG
            print("[BusinessVenueSelectorDebug] addVenueTapped=true")
#endif
            showVenueListSheet = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                onRequestAddNewLocation?()
            }
        } label: {
            HStack(spacing: FGSpacing.md) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FGColor.accentBlue)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Add New Venue")
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Add Location")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                Spacer(minLength: 0)
            }
            .padding(FGSpacing.md)
            .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
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
            if isHydrating {
                switch chrome {
                case .settings:
                    settingsChromePickerStack()
                case .dashboard:
                    dashboardChromeSelectorButton
                }
            } else if venuePairs.isEmpty && managedVenueSelectorRows.isEmpty {
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
                    dashboardChromeSelectorButton
                }
            }
        }
        .sheet(isPresented: $showVenueListSheet) {
            dashboardVenueListSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .onAppear { logPickerDebug() }
        .onChange(of: viewModel.ownerVenueDatabaseId) { _, _ in
            logPickerDebug()
        }
        .onChange(of: isHydrating) { _, hydrating in
            if hydrating {
                showVenueListSheet = false
            }
        }
    }
}

// MARK: - Venue owner sign-out
// Account-tab business log out uses ``MapViewModel/logoutUser()`` (full Supabase sign-out + session cleanup).
// ``MapViewModel/venueOwnerLocalSignOutPreservingSupabaseSession()`` remains for flows that must keep the auth session while clearing owner UI.
