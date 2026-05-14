import SwiftUI

/// Composition root: presents Discover, Calendar, Following, Chat, and Account tabs using shared view models from the root container.
///
/// Inactive tabs stay in the hierarchy with opacity and hit testing disabled so map and list state survive tab switches. The root bootstrap container usually preloads startup data first; this view keeps a fallback ``.task`` only for timeout / degraded-entry cases.
struct MainTabView: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    let performsInitialBootstrap: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selectedMainTab") private var selectedTabStorage: String = AppTab.discover.rawValue

    @AppStorage("gameon.require_device_auth_for_private_chat") private var requireDeviceAuthForPrivateChat = true
    @State private var chatGateAlertMessage: String?
    @State private var didRunInitialPrivateChatTabGate = false

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
        case calendar
        case following
        case chat
        case account
    }

    /// Vertical space occupied by the floating capsule tab bar (padding + control height). Keeps Chat tab content above the overlay.
    private static let floatingTabBarStackHeight: CGFloat = 92

    var body: some View {
        ZStack {
            preservedRoot(tab: .discover) {
                DiscoverScreen(viewModel: viewModel)
            }

            preservedRoot(tab: .calendar) {
                CalendarScreen(
                    viewModel: viewModel,
                    selectedTab: selectedTabBinding
                )
            }

            preservedRoot(tab: .following) {
                FollowingScreen(
                    viewModel: viewModel,
                    suppressInitialAutoRefresh: true
                )
            }

            preservedRoot(tab: .chat) {
                FriendsTabView(
                    viewModel: chatViewModel,
                    isTabSelected: selectedTab == .chat
                )
                .padding(
                    .bottom,
                    chatViewModel.hidesFloatingTabBarForDirectChat ? 0 : Self.floatingTabBarStackHeight
                )
            }

            preservedRoot(tab: .account) {
                SettingsScreen(viewModel: viewModel)
            }

            if !chatViewModel.hidesFloatingTabBarForDirectChat {
                floatingTabBarChrome
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: chatViewModel.hidesFloatingTabBarForDirectChat)
        .onChange(of: viewModel.switchToAccountForVenueClaim) { _, shouldSwitch in
            guard shouldSwitch else { return }
            viewModel.switchToAccountForVenueClaim = false
            withAnimation(.spring()) {
                selectedTabStorage = AppTab.account.rawValue
            }
        }
        // Discover-first: disk snapshot + map/calendar core refresh never waits on profile, favorites, or social enrichment.
        .task {
            guard performsInitialBootstrap else { return }
            viewModel.renderCachedDiscoverCore()

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
            Task { await syncChatAuthState() }
        }
        .onChange(of: viewModel.currentUserAuthId) { _, _ in
            Task { await syncChatAuthState() }
        }
        .onChange(of: viewModel.privateSessionClearNonce) { _, _ in
            chatViewModel.clearForSignOut()
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
                guard viewModel.isAuthenticatedForSocialFeatures else { return }
                await viewModel.checkCurrentUserAdminStatus()
                await chatViewModel.scheduleEnsureSocialRealtimeAfterForeground()
                await viewModel.loadPendingPickupGameJoinRequestCountForCreator(resyncRealtimeSubscription: true)
            }
        }
        .onChange(of: viewModel.discoverNavigateToAccountForUserAuth) { _, go in
            guard go else { return }
            withAnimation(.spring()) {
                selectedTabStorage = AppTab.account.rawValue
            }
            viewModel.discoverNavigateToAccountForUserAuth = false
        }
        .environmentObject(chatViewModel)
        .onChange(of: viewModel.pendingFollowingMapVenueID) { _, id in
            guard id != nil else { return }
            withAnimation(.spring()) {
                selectedTabStorage = AppTab.discover.rawValue
            }
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

    /// Scene restore: if the saved tab is Chat, require local auth or bounce away from private messages.
    private func enforcePrivateChatGateOnLaunchIfNeeded() async {
        guard selectedTab == .chat else { return }
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
        guard requireDeviceAuthForPrivateChat else { return }

        let outcome = await PrivateChatAccessGate.authenticateForPrivateChat()
        guard outcome != .granted else { return }

        await MainActor.run {
            withAnimation(.spring()) {
                selectedTabStorage = AppTab.discover.rawValue
            }
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
                withAnimation(.spring()) {
                    selectedTabStorage = AppTab.chat.rawValue
                }
            }
            return
        }

        guard requireDeviceAuthForPrivateChat else {
            await MainActor.run {
                withAnimation(.spring()) {
                    selectedTabStorage = AppTab.chat.rawValue
                }
            }
            return
        }

        let outcome = await PrivateChatAccessGate.authenticateForPrivateChat()
        await MainActor.run {
            switch outcome {
            case .granted:
                withAnimation(.spring()) {
                    selectedTabStorage = AppTab.chat.rawValue
                }
            case .authenticationFailed:
                chatGateAlertMessage = PrivateChatAccessGate.authenticationFailedMessage
            case .deviceSecurityNotConfigured:
                chatGateAlertMessage = PrivateChatAccessGate.noPasscodeMessage
            }
        }
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

    /// Independent overlay: does not participate in `DirectChatView` layout; hidden during DM threads via ``ChatViewModel/hidesFloatingTabBarForDirectChat``.
    private var floatingTabBarChrome: some View {
        VStack {
            Spacer()

            HStack(spacing: 6) {
                tabButton(.discover, title: "Discover", icon: "map.fill")

                tabButton(.calendar, title: "Calendar", icon: "calendar")

                tabButton(.following, title: "Following", icon: "heart.fill")

                chatTabButton()

                Button {
                    withAnimation(.spring()) {
                        selectedTabStorage = AppTab.account.rawValue
                    }
                } label: {
                    accountTabAvatarWithPickupBadge
                }
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
            Task { await selectChatTabAfterDeviceAuth() }
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 5) {
                    Image(systemName: "message.badge")
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

                if chatViewModel.pendingBadgeCount > 0 {
                    Text(chatViewModel.pendingBadgeCount > 99 ? "99+" : "\(chatViewModel.pendingBadgeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .offset(x: 6, y: -6)
                }
            }
        }
    }

    private func tabButton(_ tab: AppTab, title: String, icon: String) -> some View {
        Button {
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
        }
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

    /// Avatar + optional pickup-request badge; outer frame reserves space so the tab bar capsule does not clip the badge.
    private var accountTabAvatarWithPickupBadge: some View {
        accountTabAvatarCircleOnly
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay(alignment: .topTrailing) {
                if viewModel.isLoggedIn,
                   viewModel.canFanUsePickupGamesUI,
                   viewModel.pendingPickupGameJoinRequestCount > 0 {
                    pickupJoinRequestAccountTabBadge
                }
            }
            .frame(width: 52, height: 52)
    }

    private var pickupJoinRequestAccountTabBadge: some View {
        let n = viewModel.pendingPickupGameJoinRequestCount
        let label = n > 9 ? "9+" : "\(n)"
        return Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .minimumScaleFactor(0.65)
            .lineLimit(1)
            .background(Color.orange)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
            )
            .offset(x: 2, y: -2)
    }

    /// Account tab avatar only (no badge); clipped separately from the badge overlay.
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
