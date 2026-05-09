import SwiftUI

struct VenueEventCommentsView: View {
    @ObservedObject var viewModel: MapViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel

    let venueEventID: UUID
    

    @State private var newComment = ""
    private let maxCommentLength = 160
    @State private var reportMessage = ""
    @State private var isPostingComment = false
    @State private var postMessage = ""
    @State private var isReportingComment = false
    @State private var sendingFriendRequestUserId: UUID?

    private let quickUpdates = [
        "🎙️ Audio confirmed",
        "🔥 Packed",
        "🪑 Seats open",
        "📺 TVs visible",
        "🍺 Drink specials"
    ]
    
    var comments: [VenueEventCommentRow] {
        (viewModel.venueEventComments[venueEventID] ?? [])
            .sorted {
                ($0.created_at ?? "") > ($1.created_at ?? "")
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if comments.isEmpty {
                            Text("No updates yet. Be the first to share audio, crowd, or seating info.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(comments) { comment in
                                commentRow(comment)
                            }
                        }

                        if !reportMessage.isEmpty {
                            Text(reportMessage)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                        }

    
                    }
                }
            }

            inputBar
        }
        .padding()
        .background(Color.white.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task(id: venueEventID) {
            await viewModel.loadComments(for: venueEventID)

            let emails = comments.compactMap { $0.user_email }
            await viewModel.loadUserProfilesForEmails(emails)
            await refreshCommentFriendshipIfNeeded()
        }
        .onChange(of: comments.count) { _, _ in
            Task {
                let emails = comments.compactMap { $0.user_email }
                await viewModel.loadUserProfilesForEmails(emails)
                await refreshCommentFriendshipIfNeeded()
            }
        }
    }

    /// One friendship refresh for all visible comment authors (batched in ``ChatViewModel``).
    private func refreshCommentFriendshipIfNeeded() async {
        guard viewModel.isLoggedIn else { return }
        let ids = commentAuthorUserIdsForFriendship
        await chatViewModel.refreshFriendshipStateForCommentAuthors(userIds: ids)
    }

    private var commentAuthorUserIdsForFriendship: [UUID] {
        Array(
            Set(
                comments.compactMap { comment -> UUID? in
                    guard let email = comment.user_email else { return nil }
                    guard !isAuthoredByCurrentUser(email: email) else { return nil }
                    return userProfile(forAuthorEmail: email)?.id
                }.compactMap { $0 }
            )
        )
    }

    /// `user_profiles` rows are keyed in ``MapViewModel/userProfilesByEmail`` by whatever casing Postgres returns; comment rows may use a different string. Match case-insensitively so the friend chip can resolve `id`.
    private func userProfile(forAuthorEmail raw: String) -> UserProfileRow? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let exact = viewModel.userProfilesByEmail[trimmed] { return exact }
        let lower = trimmed.lowercased()
        if let byLowerKey = viewModel.userProfilesByEmail[lower] { return byLowerKey }
        return viewModel.userProfilesByEmail.first(where: { pair in
            pair.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lower
        })?.value
    }

    private func isAuthoredByCurrentUser(email: String) -> Bool {
        let a = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !a.isEmpty && !b.isEmpty && a == b
    }
    
    private func commentRow(_ comment: VenueEventCommentRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            commentAvatar(for: comment)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(displayName(for: comment))
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text("• \(timeAgo(from: comment.created_at))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    // Report / friend chip / delete — keep intrinsic width so the Add Friend chip is never squeezed to zero.
                    HStack(spacing: 8) {
                        if let email = comment.user_email,
                           !isAuthoredByCurrentUser(email: email),
                           viewModel.isLoggedIn {
                            Button {
                                Task {
                                    guard !isReportingComment else { return }
                                    isReportingComment = true
                                    defer { isReportingComment = false }

                                    await viewModel.reportComment(comment)

                                    await MainActor.run {
                                        reportMessage = "Update reported"
                                    }

                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        reportMessage = ""
                                    }
                                }
                            } label: {
                                Image(systemName: "flag")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            .accessibilityLabel("Report update")
                        }

                        friendshipChip(for: comment)

                        if let email = comment.user_email, isAuthoredByCurrentUser(email: email) {
                            Button {
                                Task {
                                    await viewModel.deleteComment(comment)

                                    let emails = comments.compactMap { $0.user_email }
                                    await viewModel.loadUserProfilesForEmails(emails)
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .accessibilityLabel("Delete update")
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                Text(comment.comment ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func friendshipChip(for comment: VenueEventCommentRow) -> some View {
        if viewModel.isLoggedIn,
           let email = comment.user_email,
           !isAuthoredByCurrentUser(email: email),
           let profile = userProfile(forAuthorEmail: email),
           let targetId = profile.id,
           !(chatViewModel.currentUserAuthId.map { $0 == targetId } ?? false) {
            CommentFriendshipChip(
                kind: chatViewModel.chipKind(forOtherUserId: targetId),
                isSending: sendingFriendRequestUserId == targetId
            ) {
                Task {
                    sendingFriendRequestUserId = targetId
                    defer { sendingFriendRequestUserId = nil }
                    await chatViewModel.sendFriendRequestFromComments(to: targetId)
                }
            }
        }
    }

    private var inputBar: some View {
        Group {
            if viewModel.isLoggedIn || viewModel.isVenueOwnerLoggedIn {
                VStack(alignment: .trailing, spacing: 4) {
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(quickUpdates, id: \.self) { update in
                                Button {
                                    Task {
                                        guard !isPostingComment else { return }
                                        isPostingComment = true
                                        defer { isPostingComment = false }

                                        await viewModel.addComment(to: venueEventID, text: update)

                                        let emails = comments.compactMap { $0.user_email }
                                        await viewModel.loadUserProfilesForEmails(emails)
                                        
                                        await MainActor.run {
                                            postMessage = "Update posted"
                                        }

                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            postMessage = ""
                                        }
                                    }
                                } label: {
                                    Text(update)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(Color.gray.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                                .disabled(isPostingComment)
                                .opacity(isPostingComment ? 0.5 : 1.0)
                            }
                        }
                    }
                    
                    HStack {
                        TextField("Add update: Audio confirmed, packed, seats open...", text: $newComment)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: newComment) { _, value in
                                if value.count > maxCommentLength {
                                    newComment = String(value.prefix(maxCommentLength))
                                }
                            }

                        Button {
                            let textToSend = newComment
                            newComment = ""

                            Task {
                                guard !isPostingComment else { return }
                                isPostingComment = true
                                defer { isPostingComment = false }

                                await viewModel.addComment(to: venueEventID, text: textToSend)

                                let emails = comments.compactMap { $0.user_email }
                                await viewModel.loadUserProfilesForEmails(emails)
                                
                                await MainActor.run {
                                    postMessage = "Update posted"
                                }

                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    postMessage = ""
                                }
                            }
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .foregroundStyle(.blue)
                        }
                        .disabled(
                            newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            isPostingComment
                        )
                        .opacity(isPostingComment ? 0.5 : 1.0)
                    }

                    Text("\(newComment.count)/\(maxCommentLength)")
                        .font(.caption2)
                        .foregroundStyle(newComment.count >= maxCommentLength ? .red : .secondary)
                    
                    if isPostingComment {
                        Text("Posting update...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !postMessage.isEmpty {
                        Text(postMessage)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                    }
                }
            } else {
                Text("Login as a user or venue owner to add an update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func commentAvatar(for comment: VenueEventCommentRow) -> some View {
        let email = comment.user_email ?? ""

        let avatarURL: String = {
            if isAuthoredByCurrentUser(email: email) {
                return viewModel.currentUserAvatarURL
            }

            return userProfile(forAuthorEmail: email)?.avatar_url ?? ""
        }()

        let name = displayName(for: comment)

        return Group {
            if let url = URL(string: avatarURL), !avatarURL.isEmpty {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Circle()
                        .fill(Color.gray.opacity(0.20))
                }
            } else {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .overlay {
                        Text(String(name.prefix(1)).uppercased())
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.blue)
                    }
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(Circle())
    }
    
    private func displayName(for comment: VenueEventCommentRow) -> String {
        guard let email = comment.user_email else {
            return "Fan update"
        }

        if isAuthoredByCurrentUser(email: email) {
            return viewModel.currentUserDisplayName.isEmpty ? "You" : viewModel.currentUserDisplayName
        }

        if let profile = userProfile(forAuthorEmail: email),
           let name = profile.display_name,
           !name.isEmpty {
            return name
        }

        return "Fan update"
    }
    
    private func timeAgo(from rawDate: String?) -> String {
        guard let rawDate else { return "just now" }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]

        guard let date = formatter.date(from: rawDate) else {
            return "just now"
        }

        let seconds = Int(Date().timeIntervalSince(date))

        if seconds < 60 {
            return "just now"
        } else if seconds < 3600 {
            return "\(seconds / 60)m ago"
        } else if seconds < 86400 {
            return "\(seconds / 3600)h ago"
        } else {
            return "\(seconds / 86400)d ago"
        }
    }
    
}
