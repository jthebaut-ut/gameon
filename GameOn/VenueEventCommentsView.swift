import SwiftUI

struct VenueEventCommentsView: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var fanUpdatesStore: FanUpdatesRealtimeStore
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
    @State private var fanUpdateBurstSentAt: [Date] = []
    @State private var isManuallyRefreshingComments = false
    @State private var isAutoRefreshingComments = false
    @State private var isUserRefreshingComments = false
    @State private var isNearCommentsBottom = true
    @State private var hasUnseenNewComments = false
    @State private var lastCommentId: String?

    private let commentsBottomAnchorID = "comments-bottom-anchor"
    private let commentsScrollCoordinateSpaceName = "fan-updates-comments-scroll"
    private let commentsNearBottomThreshold: CGFloat = 72

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
            return RateLimitService.fanUpdateSlowDownMessage
        }
        if !postMessage.isEmpty {
            return postMessage
        }
        return nil
    }

    private var fanUpdateComposerHelperColor: Color {
        if fanUpdateCooldownRemainingSeconds > 0 || postMessageIsSoftNotice {
            return mutedLabelColor
        }
        return postMessageIsError ? Color.red : Color.green
    }
    
    var comments: [VenueEventCommentRow] {
        (fanUpdatesStore.venueEventComments[venueEventID] ?? [])
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

    private var latestCommentId: String? {
        comments.last.map { commentScrollID(for: $0) }
    }

    private var latestComment: VenueEventCommentRow? {
        comments.last
    }

    private var showNewUpdatesJumpButton: Bool {
        hasUnseenNewComments && !isNearCommentsBottom && latestCommentId != nil
    }

    private var fanUpdatesRefreshInFlight: Bool {
        isManuallyRefreshingComments || isAutoRefreshingComments || isUserRefreshingComments
    }

    private var fanUpdatesInteractiveRefreshInFlight: Bool {
        isManuallyRefreshingComments || isUserRefreshingComments
    }

    private var shouldShowFanUpdatesRefreshSpinner: Bool {
        isUserRefreshingComments
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
                GeometryReader { scrollGeo in
                    ZStack(alignment: .bottom) {
                        commentsScrollContent(layoutWidth: layoutWidth)
                            .coordinateSpace(name: commentsScrollCoordinateSpaceName)
                            .onPreferenceChange(FanUpdatesCommentsBottomPreferenceKey.self) { bottomMaxY in
                                updateCommentsNearBottom(
                                    bottomMaxY: bottomMaxY,
                                    viewportHeight: scrollGeo.size.height
                                )
                            }

                        if showNewUpdatesJumpButton {
                            newUpdatesJumpButton {
                                guard let target = latestCommentId else { return }
                                hasUnseenNewComments = false
                                scrollToComment(target, proxy: proxy, animated: true)
                            }
                            .padding(.bottom, 12)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                }
                .background(scrollSurfaceBackground)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(cardBorderColor, lineWidth: fanUpdatesIsDark ? 1 : 0.5)
                )
                .onChange(of: latestCommentId) { oldValue, newValue in
                    handleLatestCommentChanged(from: oldValue, to: newValue, proxy: proxy)
                }
                .onChange(of: showNativeAdsInFeed) { _, showAds in
                    guard showAds, let target = latestCommentId, isNearCommentsBottom || !hasUnseenNewComments else { return }
                    scrollToComment(target, proxy: proxy, animated: false)
                }
                .onAppear {
                    guard let target = latestCommentId else { return }
                    lastCommentId = target
                    hasUnseenNewComments = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        scrollToComment(target, proxy: proxy, animated: false)
                    }
                }
            }

            fanUpdatesBottomRefreshSpinner

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
            #if DEBUG
            print("[FanUpdatesStoreMigrationDebug] VenueEventCommentsViewReadsStore=true")
            #endif
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
        .task(id: venueEventID) {
            await runFanUpdatesAutoRefreshLoop()
        }
        .onDisappear {
            viewModel.cancelFanChatReceiverRefreshBurst(for: venueEventID)
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

    private func commentsScrollContent(layoutWidth: CGFloat) -> some View {
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

                GeometryReader { bottomGeo in
                    Color.clear.preference(
                        key: FanUpdatesCommentsBottomPreferenceKey.self,
                        value: bottomGeo.frame(in: .named(commentsScrollCoordinateSpaceName)).maxY
                    )
                }
                .frame(height: 1)
                .id(commentsBottomAnchorID)
            }
            .padding(12)
            .animation(.easeOut(duration: 0.22), value: comments.count)
            .animation(.easeOut(duration: 0.22), value: showNativeAdsInFeed)
        }
    }

    private func newUpdatesJumpButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("New updates", systemImage: "arrow.down.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(primaryLabelColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(cardBorderColor, lineWidth: fanUpdatesIsDark ? 1 : 0.5)
                )
                .shadow(color: Color.black.opacity(fanUpdatesIsDark ? 0.22 : 0.12), radius: 10, y: 3)
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.96, hapticOnPress: false))
        .accessibilityLabel("Jump to new fan updates")
    }

    private func commentScrollID(for comment: VenueEventCommentRow) -> String {
        if let id = comment.id {
            return "comment-\(id.uuidString)"
        }

        let stamp = comment.created_at ?? ""
        let author = comment.user_email ?? ""
        let body = comment.comment ?? ""
        return "comment-pending-\(stamp)-\(author)-\(body)"
    }

    private func updateCommentsNearBottom(bottomMaxY: CGFloat, viewportHeight: CGFloat) {
        let nearBottom = bottomMaxY <= viewportHeight + commentsNearBottomThreshold
        guard nearBottom != isNearCommentsBottom else { return }
        isNearCommentsBottom = nearBottom
        if nearBottom {
            hasUnseenNewComments = false
        }
    }

    private func handleLatestCommentChanged(from oldValue: String?, to newValue: String?, proxy: ScrollViewProxy) {
        guard let target = newValue else {
            lastCommentId = nil
            hasUnseenNewComments = false
            return
        }

        let isInitialCommentLoad = oldValue == nil || lastCommentId == nil
        let shouldFollowCurrentUserPost = latestComment.map(isCurrentUserVisiblePost) == true
        lastCommentId = target

        if isInitialCommentLoad || isNearCommentsBottom || shouldFollowCurrentUserPost {
            hasUnseenNewComments = false
            scrollToComment(target, proxy: proxy, animated: !isInitialCommentLoad)
        } else {
            hasUnseenNewComments = true
        }
    }

    private func isCurrentUserVisiblePost(_ comment: VenueEventCommentRow) -> Bool {
        guard let email = comment.user_email else { return false }
        return isAuthoredByCurrentUser(email: email)
    }

    private func scrollToComment(_ target: String, proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let scroll = {
                proxy.scrollTo(target, anchor: .bottom)
            }

            if animated {
                withAnimation(.easeOut(duration: 0.22)) {
                    scroll()
                }
            } else {
                scroll()
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

    @ViewBuilder
    private var fanUpdatesBottomRefreshSpinner: some View {
        if shouldShowFanUpdatesRefreshSpinner {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.82)
                    .tint(fanUpdatesIsDark ? primaryLabelColor : nil)

                Text("Refreshing updates")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(secondaryLabelColor)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Refreshing fan updates")
        }
    }

    private var fanUpdatesSkeletonCard: some View {
        FGSmoothPlaceholderBlock(height: 56, cornerRadius: 14, opacity: fanUpdatesIsDark ? 0.13 : 0.08)
            .background(cardSurfaceBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func loadCommentsAndRealtimeInSheet() async {
        showNativeAdsInFeed = false
        commentsLoadingOlder = false
        lastCommentId = latestCommentId
        hasUnseenNewComments = false
        isNearCommentsBottom = true

        let hadCache = !(fanUpdatesStore.venueEventComments[venueEventID] ?? []).isEmpty
        isLoadingInitialComments = !hadCache

        FanUpdatesTapPerf.logCommentLoadStarted(eventId: venueEventID)
        let loadStarted = CFAbsoluteTimeGetCurrent()

        #if DEBUG
        print("[FanChatReadyDebug] sheetOpen eventId=\(venueEventID.uuidString.lowercased())")
        #endif
        Task {
            await viewModel.startVenueEventCommentsRealtime(for: venueEventID)
            viewModel.scheduleOpenVenueEventCommentsRecoveryBurst(for: venueEventID)
        }

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
        } else {
            commentsHasOlder = await viewModel.loadCommentsFirstPage(for: venueEventID, logFullSheetLoad: true)
            withAnimation(.easeOut(duration: 0.22)) {
                isLoadingInitialComments = false
            }
            FanUpdatesTapPerf.logCommentLoadCompleted(
                ms: (CFAbsoluteTimeGetCurrent() - loadStarted) * 1000
            )
            scheduleNativeAdsAfterCommentsRender()
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

    @MainActor
    private func runFanUpdatesAutoRefreshLoop() async {
        enum FanUpdatesAutoRefreshValidation {
            static let fanUpdatesAutoRefreshEnabled = true
        }

        guard FanUpdatesAutoRefreshValidation.fanUpdatesAutoRefreshEnabled else {
            #if DEBUG
            print("[FanChatAutoRefreshDebug] enabled=false reason=realtimeValidation")
            print("[FanChatAutoRefreshDebug] skipped reason=disabledForValidation")
            #endif
            return
        }

        #if DEBUG
        print("[FanChatAutoRefreshDebug] enabled=true reason=realtimeStillFallbackUsed")
        print("[FanChatAutoRefreshDebug] started eventId=\(venueEventID.uuidString.lowercased())")
        #endif
        defer {
            isAutoRefreshingComments = false
            #if DEBUG
            print("[FanChatAutoRefreshDebug] stopped eventId=\(venueEventID.uuidString.lowercased())")
            #endif
        }

        while !Task.isCancelled {
            #if DEBUG
            print("[FanChatAutoRefreshDebug] tick eventId=\(venueEventID.uuidString.lowercased())")
            #endif

            if fanUpdatesRefreshInFlight {
                #if DEBUG
                print("[FanChatAutoRefreshDebug] skipped reason=refreshInFlight")
                #endif
            } else {
                isAutoRefreshingComments = true
                let hasNewRows = await viewModel.autoRefreshFanUpdatesComments(for: venueEventID)
                isAutoRefreshingComments = false
                if hasNewRows {
                    await loadCommentProfilesAndFriendshipChips()
                }
            }

            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
        }
    }

    @ViewBuilder
    private func venueCommentsListRow(_ item: VenueCommentsListItem, layoutWidth: CGFloat) -> some View {
        switch item {
        case .comment(let comment):
            commentRow(comment)
                .id(commentScrollID(for: comment))
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

                    VStack(alignment: .trailing, spacing: 4) {
                        // Trailing: report (others) → Add Friend / status (others) → delete (self, rightmost).
                        HStack(spacing: 8) {
                        if let email = comment.user_email,
                           let commentID = comment.serverCommentID,
                           !isAuthoredByCurrentUser(email: email),
                           !comment.isPendingSend,
                           !comment.isFailedSend,
                           viewModel.isAuthenticatedForSocialFeatures {
                            let alreadyReported = fanUpdatesStore.commentIDsReportedByCurrentUser.contains(commentID)
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

                        if let email = comment.user_email,
                           isAuthoredByCurrentUser(email: email),
                           !comment.isPendingSend,
                           !comment.isFailedSend {
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

                        ownCommentDeliveryStatus(for: comment)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                Text(comment.comment ?? "")
                    .font(.subheadline)
                    .foregroundStyle(primaryLabelColor)
                    .fixedSize(horizontal: false, vertical: true)

                commentLikeControl(for: comment)

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
    private func commentLikeControl(for comment: VenueEventCommentRow) -> some View {
        if let commentID = comment.serverCommentID {
            let canToggleLike = viewModel.isAuthenticatedForSocialFeatures && viewModel.canUseFanSocialFeatures
            let isLiked = comment.isLikedByCurrentUser
            let likeCount = comment.likeCount
            let likeColor = isLiked ? Color.red.opacity(0.9) : mutedLabelColor

            Button {
                guard canToggleLike else { return }
                FGInteractionHaptics.selection()
                Task { await viewModel.toggleCommentLike(commentId: commentID) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(likeColor)

                    if likeCount > 0 {
                        Text("\(likeCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(likeColor)
                            .contentTransition(.numericText())
                    }
                }
                .padding(.top, 2)
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.9, hapticOnPress: false))
            .disabled(!canToggleLike)
            .opacity(canToggleLike || likeCount > 0 ? 1 : 0.72)
            .animation(.easeOut(duration: 0.16), value: isLiked)
            .animation(.easeOut(duration: 0.16), value: likeCount)
            .accessibilityLabel(isLiked ? "Unlike fan update" : "Like fan update")
            .accessibilityValue(likeCount == 1 ? "1 like" : "\(likeCount) likes")
            .accessibilityHint(canToggleLike ? "Toggles your like on this update" : "Sign in as a fan to like updates")
        }
    }

    @ViewBuilder
    private func ownCommentDeliveryStatus(for comment: VenueEventCommentRow) -> some View {
        if let email = comment.user_email, isAuthoredByCurrentUser(email: email) {
            switch comment.delivery_state {
            case .pending:
                Label("Sending…", systemImage: "clock")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(secondaryLabelColor)
            case .sent:
                Label {
                    Text("Posted")
                        .foregroundStyle(secondaryLabelColor)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green.opacity(0.82))
                }
                .font(.caption2.weight(.semibold))
            case .failed:
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
                    Label("Failed", systemImage: "exclamationmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry sending update")
            }
        }
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

                        manualRefreshCommentsButton

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
                HStack(spacing: 10) {
                    Text(BusinessFanGateCopy.commentsViewOnlyForBusiness)
                        .font(.caption)
                        .foregroundStyle(mutedLabelColor)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    manualRefreshCommentsButton
                }
            } else {
                HStack(spacing: 10) {
                    Text("Login as a user or venue owner to add an update.")
                        .font(.caption)
                        .foregroundStyle(mutedLabelColor)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    manualRefreshCommentsButton
                }
            }
        }
    }

    private var manualRefreshCommentsButton: some View {
        Button {
            Task { await manualRefreshCommentsTapped() }
        } label: {
            ZStack {
                if isUserRefreshingComments {
                    ProgressView()
                        .scaleEffect(0.74)
                        .tint(secondaryLabelColor)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(secondaryLabelColor)
                }
            }
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(fanUpdatesIsDark ? 0.18 : 0.38), lineWidth: 0.75)
                }
                .contentShape(Circle())
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.94, hapticOnPress: false))
        .disabled(fanUpdatesInteractiveRefreshInFlight)
        .opacity(fanUpdatesInteractiveRefreshInFlight ? 0.62 : 1.0)
        .accessibilityLabel("Refresh fan updates")
    }

    @MainActor
    private func manualRefreshCommentsTapped() async {
        guard !fanUpdatesInteractiveRefreshInFlight else { return }
        #if DEBUG
        print("[FanChatBottomRefreshDebug] tapped eventId=\(venueEventID.uuidString.lowercased())")
        print("[FanChatManualRefreshDebug] tapped eventId=\(venueEventID.uuidString.lowercased())")
        #endif
        isManuallyRefreshingComments = true
        showFanUpdatesRefreshSpinner(reason: "bottom")
        defer {
            isManuallyRefreshingComments = false
            hideFanUpdatesRefreshSpinner()
        }

        _ = await viewModel.manualRefreshFanUpdatesComments(for: venueEventID)
        if Task.isCancelled {
            logFanUpdatesBottomRefreshCancelledSilently()
            return
        }
        await loadCommentProfilesAndFriendshipChips()
        if Task.isCancelled {
            logFanUpdatesBottomRefreshCancelledSilently()
            return
        }
    }

    @MainActor
    private func showFanUpdatesRefreshSpinner(reason: String) {
        guard !isUserRefreshingComments else { return }
        isUserRefreshingComments = true
        #if DEBUG
        print("[FanChatBottomRefreshDebug] spinnerVisible=true")
        print("[FanChatRefreshSpinnerDebug] visible=true reason=\(reason)")
        #endif
    }

    @MainActor
    private func hideFanUpdatesRefreshSpinner() {
        guard isUserRefreshingComments else { return }
        isUserRefreshingComments = false
        #if DEBUG
        print("[FanChatBottomRefreshDebug] spinnerVisible=false")
        print("[FanChatRefreshSpinnerDebug] visible=false")
        #endif
    }

    private func logFanUpdatesBottomRefreshCancelledSilently() {
        #if DEBUG
        print("[CancellationHandlingDebug] ignoredCancellation context=fan_updates_bottom_refresh")
        print("[FanChatBottomRefreshDebug] cancelledSilently eventId=\(venueEventID.uuidString.lowercased())")
        #endif
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
        let now = Date()
        pruneLocalFanUpdateBurst(now: now)

        if let last = fanUpdateBurstSentAt.last,
           fanUpdateBurstSentAt.count >= RateLimitService.venueEventCommentBurstAllowance {
            let cooldownSeconds = max(
                0,
                RateLimitService.venueEventCommentCooldownSeconds - now.timeIntervalSince(last)
            )
            if cooldownSeconds > 0 {
                fanUpdateCooldownUntil = last.addingTimeInterval(RateLimitService.venueEventCommentCooldownSeconds)
                updateFanUpdateCooldownRemainingSeconds(now: now)
                RateLimitService.logFanUpdateRateLimitDebug(
                    allowed: false,
                    burstCount: fanUpdateBurstSentAt.count,
                    cooldownSeconds: cooldownSeconds
                )
                return RateLimitService.fanUpdateSlowDownMessage
            }
        }

        if let lastSuccessfulFanUpdateKey,
           let lastSuccessfulFanUpdateAt,
           lastSuccessfulFanUpdateKey == fanUpdateDuplicateKey(for: cleanText),
           cleanText.count >= 8,
           Date().timeIntervalSince(lastSuccessfulFanUpdateAt) < RateLimitService.venueEventCommentDuplicateWindow {
            RateLimitService.logFanUpdateRateLimitDebug(
                allowed: false,
                burstCount: fanUpdateBurstSentAt.count,
                cooldownSeconds: 0
            )
            return "You already posted that update."
        }

        RateLimitService.logFanUpdateRateLimitDebug(
            allowed: true,
            burstCount: fanUpdateBurstSentAt.count + 1,
            cooldownSeconds: 0
        )
        return nil
    }

    private func registerSuccessfulFanUpdate(_ cleanText: String) {
        let now = Date()
        pruneLocalFanUpdateBurst(now: now)
        fanUpdateBurstSentAt.append(now)
        lastSuccessfulFanUpdateKey = fanUpdateDuplicateKey(for: cleanText)
        lastSuccessfulFanUpdateAt = now
        updateFanUpdateCooldownRemainingSeconds()
    }

    private func pruneLocalFanUpdateBurst(now: Date = Date()) {
        fanUpdateBurstSentAt.removeAll {
            now.timeIntervalSince($0) > RateLimitService.venueEventCommentBurstWindow
        }
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
            || message == RateLimitService.fanUpdateSlowDownMessage
            || message == RateLimitService.duplicateBlockedMessage
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

private struct FanUpdatesCommentsBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
