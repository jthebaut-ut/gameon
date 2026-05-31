import Combine
import CoreLocation
import MapKit
import SwiftUI

enum WatchingExpiredVenueGameDiagnostics {
    nonisolated static let enabled = false
}

struct FollowingScreen: View {
    @ObservedObject var viewModel: MapViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    var suppressInitialAutoRefresh = false
    var isFollowingTabSelected: Bool = true

    @Environment(\.colorScheme) private var followingColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var favoriteActionBanner: String?
    @State private var didHandleInitialAutoRefresh = false

    /// Venue events the user marked "Interested" from Following without a Supabase row (table has no status column).
    @AppStorage("gameon.following.interestedOnlyVenueEventIDs") private var interestedOnlyEncoded: String = ""
    @AppStorage(FavoriteTeamsStore.appStorageKey) private var favoriteTeamIDsRaw: String = ""
    @AppStorage(ProGamesFavoriteTeamAutoFollowPreference.enabledKey) private var proGamesAutoFollowFavoriteTeams = false
    @AppStorage(ProGamesFavoriteTeamAutoFollowPreference.windowDaysKey) private var proGamesFavoriteTeamWindowDays = ProGamesFavoriteTeamAutoFollowPreference.Window.next30.rawValue
    @State private var pickupDetailNav: PickupDetailNavigationToken?
    @State private var followingPickupWithdrawConfirm: PickupJoinWithdrawConfirmState?
    @State private var followingPickupWithdrawInFlight = false

    @State private var followingMyPickupClockTick: Date = Date()
    @State private var followingMyPickupFormMode: PickupGameFormMode?
    @State private var followingMyPickupDeleteTarget: PickupGameRow?
    @State private var followingMyPickupOrganizerRequestsGame: PickupGameRow?
    @State private var followingMyPickupDetailGame: PickupGameRow?
    @State private var followingPickupInviteGame: PickupGameRow?
    @State private var followingPickupInviteDetail: PickupGameInviteDisplay?
    @State private var followingPendingPostCreateInviteGame: PickupGameRow?
    @State private var pickupInviteResponseInFlightId: UUID?
    @State private var followingMyPickupBanner: String?
    @State private var followingMyPickupDidScheduleExpiryRefresh = false
    @State private var selectedGoingMode: GoingParticipationMode = .venueGames
    @State private var selectedGoingVenueTab: GoingVenueTab = .games
    @State private var selectedGoingGamesTab: GoingGamesTab = .playing
    @State private var cachedGoingVenueGameItems: [FollowingGoingDisplayItem] = []
    @State private var cachedPlayingGameCards: [PickupGameJoinRequestCardDisplay] = []

    private let followingMyPickupMinuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Nil while Going tab is not selected so lazy mount does not trigger global refresh at launch.
    private var followingTabTaskIdentity: String? {
        guard isFollowingTabSelected else { return nil }
        return viewModel.currentUserAuthId?.uuidString ?? "signedOut"
    }

    private var favoriteTeamAutoFollowTaskIdentity: String? {
        guard isFollowingTabSelected, selectedGoingMode == .proGames else { return nil }
        let auth = viewModel.currentUserAuthId?.uuidString ?? "signedOut"
        return [
            auth,
            proGamesAutoFollowFavoriteTeams ? "on" : "off",
            "\(proGamesFavoriteTeamWindowDays)",
            favoriteTeamIDsRaw
        ].joined(separator: "|")
    }

    var body: some View {
        ZStack {
            Color.clear
                .fanGeoScreenBackground()
                .ignoresSafeArea()

            if viewModel.isAuthenticatedForSocialFeatures {
                if viewModel.hasAuthenticatedVenueOwnerSession {
                    businessFollowingLockedContent
                } else {
                    loggedInContent
                }
            } else {
                loggedOutContent
            }
        }
        .onAppear {
            rebuildFollowingDisplayCaches(reason: "appear")
            refreshFavoriteTeamProGamesIfVisible(reason: "appear")
            if suppressInitialAutoRefresh && !didHandleInitialAutoRefresh {
                didHandleInitialAutoRefresh = true
                return
            }
            guard isFollowingTabSelected else { return }
            guard viewModel.isAuthenticatedForSocialFeatures, viewModel.canUseFollowingTab else { return }
            Task { await reloadFollowingDataForCurrentUser() }
        }
        .onChange(of: viewModel.currentUserAuthId) { _, newId in
            rebuildFollowingDisplayCaches(reason: "authChanged")
            guard isFollowingTabSelected else { return }
            if newId != nil {
                Task { await reloadFollowingDataForCurrentUser() }
            } else {
                clearFollowingUserSpecificState()
                interestedOnlyEncoded = ""
            }
        }
        .task(id: followingTabTaskIdentity) {
            guard isFollowingTabSelected else { return }
            guard viewModel.isAuthenticatedForSocialFeatures, viewModel.canUseFollowingTab else { return }
            await viewModel.refreshFollowingTabDataGloballyUnlessFresh()
            await viewModel.loadMyPickupGameJoinRequestsForFollowing(reason: "goingTabActivation")
            await viewModel.loadIncomingPickupGameInvites()
            await refreshFavoriteTeamProGames(reason: "goingTabActivation")
        }
        .task(id: favoriteTeamAutoFollowTaskIdentity) {
            guard favoriteTeamAutoFollowTaskIdentity != nil else { return }
            await refreshFavoriteTeamProGames(reason: "autoFollowStateChanged")
        }
        .sheet(item: $pickupDetailNav, onDismiss: {
            Task {
                await viewModel.loadMyPickupGameJoinRequestsForFollowing(
                    forceRefresh: true,
                    reason: "pickupDetailDismiss"
                )
            }
        }) { token in
            DiscoverPickupGameDetailSheet(viewModel: viewModel, gameId: token.id)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, isFollowingTabSelected else { return }
            guard viewModel.isAuthenticatedForSocialFeatures, viewModel.canFanUsePickupGamesUI else { return }
            Task {
                await viewModel.loadMyPickupGameJoinRequestsForFollowing(reason: "foreground")
                await viewModel.loadIncomingPickupGameInvites()
            }
        }
        .onChange(of: viewModel.isAuthenticatedForSocialFeatures) { _, _ in
            rebuildFollowingDisplayCaches(reason: "socialAuthChanged")
            Task { await syncFollowingAfterAuthChange() }
        }
        .onChange(of: viewModel.followingTabGoingItems.count) { _, _ in
            rebuildFollowingDisplayCaches(reason: "goingItemsChanged")
        }
        .onChange(of: viewModel.myPickupGameJoinRequestCards) { _, _ in
            rebuildFollowingDisplayCaches(reason: "pickupJoinCardsChanged")
        }
        .onChange(of: viewModel.incomingPickupGameInvites.count) { _, _ in
            prefetchVisibleGoingAvatars(reason: "incomingPickupInvitesChanged")
        }
        .onChange(of: isFollowingTabSelected) { _, visible in
#if DEBUG
            let started = CFAbsoluteTimeGetCurrent()
#endif
            if visible {
                rebuildFollowingDisplayCaches(reason: "followingTabVisible")
                refreshFavoriteTeamProGamesIfVisible(reason: "followingTabVisible")
            }
#if DEBUG
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            print("[TabRenderPerf] tab=going visible=\(visible) renderMs=\(String(format: "%.2f", ms))")
#endif
        }
        .alert(item: $followingPickupWithdrawConfirm) { state in
            Alert(
                title: Text(state.intent.alertTitle),
                message: Text(state.intent.alertMessage),
                primaryButton: .destructive(Text("Yes, withdraw")) {
                    Task { await performFollowingPickupWithdraw(state) }
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(item: $followingMyPickupFormMode) { mode in
            NavigationStack {
                SettingsPickupGameFormView(
                    viewModel: viewModel,
                    mode: mode,
                    onCreated: { row in
                        followingPendingPostCreateInviteGame = row
                    }
                ) {
                    followingMyPickupFormMode = nil
                    Task {
                        await viewModel.loadMyPickupGamesForSettings(forceRefresh: true, reason: "followingFormDismiss")
                        await viewModel.refreshPickupGamesForDiscoverMap(force: true)
                        logFollowingMyPickupGames(action: "formDismissReload")
                    }
                }
            }
        }
        .onChange(of: followingMyPickupFormMode) { _, newValue in
            guard newValue == nil, let row = followingPendingPostCreateInviteGame else { return }
            followingPendingPostCreateInviteGame = nil
            followingPickupInviteGame = row
        }
        .sheet(item: $followingPickupInviteGame, onDismiss: {
            Task {
                await viewModel.loadIncomingPickupGameInvites()
                await viewModel.loadMyPickupGamesForSettings()
            }
        }) { game in
            PickupGameInviteFriendsSheet(viewModel: viewModel, game: game)
                .environmentObject(chatViewModel)
        }
        .sheet(item: $followingPickupInviteDetail) { item in
            PickupGameInviteDetailSheet(
                item: item,
                isResponding: pickupInviteResponseInFlightId == item.id,
                onRespond: { status in
                    await respondToPickupInvite(item, status: status)
                    followingPickupInviteDetail = nil
                }
            )
        }
        .sheet(item: $followingMyPickupOrganizerRequestsGame, onDismiss: {
            Task {
                await viewModel.loadMyPickupGamesForSettings()
                logFollowingMyPickupGames(action: "requestsSheetDismiss")
            }
        }) { game in
            PickupOrganizerRequestsSheet(viewModel: viewModel, game: game)
        }
        .sheet(item: $followingMyPickupDetailGame, onDismiss: {
            Task {
                await viewModel.loadMyPickupGamesForSettings()
                logFollowingMyPickupGames(action: "detailSheetDismiss")
            }
        }) { game in
            NavigationStack {
                ScrollView {
                    SettingsPickupMyGameListCard(
                        viewModel: viewModel,
                        row: game,
                        pendingJoinCount: viewModel.organizerPendingPickupJoinRequests(for: game.id),
                        withdrawnJoinRows: viewModel.pickupOrganizerWithdrawnRequestsByGameId[game.id] ?? [],
                        now: followingMyPickupClockTick,
                        colorScheme: followingColorScheme,
                        onEdit: {
                            followingMyPickupDetailGame = nil
                            followingMyPickupFormMode = .edit(game)
                        },
                        onDelete: {
                            followingMyPickupDetailGame = nil
                            followingMyPickupDeleteTarget = game
                        },
                        onManageRequests: {
                            followingMyPickupDetailGame = nil
                            followingMyPickupOrganizerRequestsGame = game
                        },
                        onInvite: {
                            followingMyPickupDetailGame = nil
                            followingPickupInviteGame = game
                        }
                    )
                    .environmentObject(chatViewModel)
                    .padding(.vertical, 8)
                }
                .fanGeoScreenBackground()
                .navigationTitle("Pickup game")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { followingMyPickupDetailGame = nil }
                    }
                }
            }
        }
        .alert(followingMyPickupDeleteAlertTitle, isPresented: Binding(
            get: { followingMyPickupDeleteTarget != nil },
            set: { if !$0 { followingMyPickupDeleteTarget = nil } }
        )) {
            Button("Keep game", role: .cancel) { followingMyPickupDeleteTarget = nil }
            Button(followingMyPickupDeleteButtonTitle, role: .destructive) {
                guard let row = followingMyPickupDeleteTarget else { return }
                followingMyPickupDeleteTarget = nil
                Task { await performFollowingMyPickupDelete(row) }
            }
        } message: {
            Text(followingMyPickupDeleteAlertMessage)
        }
        .overlay(alignment: .bottom) {
            if let text = followingMyPickupBanner, !text.isEmpty {
                Text(text)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.sm)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding()
            }
        }
    }

    /// Reload Following when fan or business-owner auth changes while a Supabase session may already exist.
    private func syncFollowingAfterAuthChange() async {
        if viewModel.isAuthenticatedForSocialFeatures, viewModel.canUseFollowingTab {
            await reloadFollowingDataForCurrentUser()
        } else {
            clearFollowingUserSpecificState()
            interestedOnlyEncoded = ""
        }
    }

    private func performFollowingPickupWithdraw(_ state: PickupJoinWithdrawConfirmState) async {
        followingPickupWithdrawInFlight = true
        followingPickupWithdrawConfirm = nil
        defer { followingPickupWithdrawInFlight = false }
        do {
            try await viewModel.withdrawMyPickupJoinRequest(requestId: state.requestId, pickupGameId: state.pickupGameId)
        } catch {
            viewModel.showSocialActionToast(error.localizedDescription, isError: true)
        }
    }

    private var followingMyPickupDeleteTargetIsExpired: Bool {
        guard let row = followingMyPickupDeleteTarget,
              let deadline = row.pickupHistoryClientCleanupDeadline() else {
            return false
        }
        return followingMyPickupClockTick >= deadline
    }

    private var followingMyPickupDeleteAlertTitle: String {
        followingMyPickupDeleteTargetIsExpired ? "Clear expired pickup game?" : "Cancel this pickup game?"
    }

    private var followingMyPickupDeleteButtonTitle: String {
        followingMyPickupDeleteTargetIsExpired ? "Clear expired" : "Cancel game"
    }

    private var followingMyPickupDeleteAlertMessage: String {
        followingMyPickupDeleteTargetIsExpired
            ? "This removes the expired hosted pickup game from your active Hosting list."
            : "Players who requested or joined will be notified."
    }

    // MARK: - Logged out

    private var loggedOutContent: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 24)

            FanGeoBrandHeroView(
                title: "Sign in required",
                subtitle: "Sign in to save venues and track games you plan to attend.",
                variant: followingColorScheme == .dark ? .white : .dark,
                logoWidth: 128,
                alignment: .center,
                textAlignment: .center
            )
            .padding(.horizontal, 28)

            Button {
                viewModel.discoverNavigateToAccountForUserAuth = true
            } label: {
                Text("Sign in or create account")
                    .font(.headline)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.accentColor)
            .padding(.horizontal, 28)
            .padding(.top, 8)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 110)
    }

    // MARK: - Business account (fan features locked)

    private var businessFollowingLockedContent: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 24)

            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(FGColor.accentYellow)

            Text("Going")
                .font(FGTypography.screenTitle)
                .foregroundStyle(FGColor.primaryText(followingColorScheme))

            Text(BusinessFanGateCopy.followingLockedBody)
                .font(FGTypography.body)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 110)
        .onAppear {
            viewModel.logBusinessUserGateBlocked(action: "followingTab")
        }
    }

    // MARK: - Logged in

    private var loggedInContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            goingHubHeader
            .padding(.horizontal, FGSpacing.md)
            .padding(.bottom, 8)

            ScrollView {
                goingHubContent
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.bottom, 110)
            }
            .refreshable {
                await viewModel.fetchSavedProGames()
                await viewModel.refreshFollowingTabDataGlobally()
                await viewModel.loadMyPickupGameJoinRequestsForFollowing(
                    forceRefresh: true,
                    reason: "pullToRefresh"
                )
                logFollowingMyPickupGames(action: "pullToRefresh")
                logGoingHubDebug(reason: "pullToRefresh")
            }
            .onReceive(followingMyPickupMinuteTicker) { date in
                followingMyPickupClockTick = date
                scheduleFollowingMyPickupExpiryRefreshIfNeeded(now: date)
            }
        }
        .onAppear {
            logGoingHubDebug(reason: "appear")
        }
    }

    private var goingHubHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Going")
                        .font(FGTypography.screenTitle)
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                        .padding(.top, 8)

                    Text("Games, venues, and pickup plans you're part of.")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                goingInviteBellButton
            }

            if let favoriteActionBanner {
                Text(favoriteActionBanner)
                    .font(FGTypography.metadata)
                    .fontWeight(.semibold)
                    .foregroundStyle(FGColor.accentYellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(FGColor.accentYellow.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: FGRadius.small, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if goingHubShouldShowActivityStrip {
                goingHubActivityStrip
            }
        }
    }

    private var goingInviteBellButton: some View {
        let count = viewModel.incomingPickupGameInvites.count
        return Button {
            selectedGoingMode = .pickupGames
            selectedGoingGamesTab = .invites
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(FGColor.divider(followingColorScheme).opacity(0.7), lineWidth: 1)
                    )

                if count > 0 {
                    Text(count > 9 ? "9+" : "\(count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .padding(.horizontal, count > 9 ? 3 : 0)
                        .background(Color.red.opacity(0.95), in: Capsule())
                        .offset(x: 3, y: -2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(count) pickup game invites" : "Pickup game invites")
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: count)
    }

    private var goingHubContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            goingModeSwitcher

            Group {
                switch selectedGoingMode {
                case .venueGames:
                    goingVenueTabsGroup
                case .pickupGames:
                    goingGamesTabsGroup
                case .proGames:
                    goingProGamesGroup
                }
            }
            .id(selectedGoingMode)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .padding(.top, 6)
    }

    private var goingVenueGameItems: [FollowingGoingDisplayItem] {
        cachedGoingVenueGameItems
    }

    private func rebuildFollowingDisplayCaches(reason: String) {
#if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
#endif
        let sorted = MapViewModel.sortFollowingGoingItemsChronologically(
            viewModel.followingTabGoingItems
                .filter(\.isActiveGoingTabPlan)
        )
        cachedGoingVenueGameItems = sorted
        cachedPlayingGameCards = viewModel.myPickupGameJoinRequestCards.filter { card in
            switch card.pill {
            case .pending, .approved, .declined:
                return true
            case .cancelled, .withdrawing, .canceledByOrganizer:
                return false
            }
        }
        logGoingTabSortDebug(sorted)
        prefetchVisibleGoingAvatars(reason: reason)
#if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        print("[RenderPerf] view=FollowingScreen renderMs=\(String(format: "%.2f", ms)) rebuildReason=\(reason)")
        print("[PickupPlayingDebug] visiblePlayingCount=\(cachedPlayingGameCards.count)")
#endif
    }

    private func prefetchVisibleGoingAvatars(reason: String) {
        var seen = Set<URL>()
        var urls: [URL] = []

        func appendURL(thumbnail: String?, full: String?, refreshToken: UUID) {
            guard let raw = ImageDisplayURL.forListDisplay(
                thumbnail: thumbnail,
                full: full ?? "",
                refreshToken: refreshToken
            ),
                  let url = URL(string: raw),
                  seen.insert(url).inserted else { return }
            urls.append(url)
        }

        for card in cachedPlayingGameCards.prefix(10) {
            appendURL(
                thumbnail: viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: card.organizerUserId),
                full: viewModel.pickupOrganizerAvatarFullForDetail(userId: card.organizerUserId),
                refreshToken: viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: card.organizerUserId)
            )
        }

        for item in viewModel.incomingPickupGameInvites.prefix(6) {
            appendURL(
                thumbnail: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_thumbnail_url),
                full: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_url),
                refreshToken: UserAvatarView.stableRefreshToken(
                    userId: item.invite.inviter_user_id,
                    thumbnailURL: item.inviterProfile?.avatar_thumbnail_url,
                    avatarURL: item.inviterProfile?.avatar_url
                )
            )
        }

        guard !urls.isEmpty else {
#if DEBUG
            print("[SmoothPerf] operation=goingAvatarPrefetch skipped=noURLs durationMs=0 coalesced=false avatarCount=0 reason=\(reason)")
#endif
            return
        }

        Task {
            let startedAt = Date()
            await DiscoverMapImageCache.shared.prefetch(urls: urls, bucket: .avatar)
#if DEBUG
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("[SmoothPerf] operation=goingAvatarPrefetch skipped=none durationMs=\(ms) coalesced=false avatarCount=\(urls.count) reason=\(reason)")
#endif
        }
    }

    private func logGoingTabSortDebug(_ items: [FollowingGoingDisplayItem]) {
#if DEBUG
        let firstStart = items.first.map { goingTabSortDebugStartString(for: $0.venueEvent) } ?? "nil"
        print("[GoingTabSortDebug] count=\(items.count) firstStart=\(firstStart)")
#endif
    }

    private func goingTabSortDebugStartString(for row: VenueEventRow) -> String {
        if let raw = row.scheduled_start_at?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
        let date = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let time = row.event_time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let combined = [date, time].filter { !$0.isEmpty }.joined(separator: " ")
        return combined.isEmpty ? "nil" : combined
    }

    private func watchingVenueGameIsCompleted(_ item: FollowingGoingDisplayItem) -> Bool {
        let completed = VenueGameExpiration.isWatchingCompleted(row: item.venueEvent)
#if DEBUG
        if completed, WatchingExpiredVenueGameDiagnostics.enabled {
            VenueGameExpiration.logAuditOncePerEvaluation(row: item.venueEvent, eventID: item.id)
            print("[WatchingExpiredVenueGame] detected event_id=\(item.id.uuidString.lowercased())")
        }
#endif
        return completed
    }

    private var goingModeSwitcher: some View {
        GameOnSegmentedControl(
            tabs: [
                GameOnSegmentedTab(
                    id: GoingParticipationMode.venueGames,
                    title: GoingParticipationMode.venueGames.title,
                    tint: GoingParticipationMode.venueGames.tint,
                    accessibilityLabel: "Venue-hosted games"
                ),
                GameOnSegmentedTab(
                    id: GoingParticipationMode.pickupGames,
                    title: GoingParticipationMode.pickupGames.title,
                    tint: GoingParticipationMode.pickupGames.tint,
                    showsActivityDot: viewModel.pendingPickupGameJoinRequestCount > 0 || !viewModel.incomingPickupGameInvites.isEmpty,
                    accessibilityLabel: "Pickup and community games",
                    activityAccessibilityLabel: "Pickup activity waiting"
                ),
                GameOnSegmentedTab(
                    id: GoingParticipationMode.proGames,
                    title: GoingParticipationMode.proGames.title,
                    badge: savedProGamesTabBadge,
                    tint: GoingParticipationMode.proGames.tint,
                    accessibilityLabel: "Saved pro games"
                )
            ],
            selection: $selectedGoingMode
        )
    }

    private var goingVenueTabsGroup: some View {
        goingTabbedPanel(title: "Venue Games", subtitle: "Venue-hosted games, sports bars, saved venues, and friends going later.") {
            GameOnSegmentedControl(
                tabs: [
                    GameOnSegmentedTab(id: GoingVenueTab.games, title: "I’m Going", systemImage: "checkmark.circle.fill", tint: FGColor.accentGreen, accessibilityLabel: "I’m Going venue games"),
                    GameOnSegmentedTab(id: GoingVenueTab.saved, title: "Saved", systemImage: "heart.fill", tint: FGColor.accentGreen)
                ],
                selection: $selectedGoingVenueTab
            )
        } content: {
            Group {
                switch selectedGoingVenueTab {
                case .games:
                    venueGamesTabContent
                case .saved:
                    savedVenuesTabContent
                }
            }
            .id(selectedGoingVenueTab)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .onAppear {
#if DEBUG
            print("[GoingTabDebug] renamedWatchingTabToImGoing=true")
            print("[GoingTabDebug] imGoingTabVisible=true")
#endif
        }
    }

    private var goingGamesTabsGroup: some View {
        goingTabbedPanel(title: "Pickup Games", subtitle: "Pickup, practice, and scrimmage activity.") {
            GameOnSegmentedControl(
                tabs: [
                    GameOnSegmentedTab(id: GoingGamesTab.playing, title: "Playing", badge: pickupPlayingTabBadge, tint: FGColor.accentGreen),
                    GameOnSegmentedTab(id: GoingGamesTab.hosting, title: "Hosting", badge: pickupHostingTabBadge, tint: Color.orange),
                    GameOnSegmentedTab(id: GoingGamesTab.invites, title: "Invites", badge: pickupInvitesTabBadge, tint: FGColor.accentBlue)
                ],
                selection: $selectedGoingGamesTab
            )
        } content: {
            Group {
                switch selectedGoingGamesTab {
                case .playing:
                    playingGamesContent
                case .hosting:
                    hostingGamesContent
                case .invites:
                    invitesGamesContent
                }
            }
            .id(selectedGoingGamesTab)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }

    private var goingProGamesGroup: some View {
        goingTabbedPanel(title: "Pro Games", subtitle: "Saved and favorite-team pro games to watch later.") {
            EmptyView()
        } content: {
            savedProGamesContent
        }
    }

    private var savedProGamesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                sectionEyebrow("Saved Games")
                if manualSavedProGamesForDisplay.isEmpty {
                    emptyCard(
                        icon: "heart",
                        title: "No saved pro games yet.",
                        subtitle: "Save a live or scheduled pro game to watch later."
                    )
                } else {
                    VStack(spacing: 12) {
                        ForEach(manualSavedProGamesForDisplay) { game in
                            savedProGameCard(game, badges: savedProGameBadges(for: game))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionEyebrow("Favorite Team Games")
                if proGamesAutoFollowFavoriteTeams {
                    if favoriteTeamProGamesForDisplay.isEmpty {
                        emptyCard(
                            icon: "star",
                            title: "No upcoming pro games found for your favorite teams.",
                            subtitle: "Try a longer Favorite Team Game Window in Settings."
                        )
                    } else {
                        VStack(spacing: 12) {
                            ForEach(favoriteTeamProGamesForDisplay) { autoGame in
                                savedProGameCard(
                                    autoGame.game,
                                    badges: favoriteTeamProGameBadges(),
                                    showsUnsaveButton: false
                                )
                            }
                        }
                    }
                } else {
                    emptyCard(
                        icon: "star",
                        title: "Favorite Team auto-follow is off.",
                        subtitle: "Turn on Favorite Team auto-follow in Settings to see upcoming pro games from your teams."
                    )
                }
            }
        }
        .padding(.top, 6)
    }

    private var manualSavedProGamesForDisplay: [SavedProGame] {
        viewModel.savedProGames.map { viewModel.currentSavedProGameSnapshot($0) }
    }

    private var favoriteTeamProGamesForDisplay: [FavoriteTeamProGame] {
        let manualKeys = Set(manualSavedProGamesForDisplay.map(\.stableKey))
        return viewModel.favoriteTeamProGames.filter { !manualKeys.contains($0.game.stableKey) }
    }

    private func favoriteTeamAutoFollowMatch(for game: SavedProGame) -> FavoriteTeamProGame? {
        viewModel.favoriteTeamProGames.first { $0.game.stableKey == game.stableKey }
    }

    private func savedProGameBadges(for game: SavedProGame) -> [String] {
        var badges = ["Saved"]
        if favoriteTeamAutoFollowMatch(for: game) != nil {
            badges.append("Favorite Team")
        }
        return badges
    }

    private func favoriteTeamProGameBadges() -> [String] {
        ["Favorite Team"]
    }

    private func sectionEyebrow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.8)
            .foregroundStyle(FGColor.mutedText(followingColorScheme))
            .padding(.horizontal, 2)
    }

    private func refreshFavoriteTeamProGamesIfVisible(reason: String) {
        guard isFollowingTabSelected, selectedGoingMode == .proGames else { return }
        Task { await refreshFavoriteTeamProGames(reason: reason) }
    }

    private func refreshFavoriteTeamProGames(reason: String) async {
        guard viewModel.isAuthenticatedForSocialFeatures, viewModel.canUseFollowingTab else {
            await MainActor.run {
                viewModel.favoriteTeamProGames = []
            }
            return
        }
#if DEBUG
        print("[SavedProGames] favoriteTeamAutoFollowRefresh reason=\(reason)")
#endif
        let window = ProGamesFavoriteTeamAutoFollowPreference.Window.resolved(rawValue: proGamesFavoriteTeamWindowDays)
        await viewModel.refreshFavoriteTeamProGames(
            enabled: proGamesAutoFollowFavoriteTeams,
            windowDays: window.rawValue,
            favoriteTeamIDsRaw: favoriteTeamIDsRaw
        )
    }

    private var playingGamesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !viewModel.canFanUsePickupGamesUI {
                emptyCard(
                    icon: "figure.run",
                    title: "Games unavailable",
                    subtitle: "Switch to a fan account to join and play games."
                )
            } else {
                if playingGameCards.isEmpty {
                    emptyCard(
                        icon: "figure.run",
                        title: "No games you’re playing yet.",
                        subtitle: "Join a game to see it here."
                    )
                } else {
                    joinedGamesListContent
                }
            }
        }
        .padding(.top, 6)
        .onAppear {
            guard viewModel.canFanUsePickupGamesUI else { return }
            viewModel.acknowledgePickupFollowingGamesToPlayActivity()
        }
    }

    private var hostingGamesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !viewModel.canFanUsePickupGamesUI {
                emptyCard(
                    icon: "figure.run",
                    title: "Games unavailable",
                    subtitle: "Switch to a fan account to create and manage games."
                )
            } else {
                hostPickupInlineCTA

                if viewModel.myPickupGamesForSettings.isEmpty, viewModel.myRemovedPickupGamesForSettings.isEmpty {
                    emptyCard(
                        icon: "sportscourt.fill",
                        title: "No games you’re hosting yet.",
                        subtitle: "Create a game when you’re ready to play."
                    )
                } else {
                    hostedGamesListContent
                }
            }
        }
        .padding(.top, 6)
        .onAppear {
            guard viewModel.canFanUsePickupGamesUI else { return }
            followingMyPickupClockTick = Date()
            Task {
                await viewModel.loadMyPickupGamesForSettings()
                if let uid = viewModel.currentUserAuthId {
                    await viewModel.refreshPickupCreatorPublicRatingStats(creatorUserIds: [uid])
                }
                logFollowingMyPickupGames(action: "gamesListAppear")
            }
            scheduleFollowingMyPickupExpiryRefreshIfNeeded(now: Date())
        }
    }

    private var invitesGamesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !viewModel.canFanUsePickupGamesUI {
                emptyCard(
                    icon: "envelope",
                    title: "Invites unavailable",
                    subtitle: "Switch to a fan account to receive pickup game invites."
                )
            } else if viewModel.incomingPickupGameInvites.isEmpty {
                emptyCard(
                    icon: "envelope.open",
                    title: "No pending invites",
                    subtitle: "Friend invites to pickup, practice, and scrimmage games will appear here."
                )
            } else {
                incomingPickupGameInvitesContent
            }
        }
        .padding(.top, 6)
        .onAppear {
            guard viewModel.canFanUsePickupGamesUI else { return }
            Task { await viewModel.loadIncomingPickupGameInvites() }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: viewModel.incomingPickupGameInvites.count)
    }

    private var pickupPlayingTabBadge: String? {
        let count = viewModel.pickupActivityCount
        guard count > 0 else { return nil }
        return count > 9 ? "9+" : "\(count)"
    }

    private var savedProGamesTabBadge: String? {
        let count = manualSavedProGamesForDisplay.count + favoriteTeamProGamesForDisplay.count
        guard count > 0 else { return nil }
        return count > 9 ? "9+" : "\(count)"
    }

    private var playingGameCards: [PickupGameJoinRequestCardDisplay] {
        cachedPlayingGameCards
    }

    private var pickupHostingTabBadge: String? {
        let count = viewModel.pendingPickupGameJoinRequestCount
        guard count > 0 else { return nil }
        return count > 9 ? "9+ Pending" : "\(count) Pending"
    }

    private var pickupInvitesTabBadge: String? {
        let count = viewModel.incomingPickupGameInvites.count
        guard count > 0 else { return nil }
        return count > 9 ? "9+" : "\(count)"
    }

    private func goingTabbedPanel<Tabs: View, Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder tabs: () -> Tabs,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(FGColor.mutedText(followingColorScheme))
                Text(subtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            tabs()

            Divider()
                .overlay(FGColor.divider(followingColorScheme).opacity(0.65))
                .padding(.top, 2)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(followingColorScheme == .dark ? 0.38 : 0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(FGColor.divider(followingColorScheme).opacity(0.72), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(followingColorScheme == .dark ? 0.20 : 0.055), radius: 10, y: 3)
    }

    private func goingCategoryBlock<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(FGColor.mutedText(followingColorScheme))

            content()
        }
    }

    private var goingHubParticipationSummaryCard: some View {
        HStack(spacing: 12) {
            goingHubMetricPill(
                value: viewModel.myPickupGamesForSettings.count + viewModel.myPickupGameJoinRequestCards.count,
                label: "Pickup",
                tint: FGColor.accentGreen
            )
            goingHubMetricPill(
                value: viewModel.followingTabGoingItems.count,
                label: "I’m Going",
                tint: Color.orange
            )
            goingHubMetricPill(
                value: chatViewModel.friends.count,
                label: "Social",
                tint: FGColor.accentBlue
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 22))
    }

    private func goingHubMetricPill(value: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value > 0 ? "\(value)" : "0")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(followingColorScheme))
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(tint.opacity(followingColorScheme == .dark ? 0.13 : 0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var goingHubUpcomingSubtitle: String {
        let attendance = viewModel.followingTabGoingItems.count
        let joined = viewModel.myPickupGameJoinRequestCards.count
        let hosting = viewModel.myPickupGamesForSettings.count
        let total = attendance + joined + hosting
        guard total > 0 else { return "Your next games and plans will collect here." }
        if total == 1 { return "1 upcoming thing you’re part of." }
        return "\(total) upcoming things you’re part of."
    }

    private var goingHubPickupActivityCount: Int {
        viewModel.pendingPickupGameJoinRequestCount + viewModel.pickupActivityCount
    }

    private var goingHubActivityBadgeState: String {
        if viewModel.pendingPickupGameJoinRequestCount > 0 {
            return "pendingResponse:\(viewModel.pendingPickupGameJoinRequestCount)"
        }
        if viewModel.pickupActivityCount > 0 || viewModel.hasUnreadPickupActivity {
            return "pickupActivity:\(max(viewModel.pickupActivityCount, 1))"
        }
        return "none"
    }

    private var goingHubShouldShowActivityStrip: Bool {
        goingHubActivityBadgeState != "none"
    }

    private var goingHubActivityStrip: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Color.orange.opacity(0.92))
                .frame(width: 7, height: 7)

            Text(goingHubActivityText)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(followingColorScheme))
                .lineLimit(2)

            Spacer(minLength: 0)

            Text("Pickup")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.orange.opacity(0.95))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(followingColorScheme == .dark ? 0.16 : 0.11), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 16))
        .accessibilityLabel(goingHubActivityText)
    }

    private var goingHubActivityText: String {
        if viewModel.pendingPickupGameJoinRequestCount == 1 {
            return "1 player waiting to join."
        }
        if viewModel.pendingPickupGameJoinRequestCount > 1 {
            return "\(viewModel.pendingPickupGameJoinRequestCount) players waiting to join."
        }
        if viewModel.pickupActivityCount == 1 {
            return "New activity on a pickup game you joined."
        }
        if viewModel.pickupActivityCount > 1 {
            return "\(viewModel.pickupActivityCount) pickup games have new activity."
        }
        return "Pickup activity is waiting in Going."
    }

    private func goingHubSection<Content: View>(
        eyebrow: String,
        title: String,
        subtitle: String,
        icon: String,
        activityCount: Int?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FGColor.accentGreen)
                    .frame(width: 28, height: 28)
                    .background(FGColor.accentGreen.opacity(followingColorScheme == .dark ? 0.16 : 0.11), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(FGColor.mutedText(followingColorScheme))
                    Text(title)
                        .font(FGTypography.sectionTitle)
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    Text(subtitle)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if let activityCount, activityCount > 0 {
                    goingHubSmallBadge(count: activityCount)
                }
            }

            content()
        }
    }

    private func goingHubSmallBadge(count: Int) -> some View {
        let label = count > 9 ? "9+" : "\(count)"
        return Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, count > 9 ? 4 : 0)
            .background(Color.orange.opacity(0.92), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
            .accessibilityLabel("\(count) pickup activity items")
    }

    private var hostPickupInlineCTA: some View {
        Button {
            openCreatePickupFromGoing()
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(FGColor.accentGreen, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Create Game")
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    Text("Create a casual game and manage it here.")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FGColor.mutedText(followingColorScheme))
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canFanUsePickupGamesUI)
        .opacity(viewModel.canFanUsePickupGamesUI ? 1 : 0.55)
        .accessibilityLabel("Create Game")
    }

    private var venueGamesTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if goingVenueGameItems.isEmpty {
                emptyCard(
                    icon: "checkmark.circle.fill",
                    title: "No games yet",
                    subtitle: "Venue games you join will appear here."
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(goingVenueGameItems) { item in
                        goingPlanCard(item, isCompleted: watchingVenueGameIsCompleted(item))
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private var savedVenuesTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.followingTabSavedVenues.isEmpty {
                emptyCard(
                    icon: "heart",
                    title: "No favorite venues yet.",
                    subtitle: "Save bars and watch spots from Discover."
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(viewModel.followingTabSavedVenues) { bar in
                        venueCard(bar)
                    }
                }
                .animation(.spring(response: 0.36, dampingFraction: 0.86), value: viewModel.favoriteVenueIDs)
            }
        }
        .padding(.top, 6)
    }

    private func savedProGameCard(
        _ game: SavedProGame,
        badges: [String],
        showsUnsaveButton: Bool = true
    ) -> some View {
        let sportType = game.liveSportVisualType
        let accent = sportType.catalogAccent
        let featuredEvent = savedProGameFeaturedEvent(game)

        return HStack(alignment: .top, spacing: 14) {
            ProGameSportBadgeView(
                sportType: sportType,
                diameter: 56,
                isFeatured: featuredEvent != nil
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let featuredEvent {
                        savedProGameFeaturedBadge(featuredEvent, accent: accent)
                    }

                    Text(savedProGameStatusText(game))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(statusTint(for: game, fallback: accent))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(statusTint(for: game, fallback: accent).opacity(followingColorScheme == .dark ? 0.18 : 0.10))
                        )
                }

                if !badges.isEmpty {
                    savedProGameStatusBadges(badges, accent: accent)
                }

                Text(savedProGameTitle(game))
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(savedProGameDateLine(game))
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .lineLimit(1)

                Text("\(AppSportCatalog.displayLabel(forSportToken: game.sport)) · \(game.league)")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let scoreLine = savedProGameScoreLine(game) {
                    Text(scoreLine)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                        .lineLimit(1)
                }

                if let tv = game.tvSummary, !tv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(tv, systemImage: "tv.fill")
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if showsUnsaveButton {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        viewModel.removeSavedProGame(id: game.stableKey)
                        viewModel.showSocialActionToast("Removed from Pro Games.", isError: false)
                    }
                } label: {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.red.opacity(0.95))
                        .frame(width: 32, height: 32)
                        .background(Color.red.opacity(followingColorScheme == .dark ? 0.18 : 0.10), in: Circle())
                        .overlay(Circle().strokeBorder(Color.red.opacity(followingColorScheme == .dark ? 0.38 : 0.24), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Unsave pro game")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(accent.opacity(followingColorScheme == .dark ? 0.38 : 0.22), lineWidth: 1)
        )
    }

    private func savedProGameStatusBadges(_ badges: [String], accent: Color) -> some View {
        HStack(spacing: 6) {
            ForEach(badges, id: \.self) { badge in
                Label(badge, systemImage: badge == "Saved" ? "heart.fill" : "star.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(badge == "Saved" ? Color.red.opacity(0.95) : accent)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill((badge == "Saved" ? Color.red : accent).opacity(followingColorScheme == .dark ? 0.18 : 0.10))
                    )
            }
        }
    }

    private func savedProGameFeaturedEvent(_ game: SavedProGame) -> FeaturedEvent? {
        guard let slug = game.featuredEventSlug?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty else {
            return nil
        }
        let normalizedSlug = LiveMatchFilters.normalizedSearchText(slug)
        return viewModel.activeFeaturedEvents.first {
            LiveMatchFilters.normalizedSearchText($0.slug) == normalizedSlug
        } ?? FeaturedEvent.fallbackEvents.first {
            LiveMatchFilters.normalizedSearchText($0.slug) == normalizedSlug
        }
    }

    private func savedProGameFeaturedBadge(_ featuredEvent: FeaturedEvent, accent: Color) -> some View {
        Text(featuredEvent.chipTitle)
            .font(.caption2.weight(.bold))
            .foregroundStyle(accent)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(accent.opacity(followingColorScheme == .dark ? 0.18 : 0.10)))
    }

    private func savedProGameTitle(_ game: SavedProGame) -> String {
        "\(savedProGameTeamName(game.awayTeam)) at \(savedProGameTeamName(game.homeTeam))"
    }

    private func savedProGameTeamName(_ teamName: String) -> String {
        let trimmed = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              CountryFlagHelper.isCountry(trimmed),
              let flag = CountryFlagHelper.flag(for: trimmed),
              !flag.isEmpty else {
            return trimmed
        }
        return "\(flag) \(trimmed)"
    }

    private func savedProGameDateLine(_ game: SavedProGame) -> String {
        let date = game.startTime.formatted(.dateTime.month(.abbreviated).day().year())
        let time = CompactGameTimeFormatter.timeWithZone(
            for: game.startTime,
            timeZoneOption: viewModel.selectedTimeZone
        )
        return "\(date) · \(time)"
    }

    private func savedProGameStatusText(_ game: SavedProGame) -> String {
        switch game.matchStatus {
        case .live:
            return "LIVE"
        case .halfTime:
            return "HT"
        case .fullTime:
            return "Final"
        case .scheduled:
            return "Scheduled"
        }
    }

    private func savedProGameScoreLine(_ game: SavedProGame) -> String? {
        guard game.matchStatus.isHappeningNow || game.matchStatus == .fullTime else { return nil }
        return "\(game.awayTeam) \(game.scoreAway) · \(game.homeTeam) \(game.scoreHome)"
    }

    private func statusTint(for game: SavedProGame, fallback: Color) -> Color {
        game.matchStatus.isHappeningNow ? FGColor.dangerRed : fallback
    }

    private var joinedGamesListContent: some View {
        let _: Void = logPickupPerfRender(mode: "Playing", rowCount: playingGameCards.count, renderPath: "LazyVStack+EquatableRenderCard")
        return LazyVStack(alignment: .leading, spacing: 12) {
            if viewModel.isPickupFollowingJoinListRefreshing && !playingGameCards.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Refreshing games...")
                        .font(FGTypography.caption.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                }
                .padding(.horizontal, 4)
            }

            if playingGameCards.isEmpty {
                emptyCard(
                    icon: "figure.run",
                    title: "No games you’re playing yet.",
                    subtitle: "Join a game to see it here."
                )
            } else {
                ForEach(playingGameCards) { card in
                    EquatableRenderCard(token: pickupPlayingCardRenderToken(for: card)) {
                        pickupGameJoinCard(card)
                    }
                    .equatable()
                }
            }
        }
    }

    @ViewBuilder
    private var incomingPickupGameInvitesContent: some View {
        if !viewModel.incomingPickupGameInvites.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(viewModel.incomingPickupGameInvites) { item in
                    EquatableRenderCard(token: pickupInviteRenderToken(for: item)) {
                        pickupGameInviteCard(item)
                    }
                    .equatable()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    private func pickupInviteRenderToken(for item: PickupGameInviteDisplay) -> PickupInviteRenderToken {
        PickupInviteRenderToken(
            id: item.id,
            game: item.game,
            inviterName: pickupInviteInviterName(item),
            inviterAvatarThumbnailURL: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_thumbnail_url),
            inviterAvatarURL: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_url),
            isBusy: pickupInviteResponseInFlightId == item.id,
            colorScheme: followingColorScheme
        )
    }

    private func pickupGameInviteCard(_ item: PickupGameInviteDisplay) -> some View {
        let game = item.game
        let inviterName = pickupInviteInviterName(item)
        let location = [game.address, game.city, game.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let isBusy = pickupInviteResponseInFlightId == item.id

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                pickupInviteInviterAvatar(item, size: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(inviterName) invited you")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    HStack(alignment: .top, spacing: 8) {
                        SportArtworkIconView(sport: game.sport, diameter: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(game.title)
                                .font(FGTypography.cardTitle)
                                .foregroundStyle(FGColor.primaryText(followingColorScheme))
                                .lineLimit(2)
                            GameFormatBadgeView(format: game.gameFormat, colorScheme: followingColorScheme)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if let dateLine = game.pickupDateWithCompactTimeRange {
                Label(dateLine, systemImage: "calendar")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
            }
            if !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .lineLimit(2)
            }
            Label(spotsOpenLine(for: game), systemImage: "person.3")
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))

            Button {
                followingPickupInviteDetail = item
            } label: {
                HStack(spacing: 6) {
                    Text("View invite details")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                pickupInviteResponseButton("Accept", tint: FGColor.accentGreen, disabled: isBusy) {
                    await respondToPickupInvite(item, status: "accepted")
                }
                pickupInviteResponseButton("Maybe", tint: Color.orange, disabled: isBusy) {
                    await respondToPickupInvite(item, status: "maybe")
                }
                pickupInviteResponseButton("Decline", tint: Color.red.opacity(0.9), disabled: isBusy) {
                    await respondToPickupInvite(item, status: "declined")
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(followingColorScheme == .dark ? 0.38 : 0.24), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            followingPickupInviteDetail = item
        }
    }

    private func pickupInviteResponseButton(
        _ title: String,
        tint: Color,
        disabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            if disabled {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                Text(title)
                    .font(FGTypography.metadata.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(disabled)
    }

    private func respondToPickupInvite(_ item: PickupGameInviteDisplay, status: String) async {
        pickupInviteResponseInFlightId = item.id
        let priorInvites = viewModel.incomingPickupGameInvites
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            viewModel.incomingPickupGameInvites.removeAll { $0.id == item.id }
        }
        if status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "accepted" {
            FGInteractionHaptics.success()
        } else {
            FGInteractionHaptics.selection()
        }
        defer {
            pickupInviteResponseInFlightId = nil
            if viewModel.incomingPickupGameInvites.isEmpty && priorInvites.count > 1 {
                Task { await viewModel.loadIncomingPickupGameInvites() }
            }
        }
        await viewModel.respondToPickupGameInvite(item.invite, status: status)
    }

    private func pickupInviteInviterAvatar(_ item: PickupGameInviteDisplay, size: CGFloat) -> some View {
        UserAvatarView(
            avatarThumbnailURL: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_thumbnail_url),
            avatarURL: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_url),
            avatarDisplayRefreshToken: UserAvatarView.stableRefreshToken(
                userId: item.invite.inviter_user_id,
                thumbnailURL: item.inviterProfile?.avatar_thumbnail_url,
                avatarURL: item.inviterProfile?.avatar_url
            ),
            displayName: pickupInviteInviterName(item),
            email: item.inviterProfile?.email ?? "",
            size: size,
            fallbackStyle: followingColorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
        )
    }

    private func pickupInviteInviterName(_ item: PickupGameInviteDisplay) -> String {
        let display = item.inviterProfile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !display.isEmpty { return display }
        let username = item.inviterProfile?.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !username.isEmpty { return username }
        return "A friend"
    }

    private func spotsOpenLine(for game: PickupGameRow) -> String {
        let open = game.pickupOpenSlotsRemaining
        if open == 1 { return "1 spot open" }
        return "\(open) spots open"
    }

    private var hostedGamesListContent: some View {
        let hostingRowCount = viewModel.myPickupGamesForSettings.count + viewModel.myRemovedPickupGamesForSettings.count
        let _: Void = logPickupPerfRender(mode: "Hosting", rowCount: hostingRowCount, renderPath: "LazyVStack+EquatableRenderCard")
        return LazyVStack(alignment: .leading, spacing: 12) {
            if viewModel.myPickupGamesForSettings.isEmpty, viewModel.myRemovedPickupGamesForSettings.isEmpty {
                hostingEmptyStateCard
            } else {
                ForEach(viewModel.myPickupGamesForSettings) { row in
                    let pendingHere = viewModel.organizerPendingPickupJoinRequests(for: row.id)
                    let withdrawnRows = viewModel.pickupOrganizerWithdrawnRequestsByGameId[row.id] ?? []
                    EquatableRenderCard(
                        token: PickupHostedCardRenderToken(
                            row: row,
                            pendingJoinCount: pendingHere,
                            withdrawnJoinRows: withdrawnRows,
                            now: followingMyPickupClockTick,
                            colorScheme: followingColorScheme
                        )
                    ) {
                        SettingsPickupMyGameListCard(
                            viewModel: viewModel,
                            row: row,
                            pendingJoinCount: pendingHere,
                            withdrawnJoinRows: withdrawnRows,
                            now: followingMyPickupClockTick,
                            colorScheme: followingColorScheme,
                            onEdit: {
                                logFollowingMyPickupGames(action: "editTap", selectedGameId: row.id)
                                followingMyPickupFormMode = .edit(row)
                            },
                            onDelete: {
                                logFollowingMyPickupGames(action: "cancelGameTap", selectedGameId: row.id)
                                followingMyPickupDeleteTarget = row
                            },
                            onManageRequests: {
                                logFollowingMyPickupGames(action: "manageRequestsTap", selectedGameId: row.id)
                                followingMyPickupOrganizerRequestsGame = row
                            },
                            displayStyle: .followingCompact,
                            onOpenDetails: {
                                logFollowingMyPickupGames(action: "openDetailSheet", selectedGameId: row.id)
                                followingMyPickupDetailGame = row
                            },
                            onInvite: {
                                logFollowingMyPickupGames(action: "inviteTap", selectedGameId: row.id)
                                followingPickupInviteGame = row
                            },
                            onOpenMap: {
                                openHostedPickupGameOnDiscoverMap(row)
                            }
                        )
                        .environmentObject(chatViewModel)
                    }
                    .equatable()
                }

                if !viewModel.myRemovedPickupGamesForSettings.isEmpty {
                    Text("History")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    ForEach(viewModel.myRemovedPickupGamesForSettings) { row in
                        SettingsPickupRemovedHistoryCard(
                            viewModel: viewModel,
                            row: row,
                            withdrawnJoinRows: viewModel.pickupOrganizerWithdrawnRequestsByGameId[row.id] ?? [],
                            now: followingMyPickupClockTick,
                            colorScheme: followingColorScheme,
                            useCompactCopy: true
                        )
                    }
                }
            }
        }
    }

    private func pickupPlayingCardRenderToken(for card: PickupGameJoinRequestCardDisplay) -> PickupPlayingCardRenderToken {
        let resolvedGame = viewModel.resolvedPickupGameRow(for: card.pickupGameId)
        return PickupPlayingCardRenderToken(
            card: card,
            resolvedGame: resolvedGame,
            organizerAvatarThumbnailURL: viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: card.organizerUserId),
            organizerAvatarURL: viewModel.pickupOrganizerAvatarFullForDetail(userId: card.organizerUserId),
            organizerAvatarRefreshToken: viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: card.organizerUserId),
            organizerEmail: viewModel.pickupOrganizerEmailForDetail(userId: card.organizerUserId),
            creatorTrustStats: viewModel.pickupCreatorTrustStats(for: card.organizerUserId),
            currentUserId: viewModel.currentUserAuthId,
            hasSubmittedCreatorRating: viewModel.hasSubmittedPickupCreatorRating(for: card.pickupGameId),
            hasUnreadActivity: viewModel.pickupFollowingUnreadActivityGameIds.contains(card.pickupGameId),
            isRefreshSpinning: viewModel.pickupFollowingCardRefreshSpinGameId == card.pickupGameId,
            isWithdrawInFlight: followingPickupWithdrawInFlight,
            lastJoinStatusRefreshAt: viewModel.lastJoinStatusRefreshAt,
            colorScheme: followingColorScheme
        )
    }

    private var hostingEmptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "sportscourt.fill")
                .font(.largeTitle)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))

            Text("No games you’re hosting yet.")
                .font(FGTypography.cardTitle)
                .foregroundStyle(FGColor.primaryText(followingColorScheme))

            Text("Create a game when you’re ready to play.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                .multilineTextAlignment(.center)

            Button {
                openCreatePickupFromGoing()
            } label: {
                Text("Create Game")
                    .font(FGTypography.metadata.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(FGColor.accentGreen)
            .padding(.top, 2)
            .accessibilityLabel("Create Game")
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 22))
    }

    // MARK: - Session / cache (Following tab only)

    private func clearFollowingUserSpecificState() {
        viewModel.clearFollowingTabCaches()
        viewModel.favoriteVenueIDs = []
        viewModel.venueEventInterestIDs = []
        viewModel.interestedVenueEventKeys = []
        viewModel.incomingPickupGameInvites = []
        viewModel.favoriteTeamProGames = []
    }

    private func reloadFollowingDataForCurrentUser() async {
        await viewModel.fetchSavedProGames()
        await viewModel.refreshFollowingTabDataGlobally()
        await viewModel.loadMyPickupGameJoinRequestsForFollowing(
            forceRefresh: true,
            reason: "authOrInitialReload"
        )
        await viewModel.loadIncomingPickupGameInvites()
        await refreshFavoriteTeamProGames(reason: "authOrInitialReload")
    }

#if DEBUG
    private func logFollowingMyPickupGames(action: String, selectedGameId: UUID? = nil) {
        let active = viewModel.myPickupGamesForSettings.count
        let hist = viewModel.myRemovedPickupGamesForSettings.count
        print("[FollowingMyPickupGames] loadedCount=\(active + hist)")
        print("[FollowingMyPickupGames] activeCount=\(active)")
        print("[FollowingMyPickupGames] historyCount=\(hist)")
        if let id = selectedGameId {
            print("[FollowingMyPickupGames] selectedGameId=\(id.uuidString.lowercased())")
        } else {
            print("[FollowingMyPickupGames] selectedGameId=")
        }
        print("[FollowingMyPickupGames] action=\(action)")
    }
#else
    private func logFollowingMyPickupGames(action: String, selectedGameId: UUID? = nil) {
        _ = action
        _ = selectedGameId
    }
#endif

    private func logPickupPerfRender(mode: String, rowCount: Int, renderPath: String) {
#if DEBUG
        print("[PickupPerf] screen=Going mode=\(mode) rowCount=\(rowCount) renderPath=\(renderPath) freshnessSkip=false forcedReload=false")
#else
        _ = mode
        _ = rowCount
        _ = renderPath
#endif
    }

    private func openCreatePickupFromGoing() {
        guard viewModel.canFanUsePickupGamesUI else { return }
        logGoingHubDebug(reason: "createPickupTapped", createPickupTapped: true)
        followingMyPickupFormMode = .add
    }

    private func openHostedPickupGameOnDiscoverMap(_ row: PickupGameRow) {
        logFollowingMyPickupGames(action: "openMap", selectedGameId: row.id)
        viewModel.requestDiscoverFocusForPickupGame(id: row.id, snapshot: row)
    }

    private func openPlayingPickupGameOnDiscoverMap(_ card: PickupGameJoinRequestCardDisplay) {
        logFollowingMyPickupGames(action: "openPlayingMap", selectedGameId: card.pickupGameId)
        viewModel.requestDiscoverFocusForPickupGame(
            id: card.pickupGameId,
            snapshot: viewModel.resolvedPickupGameRow(for: card.pickupGameId)
        )
    }

#if DEBUG
    private func logGoingHubDebug(reason: String, createPickupTapped: Bool = false) {
        print("[GoingStructureDebug] venueGamesGoingCount=\(goingVenueGameItems.count)")
        print("[GoingStructureDebug] favoriteVenuesCount=\(viewModel.followingTabSavedVenues.count)")
        print("[GoingStructureDebug] pickupPlayingCount=\(viewModel.myPickupGameJoinRequestCards.count)")
        print("[GoingStructureDebug] pickupHostingCount=\(viewModel.myPickupGamesForSettings.count)")
        print("[GoingStructureDebug] hostPickupTapped=\(createPickupTapped)")
        let emptySections = goingStructureEmptySections()
        if emptySections.isEmpty {
            print("[GoingStructureDebug] sectionEmptyState=none")
        } else {
            for section in emptySections {
                print("[GoingStructureDebug] sectionEmptyState=\(section)")
            }
        }
        print("[GoingStructureDebug] reason=\(reason)")
    }
#else
    private func logGoingHubDebug(reason: String, createPickupTapped: Bool = false) {
        _ = reason
        _ = createPickupTapped
    }
#endif

    private func goingStructureEmptySections() -> [String] {
        var sections: [String] = []
        if goingVenueGameItems.isEmpty { sections.append("I’m Going") }
        if viewModel.followingTabSavedVenues.isEmpty { sections.append("Saved") }
        if viewModel.myPickupGameJoinRequestCards.isEmpty { sections.append("Playing") }
        if viewModel.myPickupGamesForSettings.isEmpty { sections.append("Hosting") }
        return sections
    }

    private func scheduleFollowingMyPickupExpiryRefreshIfNeeded(now: Date) {
        guard !followingMyPickupDidScheduleExpiryRefresh else { return }
        let rows = viewModel.myPickupGamesForSettings + viewModel.myRemovedPickupGamesForSettings
        let anyPast = rows.contains { row in
            guard let deadline = row.pickupHistoryClientCleanupDeadline() else { return false }
            return now >= deadline
        }
        guard anyPast else { return }
        followingMyPickupDidScheduleExpiryRefresh = true
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await viewModel.loadMyPickupGamesForSettings(forceRefresh: true, reason: "followingPostCleanupDeadline")
            logFollowingMyPickupGames(action: "postCleanupDeadlineRefresh")
        }
    }

    private func performFollowingMyPickupDelete(_ row: PickupGameRow) async {
        do {
            try await viewModel.deletePickupGame(id: row.id)
            followingMyPickupBanner = nil
            await viewModel.loadMyPickupGamesForSettings(forceRefresh: true, reason: "followingDeleteSuccess")
            await viewModel.refreshPickupGamesForDiscoverMap(force: true)
            logFollowingMyPickupGames(action: "deleteGameSuccess", selectedGameId: row.id)
        } catch {
            followingMyPickupBanner = error.localizedDescription
            logFollowingMyPickupGames(action: "deleteGameFailed", selectedGameId: row.id)
        }
    }

    // MARK: - Attendance actions

    private func setInterestedOnlyLocally(_ venueEventID: UUID, _ add: Bool) {
        var set = decodeInterestedOnlyUUIDs(from: interestedOnlyEncoded)
        if add {
            set.insert(venueEventID)
        } else {
            set.remove(venueEventID)
        }
        interestedOnlyEncoded = encodeInterestedOnlyUUIDs(set)
    }

    @MainActor
    private func applyAttendance(_ item: FollowingGoingDisplayItem, target: FollowingAttendanceTarget) async {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }

        let previousInterestedOnly = interestedOnlyEncoded
        let previousGoingItems = viewModel.followingTabGoingItems
        let previousCachedGoingItems = cachedGoingVenueGameItems
        let previousGoingInterestCounts = viewModel.followingTabGoingInterestCounts
        let previousServerGoingIDs = viewModel.followingTabUserVenueEventInterestIDs
        let oldStatus = item.goingTabStatusDebugValue
        let newStatus = target.goingTabStatusDebugValue
        var ok = true

#if DEBUG
        print("[FollowingState] attendance action event=\(item.id.uuidString) action=\(target)")
#endif

        switch target {
        case .going:
            if item.isServerGoing && !item.isInterestedOnlyLocal {
                logGoingTabStatusDebug(
                    eventID: item.id,
                    oldStatus: oldStatus,
                    newStatus: newStatus,
                    includedInGoingTab: true,
                    optimisticUpdate: false,
                    backendSaved: true
                )
                logGoingStatusOptimistic(
                    before: oldStatus,
                    after: newStatus,
                    eventID: item.id,
                    localUpdated: false,
                    backendSynced: true,
                    rollback: false
                )
                return
            }
            setInterestedOnlyLocally(item.id, false)
            applyOptimisticGoingTabAttendance(item, target: target)
            logGoingStatusOptimistic(
                before: oldStatus,
                after: newStatus,
                eventID: item.id,
                localUpdated: true,
                backendSynced: nil,
                rollback: false
            )
            logGoingTabStatusDebug(
                eventID: item.id,
                oldStatus: oldStatus,
                newStatus: newStatus,
                includedInGoingTab: true,
                optimisticUpdate: true,
                backendSaved: nil
            )
            ok = await syncGoingStatusToBackend(eventID: item.id, isGoing: true)
        case .interested:
            if !item.isServerGoing && item.isInterestedOnlyLocal {
                logGoingTabStatusDebug(
                    eventID: item.id,
                    oldStatus: oldStatus,
                    newStatus: newStatus,
                    includedInGoingTab: true,
                    optimisticUpdate: false,
                    backendSaved: true
                )
                logGoingStatusOptimistic(
                    before: oldStatus,
                    after: newStatus,
                    eventID: item.id,
                    localUpdated: false,
                    backendSynced: true,
                    rollback: false
                )
                return
            }
            setInterestedOnlyLocally(item.id, true)
            applyOptimisticGoingTabAttendance(item, target: target)
            logGoingStatusOptimistic(
                before: oldStatus,
                after: newStatus,
                eventID: item.id,
                localUpdated: true,
                backendSynced: nil,
                rollback: false
            )
            logGoingTabStatusDebug(
                eventID: item.id,
                oldStatus: oldStatus,
                newStatus: newStatus,
                includedInGoingTab: true,
                optimisticUpdate: true,
                backendSaved: nil
            )
            if item.isServerGoing {
                ok = await syncGoingStatusToBackend(eventID: item.id, isGoing: false)
            }
        case .notGoing:
            guard item.isActiveGoingTabPlan else {
                logGoingTabStatusDebug(
                    eventID: item.id,
                    oldStatus: oldStatus,
                    newStatus: newStatus,
                    includedInGoingTab: false,
                    optimisticUpdate: false,
                    backendSaved: true
                )
                logGoingStatusOptimistic(
                    before: oldStatus,
                    after: newStatus,
                    eventID: item.id,
                    localUpdated: false,
                    backendSynced: true,
                    rollback: false
                )
                return
            }
            setInterestedOnlyLocally(item.id, false)
            applyOptimisticGoingTabAttendance(item, target: target)
            logGoingStatusOptimistic(
                before: oldStatus,
                after: newStatus,
                eventID: item.id,
                localUpdated: true,
                backendSynced: nil,
                rollback: false
            )
            logGoingTabStatusDebug(
                eventID: item.id,
                oldStatus: oldStatus,
                newStatus: newStatus,
                includedInGoingTab: false,
                optimisticUpdate: true,
                backendSaved: nil
            )
            if item.isServerGoing {
                ok = await syncGoingStatusToBackend(eventID: item.id, isGoing: false)
            }
        }

        guard ok else {
#if DEBUG
            print("[FollowingState] attendance update failed event=\(item.id.uuidString) action=\(target)")
#endif
            interestedOnlyEncoded = previousInterestedOnly
            viewModel.followingTabGoingItems = previousGoingItems
            cachedGoingVenueGameItems = previousCachedGoingItems
            viewModel.followingTabGoingInterestCounts = previousGoingInterestCounts
            viewModel.followingTabUserVenueEventInterestIDs = previousServerGoingIDs
            viewModel.refreshFollowingInterestDerivedSnapshotsForUI()
            logGoingStatusOptimistic(
                before: oldStatus,
                after: newStatus,
                eventID: item.id,
                localUpdated: false,
                backendSynced: false,
                rollback: true
            )
            logGoingTabStatusDebug(
                eventID: item.id,
                oldStatus: oldStatus,
                newStatus: newStatus,
                includedInGoingTab: item.isActiveGoingTabPlan,
                optimisticUpdate: false,
                backendSaved: false
            )
            viewModel.showSocialActionToast("Couldn't update your game plan.")
            return
        }
        logGoingTabStatusDebug(
            eventID: item.id,
            oldStatus: oldStatus,
            newStatus: newStatus,
            includedInGoingTab: target.isIncludedInGoingTab,
            optimisticUpdate: false,
            backendSaved: true
        )
        logGoingStatusOptimistic(
            before: oldStatus,
            after: newStatus,
            eventID: item.id,
            localUpdated: true,
            backendSynced: true,
            rollback: false
        )
#if DEBUG
        switch target {
        case .going:
            print("[FollowingState] marked going")
        case .interested:
            print("[FollowingState] marked interested")
        case .notGoing:
            print("[FollowingState] marked not going, removed from following")
        }
#endif
    }

    private func syncGoingStatusToBackend(eventID: UUID, isGoing: Bool) async -> Bool {
        await viewModel.setVenueEventInterest(
            venueEventID: eventID,
            isInterested: isGoing,
            refreshFollowing: false,
            applyOptimistic: false,
            manageWriteInFlight: true,
            schedulePostWriteRefreshes: false,
            applyLocalSuccessState: false
        )
    }

    @MainActor
    private func applyOptimisticGoingTabAttendance(_ item: FollowingGoingDisplayItem, target: FollowingAttendanceTarget) {
        let attendeeCount = optimisticAttendeeCount(for: item, target: target)
        switch target {
        case .going:
            viewModel.followingTabUserVenueEventInterestIDs.insert(item.id)
            upsertOptimisticGoingTabItem(
                item,
                attendeeCount: attendeeCount,
                isServerGoing: true,
                isInterestedOnlyLocal: false
            )
        case .interested:
            viewModel.followingTabUserVenueEventInterestIDs.remove(item.id)
            upsertOptimisticGoingTabItem(
                item,
                attendeeCount: attendeeCount,
                isServerGoing: false,
                isInterestedOnlyLocal: true
            )
        case .notGoing:
            viewModel.followingTabUserVenueEventInterestIDs.remove(item.id)
            viewModel.followingTabGoingItems.removeAll { $0.id == item.id }
            cachedGoingVenueGameItems.removeAll { $0.id == item.id }
        }
        applyOptimisticGoingTabInterestCount(eventID: item.id, attendeeCount: attendeeCount)
        viewModel.followingTabGoingItems = MapViewModel.sortFollowingGoingItemsChronologically(viewModel.followingTabGoingItems)
        cachedGoingVenueGameItems = MapViewModel.sortFollowingGoingItemsChronologically(cachedGoingVenueGameItems)
        viewModel.refreshFollowingInterestDerivedSnapshotsForUI()
    }

    @MainActor
    private func upsertOptimisticGoingTabItem(
        _ item: FollowingGoingDisplayItem,
        attendeeCount: Int,
        isServerGoing: Bool,
        isInterestedOnlyLocal: Bool
    ) {
        let updated = FollowingGoingDisplayItem(
            id: item.id,
            venueEvent: item.venueEvent,
            bar: item.bar,
            attendeeCount: attendeeCount,
            isServerGoing: isServerGoing,
            isInterestedOnlyLocal: isInterestedOnlyLocal
        )
        if let index = viewModel.followingTabGoingItems.firstIndex(where: { $0.id == item.id }) {
            viewModel.followingTabGoingItems[index] = updated
        } else {
            viewModel.followingTabGoingItems.append(updated)
        }
        if let index = cachedGoingVenueGameItems.firstIndex(where: { $0.id == item.id }) {
            cachedGoingVenueGameItems[index] = updated
        } else {
            cachedGoingVenueGameItems.append(updated)
        }
    }

    private func optimisticAttendeeCount(for item: FollowingGoingDisplayItem, target: FollowingAttendanceTarget) -> Int {
        switch target {
        case .going:
            return item.isServerGoing ? item.attendeeCount : max(item.attendeeCount + 1, 1)
        case .interested:
            return item.isServerGoing ? max(item.attendeeCount - 1, 0) : item.attendeeCount
        case .notGoing:
            return item.isServerGoing ? max(item.attendeeCount - 1, 0) : item.attendeeCount
        }
    }

    @MainActor
    private func applyOptimisticGoingTabInterestCount(eventID: UUID, attendeeCount: Int) {
        if attendeeCount > 0 {
            viewModel.followingTabGoingInterestCounts[eventID] = attendeeCount
        } else {
            viewModel.followingTabGoingInterestCounts.removeValue(forKey: eventID)
        }
    }

    private func logGoingTabStatusDebug(
        eventID: UUID,
        oldStatus: String,
        newStatus: String,
        includedInGoingTab: Bool,
        optimisticUpdate: Bool,
        backendSaved: Bool?
    ) {
#if DEBUG
        print("[GoingTabStatusDebug] eventID=\(eventID.uuidString.lowercased())")
        print("[GoingTabStatusDebug] oldStatus=\(oldStatus)")
        print("[GoingTabStatusDebug] newStatus=\(newStatus)")
        print("[GoingTabStatusDebug] includedInGoingTab=\(includedInGoingTab)")
        print("[GoingTabStatusDebug] optimisticUpdate=\(optimisticUpdate)")
        print("[GoingTabStatusDebug] backendSaved=\(backendSaved.map { String($0) } ?? "pending")")
#endif
    }

    private func logGoingStatusOptimistic(
        before: String,
        after: String,
        eventID: UUID,
        localUpdated: Bool,
        backendSynced: Bool?,
        rollback: Bool
    ) {
#if DEBUG
        print("[GoingStatusOptimistic] before=\(before) after=\(after) eventId=\(eventID.uuidString.lowercased()) localUpdated=\(localUpdated) backendSynced=\(backendSynced.map { String($0) } ?? "pending") rollback=\(rollback)")
#endif
    }

    // MARK: - Shared UI pieces

    private func pickupGameJoinCard(_ card: PickupGameJoinRequestCardDisplay) -> some View {
        let resolvedGame = viewModel.resolvedPickupGameRow(for: card.pickupGameId)
        let sportVisual = SportFilterCatalog.resolve(card.sport)
        let now = Date()
        let pickupStarted = resolvedGame?.hasPickupGameStarted(now: now)
            ?? PickupGameModels.parseSupabaseTimestamptz(card.game_start_at).map { now >= $0 }
            ?? false
        let isOrganizerCanceled = card.pill == .canceledByOrganizer
        let isRejected = card.pill == .declined
        let ratingPromptEligible = resolvedGame?.isPickupCreatorRatingPromptEligible(now: now) ?? false
        let openMap = {
            openPlayingPickupGameOnDiscoverMap(card)
        }

        return VStack(alignment: .leading, spacing: FGSpacing.sm) {
            HStack(alignment: .top, spacing: FGSpacing.sm) {
                PickupGameStartedSportGlyphFrame(showStarted: pickupStarted) {
                    Image(systemName: sportVisual.systemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(sportVisual.accent)
                        .frame(width: 40, height: 40)
                        .background(sportVisual.accent.opacity(0.14), in: Circle())
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(card.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    GameFormatBadgeView(
                        format: resolvedGame?.gameFormat ?? .pickup,
                        colorScheme: followingColorScheme
                    )
                    pickupJoinStatusPill(card.pill)
                    if isOrganizerCanceled {
                        Text("Canceled by organizer")
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(Color.red.opacity(followingColorScheme == .dark ? 0.9 : 0.78))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(viewModel.pickupHistoryAutoClearCaption(forPickupGameId: card.pickupGameId))
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if isRejected {
                        Text("The organizer declined this request. You can clear it from your Playing list.")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: openMap)

            if !card.dateTimeLine.isEmpty {
                Label(card.dateTimeLine, systemImage: "calendar")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .labelStyle(.titleAndIcon)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: openMap)
                if pickupStarted {
                    PickupGameStartedLineCaption()
                        .contentShape(Rectangle())
                        .onTapGesture(perform: openMap)
                }
            }
            if !card.locationLine.isEmpty {
                Label(card.locationLine, systemImage: "mappin.and.ellipse")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .lineLimit(2)
                    .labelStyle(.titleAndIcon)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: openMap)
            }

            HStack(spacing: FGSpacing.sm) {
                PublicProfileAvatarTap(userId: card.organizerUserId, context: "following_pickup_organizer") {
                    UserAvatarView(
                        avatarThumbnailURL: viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: card.organizerUserId),
                        avatarURL: viewModel.pickupOrganizerAvatarFullForDetail(userId: card.organizerUserId),
                        avatarDisplayRefreshToken: viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: card.organizerUserId),
                        displayName: card.organizerName,
                        email: viewModel.pickupOrganizerEmailForDetail(userId: card.organizerUserId),
                        size: 36,
                        fallbackStyle: followingColorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
                    )
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Organizer")
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.mutedText(followingColorScheme))
                    Text(card.organizerName)
                        .font(FGTypography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                }
                Spacer(minLength: 0)
            }

            PickupCreatorTrustLineView(stats: viewModel.pickupCreatorTrustStats(for: card.organizerUserId))

            if !isOrganizerCanceled,
               card.pill == .approved,
               let row = resolvedGame,
               ratingPromptEligible,
               let me = viewModel.currentUserAuthId,
               me != card.organizerUserId,
               !viewModel.hasSubmittedPickupCreatorRating(for: card.pickupGameId) {
                PickupCreatorRatingPromptCard(viewModel: viewModel, game: row)
            }

            if let spots = card.spotsRemainingSummary, !spots.isEmpty, !isOrganizerCanceled {
                Text(spots)
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.mutedText(followingColorScheme))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: openMap)
            }

            if card.pill == .pending || card.pill == .approved || isRejected {
                Group {
                    if card.pill == .pending {
                        Button(role: .destructive) {
                            let rid = viewModel.pickupJoinRequestLatestByPickupGameIdForFan[card.pickupGameId]?.id ?? card.id
#if DEBUG
                            print("[PickupJoinWithdraw] tapped gameId=\(card.pickupGameId.uuidString.lowercased())")
                            print("[PickupJoinWithdraw] requestId=\(rid.uuidString.lowercased())")
#endif
                            followingPickupWithdrawConfirm = PickupJoinWithdrawConfirmState(
                                requestId: rid,
                                pickupGameId: card.pickupGameId,
                                intent: .pending
                            )
                        } label: {
                            Text("Withdraw request")
                                .font(FGTypography.metadata.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.red.opacity(0.92))
                        .disabled(followingPickupWithdrawInFlight)
                    } else if card.pill == .approved {
                        Button(role: .destructive) {
                            let rid = viewModel.pickupJoinRequestLatestByPickupGameIdForFan[card.pickupGameId]?.id ?? card.id
#if DEBUG
                            print("[PickupJoinWithdraw] tapped gameId=\(card.pickupGameId.uuidString.lowercased())")
                            print("[PickupJoinWithdraw] requestId=\(rid.uuidString.lowercased())")
#endif
                            followingPickupWithdrawConfirm = PickupJoinWithdrawConfirmState(
                                requestId: rid,
                                pickupGameId: card.pickupGameId,
                                intent: .approved
                            )
                        } label: {
                            Text("Can’t make it")
                                .font(FGTypography.metadata.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.red.opacity(0.92))
                        .disabled(followingPickupWithdrawInFlight)
                    } else {
                        Button {
                            viewModel.markPickupFollowingRejectedRequestCleared(
                                requestId: card.id,
                                pickupGameId: card.pickupGameId
                            )
                        } label: {
                            Text("Clear")
                                .font(FGTypography.metadata.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.gray.opacity(0.9))
                    }
                }
                .padding(.top, 4)
            }

            HStack(alignment: .center, spacing: FGSpacing.sm) {
                if !isOrganizerCanceled {
                    if let at = viewModel.lastJoinStatusRefreshAt {
                        Label {
                            Text("Updated \(at.formatted(date: .abbreviated, time: .shortened))")
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    } else {
                        Label("Sync pending", systemImage: "clock")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.mutedText(followingColorScheme))
                    }
                    Spacer(minLength: 0)
                    if viewModel.pickupFollowingUnreadActivityGameIds.contains(card.pickupGameId) {
                        Circle()
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Pickup activity")
                    }
                    Button {
                        Task { await viewModel.refreshPickupFollowingJoinCard(pickupGameId: card.pickupGameId) }
                    } label: {
                        if viewModel.pickupFollowingCardRefreshSpinGameId == card.pickupGameId {
                            ProgressView()
                                .scaleEffect(0.85)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.orange.opacity(0.95))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh pickup status")
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, 2)

            if isOrganizerCanceled {
                HStack(spacing: FGSpacing.sm) {
                    Button {
                        viewModel.markPickupFollowingOrganizerCanceledCardUserCleared(pickupGameId: card.pickupGameId)
                    } label: {
                        Text("Clear now")
                            .font(FGTypography.metadata.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.red.opacity(0.88))

                    Button {
                        pickupDetailNav = PickupDetailNavigationToken(id: card.pickupGameId)
                    } label: {
                        Text("View details")
                            .font(FGTypography.metadata.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .tint(FGColor.accentBlue)
                }
            } else {
                Button {
                    pickupDetailNav = PickupDetailNavigationToken(id: card.pickupGameId)
                } label: {
                    Text("View Details")
                        .font(FGTypography.caption)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(FGColor.accentBlue)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                if isOrganizerCanceled || isRejected {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    (isOrganizerCanceled ? Color.red : Color.gray).opacity(followingColorScheme == .dark ? 0.22 : 0.12),
                                    (isOrganizerCanceled ? Color.red : Color.gray).opacity(followingColorScheme == .dark ? 0.12 : 0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 22))
        .overlay {
            if let border = pickupCardAccentBorder(card) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(border, lineWidth: card.pill == .approved ? 1.5 : (card.pill == .canceledByOrganizer ? 1.35 : 1.25))
            }
        }
        .task(id: card.organizerUserId) {
            await viewModel.loadPickupCreatorDisplayNameIfNeeded(creatorUserId: card.organizerUserId)
        }
        .onAppear {
            if let row = viewModel.resolvedPickupGameRow(for: card.pickupGameId) {
                PickupGameStartedStateDebug.log(
                    row: row,
                    now: Date(),
                    allowedActions: "following_join_card,view_detail"
                )
            }
        }
    }

    private func pickupCardAccentBorder(_ card: PickupGameJoinRequestCardDisplay) -> Color? {
        switch card.pill {
        case .approved: return FGColor.accentGreen.opacity(0.38)
        case .declined: return FGColor.divider(followingColorScheme)
        case .canceledByOrganizer: return Color.red.opacity(followingColorScheme == .dark ? 0.42 : 0.32)
        default: return nil
        }
    }

    private func pickupJoinStatusPill(_ pill: PickupFollowingJoinRequestPillKind) -> some View {
        let colors = pickupJoinPillColors(pill)
        return Text(pill.title)
            .font(FGTypography.metadata)
            .fontWeight(.semibold)
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(colors.background)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(colors.stroke, lineWidth: 1))
    }

    private func pickupJoinPillColors(_ pill: PickupFollowingJoinRequestPillKind) -> (background: Color, foreground: Color, stroke: Color) {
        switch pill {
        case .pending:
            return (
                FGColor.accentYellow.opacity(followingColorScheme == .dark ? 0.22 : 0.18),
                followingColorScheme == .dark ? Color.white.opacity(0.92) : Color.orange.opacity(0.95),
                FGColor.accentYellow.opacity(0.55)
            )
        case .approved:
            return (
                FGColor.accentGreen.opacity(0.16),
                FGColor.accentGreen,
                FGColor.accentGreen.opacity(0.42)
            )
        case .declined:
            return (
                Color.gray.opacity(followingColorScheme == .dark ? 0.22 : 0.14),
                FGColor.secondaryText(followingColorScheme),
                FGColor.divider(followingColorScheme)
            )
        case .cancelled:
            return (
                Color.gray.opacity(0.12),
                FGColor.mutedText(followingColorScheme),
                FGColor.divider(followingColorScheme).opacity(0.75)
            )
        case .withdrawing:
            return (
                Color.orange.opacity(followingColorScheme == .dark ? 0.18 : 0.12),
                Color.orange.opacity(followingColorScheme == .dark ? 0.95 : 0.88),
                Color.orange.opacity(0.45)
            )
        case .canceledByOrganizer:
            return (
                Color.red.opacity(followingColorScheme == .dark ? 0.28 : 0.16),
                Color.red.opacity(followingColorScheme == .dark ? 0.95 : 0.88),
                Color.red.opacity(0.45)
            )
        }
    }

    private func emptyCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))

            Text(title)
                .font(FGTypography.cardTitle)
                .foregroundStyle(FGColor.primaryText(followingColorScheme))

            Text(subtitle)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 22))
    }

    @ViewBuilder
    private func followingVenueLeadingVisual(bar: BarVenue, sportRaw: String) -> some View {
        let side: CGFloat = 54
        let raw = sportRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let sportKey = raw.isEmpty ? bar.primarySport : raw
        Group {
            if let urlString = ImageDisplayURL.forList(thumbnail: bar.coverPhotoThumbnailURL, full: bar.coverPhotoURL),
               let url = URL(string: urlString) {
                DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(followingColorScheme == .dark ? 0.22 : 0.08))
                }
                .frame(width: side, height: side)
                .clipped()
            } else {
                let vis = SportFilterCatalog.resolve(sportKey)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(vis.accent.opacity(followingColorScheme == .dark ? 0.24 : 0.15))
                    .frame(width: side, height: side)
                    .overlay {
                        Image(systemName: vis.systemImage)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(vis.accent)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func goingPlanCard(_ item: FollowingGoingDisplayItem, isCompleted: Bool) -> some View {
        let title = item.venueEvent.event_title ?? "Event"
        let bar = item.bar
        let sportRaw = item.venueEvent.sport ?? bar.primarySport
        let datePart = item.venueEvent.event_date ?? ""
        let timePart = item.venueEvent.event_time ?? ""
        let dateTimeLine = [datePart, timePart].filter { !$0.isEmpty }.joined(separator: " · ")
        let primaryText = isCompleted ? FGColor.mutedText(followingColorScheme) : FGColor.primaryText(followingColorScheme)
        let secondaryText = isCompleted ? FGColor.mutedText(followingColorScheme) : FGColor.secondaryText(followingColorScheme)

        return HStack(alignment: .top, spacing: 12) {
            followingVenueLeadingVisual(bar: bar, sportRaw: sportRaw)
                .opacity(isCompleted ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(primaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    if isCompleted {
                        watchingCompletedPill
                    } else {
                        attendanceMenu(item: item)
                    }
                }

                if !dateTimeLine.isEmpty {
                    Label(dateTimeLine, systemImage: "calendar")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(secondaryText)
                        .labelStyle(.titleAndIcon)
                }

                Button {
#if DEBUG
                    let matched = viewModel.bars.contains(where: { $0.id == bar.id })
                    print("[FollowingVenueOpen] venue=\(bar.name) matched=\(matched ? "mapRow" : "offMap")")
#endif
                    viewModel.requestDiscoverFocusForSavedVenue(bar)
                } label: {
                    Label(bar.name, systemImage: "mappin.and.ellipse")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(primaryText)
                        .labelStyle(.titleAndIcon)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(isCompleted)
                .accessibilityLabel("Open \(bar.name) on map")

                Button {
                    openFollowingDirectionsToVenue(bar: bar)
                } label: {
                    Text(bar.address)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(isCompleted ? secondaryText : FGColor.accentBlue)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(isCompleted)
                .accessibilityLabel("Directions to \(bar.name)")

                if let bizEmail = VenueGameBusinessEmail.resolvedDisplayEmail(for: bar), !isCompleted {
                    VenueGameBusinessContactEmailRow(
                        email: bizEmail,
                        secondaryForeground: FGColor.secondaryText(followingColorScheme)
                    )
                    .padding(.top, 2)
                    .onAppear { VenueGameBusinessEmail.logDebug(bar: bar) }
                }

                if isCompleted {
                    Button {
                        Task { await clearWatchingVenueGame(item) }
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(FGColor.primaryText(followingColorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(followingColorScheme == .dark ? 0.14 : 0.07))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear completed game from I’m Going")
                } else {
                    HStack(alignment: .center, spacing: 10) {
                        GoingAvatarStack(profiles: viewModel.goingProfiles(for: item.id), viewerUserID: viewModel.currentUserAuthId)
                        Label("\(item.attendeeCount) interested / going", systemImage: "person.2.fill")
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(secondaryText)
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    isCompleted
                        ? Color.primary.opacity(followingColorScheme == .dark ? 0.10 : 0.05)
                        : Color.clear
                )
        }
        .background {
            if !isCompleted {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    isCompleted
                        ? FGColor.divider(followingColorScheme).opacity(0.85)
                        : Color.clear,
                    lineWidth: 1
                )
        }
        .opacity(isCompleted ? 0.88 : 1)
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 22))
        .task(id: item.id) {
            guard viewModel.isAuthenticatedForSocialFeatures, !isCompleted else { return }
            await viewModel.loadGoingUserProfiles(for: item.id)
        }
    }

    private var watchingCompletedPill: some View {
        Text("Ended")
            .font(.caption.weight(.bold))
            .foregroundStyle(FGColor.mutedText(followingColorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(followingColorScheme == .dark ? 0.16 : 0.08))
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.divider(followingColorScheme), lineWidth: 1)
            }
            .accessibilityLabel("Game ended")
    }

    @MainActor
    private func clearWatchingVenueGame(_ item: FollowingGoingDisplayItem) async {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
#if DEBUG
        if WatchingExpiredVenueGameDiagnostics.enabled {
            print("[WatchingExpiredVenueGame] clear tapped event_id=\(item.id.uuidString.lowercased())")
        }
#endif
        setInterestedOnlyLocally(item.id, false)
        let ok = await viewModel.removeInterestInVenueEvent(venueEventID: item.id, refreshFollowing: true)
        if ok {
#if DEBUG
            if WatchingExpiredVenueGameDiagnostics.enabled {
                print("[WatchingExpiredVenueGame] clear success event_id=\(item.id.uuidString.lowercased())")
            }
#endif
            viewModel.showSocialActionToast("Removed from I’m Going.")
        } else {
#if DEBUG
            if WatchingExpiredVenueGameDiagnostics.enabled {
                print("[WatchingExpiredVenueGame] clear failed event_id=\(item.id.uuidString.lowercased()) error=removeInterestInVenueEvent")
            }
#endif
            viewModel.showSocialActionToast("Couldn't clear this game. Try again.")
        }
    }

    @ViewBuilder
    private func attendanceMenu(item: FollowingGoingDisplayItem) -> some View {
        if viewModel.isAuthenticatedForSocialFeatures {
            Menu {
                Button {
                    Task { await applyAttendance(item, target: .going) }
                } label: {
                    Label("Going ✅", systemImage: "checkmark.circle.fill")
                }

                Button {
                    Task { await applyAttendance(item, target: .interested) }
                } label: {
                    Label("Interested 👀", systemImage: "eye")
                }

                Button(role: .destructive) {
                    Task { await applyAttendance(item, target: .notGoing) }
                } label: {
                    Label("Not going ❌", systemImage: "xmark.circle")
                }
            } label: {
                attendancePill(item: item)
            }
            .buttonStyle(.plain)
        } else {
            attendancePill(item: item)
                .opacity(0.45)
        }
    }

    private func attendancePill(item: FollowingGoingDisplayItem) -> some View {
        let pillIsGoing = item.isServerGoing
        return HStack(spacing: 6) {
            Text(pillIsGoing ? "Going" : "Interested")
                .font(.caption)
                .fontWeight(.bold)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(pillIsGoing ? Color.green.opacity(0.22) : Color.orange.opacity(0.22))
        )
        .overlay(
            Capsule()
                .strokeBorder(pillIsGoing ? Color.green.opacity(0.45) : Color.orange.opacity(0.45), lineWidth: 1)
        )
        .foregroundStyle(pillIsGoing ? Color.green : Color.orange)
    }

    private func venueCard(_ bar: BarVenue) -> some View {
        let isFavorite = viewModel.favoriteVenueIDs.contains(bar.id)
        let sportRaw = bar.primarySport

        return ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 12) {
                followingVenueLeadingVisual(bar: bar, sportRaw: sportRaw)
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        viewModel.requestDiscoverFocusForSavedVenue(bar)
                    } label: {
                        Text(bar.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(FGColor.primaryText(followingColorScheme))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(bar.name) on map")

                    Label("Saved venue", systemImage: "building.2")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                        .labelStyle(.titleAndIcon)

                    Button {
                        openFollowingDirectionsToVenue(bar: bar)
                    } label: {
                        Text(bar.address)
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.accentBlue)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Directions to \(bar.name)")

                    if let bizEmail = VenueGameBusinessEmail.resolvedDisplayEmail(for: bar) {
                        VenueGameBusinessContactEmailRow(
                            email: bizEmail,
                            secondaryForeground: FGColor.secondaryText(followingColorScheme)
                        )
                        .padding(.top, 2)
                        .onAppear { VenueGameBusinessEmail.logDebug(bar: bar) }
                    }

                    Button {
                        viewModel.requestDiscoverFocusForSavedVenue(bar)
                    } label: {
                        FlowTags(tags: bar.tags)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)

            Button {
                Task { await toggleSavedVenueHeart(bar: bar, currentlySaved: isFavorite) }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(isFavorite ? Color.red : Color.secondary)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Remove from saved venues" : "Save venue")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 22))
    }

    // MARK: - Maps / Discover (Following tab)

    /// Opens Apple Maps directions: uses venue coordinates when they look valid; otherwise falls back to encoded address (`daddr`).
    private func openFollowingDirectionsToVenue(bar: BarVenue) {
#if DEBUG
        print("[FollowingDirections] venue=\(bar.name) address=\(bar.address)")
#endif
        let trimmedAddress = bar.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.followingDirectionsCoordinateLooksUsable(bar.coordinate) {
            let location = CLLocation(latitude: bar.coordinate.latitude, longitude: bar.coordinate.longitude)
            let mapItem = MKMapItem(location: location, address: nil)
            mapItem.name = bar.name
            mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            return
        }
        guard !trimmedAddress.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.queryItems = [URLQueryItem(name: "daddr", value: trimmedAddress)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }

    private static func followingDirectionsCoordinateLooksUsable(_ c: CLLocationCoordinate2D) -> Bool {
        guard CLLocationCoordinate2DIsValid(c) else { return false }
        if abs(c.latitude) < 1e-5 && abs(c.longitude) < 1e-5 { return false }
        return abs(c.latitude) <= 90 && abs(c.longitude) <= 180
    }

    private func toggleSavedVenueHeart(bar: BarVenue, currentlySaved: Bool) async {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        let wantSave = !currentlySaved
        let ok = await viewModel.setVenueFavorite(bar: bar, isFavorite: wantSave)
        if !ok {
            await MainActor.run {
                favoriteActionBanner = "Couldn’t update saved venue. Try again."
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                    favoriteActionBanner = nil
                }
            }
        }
    }
}

/// Premium separation for Following list cards on `systemGroupedBackground` (stroke, soft lift, top-edge sheen).
private struct FollowingCardChromeModifier: ViewModifier {
    var colorScheme: ColorScheme
    var cornerRadius: CGFloat = 20
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    func body(content: Content) -> some View {
        let isLight = colorScheme == .light
        let shadowColor = Color.black.opacity(isLight ? 0.125 : 0.32)
        let shadowRadius: CGFloat = isLight ? 12 : 8
        let shadowY: CGFloat = isLight ? 3 : 2
        let outerStroke = FGColor.divider(colorScheme).opacity(isLight ? 0.92 : 0.88)
        let innerStroke = Color.white.opacity(isLight ? 0.10 : 0.04)
        let sheenTop = Color.white.opacity(isLight ? 0.16 : 0.04)

        content
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
            .overlay {
                ZStack {
                    shape
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: sheenTop, location: 0),
                                    .init(color: Color.clear, location: 0.2)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.overlay)
                    shape
                        .strokeBorder(innerStroke, lineWidth: 0.5)
                        .padding(1)
                    shape
                        .strokeBorder(outerStroke, lineWidth: 1.35)
                }
                .allowsHitTesting(false)
            }
    }
}

private enum FollowingAttendanceTarget {
    case going
    case interested
    case notGoing

    var goingTabStatusDebugValue: String {
        switch self {
        case .going:
            return "going"
        case .interested:
            return "interested"
        case .notGoing:
            return "not_going"
        }
    }

    var isIncludedInGoingTab: Bool {
        switch self {
        case .going, .interested:
            return true
        case .notGoing:
            return false
        }
    }
}

private enum GoingParticipationMode: Hashable {
    case venueGames
    case pickupGames
    case proGames

    var title: String {
        switch self {
        case .venueGames: return "Venues"
        case .pickupGames: return "Pickup Games"
        case .proGames: return "Pro Games"
        }
    }

    var tint: Color {
        switch self {
        case .venueGames: return FGColor.accentGreen
        case .pickupGames: return FGColor.accentGreen
        case .proGames: return FGColor.accentBlue
        }
    }
}

private struct PickupGameInviteDetailSheet: View {
    let item: PickupGameInviteDisplay
    let isResponding: Bool
    let onRespond: (String) async -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var game: PickupGameRow { item.game }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FGSpacing.lg) {
                    hero
                    inviterLine
                    gameFacts
                    actionRow
                }
                .padding(FGSpacing.lg)
            }
            .scrollContentBackground(.hidden)
            .fanGeoScreenBackground()
            .navigationTitle("Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.34 : 0.18),
                    FGColor.accentBlue.opacity(colorScheme == .dark ? 0.30 : 0.14),
                    Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            SportArtworkIconView(sport: game.sport, diameter: 86)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 24)
                .opacity(0.92)

            VStack(alignment: .leading, spacing: 8) {
                GameFormatBadgeView(format: game.gameFormat, colorScheme: colorScheme)
                Text(game.title)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(AppSportCatalog.displayLabel(forSportToken: game.sport))
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            .padding(FGSpacing.lg)
        }
        .frame(minHeight: 168)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.26 : 0.08), radius: 14, y: 6)
    }

    private var inviterLine: some View {
        HStack(spacing: 10) {
            UserAvatarView(
                avatarThumbnailURL: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_thumbnail_url),
                avatarURL: ImageDisplayURL.canonicalStorageURLString(item.inviterProfile?.avatar_url),
                avatarDisplayRefreshToken: UserAvatarView.stableRefreshToken(
                    userId: item.invite.inviter_user_id,
                    thumbnailURL: item.inviterProfile?.avatar_thumbnail_url,
                    avatarURL: item.inviterProfile?.avatar_url
                ),
                displayName: inviterName,
                email: item.inviterProfile?.email ?? "",
                size: 44,
                fallbackStyle: colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("\(inviterName) invited you to")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                Text(game.title)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
            }
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        )
    }

    private var gameFacts: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let dateLine = game.pickupDateWithCompactTimeRange {
                factRow("calendar", dateLine)
            }
            if !locationLine.isEmpty {
                factRow("mappin.and.ellipse", locationLine)
            }
            factRow("person.3", spotsOpenLine)
            if let lat = game.latitude, let lon = game.longitude {
                Button {
                    if let url = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)&q=Pickup%20game") {
                        openURL(url)
                    }
                } label: {
                    Label("View on map", systemImage: "map")
                        .font(FGTypography.metadata.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(FGColor.accentBlue)
            }
        }
        .padding(FGSpacing.md)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        )
    }

    private func factRow(_ systemImage: String, _ text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(FGTypography.caption.weight(.semibold))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            responseButton("Accept", status: "accepted", tint: FGColor.accentGreen)
            responseButton("Maybe", status: "maybe", tint: Color.orange)
            responseButton("Decline", status: "declined", tint: Color.red.opacity(0.9))
        }
    }

    private func responseButton(_ title: String, status: String, tint: Color) -> some View {
        Button {
            Task { await onRespond(status) }
        } label: {
            if isResponding {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                Text(title)
                    .font(FGTypography.metadata.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .disabled(isResponding)
    }

    private var inviterName: String {
        let display = item.inviterProfile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !display.isEmpty { return display }
        let username = item.inviterProfile?.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !username.isEmpty { return username }
        return "A friend"
    }

    private var locationLine: String {
        [game.address, game.city, game.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var spotsOpenLine: String {
        let open = game.pickupOpenSlotsRemaining
        return open == 1 ? "1 spot open" : "\(open) spots open"
    }
}

private enum GoingVenueTab: Hashable {
    case games
    case saved
}

private enum GoingGamesTab: Hashable {
    case playing
    case hosting
    case invites
}

private func decodeInterestedOnlyUUIDs(from encoded: String) -> Set<UUID> {
    let parts = encoded.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    var out: Set<UUID> = []
    for p in parts {
        if let u = UUID(uuidString: p) {
            out.insert(u)
        }
    }
    return out
}

private struct EquatableRenderCard<Token: Equatable, Content: View>: View, Equatable {
    let token: Token
    let content: () -> Content

    static func == (lhs: EquatableRenderCard<Token, Content>, rhs: EquatableRenderCard<Token, Content>) -> Bool {
        lhs.token == rhs.token
    }

    var body: some View {
        content()
    }
}

private struct PickupInviteRenderToken: Equatable {
    let id: UUID
    let game: PickupGameRow
    let inviterName: String
    let inviterAvatarThumbnailURL: String
    let inviterAvatarURL: String
    let isBusy: Bool
    let colorScheme: ColorScheme
}

private struct PickupPlayingCardRenderToken: Equatable {
    let card: PickupGameJoinRequestCardDisplay
    let resolvedGame: PickupGameRow?
    let organizerAvatarThumbnailURL: String?
    let organizerAvatarURL: String?
    let organizerAvatarRefreshToken: UUID
    let organizerEmail: String
    let creatorTrustStats: PickupCreatorPublicRatingStats?
    let currentUserId: UUID?
    let hasSubmittedCreatorRating: Bool
    let hasUnreadActivity: Bool
    let isRefreshSpinning: Bool
    let isWithdrawInFlight: Bool
    let lastJoinStatusRefreshAt: Date?
    let colorScheme: ColorScheme
}

private struct PickupHostedCardRenderToken: Equatable {
    let row: PickupGameRow
    let pendingJoinCount: Int
    let withdrawnJoinRows: [PickupGameRequestRow]
    let now: Date
    let colorScheme: ColorScheme
}

private func encodeInterestedOnlyUUIDs(_ set: Set<UUID>) -> String {
    set.map(\.uuidString).sorted().joined(separator: ",")
}
