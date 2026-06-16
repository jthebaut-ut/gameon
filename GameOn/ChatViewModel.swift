import Combine
import Foundation
import Supabase
import SwiftUI

/// Owns friends / friend-request state for the Chat tab. Independent of ``MapViewModel``.
@MainActor
final class ChatViewModel: ObservableObject {

    private var instanceDebugID: String {
        "\(ObjectIdentifier(self))"
    }

    init() {
#if DEBUG
        print("[ChatViewModelInstanceDebug] init id=\(instanceDebugID)")
        print("[MainActorDebug] ChatViewModel.init actor=MainActor")
#endif
    }

    deinit {
#if DEBUG
        print("[ChatViewModelInstanceDebug] deinit id=\(ObjectIdentifier(self))")
#endif
    }

    /// Used to refresh internal reputation state after friend accept (set from ``FriendsTabView``).
    weak var mapViewModel: MapViewModel?

    /// Compact friendship state for comment rows (and similar surfaces). Absence in ``friendshipChipByOtherUserId`` means treat as stranger → Add Friend.
    enum FriendshipChipKind: Equatable {
        case addFriend
        /// Viewer sent a request to this user (show “Requested”).
        case pendingOutgoing
        /// This user sent the viewer a request (show inbox-style hint; not “Requested”).
        case pendingIncoming
        case friends
        /// Viewer’s outgoing request was declined; still visible in Sent until cleared.
        case declinedOutgoing
    }

    struct FriendDisplay: Identifiable, Hashable {
        let id: UUID
        let preview: UserPreview
        let subtitle: String?
        let lastMessageAt: Date?
        let unreadCount: Int
        let isConversationBacked: Bool
    }

    struct IncomingRequestDisplay: Identifiable, Hashable {
        let friendship: FriendshipRow
        let requester: UserPreview
        var id: UUID { friendship.id }
    }

    struct OutgoingRequestDisplay: Identifiable, Hashable {
        let friendship: FriendshipRow
        let addressee: UserPreview
        var id: UUID { friendship.id }
    }

    @Published private(set) var friends: [FriendDisplay] = []
    @Published private(set) var incomingRequests: [IncomingRequestDisplay] = []
    @Published private(set) var outgoingRequests: [OutgoingRequestDisplay] = []
    @Published private(set) var pendingBadgeCount: Int = 0
    /// Unread peer DMs for the signed-in user (MainTabView private chat tab badge + ``AppIconBadgeSync``). Server source: inbox RPC unread totals / `get_dm_unread_total`; not friend-request counts.
    @Published private(set) var unreadDirectMessageCount: Int = 0
    /// When non-nil, ``MainTabView`` switches to Chat and ``FriendsTabView`` pushes ``DirectChatView`` for this peer.
    @Published var pendingDmOpenPreview: UserPreview?
    /// Lightweight in-app banner for an incoming DM while the thread is not open (local only).
    @Published private(set) var dmInAppNotification: DmInAppNotificationPayload?
    @Published var errorMessage: String?
    /// Shown when swipe-delete (inbox clear) fails; kept separate from ``errorMessage`` so friend-request errors don’t clash.
    @Published var inboxDeleteError: String?
    @Published private(set) var requiresSignIn: Bool = false
    @Published var isLoading: Bool = false

    /// Other user id → chip state. Keys only for users with an active friendship row; missing key ⇒ ``FriendshipChipKind.addFriend``.
    @Published private(set) var friendshipChipByOtherUserId: [UUID: FriendshipChipKind] = [:]
    @Published private(set) var currentUserAuthId: UUID?

    // MARK: - Moderation (blocked users)

    @Published private(set) var blockedUserIds: Set<UUID> = []
    /// Users who have blocked the current user (reverse of ``blockedUserIds``).
    @Published private(set) var usersWhoBlockedMeIds: Set<UUID> = []
    @Published private(set) var blockedUserPreviews: [UserPreview] = []
    private let moderation = ModerationService()

    /// When true, ``MainTabView`` hides the floating tab bar so ``DirectChatView`` composer stays visible.
    @Published var hidesFloatingTabBarForDirectChat: Bool = false
    @Published private(set) var activeVisibleConversationId: UUID?
    @Published private(set) var directChatReadVisibilityVersion: Int = 0

    @Published private(set) var addFriendSearchResults: [AddFriendSearchTarget] = []
    @Published private(set) var addFriendSearchIsLoading: Bool = false

    private let service = FriendshipService()
    private let directChatService = DirectChatService()
    private let socialIdentityService = SocialIdentityService()
    private var lastLoadAt: Date?
    private let minRefreshInterval: TimeInterval = 12
    private var lastInboxLoadAt: Date?
    private let minInboxRefreshInterval: TimeInterval = 2
    private var startupLightweightPrefetchTask: Task<StartupChatPrefetchResult, Never>?
    private var lastStartupLightweightPrefetchAt: Date?
    private let startupLightweightPrefetchTTL: TimeInterval = 90

    private var chatTabVisibleForDirectReadState = false
    private var privateChatUnlockedForDirectReadState = false

    /// Payload for the top-of-app DM toast/banner.
    struct DmInAppNotificationPayload: Identifiable, Equatable {
        let id: UUID
        let conversationId: UUID?
        let senderPreview: UserPreview
        let bodyPreview: String
    }

    struct StartupChatPrefetchResult {
        let dmBadgePrefetched: Bool
        let inboxSummariesPrefetched: Bool
        let skippedReason: String?
    }

    // MARK: - Realtime (in-app inbox)

    /// In-app realtime listener for `public.direct_messages` INSERTs while signed in (singleton per user).
    /// Lifecycle: ``ensureSignedInSocialRealtimeIfNeeded()`` / ``scheduleEnsureSocialRealtimeAfterForeground()``; stopped on logout.
    /// This does **not** work when the app is backgrounded/killed; that requires APNs/push later.
    ///
    /// **Scope:** When ``inboxRealtimeUsesConversationFilter`` is false (no filter or list too large), the client listens without
    /// a `postgres` filter; **RLS on `direct_messages`** restricts which rows each JWT receives at scale.
    ///
    /// **TODO (ideal at scale):** user-scoped Realtime channel or Edge Function broadcast delivering inbox summary deltas only,
    /// avoiding per-row fan-out and large conversation-id filter lists.
    private var inboxChannel: RealtimeChannelV2?
    private var inboxListenTask: Task<Void, Never>?
    /// Debounced server unread total (`get_dm_unread_total` / equivalent) after local inbox row tweaks from Realtime.
    private var inboxUnreadDebounceTask: Task<Void, Never>?
    /// Coalesces rare “peer not in inbox list yet” cases into a single full ``refreshInboxSummaries()`` (not per INSERT).
    private var inboxMissingPeerReconcileTask: Task<Void, Never>?
    /// Coalesces explicit badge recount requests from foreground, tab switches, and read-state changes.
    private var badgeRecalculationTask: Task<Void, Never>?
    private var badgeRecalculationNeedsInboxSummaries = false
    private var dmLatencyInboxEventStartByConversationID: [UUID: CFAbsoluteTime] = [:]
    /// User id the active inbox channel was bound to (debug + duplicate-guard).
    private var inboxRealtimeBoundUserId: UUID?
    /// True when the inbox listener uses a client-side `conversation_id IN (...)` filter (see run loop).
    private var inboxRealtimeUsesConversationFilter: Bool = false
    private var chatPresenceChannel: RealtimeChannelV2?
    private var chatPresenceListenTask: Task<Void, Never>?
    private var chatPresenceTrackedUserIds: Set<UUID> = []
    private var chatPresenceExpiryTask: Task<Void, Never>?

    /// Supabase Realtime `IN` filters should stay small; above this we omit the client filter and rely on RLS.
    private let kMaxConversationIdsForInboxRealtimeClientFilter = 48
    private let kMaxUserProfileIdsForPresenceRealtimeClientFilter = 64

    struct DMRealtimeIdentitySnapshot {
        let accountType: String
        let authUserId: UUID?
        let businessId: UUID?
        let listeningIdentityIds: [UUID]

        var authUserIdLogValue: String {
            authUserId?.uuidString.lowercased() ?? "nil"
        }

        var businessIdLogValue: String {
            businessId?.uuidString.lowercased() ?? "nil"
        }

        var listeningLogValue: String {
            guard !listeningIdentityIds.isEmpty else { return "none" }
            return listeningIdentityIds
                .map { $0.uuidString.lowercased() }
                .joined(separator: ",")
        }
    }

    // MARK: - Realtime (friend requests)

    private var friendshipsChannel: RealtimeChannelV2?
    private var friendshipsListenTask: Task<Void, Never>?
    private var friendshipsRealtimeBoundUserId: UUID?
    private var friendRequestRealtimeDebounceTask: Task<Void, Never>?
    /// Debounces ``ensureSignedInSocialRealtimeIfNeeded()`` after app foreground to avoid reconnect storms.
    private var socialRealtimeForegroundTask: Task<Void, Never>?

    func dmRealtimeIdentitySnapshot(fallbackAuthUserId: UUID? = nil) -> DMRealtimeIdentitySnapshot {
        let authUserId = currentUserAuthId ?? fallbackAuthUserId
        let businessId = currentBusinessIdentityIdForDMRealtime()
        let accountType = businessId == nil ? "user" : "business"
        let ids = [authUserId, businessId]
            .compactMap { $0 }
            .reduce(into: [UUID]()) { result, id in
                if !result.contains(id) { result.append(id) }
            }
        return DMRealtimeIdentitySnapshot(
            accountType: accountType,
            authUserId: authUserId,
            businessId: businessId,
            listeningIdentityIds: ids
        )
    }

    func isCurrentDMRealtimeIdentity(_ id: UUID, fallbackAuthUserId: UUID? = nil) -> Bool {
        dmRealtimeIdentitySnapshot(fallbackAuthUserId: fallbackAuthUserId)
            .listeningIdentityIds
            .contains(id)
    }

    private func currentBusinessIdentityIdForDMRealtime() -> UUID? {
        guard let mapViewModel else { return nil }
        let isBusinessContext = mapViewModel.currentUserIsBusinessAccount
            || mapViewModel.isVenueOwnerLoggedIn
            || mapViewModel.hasAuthenticatedVenueOwnerSession
        guard isBusinessContext else { return nil }
        return mapViewModel.currentBusinessIdForAddLocation()
            ?? mapViewModel.ownedBusinesses.first?.id
    }

    func currentUserIdIfSignedIn() async -> UUID? {
        try? await service.currentUserId()
    }

    private func noteAuthenticatedChatSession(userId: UUID, source: String) {
        currentUserAuthId = userId
        requiresSignIn = false
#if DEBUG
        let email = mapViewModel?.authenticatedSocialEmailForUI ?? ""
        let isBusiness = mapViewModel?.currentUserIsBusinessAccount == true
            || mapViewModel?.isVenueOwnerLoggedIn == true
            || mapViewModel?.hasAuthenticatedVenueOwnerSession == true
        let hasUserProfile = mapViewModel?.userProfileExistsForPresentation == true
            || mapViewModel?.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || mapViewModel?.currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        print("[ChatAuthGate] chatViewModelAuthenticated source=\(source)")
        print("[ChatAuthGate] hasSession=true")
        print("[ChatAuthGate] userEmail=\(email.isEmpty ? "nil" : email)")
        print("[ChatAuthGate] isBusinessAccount=\(isBusiness)")
        print("[ChatAuthGate] hasUserProfile=\(hasUserProfile)")
        print("[ChatAuthGate] reasonBlocked=none")
#endif
    }

    private func ignoreCancellationIfNeeded(_ error: Error, context: String) -> Bool {
        guard error is CancellationError else { return false }
        #if DEBUG
        print("[CancellationHandlingDebug] ignoredCancellation context=\(context)")
        #endif
        return true
    }

    /// Clears social UI state when the session ends (no network).
    func clearForSignOut() {
        friends = []
        incomingRequests = []
        outgoingRequests = []
        pendingBadgeCount = 0
        unreadDirectMessageCount = 0
        errorMessage = nil
        inboxDeleteError = nil
        requiresSignIn = true
        lastLoadAt = nil
        lastInboxLoadAt = nil
        friendshipChipByOtherUserId = [:]
        currentUserAuthId = nil
        hidesFloatingTabBarForDirectChat = false
        blockedUserIds = []
        usersWhoBlockedMeIds = []
        blockedUserPreviews = []
        addFriendSearchResults = []
        addFriendSearchIsLoading = false
        pendingDmOpenPreview = nil
        dmInAppNotification = nil
        activeVisibleConversationId = nil
        chatTabVisibleForDirectReadState = false
        privateChatUnlockedForDirectReadState = false
        inboxUnreadDebounceTask?.cancel()
        inboxUnreadDebounceTask = nil
        inboxMissingPeerReconcileTask?.cancel()
        inboxMissingPeerReconcileTask = nil
        badgeRecalculationTask?.cancel()
        badgeRecalculationTask = nil
        badgeRecalculationNeedsInboxSummaries = false
        startupLightweightPrefetchTask?.cancel()
        startupLightweightPrefetchTask = nil
        lastStartupLightweightPrefetchAt = nil
        friendRequestRealtimeDebounceTask?.cancel()
        friendRequestRealtimeDebounceTask = nil
        socialRealtimeForegroundTask?.cancel()
        socialRealtimeForegroundTask = nil

        Task { [weak self] in
            guard let self else { return }
            await self.stopInboxRealtimeListener()
            await self.stopFriendshipsRealtimeListener()
            await self.stopChatPresenceRealtimeListener()
            await AppIconBadgeSync.apply(count: 0)
        }
    }

    func clearForLogout() async {
        clearForSignOut()
    }

    /// True if either party has blocked the other (client-side UX guard).
    func isEitherDirectionBlocked(with peerId: UUID) -> Bool {
        blockedUserIds.contains(peerId) || usersWhoBlockedMeIds.contains(peerId)
    }

    /// Reloads block sets from Supabase; ignores failures (keeps prior state).
    private func reloadModerationBlockSets() async {
        do {
            blockedUserIds = try await moderation.fetchBlockedUserIds()
            usersWhoBlockedMeIds = try await moderation.fetchUsersWhoBlockedMeIds()
        } catch {
            // TODO: Non-fatal telemetry; server-side enforcement still required.
        }
    }

    /// Ensures DM inbox + friend-request Realtime listeners are running while signed in.
    /// Tab switches, DM navigation, and sheets do **not** stop these listeners (see ``setChatTabRealtimeEnabled``).
    func ensureSignedInSocialRealtimeIfNeeded() async {
        guard requiresSignIn == false else { return }
#if DEBUG
        print("[BadgeArchitectureDebug] ensureRealtime vm=\(instanceDebugID)")
        print("[MainActorDebug] ensureRealtime actor=MainActor")
#endif
        await repairInconsistentSocialRealtimeChannelsIfNeeded()
        startInboxRealtimeListenerIfNeeded()
        startFriendshipsRealtimeListenerIfNeeded()
        syncChatPresenceRealtimeIfNeeded(reason: "ensureSignedInSocialRealtime")
    }

    /// Debounced re-attach after foreground (avoids stacked reconnects with scene churn).
    func scheduleEnsureSocialRealtimeAfterForeground() {
        socialRealtimeForegroundTask?.cancel()
        socialRealtimeForegroundTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
#if DEBUG
            print("[RealtimeLifecycle] foreground debounced ensure")
#endif
            let identity = self.dmRealtimeIdentitySnapshot()
            DMRealtimeDiagnostics.debug(
                "reconnectOnForeground=true accountType=\(identity.accountType) authUserId=\(identity.authUserIdLogValue) businessId=\(identity.businessIdLogValue)"
            )
            DMRealtimeDiagnostics.debug(
                "foregroundReconnectCheck=true accountType=\(identity.accountType) authUserId=\(identity.authUserIdLogValue) businessId=\(identity.businessIdLogValue)"
            )
#if DEBUG
            RealtimeHealthDiagnostics.log("appForegroundReconnect=chat_social")
#endif
            await self.restartSocialRealtimeAfterForeground()
            await self.refreshChatPresenceSnapshots(reason: "foregroundReconnect")
            self.requestForegroundBadgeRefresh()
        }
    }

    private func restartSocialRealtimeAfterForeground() async {
        guard requiresSignIn == false else { return }
#if DEBUG
        RealtimeHealthDiagnostics.log("reconnectDetected=chat_social_foreground_resubscribe")
#endif
        print("[PresenceDebug] foregroundReconnect=true")
        await stopInboxRealtimeListener()
        await stopFriendshipsRealtimeListener()
        await stopChatPresenceRealtimeListener()
        await ensureSignedInSocialRealtimeIfNeeded()
    }

    func forceRestartChatRealtimeAfterGlobalRetryExhausted(reason: String) async {
        guard requiresSignIn == false else { return }
        DMRealtimeDiagnostics.debug("globalRealtimeRestart=true reason=\(reason)")
#if DEBUG
        RealtimeHealthDiagnostics.log("reconnectDetected=chat_social_global_retry_exhausted reason=\(reason)")
#endif
        await stopInboxRealtimeListener()
        await stopFriendshipsRealtimeListener()
        await stopChatPresenceRealtimeListener()
        await ensureSignedInSocialRealtimeIfNeeded()
    }

    private func realtimeErrorIndicatesGlobalRetryExhausted(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("maximum retry attempts")
            || message.contains("max retry")
            || message.contains("retry attempts reached")
    }

    private func repairInconsistentSocialRealtimeChannelsIfNeeded() async {
        if (inboxListenTask == nil) != (inboxChannel == nil) {
#if DEBUG
            RealtimeHealthDiagnostics.log("reconnectDetected=dm_inbox_inconsistent_state")
#endif
            await stopInboxRealtimeListener()
        }
        if (friendshipsListenTask == nil) != (friendshipsChannel == nil) {
#if DEBUG
            RealtimeHealthDiagnostics.log("reconnectDetected=friendships_inconsistent_state")
#endif
            await stopFriendshipsRealtimeListener()
        }
        if (chatPresenceListenTask == nil) != (chatPresenceChannel == nil) {
#if DEBUG
            RealtimeHealthDiagnostics.log("reconnectDetected=chat_presence_inconsistent_state")
#endif
            await stopChatPresenceRealtimeListener()
        }
    }

    private func syncChatPresenceRealtimeIfNeeded(reason: String) {
        guard requiresSignIn == false else {
            Task { await stopChatPresenceRealtimeListener() }
            return
        }
        let ids = Set(
            friends
                .filter { !$0.preview.isDeleted }
                .map(\.id)
        )
        guard !ids.isEmpty else {
            Task { await stopChatPresenceRealtimeListener() }
            return
        }

        if ids == chatPresenceTrackedUserIds,
           chatPresenceListenTask != nil,
           chatPresenceChannel != nil {
            startChatPresenceExpiryTickerIfNeeded()
            print("[PresenceDebug] subscribeStarted=false reason=alreadyActive onlineUsersCount=\(chatPresenceOnlineCount())")
            return
        }

        chatPresenceTrackedUserIds = ids
        chatPresenceListenTask?.cancel()
        chatPresenceListenTask = nil
        if let channel = chatPresenceChannel {
            chatPresenceChannel = nil
            Task { await supabase.removeChannel(channel) }
        }

        let sortedIds = ids.sorted { $0.uuidString < $1.uuidString }
        startChatPresenceExpiryTickerIfNeeded()
        chatPresenceListenTask = Task { @MainActor [weak self] in
            await self?.runChatPresenceRealtimeLoop(userIds: sortedIds, reason: reason)
        }
    }

    private func runChatPresenceRealtimeLoop(userIds: [UUID], reason: String) async {
        guard !userIds.isEmpty else { return }
        let channelName = "chat-presence-\(UUID().uuidString.lowercased())"
        let channel = supabase.channel(channelName)
        chatPresenceChannel = channel
        let identity = dmRealtimeIdentitySnapshot()
        print("[PresenceDebug] subscribeStarted=true reason=\(reason) channelName=\(channelName)")
        print("[PresenceDebug] userId=\(identity.authUserIdLogValue)")
        print("[PresenceDebug] businessId=\(identity.businessIdLogValue)")

        let streams = Self.chunked(userIds, size: kMaxUserProfileIdsForPresenceRealtimeClientFilter).map { chunk in
            channel.postgresChange(
                UpdateAction.self,
                schema: "public",
                table: "user_profiles",
                filter: RealtimePostgresFilter.in("id", values: chunk)
            )
        }

        var shouldRestartChatRealtime = false
        do {
            try await channel.subscribeWithError()
            print("[PresenceDebug] onlineUsersCount=\(chatPresenceOnlineCount())")
            await withTaskGroup(of: Void.self) { group in
                for stream in streams {
                    group.addTask { [weak self] in
                        await self?.consumeChatPresenceUpdates(stream)
                    }
                }
            }
        } catch is CancellationError {
        } catch {
#if DEBUG
            print("[PresenceDebug] subscribeError=\(error.localizedDescription) channelName=\(channelName)")
#endif
            shouldRestartChatRealtime = realtimeErrorIndicatesGlobalRetryExhausted(error)
        }

        if chatPresenceChannel === channel {
            chatPresenceChannel = nil
        }
        if chatPresenceListenTask != nil, !Task.isCancelled {
            await supabase.removeChannel(channel)
        }
        if shouldRestartChatRealtime {
            Task { @MainActor [weak self] in
                await Task.yield()
                await self?.forceRestartChatRealtimeAfterGlobalRetryExhausted(reason: "presenceMaxRetry")
            }
        }
    }

    private func consumeChatPresenceUpdates(_ stream: AsyncStream<UpdateAction>) async {
        let decoder = JSONDecoder()
        for await update in stream {
            if Task.isCancelled { break }
            let row: UserProfileRow
            do {
                row = try update.decodeRecord(as: UserProfileRow.self, decoder: decoder)
            } catch {
                continue
            }
            guard let userId = row.id else { continue }
            applyChatPresenceUpdate(userId: userId, lastSeenAtRaw: row.last_seen_at, source: "realtime")
        }
    }

    private func applyChatPresenceUpdate(userId: UUID, lastSeenAtRaw: String?, source: String) {
        let userLow = userId.uuidString.lowercased()
        let isOnline = PresenceOnlineStatus.parse(lastSeenAtRaw).map {
            Date().timeIntervalSince($0) <= PresenceOnlineStatus.onlineWindowSeconds
        } ?? false
        print("[PresenceDebug] userOnline=\(isOnline) userId=\(userLow) source=\(source)")
        print("[PresenceDebug] lastSeen=\(lastSeenAtRaw ?? "nil") userId=\(userLow)")

        var changed = false
        let nextFriends = friends.map { display -> FriendDisplay in
            guard display.id == userId || display.preview.id == userId else { return display }
            guard display.preview.lastSeenAtRaw != lastSeenAtRaw else { return display }
            changed = true
            return FriendDisplay(
                id: display.id,
                preview: Self.preview(display.preview, replacingLastSeenAtRawWith: lastSeenAtRaw),
                subtitle: display.subtitle,
                lastMessageAt: display.lastMessageAt,
                unreadCount: display.unreadCount,
                isConversationBacked: display.isConversationBacked
            )
        }
        if changed {
            friends = nextFriends
            print("[PresenceDebug] onlineUsersCount=\(chatPresenceOnlineCount(in: nextFriends))")
        }

        var incomingChanged = false
        let nextIncoming = incomingRequests.map { item -> IncomingRequestDisplay in
            guard item.requester.id == userId else { return item }
            guard item.requester.lastSeenAtRaw != lastSeenAtRaw else { return item }
            incomingChanged = true
            return IncomingRequestDisplay(
                friendship: item.friendship,
                requester: Self.preview(item.requester, replacingLastSeenAtRawWith: lastSeenAtRaw)
            )
        }
        if incomingChanged {
            incomingRequests = nextIncoming
        }

        var outgoingChanged = false
        let nextOutgoing = outgoingRequests.map { item -> OutgoingRequestDisplay in
            guard item.addressee.id == userId else { return item }
            guard item.addressee.lastSeenAtRaw != lastSeenAtRaw else { return item }
            outgoingChanged = true
            return OutgoingRequestDisplay(
                friendship: item.friendship,
                addressee: Self.preview(item.addressee, replacingLastSeenAtRawWith: lastSeenAtRaw)
            )
        }
        if outgoingChanged {
            outgoingRequests = nextOutgoing
        }
    }

    private func refreshChatPresenceSnapshots(reason: String) async {
        let ids = Array(Set(friends.map(\.id)))
        guard !ids.isEmpty else { return }
        do {
            let previews = try await socialIdentityService.fetchUserPreviews(for: ids)
            for id in ids {
                applyChatPresenceUpdate(
                    userId: id,
                    lastSeenAtRaw: previews[id]?.lastSeenAtRaw,
                    source: reason
                )
            }
        } catch {
#if DEBUG
            print("[PresenceDebug] refreshFailed reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
    }

    private func startChatPresenceExpiryTickerIfNeeded() {
        guard chatPresenceExpiryTask == nil else { return }
        chatPresenceExpiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    return
                }
                self?.expireStaleChatPresence()
            }
        }
    }

    private func expireStaleChatPresence() {
        let now = Date()
        let expiringIds = friends.compactMap { display -> UUID? in
            guard let lastSeen = PresenceOnlineStatus.parse(display.preview.lastSeenAtRaw),
                  now.timeIntervalSince(lastSeen) > PresenceOnlineStatus.onlineWindowSeconds else {
                return nil
            }
            return display.id
        }
        guard !expiringIds.isEmpty else { return }
        for id in expiringIds {
            applyChatPresenceUpdate(userId: id, lastSeenAtRaw: nil, source: "expiry")
        }
    }

    private func stopChatPresenceRealtimeListener() async {
        chatPresenceListenTask?.cancel()
        chatPresenceListenTask = nil
        chatPresenceTrackedUserIds = []
        chatPresenceExpiryTask?.cancel()
        chatPresenceExpiryTask = nil
        guard let channel = chatPresenceChannel else { return }
        chatPresenceChannel = nil
        await supabase.removeChannel(channel)
    }

    private func chatPresenceOnlineCount(in displays: [FriendDisplay]? = nil) -> Int {
        (displays ?? friends).filter { $0.preview.isOnlineNow }.count
    }

    private static func preview(
        _ preview: UserPreview,
        replacingLastSeenAtRawWith lastSeenAtRaw: String?
    ) -> UserPreview {
        UserPreview(
            id: preview.id,
            displayName: preview.displayName,
            username: preview.username,
            email: preview.email,
            avatarURL: preview.avatarURL,
            avatarThumbnailURL: preview.avatarThumbnailURL,
            isBusinessAccount: preview.isBusinessAccount,
            isDeleted: preview.isDeleted,
            lastSeenAtRaw: lastSeenAtRaw
        )
    }

    private static func chunked<T>(_ values: [T], size: Int) -> [[T]] {
        guard size > 0, !values.isEmpty else { return [] }
        var result: [[T]] = []
        var index = values.startIndex
        while index < values.endIndex {
            let end = values.index(index, offsetBy: size, limitedBy: values.endIndex) ?? values.endIndex
            result.append(Array(values[index..<end]))
            index = end
        }
        return result
    }

    func setDirectChatReadStateVisibility(chatTabVisible: Bool, privateChatUnlocked: Bool) {
        let wasAllowed = chatTabVisibleForDirectReadState && privateChatUnlockedForDirectReadState
        chatTabVisibleForDirectReadState = chatTabVisible
        privateChatUnlockedForDirectReadState = privateChatUnlocked
        let isAllowed = chatTabVisible && privateChatUnlocked
        if !isAllowed {
            clearActiveVisibleConversationId(reason: chatTabVisible ? "private_chat_locked" : "chat_tab_hidden")
        } else if !wasAllowed {
            directChatReadVisibilityVersion += 1
        }
#if DEBUG
        print("[DMReadStateDebug] chatTabVisible=\(chatTabVisible)")
        print("[DMReadStateDebug] privateChatUnlocked=\(privateChatUnlocked)")
#endif
    }

    @discardableResult
    func setActiveVisibleConversationIdIfAllowed(_ conversationId: UUID?, reason: String) -> Bool {
        guard let conversationId else {
            clearActiveVisibleConversationId(reason: "\(reason):missing_conversation")
            return false
        }
        guard chatTabVisibleForDirectReadState && privateChatUnlockedForDirectReadState else {
            clearActiveVisibleConversationId(reason: reason)
            return false
        }
        activeVisibleConversationId = conversationId
#if DEBUG
        print("[DMActiveVisibilityDebug] setActiveVisibleConversationId=\(conversationId.uuidString.lowercased())")
#endif
        return true
    }

    func clearActiveVisibleConversationId(reason: String) {
        guard activeVisibleConversationId != nil else {
#if DEBUG
            print("[DMActiveVisibilityDebug] clearActiveVisibleConversationId reason=\(reason)")
#endif
            return
        }
        activeVisibleConversationId = nil
#if DEBUG
        print("[DMActiveVisibilityDebug] clearActiveVisibleConversationId reason=\(reason)")
#endif
    }

    func canMarkActiveDirectThreadRead(conversationId: UUID?, reason: String) -> Bool {
#if DEBUG
        print("[DMReadStateDebug] activeVisibleConversationId=\(activeVisibleConversationId?.uuidString.lowercased() ?? "nil")")
#endif
        guard let conversationId, activeVisibleConversationId == conversationId else {
#if DEBUG
            print("[DMReadStateDebug] markReadSuppressed reason=notActiveVisibleThread")
#endif
            return false
        }
#if DEBUG
        print("[DMReadStateDebug] markReadAllowed reason=\(reason)")
#endif
        return true
    }

    func dismissDmInAppNotification() {
        dmInAppNotification = nil
    }

    /// User tapped the in-app DM banner: navigate to Chat + open thread.
    func openConversationFromDmBanner() {
        guard let note = dmInAppNotification else { return }
        dmInAppNotification = nil
        pendingDmOpenPreview = note.senderPreview
    }

    /// Background reconcile only (no blocking UI); caller already applied local inbox/unread patches.
    func scheduleLightweightInboxReconcile(delayNanoseconds: UInt64 = 900_000_000) {
        inboxMissingPeerReconcileTask?.cancel()
        inboxMissingPeerReconcileTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.refreshInboxSummaries()
        }
    }

    func requestBadgeRecalculation(
        reason: String,
        includeInboxSummaries: Bool = false,
        delayNanoseconds: UInt64 = 120_000_000
    ) {
#if DEBUG
        print("[BadgeSyncDebug] recalculation requested reason=\(reason)")
        print("[BadgeSyncDebug] includeInboxSummaries=\(includeInboxSummaries)")
#endif
        if badgeRecalculationTask != nil {
            if includeInboxSummaries && !badgeRecalculationNeedsInboxSummaries {
                badgeRecalculationNeedsInboxSummaries = true
#if DEBUG
                print("[BadgeSyncDebug] upgraded pending refresh reason=\(reason)")
                print("[BadgeSyncDebug] includeInboxSummaries=true")
#endif
            }
#if DEBUG
            print("[BadgeSyncDebug] skipped duplicate refresh")
#endif
            return
        }

        badgeRecalculationNeedsInboxSummaries = includeInboxSummaries
        badgeRecalculationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                await MainActor.run {
                    if self?.badgeRecalculationTask != nil {
                        self?.badgeRecalculationTask = nil
                        self?.badgeRecalculationNeedsInboxSummaries = false
                    }
                }
                return
            }

            guard let self, !Task.isCancelled else { return }
            let shouldRefreshInbox = self.badgeRecalculationNeedsInboxSummaries
            self.badgeRecalculationNeedsInboxSummaries = false
            if shouldRefreshInbox {
                await self.refreshInboxSummaries()
            } else {
                await self.refreshUnreadDirectMessageCount()
            }
            self.badgeRecalculationTask = nil
        }
    }

    func requestForegroundBadgeRefresh() {
#if DEBUG
        print("[BadgeSyncDebug] foreground refresh")
#endif
        requestBadgeRecalculation(reason: "foreground", includeInboxSummaries: true)
    }

    /// Legacy hook from the Chat tab: **only starts** listeners when enabled; disabling is a no-op so
    /// friend requests + inbox badges keep updating while on other tabs or inside a DM thread.
    func setChatTabRealtimeEnabled(_ enabled: Bool) {
        guard enabled else { return }
        Task { await ensureSignedInSocialRealtimeIfNeeded() }
    }

    /// Starts/stops a lightweight in-app inbox listener for unread badge refresh.
    /// Call this from the Chat tab view layer when the Chat tab becomes visible or hidden.
    func setInboxRealtimeEnabled(_ enabled: Bool) {
        guard enabled else { return }
        Task { await ensureSignedInSocialRealtimeIfNeeded() }
    }

    private func startInboxRealtimeListenerIfNeeded() {
        guard requiresSignIn == false else { return }
        guard inboxListenTask == nil, inboxChannel == nil else {
#if DEBUG
            print("[RealtimeLifecycle] duplicate prevented (inbox listener already active)")
#endif
#if DEBUG
            print("[RealtimeSubscriptionDebug] duplicatePrevented vm=\(instanceDebugID) taskActive=\(inboxListenTask != nil) channelActive=\(inboxChannel != nil)")
#endif
            return
        }
#if DEBUG
        print("[RealtimeLifecycle] starting inbox listener")
#endif
#if DEBUG
        print("[RealtimeSubscriptionDebug] startingInbox vm=\(instanceDebugID)")
        print("[MainActorDebug] startInboxRealtimeListenerIfNeeded actor=MainActor")
#endif
        inboxListenTask = Task { [weak self] in
            guard let self else { return }
            await self.runInboxRealtimeListenerLoop()
        }
    }

    private func removeInboxRealtimeChannelOnly() async {
        if let ch = inboxChannel {
            await supabase.removeChannel(ch)
        }
        inboxChannel = nil
        inboxRealtimeBoundUserId = nil
        inboxRealtimeUsesConversationFilter = false
    }

    private func runInboxRealtimeListenerLoop() async {
        // Ensure we have a current user id; ignore if not signed in.
        let me: UUID
        if let cached = currentUserAuthId {
            me = cached
        } else if let fetched = try? await directChatService.currentUserId() {
            me = fetched
        } else {
            return
        }

        defer {
            inboxUnreadDebounceTask?.cancel()
            inboxUnreadDebounceTask = nil
            inboxMissingPeerReconcileTask?.cancel()
            inboxMissingPeerReconcileTask = nil
            inboxListenTask = nil
        }

        let identity = dmRealtimeIdentitySnapshot(fallbackAuthUserId: me)
        let channelName = "dm-inbox-\(me.uuidString.lowercased())"
        let channel = supabase.channel(channelName)
        inboxChannel = channel
        let subscribeStartedAt = CFAbsoluteTimeGetCurrent()

        let readStateChanges = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "conversation_read_state"
        )

        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "direct_messages"
        )
        inboxRealtimeUsesConversationFilter = false
#if DEBUG
        print("[ChatRealtime] inbox scope: postgresChange unfiltered; user-visible events rely on RLS.")
        print("[RealtimeSubscriptionDebug] inboxFilter=none reason=avoid_stale_conversation_snapshot vm=\(instanceDebugID)")
        print("[RealtimePublicationVerify] expected table=conversation_read_state publication=supabase_realtime migration=20260731_0030")
        print("[RealtimeChainDebug] subscribeRequested table=conversation_read_state channel=\(channel.topic) filter=none")
        RealtimeHealthDiagnostics.log("channelName=\(channel.topic)")
        RealtimeHealthDiagnostics.log("subscribeStart=true channelName=\(channel.topic)")
#endif
        DMRealtimeDiagnostics.debug("subscribeStarted=true accountType=\(identity.accountType)")
        DMRealtimeDiagnostics.debug("authUserId=\(identity.authUserIdLogValue)")
        DMRealtimeDiagnostics.debug("businessId=\(identity.businessIdLogValue)")
        DMRealtimeDiagnostics.debug("channelName=\(channel.topic)")
        DMRealtimeDiagnostics.debug("listeningForSender=\(identity.listeningLogValue)")
        DMRealtimeDiagnostics.debug("listeningForRecipient=\(identity.listeningLogValue)")

        var shouldRestartChatRealtime = false
        do {
            try await channel.subscribeWithError()
            inboxRealtimeBoundUserId = me
            DMRealtimeDiagnostics.debug("channelStatus=\(String(describing: channel.status)) channelName=\(channel.topic)")
#if DEBUG
            print("[DMRealtime] inbox subscribed channel=dm-inbox-\(me.uuidString.lowercased())")
#endif
#if DEBUG
            print("[RealtimeSubscriptionDebug] inboxSubscribed vm=\(instanceDebugID) user=\(me.uuidString.lowercased()) filtered=\(inboxRealtimeUsesConversationFilter)")
            print("[DMRealtimeLatencyDebug] realtimeSubscribed conversationId=inbox channel=\(channel.topic)")
            print("[RealtimeChainDebug] subscribeReady table=conversation_read_state channel=\(channel.topic)")
            RealtimeHealthDiagnostics.log("subscribeReady elapsedMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - subscribeStartedAt) * 1000)) channelName=\(channel.topic)")
#endif
#if DEBUG
            DMRealtimeDiagnostics.log(
                "phase=inbox_realtime_subscribe_ready channel=dm-inbox-\(me.uuidString.lowercased()) filtered=\(inboxRealtimeUsesConversationFilter)"
            )
#endif

            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    await self?.consumeConversationReadStateRealtime(readStateChanges)
                }
                group.addTask { [weak self] in
                    await self?.consumeInboxDirectMessageInserts(inserts, me: me)
                }
            }
        } catch is CancellationError {
#if DEBUG
            print("[DMRealtime] inbox listener cancelled")
#endif
        } catch {
            DMRealtimeDiagnostics.debug("channelError=\(error.localizedDescription) channelName=\(channel.topic)")
#if DEBUG
            print("[DMRealtime] inbox listener error: \(error)")
#endif
#if DEBUG
            print("[RealtimeChainDebug] subscribeFailed table=conversation_read_state error=\(error.localizedDescription)")
            RealtimeHealthDiagnostics.log("subscribeError=\(error.localizedDescription) channelName=\(channel.topic)")
#endif
            shouldRestartChatRealtime = realtimeErrorIndicatesGlobalRetryExhausted(error)
        }

        await removeInboxRealtimeChannelOnly()
        if shouldRestartChatRealtime {
            Task { @MainActor [weak self] in
                await Task.yield()
                await self?.forceRestartChatRealtimeAfterGlobalRetryExhausted(reason: "inboxMaxRetry")
            }
        }
        // Allow ``startInboxRealtimeListenerIfNeeded()`` after disconnect; do not call ``stopInboxRealtimeListener()`` here
        // (that would deadlock while awaiting this same task).
    }

    /// Read cursor changes (mark-read) do not emit `direct_messages` rows; listen for lightweight RPC recount instead of reloading the inbox.
    private func consumeConversationReadStateRealtime(_ stream: AsyncStream<AnyAction>) async {
        for await action in stream {
            if Task.isCancelled { break }
            switch action {
            case .insert, .update, .delete:
                #if DEBUG
                let eventType: String
                switch action {
                case .insert: eventType = "insert"
                case .update: eventType = "update"
                case .delete: eventType = "delete"
                }
                print("[RealtimeChainDebug] eventReceived table=conversation_read_state eventType=\(eventType) rowId=unknown")
                print("[RealtimeChainDebug] eventMatchedCurrentView table=conversation_read_state matched=unknown reason=unfilteredBadgeListenerReliesOnRLS")
                #endif
                scheduleDebouncedUnreadDirectMessageRPCRefresh()
            }
        }
    }

    private func consumeInboxDirectMessageInserts(_ inserts: AsyncStream<InsertAction>, me: UUID) async {
        for await insertion in inserts {
            if Task.isCancelled { break }
            do {
                try Task.checkCancellation()
            } catch {
                break
            }
            let row: DirectMessageRow
            do {
                row = try insertion.decodeRecord(as: DirectMessageRow.self, decoder: JSONDecoder())
            } catch {
                continue
            }

            if row.deleted_at != nil {
                DMRealtimeDiagnostics.debug("ignoredReason=deleted messageId=\(row.id.uuidString.lowercased())")
                continue
            }
            if row.is_deleted == true {
                DMRealtimeDiagnostics.debug("ignoredReason=deleted messageId=\(row.id.uuidString.lowercased())")
                continue
            }
            let identity = dmRealtimeIdentitySnapshot(fallbackAuthUserId: me)
            DMRealtimeDiagnostics.debug(
                "insertReceived messageId=\(row.id.uuidString.lowercased()) senderId=\(row.sender_id.uuidString.lowercased()) conversationId=\(row.conversation_id?.uuidString.lowercased() ?? "nil")"
            )
            if isCurrentDMRealtimeIdentity(row.sender_id, fallbackAuthUserId: me) {
                DMRealtimeDiagnostics.debug(
                    "ignoredReason=selfEcho messageId=\(row.id.uuidString.lowercased()) accountType=\(identity.accountType)"
                )
                continue
            }
#if DEBUG
            if let cid = row.conversation_id {
                dmLatencyInboxEventStartByConversationID[cid] = CFAbsoluteTimeGetCurrent()
            }
            print("[DMRealtimeLatencyDebug] realtimeInsertReceived conversationId=\(row.conversation_id?.uuidString.lowercased() ?? "nil") messageId=\(row.id.uuidString.lowercased()) elapsedSinceSendMs=nil")
            RealtimeHealthDiagnostics.log("eventReceived table=direct_messages id=\(row.id.uuidString.lowercased()) elapsedSinceInsertMs=nil")
            DMRealtimeDiagnostics.log(
                "phase=receiver_inbox_realtime_callback_fired messageId=\(row.id.uuidString.lowercased()) sender=\(row.sender_id.uuidString.lowercased()) conversation=\(row.conversation_id?.uuidString.lowercased() ?? "nil")"
            )
#endif
            if isEitherDirectionBlocked(with: row.sender_id) {
                DMRealtimeDiagnostics.debug("ignoredReason=blocked messageId=\(row.id.uuidString.lowercased())")
                #if DEBUG
                print("[ChatRealtime] inbox INSERT id=\(row.id) sender=\(row.sender_id) → skip(blocked)")
                #endif
                continue
            }

            #if DEBUG
            print("[ChatRealtime] inbox INSERT id=\(row.id) conv=\(row.conversation_id?.uuidString ?? "nil") sender=\(row.sender_id)")
            #endif

            let patched = await applyRealtimeIncomingPeerMessage(row)
            DMRealtimeDiagnostics.debug(
                "insertMatchedThread=\(patched) messageId=\(row.id.uuidString.lowercased()) conversationId=\(row.conversation_id?.uuidString.lowercased() ?? "nil")"
            )
            maybeEmitDmInAppNotification(row: row, me: me)
            if patched {
                DMRealtimeDiagnostics.debug("ignoredReason=none messageId=\(row.id.uuidString.lowercased())")
#if DEBUG
                print("[UnreadStateDebug] incomingInsert source=localRealtimePatch action=keptLocalUnread")
#endif
            } else {
#if DEBUG
                print("[UnreadStateDebug] incomingInsert source=missingLocalRow action=serverRecountAndInboxReconcile")
#endif
                scheduleDebouncedUnreadDirectMessageRPCRefresh()
                scheduleLightweightInboxReconcile(delayNanoseconds: 600_000_000)
            }
        }
    }

    /// Called from ``DirectChatPresenter`` after flushes read cursor for an incoming peer message (no full inbox fetch).
    func notifyIncomingDmHandledInActiveThread() {
        requestBadgeRecalculation(reason: "active_thread_incoming_handled")
    }

    /// Coalesces server unread recount RPC after local patches (low latency).
    private func scheduleDebouncedUnreadDirectMessageRPCRefresh() {
        #if DEBUG
        print("[RealtimeChainDebug] refreshQueued table=conversation_read_state reason=debounced_unread_rpc")
        #endif
        requestBadgeRecalculation(reason: "debounced_unread_rpc", delayNanoseconds: 110_000_000)
    }

    private func isUserViewingThisDmThread(conversationId: UUID?, peerSenderId _: UUID) -> Bool {
        guard let conversationId else { return false }
        return activeVisibleConversationId == conversationId
    }

    private func maybeEmitDmInAppNotification(row: DirectMessageRow, me: UUID) {
        guard !isCurrentDMRealtimeIdentity(row.sender_id, fallbackAuthUserId: me) else { return }
        guard !isUserViewingThisDmThread(conversationId: row.conversation_id, peerSenderId: row.sender_id) else {
#if DEBUG
            print("[DMInAppNotificationDebug] conversationId=\(row.conversation_id?.uuidString ?? "nil")")
            print("[DMInAppNotificationDebug] sender=\(row.sender_id.uuidString)")
            print("[DMInAppNotificationDebug] shouldShow=false")
            print("[DMInAppNotificationDebug] reason=thread_already_open")
#endif
            return
        }
        let previewFromFriendRow = friends.first(where: { $0.id == row.sender_id })?.preview
        let senderPreview = previewFromFriendRow
            ?? deletedUserPreview(userId: row.sender_id)
        let trimmed = row.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = trimmed.isEmpty ? "New message" : String(trimmed.prefix(120))
        dmInAppNotification = DmInAppNotificationPayload(
            id: row.id,
            conversationId: row.conversation_id,
            senderPreview: senderPreview,
            bodyPreview: snippet
        )
#if DEBUG
        print("[DMInAppNotificationDebug] conversationId=\(row.conversation_id?.uuidString ?? "nil")")
        print("[DMInAppNotificationDebug] sender=\(senderPreview.displayName)")
        print("[DMInAppNotificationDebug] shouldShow=true")
        print("[DMInAppNotificationDebug] reason=incoming_peer_dm_background")
#endif
    }

    /// Zeros this peer’s row in the local inbox immediately after opening a thread / mark-read so the tab badge drops before summaries refetch.
    func markDirectInboxReadLocally(peerUserId: UUID, conversationId: UUID? = nil) {
#if DEBUG
        print("[BadgeSyncDebug] marked read conversationId=\(conversationId?.uuidString.lowercased() ?? "nil")")
#endif
        guard let idx = friends.firstIndex(where: { $0.id == peerUserId }) else {
            requestBadgeRecalculation(reason: "marked_read_missing_row")
            return
        }
        let old = friends[idx]
        guard old.unreadCount > 0 else {
            requestBadgeRecalculation(reason: "marked_read_no_local_unread")
            return
        }
#if DEBUG
        print("[UnreadBadgeDebug] conversationId=local_mark_read")
        print("[UnreadBadgeDebug] oldUnread=\(old.unreadCount)")
        print("[UnreadBadgeDebug] newUnread=0")
#endif
        let updated = FriendDisplay(
            id: old.id,
            preview: old.preview,
            subtitle: old.subtitle,
            lastMessageAt: old.lastMessageAt,
            unreadCount: 0,
            isConversationBacked: old.isConversationBacked
        )
        var next = friends
        next[idx] = updated
        friends = next
#if DEBUG
        print("[BadgeSyncDebug] chat list updated")
#endif
        let totalUnread = next.reduce(0) { $0 + $1.unreadCount }
#if DEBUG
        print("[UnreadBadgeDebug] totalBadge=\(totalUnread)")
#endif
        Task { await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread, source: "local_mark_read") }
        requestBadgeRecalculation(reason: "marked_read")
    }

    /// Applies a lightweight inbox row update for an incoming peer DM (1:1). Returns false if a full inbox reconcile should run.
    private func applyRealtimeIncomingPeerMessage(_ row: DirectMessageRow) async -> Bool {
        let peerId = row.sender_id
        let viewing = isUserViewingThisDmThread(conversationId: row.conversation_id, peerSenderId: peerId)
        let badgeBefore = unreadDirectMessageCount
#if DEBUG
        let applyStartedAt = CFAbsoluteTimeGetCurrent()
        RealtimeHealthDiagnostics.log("mainActorApplyStart=direct_messages_inbox id=\(row.id.uuidString.lowercased())")
        print("[BadgeReceiveDebug] incomingDM conversationId=\(row.conversation_id?.uuidString.lowercased() ?? "nil")")
        print("[BadgeReceiveDebug] activeVisibleConversationId=\(activeVisibleConversationId?.uuidString.lowercased() ?? "nil")")
        print("[BadgeReceiveDebug] isExactVisibleThread=\(viewing)")
        print("[BadgeReceiveDebug] shouldCountUnread=\(!viewing)")
        print("[BadgeReceiveDebug] badgeBefore=\(badgeBefore)")
        print("[BadgeReceiveDebug] actor=MainActor")
#endif

        guard let idx = friends.firstIndex(where: { $0.id == peerId }) else {
            DMRealtimeDiagnostics.debug(
                "ignoredReason=missingInboxRow messageId=\(row.id.uuidString.lowercased()) senderId=\(peerId.uuidString.lowercased()) activeThread=\(viewing)"
            )
#if DEBUG
            print("[BadgeReceiveDebug] skipped reason=missing_inbox_row")
#endif
            return false
        }

        let old = friends[idx]
        let body = row.body.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let rawPreview: String
        if body.isEmpty {
            rawPreview = "Say hi"
        } else {
            rawPreview = body
        }
        let lastAt = Self.parseISO8601(row.created_at) ?? Date()
        let newUnread: Int
        if viewing {
            newUnread = 0
        } else {
            newUnread = old.unreadCount + 1
        }
#if DEBUG
        print("[UnreadBadgeDebug] conversationId=\(row.conversation_id?.uuidString ?? "nil")")
        print("[UnreadBadgeDebug] oldUnread=\(old.unreadCount)")
        print("[UnreadBadgeDebug] newUnread=\(newUnread)")
#endif
        let updated = FriendDisplay(
            id: old.id,
            preview: old.preview,
            subtitle: rawPreview,
            lastMessageAt: lastAt,
            unreadCount: newUnread,
            isConversationBacked: true
        )
        var next = friends
        next[idx] = updated
        next.sort { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
        friends = next
        syncChatPresenceRealtimeIfNeeded(reason: "incomingDmPatchedInbox")
#if DEBUG
        print("[BadgeSyncDebug] chat list updated")
        let inboxElapsedStart = row.conversation_id.flatMap { dmLatencyInboxEventStartByConversationID[$0] }
        let inboxElapsed = inboxElapsedStart.map { String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? "nil"
        print("[DMRealtimeLatencyDebug] inboxUpdated conversationId=\(row.conversation_id?.uuidString.lowercased() ?? "nil") elapsedMs=\(inboxElapsed)")
#endif
        let totalUnread = next.reduce(0) { $0 + $1.unreadCount }
#if DEBUG
        print("[UnreadBadgeDebug] totalBadge=\(totalUnread)")
#endif
        await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread, source: viewing ? "incoming_visible_thread" : "incoming_realtime_local_increment")
#if DEBUG
        print("[BadgeReceiveDebug] badgeAfter=\(totalUnread)")
        RealtimeHealthDiagnostics.log("mainActorApplyEnd elapsedMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - applyStartedAt) * 1000)) table=direct_messages_inbox id=\(row.id.uuidString.lowercased())")
#endif
        requestBadgeRecalculation(reason: "incoming_message")
        return true
    }

    private func stopInboxRealtimeListener() async {
#if DEBUG
        print("[RealtimeLifecycle] stopping inbox listener")
#endif
        inboxUnreadDebounceTask?.cancel()
        inboxUnreadDebounceTask = nil
        inboxMissingPeerReconcileTask?.cancel()
        inboxMissingPeerReconcileTask = nil
        if let task = inboxListenTask {
            task.cancel()
            _ = await task.result
            inboxListenTask = nil
        }

        await removeInboxRealtimeChannelOnly()
    }

    private func removeFriendshipsChannelOnly() async {
        if let ch = friendshipsChannel {
            await supabase.removeChannel(ch)
        }
        friendshipsChannel = nil
        friendshipsRealtimeBoundUserId = nil
    }

    private func startFriendshipsRealtimeListenerIfNeeded() {
        guard friendshipsListenTask == nil, friendshipsChannel == nil else {
#if DEBUG
            print("[RealtimeLifecycle] duplicate prevented (friendship listener already active)")
#endif
            return
        }
        guard requiresSignIn == false else { return }
#if DEBUG
        print("[RealtimeLifecycle] starting friendship listener")
#endif
        friendshipsListenTask = Task { [weak self] in
            guard let self else { return }
            await self.runFriendshipsRealtimeListenerLoop()
        }
    }

    private func runFriendshipsRealtimeListenerLoop() async {
        defer {
            friendshipsListenTask = nil
        }

        let me: UUID
        if let cached = currentUserAuthId {
            me = cached
        } else if let fetched = try? await service.currentUserId() {
            me = fetched
        } else {
            return
        }

#if DEBUG
        print("[FriendRequestRealtime] friendship channel bound user=\(me.uuidString.lowercased())")
#endif

        let channel = supabase.channel("friendships-\(me.uuidString.lowercased())")
        friendshipsChannel = channel

        let changes = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "friendships"
        )

        defer {
            friendRequestRealtimeDebounceTask?.cancel()
            friendRequestRealtimeDebounceTask = nil
        }

        var shouldRestartChatRealtime = false
        do {
            try await channel.subscribeWithError()
            friendshipsRealtimeBoundUserId = me

            for await action in changes {
                if Task.isCancelled { break }
                try Task.checkCancellation()
                switch action {
                case .insert, .update, .delete:
                    logFriendRequestRealtimeCancelledIfNeeded(action)
#if DEBUG
                    print("[FriendRequestRealtime] event received")
#endif
                    scheduleFriendRequestRealtimeRefresh()
                }
            }
        } catch {
            if !(error is CancellationError) {
#if DEBUG
                print("[FriendRequestRealtime] subscribe/stream error: \(error)")
                print("[RealtimeLifecycle] friendship listener ended with error")
#endif
                shouldRestartChatRealtime = realtimeErrorIndicatesGlobalRetryExhausted(error)
            }
        }

        await removeFriendshipsChannelOnly()
        if shouldRestartChatRealtime {
            Task { @MainActor [weak self] in
                await Task.yield()
                await self?.forceRestartChatRealtimeAfterGlobalRetryExhausted(reason: "friendshipsMaxRetry")
            }
        }
    }

    private func logFriendRequestRealtimeCancelledIfNeeded(_ action: AnyAction) {
        guard case let .update(u) = action else { return }
        guard let raw = u.record["status"] else { return }
        let lowered: String?
        switch raw {
        case let .string(s):
            lowered = s.lowercased()
        default:
            lowered = nil
        }
        if lowered == "cancelled" {
#if DEBUG
            print("[FriendRequestRealtime] cancelled request received")
#endif
        }
    }

    private func scheduleFriendRequestRealtimeRefresh() {
        friendRequestRealtimeDebounceTask?.cancel()
        friendRequestRealtimeDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
#if DEBUG
            print("[FriendRequestRealtime] refreshing requests")
#endif
            await self.refreshFriendRequestListsOnly()
#if DEBUG
            print("[FriendRequestRealtime] badge updated pending=\(self.pendingBadgeCount)")
#endif
        }
    }

    private func stopFriendshipsRealtimeListener() async {
        friendRequestRealtimeDebounceTask?.cancel()
        friendRequestRealtimeDebounceTask = nil

        if let task = friendshipsListenTask {
            task.cancel()
            _ = await task.result
            friendshipsListenTask = nil
        }

        await removeFriendshipsChannelOnly()
        friendshipsRealtimeBoundUserId = nil
#if DEBUG
        print("[RealtimeLifecycle] stopping friendship listener")
#endif
    }

    /// Refreshes friend request rows + chip map + pending badge without reloading DM inbox.
    func refreshFriendRequestListsOnly() async {
        let startedAt = Date()
        guard let me = try? await service.currentUserId() else {
            clearForSignOut()
            print("[NotificationPerf] chatFriendRequestsSkipped reason=missingSession")
            return
        }
        noteAuthenticatedChatSession(userId: me, source: "friendRequests")
        await reloadModerationBlockSets()
        do {
            async let accepted = service.fetchAcceptedFriendships(for: me)
            async let incomingRows = service.fetchIncomingFriendRequestsVisible(for: me)
            async let outgoingRows = service.fetchOutgoingFriendRequestsVisible(for: me)
            let (accRows, inRows, outRows) = try await (accepted, incomingRows, outgoingRows)

            let previewIds = Set(
                inRows.map(\.requester_id)
                    + outRows.map(\.addressee_id)
            )
            let previewsById = try await socialIdentityService.fetchUserPreviews(for: Array(previewIds))

            incomingRequests = inRows
                .filter { !isEitherDirectionBlocked(with: $0.requester_id) }
                .map { row in
                    let preview = previewsById[row.requester_id] ?? deletedUserPreview(userId: row.requester_id)
                    return IncomingRequestDisplay(friendship: row, requester: preview)
                }

            outgoingRequests = outRows
                .filter { !isEitherDirectionBlocked(with: $0.addressee_id) }
                .map { row in
                    let preview = previewsById[row.addressee_id] ?? deletedUserPreview(userId: row.addressee_id)
                    return OutgoingRequestDisplay(friendship: row, addressee: preview)
                }

            pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
            print("[NotificationPerf] chatFriendRequestsFinished durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) pending=\(pendingBadgeCount)")
#if DEBUG
            print("[BadgeSyncDebug] tab badge updated")
#endif
            noteAuthenticatedChatSession(userId: me, source: "friendRequestsLoaded")
            applyFriendshipChipStates(me: me, accepted: accRows, incoming: inRows, outgoing: outRows)
        } catch {
            // Keep existing lists; next refresh or realtime will retry.
            print("[NotificationPerf] chatFriendRequestsFailed durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) error=\(error.localizedDescription)")
        }
    }

    /// Refreshes the Chat tab badge for unread peer DMs (no friendship / request counts).
    func refreshUnreadDirectMessageCount() async {
        let startedAt = Date()
        guard let me = try? await directChatService.currentUserId() else {
            clearForSignOut()
            print("[NotificationPerf] chatUnreadSkipped reason=missingSession")
            return
        }
        noteAuthenticatedChatSession(userId: me, source: "unreadDirectMessageCount")
        let prior = unreadDirectMessageCount
        #if DEBUG
        print("[RealtimeChainDebug] refreshStarted table=conversation_read_state key=unreadDirectMessageCount")
        #endif
        guard let n = try? await directChatService.fetchUnreadDirectMessageCount(currentUserId: me) else {
            print("[NotificationPerf] chatUnreadFailed durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            return
        }
        await setUnreadDirectMessageCountAndSyncAppIcon(n, source: "rpc_total_refresh")
        print("[NotificationPerf] chatUnreadFinished durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) unread=\(n)")
#if DEBUG
        print("[RealtimeChainDebug] refreshSucceeded table=conversation_read_state key=unreadDirectMessageCount")
        print("[UnreadBadgeDebug] conversationId=rpc_total_refresh")
        print("[UnreadBadgeDebug] oldUnread=\(prior)")
        print("[UnreadBadgeDebug] newUnread=\(n)")
        print("[UnreadBadgeDebug] totalBadge=\(n)")
#endif
    }

    /// Launch warm path: refreshes only the DM unread badge and inbox summaries, never message bodies.
    func prefetchLightweightStartupChatData() async -> StartupChatPrefetchResult {
        if let inFlight = startupLightweightPrefetchTask {
            print("[NotificationPerf] chatStartupPrefetchCoalesced=true")
#if DEBUG
            print("[StartupPrefetchDebug] skippedReason=chatInFlight")
#endif
            return await inFlight.value
        }
        if let lastStartupLightweightPrefetchAt,
           Date().timeIntervalSince(lastStartupLightweightPrefetchAt) < startupLightweightPrefetchTTL {
            print("[NotificationPerf] chatStartupPrefetchSkipped reason=freshCache")
#if DEBUG
            print("[StartupPrefetchDebug] skippedReason=chatFreshCache")
#endif
            return StartupChatPrefetchResult(
                dmBadgePrefetched: true,
                inboxSummariesPrefetched: true,
                skippedReason: "chatFreshCache"
            )
        }

        let task = Task<StartupChatPrefetchResult, Never> { [weak self] in
            guard let self else {
                return StartupChatPrefetchResult(
                    dmBadgePrefetched: false,
                    inboxSummariesPrefetched: false,
                    skippedReason: "chatViewModelReleased"
                )
            }
            return await self.runLightweightStartupChatPrefetch()
        }
        startupLightweightPrefetchTask = task
        let startedAt = Date()
        let result = await task.value
        startupLightweightPrefetchTask = nil
        if result.skippedReason == nil {
            lastStartupLightweightPrefetchAt = Date()
        }
        print("[NotificationPerf] chatStartupPrefetchFinished durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) skippedReason=\(result.skippedReason ?? "none")")
        return result
    }

    private func runLightweightStartupChatPrefetch() async -> StartupChatPrefetchResult {
        guard (try? await directChatService.currentUserId()) != nil else {
            clearForSignOut()
            return StartupChatPrefetchResult(
                dmBadgePrefetched: false,
                inboxSummariesPrefetched: false,
                skippedReason: "chatMissingSession"
            )
        }

        await refreshUnreadDirectMessageCount()
        await refreshInboxSummariesIfNeeded()
        return StartupChatPrefetchResult(
            dmBadgePrefetched: true,
            inboxSummariesPrefetched: true,
            skippedReason: nil
        )
    }

    /// Loads friends and requests; coalesces rapid repeats.
    func loadIfNeeded() async {
        if isLoading { return }
        if let last = lastLoadAt, Date().timeIntervalSince(last) < minRefreshInterval {
            return
        }
        await refresh()
    }

    /// Refreshes Chat → Friends inbox summaries (preview/time/unread + sorted order) without reloading requests.
    func refreshInboxSummariesIfNeeded() async {
        if isLoading { return }
        if let last = lastInboxLoadAt, Date().timeIntervalSince(last) < minInboxRefreshInterval {
            return
        }
        await refreshInboxSummaries()
    }

    func refreshInboxSummaries() async {
        let refreshStartedAt = CFAbsoluteTimeGetCurrent()
        guard let me = try? await directChatService.currentUserId() else {
            clearForSignOut()
            return
        }
        noteAuthenticatedChatSession(userId: me, source: "inboxSummaries")
        await reloadModerationBlockSets()
        do {
            let rows = try await directChatService.fetchInboxSummaries()
            let participantPreviews = try await fetchDmParticipantPreviews(for: rows)
            let displays = rows.map { row -> FriendDisplay in
                let preview = inboxPreview(
                    for: row,
                    resolvedPreview: participantPreviews[row.friend_user_id],
                    profileLookupAttempted: true
                )
                logChatRowDebug(preview: preview)
                logDeletedUserRenderDebug(surface: "dm_inbox", preview: preview)

                let body = row.last_message_body?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let rawPreview: String
                if let body, !body.isEmpty {
                    if row.last_message_sender_id == me {
                        rawPreview = "You: \(body)"
                    } else {
                        rawPreview = body
                    }
                } else {
                    rawPreview = "Say hi"
                }

                let lastAt = Self.parseISO8601(row.last_message_created_at)
                let unread = max(0, row.unread_count ?? 0)
                return FriendDisplay(
                    id: row.friend_user_id,
                    preview: preview,
                    subtitle: rawPreview,
                    lastMessageAt: lastAt,
                    unreadCount: unread,
                    isConversationBacked: true
                )
            }

            // Hide users blocked in either direction.
            var visible = displays.filter { !isEitherDirectionBlocked(with: $0.id) }
            visible = try await mergeAcceptedFriendsMissingFromInbox(me: me, inboxDisplays: visible)
            friends = visible
            syncChatPresenceRealtimeIfNeeded(reason: "inboxSummariesLoaded")
#if DEBUG
            print("[BadgeSyncDebug] chat list updated")
            let elapsed = String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - refreshStartedAt) * 1000)
            print("[DMRealtimeLatencyDebug] inboxUpdated conversationId=refresh_inbox_summaries elapsedMs=\(elapsed)")
#endif
            let totalUnread = visible.reduce(0) { $0 + $1.unreadCount }
            await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread, source: "refresh_inbox_summaries")
            lastInboxLoadAt = Date()
            noteAuthenticatedChatSession(userId: me, source: "inboxSummariesLoaded")
        } catch {
            // Keep existing list on transient failures; unread badge may be stale until next refresh.
        }
    }

    // MARK: - Blocked Users management

    func refreshBlockedUsers() async {
        do {
            blockedUserIds = try await moderation.fetchBlockedUserIds()
            usersWhoBlockedMeIds = try await moderation.fetchUsersWhoBlockedMeIds()
            let previews = await moderation.fetchUserPreviews(for: Array(blockedUserIds))
            // Keep stable order.
            let byId = Dictionary(uniqueKeysWithValues: previews.map { ($0.id, $0) })
            blockedUserPreviews = Array(blockedUserIds).compactMap { byId[$0] }.sorted { $0.displayName < $1.displayName }
        } catch {
            blockedUserIds = []
            usersWhoBlockedMeIds = []
            blockedUserPreviews = []
        }
    }

    func unblockUser(_ userId: UUID) async {
        do {
            try await moderation.unblock(userId: userId)
            await refreshBlockedUsers()
            await refreshInboxSummaries()
        } catch {
            // Keep UI lightweight; surface errors only if needed later.
        }
    }

    /// Swipe-delete from inbox: calls the same `clear_direct_conversation` RPC as in-thread “Clear chat history”.
    /// Does not remove the friendship; only clears/hides the thread per server rules.
    func clearInboxConversation(withFriendUserId friendUserId: UUID) async {
        let snapshot = friends
        inboxDeleteError = nil
        do {
            let cid = try await directChatService.startDirectConversation(friendUserId: friendUserId)
            try await directChatService.clearDirectConversation(conversationId: cid)
            friends.removeAll { $0.id == friendUserId }
            let totalUnread = friends.reduce(0) { $0 + $1.unreadCount }
            await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread, source: "clear_inbox_conversation")
            await refreshInboxSummaries()
        } catch {
            friends = snapshot
            if ignoreCancellationIfNeeded(error, context: "inbox_delete") { return }
            inboxDeleteError = error.localizedDescription
        }
    }

    func previewForLoadedDmParticipant(userId: UUID) -> UserPreview? {
        friends.first(where: { $0.id == userId })?.preview
    }

    func resolveDmParticipantPreview(
        userId: UUID,
        fallback: UserPreview,
        surface: String
    ) async -> UserPreview {
        if fallback.isDeleted {
            logDeletedUserRenderDebug(surface: surface, preview: fallback)
            return fallback
        }

        do {
            if let resolved = try await socialIdentityService.fetchUserPreviews(for: [userId])[userId] {
                logDeletedUserRenderDebug(surface: surface, preview: resolved)
                patchLoadedDmParticipantPreview(resolved)
                return resolved
            }
        } catch {
            // Treat unresolved fan identities as deleted for DM presentation; the messages remain intact.
        }

        let deleted = deletedUserPreview(userId: userId, email: fallback.email)
        logDeletedUserRenderDebug(surface: surface, preview: deleted)
        patchLoadedDmParticipantPreview(deleted)
        return deleted
    }

    func refreshDirectChatPresencePreview(
        userId: UUID,
        fallback: UserPreview,
        source: String
    ) async -> UserPreview? {
        do {
            guard let resolved = try await socialIdentityService.fetchUserPreviews(for: [userId])[userId] else {
                return nil
            }
            patchLoadedDmParticipantPreview(resolved)
            return resolved
        } catch {
#if DEBUG
            print("[PresenceDebug] directChatPresenceRefreshFailed=true friendId=\(userId.uuidString.lowercased()) presenceSource=\(source) error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    /// Same RPC path as ``DirectChatView`` / inbox rows: returns an existing peer DM conversation id or creates one (no duplicate threads).
    func startDirectConversationWithFriend(friendUserId: UUID) async throws -> UUID {
        try await directChatService.startDirectConversation(friendUserId: friendUserId)
    }

    func refresh() async {
        let fullRefreshStartedAt = CFAbsoluteTimeGetCurrent()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let me = try await service.currentUserId()
            if let priorMe = currentUserAuthId, priorMe != me {
                await stopInboxRealtimeListener()
                await stopFriendshipsRealtimeListener()
            }
            noteAuthenticatedChatSession(userId: me, source: "fullRefresh")
            await reloadModerationBlockSets()
            async let accepted = service.fetchAcceptedFriendships(for: me)
            async let incoming = service.fetchIncomingFriendRequestsVisible(for: me)
            async let outgoing = service.fetchOutgoingFriendRequestsVisible(for: me)
            async let inbox = directChatService.fetchInboxSummaries()
            let (accRows, inRows, outRows, inboxRows) = try await (accepted, incoming, outgoing, inbox)
            let participantPreviews = try await fetchDmParticipantPreviews(for: inboxRows)

            let previewIds = Set(
                inRows.map(\.requester_id)
                    + outRows.map(\.addressee_id)
            )
            let previewsById = try await socialIdentityService.fetchUserPreviews(for: Array(previewIds))

            let inboxFiltered = inboxRows.filter { !isEitherDirectionBlocked(with: $0.friend_user_id) }
            var friendDisplays = inboxFiltered.map { row -> FriendDisplay in
                let preview = inboxPreview(
                    for: row,
                    resolvedPreview: participantPreviews[row.friend_user_id],
                    profileLookupAttempted: true
                )
                logChatRowDebug(preview: preview)
                logDeletedUserRenderDebug(surface: "dm_inbox", preview: preview)

                let body = row.last_message_body?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let rawPreview: String
                if let body, !body.isEmpty {
                    if row.last_message_sender_id == me {
                        rawPreview = "You: \(body)"
                    } else {
                        rawPreview = body
                    }
                } else {
                    rawPreview = "Say hi"
                }

                let lastAt = Self.parseISO8601(row.last_message_created_at)
                let unread = max(0, row.unread_count ?? 0)
                return FriendDisplay(
                    id: row.friend_user_id,
                    preview: preview,
                    subtitle: rawPreview,
                    lastMessageAt: lastAt,
                    unreadCount: unread,
                    isConversationBacked: true
                )
            }
            friendDisplays = try await mergeAcceptedFriendsMissingFromInbox(me: me, inboxDisplays: friendDisplays)
            friends = friendDisplays
            syncChatPresenceRealtimeIfNeeded(reason: "fullRefreshLoaded")
#if DEBUG
            print("[BadgeSyncDebug] chat list updated")
            let fullRefreshElapsed = String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - fullRefreshStartedAt) * 1000)
            print("[DMRealtimeLatencyDebug] inboxUpdated conversationId=full_refresh elapsedMs=\(fullRefreshElapsed)")
#endif

            incomingRequests = inRows
                .filter { !isEitherDirectionBlocked(with: $0.requester_id) }
                .map { row in
                let preview = previewsById[row.requester_id] ?? deletedUserPreview(userId: row.requester_id)
                return IncomingRequestDisplay(friendship: row, requester: preview)
            }

            outgoingRequests = outRows
                .filter { !isEitherDirectionBlocked(with: $0.addressee_id) }
                .map { row in
                let preview = previewsById[row.addressee_id] ?? deletedUserPreview(userId: row.addressee_id)
                return OutgoingRequestDisplay(friendship: row, addressee: preview)
            }

            pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
#if DEBUG
            print("[BadgeSyncDebug] tab badge updated")
#endif
            requiresSignIn = false
            lastLoadAt = Date()
            lastInboxLoadAt = Date()
            noteAuthenticatedChatSession(userId: me, source: "fullRefreshLoaded")
            applyFriendshipChipStates(
                me: me,
                accepted: accRows,
                incoming: inRows,
                outgoing: outRows
            )
            let totalUnread = friends.reduce(0) { $0 + $1.unreadCount }
            await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread, source: "full_refresh")
            await ensureSignedInSocialRealtimeIfNeeded()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "chat_full_refresh") { return }
            friends = []
            incomingRequests = []
            outgoingRequests = []
            pendingBadgeCount = 0
            friendshipChipByOtherUserId = [:]
            currentUserAuthId = nil
            let msg = error.localizedDescription
            if msg.localizedCaseInsensitiveContains("session")
                || msg.localizedCaseInsensitiveContains("jwt")
                || msg.localizedCaseInsensitiveContains("not authenticated") {
                clearForSignOut()
            } else {
                requiresSignIn = false
                errorMessage = msg
                lastLoadAt = Date()
            }
        }
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: raw) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: raw)
    }

    func accept(_ item: IncomingRequestDisplay) async {
        do {
            let friendship = try await service.acceptFriendRequest(requestId: item.friendship.id)
            await refresh()
            await awardFriendConnectedXP(friendship: friendship)
        } catch {
            if ignoreCancellationIfNeeded(error, context: "friend_request_accept") { return }
            errorMessage = error.localizedDescription
        }
    }

    private func awardFriendConnectedXP(friendship: FriendshipRow) async {
        guard let map = mapViewModel else { return }
        guard let me = try? await service.currentUserId() else { return }
        let otherId = friendship.requester_id == me ? friendship.addressee_id : friendship.requester_id
        await map.awardFanXP(
            userId: me,
            amount: 5,
            source: FanXPSource.friendConnected,
            sourceId: friendship.id
        )
        await map.awardFanXP(
            userId: otherId,
            amount: 5,
            source: FanXPSource.friendConnected,
            sourceId: friendship.id,
            showToast: false
        )
    }

    func reject(_ item: IncomingRequestDisplay) async {
        let responded = ISO8601DateFormatter().string(from: Date())
        let optimistic = item.friendship.withDeclinedNow(respondedAt: responded)
        let snapshot = incomingRequests
        if let idx = incomingRequests.firstIndex(where: { $0.id == item.id }) {
            var next = incomingRequests
            next[idx] = IncomingRequestDisplay(friendship: optimistic, requester: item.requester)
            incomingRequests = next
        }
        pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
        let rid = item.requester.id
        if friendshipChipByOtherUserId[rid] == .pendingIncoming {
            var m = friendshipChipByOtherUserId
            m.removeValue(forKey: rid)
            friendshipChipByOtherUserId = m
        }
        do {
            try await service.rejectFriendRequest(requestId: item.friendship.id)
            await refreshFriendRequestListsOnly()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "friend_request_reject") {
                incomingRequests = snapshot
                pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
                return
            }
            incomingRequests = snapshot
            pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
            errorMessage = error.localizedDescription
            await refreshFriendRequestListsOnly()
        }
    }

    /// Clears a **declined** incoming request from the receiver’s list (soft-dismiss on server).
    func clearIncomingDeclinedRequest(_ item: IncomingRequestDisplay) async {
        guard item.friendship.isDeclinedStatus else { return }
        DebugLogGate.debug("[FriendRequest] clear requested id=\(item.id)")
        let snapshot = incomingRequests
        incomingRequests.removeAll { $0.id == item.id }
        pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
        do {
            try await service.clearFriendRequestView(requestId: item.id)
            DebugLogGate.debug("[FriendRequest] clear completed id=\(item.id)")
            await refreshFriendRequestListsOnly()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "friend_request_clear_incoming") {
                incomingRequests = snapshot
                pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
                return
            }
            DebugLogGate.debug("[FriendRequest] clear failed id=\(item.id) error=\(error)")
            incomingRequests = snapshot
            pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
            errorMessage = error.localizedDescription
        }
    }

    /// Clears a **declined** outgoing request from the sender’s list (soft-dismiss on server).
    func clearOutgoingDeclinedRequest(_ item: OutgoingRequestDisplay) async {
        guard item.friendship.isDeclinedStatus else { return }
        DebugLogGate.debug("[FriendRequest] clear requested id=\(item.id)")
        let snapshot = outgoingRequests
        outgoingRequests.removeAll { $0.id == item.id }
        do {
            try await service.clearFriendRequestView(requestId: item.id)
            DebugLogGate.debug("[FriendRequest] clear completed id=\(item.id)")
            await refreshFriendRequestListsOnly()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "friend_request_clear_outgoing") {
                outgoingRequests = snapshot
                return
            }
            DebugLogGate.debug("[FriendRequest] clear failed id=\(item.id) error=\(error)")
            outgoingRequests = snapshot
            errorMessage = error.localizedDescription
        }
    }

    func cancel(_ item: OutgoingRequestDisplay) async {
        guard item.friendship.isPendingStatus else { return }
        DebugLogGate.debug("[FriendRequest] outgoing cancel requested id=\(item.id)")
        let snapshotOut = outgoingRequests
        let snapshotChips = friendshipChipByOtherUserId

        outgoingRequests.removeAll { $0.id == item.id }
        let peerId = item.addressee.id
        if friendshipChipByOtherUserId[peerId] == .pendingOutgoing {
            var m = friendshipChipByOtherUserId
            m.removeValue(forKey: peerId)
            friendshipChipByOtherUserId = m
        }

        do {
            try await service.cancelFriendRequest(requestId: item.friendship.id)
            DebugLogGate.debug("[FriendRequest] outgoing cancel completed id=\(item.id)")
            await refreshFriendRequestListsOnly()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "friend_request_cancel") {
                outgoingRequests = snapshotOut
                friendshipChipByOtherUserId = snapshotChips
                return
            }
            DebugLogGate.debug("[FriendRequest] outgoing cancel failed id=\(item.id) error=\(error)")
            outgoingRequests = snapshotOut
            friendshipChipByOtherUserId = snapshotChips
            errorMessage = error.localizedDescription
            await refreshFriendRequestListsOnly()
        }
    }

    func sendFriendRequest(to addresseeId: UUID) async {
        if isEitherDirectionBlocked(with: addresseeId) {
            errorMessage = "You can’t send a friend request to this user."
            return
        }
        do {
            let me = try await service.currentUserId()
            try await service.sendFriendRequest(requesterId: me, addresseeId: addresseeId)
            await refreshFriendRequestListsOnly()
        } catch {
            if ignoreCancellationIfNeeded(error, context: "friend_request_send") { return }
            errorMessage = error.localizedDescription
        }
    }

    func refreshAddFriendSearch(query raw: String) async {
        let normalized = FriendshipService.normalizedFriendLookupQuery(raw)
        guard !normalized.isEmpty else {
            addFriendSearchResults = []
            return
        }
        addFriendSearchIsLoading = true
        defer { addFriendSearchIsLoading = false }
        do {
            let me = try await service.currentUserId()
            addFriendSearchResults = try await service.searchAddFriendTargets(
                normalizedQuery: normalized,
                excludingUserId: me
            )
        } catch {
            addFriendSearchResults = []
        }
    }

    func clearAddFriendSearch() {
        addFriendSearchResults = []
        addFriendSearchIsLoading = false
    }

    /// Add friend to a selected search hit (fan user or ``businesses`` row by id).
    func sendFriendRequest(to target: AddFriendSearchTarget) async -> AddFriendLookupOutcome {
#if DEBUG
        print("[FriendSearchDebug] send entity_type=\(target.entityType.rawValue) entity_id=\(target.entityId.uuidString)")
#endif
        do {
            let me = try await service.currentUserId()
            if target.entityType == .user, me == target.entityId {
                return .informational("Cannot add yourself. Use another fan or business.")
            }

            let rows = try await service.fetchFriendships(for: target, me: me)
            let relation = FriendshipService.classifyExistingRelation(me: me, rows: rows)
            if let message = FriendshipService.userFacingMessageForExistingRelation(relation) {
                return .informational(message)
            }

            let requesterEntity = (try? await service.fetchSocialEntity(userId: me))
                ?? FriendSocialEntity(id: me, kind: .fanUser)
            let targetEntity = FriendSocialEntity(id: target.entityId, kind: target.socialEntityKind)
#if DEBUG
            FriendshipService.logPendingRelationshipDebug(
                requester: requesterEntity,
                target: targetEntity,
                matchedPending: false,
                friendshipId: nil
            )
#endif

            switch target.entityType {
            case .user:
                try await service.sendFriendRequest(requesterId: me, addresseeId: target.entityId)
            case .business:
                try await service.sendFriendRequestToBusiness(requesterId: me, businessId: target.entityId)
            }
            await refreshAfterFriendLookupAttempt()
            logFriendRequestVisibilityDebug(
                lookupResult: "created",
                targetUserId: target.entityId,
                me: me
            )
            return .success
        } catch {
            await refreshAfterFriendLookupAttempt()
            return await resolveAddFriendLookupOutcomeAfterError(error, target: target)
        }
    }

    /// Legacy path: normalized query only (fan RPC). Prefer ``sendFriendRequest(to:)`` after search.
    func sendFriendRequestByLookup(_ raw: String) async -> AddFriendLookupOutcome {
        let normalized = FriendshipService.normalizedFriendLookupQuery(raw)
        guard !normalized.isEmpty else {
            return .informational("Enter an email or display name.")
        }
        await refreshAddFriendSearch(query: raw)
        if let first = addFriendSearchResults.first {
            return await sendFriendRequest(to: first)
        }
        return .informational("No FanGeo account found with that email or display name.")
    }

    /// Refreshes Chat lists so pending/accepted rows appear immediately after Add Friend (including duplicate path).
    private func refreshAfterFriendLookupAttempt() async {
        await refreshFriendRequestListsOnly()
        await refreshInboxSummaries()
    }

    /// Accepted friends without a DM thread yet still appear in the Friends directory (presentation only; inbox RPC unchanged).
    private func mergeAcceptedFriendsMissingFromInbox(
        me: UUID,
        inboxDisplays: [FriendDisplay]
    ) async throws -> [FriendDisplay] {
        let accepted = try await service.fetchAcceptedFriendships(for: me)
        let inboxIds = Set(inboxDisplays.map(\.id))
        let missingIds: [UUID] = accepted.compactMap { row in
            guard (row.requester_entity_type ?? "user").lowercased() == "user",
                  (row.addressee_entity_type ?? "user").lowercased() == "user" else {
                return nil
            }
            let other = row.requester_id == me ? row.addressee_id : row.requester_id
            guard !inboxIds.contains(other) else { return nil }
            guard !isEitherDirectionBlocked(with: other) else { return nil }
            return other
        }
        guard !missingIds.isEmpty else { return inboxDisplays }

        let previews = try await socialIdentityService.fetchUserPreviews(for: missingIds)
        var merged = inboxDisplays
        for pid in missingIds {
            let preview = previews[pid] ?? deletedUserPreview(userId: pid)
            logDeletedUserRenderDebug(surface: "dm_inbox", preview: preview)
            merged.append(
                FriendDisplay(
                    id: pid,
                    preview: preview,
                    subtitle: "Say hi",
                    lastMessageAt: nil,
                    unreadCount: 0,
                    isConversationBacked: false
                )
            )
        }
        return merged
    }

    private func resolveAddFriendLookupOutcomeAfterError(
        _ error: Error,
        target: AddFriendSearchTarget
    ) async -> AddFriendLookupOutcome {
#if DEBUG
        print("[ChatIdentityDebug] query entity_type=\(target.entityType.rawValue) entity_id=\(target.entityId.uuidString)")
        if let email = target.matchedEmail {
            print("[ChatIdentityDebug] matchedEmail=\(email)")
        }
        print("[ChatIdentityDebug] matchedEntityId=\(target.entityId.uuidString)")
#endif

        var verifiedRelation: FriendLookupExistingRelation = .none

        if let me = try? await service.currentUserId() {
            let requesterEntity = (try? await service.fetchSocialEntity(userId: me))
                ?? FriendSocialEntity(id: me, kind: .fanUser)
            let targetEntity = FriendSocialEntity(id: target.entityId, kind: target.socialEntityKind)

            let exactPending = try? await service.findPendingFriendship(requesterId: me, target: target)
            let rows = (try? await service.fetchFriendships(for: target, me: me)) ?? []
            verifiedRelation = FriendshipService.classifyExistingRelation(me: me, rows: rows)

#if DEBUG
            FriendshipService.logPendingRelationshipDebug(
                requester: requesterEntity,
                target: targetEntity,
                matchedPending: exactPending != nil,
                friendshipId: exactPending?.id
            )
#endif

            if FriendshipService.isDuplicateFriendLookupError(error) {
                logFriendRequestVisibilityDebug(
                    lookupResult: "duplicate",
                    targetUserId: target.entityId,
                    me: me,
                    existingRelation: verifiedRelation
                )

                if let message = FriendshipService.userFacingMessageForExistingRelation(verifiedRelation),
                   FriendshipService.isPendingLikeRelation(verifiedRelation) || verifiedRelation == .accepted {
                    return .informational(message)
                }

                if target.entityType == .user,
                   let email = target.matchedEmail, !email.isEmpty,
                   let sibling = try? await service.findPendingFriendshipWithOtherProfileSharingEmail(
                    requesterId: me,
                    excludePeerUserId: target.entityId,
                    normalizedEmail: email
                   ) {
#if DEBUG
                    print("[PendingRelationshipDebug] duplicateEmailButDifferentEntity=true otherEntityId=\(sibling.other.id.uuidString)")
                    print("[ChatIdentityDebug] duplicateEmailButDifferentEntity=true matchedEntityId=\(target.entityId.uuidString)")
#endif
                    return .error("Couldn't send friend request. Please try again.")
                }

#if DEBUG
                print("[PendingRelationshipDebug] duplicateEmailButDifferentEntity=true")
#endif
                return .error("Couldn't send friend request. Please try again.")
            }

            logFriendRequestVisibilityDebug(
                lookupResult: "error",
                targetUserId: target.entityId,
                me: me,
                existingRelation: verifiedRelation
            )
        }

        return FriendshipService.addFriendLookupOutcome(
            for: error,
            verifiedRelationForTarget: verifiedRelation
        )
    }

    private func logFriendRequestVisibilityDebug(
        lookupResult: String,
        targetUserId: UUID,
        me: UUID,
        existingRelation: FriendLookupExistingRelation = .none
    ) {
#if DEBUG
        let status: String
        switch existingRelation {
        case .none: status = "none"
        case .accepted: status = "accepted"
        case .pendingOutgoing: status = "pending_outgoing"
        case .pendingIncoming: status = "pending_incoming"
        case .declinedVisible: status = "declined_visible"
        }
        let inFriends = friends.contains { $0.id == targetUserId }
        let inIncoming = incomingRequests.contains {
            $0.requester.id == targetUserId || $0.friendship.requester_id == targetUserId
        }
        let inOutgoing = outgoingRequests.contains {
            $0.addressee.id == targetUserId || $0.friendship.addressee_id == targetUserId
        }
        DebugLogGate.debug("[FriendRequestVisibilityDebug] lookupResult=\(lookupResult)")
        DebugLogGate.debug("[FriendRequestVisibilityDebug] existingStatus=\(status) target=\(targetUserId.uuidString) me=\(me.uuidString)")
        DebugLogGate.debug("[FriendRequestVisibilityDebug] appearsInFriends=\(inFriends)")
        DebugLogGate.debug("[FriendRequestVisibilityDebug] appearsInRequests=\(inIncoming || inOutgoing) incoming=\(inIncoming) outgoing=\(inOutgoing)")
#endif
    }

    func chipKind(forOtherUserId userId: UUID) -> FriendshipChipKind {
        friendshipChipByOtherUserId[userId] ?? .addFriend
    }

    /// One batched refresh for all visible comment authors (no per-row queries).
    func refreshFriendshipStateForCommentAuthors(userIds: [UUID]) async {
        let unique = Array(Set(userIds))
        guard !unique.isEmpty else { return }
        if Task.isCancelled {
            #if DEBUG
            print("[CancellationHandlingDebug] ignoredCancellation context=comment_author_friendship_refresh")
            #endif
            return
        }
        guard (try? await service.currentUserId()) != nil else { return }
        await refresh()
    }

    /// Sends a friend request from a comment row; optimistic Pending, then lightweight list refresh.
    func sendFriendRequestFromComments(to addresseeId: UUID) async {
        if isEitherDirectionBlocked(with: addresseeId) {
            errorMessage = "You can’t send a friend request to this user."
            return
        }
        let previous = friendshipChipByOtherUserId[addresseeId]
        friendshipChipByOtherUserId[addresseeId] = .pendingOutgoing
        do {
            let me = try await service.currentUserId()
            try await service.sendFriendRequest(requesterId: me, addresseeId: addresseeId)
            await refreshFriendRequestListsOnly()
        } catch {
            if let previous {
                friendshipChipByOtherUserId[addresseeId] = previous
            } else {
                friendshipChipByOtherUserId.removeValue(forKey: addresseeId)
            }
            if ignoreCancellationIfNeeded(error, context: "friend_request_send_from_comments") { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Updates DM unread state for the Chat tab **and** mirrors it to the app icon badge (foreground / local only until APNs). See ``AppIconBadgeSync``.
    private func setUnreadDirectMessageCountAndSyncAppIcon(_ newValue: Int, source: String = "unspecified") async {
        let updateStartedAt = CFAbsoluteTimeGetCurrent()
        let clamped = max(0, newValue)
        let oldValue = unreadDirectMessageCount
        unreadDirectMessageCount = clamped
#if DEBUG
        print("[RealtimeChainDebug] uiStateUpdated table=conversation_read_state key=unreadDirectMessageCount oldValue=\(oldValue) newValue=\(clamped)")
        print("[UnreadStateDebug] source=\(source) oldTotal=\(oldValue) newTotal=\(clamped) vm=\(instanceDebugID)")
        print("[BadgeSyncDebug] unread total=\(clamped)")
        print("[BadgeSyncDebug] tab badge updated")
        print("[MainActorDebug] setUnreadDirectMessageCount actor=MainActor")
        let elapsed = String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - updateStartedAt) * 1000)
        print("[DMRealtimeLatencyDebug] unreadBadgeUpdated count=\(clamped) elapsedMs=\(elapsed)")
#endif
        await AppIconBadgeSync.apply(count: unreadDirectMessageCount)
    }

    private func applyFriendshipChipStates(
        me: UUID,
        accepted: [FriendshipRow],
        incoming: [FriendshipRow],
        outgoing: [FriendshipRow]
    ) {
        var next: [UUID: FriendshipChipKind] = [:]
        for row in accepted {
            let other = row.requester_id == me ? row.addressee_id : row.requester_id
            next[other] = .friends
        }
        for row in outgoing where row.isPendingStatus {
            let other = row.addressee_id
            if next[other] != .friends {
                next[other] = .pendingOutgoing
            }
        }
        for row in incoming where row.isPendingStatus {
            let other = row.requester_id
            if next[other] != .friends, next[other] != .pendingOutgoing {
                next[other] = .pendingIncoming
            }
        }
        for row in outgoing where row.isDeclinedStatus && row.requester_cleared_at == nil {
            let other = row.addressee_id
            if next[other] != .friends, next[other] != .pendingOutgoing, next[other] != .pendingIncoming {
                next[other] = .declinedOutgoing
            }
        }
        friendshipChipByOtherUserId = next
    }

    private func fetchDmParticipantPreviews(for rows: [DmInboxSummaryRow]) async throws -> [UUID: UserPreview] {
        let ids = Array(Set(rows.map(\.friend_user_id)))
        guard !ids.isEmpty else { return [:] }
        return try await socialIdentityService.fetchUserPreviews(for: ids)
    }

    private func deletedUserPreview(userId: UUID, email: String? = nil) -> UserPreview {
        UserPreview(
            id: userId,
            displayName: "Deleted User",
            email: email,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            isDeleted: true
        )
    }

    private func patchLoadedDmParticipantPreview(_ preview: UserPreview) {
        guard let index = friends.firstIndex(where: { $0.id == preview.id }) else { return }
        let existing = friends[index]
        friends[index] = FriendDisplay(
            id: existing.id,
            preview: preview,
            subtitle: existing.subtitle,
            lastMessageAt: existing.lastMessageAt,
            unreadCount: existing.unreadCount,
            isConversationBacked: existing.isConversationBacked
        )
    }

    private func fallbackPreview(
        userId: UUID,
        displayName: String? = nil,
        email: String? = nil,
        avatarURL: String? = nil,
        avatarThumbnailURL: String? = nil,
        isDeleted: Bool = false
    ) -> UserPreview {
        if isDeleted {
            return UserPreview(
                id: userId,
                displayName: "Deleted User",
                email: email,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                isDeleted: true
            )
        }
        let trimmed = displayName?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        let resolved = trimmed.isEmpty ? "Player" : trimmed
        return UserPreview(
            id: userId,
            displayName: resolved,
            email: email,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL
        )
    }

    private func inboxPreview(
        for row: DmInboxSummaryRow,
        resolvedPreview: UserPreview? = nil,
        profileLookupAttempted: Bool = false
    ) -> UserPreview {
        let isDeleted = row.friend_is_deleted == true
            || OwnerBusinessEmail.normalized(row.friend_email ?? "").hasSuffix("@deleted.fangeo.local")
            || row.friend_display_name?.trimmingCharacters(in: .whitespacesAndNewlines) == "Deleted User"
            || resolvedPreview?.isDeleted == true
        if isDeleted {
            return deletedUserPreview(userId: row.friend_user_id, email: row.friend_email)
        }

        if row.friend_is_business == true {
            let businessName = row.friend_business_display_name?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            let fallbackName = row.friend_display_name?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            let email = row.friend_email?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let resolved = !businessName.isEmpty
                ? businessName
                : (!fallbackName.isEmpty ? fallbackName : (email?.isEmpty == false ? email! : "Business"))
            return UserPreview(
                id: row.friend_user_id,
                displayName: resolved,
                email: email,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                isBusinessAccount: true,
                lastSeenAtRaw: resolvedPreview?.lastSeenAtRaw
            )
        }

        if let resolvedPreview {
            return resolvedPreview
        }

        if profileLookupAttempted {
            return deletedUserPreview(userId: row.friend_user_id, email: row.friend_email)
        }

        return fallbackPreview(
            userId: row.friend_user_id,
            displayName: row.friend_display_name,
            email: row.friend_email,
            avatarURL: row.friend_avatar_url,
            avatarThumbnailURL: row.friend_avatar_thumbnail_url
        )
    }

    private func logDeletedUserRenderDebug(surface: String, preview: UserPreview) {
#if DEBUG
        print("[DeletedUserRenderDebug] surface=\(surface)")
        print("[DeletedUserRenderDebug] userID=\(preview.id.uuidString.lowercased())")
        print("[DeletedUserRenderDebug] isDeleted=\(preview.isDeleted)")
        print("[DeletedUserRenderDebug] displayNameUsed=\(preview.displayName)")
#endif
    }

    private func logChatRowDebug(preview: UserPreview) {
#if DEBUG
        let avatarSource: String
        if preview.isBusinessIdentity {
            avatarSource = "business_building_icon"
        } else if !(preview.avatarThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    || !(preview.avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            avatarSource = "user_photo"
        } else {
            avatarSource = "generic_person_fallback"
        }
        DebugLogGate.debug(
            "[ChatRowDebug] displayName=\(preview.displayName) email=\(preview.email ?? "nil") isBusinessIdentity=\(preview.isBusinessIdentity) avatarSource=\(avatarSource)"
        )
#endif
    }

    private func formattedFriendshipSubtitle(row: FriendshipRow) -> String? {
        if let responded = row.responded_at, !responded.isEmpty {
            return "Friends since \(shortDate(from: responded))"
        }
        return nil
    }

    private func shortDate(from iso: String) -> String {
        let trimmed = String(iso.prefix(10))
        return trimmed.isEmpty ? iso : trimmed
    }
}
