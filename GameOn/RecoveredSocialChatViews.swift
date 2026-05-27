import SwiftUI

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

    var body: some View {
        NavigationStack {
            chatRootContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(chatRootBackground)
            .navigationDestination(item: $dmBannerNavigationFriend) { friend in
                DirectChatView(friend: friend)
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        if mapViewModel.canUsePrivateChat {
                            Button {
                                showingAddFriendSheet = true
                            } label: {
                                Image(systemName: "person.badge.plus")
                                    .font(.system(size: 18, weight: .semibold))
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .accessibilityLabel("Add friend")
                        }

                        Button {
                            showingBlockedUsersSheet = true
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                        }
                        .accessibilityLabel("Chat options")
                    }
                }
            }
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
        }
        .onChange(of: friendDirectorySearchText) { _, query in
            rebuildFriendDisplaySnapshots(reason: "searchChanged")
            logFriendsDirectorySearchQuery(query)
        }
        .onChange(of: viewModel.pendingDmOpenPreview) { _, preview in
            guard preview != nil else { return }
            consumePendingDmOpenPreviewIfNeeded()
        }
        .modifier(ChatErrorAlertsModifier(viewModel: viewModel))
    }

    private func handleTabSelectedChange(_ on: Bool) {
        guard on else { return }
#if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
#endif
        rebuildFriendDisplaySnapshots(reason: "chatTabSelected")
#if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        print("[TabRenderPerf] tab=chat visible=true renderMs=\(String(format: "%.2f", ms))")
#endif
        UIPerformanceDiagnostics.signpost("DM inbox open", "source=tabSelected")
        consumePendingDmOpenPreviewIfNeeded()
        Task {
            await viewModel.ensureSignedInSocialRealtimeIfNeeded()
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
        consumePendingDmOpenPreviewIfNeeded()
        Task {
            await viewModel.refreshInboxSummariesIfNeeded()
            await viewModel.refreshFriendRequestListsOnly()
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
#if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        print("[RenderPerf] view=FriendsTabView renderMs=\(String(format: "%.2f", ms)) rebuildReason=\(reason)")
#endif
    }

    @ViewBuilder
    private var chatRootContent: some View {
        if viewModel.requiresSignIn {
            chatSignInRequiredView
        } else if viewModel.isLoading && viewModel.friends.isEmpty && viewModel.incomingRequests.isEmpty {
            ProgressView("Loading…")
        } else {
            VStack(spacing: 12) {
                chatSectionPicker
                selectedChatSectionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var chatSignInRequiredView: some View {
        ContentUnavailableView(
            "Sign in to chat",
            systemImage: "person.crop.circle.badge.questionmark",
            description: Text("Use your account tab to sign in, then open Chat again.")
        )
    }

    private var chatSectionPicker: some View {
        Picker("", selection: $selectedSection) {
            Text("Chats").tag(ChatSection.chats)
            Text("Friends").tag(ChatSection.friends)
            Text("Requests").tag(ChatSection.requests)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 4)
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

    private var chatsList: some View {
        Group {
            if chatConversationFriends.isEmpty {
                ContentUnavailableView(
                    "No conversations yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Accept a friend request or start chatting from a venue.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { layoutGeo in
                    chatsInboxList(layoutWidth: layoutGeo.size.width)
                }
            }
        }
        .onAppear {
            logChatInboxAdPlacement()
        }
    }

    private func chatsInboxList(layoutWidth: CGFloat) -> some View {
        let inboxItems = ChatInboxAdPlacement.listItems(for: chatConversationFriends)
        return List {
            ForEach(inboxItems) { item in
                chatInboxListRow(item, layoutWidth: layoutWidth)
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

    @ViewBuilder
    private func chatInboxListRow(_ item: ChatInboxListItem, layoutWidth: CGFloat) -> some View {
        switch item {
        case .conversation(let friend):
            NavigationLink {
                DirectChatView(friend: friend.preview)
            } label: {
                friendRow(friend)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    Task {
                        await viewModel.clearInboxConversation(withFriendUserId: friend.id)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
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
                    VStack(alignment: .leading, spacing: 14) {
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
            let df = DateFormatter()
            df.timeStyle = .short
            df.dateStyle = .none
            return df.string(from: date)
        }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let df = DateFormatter()
        df.locale = .autoupdatingCurrent
        df.setLocalizedDateFormatFromTemplate("MMM d")
        return df.string(from: date)
    }
}

private struct ChatFriendInboxRow: View, Equatable {
    let item: ChatViewModel.FriendDisplay
    let timeLabel: String

    static func == (lhs: ChatFriendInboxRow, rhs: ChatFriendInboxRow) -> Bool {
        lhs.item == rhs.item && lhs.timeLabel == rhs.timeLabel
    }

    var body: some View {
        HStack(spacing: 12) {
            ProfileAvatarView(preview: item.preview, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview.displayName)
                    .font(.subheadline.weight(.semibold))
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if item.unreadCount > 0 {
                    Text(item.unreadCount > 99 ? "99+ unread" : "\(item.unreadCount) unread")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
            Text(timeLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
                VStack(spacing: 6) {
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
