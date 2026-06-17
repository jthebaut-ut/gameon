import SwiftUI

private enum ChatRowTimeFormatters {
    static let shortTime: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()

    static let monthDay: DateFormatter = {
        let df = DateFormatter()
        df.locale = .autoupdatingCurrent
        df.setLocalizedDateFormatFromTemplate("MMM d")
        return df
    }()
}

// MARK: - Avatar (toolbar / rows / bubbles)

struct ProfileAvatarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var mapViewModel: MapViewModel
    let preview: UserPreview
    let size: CGFloat
    /// Passed to ``MapViewModel/presentPublicProfile(userId:context:)`` debug logs.
    var profileTapContext: String = "profile_avatar"

    var body: some View {
        let avatar = SocialAvatarRenderer.socialAvatarView(for: preview, size: size)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(FGColor.cardBackground(colorScheme))
            )
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if preview.isOnlineNow {
                    PresenceOnlineBadge(size: max(9, size * 0.22))
                        .offset(x: size * 0.03, y: size * 0.03)
                }
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 8, y: 4)

        if preview.isBusinessIdentity || !preview.canOpenPublicProfile {
            avatar
        } else {
            PublicProfileAvatarTap(userId: preview.id, context: profileTapContext) {
                avatar
            }
        }
    }
}

private struct PresenceOnlineBadge: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(FGColor.accentGreen)
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.92), lineWidth: max(1.5, size * 0.18))
            }
            .shadow(color: FGColor.accentGreen.opacity(0.32), radius: 4, y: 1)
            .accessibilityLabel("Online now")
    }
}

// MARK: - DM bubble row

struct DirectMessageBubbleView: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let isFromCurrentUser: Bool
    let showFriendAvatar: Bool
    let friendPreview: UserPreview
    let timestamp: String?

    private static let avatarColumnWidth: CGFloat = 34

    var body: some View {
        HStack(alignment: .bottom, spacing: FGSpacing.sm) {
            if !isFromCurrentUser, showFriendAvatar {
                ProfileAvatarView(preview: friendPreview, size: 30)
                    .frame(width: Self.avatarColumnWidth, alignment: .center)
            } else if !isFromCurrentUser {
                Color.clear
                    .frame(width: Self.avatarColumnWidth, height: 1)
            }

            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: FGSpacing.xs + 1) {
                Text(text)
                    .font(FGTypography.body)
                    .foregroundStyle(
                        isFromCurrentUser
                            ? Color.white.opacity(0.98)
                            : FGColor.primaryText(colorScheme)
                    )
                    .multilineTextAlignment(isFromCurrentUser ? .trailing : .leading)
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.sm + 3)
                    .background {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .fill(
                                isFromCurrentUser
                                    ? AnyShapeStyle(
                                        LinearGradient(
                                            colors: [FGColor.gradientMiddle.opacity(0.96), FGColor.gradientEnd.opacity(0.90)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    : AnyShapeStyle(FGColor.cardBackground(colorScheme))
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .strokeBorder(
                                isFromCurrentUser
                                    ? Color.white.opacity(0.12)
                                    : FGColor.divider(colorScheme),
                                lineWidth: 1
                            )
                    }
                    .softCardShadow()

                if let timestamp, !timestamp.isEmpty {
                    Text(timestamp)
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .padding(.horizontal, FGSpacing.xs)
                        .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
            .padding(.leading, isFromCurrentUser ? 52 : 0)
            .padding(.trailing, isFromCurrentUser ? 0 : 52)

            if isFromCurrentUser {
                Color.clear
                    .frame(width: Self.avatarColumnWidth, height: 1)
            }
        }
    }
}

// MARK: - Chat tab root (friends inbox + requests + DM threads)

struct FriendsTabView: View {
    @ObservedObject var mapViewModel: MapViewModel
    @ObservedObject var viewModel: ChatViewModel
    var isTabSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedSection: ChatSection = .chats
    @State private var showingAddFriendSheet = false
    @State private var showingBlockedUsersSheet = false
    @State private var manualFriendLookupDraft: String = ""
    @State private var friendDirectorySearchText = ""
    @State private var chatConversationFriendsSnapshot: [ChatViewModel.FriendDisplay] = []
    @State private var friendsDirectoryItemsSnapshot: [ChatViewModel.FriendDisplay] = []
    @State private var filteredFriendsDirectoryItemsSnapshot: [ChatViewModel.FriendDisplay] = []
    /// Populated after first paint from cached friend presence (see ``refreshFansLiveNowAfterFirstPaint``).
    @State private var fansLiveNowEntries: [ChatFansLiveNowEntry] = []
    /// Programmatic push (in-app DM banner → Chat tab → ``DirectChatView``).
    @State private var dmBannerNavigationFriend: UserPreview?

    private enum ChatSection: String, CaseIterable, Identifiable {
        case chats = "Chats"
        case friends = "Friends"
        case requests = "Requests"
        var id: String { rawValue }
    }

    private var chatRootBackground: Color {
        colorScheme == .dark ? Color.black : Color(.systemBackground)
    }

    private var chatConversationFriends: [ChatViewModel.FriendDisplay] {
        chatConversationFriendsSnapshot
    }

    private var friendsDirectoryItems: [ChatViewModel.FriendDisplay] {
        friendsDirectoryItemsSnapshot
    }

    private var filteredFriendsDirectoryItems: [ChatViewModel.FriendDisplay] {
        filteredFriendsDirectoryItemsSnapshot
    }

    private var isBusinessChatAccount: Bool {
        mapViewModel.currentUserIsBusinessAccount
            || mapViewModel.isVenueOwnerLoggedIn
            || mapViewModel.hasAuthenticatedVenueOwnerSession
    }

    private var hasChatAuthSession: Bool {
        mapViewModel.canUsePrivateChat || viewModel.currentUserAuthId != nil
    }

    private var hasRegularUserProfileForChatGate: Bool {
        mapViewModel.userProfileExistsForPresentation
            || !mapViewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !mapViewModel.currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowChatSignInRequired: Bool {
        !hasChatAuthSession
    }

    var body: some View {
        NavigationStack {
            chatRootContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(chatRootBackground)
            .navigationDestination(item: $dmBannerNavigationFriend) { friend in
                DirectChatView(friend: friend)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
        .background(chatRootBackground.ignoresSafeArea())
        .sheet(isPresented: $showingAddFriendSheet) {
            AddFriendGlassSheet(
                lookupDraft: $manualFriendLookupDraft,
                viewModel: viewModel,
                onClose: {
                    showingAddFriendSheet = false
                    manualFriendLookupDraft = ""
                    viewModel.clearAddFriendSearch()
                }
            )
        }
        .sheet(isPresented: $showingBlockedUsersSheet) {
            BlockedUsersSheet(viewModel: viewModel)
        }
        .onChange(of: isTabSelected) { _, on in
            handleTabSelectedChange(on)
        }
        .onAppear {
            handleAppear()
        }
        .onChange(of: viewModel.friends) { _, _ in
            rebuildFriendDisplaySnapshots(reason: "friendsChanged")
            logFriendsDirectoryLoadedCount()
            refreshFansLiveNowAfterFirstPaint(reason: "friendsPresenceChanged")
        }
        .onChange(of: friendDirectorySearchText) { _, query in
            rebuildFriendDisplaySnapshots(reason: "searchChanged")
            logFriendsDirectorySearchQuery(query)
        }
        .onChange(of: viewModel.pendingDmOpenPreview) { _, preview in
            guard preview != nil else { return }
            consumePendingDmOpenPreviewIfNeeded()
        }
        .onChange(of: viewModel.requiresSignIn) { _, _ in
            logChatAuthGate(reason: "requiresSignInChanged")
        }
        .onChange(of: viewModel.currentUserAuthId) { _, _ in
            logChatAuthGate(reason: "chatUserAuthIdChanged")
        }
        .onChange(of: mapViewModel.currentUserAuthId) { _, _ in
            logChatAuthGate(reason: "mapUserAuthIdChanged")
            fansLiveNowEntries = []
            ChatFansLiveNowSessionCache.clear(authId: nil)
        }
        .onChange(of: mapViewModel.currentUserIsBusinessAccount) { _, _ in
            logChatAuthGate(reason: "businessAccountChanged")
        }
        .modifier(ChatErrorAlertsModifier(viewModel: viewModel))
    }

    private func handleTabSelectedChange(_ on: Bool) {
        guard on else { return }
        AppPerfDebug.screenLoadStart(tab: "chat", source: "tabSelected")
        UIPerformanceDiagnostics.signpost("DM inbox open", "source=tabSelected")
        consumePendingDmOpenPreviewIfNeeded()
        Task { @MainActor in
            await Task.yield()
#if DEBUG
            let started = CFAbsoluteTimeGetCurrent()
#endif
            rebuildFriendDisplaySnapshots(reason: "chatTabSelected")
#if DEBUG
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            print("[TabRenderPerf] tab=chat visible=true renderMs=\(String(format: "%.2f", ms))")
            AppPerfDebug.mainActorBlocked(ms: ms, tab: "chat", source: "rebuildFriendDisplaySnapshots")
#endif
            await viewModel.ensureSignedInSocialRealtimeIfNeeded()
            refreshFansLiveNowAfterFirstPaint(reason: "chatTabSelected")
        }
    }

    private func handleAppear() {
#if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
#endif
        rebuildFriendDisplaySnapshots(reason: "appear")
#if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        print("[TabRenderPerf] tab=chat visible=\(isTabSelected) renderMs=\(String(format: "%.2f", ms))")
#endif
        if isTabSelected {
            UIPerformanceDiagnostics.signpost("DM inbox open", "source=onAppear")
        }
        viewModel.mapViewModel = mapViewModel
        logChatAuthGate(reason: "appear")
        consumePendingDmOpenPreviewIfNeeded()
        Task {
            if mapViewModel.didCompleteTabIntentPreloadRecently("chat", within: 10) {
                AppPerfDebug.refreshSkipped(tab: "chat", source: "inboxSummaries", reason: "tabPreloadRecent")
            } else {
                await viewModel.refreshInboxSummariesIfNeeded()
                await viewModel.refreshFriendRequestListsOnly()
            }
            if isTabSelected {
                await viewModel.ensureSignedInSocialRealtimeIfNeeded()
            }
        }
    }

    private func rebuildFriendDisplaySnapshots(reason: String) {
#if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
#endif
        let friends = viewModel.friends
        let conversations = friends.filter(\.isConversationBacked)
        let directory = friends
            .filter { !$0.preview.isDeleted }
            .sorted {
                $0.preview.displayName.localizedCaseInsensitiveCompare($1.preview.displayName) == .orderedAscending
            }
        let query = friendDirectorySearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [ChatViewModel.FriendDisplay]
        if query.isEmpty {
            filtered = directory
        } else {
            filtered = directory.filter { item in
                item.preview.displayName.lowercased().contains(query)
                    || (item.preview.username?.lowercased().contains(query) == true)
            }
        }
        chatConversationFriendsSnapshot = conversations
        friendsDirectoryItemsSnapshot = directory
        filteredFriendsDirectoryItemsSnapshot = filtered
        prefetchChatInboxAvatars(reason: reason, rows: conversations)
#if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        print("[RenderPerf] view=FriendsTabView renderMs=\(String(format: "%.2f", ms)) rebuildReason=\(reason)")
#endif
    }

    private func prefetchChatInboxAvatars(reason: String, rows: [ChatViewModel.FriendDisplay]) {
        let urls = rows.prefix(12).compactMap { item -> URL? in
            guard let raw = ImageDisplayURL.forList(
                thumbnail: item.preview.avatarThumbnailURL,
                full: item.preview.avatarURL
            ) else { return nil }
            return URL(string: raw)
        }
        guard !urls.isEmpty else {
#if DEBUG
            print("[SmoothPerf] operation=chatInboxAvatarPrefetch skipped=noURLs durationMs=0 coalesced=false avatarCount=0 reason=\(reason)")
#endif
            return
        }

        Task {
            let startedAt = Date()
            await DiscoverMapImageCache.shared.prefetch(urls: urls, bucket: .avatar)
#if DEBUG
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            print("[SmoothPerf] operation=chatInboxAvatarPrefetch skipped=none durationMs=\(ms) coalesced=false avatarCount=\(urls.count) reason=\(reason)")
#endif
        }
    }

    @ViewBuilder
    private var chatRootContent: some View {
        if shouldShowChatSignInRequired {
            chatSignInRequiredView
        } else if viewModel.isLoading && viewModel.friends.isEmpty && viewModel.incomingRequests.isEmpty {
            ProgressView("Loading…")
        } else {
            VStack(spacing: 10) {
                chatHeader
                chatSectionPicker
                selectedChatSectionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 10)
        }
    }

    private var chatSignInRequiredView: some View {
        ContentUnavailableView(
            "Sign in to chat",
            systemImage: "person.crop.circle.badge.questionmark",
            description: Text("Use your account tab to sign in, then open Chat again.")
        )
    }

    private func logChatAuthGate(reason: String) {
#if DEBUG
        let hasSession = hasChatAuthSession
        let reasonBlocked = hasSession ? "none" : "missingSupabaseSession"
        print("[ChatAuthGate] reason=\(reason)")
        print("[ChatAuthGate] hasSession=\(hasSession)")
        print("[ChatAuthGate] userEmail=\(mapViewModel.authenticatedSocialEmailForUI.isEmpty ? "nil" : mapViewModel.authenticatedSocialEmailForUI)")
        print("[ChatAuthGate] isBusinessAccount=\(isBusinessChatAccount)")
        print("[ChatAuthGate] hasUserProfile=\(hasRegularUserProfileForChatGate)")
        print("[ChatAuthGate] reasonBlocked=\(reasonBlocked)")
#endif
    }

    private var chatHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            FanGeoPagePurposeHeader(
                title: "Chat",
                subtitle: "Connect with fans, friends, and venues."
            )

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if mapViewModel.canUsePrivateChat {
                    chatHeaderButton(systemImage: "person.badge.plus", accessibilityLabel: "Add friend") {
                        showingAddFriendSheet = true
                    }
                }

                chatHeaderButton(systemImage: "ellipsis", accessibilityLabel: "Chat options") {
                    showingBlockedUsersSheet = true
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func chatHeaderButton(systemImage: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .frame(width: 38, height: 38)
                .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.74 : 0.96), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
                }
                .softCardShadow()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var chatSectionPicker: some View {
        HStack(spacing: 6) {
            ForEach(ChatSection.allCases) { section in
                chatSectionButton(section)
            }
        }
        .padding(4)
        .background {
            Capsule(style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.36 : 0.72))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        }
        .softCardShadow()
        .padding(.horizontal, 16)
    }

    private func chatSectionButton(_ section: ChatSection) -> some View {
        let isSelected = selectedSection == section
        let count = chatSectionCount(section)
        return Button {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                selectedSection = section
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: chatSectionIcon(section))
                    .font(.system(size: 12, weight: .bold))

                Text(section.rawValue)
                    .font(.system(size: 12.5, weight: isSelected ? .bold : .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(Color.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .padding(.horizontal, count > 99 ? 5 : 0)
                        .background(FGColor.accentGreen, in: Capsule())
                }
            }
            .foregroundStyle(isSelected ? FGColor.primaryText(colorScheme) : FGColor.secondaryText(colorScheme))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? FGColor.cardBackground(colorScheme) : Color.clear)
            }
            .overlay(alignment: .bottom) {
                Capsule(style: .continuous)
                    .fill(isSelected ? FGColor.accentGreen : Color.clear)
                    .frame(width: 26, height: 2)
                    .offset(y: -2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.rawValue), \(count)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func chatSectionCount(_ section: ChatSection) -> Int {
        switch section {
        case .chats:
            return chatConversationFriends.count
        case .friends:
            return friendsDirectoryItems.count
        case .requests:
            return viewModel.incomingRequests.count + viewModel.outgoingRequests.count
        }
    }

    private func chatSectionIcon(_ section: ChatSection) -> String {
        switch section {
        case .chats:
            return "bubble.left.and.bubble.right.fill"
        case .friends:
            return "person.2.fill"
        case .requests:
            return "person.badge.plus"
        }
    }

    @ViewBuilder
    private var selectedChatSectionContent: some View {
        switch selectedSection {
        case .chats:
            chatsList
        case .friends:
            friendsDirectoryList
        case .requests:
            requestsList
        }
    }

    /// When switching to Chat from another tab (e.g. Account → Settings pickup), `onChange(pendingDmOpenPreview)` may not run
    /// because the preview is already non-nil when this view appears—drain it here so programmatic DM opens still navigate.
    private func consumePendingDmOpenPreviewIfNeeded() {
        guard !viewModel.requiresSignIn else { return }
        guard let preview = viewModel.pendingDmOpenPreview else { return }
        selectedSection = .chats
        dmBannerNavigationFriend = preview
        viewModel.pendingDmOpenPreview = nil
    }

    private func refreshFansLiveNowAfterFirstPaint(reason: String) {
        guard selectedSection == .chats, !shouldShowChatSignInRequired else { return }
        Task { @MainActor in
            await Task.yield()
            let authId = mapViewModel.currentUserAuthId
            let suggestedFans = authId.flatMap { ProfilePhase1PersonalizationCache.suggestedFansByAuthId[$0] } ?? []
            let entries = ChatFansLiveNowSessionCache.resolve(
                authId: authId,
                friends: viewModel.friends,
                suggestedFans: suggestedFans
            )
            fansLiveNowEntries = entries
#if DEBUG
            print("[FansLiveNow] refresh reason=\(reason) count=\(entries.count)")
#endif
        }
    }

    private var fansLiveNowStrip: some View {
        ChatFansLiveNowStripView(
            entries: fansLiveNowEntries,
            onSeeAll: { selectedSection = .friends },
            onOpenProfile: { userId in
                mapViewModel.presentPublicProfile(userId: userId, context: "fans_live_now")
            }
        )
    }

    private var chatsList: some View {
        Group {
            if chatConversationFriends.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if !fansLiveNowEntries.isEmpty {
                            fansLiveNowStrip
                        }
                        chatEmptyState
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 110)
                }
                .background(chatRootBackground)
            } else {
                GeometryReader { layoutGeo in
                    VStack(spacing: 8) {
                        if !fansLiveNowEntries.isEmpty {
                            fansLiveNowStrip
                                .padding(.horizontal, 16)
                        }
                        chatsInboxList(layoutWidth: layoutGeo.size.width)
                    }
                }
            }
        }
        .onAppear {
            logChatInboxAdPlacement()
            refreshFansLiveNowAfterFirstPaint(reason: "chatsListAppear")
        }
    }

    private func chatsInboxList(layoutWidth: CGFloat) -> some View {
        let inboxItems = ChatInboxAdPlacement.listItems(for: chatConversationFriends)
        return List {
            Section {
                ForEach(inboxItems) { item in
                    chatInboxListRow(item, layoutWidth: layoutWidth)
                }
            } header: {
                chatListHeader(title: "Recent Chats", trailingTitle: chatConversationFriends.count > 3 ? "See all" : nil)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(chatRootBackground)
        .refreshable { await viewModel.refreshInboxSummaries() }
        .onAppear {
            viewModel.clearActiveVisibleConversationId(reason: "chat_list_visible")
            logChatInboxAdPlacement()
        }
        .onChange(of: chatConversationFriends.count) { _, _ in
            logChatInboxAdPlacement()
        }
    }

    private func chatListHeader(title: String, trailingTitle: String?) -> some View {
        HStack {
            Text(title)
                .font(.headline.weight(.bold))
                .textCase(nil)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Spacer()
            if let trailingTitle {
                Text(trailingTitle)
                    .font(.caption.weight(.bold))
                    .textCase(nil)
                    .foregroundStyle(FGColor.accentGreen)
            }
        }
        .padding(.horizontal, 0)
    }

    private var chatEmptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(FGColor.accentGreen)
                .frame(width: 52, height: 52)
                .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.10), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text("Start a conversation with fans, friends, or venues.")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                Text("Find local fans or explore sports venues to start planning your next game day.")
                    .font(.subheadline)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            HStack(spacing: 10) {
                Button {
                    showingAddFriendSheet = true
                } label: {
                    Label("Find Fans", systemImage: "person.badge.plus")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(FGColor.accentGreen, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    mapViewModel.requestDiscoverTabForHomeCrowd = true
                } label: {
                    Label("Explore Venues", systemImage: "map.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(FGColor.accentGreen)
                .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        }
        .softCardShadow()
    }

    @ViewBuilder
    private func chatInboxListRow(_ item: ChatInboxListItem, layoutWidth: CGFloat) -> some View {
        switch item {
        case .conversation(let friend):
            Button {
                dmBannerNavigationFriend = friend.preview
            } label: {
                friendRow(friend)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    Task {
                        await viewModel.clearInboxConversation(withFriendUserId: friend.id)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        case .nativeAd(let slot):
            if isTabSelected {
                let _ = logChatNativeAdInserted(slot)
                CompactNativeAdCard(
                    placement: "chat.inboxFeed",
                    hostTabRaw: "chat",
                    slotIndex: slot.slotIndex,
                    layoutWidth: max(280, layoutWidth)
                )
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                let _ = logChatNativeAdSkipped(reason: "tabNotSelected")
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: CompactNativeAdLayout.preferredHeight)
                    .allowsHitTesting(false)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
    }

    private func logChatInboxAdPlacement() {
        guard AdDiagnostics.enabled else { return }
        let conversationCount = chatConversationFriends.count
        let insertionIndexes = ChatInboxAdPlacement.insertionPositions(for: conversationCount)
        let renderedInsertionIndexes = insertionIndexes.map(String.init).joined(separator: ",")
        print("[NativeAdDebug] placement=chat.inboxFeed conversationCount=\(conversationCount)")
        print("[NativeAdDebug] placement=chat.inboxFeed insertedAtIndex=\(insertionIndexes.first ?? -1)")
        if let reason = ChatInboxAdPlacement.skippedReason(conversationCount: conversationCount) {
            print("[NativeAdDebug] placement=chat.inboxFeed skippedReason=\(reason)")
        }
        print("[ChatInboxAdDebug] conversationCount=\(conversationCount)")
        print("[ChatInboxAdDebug] insertionIndexes=[\(renderedInsertionIndexes)]")
        print("[ChatInboxAdDebug] adsInsertedCount=\(insertionIndexes.count)")
        print("[ChatInboxAdDebug] debugOverride=\(ChatInboxAdPlacement.debugOverrideEnabled)")
        print("[ChatInboxAdDebug] enabled=true")
        print("[ChatInboxAdDebug] dmThreadAds=false")
    }

    private func logChatNativeAdInserted(_ slot: ChatInboxNativeAdSlot) {
        guard AdDiagnostics.enabled else { return }
        print("[NativeAdDebug] placement=chat.inboxFeed insertedAtIndex=\(slot.insertedAfterConversationPosition)")
    }

    private func logChatNativeAdSkipped(reason: String) {
        guard AdDiagnostics.enabled else { return }
        print("[NativeAdDebug] placement=chat.inboxFeed skippedReason=\(reason)")
    }

    private var friendsDirectoryList: some View {
        Group {
            if friendsDirectoryItems.isEmpty {
                ContentUnavailableView(
                    "No friends yet",
                    systemImage: "person.2",
                    description: Text("Add fans to start building your sports circle.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        friendsDirectorySearchField

                        if filteredFriendsDirectoryItems.isEmpty {
                            Text("No friends match your search.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 28)
                        } else {
                            LazyVGrid(
                                columns: [
                                    GridItem(.adaptive(minimum: 158, maximum: 220), spacing: 12, alignment: .top)
                                ],
                                spacing: 12
                            ) {
                                ForEach(filteredFriendsDirectoryItems) { item in
                                    friendDirectoryCard(item)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 110)
                }
                .background(chatRootBackground)
                .refreshable {
                    await viewModel.refreshFriendRequestListsOnly()
                    await viewModel.refreshInboxSummaries()
                }
                .onAppear {
                    logFriendsDirectoryLoadedCount()
                }
            }
        }
    }

    private var friendsDirectorySearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(FGColor.mutedText(colorScheme))
            TextField("Search friends", text: $friendDirectorySearchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.92))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
        }
        .softCardShadow()
    }

    private var requestsList: some View {
        Group {
            if viewModel.incomingRequests.isEmpty && viewModel.outgoingRequests.isEmpty {
                ContentUnavailableView(
                    "No pending requests",
                    systemImage: "person.2",
                    description: Text("When someone adds you, it will show up here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !viewModel.incomingRequests.isEmpty {
                        Section("Requests") {
                            ForEach(viewModel.incomingRequests) { item in
                                requestRowIncoming(item)
                            }
                        }
                    }
                    if !viewModel.outgoingRequests.isEmpty {
                        Section("Sent") {
                            ForEach(viewModel.outgoingRequests) { item in
                                requestRowOutgoing(item)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(chatRootBackground)
                .refreshable { await viewModel.refresh() }
            }
        }
    }

    private func friendRow(_ item: ChatViewModel.FriendDisplay) -> some View {
        ChatFriendInboxRow(item: item, timeLabel: Self.inboxTimeLabel(item.lastMessageAt))
            .equatable()
    }

    private func friendDirectoryCard(_ item: ChatViewModel.FriendDisplay) -> some View {
        FriendDirectoryCard(
            item: item,
            colorScheme: colorScheme,
            onProfile: { openFriendProfile(from: $0) },
            onMessage: { openMessage(from: $0) }
        )
        .equatable()
    }

    private var friendDirectoryCardBackground: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(.ultraThinMaterial)
        }
        return AnyShapeStyle(Color.white.opacity(0.94))
    }

    private func friendDirectorySubtitle(for item: ChatViewModel.FriendDisplay) -> String {
        let handle = item.preview.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !handle.isEmpty {
            return FanGeoHandleRules.displayHandle(stored: handle)
        }
        return "FanGeo friend"
    }

    private func openMessage(from item: ChatViewModel.FriendDisplay) {
#if DEBUG
        print("[FriendsDirectoryDebug] messageTapped=\(item.id.uuidString.lowercased())")
#endif
        dmBannerNavigationFriend = item.preview
    }

    private func openFriendProfile(from item: ChatViewModel.FriendDisplay) {
#if DEBUG
        print("[FriendsDirectoryDebug] cardTapped=\(item.id.uuidString.lowercased())")
#endif
        mapViewModel.presentPublicProfile(userId: item.id, context: "friends_directory_card")
    }

    private func logFriendsDirectoryLoadedCount() {
#if DEBUG
        print("[FriendsDirectoryDebug] loadedCount=\(friendsDirectoryItems.count)")
#endif
    }

    private func logFriendsDirectorySearchQuery(_ query: String) {
#if DEBUG
        print("[FriendsDirectoryDebug] searchQuery=\(query.trimmingCharacters(in: .whitespacesAndNewlines))")
#endif
    }

    private func requestRowIncoming(_ item: ChatViewModel.IncomingRequestDisplay) -> some View {
        let declined = item.friendship.isDeclinedStatus
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProfileAvatarView(preview: item.requester, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.requester.displayName)
                        .font(.subheadline.weight(.semibold))
                    if declined {
                        Text("Declined")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.orange)
                    } else {
                        Text("Wants to connect")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if declined {
                Button("Clear") {
                    Task { await viewModel.clearIncomingDeclinedRequest(item) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.orange)
            } else {
                HStack(spacing: 10) {
                    Button("Accept") { Task { await viewModel.accept(item) } }
                        .buttonStyle(.borderedProminent)
                    Button("Decline") { Task { await viewModel.reject(item) } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
        .background {
            if declined {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(colorScheme == .dark ? 0.14 : 0.10))
            }
        }
    }

    private func requestRowOutgoing(_ item: ChatViewModel.OutgoingRequestDisplay) -> some View {
        let declined = item.friendship.isDeclinedStatus
        return HStack(spacing: 10) {
            ProfileAvatarView(preview: item.addressee, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.addressee.displayName)
                    .font(.subheadline.weight(.semibold))
                if declined {
                    Text("Declined")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.orange)
                } else {
                    Text("Pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if declined {
                Button("Clear") {
                    Task { await viewModel.clearOutgoingDeclinedRequest(item) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.orange)
            } else {
                Button("Cancel") { Task { await viewModel.cancel(item) } }
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
        .background {
            if declined {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(colorScheme == .dark ? 0.14 : 0.10))
            }
        }
    }

    private static func inboxTimeLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return ChatRowTimeFormatters.shortTime.string(from: date)
        }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return ChatRowTimeFormatters.monthDay.string(from: date)
    }
}

private struct ChatFriendInboxRow: View, Equatable {
    let item: ChatViewModel.FriendDisplay
    let timeLabel: String
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: ChatFriendInboxRow, rhs: ChatFriendInboxRow) -> Bool {
        lhs.item == rhs.item && lhs.timeLabel == rhs.timeLabel
    }

    var body: some View {
        HStack(spacing: 12) {
            ProfileAvatarView(preview: item.preview, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.preview.displayName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if !timeLabel.isEmpty {
                        Text(timeLabel)
                            .font(.caption2.weight(item.unreadCount > 0 ? .bold : .medium))
                            .foregroundStyle(item.unreadCount > 0 ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                }

                HStack(alignment: .center, spacing: 8) {
                    Text(chatPreviewLine)
                        .font(.caption.weight(item.unreadCount > 0 ? .semibold : .medium))
                        .foregroundStyle(item.unreadCount > 0 ? FGColor.primaryText(colorScheme) : FGColor.secondaryText(colorScheme))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if item.unreadCount > 0 {
                        Text(item.unreadCount > 99 ? "99+" : "\(item.unreadCount)")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(Color.white)
                            .frame(minWidth: 21, minHeight: 21)
                            .padding(.horizontal, item.unreadCount > 99 ? 5 : 0)
                            .background(FGColor.accentGreen, in: Capsule())
                    }
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.34 : 0.48), lineWidth: 1)
        }
        .softCardShadow()
    }

    private var chatPreviewLine: String {
        let raw = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Start the conversation" : raw
    }
}

private struct FriendDirectoryCard: View, Equatable {
    let item: ChatViewModel.FriendDisplay
    let colorScheme: ColorScheme
    let onProfile: (ChatViewModel.FriendDisplay) -> Void
    let onMessage: (ChatViewModel.FriendDisplay) -> Void

    static func == (lhs: FriendDirectoryCard, rhs: FriendDirectoryCard) -> Bool {
        lhs.item == rhs.item && lhs.colorScheme == rhs.colorScheme
    }

    var body: some View {
        VStack(spacing: 10) {
            Button {
                onProfile(item)
            } label: {
                VStack(spacing: 10) {
                    ProfileAvatarView(preview: item.preview, size: 74, profileTapContext: "friends_directory_avatar")
                        .padding(.top, 4)

                    VStack(spacing: 3) {
                        Text(item.preview.displayName)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)

                        Text(subtitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)
                    }
                    .frame(maxWidth: .infinity, minHeight: 38)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Button {
                onMessage(item)
            } label: {
                Label("Message", systemImage: "bubble.left.fill")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(FGColor.accentBlue, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 178)
        .background(cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.34 : 0.52), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .softCardShadow()
    }

    private var subtitle: String {
        let handle = item.preview.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !handle.isEmpty {
            return FanGeoHandleRules.displayHandle(stored: handle)
        }
        return "FanGeo friend"
    }

    private var cardBackground: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(.ultraThinMaterial)
        }
        return AnyShapeStyle(Color.white.opacity(0.94))
    }
}

private struct ChatErrorAlertsModifier: ViewModifier {
    @ObservedObject var viewModel: ChatViewModel

    private var friendRequestErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var inboxDeleteErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.inboxDeleteError != nil },
            set: { if !$0 { viewModel.inboxDeleteError = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .alert(
                "Couldn’t update friend request",
                isPresented: friendRequestErrorAlertBinding
            ) {
                Button("OK", role: .cancel) {
                    viewModel.errorMessage = nil
                }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert(
                "Couldn’t delete conversation",
                isPresented: inboxDeleteErrorAlertBinding
            ) {
                Button("OK", role: .cancel) {
                    viewModel.inboxDeleteError = nil
                }
            } message: {
                Text(viewModel.inboxDeleteError ?? "")
            }
    }
}

// MARK: - Blocked Users

private struct BlockedUsersSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.blockedUserIds.isEmpty {
                    ContentUnavailableView(
                        "No blocked users",
                        systemImage: "hand.raised.slash",
                        description: Text("People you block will appear here.")
                    )
                    .padding(.top, 24)
                } else {
                    List {
                        ForEach(blockedItems, id: \.id) { item in
                            HStack(spacing: 12) {
                                ProfileAvatarView(preview: item.preview, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.subheadline.weight(.semibold))
                                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Button("Unblock") {
                                    Task { await viewModel.unblockUser(item.id) }
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Blocked Users")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await viewModel.refreshBlockedUsers()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var blockedItems: [BlockedUserDisplay] {
        // If we can resolve previews, show them; otherwise show ids with fallback text.
        let byId = Dictionary(uniqueKeysWithValues: viewModel.blockedUserPreviews.map { ($0.id, $0) })
        return viewModel.blockedUserIds
            .map { id -> BlockedUserDisplay in
                if let preview = byId[id] {
                    return BlockedUserDisplay(
                        id: id,
                        preview: preview,
                        title: preview.displayName,
                        subtitle: nil
                    )
                }
                let fallback = UserPreview(id: id, displayName: "Blocked user", avatarURL: nil)
                return BlockedUserDisplay(
                    id: id,
                    preview: fallback,
                    title: "Blocked user",
                    subtitle: shortId(id)
                )
            }
            .sorted { $0.title < $1.title }
    }

    private func shortId(_ id: UUID) -> String {
        let s = id.uuidString
        return "\(s.prefix(8))…"
    }

    private struct BlockedUserDisplay: Identifiable {
        let id: UUID
        let preview: UserPreview
        let title: String
        let subtitle: String?
    }
}

// MARK: - Add Friend (Liquid Glass sheet)

private struct AddFriendSearchResultRow: View {
    let target: AddFriendSearchTarget
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                addFriendResultAvatar
                addFriendResultText
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.12)
                            : Color(.secondarySystemGroupedBackground).opacity(0.6)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var addFriendResultAvatar: some View {
        if target.entityType == .user {
            PublicProfileAvatarTap(userId: target.entityId, context: "add_friend_search") {
                UserAvatarView(
                    avatarThumbnailURL: target.avatarThumbnailURL,
                    avatarURL: target.avatarURL ?? "",
                    avatarDisplayRefreshToken: UserAvatarView.stableRefreshToken(
                        userId: target.entityId,
                        thumbnailURL: target.avatarThumbnailURL,
                        avatarURL: target.avatarURL
                    ),
                    displayName: target.displayName,
                    email: "",
                    size: 36,
                    fallbackStyle: .lightOnWhiteChrome,
                    imagePlaceholderTint: FGColor.accentBlue
                )
            }
        } else {
            Image(systemName: "building.2.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Circle())
        }
    }

    private var addFriendResultText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(target.listTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            if !target.publicHandleLine.isEmpty {
                Text(target.publicHandleLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if target.entityType == .business {
                Text("Business")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AddFriendGlassSheet: View {
    @Binding var lookupDraft: String
    @ObservedObject var viewModel: ChatViewModel
    let onClose: () -> Void

    @State private var inlineError: String?
    @State private var inlineWarning: String?
    @State private var successMessage: String?
    @State private var isSending = false
    @State private var selectedTarget: AddFriendSearchTarget?
    @State private var searchTask: Task<Void, Never>?

    private var normalizedDraft: String {
        FriendshipService.normalizedFriendLookupQuery(lookupDraft)
    }

    private var canSend: Bool {
        selectedTarget != nil && !isSending
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            VStack(alignment: .leading, spacing: 8) {
                Text("Search fans or businesses")
                    .font(.subheadline.weight(.semibold))

                TextField("Search by @handle, name, or email", text: $lookupDraft)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground).opacity(0.7))
                    )

                Text("Results show User vs Business. Pick one, then Send.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.addFriendSearchIsLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }

                searchResultsList

                if let successMessage {
                    Text(successMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
                if let inlineWarning {
                    Text(inlineWarning)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                if let inlineError {
                    Text(inlineError)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 18)

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .onChange(of: lookupDraft) { _, newValue in
            inlineError = nil
            inlineWarning = nil
            successMessage = nil
            selectedTarget = nil
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 320_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.refreshAddFriendSearch(query: newValue)
            }
        }
        .onChange(of: viewModel.addFriendSearchResults) { _, results in
            if selectedTarget == nil {
                selectedTarget = results.first
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
        .presentationBackground(.ultraThinMaterial)
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if viewModel.addFriendSearchResults.isEmpty {
            if !normalizedDraft.isEmpty, !viewModel.addFriendSearchIsLoading {
                Text("No matches yet. Try another @handle, name, or email.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.addFriendSearchResults) { target in
                        AddFriendSearchResultRow(
                            target: target,
                            isSelected: selectedTarget?.id == target.id
                        ) {
                            selectedTarget = target
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private var header: some View {
        HStack {
            Button("Close", action: onClose)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)

            Spacer()

            Text("Add friend")
                .font(.headline.weight(.semibold))

            Spacer()

            Button("Send") {
                guard let target = selectedTarget else { return }
                Task {
                    isSending = true
                    inlineError = nil
                    inlineWarning = nil
                    successMessage = nil
                    let outcome = await viewModel.sendFriendRequest(to: target)
                    switch outcome {
                    case .success:
                        successMessage = "Friend request sent."
                    case .informational(let msg):
                        inlineWarning = msg
                    case .error(let msg):
                        inlineError = msg
                    }
                    isSending = false
                }
            }
            .buttonStyle(.plain)
            .font(.headline.weight(.semibold))
            .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            .disabled(!canSend)
            .frame(width: 68, alignment: .trailing)
        }
        .padding(.horizontal, 18)
    }
}

// MARK: - Fans Live Now (Chat Chats tab)

struct ChatFansLiveNowEntry: Identifiable, Hashable {
    let id: UUID
    let preview: UserPreview
    let subtitle: String
}

enum ChatFansLiveNowSessionCache {
    static let displayLimit = 12

    private static var entriesByAuthId: [UUID: [ChatFansLiveNowEntry]] = [:]
    private static var presenceSignatureByAuthId: [UUID: String] = [:]

    static func clear(authId: UUID?) {
        guard let authId else {
            entriesByAuthId.removeAll()
            presenceSignatureByAuthId.removeAll()
            return
        }
        entriesByAuthId.removeValue(forKey: authId)
        presenceSignatureByAuthId.removeValue(forKey: authId)
    }

    static func resolve(
        authId: UUID?,
        friends: [ChatViewModel.FriendDisplay],
        suggestedFans: [FriendSuggestionProfile]
    ) -> [ChatFansLiveNowEntry] {
        guard let authId else { return [] }
        let signature = onlinePresenceSignature(friends)
        if let cached = entriesByAuthId[authId], presenceSignatureByAuthId[authId] == signature {
            return cached
        }
        let built = buildEntries(friends: friends, suggestedFans: suggestedFans)
        entriesByAuthId[authId] = built
        presenceSignatureByAuthId[authId] = signature
        return built
    }

    private static func onlinePresenceSignature(_ friends: [ChatViewModel.FriendDisplay]) -> String {
        friends
            .filter { !$0.preview.isDeleted && $0.preview.isOnlineNow }
            .map { "\($0.id.uuidString.lowercased()):\($0.preview.lastSeenAtRaw ?? "")" }
            .sorted()
            .joined(separator: "|")
    }

    private static func buildEntries(
        friends: [ChatViewModel.FriendDisplay],
        suggestedFans: [FriendSuggestionProfile]
    ) -> [ChatFansLiveNowEntry] {
        let suggestionByUserId = Dictionary(uniqueKeysWithValues: suggestedFans.map { ($0.userID, $0) })
        var seen = Set<UUID>()

        let onlineFriends = friends
            .filter { !$0.preview.isDeleted && $0.preview.isOnlineNow }
            .sorted { lhs, rhs in
                let left = PresenceOnlineStatus.parse(lhs.preview.lastSeenAtRaw) ?? .distantPast
                let right = PresenceOnlineStatus.parse(rhs.preview.lastSeenAtRaw) ?? .distantPast
                if left != right { return left > right }
                return lhs.preview.displayName.localizedCaseInsensitiveCompare(rhs.preview.displayName) == .orderedAscending
            }

        var entries: [ChatFansLiveNowEntry] = []
        entries.reserveCapacity(min(displayLimit, onlineFriends.count))

        for friend in onlineFriends {
            guard seen.insert(friend.id).inserted else { continue }
            entries.append(
                ChatFansLiveNowEntry(
                    id: friend.id,
                    preview: friend.preview,
                    subtitle: subtitle(for: friend.preview, suggestion: suggestionByUserId[friend.id])
                )
            )
            if entries.count >= displayLimit { break }
        }
        return entries
    }

    private static func subtitle(for preview: UserPreview, suggestion: FriendSuggestionProfile?) -> String {
        if preview.isBusinessAccount { return "Venue" }
        if let suggestion {
            if let label = suggestion.reasonLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty {
                return label
            }
            if suggestion.sharedFavoriteTeamsCount > 0 { return "Same Team" }
            if suggestion.sharedEventInterestCount > 0 { return "Same watch party" }
            if suggestion.sharedPickupGameCount > 0 { return "Same pickup game" }
            if suggestion.mutualFriendCount > 0 { return "Mutual friends" }
        }
        return "Active Fan"
    }
}

private struct ChatFansLiveNowStripView: View {
    @Environment(\.colorScheme) private var colorScheme

    let entries: [ChatFansLiveNowEntry]
    let onSeeAll: () -> Void
    let onOpenProfile: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Fans Live Now")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer()
                Button("See all", action: onSeeAll)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentGreen)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(entries) { entry in
                        ChatFansLiveNowCell(entry: entry, onOpenProfile: onOpenProfile)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fans live now")
    }
}

private struct ChatFansLiveNowCell: View {
    @Environment(\.colorScheme) private var colorScheme

    let entry: ChatFansLiveNowEntry
    let onOpenProfile: (UUID) -> Void

    private let avatarSize: CGFloat = 58
    private let ringSize: CGFloat = 66

    var body: some View {
        Button {
            onOpenProfile(entry.id)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .strokeBorder(FGColor.accentGreen.opacity(0.92), lineWidth: 2.5)
                        .frame(width: ringSize, height: ringSize)

                    SocialAvatarRenderer.socialAvatarView(for: entry.preview, size: avatarSize)
                        .frame(width: avatarSize, height: avatarSize)
                        .clipShape(Circle())
                        .overlay(alignment: .bottomTrailing) {
                            PresenceOnlineBadge(size: max(9, avatarSize * 0.22))
                                .offset(x: avatarSize * 0.03, y: avatarSize * 0.03)
                        }
                }

                Text(entry.preview.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                    .frame(width: ringSize + 8)

                Text(entry.subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                    .frame(width: ringSize + 8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.preview.displayName), \(entry.subtitle), online")
    }
}
