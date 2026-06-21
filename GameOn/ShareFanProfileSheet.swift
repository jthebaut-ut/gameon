import SwiftUI

struct ShareFanProfileSheet: View {
    let profile: PublicUserProfileData
    @ObservedObject var mapViewModel: MapViewModel

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var selectedFriendIds: Set<UUID> = []
    @State private var searchText = ""
    @State private var isSending = false
    @State private var errorText: String?

    private var sharePayload: FanProfileSharePayload? {
        FanProfileShareMessage.payload(
            from: profile,
            sharedByDisplayName: mapViewModel.currentUserDisplayName,
            languageCode: appLanguageRaw
        )
    }

    private var eligibleRecipients: [ChatViewModel.FriendDisplay] {
        let me = mapViewModel.currentUserAuthId
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return chatViewModel.friends
            .filter { friend in
                guard friend.id != me else { return false }
                guard !chatViewModel.isEitherDirectionBlocked(with: friend.id) else { return false }
                guard query.isEmpty else {
                    let name = friend.preview.displayName.lowercased()
                    let handle = friend.preview.username?.lowercased() ?? ""
                    return name.contains(query) || handle.contains(query)
                }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.isConversationBacked != rhs.isConversationBacked {
                    return lhs.isConversationBacked && !rhs.isConversationBacked
                }
                if let l = lhs.lastMessageAt, let r = rhs.lastMessageAt, l != r {
                    return l > r
                }
                return lhs.preview.displayName.localizedCaseInsensitiveCompare(rhs.preview.displayName) == .orderedAscending
            }
    }

    private var canSend: Bool {
        !selectedFriendIds.isEmpty && !isSending && sharePayload != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section {
                        TextField("Search friends", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section {
                        if eligibleRecipients.isEmpty {
                            Text("No chats available yet")
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        } else {
                            ForEach(eligibleRecipients) { friend in
                                shareRecipientRow(friend)
                            }
                        }
                    } header: {
                        Text("Chats & friends")
                    } footer: {
                        Text("\(selectedFriendIds.count) selected")
                    }
                }
                .scrollContentBackground(.hidden)

                if let errorText, !errorText.isEmpty {
                    Text(errorText)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, FGSpacing.lg)
                        .padding(.vertical, FGSpacing.sm)
                }
            }
            .fanGeoScreenBackground()
            .navigationTitle("Share Fan Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await sendShare() }
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Text("Send")
                        }
                    }
                    .disabled(!canSend)
                }
            }
            .task {
                await chatViewModel.loadIfNeeded()
            }
        }
    }

    private func shareRecipientRow(_ friend: ChatViewModel.FriendDisplay) -> some View {
        let isSelected = selectedFriendIds.contains(friend.id)
        return Button {
            toggleSelection(friend.id)
        } label: {
            HStack(spacing: 12) {
                ProfileAvatarView(preview: friend.preview, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.preview.displayName)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    if let handle = friend.preview.username?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty {
                        Text("@\(handle)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    } else if let subtitle = friend.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.secondaryText(colorScheme).opacity(0.55))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleSelection(_ friendId: UUID) {
        if selectedFriendIds.contains(friendId) {
            selectedFriendIds.remove(friendId)
        } else {
            selectedFriendIds.insert(friendId)
        }
    }

    private func sendShare() async {
        guard !isSending else { return }
        guard let payload = sharePayload else {
            await MainActor.run { errorText = "This profile can't be shared right now." }
            return
        }

        let body = FanProfileShareMessage.encodeBody(payload: payload)
        guard body.count <= 1000 else {
            await MainActor.run { errorText = "Profile share payload is too large." }
            return
        }

        print("[ProfileShareDebug] sourceDisplayName=\(profile.displayName)")
        print("[ProfileShareDebug] sourceHandle=\(FanProfileShareMessage.sanitizedPublicHandle(profile.publicHandleLine) ?? "nil")")
        let avatarURLs = FanProfileShareMessage.resolvedAvatarURLs(
            thumbnail: profile.avatarThumbnailURL,
            full: profile.avatarURL
        )
        print("[ProfileShareDebug] sourceAvatarURL=\(avatarURLs.thumbnail ?? avatarURLs.full ?? "nil")")

        await MainActor.run {
            isSending = true
            errorText = nil
        }
        defer {
            Task { @MainActor in isSending = false }
        }

        if let err = await chatViewModel.shareFanProfileMessage(
            body: body,
            toRecipientUserIds: Array(selectedFriendIds)
        ) {
            await MainActor.run { errorText = err }
            return
        }

        await MainActor.run {
            mapViewModel.showSocialActionToast("Profile shared.", isError: false)
            dismiss()
        }
    }
}
