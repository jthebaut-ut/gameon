import Combine
import Foundation
import Supabase
import SwiftUI

/// Owns friends / friend-request state for the Chat tab. Independent of ``MapViewModel``.
@MainActor
final class ChatViewModel: ObservableObject {

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

    @Published private(set) var addFriendSearchResults: [AddFriendSearchTarget] = []
    @Published private(set) var addFriendSearchIsLoading: Bool = false

    private let service = FriendshipService()
    private let directChatService = DirectChatService()
    private let socialIdentityService = SocialIdentityService()
    private var lastLoadAt: Date?
    private let minRefreshInterval: TimeInterval = 12
    private var lastInboxLoadAt: Date?
    private let minInboxRefreshInterval: TimeInterval = 2

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
    /// Periodic full inbox reconcile while the listener is active (friendship/block drift, ordering, unread correctness).
    private var inboxReconciliationTask: Task<Void, Never>?
    /// User id the active inbox channel was bound to (debug + duplicate-guard).
    private var inboxRealtimeBoundUserId: UUID?
    /// True when the inbox listener uses a client-side `conversation_id IN (...)` filter (see run loop).
    private var inboxRealtimeUsesConversationFilter: Bool = false

    /// Supabase Realtime `IN` filters should stay small; above this we omit the client filter and rely on RLS.
    private let kMaxConversationIdsForInboxRealtimeClientFilter = 48

    // MARK: - Realtime (friend requests)

    private var friendshipsChannel: RealtimeChannelV2?
    private var friendshipsListenTask: Task<Void, Never>?
    private var friendshipsRealtimeBoundUserId: UUID?
    private var friendRequestRealtimeDebounceTask: Task<Void, Never>?
    /// Debounces ``ensureSignedInSocialRealtimeIfNeeded()`` after app foreground to avoid reconnect storms.
    private var socialRealtimeForegroundTask: Task<Void, Never>?

    func currentUserIdIfSignedIn() async -> UUID? {
        try? await service.currentUserId()
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
        inboxUnreadDebounceTask?.cancel()
        inboxUnreadDebounceTask = nil
        inboxMissingPeerReconcileTask?.cancel()
        inboxMissingPeerReconcileTask = nil
        inboxReconciliationTask?.cancel()
        inboxReconciliationTask = nil
        friendRequestRealtimeDebounceTask?.cancel()
        friendRequestRealtimeDebounceTask = nil
        socialRealtimeForegroundTask?.cancel()
        socialRealtimeForegroundTask = nil

        Task { [weak self] in
            guard let self else { return }
            await self.stopInboxRealtimeListener()
            await self.stopFriendshipsRealtimeListener()
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
        startInboxRealtimeListenerIfNeeded()
        startFriendshipsRealtimeListenerIfNeeded()
    }

    /// Debounced re-attach after foreground (avoids stacked reconnects with scene churn).
    func scheduleEnsureSocialRealtimeAfterForeground() {
        socialRealtimeForegroundTask?.cancel()
        socialRealtimeForegroundTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            print("[RealtimeLifecycle] foreground debounced ensure")
            await self.ensureSignedInSocialRealtimeIfNeeded()
        }
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
            print("[RealtimeLifecycle] duplicate prevented (inbox listener already active)")
            return
        }
        print("[RealtimeLifecycle] starting inbox listener")
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
            inboxReconciliationTask?.cancel()
            inboxReconciliationTask = nil
            inboxUnreadDebounceTask?.cancel()
            inboxUnreadDebounceTask = nil
            inboxMissingPeerReconcileTask?.cancel()
            inboxMissingPeerReconcileTask = nil
            inboxListenTask = nil
        }

        let channel = supabase.channel("dm-inbox-\(me.uuidString.lowercased())")
        inboxChannel = channel

        let readStateChanges = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "conversation_read_state"
        )

        let convIds = (try? await directChatService.fetchMyDirectConversationIds(userId: me)) ?? []
        let inserts: AsyncStream<InsertAction>
        if !convIds.isEmpty, convIds.count <= kMaxConversationIdsForInboxRealtimeClientFilter {
            let filter = RealtimePostgresFilter.in("conversation_id", values: convIds)
            inserts = channel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "direct_messages",
                filter: filter
            )
            inboxRealtimeUsesConversationFilter = true
            #if DEBUG
            print("[ChatRealtime] inbox scope: postgresChange filter conversation_id IN (\(convIds.count) ids); RLS still applies.")
            #endif
        } else {
            inserts = channel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "direct_messages"
            )
            inboxRealtimeUsesConversationFilter = false
            #if DEBUG
            print("[ChatRealtime] inbox scope: postgresChange unfiltered (convIds=\(convIds.count)); user-visible events rely on RLS.")
            #endif
        }

        do {
            try await channel.subscribeWithError()
            inboxRealtimeBoundUserId = me
            print("[DMRealtime] inbox subscribed channel=dm-inbox-\(me.uuidString.lowercased())")

            inboxReconciliationTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 180_000_000_000)
                    guard !Task.isCancelled else { break }
                    await self?.refreshInboxSummaries()
                }
            }

            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    await self?.consumeConversationReadStateRealtime(readStateChanges)
                }
                group.addTask { [weak self] in
                    await self?.consumeInboxDirectMessageInserts(inserts, me: me)
                }
            }
        } catch is CancellationError {
            print("[DMRealtime] inbox listener cancelled")
        } catch {
            print("[DMRealtime] inbox listener error: \(error)")
        }

        await removeInboxRealtimeChannelOnly()
        // Allow ``startInboxRealtimeListenerIfNeeded()`` after disconnect; do not call ``stopInboxRealtimeListener()`` here
        // (that would deadlock while awaiting this same task).
    }

    /// Read cursor changes (mark-read) do not emit `direct_messages` rows; listen for lightweight RPC recount instead of reloading the inbox.
    private func consumeConversationReadStateRealtime(_ stream: AsyncStream<AnyAction>) async {
        for await action in stream {
            if Task.isCancelled { break }
            switch action {
            case .insert, .update, .delete:
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

            if row.deleted_at != nil { continue }
            if row.sender_id == me { continue }
            if isEitherDirectionBlocked(with: row.sender_id) {
                #if DEBUG
                print("[ChatRealtime] inbox INSERT id=\(row.id) sender=\(row.sender_id) → skip(blocked)")
                #endif
                continue
            }

            #if DEBUG
            print("[ChatRealtime] inbox INSERT id=\(row.id) conv=\(row.conversation_id?.uuidString ?? "nil") sender=\(row.sender_id)")
            #endif

            let patched = await applyRealtimeIncomingPeerMessage(row)
            if patched {
                #if DEBUG
                print("[ChatRealtime]   → local inbox row patch + debounced refreshUnreadDirectMessageCount(550ms)")
                #endif
                scheduleDebouncedUnreadDirectMessageRPCRefresh()
            } else {
                #if DEBUG
                print("[ChatRealtime]   → schedule full refreshInboxSummaries debounce(800ms)")
                #endif
            }
        }
    }

    /// Coalesces multiple realtime events into one ``refreshUnreadDirectMessageCount()`` (single RPC), not a full inbox fetch.
    private func scheduleDebouncedUnreadDirectMessageRPCRefresh() {
        inboxUnreadDebounceTask?.cancel()
        inboxUnreadDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 550_000_000)
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.refreshUnreadDirectMessageCount()
            #if DEBUG
            print("[ChatRealtime]   → debounced refreshUnreadDirectMessageCount completed")
            #endif
        }
    }

    /// Zeros this peer’s row in the local inbox immediately after opening a thread / mark-read so the tab badge drops before summaries refetch.
    func markDirectInboxReadLocally(peerUserId: UUID) {
        guard let idx = friends.firstIndex(where: { $0.id == peerUserId }) else {
            scheduleDebouncedUnreadDirectMessageRPCRefresh()
            return
        }
        let old = friends[idx]
        guard old.unreadCount > 0 else { return }
        let updated = FriendDisplay(
            id: old.id,
            preview: old.preview,
            subtitle: old.subtitle,
            lastMessageAt: old.lastMessageAt,
            unreadCount: 0
        )
        var next = friends
        next[idx] = updated
        friends = next
        let totalUnread = next.reduce(0) { $0 + $1.unreadCount }
        Task { await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread) }
    }

    /// Applies a lightweight inbox row update for an incoming peer DM (1:1). Returns false if a full inbox reconcile should run.
    private func applyRealtimeIncomingPeerMessage(_ row: DirectMessageRow) async -> Bool {
        let peerId = row.sender_id
        guard let idx = friends.firstIndex(where: { $0.id == peerId }) else {
            inboxMissingPeerReconcileTask?.cancel()
            inboxMissingPeerReconcileTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 800_000_000)
                } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.refreshInboxSummaries()
            }
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
        let newUnread = old.unreadCount + 1
        let updated = FriendDisplay(
            id: old.id,
            preview: old.preview,
            subtitle: rawPreview,
            lastMessageAt: lastAt,
            unreadCount: newUnread
        )
        var next = friends
        next[idx] = updated
        next.sort { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
        friends = next
        let totalUnread = next.reduce(0) { $0 + $1.unreadCount }
        await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread)
        return true
    }

    private func stopInboxRealtimeListener() async {
        print("[RealtimeLifecycle] stopping inbox listener")
        inboxUnreadDebounceTask?.cancel()
        inboxUnreadDebounceTask = nil
        inboxMissingPeerReconcileTask?.cancel()
        inboxMissingPeerReconcileTask = nil
        inboxReconciliationTask?.cancel()
        inboxReconciliationTask = nil

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
            print("[RealtimeLifecycle] duplicate prevented (friendship listener already active)")
            return
        }
        guard requiresSignIn == false else { return }
        print("[RealtimeLifecycle] starting friendship listener")
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

        print("[FriendRequestRealtime] friendship channel bound user=\(me.uuidString.lowercased())")

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

        do {
            try await channel.subscribeWithError()
            friendshipsRealtimeBoundUserId = me

            for await action in changes {
                if Task.isCancelled { break }
                try Task.checkCancellation()
                switch action {
                case .insert, .update, .delete:
                    logFriendRequestRealtimeCancelledIfNeeded(action)
                    print("[FriendRequestRealtime] event received")
                    scheduleFriendRequestRealtimeRefresh()
                }
            }
        } catch {
            if !(error is CancellationError) {
                print("[FriendRequestRealtime] subscribe/stream error: \(error)")
                print("[RealtimeLifecycle] friendship listener ended with error")
            }
        }

        await removeFriendshipsChannelOnly()
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
            print("[FriendRequestRealtime] cancelled request received")
        }
    }

    private func scheduleFriendRequestRealtimeRefresh() {
        friendRequestRealtimeDebounceTask?.cancel()
        friendRequestRealtimeDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 320_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            print("[FriendRequestRealtime] refreshing requests")
            await self.refreshFriendRequestListsOnly()
            print("[FriendRequestRealtime] badge updated pending=\(self.pendingBadgeCount)")
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
        print("[RealtimeLifecycle] stopping friendship listener")
    }

    /// Refreshes friend request rows + chip map + pending badge without reloading DM inbox.
    func refreshFriendRequestListsOnly() async {
        guard let me = try? await service.currentUserId() else {
            clearForSignOut()
            return
        }
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
                    let preview = previewsById[row.requester_id] ?? fallbackPreview(userId: row.requester_id)
                    return IncomingRequestDisplay(friendship: row, requester: preview)
                }

            outgoingRequests = outRows
                .filter { !isEitherDirectionBlocked(with: $0.addressee_id) }
                .map { row in
                    let preview = previewsById[row.addressee_id] ?? fallbackPreview(userId: row.addressee_id)
                    return OutgoingRequestDisplay(friendship: row, addressee: preview)
                }

            pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
            currentUserAuthId = me
            applyFriendshipChipStates(me: me, accepted: accRows, incoming: inRows, outgoing: outRows)
        } catch {
            // Keep existing lists; next refresh or realtime will retry.
        }
    }

    /// Refreshes the Chat tab badge for unread peer DMs (no friendship / request counts).
    func refreshUnreadDirectMessageCount() async {
        guard let me = try? await directChatService.currentUserId() else {
            clearForSignOut()
            return
        }
        guard let n = try? await directChatService.fetchUnreadDirectMessageCount(currentUserId: me) else {
            return
        }
        await setUnreadDirectMessageCountAndSyncAppIcon(n)
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
        guard let me = try? await directChatService.currentUserId() else {
            clearForSignOut()
            return
        }
        await reloadModerationBlockSets()
        do {
            let rows = try await directChatService.fetchInboxSummaries()
            let displays = rows.map { row -> FriendDisplay in
                let preview = inboxPreview(for: row)
                logChatRowDebug(preview: preview)

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
                    unreadCount: unread
                )
            }

            // Hide users blocked in either direction.
            var visible = displays.filter { !isEitherDirectionBlocked(with: $0.id) }
            visible = try await mergeAcceptedFriendsMissingFromInbox(me: me, inboxDisplays: visible)
            friends = visible
            let totalUnread = visible.reduce(0) { $0 + $1.unreadCount }
            await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread)
            lastInboxLoadAt = Date()
            currentUserAuthId = me
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
            await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread)
            await refreshInboxSummaries()
        } catch {
            friends = snapshot
            inboxDeleteError = error.localizedDescription
        }
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let me = try await service.currentUserId()
            if let priorMe = currentUserAuthId, priorMe != me {
                await stopInboxRealtimeListener()
                await stopFriendshipsRealtimeListener()
            }
            await reloadModerationBlockSets()
            async let accepted = service.fetchAcceptedFriendships(for: me)
            async let incoming = service.fetchIncomingFriendRequestsVisible(for: me)
            async let outgoing = service.fetchOutgoingFriendRequestsVisible(for: me)
            async let inbox = directChatService.fetchInboxSummaries()
            let (accRows, inRows, outRows, inboxRows) = try await (accepted, incoming, outgoing, inbox)

            let previewIds = Set(
                inRows.map(\.requester_id)
                    + outRows.map(\.addressee_id)
            )
            let previewsById = try await socialIdentityService.fetchUserPreviews(for: Array(previewIds))

            let inboxFiltered = inboxRows.filter { !isEitherDirectionBlocked(with: $0.friend_user_id) }
            var friendDisplays = inboxFiltered.map { row -> FriendDisplay in
                let preview = inboxPreview(for: row)
                logChatRowDebug(preview: preview)

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
                    unreadCount: unread
                )
            }
            friendDisplays = try await mergeAcceptedFriendsMissingFromInbox(me: me, inboxDisplays: friendDisplays)
            friends = friendDisplays

            incomingRequests = inRows
                .filter { !isEitherDirectionBlocked(with: $0.requester_id) }
                .map { row in
                let preview = previewsById[row.requester_id] ?? fallbackPreview(userId: row.requester_id)
                return IncomingRequestDisplay(friendship: row, requester: preview)
            }

            outgoingRequests = outRows
                .filter { !isEitherDirectionBlocked(with: $0.addressee_id) }
                .map { row in
                let preview = previewsById[row.addressee_id] ?? fallbackPreview(userId: row.addressee_id)
                return OutgoingRequestDisplay(friendship: row, addressee: preview)
            }

            pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
            requiresSignIn = false
            lastLoadAt = Date()
            lastInboxLoadAt = Date()
            currentUserAuthId = me
            applyFriendshipChipStates(
                me: me,
                accepted: accRows,
                incoming: inRows,
                outgoing: outRows
            )
            let totalUnread = friends.reduce(0) { $0 + $1.unreadCount }
            await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread)
            await ensureSignedInSocialRealtimeIfNeeded()
        } catch {
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
            _ = try await service.acceptFriendRequest(requestId: item.friendship.id)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
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
            incomingRequests = snapshot
            pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
            errorMessage = error.localizedDescription
            await refreshFriendRequestListsOnly()
        }
    }

    /// Clears a **declined** incoming request from the receiver’s list (soft-dismiss on server).
    func clearIncomingDeclinedRequest(_ item: IncomingRequestDisplay) async {
        guard item.friendship.isDeclinedStatus else { return }
        print("[FriendRequest] clear requested id=\(item.id)")
        let snapshot = incomingRequests
        incomingRequests.removeAll { $0.id == item.id }
        pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
        do {
            try await service.clearFriendRequestView(requestId: item.id)
            print("[FriendRequest] clear completed id=\(item.id)")
            await refreshFriendRequestListsOnly()
        } catch {
            print("[FriendRequest] clear failed id=\(item.id) error=\(error)")
            incomingRequests = snapshot
            pendingBadgeCount = incomingRequests.filter { $0.friendship.isPendingStatus }.count
            errorMessage = error.localizedDescription
        }
    }

    /// Clears a **declined** outgoing request from the sender’s list (soft-dismiss on server).
    func clearOutgoingDeclinedRequest(_ item: OutgoingRequestDisplay) async {
        guard item.friendship.isDeclinedStatus else { return }
        print("[FriendRequest] clear requested id=\(item.id)")
        let snapshot = outgoingRequests
        outgoingRequests.removeAll { $0.id == item.id }
        do {
            try await service.clearFriendRequestView(requestId: item.id)
            print("[FriendRequest] clear completed id=\(item.id)")
            await refreshFriendRequestListsOnly()
        } catch {
            print("[FriendRequest] clear failed id=\(item.id) error=\(error)")
            outgoingRequests = snapshot
            errorMessage = error.localizedDescription
        }
    }

    func cancel(_ item: OutgoingRequestDisplay) async {
        guard item.friendship.isPendingStatus else { return }
        print("[FriendRequest] outgoing cancel requested id=\(item.id)")
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
            print("[FriendRequest] outgoing cancel completed id=\(item.id)")
            await refreshFriendRequestListsOnly()
        } catch {
            print("[FriendRequest] outgoing cancel failed id=\(item.id) error=\(error)")
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

    /// Accepted friends without a DM thread yet still appear under Chat → Friends (presentation only; inbox RPC unchanged).
    private func mergeAcceptedFriendsMissingFromInbox(
        me: UUID,
        inboxDisplays: [FriendDisplay]
    ) async throws -> [FriendDisplay] {
        let accepted = try await service.fetchAcceptedFriendships(for: me)
        let inboxIds = Set(inboxDisplays.map(\.id))
        let missingIds: [UUID] = accepted.compactMap { row in
            let other = row.requester_id == me ? row.addressee_id : row.requester_id
            guard !inboxIds.contains(other) else { return nil }
            guard !isEitherDirectionBlocked(with: other) else { return nil }
            return other
        }
        guard !missingIds.isEmpty else { return inboxDisplays }

        let previews = try await socialIdentityService.fetchUserPreviews(for: missingIds)
        var merged = inboxDisplays
        for pid in missingIds {
            let preview = previews[pid] ?? fallbackPreview(userId: pid)
            merged.append(
                FriendDisplay(
                    id: pid,
                    preview: preview,
                    subtitle: "Say hi",
                    lastMessageAt: nil,
                    unreadCount: 0
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
        print("[FriendRequestVisibilityDebug] lookupResult=\(lookupResult)")
        print("[FriendRequestVisibilityDebug] existingStatus=\(status) target=\(targetUserId.uuidString) me=\(me.uuidString)")
        print("[FriendRequestVisibilityDebug] appearsInFriends=\(inFriends)")
        print("[FriendRequestVisibilityDebug] appearsInRequests=\(inIncoming || inOutgoing) incoming=\(inIncoming) outgoing=\(inOutgoing)")
#endif
    }

    func chipKind(forOtherUserId userId: UUID) -> FriendshipChipKind {
        friendshipChipByOtherUserId[userId] ?? .addFriend
    }

    /// One batched refresh for all visible comment authors (no per-row queries).
    func refreshFriendshipStateForCommentAuthors(userIds: [UUID]) async {
        let unique = Array(Set(userIds))
        guard !unique.isEmpty else { return }
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
            errorMessage = error.localizedDescription
        }
    }

    /// Updates DM unread state for the Chat tab **and** mirrors it to the app icon badge (foreground / local only until APNs). See ``AppIconBadgeSync``.
    private func setUnreadDirectMessageCountAndSyncAppIcon(_ newValue: Int) async {
        unreadDirectMessageCount = max(0, newValue)
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

    private func fallbackPreview(
        userId: UUID,
        displayName: String? = nil,
        email: String? = nil,
        avatarURL: String? = nil,
        avatarThumbnailURL: String? = nil
    ) -> UserPreview {
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

    private func inboxPreview(for row: DmInboxSummaryRow) -> UserPreview {
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
                isBusinessAccount: true
            )
        }

        return fallbackPreview(
            userId: row.friend_user_id,
            displayName: row.friend_display_name,
            email: row.friend_email,
            avatarURL: row.friend_avatar_url,
            avatarThumbnailURL: row.friend_avatar_thumbnail_url
        )
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
        print(
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
