import Combine
import CoreLocation
import MapKit
import SwiftUI

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
    @State private var followingSegment: FollowingScreenMainTab = .venueGames
    @State private var pickupDetailNav: PickupDetailNavigationToken?
    @State private var followingPickupWithdrawConfirm: PickupJoinWithdrawConfirmState?
    @State private var followingPickupWithdrawInFlight = false

    @State private var followingMyPickupClockTick: Date = Date()
    @State private var followingMyPickupFormMode: PickupGameFormMode?
    @State private var followingMyPickupDeleteTarget: PickupGameRow?
    @State private var followingMyPickupOrganizerRequestsGame: PickupGameRow?
    @State private var followingMyPickupDetailGame: PickupGameRow?
    @State private var followingMyPickupBanner: String?
    @State private var followingMyPickupDidScheduleExpiryRefresh = false

    private let followingMyPickupMinuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private enum FollowingScreenMainTab: Int, CaseIterable, Identifiable, Hashable {
        case venueGames
        case savedVenues
        case gamesToPlay
        case myPickupGames

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .venueGames: return "Venue Games"
            case .savedVenues: return "Saved Venues"
            case .gamesToPlay: return "Games to Play"
            case .myPickupGames: return "My Pickup Games"
            }
        }
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
            if suppressInitialAutoRefresh && !didHandleInitialAutoRefresh {
                didHandleInitialAutoRefresh = true
                return
            }
            guard viewModel.isAuthenticatedForSocialFeatures, viewModel.canUseFollowingTab else { return }
            Task { await reloadFollowingDataForCurrentUser() }
        }
        .onChange(of: viewModel.currentUserAuthId) { _, newId in
            if newId != nil {
                Task { await reloadFollowingDataForCurrentUser() }
            } else {
                clearFollowingUserSpecificState()
                interestedOnlyEncoded = ""
            }
        }
        .task(id: viewModel.currentUserAuthId) {
            guard viewModel.isAuthenticatedForSocialFeatures, viewModel.canUseFollowingTab else { return }
            await viewModel.refreshFollowingTabDataGlobally()
            await viewModel.loadMyPickupGameJoinRequestsForFollowing()
        }
        .sheet(item: $pickupDetailNav, onDismiss: {
            Task { await viewModel.loadMyPickupGameJoinRequestsForFollowing() }
        }) { token in
            DiscoverPickupGameDetailSheet(viewModel: viewModel, gameId: token.id)
        }
        .onChange(of: followingSegment) { _, newSeg in
            if newSeg == .gamesToPlay {
                viewModel.acknowledgePickupFollowingGamesToPlayActivity()
            }
            if newSeg == .myPickupGames {
                followingMyPickupClockTick = Date()
                followingMyPickupDidScheduleExpiryRefresh = false
                Task {
                    await viewModel.loadMyPickupGamesForSettings()
                    if let uid = viewModel.currentUserAuthId {
                        await viewModel.refreshPickupCreatorPublicRatingStats(creatorUserIds: [uid])
                    }
                    logFollowingMyPickupGames(action: "segmentSelect")
                }
                scheduleFollowingMyPickupExpiryRefreshIfNeeded(now: Date())
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, isFollowingTabSelected else { return }
            guard viewModel.isAuthenticatedForSocialFeatures, viewModel.canFanUsePickupGamesUI else { return }
            Task { await viewModel.loadMyPickupGameJoinRequestsForFollowing() }
        }
        .task(id: isFollowingTabSelected) {
            guard isFollowingTabSelected else { return }
            guard viewModel.isAuthenticatedForSocialFeatures, viewModel.canUseFollowingTab else { return }
            await viewModel.runPickupFollowingJoinListAutoRefreshLoop()
        }
        .onChange(of: viewModel.isAuthenticatedForSocialFeatures) { _, _ in
            Task { await syncFollowingAfterAuthChange() }
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
                SettingsPickupGameFormView(viewModel: viewModel, mode: mode) {
                    followingMyPickupFormMode = nil
                    Task {
                        await viewModel.loadMyPickupGamesForSettings()
                        await viewModel.refreshPickupGamesForDiscoverMap(force: true)
                        logFollowingMyPickupGames(action: "formDismissReload")
                    }
                }
            }
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
        .alert("Cancel this pickup game?", isPresented: Binding(
            get: { followingMyPickupDeleteTarget != nil },
            set: { if !$0 { followingMyPickupDeleteTarget = nil } }
        )) {
            Button("Keep game", role: .cancel) { followingMyPickupDeleteTarget = nil }
            Button("Cancel game", role: .destructive) {
                guard let row = followingMyPickupDeleteTarget else { return }
                followingMyPickupDeleteTarget = nil
                Task { await performFollowingMyPickupDelete(row) }
            }
        } message: {
            Text("Players who requested or joined will be notified.")
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

            Text("Following")
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Following")
                    .font(FGTypography.screenTitle)
                    .foregroundStyle(FGColor.primaryText(followingColorScheme))
                    .padding(.top, 8)

                Text("Venue games you follow, saved spots, pickup games you’ve asked to join, and pickup games you host.")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .fixedSize(horizontal: false, vertical: true)

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
            }
            .padding(.horizontal, FGSpacing.md)

            followingGroupedSegmentControl
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, 6)
                .padding(.bottom, 6)

            ScrollView {
                followingSegmentContent
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.bottom, 110)
            }
            .refreshable {
                await viewModel.refreshFollowingTabDataGlobally()
                await viewModel.performPickupFollowingJoinListRefresh(isUserPull: true)
                logFollowingMyPickupGames(action: "pullToRefresh")
            }
            .onReceive(followingMyPickupMinuteTicker) { date in
                guard followingSegment == .myPickupGames else { return }
                followingMyPickupClockTick = date
                scheduleFollowingMyPickupExpiryRefreshIfNeeded(now: date)
            }
        }
    }

    @ViewBuilder
    private var followingSegmentContent: some View {
        switch followingSegment {
        case .venueGames:
            venueGamesTabContent
        case .savedVenues:
            savedVenuesTabContent
        case .gamesToPlay:
            gamesToPlayTabContent
        case .myPickupGames:
            myPickupGamesTabContent
        }
    }

    /// Row 1: section headers. Row 2: all pills in one line (horizontal scroll on narrow widths). Maps 1:1 to ``FollowingScreenMainTab``.
    private var followingGroupedSegmentControl: some View {
        let corner: CGFloat = 16
        let shell = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let isDark = followingColorScheme == .dark
        let venueHeaderTint = Color(red: 1.0, green: 0.58, blue: 0.18)
        let pickupHeaderTint = Color(red: 0.2, green: 0.78, blue: 0.45)
        let pillRowHeight: CGFloat = 36
        let pillHPadding: CGFloat = 12

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                followingSelectorSectionHeader(
                    icon: "building.2.fill",
                    iconTint: venueHeaderTint,
                    title: "Venues"
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                followingSelectorSectionHeader(
                    icon: "person.2.fill",
                    iconTint: pickupHeaderTint,
                    title: "Pickup Games"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 0) {
                    HStack(spacing: 8) {
                        followingSelectorPillButton(
                            title: "Games",
                            tab: .venueGames,
                            accent: .venuesWarm,
                            accessibilityLabel: "Venue games you’re following",
                            badgeCount: nil,
                            rowHeight: pillRowHeight,
                            horizontalPadding: pillHPadding
                        )
                        followingSelectorPillButton(
                            title: "Saved Venues",
                            tab: .savedVenues,
                            accent: .venuesWarm,
                            accessibilityLabel: "Saved venues",
                            badgeCount: nil,
                            rowHeight: pillRowHeight,
                            horizontalPadding: pillHPadding
                        )
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    followingSelectorInterGroupDivider(isDark: isDark, height: pillRowHeight - 6)

                    HStack(spacing: 8) {
                        followingSelectorPillButton(
                            title: "Games to Play",
                            tab: .gamesToPlay,
                            accent: .pickupGreen,
                            accessibilityLabel: "Pickup games you asked to join",
                            badgeCount: viewModel.pickupActivityCount,
                            rowHeight: pillRowHeight,
                            horizontalPadding: pillHPadding
                        )
                        followingSelectorPillButton(
                            title: "My Pickup Games",
                            tab: .myPickupGames,
                            accent: .pickupGreen,
                            accessibilityLabel: "Pickup games you host",
                            badgeCount: nil,
                            rowHeight: pillRowHeight,
                            horizontalPadding: pillHPadding
                        )
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            ZStack {
                shell.fill(.ultraThinMaterial)
                shell.fill(isDark ? Color.black.opacity(0.52) : Color.black.opacity(0.14))
            }
        }
        .clipShape(shell)
        .overlay {
            shell
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isDark ? 0.16 : 0.42),
                            Color.white.opacity(isDark ? 0.05 : 0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: Color.black.opacity(isDark ? 0.35 : 0.1), radius: 10, x: 0, y: 4)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Following categories")
    }

    private enum FollowingGroupAccentKind {
        case venuesWarm
        case pickupGreen
    }

    private func followingSelectorSectionHeader(icon: String, iconTint: Color, title: String) -> some View {
        let isDark = followingColorScheme == .dark
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconTint)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.48)
                .foregroundStyle(isDark ? Color.white.opacity(0.92) : Color.black.opacity(0.78))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private func followingSelectorInterGroupDivider(isDark: Bool, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(isDark ? 0.14 : 0.22))
            .frame(width: 1, height: height)
            .padding(.horizontal, 14)
    }

    private func followingSelectorPillButton(
        title: String,
        tab: FollowingScreenMainTab,
        accent: FollowingGroupAccentKind,
        accessibilityLabel summary: String,
        badgeCount: Int?,
        rowHeight: CGFloat,
        horizontalPadding: CGFloat
    ) -> some View {
        let isDark = followingColorScheme == .dark
        let selected = followingSegment == tab
        let showBadge = (tab == .gamesToPlay) && (badgeCount ?? 0) > 0
        let count = badgeCount ?? 0

        return Button {
            followingSegment = tab
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(title)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(
                        selected
                            ? Color.white
                            : (isDark ? Color.white.opacity(0.85) : Color.black.opacity(0.72))
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, horizontalPadding)
                    .frame(height: rowHeight)
                    .background {
                        Group {
                            if selected {
                                followingSelectorPillSelectedFill(accent: accent, isDark: isDark)
                            } else {
                                followingSelectorPillUnselectedFill(isDark: isDark)
                            }
                        }
                        .clipShape(Capsule(style: .continuous))
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(
                                followingSelectorPillStroke(selected: selected, accent: accent, isDark: isDark),
                                lineWidth: 1
                            )
                    }

                if showBadge {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.92)))
                        .offset(x: 6, y: -6)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary)
    }

    @ViewBuilder
    private func followingSelectorPillSelectedFill(accent: FollowingGroupAccentKind, isDark: Bool) -> some View {
        switch accent {
        case .venuesWarm:
            LinearGradient(
                colors: [
                    Color(red: 0.9, green: 0.52, blue: 0.22),
                    Color(red: 0.55, green: 0.34, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(isDark ? 1.0 : 0.94)
        case .pickupGreen:
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.72, blue: 0.42),
                    Color(red: 0.08, green: 0.48, blue: 0.3)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(isDark ? 1.0 : 0.92)
        }
    }

    private func followingSelectorPillUnselectedFill(isDark: Bool) -> some View {
        isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.06)
    }

    private func followingSelectorPillStroke(selected: Bool, accent: FollowingGroupAccentKind, isDark: Bool) -> Color {
        if selected {
            switch accent {
            case .venuesWarm:
                return Color(red: 1.0, green: 0.68, blue: 0.35).opacity(0.55)
            case .pickupGreen:
                return Color(red: 0.35, green: 0.9, blue: 0.62).opacity(0.45)
            }
        }
        return Color.white.opacity(isDark ? 0.14 : 0.22)
    }

    private var venueGamesTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.followingTabGoingItems.isEmpty {
                emptyCard(
                    icon: "sportscourt.fill",
                    title: "No venue game plans",
                    subtitle: "Save a venue and tap “I’m going” on a game to see it here."
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(viewModel.followingTabGoingItems) { item in
                        goingPlanCard(item)
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
                    title: "No saved venues",
                    subtitle: "Tap the heart on a venue in Discover to save it."
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

    private var gamesToPlayTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.isPickupFollowingJoinListRefreshing && !viewModel.myPickupGameJoinRequestCards.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Refreshing pickup games…")
                        .font(FGTypography.caption.weight(.medium))
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                }
                .padding(.horizontal, 4)
            }
            if viewModel.myPickupGameJoinRequestCards.isEmpty {
                emptyCard(
                    icon: "figure.run",
                    title: "No pickup games yet",
                    subtitle: "Request to join a pickup game from Discover — it will show up here with status updates."
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(viewModel.myPickupGameJoinRequestCards) { card in
                        pickupGameJoinCard(card)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private var myPickupGamesTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !viewModel.canFanUsePickupGamesUI {
                emptyCard(
                    icon: "figure.run",
                    title: "Pickup games unavailable",
                    subtitle: "Switch to a fan account to create and manage pickup games."
                )
            } else if viewModel.myPickupGamesForSettings.isEmpty, viewModel.myRemovedPickupGamesForSettings.isEmpty {
                emptyCard(
                    icon: "sportscourt.fill",
                    title: "No pickup games created yet",
                    subtitle: "Create one from Discover or the + button."
                )
            } else {
                VStack(spacing: 12) {
                    if !viewModel.myPickupGamesForSettings.isEmpty {
                        ForEach(viewModel.myPickupGamesForSettings) { row in
                            let pendingHere = viewModel.organizerPendingPickupJoinRequests(for: row.id)
                            SettingsPickupMyGameListCard(
                                viewModel: viewModel,
                                row: row,
                                pendingJoinCount: pendingHere,
                                withdrawnJoinRows: viewModel.pickupOrganizerWithdrawnRequestsByGameId[row.id] ?? [],
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
                                }
                            )
                            .environmentObject(chatViewModel)
                        }
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
        .padding(.top, 6)
        .onAppear {
            guard viewModel.canFanUsePickupGamesUI else { return }
            followingMyPickupClockTick = Date()
            Task {
                await viewModel.loadMyPickupGamesForSettings()
                if let uid = viewModel.currentUserAuthId {
                    await viewModel.refreshPickupCreatorPublicRatingStats(creatorUserIds: [uid])
                }
                logFollowingMyPickupGames(action: "tabAppear")
            }
            scheduleFollowingMyPickupExpiryRefreshIfNeeded(now: Date())
        }
    }

    // MARK: - Session / cache (Following tab only)

    private func clearFollowingUserSpecificState() {
        viewModel.clearFollowingTabCaches()
        viewModel.favoriteVenueIDs = []
        viewModel.venueEventInterestIDs = []
        viewModel.interestedVenueEventKeys = []
    }

    private func reloadFollowingDataForCurrentUser() async {
        await viewModel.refreshFollowingTabDataGlobally()
        await viewModel.loadMyPickupGameJoinRequestsForFollowing()
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

    private func scheduleFollowingMyPickupExpiryRefreshIfNeeded(now: Date) {
        guard followingSegment == .myPickupGames else { return }
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
            await viewModel.loadMyPickupGamesForSettings()
            logFollowingMyPickupGames(action: "postCleanupDeadlineRefresh")
        }
    }

    private func performFollowingMyPickupDelete(_ row: PickupGameRow) async {
        do {
            try await viewModel.deletePickupGame(id: row.id)
            followingMyPickupBanner = nil
            await viewModel.loadMyPickupGamesForSettings()
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
        var ok = true

#if DEBUG
        print("[FollowingState] attendance action event=\(item.id.uuidString) action=\(target)")
#endif

        switch target {
        case .going:
            if item.isServerGoing && !item.isInterestedOnlyLocal { return }
            setInterestedOnlyLocally(item.id, false)
            ok = await viewModel.markInterestedInVenueEvent(venueEventID: item.id, refreshFollowing: true)
        case .interested:
            if !item.isServerGoing && item.isInterestedOnlyLocal { return }
            if item.isServerGoing {
                ok = await viewModel.removeInterestInVenueEvent(venueEventID: item.id, refreshFollowing: true)
                if ok {
                    setInterestedOnlyLocally(item.id, true)
                    await viewModel.refreshFollowingTabDataGlobally()
                    viewModel.refreshFollowingInterestDerivedSnapshotsForUI()
                }
            } else {
                setInterestedOnlyLocally(item.id, true)
                await viewModel.refreshFollowingTabDataGlobally()
                viewModel.refreshFollowingInterestDerivedSnapshotsForUI()
            }
        case .notGoing:
            guard item.isServerGoing || item.isInterestedOnlyLocal else { return }
            setInterestedOnlyLocally(item.id, false)
            if item.isServerGoing {
                ok = await viewModel.removeInterestInVenueEvent(venueEventID: item.id, refreshFollowing: true)
            } else {
                await viewModel.refreshFollowingTabDataGlobally()
                viewModel.refreshFollowingInterestDerivedSnapshotsForUI()
            }
        }

        guard ok else {
#if DEBUG
            print("[FollowingState] attendance update failed event=\(item.id.uuidString) action=\(target)")
#endif
            interestedOnlyEncoded = previousInterestedOnly
            viewModel.showSocialActionToast("Couldn't update your game plan.")
            return
        }
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

    // MARK: - Shared UI pieces

    private func pickupGameJoinCard(_ card: PickupGameJoinRequestCardDisplay) -> some View {
        let sportVisual = SportFilterCatalog.resolve(card.sport)
        let now = Date()
        let pickupStarted = PickupGameModels.parseSupabaseTimestamptz(card.game_start_at).map { now >= $0 } ?? false
        let isOrganizerCanceled = card.pill == .canceledByOrganizer

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
                    }
                }
                Spacer(minLength: 0)
            }

            if !card.dateTimeLine.isEmpty {
                Label(card.dateTimeLine, systemImage: "calendar")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .labelStyle(.titleAndIcon)
                if pickupStarted {
                    PickupGameStartedLineCaption()
                }
            }
            if !card.locationLine.isEmpty {
                Label(card.locationLine, systemImage: "mappin.and.ellipse")
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                    .lineLimit(2)
                    .labelStyle(.titleAndIcon)
            }

            HStack(spacing: FGSpacing.sm) {
                UserAvatarView(
                    avatarThumbnailURL: viewModel.pickupOrganizerAvatarThumbnailForDetail(userId: card.organizerUserId),
                    avatarURL: viewModel.pickupOrganizerAvatarFullForDetail(userId: card.organizerUserId),
                    avatarDisplayRefreshToken: viewModel.pickupOrganizerAvatarRefreshTokenForDetail(userId: card.organizerUserId),
                    displayName: card.organizerName,
                    email: viewModel.pickupOrganizerEmailForDetail(userId: card.organizerUserId),
                    size: 36,
                    fallbackStyle: followingColorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
                )
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
               let row = viewModel.resolvedPickupGameRow(for: card.pickupGameId),
               row.isPickupCreatorRatingPromptEligible(),
               let me = viewModel.currentUserAuthId,
               me != card.organizerUserId,
               !viewModel.hasSubmittedPickupCreatorRating(for: card.pickupGameId) {
                PickupCreatorRatingPromptCard(viewModel: viewModel, game: row)
            }

            if let spots = card.spotsRemainingSummary, !spots.isEmpty, !isOrganizerCanceled {
                Text(spots)
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.mutedText(followingColorScheme))
            }

            if card.pill == .pending || card.pill == .approved {
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
                    } else {
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
                if isOrganizerCanceled {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.red.opacity(followingColorScheme == .dark ? 0.22 : 0.12),
                                    Color.red.opacity(followingColorScheme == .dark ? 0.12 : 0.06)
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

    private func goingPlanCard(_ item: FollowingGoingDisplayItem) -> some View {
        let title = item.venueEvent.event_title ?? "Event"
        let bar = item.bar
        let sportRaw = item.venueEvent.sport ?? bar.primarySport
        let datePart = item.venueEvent.event_date ?? ""
        let timePart = item.venueEvent.event_time ?? ""
        let dateTimeLine = [datePart, timePart].filter { !$0.isEmpty }.joined(separator: " · ")

        return HStack(alignment: .top, spacing: 12) {
            followingVenueLeadingVisual(bar: bar, sportRaw: sportRaw)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    attendanceMenu(item: item)
                }

                if !dateTimeLine.isEmpty {
                    Label(dateTimeLine, systemImage: "calendar")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
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
                        .foregroundStyle(FGColor.primaryText(followingColorScheme))
                        .labelStyle(.titleAndIcon)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(bar.name) on map")

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

                HStack(alignment: .center, spacing: 10) {
                    GoingAvatarStack(profiles: viewModel.goingProfiles(for: item.id))
                    Label("\(item.attendeeCount) interested / going", systemImage: "person.2.fill")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(followingColorScheme))
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(FollowingCardChromeModifier(colorScheme: followingColorScheme, cornerRadius: 22))
        .task(id: item.id) {
            guard viewModel.isAuthenticatedForSocialFeatures else { return }
            await viewModel.loadGoingUserProfiles(for: item.id)
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

private func encodeInterestedOnlyUUIDs(_ set: Set<UUID>) -> String {
    set.map(\.uuidString).sorted().joined(separator: ",")
}
