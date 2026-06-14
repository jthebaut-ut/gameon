import SwiftUI

/// Composition root: presents Discover, Live, Schedule, Going, Chat, and Account tabs using shared view models from the root container.
///
/// Inactive tabs stay in the hierarchy with opacity and hit testing disabled so map and list state survive tab switches. The root bootstrap container usually preloads startup data first; this view keeps a fallback ``.task`` only for timeout / degraded-entry cases.
struct MainTabView: View {
    private static var hasForcedDiscoverTabThisProcess = false

    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    let performsInitialBootstrap: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selectedMainTab") private var selectedTabStorage: String = AppTab.discover.rawValue

    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @AppStorage(PrivateChatSecuritySettings.requireFaceIDSettingKey) private var requireDeviceAuthForPrivateChat = false
    @State private var chatGateAlertMessage: String?
    @State private var didRunInitialPrivateChatTabGate = false
    @State private var showBlockingFanIdentitySetup = false
    @State private var lastAutoPresentedFanIdentitySetupUserId: UUID?
    @State private var privateChatUnlockedForCurrentSelection = false
    @State private var discoverCalendarOverlayPresented = false
    /// Sticky lazy mount: Discover at launch; other tabs insert on first selection and stay mounted.
    @State private var mountedTabs: Set<AppTab> = [.discover]
    @State private var didStartChatSocialRealtime = false
    @State private var chatSocialRealtimeDeferTask: Task<Void, Never>?
    @State private var foregroundDeferredBatchTask: Task<Void, Never>?
    @State private var tabSwitchStartAt: Date?
    @State private var tabSwitchCachedData: Bool?
    @State private var tabSwitchFromTab: AppTab?
    @State private var tabPreloadTasks: [AppTab: Task<Void, Never>] = [:]
    @State private var lastTabPreloadAt: [AppTab: Date] = [:]
    @State private var postAuthBadgeRefreshTask: Task<Void, Never>?
    @State private var postAuthBadgeRefreshUserId: UUID?
    @State private var lastPostAuthBadgeRefreshAt: Date?
    @State private var lastPostAuthBadgeRefreshUserId: UUID?

    private static let pokesBadgePollIntervalUnseenSeconds = 22
    private static let pokesBadgePollIntervalIdleSeconds = 105
    private static let chatSocialRealtimeGracePeriodSeconds: TimeInterval = 9
    private static let foregroundDeferredBatchDelayNs: UInt64 = 1_750_000_000
    private static let tabPreloadFreshnessInterval: TimeInterval = 30
    private static let postAuthBadgeRefreshThrottleInterval: TimeInterval = 4
    private static let postAuthBadgeRefreshCoalesceDelayNs: UInt64 = 140_000_000

    private var selectedTab: AppTab {
        AppTab(rawValue: selectedTabStorage) ?? .discover
    }

    private var selectedTabBinding: Binding<AppTab> {
        Binding(
            get: { AppTab(rawValue: selectedTabStorage) ?? .discover },
            set: { newTab in
                beginTabSwitch(to: newTab, reason: "selectedTabBinding")
                mountTab(newTab, reason: "selectedTabBinding")
                selectedTabStorage = newTab.rawValue
            }
        )
    }

    private func localized(_ key: String) -> String {
        L10n.t(key, languageCode: appLanguageRaw)
    }

    enum AppTab: String, CaseIterable {
        case discover
        case live
        case calendar
        case following
        case chat
        case account
    }

    /// Vertical space occupied by the floating capsule tab bar (padding + control height). Keeps Chat tab content above the overlay.
    private static let floatingTabBarStackHeight: CGFloat = 92

    var body: some View {
        tabShellWithLifecycleModifiers
            .environmentObject(viewModel)
            .environmentObject(chatViewModel)
            .overlay {
                FanXPRewardOverlayHost(manager: viewModel.fanXPRewardOverlay)
                    .id(ObjectIdentifier(viewModel.fanXPRewardOverlay))
            }
            .fullScreenCover(isPresented: $showBlockingFanIdentitySetup) {
                FanGeoIdentitySetupView(viewModel: viewModel, mode: .complete) {
                    showBlockingFanIdentitySetup = false
                }
                .interactiveDismissDisabled()
            }
            .alert(
                "Private chat",
                isPresented: Binding(
                    get: { chatGateAlertMessage != nil },
                    set: { if !$0 { chatGateAlertMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    chatGateAlertMessage = nil
                }
            } message: {
                Text(chatGateAlertMessage ?? "")
            }
            .onAppear {
                guard !didRunInitialPrivateChatTabGate else { return }
                didRunInitialPrivateChatTabGate = true
                print("[FaceIDSettingsDebug] defaultPrivateChatFaceID=false")
                print("[PrivateChatSecurityDebug] requireFaceIDSetting=\(requireDeviceAuthForPrivateChat)")
                Task { await enforcePrivateChatGateOnLaunchIfNeeded() }
            }
    }

    private var tabShellWithLifecycleModifiers: some View {
        ZStack {
            if selectedTab == .chat {
                chatTabRootBackground
                    .ignoresSafeArea()
            }

            lazyPreservedRoot(tab: .discover) {
                DiscoverScreen(
                    viewModel: viewModel,
                    chatViewModel: chatViewModel,
                    isCalendarOverlayPresented: $discoverCalendarOverlayPresented,
                    isDiscoverTabSelected: selectedTab == .discover
                )
            }

            lazyPreservedRoot(tab: .live) {
                LiveScreen(
                    viewModel: viewModel,
                    chatViewModel: chatViewModel,
                    selectedTab: selectedTabBinding
                )
            }

            lazyPreservedRoot(tab: .calendar) {
                CalendarScreen(
                    viewModel: viewModel,
                    selectedTab: selectedTabBinding,
                    isCalendarTabSelected: selectedTab == .calendar
                )
            }

            lazyPreservedRoot(tab: .following) {
                FollowingScreen(
                    viewModel: viewModel,
                    suppressInitialAutoRefresh: true,
                    isFollowingTabSelected: selectedTab == .following
                )
            }

            lazyPreservedRoot(tab: .chat) {
                FriendsTabView(
                    mapViewModel: viewModel,
                    viewModel: chatViewModel,
                    isTabSelected: selectedTab == .chat
                )
                .padding(
                    .bottom,
                    chatViewModel.hidesFloatingTabBarForDirectChat ? 0 : Self.floatingTabBarStackHeight
                )
                .background(chatTabRootBackground.ignoresSafeArea())
            }

            lazyPreservedRoot(tab: .account) {
                SettingsScreen(
                    viewModel: viewModel,
                    isAccountTabSelected: selectedTab == .account
                )
            }

            if !chatViewModel.hidesFloatingTabBarForDirectChat {
                floatingTabBarChrome
                    .opacity(discoverCalendarOverlayPresented && selectedTab == .discover ? 0.32 : 1)
                    .blur(radius: discoverCalendarOverlayPresented && selectedTab == .discover ? 1.25 : 0)
                    .allowsHitTesting(!(discoverCalendarOverlayPresented && selectedTab == .discover))
                    .animation(.easeInOut(duration: 0.24), value: discoverCalendarOverlayPresented)

            }
        }
        .overlay(alignment: .top) {
            dmInAppNotificationBannerLayer
        }
        .onAppear {
            AdDebugContext.setVisibleTab(selectedTabStorage)
            mountedTabs.insert(.discover)
            let restoredTab = selectedTab
            mountTab(restoredTab, reason: "mainTabOnAppear")
#if DEBUG
            print("[PerfLazyTab] restoredSelected tab=\(restoredTab.rawValue)")
            for tab in AppTab.allCases where !mountedTabs.contains(tab) {
                print("[PerfLazyTab] deferred tab=\(tab.rawValue)")
            }
#endif
            viewModel.isCalendarTabSelected = selectedTab == .calendar
            if !Self.hasForcedDiscoverTabThisProcess {
                Self.hasForcedDiscoverTabThisProcess = true
                selectTab(.discover, animated: false, reason: "startupForceDiscover")
#if DEBUG
                print("[StartupDiscover] selectedTab=\(AppTab.discover.rawValue)")
#endif
            }
            logBottomTabStructure()
            updateDirectChatReadStateVisibility()
            evaluateBlockingFanIdentitySetupPresentation(reason: "mainTabOnAppear")
            scheduleDeferredChatSocialRealtimeStartupIfNeeded()
            if selectedTab == .chat, viewModel.isAuthenticatedForSocialFeatures {
                Task { await startChatSocialRealtimeIfNeeded(reason: "launchVisibleChatTab") }
            }
            PresenceService.shared.startIfNeeded(
                userID: viewModel.currentUserAuthId,
                isAuthenticated: viewModel.isAuthenticatedForSocialFeatures,
                reason: "mainTabOnAppear"
            )

            LaunchWarmPreloadCoordinator.shared.beginIfNeeded(
                viewModel: viewModel,
                chatViewModel: chatViewModel,
                accountTabVisible: selectedTab == .account
            )
            schedulePostAuthBadgeRefresh(reason: "mainTabOnAppear")
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: chatViewModel.hidesFloatingTabBarForDirectChat)
        .onChange(of: viewModel.switchToAccountForVenueClaim) { _, shouldSwitch in
            guard shouldSwitch else { return }
            viewModel.switchToAccountForVenueClaim = false
            selectTab(.account, reason: "switchToAccountForVenueClaim")
        }
        // Splash timeout fallback: finish critical path only; warm preload handles the rest.
        .task {
            guard performsInitialBootstrap else { return }
            if LaunchBootstrapState.didCompleteCriticalBootstrap {
                print("[LaunchPerf] duplicateSkipped reason=fallbackCriticalAlreadyCompleted")
            } else {
                await BootstrapLoadingCoordinator.performCriticalBootstrap(
                    viewModel: viewModel,
                    chatViewModel: chatViewModel
                )
            }
            LaunchWarmPreloadCoordinator.shared.beginIfNeeded(
                viewModel: viewModel,
                chatViewModel: chatViewModel,
                accountTabVisible: selectedTab == .account
            )
            schedulePostAuthBadgeRefresh(reason: "criticalBootstrapCompleted")
            scheduleDeferredChatSocialRealtimeStartupIfNeeded()
        }
        .onChange(of: viewModel.isAuthenticatedForSocialFeatures) { _, authenticated in
            updateDirectChatReadStateVisibility()
            if !authenticated {
                cancelPostAuthBadgeRefresh(reason: "authUnavailable")
                didStartChatSocialRealtime = false
                chatSocialRealtimeDeferTask?.cancel()
                chatSocialRealtimeDeferTask = nil
                cancelTabPreloadTasks()
                LaunchWarmPreloadCoordinator.shared.cancel()
                PresenceService.shared.stop(reason: "authUnavailable")
                chatViewModel.clearForSignOut()
            } else {
                scheduleDeferredChatSocialRealtimeStartupIfNeeded()
                LaunchWarmPreloadCoordinator.shared.beginIfNeeded(
                    viewModel: viewModel,
                    chatViewModel: chatViewModel,
                    accountTabVisible: selectedTab == .account,
                    forceRefresh: true
                )
                Task { await viewModel.ensurePickupInviteRealtimeIfNeeded() }
                PresenceService.shared.startIfNeeded(
                    userID: viewModel.currentUserAuthId,
                    isAuthenticated: true,
                    reason: "authBecameAvailable"
                )
                schedulePostAuthBadgeRefresh(reason: "authBecameAvailable", force: true)
            }
        }
        .onChange(of: viewModel.currentUserAuthId) { _, newValue in
            if newValue == nil || newValue != lastAutoPresentedFanIdentitySetupUserId {
                lastAutoPresentedFanIdentitySetupUserId = nil
            }
            PresenceService.shared.startIfNeeded(
                userID: newValue,
                isAuthenticated: viewModel.isAuthenticatedForSocialFeatures,
                reason: "currentUserChanged"
            )
            if newValue == nil {
                cancelPostAuthBadgeRefresh(reason: "currentUserCleared")
            } else {
                schedulePostAuthBadgeRefresh(reason: "currentUserChanged", force: true)
            }
        }
        .onChange(of: viewModel.privateSessionClearNonce) { _, _ in
            cancelPostAuthBadgeRefresh(reason: "privateSessionCleared")
            chatViewModel.clearForSignOut()
            cancelTabPreloadTasks()
            LaunchWarmPreloadCoordinator.shared.cancel()
            PresenceService.shared.stop(reason: "privateSessionCleared")
        }
        .onChange(of: chatViewModel.unreadDirectMessageCount) { _, newValue in
#if DEBUG
            let visible = chatTabUnreadBadgeVisible(unreadCount: newValue)
            print("[BadgeArchitectureDebug] MainTabView observed ChatViewModel id=\(ObjectIdentifier(chatViewModel))")
            print("[ChatTabBadge] unreadCount=\(newValue)")
            print("[ChatTabBadge] visible=\(visible)")
            print("[MainActorDebug] MainTabView unread observer actor=MainActor")
#endif
        }
        .onChange(of: viewModel.profileEditPresentationEvaluationKey) { _, _ in
            evaluateBlockingFanIdentitySetupPresentation(reason: "profilePresentationStateChanged")
        }
        .onChange(of: chatViewModel.requiresSignIn) { _, _ in
#if DEBUG
            let n = chatViewModel.unreadDirectMessageCount
            let visible = chatTabUnreadBadgeVisible(unreadCount: n)
            print("[ChatTabBadge] unreadCount=\(n)")
            print("[ChatTabBadge] visible=\(visible)")
#endif
        }
        .onChange(of: chatViewModel.pendingDmOpenPreview) { _, preview in
            handlePendingDmOpenPreviewChange(preview)
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
        .onChange(of: viewModel.discoverNavigateToAccountForUserAuth) { _, go in
            guard go else { return }
            selectTab(.account, reason: "discoverNavigateToAccountForUserAuth")
            privateChatUnlockedForCurrentSelection = false
            updateDirectChatReadStateVisibility()
            viewModel.discoverNavigateToAccountForUserAuth = false
        }
        .onChange(of: viewModel.discoverFocusVenueId) { _, venueId in
            guard venueId != nil else { return }
            selectTab(.discover, reason: "discoverFocusVenueId")
        }
        .onChange(of: viewModel.requestDiscoverTabForHomeCrowd) { _, go in
            guard go else { return }
            selectTab(.discover, reason: "homeCrowdPick")
            viewModel.requestDiscoverTabForHomeCrowd = false
        }
        .onChange(of: selectedTabStorage) { _, newRaw in
            AdDebugContext.setVisibleTab(newRaw)
#if DEBUG
            if LiveRenderDiagnostics.enabled {
                print("[LiveTabDebug] selectedTab=\(newRaw)")
            }
#endif
            guard let tab = AppTab(rawValue: newRaw) else { return }
            mountTab(tab, reason: "selectedTabStorage")
            let switchStartedAt = tabSwitchStartAt ?? Date()
            let usedCachedData = tabSwitchCachedData ?? tabHasCachedData(tab)
#if DEBUG
            print("[TabPerfDebug] selectedTab=\(newRaw)")
            print("[TabPerfDebug] tabSwitchStart=\(switchStartedAt.timeIntervalSince1970)")
            print("[TabPerfDebug] usedCachedData=\(usedCachedData)")
#endif
            DispatchQueue.main.async {
                logTabFirstContentVisible(tab: tab, startedAt: switchStartedAt, usedCachedData: usedCachedData)
            }
            AdDebugDiagnostics.logEvent(
                event: "lazyTabMountState",
                format: "context",
                placement: "mainTabs",
                fields: [
                    "selectedTab": newRaw,
                    "mountedTabs": mountedTabs.map(\.rawValue).sorted().joined(separator: ","),
                    "discoverPreservedOffscreen": "\(newRaw != AppTab.discover.rawValue && mountedTabs.contains(.discover))"
                ]
            )
            viewModel.isCalendarTabSelected = tab == .calendar
            switch tab {
            case .account:
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
            case .calendar:
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
                viewModel.noteCalendarTabBecameActive()
            case .chat:
                updateDirectChatReadStateVisibility()
                guard viewModel.isAuthenticatedForSocialFeatures else { return }
                Task { await startChatSocialRealtimeIfNeeded(reason: "chatTabSelected") }
                chatViewModel.requestBadgeRecalculation(reason: "chat_tab_selected", includeInboxSummaries: true)
            default:
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
                return
            }
        }
        .task(id: pokesBadgeRefreshLoopToken) {
            await runPokesBadgeRefreshLoop()
        }
        .environmentObject(chatViewModel)
        .onChange(of: viewModel.pendingFollowingMapVenueID) { _, id in
            guard id != nil else { return }
            selectTab(.discover, reason: "pendingFollowingMapVenueID")
        }
        .onChange(of: viewModel.pendingFollowingMapPickupGameID) { _, id in
            guard id != nil else { return }
            selectTab(.discover, reason: "pendingFollowingMapPickupGameID")
            Task {
                await viewModel.consumeFollowingPickupGameNavigationIfPending()
            }
        }
    }

    private func evaluateBlockingFanIdentitySetupPresentation(reason: String) {
        let name = viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = viewModel.currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let missingRequiredFields = name.isEmpty && handle.isEmpty
        let authState: String = {
            if viewModel.isVenueOwnerLoggedIn { return "venueOwner" }
            if viewModel.isLoggedIn { return "fanAuthenticated" }
            return "signedOut"
        }()
        let suppressReason: String? = {
            if !viewModel.isLoggedIn { return "notAuthenticated" }
            if viewModel.isVenueOwnerLoggedIn { return "venueOwnerSession" }
            if viewModel.isAuthSessionRestoringForProfilePresentation { return "sessionRestoring" }
            if viewModel.isUserProfileLoadingForPresentation { return "profileLoading" }
            if !viewModel.hasLoadedUserProfileForPresentation { return "profileNotLoaded" }
            if !viewModel.userProfileExistsForPresentation { return "profileMissingOrNotCreated" }
            if !missingRequiredFields { return "requiredFieldsPresent" }
            if let userId = viewModel.currentUserAuthId,
               lastAutoPresentedFanIdentitySetupUserId == userId,
               !showBlockingFanIdentitySetup {
                return "alreadyPresentedThisSession"
            }
            return nil
        }()
        let shouldPresent = suppressReason == nil

#if DEBUG
        print("[ProfileEditPresentationDebug] authState=\(authState)")
        print("[ProfileEditPresentationDebug] profileLoading=\(viewModel.isUserProfileLoadingForPresentation)")
        print("[ProfileEditPresentationDebug] profileLoaded=\(viewModel.hasLoadedUserProfileForPresentation)")
        print("[ProfileEditPresentationDebug] missingRequiredFields=\(missingRequiredFields)")
        print("[ProfileEditPresentationDebug] shouldPresentEditProfile=\(shouldPresent)")
        print("[ProfileEditPresentationDebug] suppressReason=\(suppressReason ?? "none")")
#endif

        guard shouldPresent else {
            if showBlockingFanIdentitySetup,
               suppressReason == "requiredFieldsPresent" || suppressReason == "notAuthenticated" || suppressReason == "venueOwnerSession" {
                showBlockingFanIdentitySetup = false
            }
            return
        }

        if let userId = viewModel.currentUserAuthId {
            lastAutoPresentedFanIdentitySetupUserId = userId
        }
        showBlockingFanIdentitySetup = true
    }

    private func mountTab(_ tab: AppTab, reason: String) {
        if mountedTabs.contains(tab) { return }
        mountedTabs.insert(tab)
#if DEBUG
        print("[PerfLazyTab] mounted tab=\(tab.rawValue) reason=\(reason)")
#endif
    }

    private func selectTab(_ tab: AppTab, animated: Bool = true, reason: String = "userSelection") {
        beginTabSwitch(to: tab, reason: reason)
        mountTab(tab, reason: reason)
        if animated {
            withAnimation(.spring()) {
                selectedTabStorage = tab.rawValue
            }
        } else {
            selectedTabStorage = tab.rawValue
        }
    }

    private func beginTabSwitch(to tab: AppTab, reason: String) {
        tabSwitchFromTab = selectedTab
        tabSwitchStartAt = Date()
        tabSwitchCachedData = tabHasCachedData(tab)
        startTabIntentPreload(tab, reason: reason)
        UIPerformanceDiagnostics.signpost(
            "tab switch",
            "from=\(tabSwitchFromTab?.rawValue ?? "unknown") to=\(tab.rawValue) reason=\(reason)"
        )
        print("[TabSwitchPerf] begin from=\(tabSwitchFromTab?.rawValue ?? "unknown") to=\(tab.rawValue) cached=\(tabSwitchCachedData ?? false) reason=\(reason)")
#if DEBUG
        print("[UISmoothnessDebug] tabTransition=\(tabSwitchFromTab?.rawValue ?? "unknown")->\(tab.rawValue)")
        print("[TabPerfDebug] selectedTab=\(tab.rawValue)")
        print("[TabPerfDebug] tabSwitchStart=\(tabSwitchStartAt?.timeIntervalSince1970 ?? 0)")
        print("[TabPerfDebug] usedCachedData=\(tabSwitchCachedData ?? false)")
        print("[TabPerfDebug] reason=\(reason)")
#endif
    }

    private func logTabFirstContentVisible(tab: AppTab, startedAt: Date, usedCachedData: Bool) {
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        let from = tabSwitchFromTab?.rawValue ?? "unknown"
        UIPerformanceDiagnostics.log("tabSwitch from=\(from) to=\(tab.rawValue) ms=\(ms) cached=\(usedCachedData)")
        print("[TabSwitchPerf] firstContentVisible from=\(from) to=\(tab.rawValue) durationMs=\(ms) cached=\(usedCachedData)")
        switch tab {
        case .chat:
            UIPerformanceDiagnostics.signpost("DM inbox open", "ms=\(ms)")
            print("[TabPreloadDebug] tab=chat readyMs=\(ms)")
        case .account:
            UIPerformanceDiagnostics.signpost("Profile tab open", "ms=\(ms)")
            print("[TabPreloadDebug] tab=account readyMs=\(ms)")
        case .following:
            print("[TabPreloadDebug] tab=following readyMs=\(ms)")
        case .discover:
            print("[TabPreloadDebug] tab=discover readyMs=\(ms)")
        default:
            break
        }
#if DEBUG
        print("[TabPerfDebug] selectedTab=\(tab.rawValue)")
        print("[TabPerfDebug] firstContentVisibleMs=\(ms)")
        print("[TabPerfDebug] usedCachedData=\(usedCachedData)")
#endif
        tabSwitchStartAt = nil
        tabSwitchCachedData = nil
        tabSwitchFromTab = nil
    }

    private func startTabIntentPreload(_ tab: AppTab, reason: String) {
        let warmAtStart = tabHasCachedData(tab)
        if let last = lastTabPreloadAt[tab],
           Date().timeIntervalSince(last) < Self.tabPreloadFreshnessInterval,
           warmAtStart {
            print("[TabSwitchPerf] preloadSkipped tab=\(tab.rawValue) reason=fresh cached=true")
#if DEBUG
            print("[TabPreloadDebug] tab=\(tab.rawValue)")
            print("[TabPreloadDebug] warm=true")
            print("[TabPreloadDebug] skippedReason=fresh")
#endif
            return
        }
        if tabPreloadTasks[tab] != nil {
            print("[TabSwitchPerf] preloadSkipped tab=\(tab.rawValue) reason=inFlight cached=\(warmAtStart)")
#if DEBUG
            print("[TabPreloadDebug] tab=\(tab.rawValue)")
            print("[TabPreloadDebug] warm=\(warmAtStart)")
            print("[TabPreloadDebug] skippedReason=inFlight")
#endif
            return
        }

        let startedAt = Date()
        print("[TabSwitchPerf] preloadStarted tab=\(tab.rawValue) cached=\(warmAtStart) reason=\(reason)")
#if DEBUG
        print("[TabPreloadDebug] tab=\(tab.rawValue)")
        print("[TabPreloadDebug] warm=\(warmAtStart)")
        print("[TabPreloadDebug] reason=\(reason)")
#endif
        let task = Task { @MainActor in
            await runTabIntentPreload(tab: tab, reason: reason)
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            lastTabPreloadAt[tab] = Date()
            tabPreloadTasks[tab] = nil
            print("[TabSwitchPerf] preloadFinished tab=\(tab.rawValue) durationMs=\(ms)")
#if DEBUG
            print("[TabPreloadDebug] tab=\(tab.rawValue)")
            print("[TabPreloadDebug] durationMs=\(ms)")
#endif
        }
        tabPreloadTasks[tab] = task
    }

    private func runTabIntentPreload(tab: AppTab, reason _: String) async {
        guard !hasConfirmedSuspensionGateForPreload else { return }
        switch tab {
        case .chat:
            guard viewModel.isAuthenticatedForSocialFeatures else { return }
            _ = await chatViewModel.prefetchLightweightStartupChatData()
            await chatViewModel.refreshFriendRequestListsOnly()
        case .following:
            guard viewModel.isAuthenticatedForSocialFeatures, viewModel.canUseFollowingTab else { return }
            await viewModel.refreshFollowingTabDataGloballyUnlessFresh()
            if viewModel.canFanUsePickupGamesUI {
                await viewModel.loadMyPickupGameJoinRequestsForFollowing(reason: "tabPreload")
                await viewModel.loadMyPickupGamesForSettings()
                await viewModel.loadIncomingPickupGameInvites()
            }
        case .account:
            guard viewModel.isAuthenticatedForSocialFeatures else { return }
            await viewModel.prefetchLightweightUserDataForStartup()
            if viewModel.canReceiveProfilePokes {
                await viewModel.refreshUnseenPokesBadgeIfNeeded()
            }
        case .discover:
            guard viewModel.bars.isEmpty else { return }
            await viewModel.refreshDiscoverCoreInBackground()
        case .calendar:
            if viewModel.canFanUsePickupGamesUI {
                await viewModel.refreshCalendarTabPickupSources()
            }
        case .live:
            break
        }
    }

    private var hasConfirmedSuspensionGateForPreload: Bool {
        if viewModel.activeAccountBan != nil { return true }
        if viewModel.activeBusinessAccountBan != nil,
           viewModel.isBusinessBanGatePresented
            || viewModel.hasAuthenticatedVenueOwnerSession
            || viewModel.currentUserIsBusinessAccount
            || viewModel.venueOwnerMode {
            return true
        }
        return false
    }

    private func cancelTabPreloadTasks() {
        for task in tabPreloadTasks.values {
            task.cancel()
        }
        tabPreloadTasks.removeAll()
        lastTabPreloadAt.removeAll()
    }

    private func tabHasCachedData(_ tab: AppTab) -> Bool {
        switch tab {
        case .discover:
            return !viewModel.bars.isEmpty
        case .live:
            return !viewModel.liveMatches.isEmpty
        case .calendar:
            return !viewModel.events.isEmpty
        case .following:
            return !viewModel.followingTabGoingItems.isEmpty
                || !viewModel.followingTabSavedVenues.isEmpty
                || !viewModel.myPickupGameJoinRequestCards.isEmpty
                || !viewModel.myPickupGamesForSettings.isEmpty
        case .chat:
            return !chatViewModel.friends.isEmpty
                || !chatViewModel.incomingRequests.isEmpty
                || !chatViewModel.outgoingRequests.isEmpty
                || chatViewModel.unreadDirectMessageCount > 0
        case .account:
            return viewModel.currentUserAuthId != nil
                || !viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func handlePendingDmOpenPreviewChange(_ preview: UserPreview?) {
        guard preview != nil else { return }
        if requireDeviceAuthForPrivateChat && viewModel.isAuthenticatedForSocialFeatures {
            Task { await selectChatTabAfterDeviceAuth() }
        } else {
            if !requireDeviceAuthForPrivateChat {
                print("[PrivateChatSecurityDebug] biometricPromptSkippedReason=settingDisabled")
            }
            privateChatUnlockedForCurrentSelection = true
            selectTab(.chat, reason: "pendingDmOpenPreview")
            updateDirectChatReadStateVisibility()
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .active else {
            PresenceService.shared.stop(reason: "scenePhase.\(String(describing: phase))")
            if requireDeviceAuthForPrivateChat {
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
            }
            return
        }
        Task { await handleAppBecameActive() }
    }

    /// Scene restore: if the saved tab is Chat, require local auth or bounce away from private messages.
    private func enforcePrivateChatGateOnLaunchIfNeeded() async {
        guard selectedTab == .chat else { return }
        mountTab(.chat, reason: "enforcePrivateChatGateOnLaunch")
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        guard requireDeviceAuthForPrivateChat else {
            print("[PrivateChatSecurityDebug] biometricPromptSkippedReason=settingDisabled")
            await MainActor.run {
                privateChatUnlockedForCurrentSelection = true
                updateDirectChatReadStateVisibility()
            }
            return
        }

        print("[PrivateChatSecurityDebug] biometricPromptRequired=true")
        let outcome = await PrivateChatAccessGate.authenticateForPrivateChat()
        if outcome == .granted {
            await MainActor.run {
                privateChatUnlockedForCurrentSelection = true
                updateDirectChatReadStateVisibility()
            }
            return
        }

        await MainActor.run {
            selectTab(.discover, reason: "privateChatGateDenied")
            privateChatUnlockedForCurrentSelection = false
            updateDirectChatReadStateVisibility()
            switch outcome {
            case .authenticationFailed:
                chatGateAlertMessage = PrivateChatAccessGate.authenticationFailedMessage
            case .deviceSecurityNotConfigured:
                chatGateAlertMessage = PrivateChatAccessGate.noPasscodeMessage
            case .granted:
                break
            }
        }
    }

    /// Floating tab: enter Chat only after Face ID / Touch ID / passcode when the setting is enabled.
    private func selectChatTabAfterDeviceAuth() async {
        guard selectedTab != .chat else { return }

        if !viewModel.isAuthenticatedForSocialFeatures {
            await MainActor.run {
                privateChatUnlockedForCurrentSelection = true
                selectTab(.chat, reason: "selectChatTabAfterDeviceAuth")
                updateDirectChatReadStateVisibility()
            }
            return
        }

        guard requireDeviceAuthForPrivateChat else {
            print("[PrivateChatSecurityDebug] biometricPromptSkippedReason=settingDisabled")
            await MainActor.run {
                privateChatUnlockedForCurrentSelection = true
                selectTab(.chat, reason: "selectChatTabAfterDeviceAuth")
                updateDirectChatReadStateVisibility()
            }
            return
        }

        print("[PrivateChatSecurityDebug] biometricPromptRequired=true")
        let outcome = await PrivateChatAccessGate.authenticateForPrivateChat()
        await MainActor.run {
            switch outcome {
            case .granted:
                privateChatUnlockedForCurrentSelection = true
                selectTab(.chat, reason: "selectChatTabAfterDeviceAuth")
                updateDirectChatReadStateVisibility()
            case .authenticationFailed:
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
                chatGateAlertMessage = PrivateChatAccessGate.authenticationFailedMessage
            case .deviceSecurityNotConfigured:
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
                chatGateAlertMessage = PrivateChatAccessGate.noPasscodeMessage
            }
        }
    }

    private func updateDirectChatReadStateVisibility() {
        let chatVisible = selectedTab == .chat
        let unlocked = chatVisible
            && viewModel.isAuthenticatedForSocialFeatures
            && (!requireDeviceAuthForPrivateChat || privateChatUnlockedForCurrentSelection)
        chatViewModel.setDirectChatReadStateVisibility(
            chatTabVisible: chatVisible,
            privateChatUnlocked: unlocked
        )
    }

    private func schedulePostAuthBadgeRefresh(reason: String, force: Bool = false) {
        guard viewModel.isAuthenticatedForSocialFeatures,
              let userId = viewModel.currentUserAuthId else {
            print("[NotificationPerf] badgeRefreshSkipped reason=noAuthenticatedUser trigger=\(reason)")
#if DEBUG
            print("[BadgeLoginRefreshDebug] skipped because no authenticated user reason=\(reason)")
#endif
            return
        }

#if DEBUG
        print("[BadgeLoginRefreshDebug] auth event/session restored reason=\(reason) userId=\(userId.uuidString.lowercased())")
#endif

        if postAuthBadgeRefreshTask != nil, postAuthBadgeRefreshUserId == userId {
            print("[NotificationPerf] badgeRefreshCoalesced trigger=\(reason) userId=\(userId.uuidString.lowercased())")
#if DEBUG
            print("[BadgeLoginRefreshDebug] coalesced reason=\(reason) userId=\(userId.uuidString.lowercased())")
#endif
            return
        }

        if !force,
           lastPostAuthBadgeRefreshUserId == userId,
           let lastPostAuthBadgeRefreshAt,
           Date().timeIntervalSince(lastPostAuthBadgeRefreshAt) < Self.postAuthBadgeRefreshThrottleInterval {
            print("[NotificationPerf] badgeRefreshSkipped reason=throttled trigger=\(reason) userId=\(userId.uuidString.lowercased())")
#if DEBUG
            print("[BadgeLoginRefreshDebug] throttled reason=\(reason) userId=\(userId.uuidString.lowercased())")
#endif
            return
        }

        postAuthBadgeRefreshTask?.cancel()
        print("[NotificationPerf] badgeRefreshScheduled trigger=\(reason) force=\(force)")
        postAuthBadgeRefreshUserId = userId
        postAuthBadgeRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.postAuthBadgeRefreshCoalesceDelayNs)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await runPostAuthBadgeRefresh(userId: userId, reason: reason)
            if postAuthBadgeRefreshUserId == userId {
                postAuthBadgeRefreshTask = nil
                postAuthBadgeRefreshUserId = nil
            }
        }
    }

    private func cancelPostAuthBadgeRefresh(reason: String) {
        postAuthBadgeRefreshTask?.cancel()
        postAuthBadgeRefreshTask = nil
        postAuthBadgeRefreshUserId = nil
#if DEBUG
        print("[BadgeLoginRefreshDebug] cancelled reason=\(reason)")
#endif
    }

    private func runPostAuthBadgeRefresh(userId: UUID, reason: String) async {
        guard viewModel.isAuthenticatedForSocialFeatures,
              viewModel.currentUserAuthId == userId else {
            print("[NotificationPerf] badgeRefreshSkipped reason=sessionChanged trigger=\(reason)")
#if DEBUG
            print("[BadgeLoginRefreshDebug] skipped because no authenticated user reason=\(reason)")
#endif
            return
        }

        let startedAt = Date()
        lastPostAuthBadgeRefreshAt = Date()
        lastPostAuthBadgeRefreshUserId = userId
        print("[NotificationPerf] badgeRefreshStarted trigger=\(reason)")

        await chatViewModel.refreshFriendRequestListsOnly()
#if DEBUG
        print("[BadgeLoginRefreshDebug] pending friend requests count=\(chatViewModel.pendingBadgeCount)")
#endif

        await chatViewModel.refreshUnreadDirectMessageCount()
        await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()

        if viewModel.canFanUsePickupGamesUI {
            await viewModel.loadIncomingPickupGameInvites(forceRefresh: true)
            await viewModel.loadMyPickupGameJoinRequestsForFollowing(
                forceRefresh: true,
                reason: "postAuthBadgeRefresh_\(reason)"
            )
            await viewModel.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
            await viewModel.ensurePickupInviteRealtimeIfNeeded()
#if DEBUG
            print("[BadgeLoginRefreshDebug] pending pickup invites count=\(viewModel.incomingPickupGameInvites.count)")
#endif
        } else {
#if DEBUG
            print("[BadgeLoginRefreshDebug] pending pickup invites count=0")
#endif
        }

#if DEBUG
        print(
            "[BadgeLoginRefreshDebug] tab badge updated friendRequests=\(chatViewModel.pendingBadgeCount) dmUnread=\(chatViewModel.unreadDirectMessageCount) pickupInvites=\(viewModel.incomingPickupGameInvites.count) hostedPickupRequests=\(viewModel.pendingPickupGameJoinRequestCount) playingPickupCards=\(viewModel.myPickupGameJoinRequestCards.count)"
        )
#endif
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("[NotificationPerf] badgeRefreshFinished trigger=\(reason) durationMs=\(ms) friendRequests=\(chatViewModel.pendingBadgeCount) dmUnread=\(chatViewModel.unreadDirectMessageCount) pickupInvites=\(viewModel.incomingPickupGameInvites.count)")
    }

    private func logBottomTabStructure() {
#if DEBUG
        print("[NavigationDebug] bottomTabStructure=Discover|Live|Schedule|Going|Chat|Profile")
#endif
    }

    /// In-app toast when a DM arrives while the thread isn’t open (see ``ChatViewModel/dmInAppNotification``).
    private var dmInAppNotificationBannerLayer: some View {
        VStack {
            if let banner = chatViewModel.dmInAppNotification,
               !chatViewModel.hidesFloatingTabBarForDirectChat {
                dmInAppNotificationCard(banner)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: banner.id) {
                        try? await Task.sleep(nanoseconds: 8_500_000_000)
                        await MainActor.run {
                            if chatViewModel.dmInAppNotification?.id == banner.id {
                                chatViewModel.dismissDmInAppNotification()
                            }
                        }
                    }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(chatViewModel.dmInAppNotification != nil && !chatViewModel.hidesFloatingTabBarForDirectChat)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: chatViewModel.dmInAppNotification?.id)
        .zIndex(90)
    }

    private func dmInAppNotificationCard(_ banner: ChatViewModel.DmInAppNotificationPayload) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProfileAvatarView(preview: banner.senderPreview, size: 42)

            Button {
                chatViewModel.openConversationFromDmBanner()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(banner.senderPreview.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(banner.bodyPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                chatViewModel.dismissDmInAppNotification()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 14, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    /// Independent overlay: does not participate in `DirectChatView` layout; hidden during DM threads via ``ChatViewModel/hidesFloatingTabBarForDirectChat``.
    private var floatingTabBarChrome: some View {
        VStack {
            Spacer()

            HStack(spacing: 6) {
                tabButton(.discover, title: localized("discover"), icon: "map.fill")

                tabButton(.live, title: localized("live"), icon: "dot.radiowaves.left.and.right", glow: FGColor.accentGreen)

                calendarTabButton()

                followingTabButton()

                chatTabButton()

                Button {
                    FGInteractionHaptics.selection()
                    selectTab(.account, reason: "accountTabButton")
                } label: {
                    accountTabAvatar
                }
                .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
            }
            .padding(8)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(floatingTabBarTint)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(floatingTabBarBorder, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.12), radius: colorScheme == .dark ? 18 : 10, y: 8)
            .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.04), radius: 10, y: 2)
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .allowsHitTesting(true)
        .zIndex(2)
    }

    /// Lazy sticky mount: unmounted tabs render nothing; mounted tabs use off-screen preservation when inactive.
    @ViewBuilder
    private func lazyPreservedRoot<Content: View>(
        tab: AppTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if mountedTabs.contains(tab) {
            preservedRoot(tab: tab, content: content)
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // Renders a tab’s root off-screen when inactive so SwiftUI state is preserved without receiving touches.
    @ViewBuilder
    private func preservedRoot<Content: View>(
        tab: AppTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isSelected = selectedTab == tab
        content()
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .accessibilityHidden(!isSelected)
            .zIndex(isSelected ? 1 : 0)
            .animation(.easeInOut(duration: 0.18), value: isSelected)
    }
    
    private var isBusinessAccountTabContext: Bool {
        viewModel.isVenueOwnerLoggedIn || viewModel.venueOwnerMode || viewModel.currentUserIsBusinessAccount
    }

    private var businessTabIsPro: Bool {
        viewModel.businessDashboardPreloadSnapshot?.entitlementStatus?.computedIsPro == true
    }

    private var businessTabHasPendingVenueClaim: Bool {
        !viewModel.pendingVenueClaimsForSettings.isEmpty
    }

    private var businessTabShowsPendingClaimDot: Bool {
        BusinessStatusIconChrome.showsPendingClaimDot(
            isPro: businessTabIsPro,
            hasPendingVenueClaim: businessTabHasPendingVenueClaim
        )
    }

    private var businessTabStatusColor: Color {
        BusinessStatusIconChrome.statusColor(
            isPro: businessTabIsPro,
            hasPendingVenueClaim: businessTabHasPendingVenueClaim,
            colorScheme: colorScheme
        )
    }

    private var accountIconColor: Color {
        if isBusinessAccountTabContext {
            return businessTabStatusColor
        }

        if viewModel.isLoggedIn {
            return .green
        }

        return .gray
    }

    private var accountIconName: String {

        if isBusinessAccountTabContext {
            return "building.2.fill"
        }

        return "person.circle.fill"
    }

    private var floatingTabBarTint: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.34)
            : Color.white.opacity(0.58)
    }

    private var chatTabRootBackground: Color {
        colorScheme == .dark ? Color.black : Color(.systemBackground)
    }

    private var floatingTabBarBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white.opacity(0.55)
    }

    private var selectedTabBackgroundColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.86) : Color.black.opacity(0.92)
    }

    private var unselectedTabForegroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.74) : FGColor.secondaryText(colorScheme)
    }

    private var accountIconBackgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.white.opacity(0.92)
    }
    
    private func chatTabButton() -> some View {
        Button {
            FGInteractionHaptics.selection()
            startTabIntentPreload(.chat, reason: "chatTabButtonIntent")
            Task { await selectChatTabAfterDeviceAuth() }
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 5) {
                    chatTabMessageIconWithUnreadBadge
                    if selectedTab == .chat {
                        Text(localized("chat"))
                    }
                }
                .font(.caption)
                .fontWeight(.bold)
                .padding(.horizontal, selectedTab == .chat ? 12 : 10)
                .padding(.vertical, 10)
                .foregroundStyle(selectedTab == .chat ? Color.white : unselectedTabForegroundColor)
                .background(selectedTab == .chat ? selectedTabBackgroundColor : Color.clear)
                .clipShape(Capsule())
                .softActiveGlow(selectedTab == .chat, color: FGColor.accentBlue)

                if chatViewModel.pendingBadgeCount > 0 {
                    chatTabPillBadge(count: chatViewModel.pendingBadgeCount)
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
    }

    /// Same gate as ``FriendsTabView`` inbox (not ``MapViewModel/canUsePrivateChat``, which can lag session used by ``ChatViewModel``).
    private func chatTabUnreadBadgeVisible(unreadCount: Int) -> Bool {
        !chatViewModel.requiresSignIn && unreadCount > 0
    }

    /// Manual unread pill: SwiftUI `.badge` on custom floating-tab labels is unreliable; match inbox ``unreadDirectMessageCount``.
    /// Fixed layout size + padded overlay keeps the pill inside the tab row ``Capsule`` / floating bar clips (offsets do not expand layout).
    private var chatTabMessageIconWithUnreadBadge: some View {
        let n = chatViewModel.unreadDirectMessageCount
        let show = chatTabUnreadBadgeVisible(unreadCount: n)
        let label = n > 99 ? "99+" : "\(n)"

        return ZStack {
            Color.clear.frame(width: 44, height: 28)

            Image(systemName: "message.fill")
                .font(.system(size: 15, weight: .semibold))
        }
        .overlay(alignment: .topTrailing) {
            if show {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, n > 9 ? 5 : 4)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1, green: 0.42, blue: 0.12),
                                        Color(red: 0.92, green: 0.18, blue: 0.08)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    // Inset from the reserved rect so the capsule tab bar and outer rounded bar do not clip the pill.
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                    .accessibilityLabel("\(n) unread messages")
            }
        }
    }

    private func chatTabPillBadge(count: Int) -> some View {
        let label = count > 99 ? "99+" : "\(count)"
        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.red)
            .clipShape(Capsule())
    }

    private func calendarTabButton() -> some View {
        return Button {
            FGInteractionHaptics.selection()
            selectTab(.calendar, reason: "calendarTabButton")
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")

                    if selectedTab == .calendar {
                        Text(localized("Schedule"))
                    }
                }
                .font(.caption)
                .fontWeight(.bold)
                .padding(.horizontal, selectedTab == .calendar ? 12 : 10)
                .padding(.vertical, 10)
                .foregroundStyle(selectedTab == .calendar ? Color.white : unselectedTabForegroundColor)
                .background(selectedTab == .calendar ? selectedTabBackgroundColor : Color.clear)
                .clipShape(Capsule())
                .softActiveGlow(selectedTab == .calendar, color: FGColor.accentBlue)

            }
        }
        .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
    }

    private func followingTabButton() -> some View {
        Button {
            FGInteractionHaptics.selection()
            selectTab(.following, reason: "followingTabButton")
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 5) {
                    Image(systemName: "heart.fill")

                    if selectedTab == .following {
                        Text(localized("going"))
                    }
                }
                .font(.caption)
                .fontWeight(.bold)
                .padding(.horizontal, selectedTab == .following ? 12 : 10)
                .padding(.vertical, 10)
                .foregroundStyle(selectedTab == .following ? Color.white : unselectedTabForegroundColor)
                .background(selectedTab == .following ? selectedTabBackgroundColor : Color.clear)
                .clipShape(Capsule())
                .softActiveGlow(selectedTab == .following, color: FGColor.accentGreen)

                if goingTabHasActivity {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
                        .offset(x: 7, y: -6)
                        .accessibilityLabel("Pickup games activity")
                }
            }
        }
        .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
    }

    private var goingTabHasActivity: Bool {
        viewModel.hasUnreadPickupActivity
            || viewModel.pickupActivityCount > 0
            || viewModel.pendingPickupGameJoinRequestCount > 0
            || !viewModel.incomingPickupGameInvites.isEmpty
    }

    private func tabButton(_ tab: AppTab, title: String, icon: String, glow: Color = FGColor.accentBlue) -> some View {
        Button {
            FGInteractionHaptics.selection()
            selectTab(tab, reason: "tabButton")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                
                if selectedTab == tab {
                    Text(title)
                }
            }
            .font(.caption)
            .fontWeight(.bold)
            .padding(.horizontal, selectedTab == tab ? 12 : 10)
            .padding(.vertical, 10)
            .foregroundStyle(selectedTab == tab ? Color.white : unselectedTabForegroundColor)
            .background(selectedTab == tab ? selectedTabBackgroundColor : Color.clear)
            .clipShape(Capsule())
            .softActiveGlow(selectedTab == tab, color: glow)
        }
        .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
    }
    
    private var accountTabIcon: String {
        if isBusinessAccountTabContext {
            return "building.2.fill"
        }

        if viewModel.isLoggedIn {
            return "person.circle.fill"
        }

        return "person.circle"
    }

    private var accountTabTitle: String {
        if isBusinessAccountTabContext {
            return localized("business")
        }

        if viewModel.isLoggedIn {
            return localized("profile")
        }

        return "Login"
    }

    private var pokesBadgeRefreshLoopToken: String {
        let auth = viewModel.currentUserAuthId?.uuidString ?? "anonymous"
        return "\(auth)|pokes=\(viewModel.canReceiveProfilePokes)|unseen=\(viewModel.hasUnseenPokes)"
    }

    private func pokesBadgePollIntervalSeconds() -> Int {
        viewModel.hasUnseenPokes
            ? Self.pokesBadgePollIntervalUnseenSeconds
            : Self.pokesBadgePollIntervalIdleSeconds
    }

    private func runPokesBadgeRefreshLoop() async {
        guard viewModel.canReceiveProfilePokes else {
            viewModel.clearUnseenPokesBadgeState()
            return
        }

        while !Task.isCancelled {
            guard viewModel.canReceiveProfilePokes else {
                viewModel.clearUnseenPokesBadgeState()
                return
            }

            if scenePhase != .active {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            let intervalSeconds = pokesBadgePollIntervalSeconds()
            DebugLogGate.debug("[PerfPhase2D] pokesBadgePoll interval=\(intervalSeconds)")
            await viewModel.refreshUnseenPokesBadgeIfNeeded()

            do {
                try await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
            } catch {
                return
            }
        }
    }

    private var hasOpenVenueEventCommentsSheet: Bool {
        !viewModel.venueEventCommentsRealtimeTasks.isEmpty
            || !viewModel.venueEventCommentsRealtimeChannels.isEmpty
            || !viewModel.venueEventCommentsRealtimeListenerTokens.isEmpty
    }

    private func scheduleDeferredChatSocialRealtimeStartupIfNeeded() {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        guard !didStartChatSocialRealtime else { return }
        chatSocialRealtimeDeferTask?.cancel()
        DebugLogGate.debug("[PerfPhase2D] chatRealtimeDeferred reason=gracePeriodScheduled")
        chatSocialRealtimeDeferTask = Task {
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.chatSocialRealtimeGracePeriodSeconds * 1_000_000_000)
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await startChatSocialRealtimeIfNeeded(reason: "bootstrapGracePeriod")
        }
    }

    private func startChatSocialRealtimeIfNeeded(reason: String) async {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        guard !didStartChatSocialRealtime else { return }
        didStartChatSocialRealtime = true
        chatSocialRealtimeDeferTask?.cancel()
        chatSocialRealtimeDeferTask = nil
        DebugLogGate.debug("[PerfPhase2D] chatRealtimeStarted reason=\(reason)")
        await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
    }

    private func handleAppBecameActive() async {
        DebugLogGate.debug("[PerfPhase2D] foregroundBatch criticalStart")
        let foregroundRefreshStart = UIPerformanceDiagnostics.timestamp()
        defer {
            let ms = UIPerformanceDiagnostics.elapsedMs(since: foregroundRefreshStart)
            let currentTab = AppTab(rawValue: selectedTabStorage)?.rawValue ?? "unknown"
            UIPerformanceDiagnostics.log("visibleTabForegroundRefresh ms=\(UIPerformanceDiagnostics.formattedMs(ms)) tab=\(currentTab)")
        }

        let hasSession = await viewModel.hasValidSession()
        if !hasSession {
            if viewModel.isAuthSessionRestoringForProfilePresentation || viewModel.authSessionState == .loadingSession {
#if DEBUG
                print("[BusinessSessionRestoreDebug] forceLogoutSuppressedDuringRestore=true reason=foregroundInvalidSession")
#endif
                return
            }
            let shouldPreserveForRestore = await MainActor.run {
                viewModel.shouldPreserveMissingSessionForRestore()
            }
            if shouldPreserveForRestore {
                await viewModel.markTransientMissingSessionPreserved(
                    reason: "foregroundInvalidSession",
                    source: "MainTabView.handleAppBecameActive"
                )
#if DEBUG
                print("[BusinessLogoutTrace] transientMissingSessionPreserved=true reason=foregroundInvalidSession")
#endif
                Task {
                    await viewModel.bootstrapAuthSessionOnly()
                }
                return
            }
            await viewModel.forceLogout(reason: "foregroundInvalidSession", source: "MainTabView.handleAppBecameActive")
            await MainActor.run {
                chatViewModel.clearForSignOut()
                didStartChatSocialRealtime = false
                chatSocialRealtimeDeferTask?.cancel()
                chatSocialRealtimeDeferTask = nil
            }
            return
        }

        if viewModel.hasAuthenticatedVenueOwnerSession {
            await viewModel.refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
            viewModel.checkVenueApprovalStatus()
        }

        if viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn {
            await viewModel.enforceFanSingleSessionOnForeground()
            await viewModel.startFanSingleSessionRealtimeIfNeeded()
        }

        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        PresenceService.shared.startIfNeeded(
            userID: viewModel.currentUserAuthId,
            isAuthenticated: true,
            reason: "appBecameActive"
        )
        schedulePostAuthBadgeRefresh(reason: "foreground")
        await viewModel.checkCurrentUserAdminStatus()

        let currentTab = AppTab(rawValue: selectedTabStorage) ?? .discover

        if viewModel.isLoggedIn, !viewModel.isVenueOwnerLoggedIn {
            await viewModel.refreshUnseenPokesBadgeIfNeeded()
        }

        if currentTab == .chat {
            let hadChatRealtime = didStartChatSocialRealtime
            await startChatSocialRealtimeIfNeeded(reason: "foregroundVisibleChatTab")
            if hadChatRealtime {
                chatViewModel.scheduleEnsureSocialRealtimeAfterForeground()
            }
            await enforcePrivateChatGateOnLaunchIfNeeded()
        }

        if hasOpenVenueEventCommentsSheet {
            await viewModel.verifyFanChatRealtimeAfterForeground()
        }

        if viewModel.canFanUsePickupGamesUI {
            await viewModel.restartPickupInviteRealtimeAfterForeground()
            if currentTab == .calendar {
                await viewModel.refreshCalendarTabPickupSources()
            } else if currentTab == .following {
                await viewModel.loadMyPickupGameJoinRequestsForFollowing()
            }
        }

        foregroundDeferredBatchTask?.cancel()
        foregroundDeferredBatchTask = Task {
            await runForegroundDeferredBatch(visibleTab: currentTab)
        }
    }

    private func runForegroundDeferredBatch(visibleTab: AppTab) async {
        DebugLogGate.debug("[PerfPhase2D] foregroundBatch deferredStart")
        do {
            try await Task.sleep(nanoseconds: Self.foregroundDeferredBatchDelayNs)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        if visibleTab != .chat {
            if viewModel.isAuthenticatedForSocialFeatures {
                if didStartChatSocialRealtime {
                    chatViewModel.scheduleEnsureSocialRealtimeAfterForeground()
                } else {
                    await startChatSocialRealtimeIfNeeded(reason: "foregroundDeferred")
                }
            } else {
                DebugLogGate.debug("[PerfPhase2D] foregroundBatch skipped reason=chatSocialNotAuthenticated")
            }
        } else {
            DebugLogGate.debug("[PerfPhase2D] foregroundBatch skipped reason=chatSocialVisibleTabHandled")
        }

        if !hasOpenVenueEventCommentsSheet {
            await viewModel.verifyFanChatRealtimeAfterForeground()
        } else {
            DebugLogGate.debug("[PerfPhase2D] foregroundBatch skipped reason=fanChatVerifySheetOpen")
        }

        guard viewModel.canFanUsePickupGamesUI else { return }

        if visibleTab != .calendar {
            await viewModel.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
        } else {
            DebugLogGate.debug("[PerfPhase2D] foregroundBatch skipped reason=pickupCalendarVisibleTabHandled")
        }

        if visibleTab != .following {
            await viewModel.loadMyPickupGameJoinRequestsForFollowing()
        } else {
            DebugLogGate.debug("[PerfPhase2D] foregroundBatch skipped reason=pickupFollowingVisibleTabHandled")
        }
    }

    /// Avatar only; pickup participation activity now belongs in Going.
    private var accountTabAvatar: some View {
        ZStack(alignment: .topTrailing) {
            accountTabAvatarCircleOnly
                .frame(width: 44, height: 44)
                .clipShape(Circle())

            if accountTabPokesBadgeVisible {
                PokesUnseenAvatarBadge(style: .tab)
                    .offset(x: 0, y: -2)
            }

            if businessTabShowsPendingClaimDot {
                businessPendingClaimDot
                    .offset(x: -4, y: 2)
            }
        }
        .frame(width: 52, height: 52)
        .accessibilityLabel(accountTabPokesBadgeVisible ? "Account, new Pokes" : accountTabTitle)
        .onAppear {
            DebugLogGate.debug("[PokesBadgeUI] accountBadge visible=\(accountTabPokesBadgeVisible)")
        }
        .onChange(of: accountTabPokesBadgeVisible) { _, visible in
            DebugLogGate.debug("[PokesBadgeUI] accountBadge visible=\(visible)")
        }
    }

    private var accountTabPokesBadgeVisible: Bool {
        viewModel.canReceiveProfilePokes && viewModel.hasUnseenPokes
    }

    private var accountTabAvatarCircleOnly: some View {
        Group {
            if isBusinessAccountTabContext {
                Image(systemName: accountIconName)
                    .font(.title3)
                    .foregroundStyle(accountIconColor)
                    .frame(width: 44, height: 44)
                    .background(accountIconBackgroundColor)
            } else if viewModel.isLoggedIn {
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
                    fallbackStyle: colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome,
                    imagePlaceholderTint: colorScheme == .dark ? .white : nil
                )
            } else {
                Image(systemName: accountIconName)
                    .font(.title3)
                    .foregroundStyle(accountIconColor)
                    .frame(width: 44, height: 44)
                    .background(accountIconBackgroundColor)
            }
        }
    }

    private var businessPendingClaimDot: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 10, height: 10)
            .overlay {
                Circle()
                    .strokeBorder(accountIconBackgroundColor.opacity(0.96), lineWidth: 2)
            }
            .shadow(color: Color.orange.opacity(0.24), radius: 4, y: 1)
            .accessibilityHidden(true)
    }
}
