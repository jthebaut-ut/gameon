import SwiftUI

/// Composition root: owns the shared ``MapViewModel`` and presents Discover, Calendar, Following, Chat, and Account tabs.
///
/// Inactive tabs stay in the hierarchy with opacity and hit testing disabled so map and list state survive tab switches. Launch ``.task`` restores the session, loads venues, then refreshes the schedule from Supabase.
struct MainTabView: View {
    @StateObject private var viewModel = MapViewModel()
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var notifications = InAppNotificationCenter.shared
    @SceneStorage("selectedMainTab") private var selectedTabStorage: String = AppTab.discover.rawValue

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

            if let toast = notifications.toast {
                inAppToast(toast)
                    .transition(
                        .move(edge: .top)
                            .combined(with: .opacity)
                    )
                    .zIndex(20)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: chatViewModel.hidesFloatingTabBarForDirectChat)
        .animation(.spring(response: 0.34, dampingFraction: 0.92), value: notifications.toast)
        // Restore auth, then hydrate map data once; `loadGamesFromSupabase` also refreshes venue event rows and interest summaries.
        .task {
            await viewModel.restoreSession()

            //viewModel.loadFavoriteVenueIDs()

            await viewModel.loadVenuesFromSupabase()

            viewModel.loadGamesFromSupabase()

            await chatViewModel.loadIfNeeded()
        }
        .onChange(of: viewModel.isLoggedIn) { _, isLoggedIn in
            if isLoggedIn {
                Task { await chatViewModel.refresh() }
            } else {
                Task { await chatViewModel.clearForLogout() }
            }
        }
        .environmentObject(chatViewModel)
    }

    private func inAppToast(_ toast: InAppNotificationCenter.Toast) -> some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(toast.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle = toast.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 10)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .onTapGesture { notifications.dismiss() }

            Spacer()
        }
        .allowsHitTesting(true)
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
    
    private var accountIconColor: Color {

        if viewModel.isVenueOwnerLoggedIn {
            return .orange
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
            withAnimation(.spring()) {
                selectedTabStorage = AppTab.chat.rawValue
            }
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

                if chatViewModel.unreadDirectMessageCount > 0 {
                    Text(chatViewModel.unreadDirectMessageCount > 99 ? "99+" : "\(chatViewModel.unreadDirectMessageCount)")
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
            return "Venue"
        }

        if viewModel.isLoggedIn {
            return "Account"
        }

        return "Login"
    }
    private var accountTabAvatar: some View {
        Group {
            if viewModel.isLoggedIn,
               let url = URL(string: viewModel.currentUserAvatarURL),
               !viewModel.currentUserAvatarURL.isEmpty {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ProgressView()
                }
            } else {
                Image(systemName: accountIconName)
                    .font(.title3)
                    .foregroundStyle(accountIconColor)
            }
        }
        .frame(width: 44, height: 44)
        .background(Color.white)
        .clipShape(Circle())
    }
    
}
