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
    @FocusState private var focusedIdentityField: IdentityField?

    @AppStorage(FavoriteTeamsStore.appStorageKey) private var favoriteTeamIDsRaw: String = ""
    @State private var showFavoriteTeamsPicker = false
    @State private var showHandleSetup = false
    @State private var showIdentityEditor = false
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
    @State private var incomingPokesMessage: String?
    @State private var showPokesHistorySheet = false
    @State private var suggestedFans: [FriendSuggestionProfile] = []
    @State private var isLoadingSuggestedFans = false
    @State private var suggestedFansMessage: String?
    @State private var sendingSuggestedFanRequestIds: Set<UUID> = []

    private static let bioCharacterLimit = 160
    private static let incomingPokesHighlightsLimit = 50
    private static let suggestedFansLimit = 12
    private static let incomingPokesLiveRefreshIntervalSeconds = 20
    private static let incomingPokesLiveRefreshIntervalNs: UInt64 =
        UInt64(incomingPokesLiveRefreshIntervalSeconds) * 1_000_000_000

    private let profilePokesService = ProfilePokesService()
    private let friendSuggestionsService = FriendSuggestionsService()

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

    private var selectedTeams: [FavoriteTeam] {
        FavoriteTeamsStore.resolvedTeams(from: favoriteTeamIDsRaw)
    }

    private var selectedIDSet: Set<String> {
        Set(FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw))
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

    private var canShowOwnerPokesHighlights: Bool {
        viewModel.isLoggedIn && viewModel.currentUserAuthId != nil
    }

    private var canShowSuggestedFans: Bool {
        viewModel.isLoggedIn && viewModel.currentUserAuthId != nil
    }

    var body: some View {
        let _: Void = logFanUpdatesStoreMigrationDebug()

        VStack(alignment: .leading, spacing: 12) {
            if viewModel.needsFanHandleSelection && !viewModel.needsBlockingFanIdentitySetup {
                handlePromptBanner
            }

            heroBlock

            if canShowOwnerPokesHighlights {
                pokesHighlightsSection
                    .padding(.horizontal, 16)
            }

            if canShowSuggestedFans {
                suggestedFansSection
                    .padding(.horizontal, 16)
            }

            favoriteTeamsSection
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .background(cardShellBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(cardBorder)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 22, y: 12)
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.035 : 0.055), radius: 18, y: 3)
        .onAppear {
#if DEBUG
            print("[ProfileIdentityCardDebug] layout=modern_light_social_profile")
#endif
            DebugLogGate.debug("[PokesConsolidation] propsUIRemoved")
            DebugLogGate.debug("[PokesConsolidation] primarySocialSurface=pokes")
            FanReputationEngine.log(reputation)
        }
        .sheet(isPresented: $showHandleSetup) {
            FanGeoIdentitySetupView(viewModel: viewModel, mode: .handleOnly)
        }
        .sheet(isPresented: $showIdentityEditor) {
            identityEditorSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFavoriteTeamsPicker) {
            FavoriteTeamsPickerSheet(
                selectedIDs: Binding(
                    get: { selectedIDSet },
                    set: { newSet in
                        let sorted = Array(newSet).sorted()
                        favoriteTeamIDsRaw = FavoriteTeamsStore.encodeIDs(sorted)
                        Task {
                            await viewModel.syncFavoriteTeamsToSupabase(teamIDs: sorted)
                        }
                    }
                )
            )
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
        .onChange(of: editedUsername) { _, _ in
            scheduleHandleAvailabilityCheck()
        }
        .onChange(of: editedBio) { _, newValue in
            let limited = limitedBio(newValue)
            if limited != newValue {
                editedBio = limited
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

    // MARK: - Pokes highlights

    private var pokesHighlightsSection: some View {
        Button {
            showPokesHistorySheet = true
        } label: {
            HStack(spacing: 11) {
                pokesAvatarStack

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("Pokes")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(
                                viewModel.hasUnseenPokes
                                    ? FGColor.primaryText(colorScheme).opacity(0.88)
                                    : FGColor.mutedText(colorScheme)
                            )
                            .textCase(.uppercase)
                            .tracking(0.7)

                        Image(systemName: "hand.wave.fill")
                            .font(.system(size: 9, weight: .bold))
                            .pokesUnseenWaveIconEmphasis(isActive: viewModel.hasUnseenPokes)

                        if viewModel.hasUnseenPokes {
                            Text("New")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background {
                                    Capsule(style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    FGColor.accentBlue,
                                                    Color(red: 0.22, green: 0.48, blue: 0.96),
                                                    Color(red: 1, green: 0.46, blue: 0.16)
                                                ],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                }
                                .pokesUnseenNewPillEmphasis(isActive: true)
                        }
                    }
                    .pokesUnseenTitleRowEmphasis(isActive: viewModel.hasUnseenPokes)

                    Text(pokesHighlightsCopy)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(incomingPokeTotalCount == 0 ? FGColor.secondaryText(colorScheme) : FGColor.primaryText(colorScheme))
                        .lineLimit(1)

                    Text(pokesHighlightsSubcopy)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isLoadingIncomingPokes {
                    ProgressView()
                        .controlSize(.small)
                        .tint(FGColor.accentBlue)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.72))
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
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

    private var pokesAvatarStack: some View {
        ZStack {
            if uniqueRecentPokersForAvatars.isEmpty {
                Circle()
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    .frame(width: 42, height: 42)
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
                            .offset(x: CGFloat(index) * 18)
                            .zIndex(Double(visiblePokers.count - index))
                    }
                }
                .frame(width: CGFloat(visiblePokers.count - 1) * 18 + 34, height: 36, alignment: .leading)
            }
        }
        .frame(width: 88, alignment: .leading)
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
            size: 34,
            fallbackStyle: .lightOnWhiteChrome,
            imagePlaceholderTint: FGColor.accentBlue
        )
        .overlay {
            Circle()
                .strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 4, y: 2)
    }

    private var pokesHighlightsCopy: String {
        if isLoadingIncomingPokes && incomingPokes.isEmpty {
            return "Loading Pokes..."
        }
        guard incomingPokeTotalCount > 0 else { return "No pokes yet" }
        return incomingPokeTotalCount == 1 ? "1 poke" : "\(incomingPokeTotalCount) pokes"
    }

    private var pokesHighlightsSubcopy: String {
        if let incomingPokesMessage, !incomingPokesMessage.isEmpty {
            return incomingPokesMessage
        }
        if viewModel.hasUnseenPokes {
            return "New pokes since you last checked"
        }
        return incomingPokeTotalCount == 0
            ? "Fans can poke you from your public profile"
            : "Most recent pokes first"
    }

    private var pokesHighlightsAccessibilityLabel: String {
        incomingPokeTotalCount == 0 ? "Pokes, no pokes yet" : "Pokes, \(pokesHighlightsCopy)"
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
                        description: Text("When fans poke you, they'll show up here.")
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
                    Button {
                        Task { await forceRefreshIncomingPokes() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoadingIncomingPokes)
                    .accessibilityLabel("Refresh Pokes")
                }
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
            async let itemsTask = profilePokesService.fetchMyIncomingPokes(limit: Self.incomingPokesHighlightsLimit)
            async let summaryTask = profilePokesService.fetchPokeSummary(targetUserId: authId)
            let items = try await itemsTask
            let summary = try await summaryTask

            await MainActor.run {
                incomingPokes = items
                incomingPokeTotalCount = summary.totalPokes
                incomingPokesMessage = nil
                isLoadingIncomingPokes = false
                ProfilePhase1PersonalizationCache.incomingPokesLoadedAtByAuthId[authId] = Date()
                viewModel.applyIncomingPokesFetch(items)
                acknowledgePokesCardAfterSuccessfulLoad()
            }
            DebugLogGate.debug("[PokesUI] incoming load count=\(items.count) total=\(summary.totalPokes)")
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

    private var suggestedFansSection: some View {
        ProfileSuggestedFansSection(
            suggestions: suggestedFans,
            isLoading: isLoadingSuggestedFans,
            message: suggestedFansMessage,
            sendingRequestIds: sendingSuggestedFanRequestIds,
            chipKind: { chatViewModel.chipKind(forOtherUserId: $0) },
            onAdd: { suggestion in
                Task { await addSuggestedFan(suggestion) }
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
            let suggestions = try await friendSuggestionsService.fetchSuggestions(limit: Self.suggestedFansLimit)
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
            Text(reputation.title.uppercased())
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

                    identityFieldCard(title: "@handle", subtitle: "Unique username for friend search.") {
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
                            Text(handleStatusMessage)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(handleStatusIsPositive ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
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
        if let issue = FanGeoHandleRules.validate(raw) {
            handleStatusMessage = FanGeoHandleRules.validationMessage(for: issue)
            return
        }

        availabilityTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            guard let available = await viewModel.checkUsernameAvailable(raw) else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                if available {
                    handleStatusMessage = "Handle available."
                    handleStatusIsPositive = true
                } else {
                    handleStatusMessage = "That handle is already taken."
                    handleStatusIsPositive = false
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
            statCell(value: gamesWatchedValue, label: "Plans")
            statDivider
            statCell(value: venuesVisitedValue, label: "Venues")
            statDivider
            statCell(value: teamsValue, label: "Teams")
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

    private var gamesWatchedValue: String {
        let n = viewModel.followingTabGoingItems.count
        return n > 0 ? "\(n)" : "—"
    }

    private var venuesVisitedValue: String {
        let n = max(viewModel.favoriteVenueIDs.count, viewModel.followingTabSavedVenues.count)
        return n > 0 ? "\(n)" : "—"
    }

    private var teamsValue: String {
        let n = selectedTeams.count
        return n > 0 ? "\(n)" : "—"
    }

    private var friendsValue: String {
        let n = chatViewModel.friends.count
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
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Favorite teams

    private var favoriteTeamsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Favorite Teams")
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
            } else {
                favoriteTeamsCardRow
            }
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
    }

    private func favoriteTeamSocialCard(team: FavoriteTeam) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                PremiumTeamIdentityOrb(team: team, diameter: 62)
                Spacer(minLength: 0)
                Image(systemName: "star.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.86))

                removeFavoriteTeamButton(team: team)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(team.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)

                Text(team.sport.chipTitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
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
        .shadow(color: team.badgeColor.opacity(colorScheme == .dark ? 0.18 : 0.16), radius: 14, y: 8)
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
        let nextIDs = previousIDs.filter { $0 != team.id }
        guard nextIDs.count != previousIDs.count else { return }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            favoriteTeamIDsRaw = FavoriteTeamsStore.encodeIDs(nextIDs)
        }

        Task {
            let didSync = await viewModel.syncFavoriteTeamsToSupabase(teamIDs: nextIDs)
            if didSync {
#if DEBUG
                print("[FavoriteTeamsProfile] remove success team_id=\(team.id)")
#endif
                return
            }

            await MainActor.run {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    favoriteTeamIDsRaw = FavoriteTeamsStore.encodeIDs(previousIDs)
                }
            }
#if DEBUG
            print("[FavoriteTeamsProfile] remove failed team_id=\(team.id) error=sync_failed")
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

    @Environment(\.colorScheme) private var colorScheme

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
            Text("Suggested Fans")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.7)

            Text("Fans near you with shared teams, venues, or pickup games")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.82))
        }
    }

    private var loadingRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.72))
                        .frame(width: 148, height: 172)
                        .redacted(reason: .placeholder)
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityLabel("Loading suggested fans")
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
            HStack(alignment: .top, spacing: 10) {
                ForEach(suggestions) { suggestion in
                    suggestionCard(suggestion)
                }
            }
            .padding(.vertical, 1)
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
        .frame(width: 154, height: 178, alignment: .top)
        .background(cardBackground)
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.08), radius: 12, y: 7)
        .accessibilityElement(children: .combine)
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
        Text(safeReasonLabel(for: suggestion))
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
            "Same team",
            "Shared venue",
            "Pickup player",
            "Local fan",
            "Sports match"
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
        case "same_team", "shared_team", "team", "favorite_team", "favorite_teams":
            return "Same team"
        case "shared_venue", "venue", "event", "shared_event", "event_interest":
            return "Shared venue"
        case "pickup", "pickup_game", "shared_pickup", "pickup_player":
            return "Pickup player"
        case "local", "local_fan", "nearby":
            return "Local fan"
        case "sports_match", "match", "sports":
            return "Sports match"
        default:
            if suggestion.sharedFavoriteTeamsCount > 0 { return "Same team" }
            if suggestion.sharedEventInterestCount > 0 { return "Shared venue" }
            if suggestion.sharedPickupGameCount > 0 { return "Pickup player" }
            return suggestion.score > 0 ? "Sports match" : "Local fan"
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

