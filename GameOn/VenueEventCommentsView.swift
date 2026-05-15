import SwiftUI

struct VenueEventCommentsView: View {
    @ObservedObject var viewModel: MapViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme

    let venueEventID: UUID
    

    @State private var newComment = ""
    private let maxCommentLength = 160
    @State private var reportMessage = ""
    @State private var isPostingComment = false
    @State private var postMessage = ""
    @State private var postMessageIsError = false
    @State private var reportingCommentID: UUID?
    @State private var showUnreportConfirmation = false
    @State private var unreportTargetCommentID: UUID?
    @State private var sendingFriendRequestUserId: UUID?
    @State private var commentsHasOlder = false
    @State private var commentsLoadingOlder = false

    private let quickUpdates = [
        "🎙️ Audio confirmed",
        "🔥 Packed",
        "🪑 Seats open",
        "📺 TVs visible",
        "🍺 Drink specials"
    ]

    private var fanUpdatesIsDark: Bool { colorScheme == .dark }

    /// Primary sheet body (matches ``VenueEventCommentsSheet`` root in dark).
    private var sheetRootBackground: Color {
        fanUpdatesIsDark ? .black : Color(uiColor: .systemGroupedBackground)
    }

    private var scrollSurfaceBackground: Color {
        fanUpdatesIsDark ? Color.white.opacity(0.04) : Color(uiColor: .secondarySystemGroupedBackground)
    }

    private var inputBarChromeBackground: Color {
        fanUpdatesIsDark ? Color.white.opacity(0.08) : Color.white.opacity(0.94)
    }

    private var cardSurfaceBackground: Color {
        fanUpdatesIsDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var cardBorderColor: Color {
        fanUpdatesIsDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    private var quickChipFill: Color {
        fanUpdatesIsDark ? Color.white.opacity(0.08) : Color.gray.opacity(0.14)
    }

    private var quickChipStroke: Color {
        fanUpdatesIsDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
    }

    private var primaryLabelColor: Color {
        fanUpdatesIsDark ? .white : .primary
    }

    private var secondaryLabelColor: Color {
        fanUpdatesIsDark ? Color.white.opacity(0.7) : Color.primary.opacity(0.55)
    }

    private var mutedLabelColor: Color {
        fanUpdatesIsDark ? Color.white.opacity(0.45) : Color.primary.opacity(0.45)
    }

    private var textFieldChromeBackground: Color {
        fanUpdatesIsDark ? Color.white.opacity(0.12) : Color(uiColor: .tertiarySystemFill)
    }

    private var sendAccentColor: Color {
        fanUpdatesIsDark ? Color(red: 0.45, green: 0.75, blue: 1.0) : Color.accentColor
    }
    
    var comments: [VenueEventCommentRow] {
        (viewModel.venueEventComments[venueEventID] ?? [])
            .sorted {
                let a = $0.created_at ?? ""
                let b = $1.created_at ?? ""
                if a != b { return a < b }
                return ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if commentsHasOlder || commentsLoadingOlder {
                            HStack(spacing: 10) {
                                if commentsLoadingOlder {
                                    Group {
                                        if fanUpdatesIsDark {
                                            ProgressView()
                                                .scaleEffect(0.85)
                                                .tint(primaryLabelColor)
                                        } else {
                                            ProgressView()
                                                .scaleEffect(0.85)
                                        }
                                    }
                                }
                                if commentsHasOlder {
                                    Button {
                                        Task { await loadOlderCommentsTapped() }
                                    } label: {
                                        Text("Load older updates")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(secondaryLabelColor)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(commentsLoadingOlder)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 4)
                        }

                        if !viewModel.isAuthenticatedForSocialFeatures, !comments.isEmpty {
                            Text("Sign in to add friends and see friendship status on updates.")
                                .font(.caption2)
                                .foregroundStyle(secondaryLabelColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if comments.isEmpty {
                            Text("No updates yet. Be the first to share audio, crowd, or seating info.")
                                .font(.caption)
                                .foregroundStyle(secondaryLabelColor)
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

                        Color.clear
                            .frame(height: 1)
                            .id("comments-bottom-anchor")
                    }
                    .padding(12)
                }
                .background(scrollSurfaceBackground)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(cardBorderColor, lineWidth: fanUpdatesIsDark ? 1 : 0.5)
                )
                .onChange(of: comments.last?.id) { _, target in
                    guard target != nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("comments-bottom-anchor", anchor: .bottom)
                    }
                }
                .onAppear {
                    guard !comments.isEmpty else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo("comments-bottom-anchor", anchor: .bottom)
                    }
                }
            }

            inputBar
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(inputBarChromeBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(cardBorderColor, lineWidth: fanUpdatesIsDark ? 1 : 0.5)
                )
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(sheetRootBackground)
        .onChange(of: showUnreportConfirmation) { _, open in
            if !open { unreportTargetCommentID = nil }
        }
        .confirmationDialog(
            "Remove your report?",
            isPresented: $showUnreportConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Report", role: .destructive) {
                guard let commentID = unreportTargetCommentID,
                      let comment = comments.first(where: { $0.id == commentID }) else {
                    unreportTargetCommentID = nil
                    return
                }
                Task {
                    guard reportingCommentID == nil else { return }
                    reportingCommentID = commentID
                    defer {
                        reportingCommentID = nil
                        unreportTargetCommentID = nil
                    }

                    let ok = await viewModel.unreportComment(comment)

                    await MainActor.run {
                        if ok {
                            reportMessage = "Report removed"
                        }
                    }

                    if ok {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            reportMessage = ""
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                unreportTargetCommentID = nil
            }
        }
        .task(id: venueEventID) {
            commentsLoadingOlder = false
            commentsHasOlder = await viewModel.loadCommentsFirstPage(for: venueEventID)
            await viewModel.startVenueEventCommentsRealtime(for: venueEventID)

            let emails = comments.compactMap { $0.user_email }
            await viewModel.loadUserProfilesForEmails(emails)
            await refreshCommentFriendshipIfNeeded()
        }
        .onDisappear {
            Task { await viewModel.stopVenueEventCommentsRealtime(for: venueEventID) }
        }
        .onChange(of: comments.count) { _, _ in
            Task {
                let emails = comments.compactMap { $0.user_email }
                await viewModel.loadUserProfilesForEmails(emails)
                await refreshCommentFriendshipIfNeeded()
            }
        }
    }

    private func parseCommentCreatedAt(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: raw) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: raw)
    }

    private func loadOlderCommentsTapped() async {
        guard let oldest = comments.first,
              let oid = oldest.id,
              let raw = oldest.created_at,
              let od = parseCommentCreatedAt(raw) else {
            commentsHasOlder = false
            return
        }
        commentsLoadingOlder = true
        defer { commentsLoadingOlder = false }
        let more = await viewModel.loadOlderVenueComments(
            for: venueEventID,
            beforeCreatedAt: od,
            beforeId: oid
        )
        commentsHasOlder = more
    }

    /// One friendship refresh for all visible comment authors (batched in ``ChatViewModel``).
    private func refreshCommentFriendshipIfNeeded() async {
        guard viewModel.isAuthenticatedForSocialFeatures else { return }
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
        let lower = trimmed.lowercased()
        if let exact = viewModel.userProfilesByEmail[trimmed] { return exact }
        if let byLowerKey = viewModel.userProfilesByEmail[lower] { return byLowerKey }
        return viewModel.userProfilesByEmail.first(where: { pair in
            pair.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lower
        })?.value
    }

    private func isAuthoredByCurrentUser(email: String) -> Bool {
        let a = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = viewModel.authenticatedSocialEmailForUI.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
                        .foregroundStyle(primaryLabelColor)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text("• \(timeAgo(from: comment.created_at))")
                        .font(.caption)
                        .foregroundStyle(secondaryLabelColor)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    // Trailing: report (others) → Add Friend / status (others) → delete (self, rightmost).
                    HStack(spacing: 8) {
                        if let email = comment.user_email,
                           let commentID = comment.serverCommentID,
                           !isAuthoredByCurrentUser(email: email),
                           !comment.isPendingSend,
                           !comment.isFailedSend,
                           viewModel.isAuthenticatedForSocialFeatures {
                            let alreadyReported = viewModel.hasCurrentUserReportedComment(commentID: commentID)
                            Button {
                                if alreadyReported {
                                    unreportTargetCommentID = commentID
                                    showUnreportConfirmation = true
                                    return
                                }
                                Task {
                                    guard reportingCommentID == nil else { return }
                                    reportingCommentID = commentID
                                    defer { reportingCommentID = nil }

                                    let ok = await viewModel.reportComment(comment)

                                    await MainActor.run {
                                        if ok {
                                            reportMessage = "Update reported"
                                        }
                                    }

                                    if ok {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            reportMessage = ""
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: alreadyReported ? "flag.fill" : "flag")
                                    .font(.caption)
                                    .foregroundStyle(alreadyReported ? Color.red : Color.orange)
                            }
                            .buttonStyle(.plain)
                            .disabled(reportingCommentID != nil)
                            .accessibilityLabel(alreadyReported ? "Remove your report" : "Report update")
                        }

                        friendshipChip(for: comment)

                        if comment.isFailedSend,
                           let email = comment.user_email,
                           isAuthoredByCurrentUser(email: email) {
                            Button {
                                Task {
                                    if let err = await viewModel.retryCommentSend(comment) {
                                        await MainActor.run {
                                            postMessage = err
                                            postMessageIsError = true
                                        }
                                    }
                                }
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Retry sending update")
                        } else if let email = comment.user_email,
                                  isAuthoredByCurrentUser(email: email),
                                  !comment.isPendingSend {
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
                    .foregroundStyle(primaryLabelColor)
                    .fixedSize(horizontal: false, vertical: true)

                if comment.isPendingSend {
                    Label("Sending...", systemImage: "clock")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(secondaryLabelColor)
                } else if comment.isFailedSend {
                    Label("Failed to send", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
        .background(cardSurfaceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(cardBorderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func friendshipChip(for comment: VenueEventCommentRow) -> some View {
        if viewModel.isAuthenticatedForSocialFeatures,
           viewModel.canUseFanSocialFeatures,
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
            if viewModel.isAuthenticatedForSocialFeatures, viewModel.canUseFanSocialFeatures {
                VStack(alignment: .trailing, spacing: 8) {

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(quickUpdates, id: \.self) { update in
                                Button {
                                    Task {
                                        guard !isPostingComment else { return }
                                        isPostingComment = true
                                        defer { isPostingComment = false }

                                        if let err = await viewModel.addComment(to: venueEventID, text: update) {
                                            await MainActor.run {
                                                postMessage = err
                                                postMessageIsError = true
                                            }
                                        } else {
                                            await MainActor.run {
                                                postMessage = ""
                                            }
                                        }

                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            postMessage = ""
                                        }
                                    }
                                } label: {
                                    Text(update)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(primaryLabelColor)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(quickChipFill)
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(quickChipStroke, lineWidth: 1)
                                        )
                                }
                                .disabled(isPostingComment)
                                .opacity(isPostingComment ? 0.5 : 1.0)
                            }
                        }
                    }

                    HStack(alignment: .center, spacing: 10) {
                        TextField("Add update: Audio confirmed, packed, seats open...", text: $newComment)
                            .textFieldStyle(.plain)
                            .foregroundStyle(primaryLabelColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(textFieldChromeBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

                                if let err = await viewModel.addComment(to: venueEventID, text: textToSend) {
                                    await MainActor.run {
                                        newComment = textToSend
                                        postMessage = err
                                        postMessageIsError = true
                                    }
                                } else {
                                    await MainActor.run {
                                        postMessage = ""
                                    }
                                }

                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    postMessage = ""
                                }
                            }
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .foregroundStyle(sendAccentColor)
                        }
                        .disabled(
                            newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            isPostingComment
                        )
                        .opacity(isPostingComment ? 0.5 : 1.0)
                    }

                    Text("\(newComment.count)/\(maxCommentLength)")
                        .font(.caption2)
                        .foregroundStyle(
                            newComment.count >= maxCommentLength
                                ? Color.red
                                : mutedLabelColor
                        )

                    if !postMessage.isEmpty {
                        Text(postMessage)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(postMessageIsError ? Color.red : Color.green)
                    }
                }
            } else if viewModel.isAuthenticatedForSocialFeatures, !viewModel.canUseFanSocialFeatures {
                Text(BusinessFanGateCopy.commentsViewOnlyForBusiness)
                    .font(.caption)
                    .foregroundStyle(mutedLabelColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Login as a user or venue owner to add an update.")
                    .font(.caption)
                    .foregroundStyle(mutedLabelColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    
    private func commentAvatar(for comment: VenueEventCommentRow) -> some View {
        let email = comment.user_email ?? ""
        let currentBusinessAccount = isAuthoredByCurrentUser(email: email) && viewModel.isVenueOwnerLoggedIn && !viewModel.isLoggedIn
        let commentProfile = userProfile(forAuthorEmail: email)
        let isBusinessComment = currentBusinessAccount || commentProfile?.isBusinessIdentity == true

        let avatarURL: String = {
            if isAuthoredByCurrentUser(email: email) {
                if currentBusinessAccount {
                    return ""
                }
                return ImageDisplayURL.forListDisplay(
                    thumbnail: viewModel.currentUserAvatarThumbnailURL,
                    full: viewModel.currentUserAvatarURL,
                    refreshToken: viewModel.currentUserAvatarDisplayRefreshToken
                ) ?? ""
            }

            return ImageDisplayURL.forList(thumbnail: commentProfile?.avatar_thumbnail_url, full: commentProfile?.avatar_url) ?? ""
        }()

        let name = displayName(for: comment)

        return Group {
            SocialAvatarRenderer.socialAvatarView(
                displayName: name,
                email: email,
                avatarURL: avatarURL,
                avatarThumbnailURL: nil,
                isBusinessIdentity: isBusinessComment,
                size: 38,
                fallbackStyle: .blueInitials
            )
        }
        .frame(width: 38, height: 38)
        .clipShape(Circle())
    }
    
    private func displayName(for comment: VenueEventCommentRow) -> String {
        guard let email = comment.user_email else {
            return "Fan update"
        }

        if isAuthoredByCurrentUser(email: email) {
            if viewModel.isVenueOwnerLoggedIn && !viewModel.isLoggedIn {
                let businessName = viewModel.authenticatedBusinessDisplayNameForSocialFeatures
                return businessName.isEmpty ? "Business update" : businessName
            }
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
