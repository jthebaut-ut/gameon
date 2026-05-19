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
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 8, y: 4)

        if preview.isBusinessIdentity {
            avatar
        } else {
            PublicProfileAvatarTap(userId: preview.id, context: profileTapContext) {
                avatar
            }
        }
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

    @State private var selectedSection: ChatSection = .friends
    @State private var showingAddFriendSheet = false
    @State private var showingBlockedUsersSheet = false
    @State private var manualFriendLookupDraft: String = ""
    /// Programmatic push (in-app DM banner → Chat tab → ``DirectChatView``).
    @State private var dmBannerNavigationFriend: UserPreview?

    private enum ChatSection: String, CaseIterable, Identifiable {
        case friends = "Friends"
        case requests = "Requests"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.requiresSignIn {
                    ContentUnavailableView(
                        "Sign in to chat",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Use your account tab to sign in, then open Chat again.")
                    )
                } else if viewModel.isLoading && viewModel.friends.isEmpty && viewModel.incomingRequests.isEmpty {
                    ProgressView("Loading…")
                } else {
                    VStack(spacing: 12) {
                        Picker("", selection: $selectedSection) {
                            ForEach(ChatSection.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)

                        Group {
                            switch selectedSection {
                            case .friends:
                                friendsList
                            case .requests:
                                requestsList
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
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
            if on {
                consumePendingDmOpenPreviewIfNeeded()
                Task { await viewModel.ensureSignedInSocialRealtimeIfNeeded() }
            }
        }
        .onAppear {
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
        .onChange(of: viewModel.pendingDmOpenPreview) { _, preview in
            guard preview != nil else { return }
            consumePendingDmOpenPreviewIfNeeded()
        }
        .alert(
            "Couldn’t update friend request",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert(
            "Couldn’t delete conversation",
            isPresented: Binding(
                get: { viewModel.inboxDeleteError != nil },
                set: { if !$0 { viewModel.inboxDeleteError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.inboxDeleteError = nil
            }
        } message: {
            Text(viewModel.inboxDeleteError ?? "")
        }
    }

    /// When switching to Chat from another tab (e.g. Account → Settings pickup), `onChange(pendingDmOpenPreview)` may not run
    /// because the preview is already non-nil when this view appears—drain it here so programmatic DM opens still navigate.
    private func consumePendingDmOpenPreviewIfNeeded() {
        guard !viewModel.requiresSignIn else { return }
        guard let preview = viewModel.pendingDmOpenPreview else { return }
        selectedSection = .friends
        dmBannerNavigationFriend = preview
        viewModel.pendingDmOpenPreview = nil
    }

    private var friendsList: some View {
        Group {
            if viewModel.friends.isEmpty {
                ContentUnavailableView(
                    "No conversations yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Accept a friend request or start chatting from a venue.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { layoutGeo in
                    friendsInboxList(layoutWidth: layoutGeo.size.width)
                }
            }
        }
    }

    private func friendsInboxList(layoutWidth: CGFloat) -> some View {
        List {
            ForEach(ChatInboxAdPlacement.listItems(for: viewModel.friends)) { item in
                chatInboxListRow(item, layoutWidth: layoutWidth)
            }
        }
        .listStyle(.plain)
        .refreshable { await viewModel.refreshInboxSummaries() }
        .onAppear {
            viewModel.clearActiveVisibleConversationId(reason: "chat_list_visible")
            logChatInboxAdPlacement()
        }
        .onChange(of: viewModel.friends.count) { _, _ in
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
        case .nativeAd:
            CompactNativeAdCard(
                placement: "chat.inboxFeed",
                hostTabRaw: "chat",
                slotIndex: ChatInboxAdPlacement.nativeAdSlotIndex,
                layoutWidth: max(280, layoutWidth)
            )
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private func logChatInboxAdPlacement() {
#if DEBUG
        print("[ChatInboxAdDebug] conversationCount=\(viewModel.friends.count)")
        print("[ChatInboxAdDebug] insertionIndex=\(ChatInboxAdPlacement.insertedAfterConversationPosition)")
        print("[ChatInboxAdDebug] debugOverride=\(ChatInboxAdPlacement.debugOverrideEnabled)")
        print("[ChatInboxAdDebug] enabled=true")
        print("[ChatInboxAdDebug] insertedAfterIndex=\(ChatInboxAdPlacement.insertedAfterConversationPosition)")
        print("[ChatInboxAdDebug] dmThreadAds=false")
#endif
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
                .refreshable { await viewModel.refresh() }
            }
        }
    }

    private func friendRow(_ item: ChatViewModel.FriendDisplay) -> some View {
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
            Text(Self.inboxTimeLabel(item.lastMessageAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
                    avatarDisplayRefreshToken: UUID(),
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
