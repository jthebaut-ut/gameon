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
                    List {
                        if !viewModel.friends.isEmpty {
                            Section("Friends") {
                                ForEach(viewModel.friends) { item in
                                    NavigationLink {
                                        DirectChatView(friend: item.preview)
                                    } label: {
                                        friendRow(item)
                                    }
                                }
                            }
                        }

                        if !viewModel.incomingRequests.isEmpty {
                            Section("Requests") {
                                ForEach(viewModel.incomingRequests) { item in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 10) {
                                            ProfileAvatarView(preview: item.requester, size: 40)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.requester.displayName)
                                                    .font(.subheadline.weight(.semibold))
                                                Text("Wants to connect")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        HStack(spacing: 10) {
                                            Button("Accept") {
                                                Task { await viewModel.accept(item) }
                                            }
                                            .buttonStyle(.borderedProminent)

                                            Button("Decline") {
                                                Task { await viewModel.reject(item) }
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }

                        if !viewModel.outgoingRequests.isEmpty {
                            Section("Sent") {
                                ForEach(viewModel.outgoingRequests) { item in
                                    HStack(spacing: 10) {
                                        ProfileAvatarView(preview: item.addressee, size: 36)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.addressee.displayName)
                                                .font(.subheadline.weight(.semibold))
                                            Text("Pending")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Cancel") {
                                            Task { await viewModel.cancel(item) }
                                        }
                                        .font(.caption.weight(.semibold))
                                    }
                                }
                            }
                        }

                        if viewModel.friends.isEmpty && viewModel.incomingRequests.isEmpty && viewModel.outgoingRequests.isEmpty {
                            ContentUnavailableView(
                                "No conversations yet",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("Accept a friend request or start chatting from a venue.")
                            )
                        }
                    }
                    .refreshable {
                        await viewModel.refresh()
                    }
                }
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.large)
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
        }
        .padding(.vertical, 2)
    }
}
