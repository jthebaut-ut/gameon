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
                                switch tab {
                                case .friends:
                                    Text("Friends").tag(tab)
                                case .requests:
                                    if viewModel.pendingBadgeCount > 0 {
                                        Text("Requests \(viewModel.pendingBadgeCount > 99 ? "99+" : "\(viewModel.pendingBadgeCount)")")
                                            .tag(tab)
                                    } else {
                                        Text("Requests").tag(tab)
                                    }
                                }
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
                    Button {
                        showingAddFriendSheet = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 18, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("Add friend")
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
            ZStack(alignment: .topTrailing) {
                ProfileAvatarView(preview: item.preview, size: 44)
                if item.unreadCount > 0 {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                        )
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview.displayName)
                    .font(.subheadline.weight(.semibold))
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.inboxTimeLabel(item.lastMessageAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if item.unreadCount > 0 {
                    Text(item.unreadCount > 99 ? "99+" : "\(item.unreadCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.92))
                        .clipShape(Capsule())
                        .accessibilityLabel("\(item.unreadCount) unread messages")
                }
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

// MARK: - Add Friend (Liquid Glass sheet)

private struct AddFriendGlassSheet: View {
    @Binding var manualId: String
    let onClose: () -> Void
    let onSend: (UUID) -> Void

    private var parsedUUID: UUID? {
        UUID(uuidString: manualId.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Keep system dim/blur minimal by using a clear sheet background
            // and a floating glass panel inside.
            Color.clear

            floatingPanel
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
        }
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
        .presentationBackground(.clear)
        .presentationBackgroundInteraction(.enabled(upThrough: .height(420)))
    }

    private var floatingPanel: some View {
        VStack(spacing: 12) {
            dragHandle
                .padding(.top, 10)

            header
                .padding(.top, 2)

            infoPill

            manualAddSection

            Spacer(minLength: 6)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.90)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 18, x: 0, y: 10)
    }

    private var dragHandle: some View {
        Capsule()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 44, height: 4)
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack {
            Button("Close", action: onClose)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary.opacity(0.78))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(.thinMaterial)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                )

            Spacer()

            Text("Add friend")
                .font(.subheadline.weight(.semibold))

            Spacer()

            Button("Send") {
                if let id = parsedUUID { onSend(id) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(parsedUUID == nil ? Color.secondary.opacity(0.75) : Color.accentColor)
            .disabled(parsedUUID == nil)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(.thinMaterial)
                    .opacity(parsedUUID == nil ? 0.55 : 1)
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            )
        }
    }

    private var infoPill: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Add friends from comments, activity, and live event interactions.")
                .font(.footnote)
                .foregroundStyle(.secondary.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thinMaterial)
                .opacity(0.85)
        )
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
    }

    private var manualAddSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manual add")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary.opacity(0.8))

            TextField("Paste friend ID (advanced)", text: $manualId)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.thinMaterial)
                        .opacity(0.85)
                )
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )

            Text("Usually you will not need this. If someone sent you a code or ID, paste it here.")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
