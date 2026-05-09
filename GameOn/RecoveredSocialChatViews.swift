import SwiftUI

// MARK: - Avatar (toolbar / rows / bubbles)

struct ProfileAvatarView: View {
    let preview: UserPreview
    let size: CGFloat

    var body: some View {
        Group {
            if let raw = preview.avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty,
               let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Image(systemName: "person.circle.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
    }
}

// MARK: - DM bubble row

struct DirectMessageBubbleView: View {
    let text: String
    let isFromCurrentUser: Bool
    let showFriendAvatar: Bool
    let friendPreview: UserPreview
    let timestamp: String?

    private static let avatarColumnWidth: CGFloat = 30

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if !isFromCurrentUser, showFriendAvatar {
                ProfileAvatarView(preview: friendPreview, size: 28)
                    .frame(width: Self.avatarColumnWidth, alignment: .center)
            } else if !isFromCurrentUser {
                Color.clear
                    .frame(width: Self.avatarColumnWidth, height: 1)
            }

            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: 3) {
                Text(text)
                    .font(.body)
                    .multilineTextAlignment(isFromCurrentUser ? .trailing : .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isFromCurrentUser ? Color.accentColor.opacity(0.22) : Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let timestamp, !timestamp.isEmpty {
                    Text(timestamp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: isFromCurrentUser ? .trailing : .leading)

            if isFromCurrentUser {
                Color.clear
                    .frame(width: Self.avatarColumnWidth, height: 1)
            }
        }
    }
}

// MARK: - Chat tab root (friends inbox + requests + DM threads)

struct FriendsTabView: View {
    @ObservedObject var viewModel: ChatViewModel
    var isTabSelected: Bool

    @State private var selectedSection: ChatSection = .friends
    @State private var showingAddFriendSheet = false
    @State private var showingBlockedUsersSheet = false
    @State private var manualFriendIdDraft: String = ""

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
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        Button {
                            showingAddFriendSheet = true
                        } label: {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                        }
                        .accessibilityLabel("Add friend")

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
                manualId: $manualFriendIdDraft,
                onClose: { showingAddFriendSheet = false },
                onSend: { uuid in
                    Task { await viewModel.sendFriendRequest(to: uuid) }
                    showingAddFriendSheet = false
                    manualFriendIdDraft = ""
                }
            )
        }
        .sheet(isPresented: $showingBlockedUsersSheet) {
            BlockedUsersSheet(viewModel: viewModel)
        }
        .onChange(of: isTabSelected) { _, on in
            viewModel.setInboxRealtimeEnabled(on)
        }
        .onAppear {
            if isTabSelected {
                viewModel.setInboxRealtimeEnabled(true)
            }
            Task {
                await viewModel.refreshInboxSummariesIfNeeded()
            }
        }
        .onDisappear {
            viewModel.setInboxRealtimeEnabled(false)
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
                List {
                    ForEach(viewModel.friends) { item in
                        NavigationLink {
                            DirectChatView(friend: item.preview)
                        } label: {
                            friendRow(item)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task {
                                    await viewModel.clearInboxConversation(withFriendUserId: item.id)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await viewModel.refreshInboxSummaries() }
            }
        }
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
            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.inboxTimeLabel(item.lastMessageAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.65))
            }
        }
        .padding(.vertical, 2)
    }

    private func requestRowIncoming(_ item: ChatViewModel.IncomingRequestDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProfileAvatarView(preview: item.requester, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.requester.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text("Wants to connect")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button("Accept") { Task { await viewModel.accept(item) } }
                    .buttonStyle(.borderedProminent)
                Button("Decline") { Task { await viewModel.reject(item) } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private func requestRowOutgoing(_ item: ChatViewModel.OutgoingRequestDisplay) -> some View {
        HStack(spacing: 10) {
            ProfileAvatarView(preview: item.addressee, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.addressee.displayName)
                    .font(.subheadline.weight(.semibold))
                Text("Pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Cancel") { Task { await viewModel.cancel(item) } }
                .font(.caption.weight(.semibold))
        }
        .padding(.vertical, 4)
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

private struct AddFriendGlassSheet: View {
    @Binding var manualId: String
    let onClose: () -> Void
    let onSend: (UUID) -> Void

    private var parsedUUID: UUID? {
        UUID(uuidString: manualId.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(spacing: 14) {
            header

            infoPill

            VStack(alignment: .leading, spacing: 8) {
                Text("Manual add")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                TextField("Paste friend ID (advanced)", text: $manualId)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground).opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )

                Text("Usually you will not need this. If someone sent you a code or ID, paste it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)

            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
        .presentationBackground(.ultraThinMaterial)
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
                if let id = parsedUUID { onSend(id) }
            }
            .buttonStyle(.plain)
            .font(.headline.weight(.semibold))
            .foregroundStyle(parsedUUID == nil ? Color.secondary : Color.accentColor)
            .disabled(parsedUUID == nil)
            .frame(width: 68, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 2)
    }

    private var infoPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Add friends from comments, activity, and live event interactions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .padding(.horizontal, 18)
    }
}
