import CoreLocation
import CryptoKit
import Photos
import PhotosUI
import SwiftUI

@MainActor
enum ProfilePhase1PersonalizationCache {
    static let ttlSeconds: TimeInterval = 600

    static var incomingPokesLoadedAtByAuthId: [UUID: Date] = [:]
    static var suggestedFansLoadedAtByAuthId: [UUID: Date] = [:]

    static func clear(for authId: UUID?) {
        guard let authId else {
            incomingPokesLoadedAtByAuthId.removeAll()
            suggestedFansLoadedAtByAuthId.removeAll()
            return
        }
        incomingPokesLoadedAtByAuthId.removeValue(forKey: authId)
        suggestedFansLoadedAtByAuthId.removeValue(forKey: authId)
    }
}

private enum ProfileAvatarRefreshToken {
#if DEBUG
    private static var loggedMaterials: Set<String> = []
#endif

    static func stable(
        userId: UUID,
        thumbnailURL: String?,
        avatarURL: String?,
        versionSuffix: String = ""
    ) -> UUID {
        let material = "\(userId.uuidString.lowercased())|\(thumbnailURL ?? "")|\(avatarURL ?? "")|\(versionSuffix)"
        let digest = Insecure.MD5.hash(data: Data(material.utf8))
        let token = digest.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UUID(
                uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                )
            )
        }
#if DEBUG
        if loggedMaterials.insert(material).inserted {
            print("[PerfPhase1] avatarTokenStable userId=\(userId.uuidString.lowercased())")
        }
#endif
        return token
    }
}

/// Unified Account-tab “Profile & Identity” card: compact profile, reputation, and favorite teams in one surface.
struct ProfileIdentityCard: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject private var fanUpdatesStore: FanUpdatesRealtimeStore
    /// When false, Pokes / Suggested Fans loads wait until the Account tab is selected.
    var isAccountTabActive: Bool = true
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedIdentityField: IdentityField?

    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage(FavoriteTeamsStore.appStorageKey) private var favoriteTeamIDsRaw: String = ""
    @AppStorage(FavoriteTeamsStore.primaryTeamIDAppStorageKey) private var primaryFavoriteTeamIDRaw: String = ""
    @State private var showFavoriteTeamsPicker = false
    @State private var showNationalTeamPicker = false
    @State private var showHandleSetup = false
    @State private var showIdentityEditor = false
    @State private var showFanIdentityEditor = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var editedDisplayName = ""
    @State private var editedUsername = ""
    @State private var editedBio = ""
    @State private var identityMessage = ""
    @State private var handleStatusMessage = ""
    @State private var handleStatusIsPositive = false
    @State private var availabilityTask: Task<Void, Never>?
    @State private var isSavingIdentity = false
    @State private var isUploadingAvatar = false
    @State private var incomingPokes: [ProfilePokeIncomingItem] = []
    @State private var incomingPokeTotalCount = 0
    @State private var isLoadingIncomingPokes = false
    @State private var isClearingAllPokes = false
    @State private var incomingPokesMessage: String?
    @State private var showPokesHistorySheet = false
    @State private var showClearAllPokesConfirmation = false
    @State private var suggestedFans: [FriendSuggestionProfile] = []
    @State private var isLoadingSuggestedFans = false
    @State private var suggestedFansMessage: String?
    @State private var sendingSuggestedFanRequestIds: Set<UUID> = []
    @State private var profileStatsCounts: ProfileStatsCounts?
    @State private var animatedTrophyTeamID: String?
    @State private var demotedTrophyTeamID: String?
    @State private var trophyShimmerProgress: CGFloat = -0.6
    @State private var trophyAnimationTask: Task<Void, Never>?

    private static let bioCharacterLimit = 160
    private static let incomingPokesHighlightsLimit = 50
    private static let suggestedFansDisplayLimit = 10
    private static let suggestedFansFetchLimit = 30
    private static let incomingPokesLiveRefreshIntervalSeconds = 20
    private static let incomingPokesLiveRefreshIntervalNs: UInt64 =
        UInt64(incomingPokesLiveRefreshIntervalSeconds) * 1_000_000_000
    private static let favoriteTeamsCarouselHeight: CGFloat = 178
    private static let favoriteTeamsHomeCrowdBottomSpacing: CGFloat = 8
    private static let profileMajorSectionSpacing: CGFloat = 22

    private let profilePokesService = ProfilePokesService()
    private let friendSuggestionsService = FriendSuggestionsService()

    private enum ProfileSectionHierarchy {
        case hero
        case primary
        case secondary
        case utility
    }

    private enum IdentityField: Hashable {
        case displayName
        case username
        case bio
    }

    init(viewModel: MapViewModel, isAccountTabActive: Bool = true) {
        self.isAccountTabActive = isAccountTabActive
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _fanUpdatesStore = ObservedObject(wrappedValue: viewModel.fanUpdatesStore)
    }

    private var profilePersonalizationLoadToken: String {
        let auth = viewModel.currentUserAuthId?.uuidString ?? "anonymous"
        return "\(auth)|active=\(isAccountTabActive)"
    }

    private var pokesLiveRefreshLoopToken: String {
        let auth = viewModel.currentUserAuthId?.uuidString ?? "anonymous"
        return "\(auth)|pokesLive=\(isAccountTabActive)"
    }

    private var profileStatsLoadToken: String {
        let auth = viewModel.currentUserAuthId?.uuidString ?? "anonymous"
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let teams = FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw).sorted().joined(separator: ",")
        return "\(auth)|\(email)|teams=\(teams)|active=\(isAccountTabActive)"
    }

    private var selectedTeams: [FavoriteTeam] {
        FavoriteTeamsStore.resolvedTeams(from: favoriteTeamIDsRaw)
    }

    private var selectedIDSet: Set<String> {
        Set(FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw))
    }

    private var selectedTeamIDs: [String] {
        FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw)
    }

    private var primaryFavoriteTeamID: String? {
        FavoriteTeamsStore.normalizedPrimaryTeamID(primaryFavoriteTeamIDRaw, within: selectedTeamIDs)
    }

    private var primaryFavoriteTeam: FavoriteTeam? {
        guard let primaryFavoriteTeamID else { return nil }
        return selectedTeams.first { $0.id == primaryFavoriteTeamID }
    }

    private var displayName: String {
        let current = viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        guard !local.isEmpty else { return "Fan" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    /// Persisted @handle, or temporary email-prefix fallback only (never saved as username).
    private var handleLine: String {
        viewModel.currentUserPublicHandleLine
    }

    private var bioLine: String {
        viewModel.currentUserBio.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var fanXP: FanXPState {
        viewModel.currentUserFanXP
    }

    private var reputation: FanReputationProfile {
        FanReputationEngine.evaluate(
            FanReputationSignals(
                fanXP: fanXP,
                favoriteTeams: selectedTeams,
                localContext: localContext,
                savedVenueCount: savedVenueCount,
                venuePlanCount: viewModel.followingTabGoingItems.count,
                pickupHostedCount: viewModel.myPickupGamesForSettings.count + viewModel.myRemovedPickupGamesForSettings.count,
                pickupJoinedCount: viewModel.myPickupGameJoinRequestCards.count,
                organizerStats: currentOrganizerStats,
                commentCount: locallyLoadedCommentCount,
                reactionCount: locallyLoadedReactionCount
            ),
            shouldLog: false
        )
    }

    private var currentOrganizerStats: PickupCreatorPublicRatingStats? {
        guard let uid = viewModel.currentUserAuthId else { return nil }
        return viewModel.pickupCreatorTrustStats(for: uid)
    }

    private var localContext: String? {
        FanReputationEngine.localContext(
            latitude: viewModel.currentUserLocation?.latitude,
            longitude: viewModel.currentUserLocation?.longitude
        )
    }

    private var locallyLoadedCommentCount: Int {
        fanUpdatesStore.venueEventComments.values.reduce(0) { $0 + $1.count }
    }

    private var locallyLoadedReactionCount: Int {
        fanUpdatesStore.venueEventVibeCounts.values.reduce(0) { total, counts in
            total + counts.values.reduce(0, +)
        }
    }

    private var savedVenueCount: Int {
        max(viewModel.favoriteVenueIDs.count, viewModel.followingTabSavedVenues.count)
    }

    private func logFanUpdatesStoreMigrationDebug() {
#if DEBUG
        print("[FanUpdatesStoreMigrationDebug] ProfileIdentityReadsStore=true")
#endif
    }

    private func loadProfileStatsIfNeeded() async {
        guard isAccountTabActive, let userId = viewModel.currentUserAuthId else { return }
        let email = await viewModel.strictNormalizedSessionEmailForSocialTables()
            ?? viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let counts = await ProfileStatsService.shared.loadStats(
            userId: userId,
            userEmail: email,
            forceRefresh: false
        )
        await MainActor.run {
            profileStatsCounts = counts
#if DEBUG
            print("[ProfileStatsDebug] pickupGamesCount=\(counts.pickupGamesCount)")
            print("[ProfileStatsDebug] venueGamesCount=\(counts.venueGamesCount)")
            print("[ProfileStatsDebug] favoriteTeamsCount=\(counts.favoriteTeamsCount)")
            print("[ProfileStatsDebug] friendsCount=\(counts.friendsCount)")
#endif
        }
    }

    private var canShowOwnerPokesHighlights: Bool {
        viewModel.isLoggedIn && viewModel.currentUserAuthId != nil
    }

    private var canShowSuggestedFans: Bool {
        viewModel.isLoggedIn && viewModel.currentUserAuthId != nil
    }

    private var shouldBlockFanIdentityCardForBusiness: Bool {
        viewModel.venueOwnerMode || viewModel.isVenueOwnerLoggedIn || viewModel.currentUserIsBusinessAccount
    }

    var body: some View {
        let _: Void = logFanUpdatesStoreMigrationDebug()

        if shouldBlockFanIdentityCardForBusiness {
            EmptyView()
                .onAppear {
#if DEBUG
                    print("[BusinessDashboardCleanup] FAN_LEVEL_CARD_BLOCKED_FOR_BUSINESS")
#endif
                }
        } else {
            VStack(alignment: .leading, spacing: Self.profileMajorSectionSpacing) {
                if viewModel.needsFanHandleSelection && !viewModel.needsBlockingFanIdentitySetup {
                    handlePromptBanner
                        .padding(.horizontal, 16)
                }

                profileSectionContainer(.hero) {
                    heroBlock
                }

                profileSectionContainer(.primary) {
                    nationalTeamSection
                }

                if canShowOwnerPokesHighlights {
                    profileSectionContainer(.utility) {
                        pokesHighlightsSection
                    }
                }

                profileSectionContainer(.primary) {
                    favoriteTeamsSection
                }

                if canShowSuggestedFans {
                    profileSectionContainer(.secondary) {
                        suggestedFansSection
                    }
                }

                profileSectionContainer(.secondary) {
                    homeCrowdSection
                }

                profileSectionContainer(.secondary) {
                    openToPreviewSection
                }
                .padding(.bottom, 16)
            }
            .padding(.top, 14)
            .background(cardShellBackground)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(cardBorder)
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 22, y: 12)
            .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.035 : 0.055), radius: 18, y: 3)
            .onAppear {
#if DEBUG
                print("[ProfileIdentityCardDebug] layout=modern_light_social_profile")
                print("[ProfileBioDebug] identityCardDisplayedBio=\(bioLine)")
                print("[ProfileHierarchyDebug] sectionSpacingApplied=\(Int(Self.profileMajorSectionSpacing))")
                print("[ProfileHierarchyDebug] cardElevationUpdated=true")
                print("[ProfileHierarchyDebug] sectionGroupingEnabled=true")
#endif
                DebugLogGate.debug("[PokesConsolidation] propsUIRemoved")
                DebugLogGate.debug("[PokesConsolidation] primarySocialSurface=pokes")
                FanReputationEngine.log(reputation)
            }
            .onChange(of: viewModel.currentUserBio) { _, newValue in
#if DEBUG
                print("[ProfileBioDebug] identityCardDisplayedBio=\(newValue.trimmingCharacters(in: .whitespacesAndNewlines))")
#endif
            }
            .sheet(isPresented: $showHandleSetup) {
                FanGeoIdentitySetupView(viewModel: viewModel, mode: .handleOnly)
            }
            .sheet(isPresented: $showIdentityEditor) {
                identityEditorSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showFanIdentityEditor) {
                FanIdentityPreferencesEditorView(viewModel: viewModel)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .task {
                await viewModel.loadFanIdentityPreferencesFromProfile()
            }
            .task(id: profileStatsLoadToken) {
                await loadProfileStatsIfNeeded()
            }
            .sheet(isPresented: $showFavoriteTeamsPicker) {
                FavoriteTeamsPickerSheet(
                    selectedIDs: Binding(
                        get: { selectedIDSet },
                        set: { newSet in
                            let sorted = Array(newSet).sorted()
                            let nextPrimary = FavoriteTeamsStore.normalizedPrimaryTeamID(primaryFavoriteTeamIDRaw, within: sorted)
                            favoriteTeamIDsRaw = FavoriteTeamsStore.encodeIDs(sorted)
                            primaryFavoriteTeamIDRaw = nextPrimary ?? ""
                            Task {
                                await viewModel.syncFavoriteTeamsToSupabase(teamIDs: sorted, primaryTeamID: nextPrimary)
                            }
                        }
                    )
                )
            }
            .sheet(isPresented: $showNationalTeamPicker) {
                NationalTeamPickerSheet(currentIdentity: viewModel.currentUserNationalTeam) { identity in
                    Task { await saveNationalTeamIdentity(identity) }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showPokesHistorySheet) {
                pokesHistorySheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: showPokesHistorySheet) { _, isPresented in
                if isPresented {
                    DebugLogGate.debug("[PokesUI] history opened")
                    viewModel.acknowledgeIncomingPokes(reason: "pokesHistorySheet")
                }
            }
            .task(id: profilePersonalizationLoadToken) {
                guard isAccountTabActive else {
#if DEBUG
                    print("[PerfPhase1C] profileLoadDeferred reason=accountTabHidden")
#endif
                    return
                }
#if DEBUG
                print("[PerfPhase1C] profileLoadStarted reason=accountTabVisible")
#endif
                await refreshIncomingPokesLive(reason: "accountVisible")
                await loadSuggestedFans()
            }
            .task(id: pokesLiveRefreshLoopToken) {
                guard isAccountTabActive else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: Self.incomingPokesLiveRefreshIntervalNs)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled, isAccountTabActive else { return }
                    await refreshIncomingPokesLive(reason: "slowInterval")
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, isAccountTabActive else { return }
                Task {
                    await refreshIncomingPokesLive(reason: "foreground")
                }
            }
            .onChange(of: selectedAvatarItem) { _, item in
                guard let item else { return }
                Task { await replaceAvatar(with: item) }
            }
            .onChange(of: editedUsername) { _, newValue in
                let normalized = FanGeoHandleRules.normalizeForStorage(newValue)
                if normalized != newValue {
                    editedUsername = normalized
                    return
                }
                scheduleHandleAvailabilityCheck()
            }
            .onChange(of: editedBio) { _, newValue in
                let limited = limitedBio(newValue)
                if limited != newValue {
                    editedBio = limited
                }
            }
        }
    }

    // MARK: - Shell

    private var cardShellBackground: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.96),
                    Color(red: 0.94, green: 0.98, blue: 1.0).opacity(colorScheme == .dark ? 0.05 : 0.72),
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.035 : 0.055)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.10 : 0.92),
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.12),
                        Color.black.opacity(colorScheme == .dark ? 0.02 : 0.055)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
            )
    }

    private func profileSectionContainer<Content: View>(
        _ hierarchy: ProfileSectionHierarchy,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(profileSectionInnerPadding(for: hierarchy))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(profileSectionBackground(for: hierarchy))
            .clipShape(RoundedRectangle(cornerRadius: profileSectionCornerRadius(for: hierarchy), style: .continuous))
            .overlay(profileSectionBorder(for: hierarchy))
            .shadow(
                color: profileSectionShadowColor(for: hierarchy),
                radius: profileSectionShadowRadius(for: hierarchy),
                x: 0,
                y: profileSectionShadowYOffset(for: hierarchy)
            )
            .padding(.horizontal, 16)
    }

    private func profileSectionInnerPadding(for hierarchy: ProfileSectionHierarchy) -> EdgeInsets {
        switch hierarchy {
        case .hero:
            EdgeInsets(top: 0, leading: 0, bottom: 16, trailing: 0)
        case .primary:
            EdgeInsets(top: 16, leading: 14, bottom: 16, trailing: 14)
        case .secondary:
            EdgeInsets(top: 14, leading: 13, bottom: 14, trailing: 13)
        case .utility:
            EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        }
    }

    private func profileSectionCornerRadius(for hierarchy: ProfileSectionHierarchy) -> CGFloat {
        switch hierarchy {
        case .hero:
            26
        case .primary:
            24
        case .secondary, .utility:
            22
        }
    }

    private func profileSectionBackground(for hierarchy: ProfileSectionHierarchy) -> some View {
        RoundedRectangle(cornerRadius: profileSectionCornerRadius(for: hierarchy), style: .continuous)
            .fill(
                LinearGradient(
                    colors: profileSectionBackgroundColors(for: hierarchy),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private func profileSectionBorder(for hierarchy: ProfileSectionHierarchy) -> some View {
        RoundedRectangle(cornerRadius: profileSectionCornerRadius(for: hierarchy), style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: profileSectionBorderColors(for: hierarchy),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: profileSectionBorderWidth(for: hierarchy)
            )
    }

    private func profileSectionBackgroundColors(for hierarchy: ProfileSectionHierarchy) -> [Color] {
        switch hierarchy {
        case .hero:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.085 : 0.98),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.075 : 0.070),
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.045 : 0.050)
            ]
        case .primary:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.075 : 0.96),
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.060 : 0.055),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.050 : 0.045)
            ]
        case .secondary:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.050 : 0.88),
                Color.white.opacity(colorScheme == .dark ? 0.030 : 0.64),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.035 : 0.030)
            ]
        case .utility:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.040 : 0.80),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.035 : 0.032)
            ]
        }
    }

    private func profileSectionBorderColors(for hierarchy: ProfileSectionHierarchy) -> [Color] {
        switch hierarchy {
        case .hero:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.13 : 0.92),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.18),
                Color.black.opacity(colorScheme == .dark ? 0.04 : 0.08)
            ]
        case .primary:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.86),
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.17),
                Color.black.opacity(colorScheme == .dark ? 0.03 : 0.065)
            ]
        case .secondary:
            return [
                Color.white.opacity(colorScheme == .dark ? 0.075 : 0.72),
                Color.black.opacity(colorScheme == .dark ? 0.025 : 0.055)
            ]
        case .utility:
            return [
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.10),
                Color.black.opacity(colorScheme == .dark ? 0.02 : 0.05)
            ]
        }
    }

    private func profileSectionBorderWidth(for hierarchy: ProfileSectionHierarchy) -> CGFloat {
        switch hierarchy {
        case .hero, .primary:
            1
        case .secondary, .utility:
            0.85
        }
    }

    private func profileSectionShadowColor(for hierarchy: ProfileSectionHierarchy) -> Color {
        switch hierarchy {
        case .hero:
            return Color.black.opacity(colorScheme == .dark ? 0.26 : 0.075)
        case .primary:
            return FGColor.accentBlue.opacity(colorScheme == .dark ? 0.13 : 0.075)
        case .secondary:
            return Color.black.opacity(colorScheme == .dark ? 0.14 : 0.040)
        case .utility:
            return FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.035)
        }
    }

    private func profileSectionShadowRadius(for hierarchy: ProfileSectionHierarchy) -> CGFloat {
        switch hierarchy {
        case .hero:
            20
        case .primary:
            16
        case .secondary:
            10
        case .utility:
            8
        }
    }

    private func profileSectionShadowYOffset(for hierarchy: ProfileSectionHierarchy) -> CGFloat {
        switch hierarchy {
        case .hero:
            10
        case .primary:
            8
        case .secondary:
            5
        case .utility:
            3
        }
    }

    // MARK: - Pokes highlights

    @ViewBuilder
    private var pokesHighlightsSection: some View {
        let _ = logPokeCompactRowState()
        if shouldShowCompactPokesRow {
            Button {
#if DEBUG
                print("[PokeUIFlowDebug] openingFullPokeSheet=true")
#endif
                showPokesHistorySheet = true
            } label: {
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        compactPokesAvatarStack
                        Image(systemName: "hand.wave.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 19, height: 19)
                            .background(Circle().fill(FGColor.accentBlue))
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.92), lineWidth: 1)
                            }
                            .offset(x: 2, y: 2)
                            .pokesUnseenWaveIconEmphasis(isActive: viewModel.hasUnseenPokes)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(compactPokesSummaryCopy)
                                .font(.system(size: 13, weight: .heavy, design: .rounded))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .lineLimit(1)

                            if viewModel.hasUnseenPokes {
                                Text("New")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule(style: .continuous).fill(FGColor.accentBlue))
                                    .pokesUnseenNewPillEmphasis(isActive: true)
                            }
                        }
                        .pokesUnseenTitleRowEmphasis(isActive: viewModel.hasUnseenPokes)

                        Text("Tap for full poke history")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.74))
                }
                .padding(.horizontal, 12)
                .frame(height: 64)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    pokesHighlightsCardBackground
                }
                .pokesUnseenHighlightsEmphasis(isActive: viewModel.hasUnseenPokes)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pokesHighlightsAccessibilityLabel)
            .accessibilityHint("Opens Pokes history")
        }
    }

    private var pokesHighlightsCardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.07 : 0.96),
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.09),
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.04 : 0.045)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.16),
                                Color.white.opacity(colorScheme == .dark ? 0.06 : 0.78)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
    }

    private var compactPokesAvatarStack: some View {
        ZStack {
            if uniqueRecentPokersForAvatars.isEmpty {
                Circle()
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: "hand.wave.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.9), lineWidth: 1)
                    }
            } else {
                let visiblePokers = Array(uniqueRecentPokersForAvatars.prefix(4))
                ZStack(alignment: .leading) {
                    ForEach(Array(visiblePokers.enumerated()), id: \.element.id) { index, poke in
                        pokesAvatar(poke)
                            .offset(x: CGFloat(index) * 15)
                            .zIndex(Double(visiblePokers.count - index))
                    }
                }
                .frame(width: CGFloat(visiblePokers.count - 1) * 15 + 30, height: 34, alignment: .leading)
            }
        }
        .frame(width: 74, alignment: .leading)
    }

    private var uniqueRecentPokersForAvatars: [ProfilePokeIncomingItem] {
        var seen = Set<UUID>()
        var ordered: [ProfilePokeIncomingItem] = []
        for poke in incomingPokes {
            if seen.insert(poke.pokerUserId).inserted {
                ordered.append(poke)
            }
        }
        return ordered
    }

    private func pokesAvatar(_ poke: ProfilePokeIncomingItem) -> some View {
        UserAvatarView(
            avatarThumbnailURL: poke.pokerAvatarThumbnailURL,
            avatarURL: poke.pokerAvatarURL ?? "",
            avatarDisplayRefreshToken: ProfileAvatarRefreshToken.stable(
                userId: poke.pokerUserId,
                thumbnailURL: poke.pokerAvatarThumbnailURL,
                avatarURL: poke.pokerAvatarURL,
                versionSuffix: poke.createdAt ?? ""
            ),
            displayName: poke.pokerDisplayName,
            email: "",
            size: 30,
            fallbackStyle: .lightOnWhiteChrome,
            imagePlaceholderTint: FGColor.accentBlue
        )
        .overlay {
            Circle()
                .strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 4, y: 2)
    }

    private var shouldShowCompactPokesRow: Bool {
        incomingPokeTotalCount > 0
    }

    private var compactPokesSummaryCopy: String {
        let count = incomingPokeTotalCount
        guard count > 0 else { return "" }
        let firstName = uniqueRecentPokersForAvatars.first?.pokerDisplayName
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstName.isEmpty {
            if count == 1 {
                return "\(firstName) poked you"
            }
            return "\(firstName) and \(count - 1) \(count == 2 ? "other" : "others") poked you"
        }
        if count == 1 {
            return "1 recent poke"
        }
        return "\(count) recent pokes"
    }

    private var pokesHighlightsAccessibilityLabel: String {
        "Pokes, \(compactPokesSummaryCopy)"
    }

    private func logPokeCompactRowState() {
#if DEBUG
        print("[PokeUIFlowDebug] compactRowVisible=\(shouldShowCompactPokesRow)")
        print("[PokeUIFlowDebug] pokeCount=\(incomingPokeTotalCount)")
        if !shouldShowCompactPokesRow {
            print("[PokeUIFlowDebug] emptyPokesHidden=true")
        }
#endif
    }

    private var pokesHistorySheet: some View {
        NavigationStack {
            Group {
                if isLoadingIncomingPokes && incomingPokes.isEmpty {
                    ProgressView("Loading Pokes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if incomingPokes.isEmpty {
                    ContentUnavailableView(
                        "No pokes yet",
                        systemImage: "hand.wave.fill",
                        description: Text("When fans poke you, they’ll appear here.")
                    )
                } else {
                    List(incomingPokes) { poke in
                        Button {
                            viewModel.presentPublicProfile(
                                userId: poke.pokerUserId,
                                context: "pokes_history",
                                activeSheet: "Pokes"
                            )
                        } label: {
                            pokesHistoryRow(poke)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Pokes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showPokesHistorySheet = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
#if DEBUG
                            print("[FanPokesDebug] clearAllTapped=true")
#endif
                            showClearAllPokesConfirmation = true
                        } label: {
                            Text("Clear")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                        }
                        .disabled(incomingPokes.isEmpty || isLoadingIncomingPokes || isClearingAllPokes)
                        .foregroundStyle(FGColor.dangerRed)
                        .accessibilityLabel("Clear all Pokes")

                        Button {
                            Task { await forceRefreshIncomingPokes() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isLoadingIncomingPokes || isClearingAllPokes)
                        .accessibilityLabel("Refresh Pokes")
                    }
                }
            }
            .alert("Clear all pokes?", isPresented: $showClearAllPokesConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear All", role: .destructive) {
#if DEBUG
                    print("[FanPokesDebug] clearAllConfirmed=true")
#endif
                    Task { await clearAllIncomingPokes() }
                }
            } message: {
                Text("This will remove all pokes from your list. This can’t be undone.")
            }
            .task {
                await forceRefreshIncomingPokes()
            }
            .refreshable {
                await forceRefreshIncomingPokes()
            }
        }
    }

    private func pokesHistoryRow(_ poke: ProfilePokeIncomingItem) -> some View {
        HStack(spacing: 12) {
            UserAvatarView(
                avatarThumbnailURL: poke.pokerAvatarThumbnailURL,
                avatarURL: poke.pokerAvatarURL ?? "",
                avatarDisplayRefreshToken: ProfileAvatarRefreshToken.stable(
                    userId: poke.pokerUserId,
                    thumbnailURL: poke.pokerAvatarThumbnailURL,
                    avatarURL: poke.pokerAvatarURL,
                    versionSuffix: poke.createdAt ?? ""
                ),
                displayName: poke.pokerDisplayName,
                email: "",
                size: 42,
                fallbackStyle: .lightOnWhiteChrome
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(poke.pokerDisplayName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)

                if !poke.publicHandleLine.isEmpty {
                    Text(poke.publicHandleLine)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(poke.relativePokedLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func forceRefreshIncomingPokes() async {
        await refreshIncomingPokesLive(reason: "manual")
    }

    private func clearAllIncomingPokes() async {
        guard !isClearingAllPokes else { return }
        await MainActor.run {
            isClearingAllPokes = true
            incomingPokesMessage = nil
        }

        do {
            let clearedCount = try await profilePokesService.clearIncomingPokesHistoryForCurrentUser()
            await MainActor.run {
                incomingPokes = []
                incomingPokeTotalCount = 0
                incomingPokesMessage = nil
                isClearingAllPokes = false
                if let authId = viewModel.currentUserAuthId {
                    ProfilePhase1PersonalizationCache.incomingPokesLoadedAtByAuthId[authId] = Date()
                }
                viewModel.clearUnseenPokesBadgeState()
#if DEBUG
                print("[FanPokesDebug] clearAllCompleted count=\(clearedCount)")
#endif
            }
        } catch {
            await MainActor.run {
                incomingPokesMessage = "Couldn't clear Pokes"
                isClearingAllPokes = false
#if DEBUG
                print("[FanPokesDebug] clearAllFailed error=\(error.localizedDescription)")
#endif
            }
        }
    }

    private func refreshIncomingPokesLive(reason: String) async {
        guard isAccountTabActive else { return }
        await loadIncomingPokes(ignoreCache: true)
    }

    /// Clears tab/avatar/card unseen state after the Pokes card has loaded on Account (not on tab select alone).
    private func acknowledgePokesCardAfterSuccessfulLoad() {
        guard isAccountTabActive, viewModel.hasUnseenPokes else { return }
        viewModel.acknowledgeIncomingPokes(reason: "pokesCardLoaded")
    }

    private func loadIncomingPokes(ignoreCache: Bool = false) async {
        guard canShowOwnerPokesHighlights, let authId = viewModel.currentUserAuthId else {
            await MainActor.run {
                incomingPokes = []
                incomingPokeTotalCount = 0
                incomingPokesMessage = nil
                isLoadingIncomingPokes = false
            }
            return
        }

        if !ignoreCache,
           !incomingPokes.isEmpty,
           let loadedAt = ProfilePhase1PersonalizationCache.incomingPokesLoadedAtByAuthId[authId],
           Date().timeIntervalSince(loadedAt) < ProfilePhase1PersonalizationCache.ttlSeconds {
            acknowledgePokesCardAfterSuccessfulLoad()
            return
        }

        await MainActor.run {
            isLoadingIncomingPokes = true
            incomingPokesMessage = nil
        }

        do {
            let items = try await profilePokesService.fetchMyIncomingPokes(limit: Self.incomingPokesHighlightsLimit)

            await MainActor.run {
                incomingPokes = items
                incomingPokeTotalCount = items.count
                incomingPokesMessage = nil
                isLoadingIncomingPokes = false
                ProfilePhase1PersonalizationCache.incomingPokesLoadedAtByAuthId[authId] = Date()
                viewModel.applyIncomingPokesFetch(items)
                acknowledgePokesCardAfterSuccessfulLoad()
            }
            DebugLogGate.debug("[PokesUI] incoming load count=\(items.count) total=\(items.count)")
        } catch {
            await MainActor.run {
                incomingPokes = []
                incomingPokeTotalCount = 0
                incomingPokesMessage = "Couldn't load Pokes"
                isLoadingIncomingPokes = false
            }
        }
    }

    // MARK: - Suggested fans

    private var displayedSuggestedFans: [FriendSuggestionProfile] {
        Array(suggestedFans.prefix(Self.suggestedFansDisplayLimit))
    }

    private var suggestedFansSection: some View {
        ProfileSuggestedFansSection(
            suggestions: displayedSuggestedFans,
            isLoading: isLoadingSuggestedFans,
            message: suggestedFansMessage,
            sendingRequestIds: sendingSuggestedFanRequestIds,
            chipKind: { chatViewModel.chipKind(forOtherUserId: $0) },
            onAdd: { suggestion in
                Task { await addSuggestedFan(suggestion) }
            },
            onDismiss: { suggestion in
                Task { await dismissSuggestedFan(suggestion) }
            }
        )
    }

    private func loadSuggestedFans(ignoreCache: Bool = false) async {
        guard canShowSuggestedFans else {
            await MainActor.run {
                suggestedFans = []
                suggestedFansMessage = nil
                isLoadingSuggestedFans = false
                sendingSuggestedFanRequestIds = []
            }
            return
        }

        if let authId = viewModel.currentUserAuthId,
           !ignoreCache,
           let loadedAt = ProfilePhase1PersonalizationCache.suggestedFansLoadedAtByAuthId[authId],
           Date().timeIntervalSince(loadedAt) < ProfilePhase1PersonalizationCache.ttlSeconds {
#if DEBUG
            print("[PerfPhase1C] profileCacheHit key=suggestedFans")
#endif
            return
        }

#if DEBUG
        print("[SuggestedFansUI] load start")
#endif
        await MainActor.run {
            isLoadingSuggestedFans = true
            suggestedFansMessage = nil
        }

        do {
            let suggestions = try await friendSuggestionsService.fetchSuggestions(
                limit: Self.suggestedFansFetchLimit
            )
            await MainActor.run {
                suggestedFans = suggestions
                suggestedFansMessage = nil
                isLoadingSuggestedFans = false
                if let authId = viewModel.currentUserAuthId {
                    ProfilePhase1PersonalizationCache.suggestedFansLoadedAtByAuthId[authId] = Date()
                }
            }
#if DEBUG
            print("[SuggestedFansUI] load success count=\(suggestions.count)")
#endif
        } catch {
            await MainActor.run {
                suggestedFans = []
                suggestedFansMessage = "More fan matches coming soon"
                isLoadingSuggestedFans = false
            }
#if DEBUG
            print("[SuggestedFansUI] load failed error=\(error.localizedDescription)")
#endif
        }
    }

    private func addSuggestedFan(_ suggestion: FriendSuggestionProfile) async {
        guard canShowSuggestedFans else { return }
        guard !sendingSuggestedFanRequestIds.contains(suggestion.userID) else { return }

#if DEBUG
        print("[SuggestedFansUI] add tapped user_id=\(suggestion.userID.uuidString.lowercased())")
#endif
        await MainActor.run {
            _ = sendingSuggestedFanRequestIds.insert(suggestion.userID)
        }
        await chatViewModel.sendFriendRequest(to: suggestion.userID)
        await MainActor.run {
            _ = sendingSuggestedFanRequestIds.remove(suggestion.userID)
        }
    }

    @MainActor
    private func dismissSuggestedFan(_ suggestion: FriendSuggestionProfile) async {
        guard canShowSuggestedFans else { return }
        let dismissedId = suggestion.userID
        let visibleBefore = displayedSuggestedFans.map(\.userID)

        suggestedFans.removeAll { $0.userID == dismissedId }
        sendingSuggestedFanRequestIds.remove(dismissedId)

        print("[SuggestedFans] dismissed user=\(dismissedId.uuidString.lowercased())")

        if let replacementId = displayedSuggestedFans.map(\.userID).first(where: { !visibleBefore.contains($0) }) {
            print("[SuggestedFans] replacement loaded user=\(replacementId.uuidString.lowercased())")
        }

        do {
            try await friendSuggestionsService.dismissSuggestion(dismissedUserId: dismissedId)
        } catch {
            DebugLogGate.debug("[SuggestedFans] dismiss persist failed user=\(dismissedId.uuidString.lowercased()) error=\(error.localizedDescription)")
        }
    }

    // MARK: - Handle prompt

    private var handlePromptBanner: some View {
        Button {
            showHandleSetup = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "at")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FGColor.accentGreen)
                Text("Choose your @handle for friend search")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(FGColor.accentGreen.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Hero (compact header + stats)

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow
                .padding(.horizontal, 18)
                .padding(.top, 18)

            statsRow
                .padding(.horizontal, 16)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 18) {
            PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                avatarStack
            }
            .disabled(isUploadingAvatar || isSavingIdentity)
            .buttonStyle(.plain)
            .accessibilityLabel("Update profile photo")

            VStack(alignment: .leading, spacing: 12) {
                Button {
                    presentIdentityEditor(focusedField: .displayName)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(displayName)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                            if reputation.privileges.isVerifiedOrganizer {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(FGColor.accentBlue)
                            }
                        }

                        Text(handleLine)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)

                        if let primaryFavoriteTeam {
                            trophyTeamHeaderBadge(primaryFavoriteTeam)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit display name and handle")

                Button {
                    presentIdentityEditor(focusedField: .bio)
                } label: {
                    Text(bioLine.isEmpty ? "Add a short bio so fans know your vibe." : bioLine)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(bioLine.isEmpty ? FGColor.mutedText(colorScheme) : FGColor.primaryText(colorScheme).opacity(0.82))
                        .lineLimit(2)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bioLine.isEmpty ? "Add bio" : "Edit bio")

                HStack(spacing: 7) {
                    reputationPill

                    if !identityMessage.isEmpty {
                        Text(identityMessage)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(identityMessage.contains("updated") || identityMessage == "Saved." ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                }
                .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var reputationPill: some View {
        HStack(spacing: 5) {
            Image(systemName: reputation.privileges.isVerifiedOrganizer ? "checkmark.seal.fill" : "bolt.heart.fill")
                .font(.system(size: 9.5, weight: .bold))
            Text(localizedReputationTitle(reputation.title).uppercased())
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(0.55)
                .lineLimit(1)
        }
        .foregroundStyle(FGColor.accentGreen)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11))
        .clipShape(Capsule())
    }

    private func localizedReputationTitle(_ title: String) -> String {
        switch title {
        case "Rookie Fan":
            return L10n.t("rookie_fan", languageCode: appLanguageRaw)
        case "Venue Regular":
            return L10n.t("venue_regular", languageCode: appLanguageRaw)
        case "Home Crowd":
            return L10n.t("home_crowd", languageCode: appLanguageRaw)
        default:
            return title
        }
    }

    private func trophyTeamHeaderBadge(_ team: FavoriteTeam) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(FGColor.accentYellow)
            Text(L10n.t("my_team", languageCode: appLanguageRaw))
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.accentYellow)
                .textCase(.uppercase)
                .tracking(0.6)
            Text(team.shortCode?.isEmpty == false ? team.shortCode! : team.name)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous)
                .fill(FGColor.accentYellow.opacity(colorScheme == .dark ? 0.16 : 0.11))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(FGColor.accentYellow.opacity(colorScheme == .dark ? 0.30 : 0.22), lineWidth: 1)
                }
        }
        .shadow(color: FGColor.accentYellow.opacity(colorScheme == .dark ? 0.20 : 0.12), radius: 9, y: 3)
        .onAppear {
#if DEBUG
            print("[FavoriteTeamsDebug] primaryTeamDisplayed=\(team.id)")
            print("[FavoriteTeamsDebug] userFacingPrimaryLabel=MyTeam")
            print("[FavoriteTeamsDebug] primaryTeamDisplayUpdated=true")
#endif
        }
    }

    private var profileHeroPokesBadgeVisible: Bool {
        viewModel.hasUnseenPokes
    }

    private var avatarStack: some View {
        ZStack(alignment: .topTrailing) {
            avatarStackCore

            if profileHeroPokesBadgeVisible {
                PokesUnseenAvatarBadge(style: .profileHero)
                    .offset(x: 3, y: 1)
            }
        }
        .onAppear {
            DebugLogGate.debug("[PokesBadgeUI] avatarBadge visible=\(profileHeroPokesBadgeVisible)")
        }
        .onChange(of: profileHeroPokesBadgeVisible) { _, visible in
            DebugLogGate.debug("[PokesBadgeUI] avatarBadge visible=\(visible)")
        }
    }

    private var avatarStackCore: some View {
        ZStack(alignment: .bottomTrailing) {
            UserAvatarView(
                avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
                avatarURL: viewModel.currentUserAvatarURL,
                avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
                displayName: displayName,
                email: viewModel.currentUserEmail,
                size: 94,
                fallbackStyle: .lightOnWhiteChrome,
                imagePlaceholderTint: FGColor.accentBlue
            )
            .overlay {
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                FGColor.accentBlue,
                                FGColor.accentGreen,
                                Color(red: 0.98, green: 0.67, blue: 0.33),
                                FGColor.accentBlue
                            ],
                            center: .center
                        ),
                        lineWidth: 3
                    )
            }
            .padding(3)
            .background(Circle().fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.96)))
            .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.16), radius: 12, y: 5)

            Circle()
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 27, height: 27)
                .overlay {
                    if isUploadingAvatar {
                        ProgressView()
                            .controlSize(.small)
                            .tint(FGColor.accentGreen)
                    } else {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(FGColor.accentGreen)
                    }
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.95), lineWidth: 1.5)
                }
                .offset(x: 2, y: 2)
        }
    }

    // MARK: - Inline identity editing

    private var identityEditorSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 12) {
                        PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                            avatarStack
                        }
                        .disabled(isUploadingAvatar || isSavingIdentity)
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Edit your profile")
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                            Text("Your public fan identity")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                    }

                    identityFieldCard(title: "Display name", subtitle: "Shown on your profile and social activity.") {
                        TextField("Display name", text: $editedDisplayName)
                            .textInputAutocapitalization(.words)
                            .disableAutocorrection(true)
                            .focused($focusedIdentityField, equals: .displayName)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .profileIdentityInputStyle(colorScheme: colorScheme)
                    }

                    identityFieldCard(title: "@handle", subtitle: "Unique FanGeo handle for friend search.") {
                        HStack(spacing: 4) {
                            Text("@")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                            TextField("handle", text: $editedUsername)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focusedIdentityField, equals: .username)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                        }
                        .profileIdentityInputStyle(colorScheme: colorScheme)

                        if !handleStatusMessage.isEmpty {
                            HandleAvailabilityStatusLabel(
                                message: handleStatusMessage,
                                isPositive: handleStatusIsPositive
                            )
                        }
                    }

                    identityFieldCard(title: "Bio", subtitle: "A short line about your fan energy.") {
                        TextEditor(text: $editedBio)
                            .focused($focusedIdentityField, equals: .bio)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .frame(minHeight: 82)
                            .scrollContentBackground(.hidden)
                            .profileIdentityInputStyle(colorScheme: colorScheme)
                            .overlay(alignment: .topLeading) {
                                if editedBio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("Add a short bio")
                                        .font(.system(size: 15, weight: .medium, design: .rounded))
                                        .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.55))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 12)
                                        .allowsHitTesting(false)
                                }
                            }

                        Text("\(editedBio.count)/\(Self.bioCharacterLimit)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    if !identityMessage.isEmpty {
                        Text(identityMessage)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(identityMessage.contains("updated") || identityMessage == "Saved." ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .fanGeoScreenBackground()
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showIdentityEditor = false }
                        .disabled(isSavingIdentity || isUploadingAvatar)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSavingIdentity ? "Saving..." : "Save") {
                        Task { await saveIdentity() }
                    }
                    .disabled(isSavingIdentity || isUploadingAvatar)
                }
            }
            .onAppear {
                resetIdentityDraft()
            }
        }
    }

    private func identityFieldCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            content()
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.86 : 0.98))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }
        }
    }

    private func presentIdentityEditor(focusedField: IdentityField) {
        resetIdentityDraft()
        showIdentityEditor = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.focusedIdentityField = focusedField
        }
    }

    private func resetIdentityDraft() {
        editedDisplayName = displayName
        editedUsername = viewModel.currentUserUsername
        editedBio = limitedBio(viewModel.currentUserBio)
        handleStatusMessage = ""
        handleStatusIsPositive = false
    }

    private func limitedBio(_ raw: String) -> String {
        String(raw.prefix(Self.bioCharacterLimit))
    }

    private func profilePhotoPickFailureHint() -> String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .denied, .restricted:
            return "Photo access is off. Turn it on in Settings > Privacy & Security > Photos to upload a profile picture."
        case .limited:
            return "Couldn’t use that photo. Try another image, or allow more photos for FanGeo in Settings."
        default:
            return "Unable to read that photo. Try a different image or check your connection."
        }
    }

    private func scheduleHandleAvailabilityCheck() {
        availabilityTask?.cancel()
        handleStatusMessage = ""
        handleStatusIsPositive = false

        let raw = editedUsername
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        let stored = FanGeoHandleRules.normalizeForStorage(raw)
        print("[HandleValidationDebug] normalizedHandle=\(stored)")
        if let issue = FanGeoHandleRules.validate(raw) {
            handleStatusMessage = "Invalid handle: \(FanGeoHandleRules.validationMessage(for: issue))"
            print("[HandleValidationDebug] handleRejected reason=\(issue)")
            return
        }

        handleStatusMessage = "Checking availability..."
        availabilityTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            print("[HandleValidationDebug] availabilityCheck=\(stored)")
            guard let available = await viewModel.checkUsernameAvailable(raw) else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                print("[HandleValidationDebug] handleAvailable=\(available)")
                if available {
                    handleStatusMessage = "Available"
                    handleStatusIsPositive = true
                } else {
                    handleStatusMessage = "Already taken"
                    handleStatusIsPositive = false
                    print("[HandleValidationDebug] handleRejected reason=already_taken")
                }
            }
        }
    }

    private func saveIdentity() async {
        guard viewModel.isLoggedIn else {
            await MainActor.run { identityMessage = "Please sign in to edit your profile." }
            return
        }

        await MainActor.run { isSavingIdentity = true }
        defer { Task { @MainActor in isSavingIdentity = false } }

        let trimmed = editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmed.isEmpty ? displayName : trimmed
        if ModerationService.containsProfanity(nextName) {
            await MainActor.run { identityMessage = ModerationService.profanityRejectionUserMessage() }
            return
        }
        if let issue = FanGeoHandleRules.validate(editedUsername) {
            await MainActor.run { identityMessage = FanGeoHandleRules.validationMessage(for: issue) }
            print("[HandleValidationDebug] handleRejected reason=\(issue)")
            return
        }

        let nextBio = limitedBio(editedBio)
        if let err = await viewModel.saveUserProfile(
            displayName: nextName,
            avatarURL: viewModel.currentUserAvatarURL,
            avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
            username: editedUsername,
            bio: nextBio
        ) {
            await MainActor.run { identityMessage = err }
            return
        }

        await MainActor.run {
            identityMessage = "Saved."
            showIdentityEditor = false
        }
    }

    private func replaceAvatar(with item: PhotosPickerItem) async {
        guard viewModel.isLoggedIn else {
            await MainActor.run { identityMessage = "Please sign in to update your avatar." }
            return
        }

        await MainActor.run {
            isUploadingAvatar = true
            identityMessage = "Uploading avatar..."
        }
        defer { Task { @MainActor in isUploadingAvatar = false } }

        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run { identityMessage = profilePhotoPickFailureHint() }
            return
        }
        guard let urls = await viewModel.uploadUserAvatar(data: data, fileName: "avatar.jpg") else {
            await MainActor.run { identityMessage = "Unable to upload avatar." }
            return
        }

        let trimmed = editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmed.isEmpty ? displayName : trimmed
        if ModerationService.containsProfanity(nextName) {
            await MainActor.run { identityMessage = ModerationService.profanityRejectionUserMessage() }
            return
        }
        if let err = await viewModel.saveUserProfile(
            displayName: nextName,
            avatarURL: urls.fullURL,
            avatarThumbnailURL: urls.thumbnailURL
        ) {
            await MainActor.run { identityMessage = err }
            return
        }
        await MainActor.run { identityMessage = "Avatar updated." }
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(value: pickupGamesValue, label: "Pickup\nGames")
            statDivider
            statCell(value: venueGamesValue, label: "Venue\nGames")
            statDivider
            statCell(value: favoriteTeamsValue, label: "Fav\nTeams")
            statDivider
            statCell(value: friendsValue, label: "Friends")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.055 : 0.92))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.0 : 0.045), lineWidth: 0.75)
                }
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.08 : 0.035), radius: 10, y: 5)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(colorScheme == .dark ? 0.14 : 0.06))
            .frame(width: 1)
            .padding(.vertical, 3)
    }

    private var pickupGamesValue: String {
        let localApproved = viewModel.myPickupGameJoinRequestCards.filter { $0.pill == .approved }.count
        let n = profileStatsCounts?.pickupGamesCount ?? localApproved
        return n > 0 ? "\(n)" : "—"
    }

    private var venueGamesValue: String {
        let n = profileStatsCounts?.venueGamesCount ?? viewModel.followingTabGoingItems.filter { $0.isServerGoing }.count
        return n > 0 ? "\(n)" : "—"
    }

    private var favoriteTeamsValue: String {
        let n = profileStatsCounts?.favoriteTeamsCount ?? selectedTeams.count
        return n > 0 ? "\(n)" : "—"
    }

    private var friendsValue: String {
        let n = profileStatsCounts?.friendsCount ?? chatViewModel.friends.count
        return n > 0 ? "\(n)" : "—"
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Home Crowd

    private var homeCrowdSection: some View {
        HomeCrowdProfileCardView(
            summary: viewModel.currentUserHomeCrowdVenue,
            isSelfProfile: true,
            onExploreVenue: viewModel.currentUserHomeCrowdVenue != nil
                ? { viewModel.focusDiscoverOnHomeCrowdVenue() }
                : nil,
            onChangeHomeCrowd: viewModel.currentUserHomeCrowdVenue != nil
                ? { viewModel.focusDiscoverOnHomeCrowdVenue() }
                : nil,
            onChooseHomeCrowd: viewModel.currentUserHomeCrowdVenue == nil
                ? { viewModel.openDiscoverToChooseHomeCrowd() }
                : nil
        )
    }

    // MARK: - Open To preview

    private var openToPreviewSection: some View {
        let prefs = viewModel.currentUserFanIdentityPreferences
        let previewItems = FanOpenToCatalog.publicDisplayItems(from: prefs.resolvedOpenToItemIDs)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("open_to", languageCode: appLanguageRaw))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .textCase(.uppercase)
                        .tracking(0.7)
                    Text(previewItems.isEmpty ? "Tell fans what you're up for" : "What you're open to")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.82))
                }
                Spacer(minLength: 0)
                Button {
                    showFanIdentityEditor = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9, weight: .bold))
                        Text("Edit Open To")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(FGColor.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        Capsule()
                            .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    }
                }
                .buttonStyle(.plain)
            }

            if previewItems.isEmpty {
                Text("Add sports, watch parties, or meetups you're open to.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .padding(.vertical, 4)
            } else {
                SelfProfileOpenToPreviewGrid(items: previewItems) { item in
                    quickRemoveOpenToItem(item)
                }
            }
        }
    }

    private func quickRemoveOpenToItem(_ item: PublicProfileOpenToItem) {
        print("[FanIdentityOpenTo] quickRemove item=\(item.id)")

        let previous = viewModel.currentUserFanIdentityPreferences
        var next = previous
        let previousIDs = next.resolvedOpenToItemIDs
        let nextIDs = previousIDs.filter { $0 != item.id }
        guard nextIDs.count != previousIDs.count else { return }

        next.openToItems = nextIDs
        next.markOpenToSaved()

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            viewModel.currentUserFanIdentityPreferences = next
        }

        Task {
            if let err = await viewModel.saveFanIdentityPreferences(next) {
                print("[FanIdentityOpenTo] quickRemoveRollback item=\(item.id)")
                await MainActor.run {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        viewModel.currentUserFanIdentityPreferences = previous
                    }
                    viewModel.showSocialActionToast(err, isError: true)
                }
                return
            }
            print("[FanIdentityOpenTo] quickRemoveSaved")
        }
    }

    // MARK: - National Team

    private var nationalTeamSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(NationalTeamCopy.text("national_team", languageCode: appLanguageRaw))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .textCase(.uppercase)
                        .tracking(0.7)
                    Text(NationalTeamCopy.text("national_team_subtitle", languageCode: appLanguageRaw))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.82))
                }
                Spacer(minLength: 0)
            }

            if let identity = viewModel.currentUserNationalTeam {
                NationalTeamIdentityCard(identity: identity, showsEditAffordance: true) {
                    openNationalTeamPicker()
                }
            } else {
                Button {
                    openNationalTeamPicker()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text(NationalTeamCopy.text("choose_national_team", languageCode: appLanguageRaw))
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(FGColor.accentGreen)
                    .padding(13)
                    .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
#if DEBUG
            print("[NationalTeamDebug] profileSectionVisible=true")
#endif
        }
    }

    private func openNationalTeamPicker() {
        showNationalTeamPicker = true
#if DEBUG
        print("[NationalTeamDebug] pickerOpened=true")
#endif
    }

    private func saveNationalTeamIdentity(_ identity: NationalTeamIdentity) async {
        if let err = await viewModel.saveNationalTeamIdentity(identity) {
            await MainActor.run {
                viewModel.showSocialActionToast(err, isError: true)
            }
        }
    }

    // MARK: - Favorite teams

    private var favoriteTeamsSection: some View {
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("favorite_teams", languageCode: appLanguageRaw))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .textCase(.uppercase)
                        .tracking(0.7)
                    Text(selectedTeams.isEmpty ? "Shape your fan identity" : "Show off your fan colors")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.82))
                }
                Spacer(minLength: 0)
                Button {
                    showFavoriteTeamsPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .bold))
                        Text(selectedTeams.isEmpty ? "Add Teams" : "Edit Teams")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(FGColor.accentBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        Capsule()
                            .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    }
                }
                .buttonStyle(.plain)
            }

            if selectedTeams.isEmpty {
                addTeamSocialCard
                    .frame(height: Self.favoriteTeamsCarouselHeight, alignment: .topLeading)
            } else {
                favoriteTeamsCardRow
            }
        }
        .padding(.bottom, Self.favoriteTeamsHomeCrowdBottomSpacing)
        .onAppear {
#if DEBUG
            print("[ProfileLayoutDebug] favoriteTeamsHomeCrowdSpacingFixed=true")
#endif
        }
    }

    private var favoriteTeamsCardRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(selectedTeams) { team in
                    favoriteTeamSocialCard(team: team)
                }

                addTeamSocialCard
            }
            .padding(.vertical, 1)
        }
        .frame(height: Self.favoriteTeamsCarouselHeight, alignment: .topLeading)
    }

    private func favoriteTeamSocialCard(team: FavoriteTeam) -> some View {
        let isPrimary = team.id == primaryFavoriteTeamID
        let isAnimatingSelection = animatedTrophyTeamID == team.id
        let isAnimatingDemotion = demotedTrophyTeamID == team.id && !isPrimary
        let sportAccent = sportAccentColor(for: team.sport.chipTitle)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                PremiumTeamIdentityOrb(team: team, diameter: 62)
                Spacer(minLength: 0)
                trophyTeamButton(
                    team: team,
                    isPrimary: isPrimary,
                    isAnimatingSelection: isAnimatingSelection
                )

                removeFavoriteTeamButton(team: team)
            }

            VStack(alignment: .leading, spacing: isPrimary ? 3 : 1) {
                if isPrimary {
                    primaryFavoriteTeamCardLabel(team)
                } else {
                    Text(team.name)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.75)
                }

                favoriteTeamCardSportBadge(team: team)

                if !isPrimary {
                    HStack(spacing: 5) {
                        Image(systemName: "trophy")
                            .font(.system(size: 10, weight: .heavy))
                        Text("Make My Team")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.white.opacity(0.70))
                    .padding(.top, 6)
                    .animation(trophyVisualTransitionAnimation, value: isPrimary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 174, height: 148, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            team.badgeColor.opacity(0.96),
                            FGColor.accentBlue.opacity(0.84),
                            Color(red: 0.09, green: 0.12, blue: 0.18).opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.34),
                                    Color.white.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
        }
        .overlay(alignment: .topLeading) {
            favoriteTeamSportAccentStripe(color: sportAccent, cornerRadius: 24)
        }
        .overlay {
            if isAnimatingSelection && !reduceMotion {
                trophySelectionShimmer(cornerRadius: 24)
            }
        }
        .shadow(
            color: isPrimary
                ? FGColor.accentYellow.opacity(colorScheme == .dark ? 0.26 : 0.20)
                : isAnimatingDemotion
                    ? FGColor.accentYellow.opacity(colorScheme == .dark ? 0.10 : 0.08)
                : team.badgeColor.opacity(colorScheme == .dark ? 0.18 : 0.16),
            radius: isPrimary ? 18 : isAnimatingDemotion ? 15 : 14,
            y: isPrimary ? 9 : 8
        )
        .animation(trophyVisualTransitionAnimation, value: isPrimary)
        .animation(trophyVisualTransitionAnimation, value: isAnimatingDemotion)
        .onAppear {
#if DEBUG
            print("[FavoriteTeamsDebug] favoriteTeamsCount=\(selectedTeams.count)")
            print("[FavoriteTeamsDebug] sportAccentRendered sport=\(team.sport.chipTitle)")
            print("[FavoriteTeamsDebug] sportAccentColorApplied=true")
#endif
        }
    }

    private func favoriteTeamSportAccentStripe(color: Color, cornerRadius: CGFloat) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            color.opacity(colorScheme == .dark ? 0.62 : 0.50),
                            color.opacity(colorScheme == .dark ? 0.22 : 0.16),
                            Color.white.opacity(0.02),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 3)
                .shadow(color: color.opacity(colorScheme == .dark ? 0.30 : 0.18), radius: 8, y: 2)
            Spacer(minLength: 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func primaryFavoriteTeamCardLabel(_ team: FavoriteTeam) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 10, weight: .heavy))
                Text(L10n.t("my_team", languageCode: appLanguageRaw))
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                    .textCase(.uppercase)
                    .tracking(0.45)
            }
            .foregroundStyle(FGColor.accentYellow)

            Text(team.name)
                .font(.system(size: 15.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .truncationMode(.tail)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
#if DEBUG
            print("[FavoriteTeamsDebug] userFacingPrimaryLabel=MyTeam")
            print("[FavoriteTeamsDebug] primaryTeamDisplayUpdated=true")
#endif
        }
    }

    private func trophyTeamButton(
        team: FavoriteTeam,
        isPrimary: Bool,
        isAnimatingSelection: Bool
    ) -> some View {
        Button {
            promoteTrophyTeam(team)
        } label: {
            ZStack {
                Image(systemName: "trophy")
                    .opacity(isPrimary ? 0 : 1)
                    .foregroundStyle(Color.white.opacity(0.78))
                Image(systemName: "trophy.fill")
                    .opacity(isPrimary ? 1 : 0)
                    .foregroundStyle(FGColor.accentYellow)
            }
                .font(.system(size: 14, weight: .heavy))
                .frame(width: 30, height: 30)
                .background {
                    Circle()
                        .fill(isPrimary ? FGColor.accentYellow.opacity(0.18) : Color.black.opacity(0.18))
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    isPrimary ? FGColor.accentYellow.opacity(0.64) : Color.white.opacity(0.22),
                                    lineWidth: 1
                                )
                        }
                }
                .shadow(color: isPrimary ? FGColor.accentYellow.opacity(0.45) : .clear, radius: 8, y: 2)
                .scaleEffect(isAnimatingSelection && !reduceMotion ? 1.13 : 1.0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(trophyVisualTransitionAnimation, value: isPrimary)
        .animation(trophyPulseAnimation, value: isAnimatingSelection)
        .accessibilityLabel(isPrimary ? "\(team.name) is My Team" : "Make \(team.name) My Team")
        .accessibilityHint(isPrimary ? "Only one favorite team can be primary" : "Promotes this favorite team to primary")
    }

    private func removeFavoriteTeamButton(team: FavoriteTeam) -> some View {
        Button {
            removeFavoriteTeam(team)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(width: 24, height: 24)
                .background {
                    Circle()
                        .fill(Color.black.opacity(0.22))
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
                        }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(team.name) from favorite teams")
    }

    private func removeFavoriteTeam(_ team: FavoriteTeam) {
#if DEBUG
        print("[FavoriteTeamsProfile] remove tapped team_id=\(team.id)")
#endif
        let previousIDs = FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw)
        let previousPrimary = primaryFavoriteTeamID
        let nextIDs = previousIDs.filter { $0 != team.id }
        guard nextIDs.count != previousIDs.count else { return }
        let nextPrimary = FavoriteTeamsStore.normalizedPrimaryTeamID(
            previousPrimary == team.id ? nil : previousPrimary,
            within: nextIDs
        )

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            favoriteTeamIDsRaw = FavoriteTeamsStore.encodeIDs(nextIDs)
            primaryFavoriteTeamIDRaw = nextPrimary ?? ""
        }

        Task {
            let didSync = await viewModel.syncFavoriteTeamsToSupabase(teamIDs: nextIDs, primaryTeamID: nextPrimary)
            if didSync {
#if DEBUG
                print("[FavoriteTeamsProfile] remove success team_id=\(team.id)")
#endif
                return
            }

            await MainActor.run {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    favoriteTeamIDsRaw = FavoriteTeamsStore.encodeIDs(previousIDs)
                    primaryFavoriteTeamIDRaw = previousPrimary ?? ""
                }
            }
#if DEBUG
            print("[FavoriteTeamsProfile] remove failed team_id=\(team.id) error=sync_failed")
#endif
        }
    }

    private func promoteTrophyTeam(_ team: FavoriteTeam) {
        let ids = FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw)
        guard ids.contains(team.id) else { return }
        let previousPrimary = primaryFavoriteTeamID
        guard previousPrimary != team.id else { return }

#if DEBUG
        print("[FavoriteTeamsDebug] trophyTeamSelected teamId=\(team.id)")
        print("[FavoriteTeamsDebug] previousTrophyTeamCleared=\(previousPrimary != nil)")
#endif

        startTrophySelectionAnimation(teamID: team.id, previousPrimaryID: previousPrimary)

        withAnimation(trophyVisualTransitionAnimation) {
            primaryFavoriteTeamIDRaw = team.id
        }

        Task {
            let didSync = await viewModel.syncFavoriteTeamsToSupabase(teamIDs: ids, primaryTeamID: team.id)
            guard !didSync else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    primaryFavoriteTeamIDRaw = previousPrimary ?? ""
                }
            }
        }
    }

    private var trophyVisualTransitionAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.24)
            : .spring(response: 0.34, dampingFraction: 0.82)
    }

    private var trophyPulseAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.20)
            : .spring(response: 0.26, dampingFraction: 0.58)
    }

    private func startTrophySelectionAnimation(teamID: String, previousPrimaryID: String?) {
        trophyAnimationTask?.cancel()
        trophyShimmerProgress = -0.6

#if DEBUG
        print("[FavoriteTeamsDebug] trophyAnimationStarted teamId=\(teamID)")
        if previousPrimaryID != nil {
            print("[FavoriteTeamsDebug] previousTrophyDemotedAnimated=true")
        }
#endif

        withAnimation(trophyPulseAnimation) {
            animatedTrophyTeamID = teamID
            demotedTrophyTeamID = previousPrimaryID
        }

        if !reduceMotion {
            withAnimation(.easeInOut(duration: 0.42)) {
                trophyShimmerProgress = 1.35
            }
        }

        let durationSeconds = reduceMotion ? 0.28 : 0.46
        trophyAnimationTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                withAnimation(trophyVisualTransitionAnimation) {
                    animatedTrophyTeamID = nil
                    demotedTrophyTeamID = nil
                }
                trophyShimmerProgress = -0.6
                trophyAnimationTask = nil
#if DEBUG
                print("[FavoriteTeamsDebug] trophyAnimationCompleted teamId=\(teamID)")
#endif
            }
        }
    }

    private func trophySelectionShimmer(cornerRadius: CGFloat) -> some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let shimmerWidth = max(width * 0.36, 46)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            FGColor.accentYellow.opacity(0.18),
                            Color.white.opacity(0.24),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: shimmerWidth, height: proxy.size.height * 1.45)
                .rotationEffect(.degrees(14))
                .offset(
                    x: -width + trophyShimmerProgress * (width + shimmerWidth),
                    y: -proxy.size.height * 0.18
                )
                .blendMode(.screen)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func favoriteTeamCardSportBadge(team: FavoriteTeam) -> some View {
        HStack(spacing: 5) {
            Text(sportIcon(for: team.sport.chipTitle))
                .font(.system(size: 13))
            Text(team.sport.chipTitle)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.84))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.13))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
                }
        }
        .onAppear {
#if DEBUG
            print("[FavoriteTeamsDebug] sportIconRendered sport=\(team.sport.chipTitle)")
            print("[FavoriteTeamsDebug] favoriteTeamCardSportIconVisible=true")
#endif
        }
    }

    private var addTeamSocialCard: some View {
        Button {
            showFavoriteTeamsPicker = true
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.11))
                        .frame(width: 58, height: 58)
                    Image(systemName: "plus")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(FGColor.accentBlue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Team")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Build your fan profile")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 148, height: 148, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.16),
                                        Color.black.opacity(colorScheme == .dark ? 0.0 : 0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add favorite team")
    }
}

private struct ProfileSuggestedFansSection: View {
    let suggestions: [FriendSuggestionProfile]
    let isLoading: Bool
    let message: String?
    let sendingRequestIds: Set<UUID>
    let chipKind: (UUID) -> ChatViewModel.FriendshipChipKind
    let onAdd: (FriendSuggestionProfile) -> Void
    let onDismiss: (FriendSuggestionProfile) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if isLoading && suggestions.isEmpty {
                loadingRow
            } else if suggestions.isEmpty {
                emptyState
            } else {
                suggestionsRow
            }
        }
        .padding(.vertical, 2)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.t("suggested_fans", languageCode: appLanguageRaw))
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.7)

            Text(L10n.t("suggested_fans_subtitle", languageCode: appLanguageRaw))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.82))
        }
    }

    private var loadingRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.72))
                        .frame(width: 148, height: 172)
                        .redacted(reason: .placeholder)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 3)
        }
        .accessibilityLabel(L10n.t("suggested_fans", languageCode: appLanguageRaw))
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FGColor.accentGreen.opacity(0.78))

            Text(message?.isEmpty == false ? message! : "More fan matches coming soon")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.0 : 0.04), lineWidth: 0.75)
                }
        }
        .accessibilityLabel("More fan matches coming soon")
    }

    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(suggestions) { suggestion in
                    suggestionCard(suggestion)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
            .padding(.trailing, 8)
        }
    }

    private func suggestionCard(_ suggestion: FriendSuggestionProfile) -> some View {
        VStack(spacing: 11) {
            PublicProfileAvatarTap(userId: suggestion.userID, context: "profile_suggested_fans") {
                VStack(spacing: 8) {
                    avatar(for: suggestion)

                    VStack(spacing: 3) {
                        Text(displayName(for: suggestion))
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        if let handle = handleText(for: suggestion) {
                            Text(handle)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                        }

                        reasonPill(for: suggestion)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .simultaneousGesture(
                TapGesture().onEnded {
#if DEBUG
                    print("[SuggestedFansUI] tapped user_id=\(suggestion.userID.uuidString.lowercased())")
#endif
                }
            )

            addButton(for: suggestion)
        }
        .padding(12)
        .frame(width: 158, height: 178, alignment: .top)
        .background(cardBackground)
        .overlay(alignment: .topTrailing) {
            dismissButton(for: suggestion)
        }
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.085), radius: 14, y: 8)
        .accessibilityElement(children: .combine)
    }

    private func dismissButton(for suggestion: FriendSuggestionProfile) -> some View {
        Button {
            onDismiss(suggestion)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(width: 22, height: 22)
                .background {
                    Circle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.92))
                        .overlay {
                            Circle()
                                .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.0 : 0.06), lineWidth: 0.75)
                        }
                }
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel("Remove suggestion")
    }

    private func avatar(for suggestion: FriendSuggestionProfile) -> some View {
        UserAvatarView(
            avatarThumbnailURL: suggestion.avatarThumbnailURL,
            avatarURL: suggestion.avatarURL ?? "",
            avatarDisplayRefreshToken: ProfileAvatarRefreshToken.stable(
                userId: suggestion.userID,
                thumbnailURL: suggestion.avatarThumbnailURL,
                avatarURL: suggestion.avatarURL
            ),
            displayName: displayName(for: suggestion),
            email: "",
            size: 58,
            fallbackStyle: .lightOnWhiteChrome,
            imagePlaceholderTint: FGColor.accentBlue
        )
        .overlay {
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            FGColor.accentBlue.opacity(0.78),
                            FGColor.accentGreen.opacity(0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
        }
        .padding(2)
        .background(Circle().fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.96)))
    }

    private func reasonPill(for suggestion: FriendSuggestionProfile) -> some View {
        Text(localizedReasonLabel(safeReasonLabel(for: suggestion)))
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(FGColor.accentGreen)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11))
            }
    }

    private func addButton(for suggestion: FriendSuggestionProfile) -> some View {
        let kind = chipKind(suggestion.userID)
        let isSending = sendingRequestIds.contains(suggestion.userID)
        let state = buttonState(for: kind, isSending: isSending)

        return Button {
            onAdd(suggestion)
        } label: {
            HStack(spacing: 5) {
                if isSending {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(state.foreground)
                } else if let systemImage = state.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9.5, weight: .bold))
                }

                Text(state.title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .foregroundStyle(state.foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                Capsule()
                    .fill(state.fill)
                    .overlay {
                        Capsule()
                            .strokeBorder(state.stroke, lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(!state.isEnabled)
        .opacity(state.isEnabled ? 1 : 0.88)
        .accessibilityLabel(state.title)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.065 : 0.96),
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.07 : 0.06),
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.045 : 0.055)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.82),
                                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
    }

    private func displayName(for suggestion: FriendSuggestionProfile) -> String {
        let trimmed = (suggestion.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Fan" : trimmed
    }

    private func handleText(for suggestion: FriendSuggestionProfile) -> String? {
        let trimmed = (suggestion.handle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("@") ? trimmed : "@\(trimmed)"
    }

    private func safeReasonLabel(for suggestion: FriendSuggestionProfile) -> String {
        let allowedLabels: Set<String> = [
            "Same pickup game",
            "Same watch party",
            "Same team",
            "Same venue",
            "Mutual friends",
            "Active fan",
            "High reputation"
        ]
        if let reasonLabel = suggestion.reasonLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           allowedLabels.contains(reasonLabel) {
            return reasonLabel
        }

        let normalizedType = (suggestion.reasonType ?? "")
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalizedType {
        case "pickup_game", "pickup", "shared_pickup", "pickup_player":
            return "Same pickup game"
        case "venue_event", "watch_party", "shared_event", "event_interest", "event":
            return "Same watch party"
        case "same_team", "shared_team", "team", "favorite_team", "favorite_teams":
            return "Same team"
        case "favorite_venue", "shared_venue", "venue":
            return "Same venue"
        case "mutual_friends", "mutual_friend":
            return "Mutual friends"
        case "recent_activity", "active_fan", "activity":
            return "Active fan"
        case "reputation", "fan_level", "high_reputation":
            return "High reputation"
        default:
            if suggestion.sharedPickupGameCount > 0 { return "Same pickup game" }
            if suggestion.sharedEventInterestCount > 0 { return "Same watch party" }
            if suggestion.sharedFavoriteTeamsCount > 0 { return "Same team" }
            return suggestion.score >= 400 ? "High reputation" : "Active fan"
        }
    }

    private func localizedReasonLabel(_ label: String) -> String {
        switch label {
        case "Same pickup game":
            return L10n.t("same_pickup_game", languageCode: appLanguageRaw)
        case "Same watch party":
            return L10n.t("same_watch_party", languageCode: appLanguageRaw)
        case "Same team":
            return L10n.t("same_team", languageCode: appLanguageRaw)
        case "Same venue":
            return L10n.t("same_venue", languageCode: appLanguageRaw)
        case "Mutual friends":
            return L10n.t("mutual_friends", languageCode: appLanguageRaw)
        case "High reputation":
            return L10n.t("high_reputation", languageCode: appLanguageRaw)
        case "Active fan":
            return L10n.t("active_fan", languageCode: appLanguageRaw)
        default:
            return label
        }
    }

    private func buttonState(
        for kind: ChatViewModel.FriendshipChipKind,
        isSending: Bool
    ) -> SuggestedFanButtonState {
        if isSending {
            return SuggestedFanButtonState(
                title: "Adding",
                systemImage: nil,
                isEnabled: false,
                foreground: FGColor.accentBlue,
                fill: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.10),
                stroke: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.24 : 0.28)
            )
        }

        switch kind {
        case .addFriend, .declinedOutgoing:
            return SuggestedFanButtonState(
                title: "Add",
                systemImage: "person.badge.plus",
                isEnabled: true,
                foreground: .white,
                fill: FGColor.accentBlue,
                stroke: FGColor.accentBlue.opacity(0.18)
            )
        case .pendingOutgoing:
            return SuggestedFanButtonState(
                title: "Requested",
                systemImage: "clock.fill",
                isEnabled: false,
                foreground: FGColor.secondaryText(colorScheme),
                fill: Color.white.opacity(colorScheme == .dark ? 0.07 : 0.72),
                stroke: Color.black.opacity(colorScheme == .dark ? 0.0 : 0.05)
            )
        case .pendingIncoming:
            return SuggestedFanButtonState(
                title: "In Chat",
                systemImage: "tray.full.fill",
                isEnabled: false,
                foreground: FGColor.secondaryText(colorScheme),
                fill: Color.white.opacity(colorScheme == .dark ? 0.07 : 0.72),
                stroke: Color.black.opacity(colorScheme == .dark ? 0.0 : 0.05)
            )
        case .friends:
            return SuggestedFanButtonState(
                title: "Friends",
                systemImage: "checkmark",
                isEnabled: false,
                foreground: FGColor.accentGreen,
                fill: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11),
                stroke: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.20 : 0.18)
            )
        }
    }
}

private struct SuggestedFanButtonState {
    let title: String
    let systemImage: String?
    let isEnabled: Bool
    let foreground: Color
    let fill: Color
    let stroke: Color
}

private extension View {
    func profileIdentityInputStyle(colorScheme: ColorScheme) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.62 : 0.96))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
    }
}

private struct PremiumTeamIdentityOrb: View {
    let team: FavoriteTeam
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: diameter, height: diameter)
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)
                }

            Text(team.initials)
                .font(.system(size: max(10, diameter * 0.34), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("\(team.name), \(team.sport.chipTitle)")
    }
}

