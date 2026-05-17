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
    @State private var postMessageIsSoftNotice = false
    @State private var reportingCommentID: UUID?
    @State private var showUnreportConfirmation = false
    @State private var unreportTargetCommentID: UUID?
    @State private var sendingFriendRequestUserId: UUID?
    @State private var commentsHasOlder = false
    @State private var commentsLoadingOlder = false
    @State private var isLoadingInitialComments = false
    @State private var showNativeAdsInFeed = false
    @State private var commentsChromeVisible = false
    @State private var fanUpdateCooldownUntil: Date?
    @State private var fanUpdateCooldownRemainingSeconds = 0
    @State private var lastSuccessfulFanUpdateKey: String?
    @State private var lastSuccessfulFanUpdateAt: Date?

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

    private var composerPostButtonDisabled: Bool {
        newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPostingComment
    }

    private var fanUpdateComposerHelperText: String? {
        if fanUpdateCooldownRemainingSeconds > 0 {
            return "Posting too fast — try again in \(fanUpdateCooldownRemainingSeconds)s"
        }
        return postMessage.isEmpty ? nil : postMessage
    }

    private var fanUpdateComposerHelperColor: Color {
        if fanUpdateCooldownRemainingSeconds > 0 || postMessageIsSoftNotice {
            return fanUpdatesIsDark ? Color.orange.opacity(0.82) : Color.orange.opacity(0.76)
        }
        return postMessageIsError ? Color.red : Color.green
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

    private var venueCommentsListItems: [VenueCommentsListItem] {
        guard showNativeAdsInFeed else {
            return comments.map { .comment($0) }
        }
        return VenueCommentsAdPlacement.listItems(for: comments)
    }

    private func venueCommentsAdLayoutWidth(for layoutWidth: CGFloat) -> CGFloat {
        max(1, layoutWidth)
    }

    var body: some View {
        GeometryReader { layoutGeo in
            venueCommentsRoot(layoutWidth: layoutGeo.size.width)
        }
    }

    private func venueCommentsRoot(layoutWidth: CGFloat) -> some View {
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

                        if isLoadingInitialComments && comments.isEmpty {
                            fanUpdatesLoadingPlaceholder
                                .transition(.opacity)
                        } else if comments.isEmpty {
                            Text("No updates yet. Be the first to share audio, crowd, or seating info.")
                                .font(.caption)
                                .foregroundStyle(secondaryLabelColor)
                                .transition(.opacity)
                        } else {
                            ForEach(venueCommentsListItems) { item in
                                venueCommentsListRow(item, layoutWidth: layoutWidth)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                    .animation(.easeOut(duration: 0.22), value: comments.count)
                    .animation(.easeOut(duration: 0.22), value: showNativeAdsInFeed)
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
                .progressiveAppear(isVisible: commentsChromeVisible, yOffset: 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(sheetRootBackground)
        .onAppear {
            withAnimation(.easeOut(duration: 0.22)) {
                commentsChromeVisible = true
            }
        }
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
            await loadCommentsAndRealtimeInSheet()
        }
        .onDisappear {
            Task { await viewModel.stopVenueEventCommentsRealtime(for: venueEventID) }
        }
        .onChange(of: comments.count) { _, _ in
            if showNativeAdsInFeed {
                discoverLogVenueCommentsAdPlacement()
            }
            Task {
                let emails = comments.compactMap { $0.user_email }
                await viewModel.loadUserProfilesForEmails(emails)
                await refreshCommentFriendshipIfNeeded()
            }
        }
        .onChange(of: showNativeAdsInFeed) { _, showAds in
            if showAds {
                discoverLogVenueCommentsAdPlacement()
            }
        }
    }

    private var fanUpdatesLoadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.82)
                    .tint(fanUpdatesIsDark ? primaryLabelColor : nil)
                Text("Loading fan updates…")
                    .font(.caption)
                    .foregroundStyle(secondaryLabelColor)
            }
            fanUpdatesSkeletonCard
            fanUpdatesSkeletonCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .progressiveAppear(isVisible: isLoadingInitialComments && comments.isEmpty, yOffset: 5)
    }

    private var fanUpdatesSkeletonCard: some View {
        FGSmoothPlaceholderBlock(height: 56, cornerRadius: 14, opacity: fanUpdatesIsDark ? 0.13 : 0.08)
            .background(cardSurfaceBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func loadCommentsAndRealtimeInSheet() async {
        showNativeAdsInFeed = false
        commentsLoadingOlder = false

        let hadCache = !(viewModel.venueEventComments[venueEventID] ?? []).isEmpty
        isLoadingInitialComments = !hadCache

        FanUpdatesTapPerf.logCommentLoadStarted(eventId: venueEventID)
        let loadStarted = CFAbsoluteTimeGetCurrent()

        if hadCache {
            Task {
                let hasMore = await viewModel.loadCommentsFirstPage(for: venueEventID, logFullSheetLoad: true)
                await MainActor.run {
                    commentsHasOlder = hasMore
                    withAnimation(.easeOut(duration: 0.22)) {
                        isLoadingInitialComments = false
                    }
                    FanUpdatesTapPerf.logCommentLoadCompleted(
                        ms: (CFAbsoluteTimeGetCurrent() - loadStarted) * 1000
                    )
                    scheduleNativeAdsAfterCommentsRender()
                }
                await loadCommentProfilesAndFriendshipChips()
            }
            await viewModel.startVenueEventCommentsRealtime(for: venueEventID)
        } else {
            commentsHasOlder = await viewModel.loadCommentsFirstPage(for: venueEventID, logFullSheetLoad: true)
            withAnimation(.easeOut(duration: 0.22)) {
                isLoadingInitialComments = false
            }
            FanUpdatesTapPerf.logCommentLoadCompleted(
                ms: (CFAbsoluteTimeGetCurrent() - loadStarted) * 1000
            )
            scheduleNativeAdsAfterCommentsRender()
            await viewModel.startVenueEventCommentsRealtime(for: venueEventID)
            await loadCommentProfilesAndFriendshipChips()
        }
    }

    private func scheduleNativeAdsAfterCommentsRender() {
        FanUpdatesTapPerf.logAdLoadStartedNonBlocking()
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.22)) {
                showNativeAdsInFeed = true
            }
            FanUpdatesTapPerf.logAdInsertedAfterComments()
        }
    }

    private func loadCommentProfilesAndFriendshipChips() async {
        let emails = comments.compactMap { $0.user_email }
        await viewModel.loadUserProfilesForEmails(emails)
        await refreshCommentFriendshipIfNeeded()
    }

    @ViewBuilder
    private func venueCommentsListRow(_ item: VenueCommentsListItem, layoutWidth: CGFloat) -> some View {
        switch item {
        case .comment(let comment):
            commentRow(comment)
        case .nativeAd(let slotIndex):
            CompactNativeAdCard(slotIndex: slotIndex, layoutWidth: venueCommentsAdLayoutWidth(for: layoutWidth))
        }
    }

    private func discoverLogVenueCommentsAdPlacement() {
#if DEBUG
        let count = comments.count
        print("[VenueCommentsAdDebug] enabled=true")
        print("[VenueCommentsAdDebug] commentCount=\(count)")
        print("[VenueCommentsAdDebug] insertedAfterIndexes=\(VenueCommentsAdPlacement.insertedAfterCommentPositions(commentCount: count))")
        print("[VenueCommentsAdDebug] nativeAdValidatorFix=true")
        print("[VenueCommentsAdDebug] minAssetSize=40")
        print("[VenueCommentsAdDebug] allAssetsInsideNativeAdView=true")
#endif
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
                                    submitFanUpdate(update, restoreTextOnFailure: false)
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
                            submitFanUpdate(textToSend, restoreTextOnFailure: true)
                        } label: {
                            composerPostButton
                        }
                        .disabled(composerPostButtonDisabled)
                        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.94, hapticOnPress: false))
                        .opacity(composerPostButtonDisabled ? 0.55 : 1.0)
                        .animation(.easeOut(duration: 0.16), value: composerPostButtonDisabled)
                    }

                    Text("\(newComment.count)/\(maxCommentLength)")
                        .font(.caption2)
                        .foregroundStyle(
                            newComment.count >= maxCommentLength
                                ? Color.red
                                : mutedLabelColor
                        )

                    if let helperText = fanUpdateComposerHelperText {
                        Text(helperText)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(fanUpdateComposerHelperColor)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.18), value: helperText)
                    }
                }
                .task(id: fanUpdateCooldownUntil) {
                    await runFanUpdateCooldownCountdown()
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

    private func submitFanUpdate(_ rawText: String, restoreTextOnFailure: Bool) {
        let cleanText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            if restoreTextOnFailure { newComment = rawText }
            return
        }

        if let blockMessage = clientSideFanUpdateBlockMessage(for: cleanText) {
            if restoreTextOnFailure { newComment = rawText }
            showSoftFanUpdateNotice(blockMessage)
            FGInteractionHaptics.selection()
            return
        }

        Task { @MainActor in
            guard !isPostingComment else {
                if restoreTextOnFailure { newComment = rawText }
                return
            }

            isPostingComment = true
            defer { isPostingComment = false }

            if let err = await viewModel.addComment(to: venueEventID, text: cleanText) {
                if restoreTextOnFailure { newComment = rawText }
                showFanUpdatePostMessage(err, isError: true, isSoftNotice: isSoftFanUpdateNotice(err))
            } else {
                registerSuccessfulFanUpdate(cleanText)
                postMessage = ""
                postMessageIsError = false
                postMessageIsSoftNotice = false
                FGInteractionHaptics.softImpact()
            }

            schedulePostMessageClear()
        }
    }

    private func clientSideFanUpdateBlockMessage(for cleanText: String) -> String? {
        if fanUpdateCooldownRemainingSeconds > 0 {
            return "Posting too fast — try again in \(fanUpdateCooldownRemainingSeconds)s"
        }

        guard RateLimitService.fanUpdateHasMinimumContentQuality(cleanText) else {
            return RateLimitService.fanUpdateMinimumQualityMessage
        }

        if let lastSuccessfulFanUpdateKey,
           let lastSuccessfulFanUpdateAt,
           lastSuccessfulFanUpdateKey == fanUpdateDuplicateKey(for: cleanText),
           Date().timeIntervalSince(lastSuccessfulFanUpdateAt) < RateLimitService.venueEventCommentDuplicateWindow {
            return "You already posted that update."
        }

        return nil
    }

    private func registerSuccessfulFanUpdate(_ cleanText: String) {
        let now = Date()
        lastSuccessfulFanUpdateKey = fanUpdateDuplicateKey(for: cleanText)
        lastSuccessfulFanUpdateAt = now
        fanUpdateCooldownUntil = now.addingTimeInterval(RateLimitService.venueEventCommentMinInterval)
        updateFanUpdateCooldownRemainingSeconds()
    }

    private func fanUpdateDuplicateKey(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = ModerationService.normalizeModerationText(trimmed)
        if !normalized.isEmpty {
            return normalized
        }
        return trimmed.filter { !$0.isWhitespace && !$0.isNewline }.lowercased()
    }

    private func showSoftFanUpdateNotice(_ message: String) {
        showFanUpdatePostMessage(message, isError: true, isSoftNotice: true)
        schedulePostMessageClear()
    }

    private func showFanUpdatePostMessage(_ message: String, isError: Bool, isSoftNotice: Bool) {
        postMessage = message
        postMessageIsError = isError
        postMessageIsSoftNotice = isSoftNotice
    }

    private func isSoftFanUpdateNotice(_ message: String) -> Bool {
        message == RateLimitService.slowDownMessage
            || message == RateLimitService.duplicateBlockedMessage
            || message == RateLimitService.fanUpdateMinimumQualityMessage
            || message.localizedCaseInsensitiveContains("too fast")
            || message.localizedCaseInsensitiveContains("duplicate")
    }

    private func schedulePostMessageClear() {
        let messageToClear = postMessage
        guard !messageToClear.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard postMessage == messageToClear else { return }
            postMessage = ""
            postMessageIsError = false
            postMessageIsSoftNotice = false
        }
    }

    @MainActor
    private func runFanUpdateCooldownCountdown() async {
        updateFanUpdateCooldownRemainingSeconds()

        while fanUpdateCooldownRemainingSeconds > 0 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            updateFanUpdateCooldownRemainingSeconds()
        }
    }

    private func updateFanUpdateCooldownRemainingSeconds(now: Date = Date()) {
        guard let fanUpdateCooldownUntil else {
            fanUpdateCooldownRemainingSeconds = 0
            return
        }

        let remaining = max(0, Int(ceil(fanUpdateCooldownUntil.timeIntervalSince(now))))
        fanUpdateCooldownRemainingSeconds = remaining
        if remaining == 0 {
            self.fanUpdateCooldownUntil = nil
        }
    }

    private var composerPostButton: some View {
        Image(systemName: "megaphone.fill")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        FGColor.accentBlue.opacity(fanUpdatesIsDark ? 0.88 : 0.82),
                                        FGColor.accentGreen.opacity(fanUpdatesIsDark ? 0.72 : 0.64)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
            }
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(fanUpdatesIsDark ? 0.22 : 0.34), lineWidth: 0.75)
            }
            .shadow(color: FGColor.accentBlue.opacity(composerPostButtonDisabled ? 0 : 0.22), radius: 8, y: 2)
            .contentShape(Circle())
            .accessibilityLabel("Post fan update")
            .onAppear {
#if DEBUG
                print("[FanUpdatesComposerDebug] iconRendered=megaphone.fill")
#endif
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

        let authorUserId = commentProfile?.id

        return Group {
            if let authorUserId, !isAuthoredByCurrentUser(email: email) {
                PublicProfileAvatarTap(userId: authorUserId, context: "venue_event_comment") {
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
            } else {
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
