import SwiftUI

/// Composition root: presents Discover, Live, Calendar, Going, Chat, and Account tabs using shared view models from the root container.
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

    @AppStorage("gameon.require_device_auth_for_private_chat") private var requireDeviceAuthForPrivateChat = true
    @State private var chatGateAlertMessage: String?
    @State private var didRunInitialPrivateChatTabGate = false
    @State private var showBlockingFanIdentitySetup = false
    @State private var privateChatUnlockedForCurrentSelection = false
    @State private var discoverCalendarOverlayPresented = false

    private var selectedTab: AppTab {
        AppTab(rawValue: selectedTabStorage) ?? .discover
    }

    private var selectedTabBinding: Binding<AppTab> {
        Binding(
            get: { AppTab(rawValue: selectedTabStorage) ?? .discover },
            set: { newTab in selectedTabStorage = newTab.rawValue }
        )
    }

    enum AppTab: String {
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
                Task { await enforcePrivateChatGateOnLaunchIfNeeded() }
            }
    }

    private var tabShellWithLifecycleModifiers: some View {
        ZStack {
            preservedRoot(tab: .discover) {
                DiscoverScreen(
                    viewModel: viewModel,
                    chatViewModel: chatViewModel,
                    isCalendarOverlayPresented: $discoverCalendarOverlayPresented
                )
            }

            preservedRoot(tab: .live) {
                LiveScreen(
                    viewModel: viewModel,
                    chatViewModel: chatViewModel,
                    selectedTab: selectedTabBinding
                )
            }

            preservedRoot(tab: .calendar) {
                CalendarScreen(
                    viewModel: viewModel,
                    selectedTab: selectedTabBinding,
                    isCalendarTabSelected: selectedTab == .calendar
                )
            }

            preservedRoot(tab: .following) {
                FollowingScreen(
                    viewModel: viewModel,
                    suppressInitialAutoRefresh: true,
                    isFollowingTabSelected: selectedTab == .following
                )
            }

            preservedRoot(tab: .chat) {
                FriendsTabView(
                    mapViewModel: viewModel,
                    viewModel: chatViewModel,
                    isTabSelected: selectedTab == .chat
                )
                .padding(
                    .bottom,
                    chatViewModel.hidesFloatingTabBarForDirectChat ? 0 : Self.floatingTabBarStackHeight
                )
            }

            preservedRoot(tab: .account) {
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
            viewModel.isCalendarTabSelected = selectedTab == .calendar
            if !Self.hasForcedDiscoverTabThisProcess {
                Self.hasForcedDiscoverTabThisProcess = true
                selectedTabStorage = AppTab.discover.rawValue
#if DEBUG
                print("[StartupDiscover] selectedTab=\(AppTab.discover.rawValue)")
#endif
            }
            logBottomTabStructure()
            updateDirectChatReadStateVisibility()
            showBlockingFanIdentitySetup = viewModel.needsBlockingFanIdentitySetup
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: chatViewModel.hidesFloatingTabBarForDirectChat)
        .onChange(of: viewModel.switchToAccountForVenueClaim) { _, shouldSwitch in
            guard shouldSwitch else { return }
            viewModel.switchToAccountForVenueClaim = false
            withAnimation(.spring()) {
                selectedTabStorage = AppTab.account.rawValue
            }
        }
        // Startup core refresh: map/calendar data should not wait on profile, favorites, or social enrichment.
        .task {
            guard performsInitialBootstrap else { return }
            await viewModel.renderCachedDiscoverCore()

            await viewModel.prepareInitialDiscoverRegionAndPreload()

            await viewModel.bootstrapAuthSessionOnly()

            Task {
                await viewModel.refreshDiscoverCoreInBackground()
            }
            Task {
                await viewModel.refreshUserPersonalizationInBackground()
            }

            if viewModel.isAuthenticatedForSocialFeatures {
                await chatViewModel.loadIfNeeded()
                await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
            } else {
                await MainActor.run {
                    chatViewModel.clearForSignOut()
                }
            }
        }
        .onChange(of: viewModel.isAuthenticatedForSocialFeatures) { _, _ in
            updateDirectChatReadStateVisibility()
            Task { await syncChatAuthState() }
        }
        .onChange(of: viewModel.currentUserAuthId) { _, _ in
            Task { await syncChatAuthState() }
        }
        .onChange(of: viewModel.privateSessionClearNonce) { _, _ in
            chatViewModel.clearForSignOut()
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
        .onChange(of: viewModel.needsBlockingFanIdentitySetup) { _, needs in
            showBlockingFanIdentitySetup = needs
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
            guard preview != nil else { return }
            if requireDeviceAuthForPrivateChat && viewModel.isAuthenticatedForSocialFeatures {
                Task { await selectChatTabAfterDeviceAuth() }
            } else {
                privateChatUnlockedForCurrentSelection = true
                withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                    selectedTabStorage = AppTab.chat.rawValue
                }
                updateDirectChatReadStateVisibility()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                let hasSession = await viewModel.hasValidSession()
                if !hasSession {
                    await MainActor.run {
                        viewModel.clearAuthenticatedSessionCaches()
                        viewModel.clearVenueOwnerDraftState()
                        viewModel.isLoggedIn = false
                        viewModel.isVenueOwnerLoggedIn = false
                        viewModel.venueOwnerMode = false
                        viewModel.isAdminLoggedIn = false
                        viewModel.clearPersistedAccountMode()
                        chatViewModel.clearForSignOut()
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
                await viewModel.checkCurrentUserAdminStatus()
                chatViewModel.scheduleEnsureSocialRealtimeAfterForeground()
                await viewModel.verifyFanChatRealtimeAfterForeground()
                await viewModel.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
                if viewModel.canFanUsePickupGamesUI {
                    if AppTab(rawValue: selectedTabStorage) == .calendar {
                        await viewModel.refreshCalendarTabPickupSources()
                    } else {
                        await viewModel.loadMyPickupGameJoinRequestsForFollowing()
                    }
                }
            }
        }
        .onChange(of: viewModel.discoverNavigateToAccountForUserAuth) { _, go in
            guard go else { return }
            withAnimation(.spring()) {
                selectedTabStorage = AppTab.account.rawValue
            }
            privateChatUnlockedForCurrentSelection = false
            updateDirectChatReadStateVisibility()
            viewModel.discoverNavigateToAccountForUserAuth = false
        }
        .onChange(of: selectedTabStorage) { _, newRaw in
#if DEBUG
            print("[LiveTabDebug] selectedTab=\(newRaw)")
#endif
            viewModel.isCalendarTabSelected = AppTab(rawValue: newRaw) == .calendar
            switch AppTab(rawValue: newRaw) {
            case .calendar:
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
                viewModel.noteCalendarTabBecameActive()
            case .chat:
                updateDirectChatReadStateVisibility()
                guard viewModel.isAuthenticatedForSocialFeatures else { return }
                chatViewModel.requestBadgeRecalculation(reason: "chat_tab_selected", includeInboxSummaries: true)
            default:
                privateChatUnlockedForCurrentSelection = false
                updateDirectChatReadStateVisibility()
                return
            }
        }
        .environmentObject(chatViewModel)
        .onChange(of: viewModel.pendingFollowingMapVenueID) { _, id in
            guard id != nil else { return }
            withAnimation(.spring()) {
                selectedTabStorage = AppTab.discover.rawValue
            }
        }
    }

    /// Scene restore: if the saved tab is Chat, require local auth or bounce away from private messages.
    private func enforcePrivateChatGateOnLaunchIfNeeded() async {
        guard selectedTab == .chat else { return }
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        guard requireDeviceAuthForPrivateChat else { return }

        let outcome = await PrivateChatAccessGate.authenticateForPrivateChat()
        if outcome == .granted {
            await MainActor.run {
                privateChatUnlockedForCurrentSelection = true
                updateDirectChatReadStateVisibility()
            }
            return
        }

        await MainActor.run {
            withAnimation(.spring()) {
                selectedTabStorage = AppTab.discover.rawValue
            }
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
                withAnimation(.spring()) {
                    selectedTabStorage = AppTab.chat.rawValue
                }
                updateDirectChatReadStateVisibility()
            }
            return
        }

        guard requireDeviceAuthForPrivateChat else {
            await MainActor.run {
                privateChatUnlockedForCurrentSelection = true
                withAnimation(.spring()) {
                    selectedTabStorage = AppTab.chat.rawValue
                }
                updateDirectChatReadStateVisibility()
            }
            return
        }

        let outcome = await PrivateChatAccessGate.authenticateForPrivateChat()
        await MainActor.run {
            switch outcome {
            case .granted:
                privateChatUnlockedForCurrentSelection = true
                withAnimation(.spring()) {
                    selectedTabStorage = AppTab.chat.rawValue
                }
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

    private func syncChatAuthState() async {
        if viewModel.isAuthenticatedForSocialFeatures {
            await chatViewModel.refresh()
        } else {
            await MainActor.run {
                chatViewModel.clearForSignOut()
            }
        }
    }

    private func logBottomTabStructure() {
#if DEBUG
        print("[NavigationDebug] bottomTabStructure=Discover|Live|Calendar|Going|Chat|Profile")
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
                tabButton(.discover, title: "Discover", icon: "map.fill")

                tabButton(.live, title: "Live", icon: "dot.radiowaves.left.and.right", glow: FGColor.accentGreen)

                calendarTabButton()

                followingTabButton()

                chatTabButton()

                Button {
                    FGInteractionHaptics.selection()
                    withAnimation(.spring()) {
                        selectedTabStorage = AppTab.account.rawValue
                    }
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
            .padding(.bottom, 12)
        }
        .allowsHitTesting(true)
        .zIndex(2)
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
    }
    
    /// Business tab building icon: orange while any location claim is pending; green when every managed venue is active and nothing is pending.
    private var venueOwnerBusinessTabAccentColor: Color {
        if !viewModel.pendingVenueClaimsForSettings.isEmpty {
            return .orange
        }
        if viewModel.hasActiveVenueClaimRejectionForBusinessUI {
            return .red
        }
        let managed = viewModel.managedVenuesForOwner()
        guard !managed.isEmpty else { return .orange }
        let allActive = managed.allSatisfy { row in
            let s = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return s.isEmpty || s == "active"
        }
        return allActive ? .green : .orange
    }

    private var accountIconColor: Color {
        if viewModel.isVenueOwnerLoggedIn {
            return venueOwnerBusinessTabAccentColor
        }

        if viewModel.isLoggedIn {
            return .green
        }

        return .gray
    }

    private var accountIconName: String {

        if viewModel.isVenueOwnerLoggedIn {
            return "building.2.fill"
        }

        return "person.circle.fill"
    }

    private var floatingTabBarTint: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.34)
            : Color.white.opacity(0.58)
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
            Task { await selectChatTabAfterDeviceAuth() }
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 5) {
                    chatTabMessageIconWithUnreadBadge
                    if selectedTab == .chat {
                        Text("Chat")
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
            withAnimation(.spring()) {
                selectedTabStorage = AppTab.calendar.rawValue
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")

                    if selectedTab == .calendar {
                        Text("Calendar")
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
            withAnimation(.spring()) {
                selectedTabStorage = AppTab.following.rawValue
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 5) {
                    Image(systemName: "heart.fill")

                    if selectedTab == .following {
                        Text("Going")
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
    }

    private func tabButton(_ tab: AppTab, title: String, icon: String, glow: Color = FGColor.accentBlue) -> some View {
        Button {
            FGInteractionHaptics.selection()
            withAnimation(.spring()) {
                selectedTabStorage = tab.rawValue
            }
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
        if viewModel.isVenueOwnerLoggedIn {
            return "building.2.fill"
        }

        if viewModel.isLoggedIn {
            return "person.circle.fill"
        }

        return "person.circle"
    }

    private var accountTabTitle: String {
        if viewModel.isVenueOwnerLoggedIn {
            return "Business"
        }

        if viewModel.isLoggedIn {
            return "Account"
        }

        return "Login"
    }

    /// Avatar only; pickup participation activity now belongs in Going.
    private var accountTabAvatar: some View {
        accountTabAvatarCircleOnly
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .frame(width: 52, height: 52)
    }

    private var accountTabAvatarCircleOnly: some View {
        Group {
            if viewModel.isLoggedIn {
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
}
