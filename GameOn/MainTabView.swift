import SwiftUI

/// Composition root: owns the shared ``MapViewModel`` and presents Discover, Calendar, Following, Chat, and Account tabs.
///
/// Inactive tabs stay in the hierarchy with opacity and hit testing disabled so map and list state survive tab switches. Launch ``.task`` restores the session, loads venues, then refreshes the schedule from Supabase.
struct MainTabView: View {
    @StateObject private var viewModel = MapViewModel()
    @StateObject private var chatViewModel = ChatViewModel()
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
                FollowingScreen(viewModel: viewModel)
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
            viewModel.renderCachedDiscoverCore()

            await viewModel.bootstrapAuthSessionOnly()

            Task {
                await viewModel.refreshDiscoverCoreInBackground()
                await viewModel.refreshSocialEnrichmentInBackground()
            }
            Task {
                await viewModel.refreshUserPersonalizationInBackground()
            }

            await chatViewModel.loadIfNeeded()
        }
        .onChange(of: viewModel.isAuthenticatedForSocialFeatures) { _, _ in
            Task { await syncChatAuthState() }
        }
        .onChange(of: viewModel.currentUserAuthId) { _, _ in
            Task { await syncChatAuthState() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                guard viewModel.isAuthenticatedForSocialFeatures else { return }
                await viewModel.checkCurrentUserAdminStatus()
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
            await chatViewModel.clearForLogout()
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
                    accountTabAvatar
                }
            }
            .padding(8)
            .background(Color.white.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(radius: 8)
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
                .foregroundStyle(selectedTab == .chat ? Color.white : Color.primary)
                .background(selectedTab == .chat ? Color.black : Color.clear)
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
            .foregroundStyle(selectedTab == tab ? Color.white : Color.primary)
            .background(selectedTab == tab ? Color.black : Color.clear)
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
    private var accountTabAvatar: some View {
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
                    fallbackStyle: .lightOnWhiteChrome
                )
            } else {
                Image(systemName: accountIconName)
                    .font(.title3)
                    .foregroundStyle(accountIconColor)
                    .frame(width: 44, height: 44)
                    .background(Color.white)
                    .clipShape(Circle())
            }
        }
    }
    
}
