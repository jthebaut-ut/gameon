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
        case pending
        case friends
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
    /// Unread peer DMs (Chat tab capsule + app icon badge when synced). Friend requests stay in the Requests segment only.
    @Published private(set) var unreadDirectMessageCount: Int = 0
    @Published var errorMessage: String?
    @Published private(set) var requiresSignIn: Bool = false
    @Published var isLoading: Bool = false

    /// Other user id → chip state. Keys only for users with an active friendship row; missing key ⇒ ``FriendshipChipKind.addFriend``.
    @Published private(set) var friendshipChipByOtherUserId: [UUID: FriendshipChipKind] = [:]
    @Published private(set) var currentUserAuthId: UUID?

    /// When true, ``MainTabView`` hides the floating tab bar so ``DirectChatView`` composer stays visible.
    @Published var hidesFloatingTabBarForDirectChat: Bool = false

    private let service = FriendshipService()
    private let directChatService = DirectChatService()
    private var lastLoadAt: Date?
    private let minRefreshInterval: TimeInterval = 12
    private var lastInboxLoadAt: Date?
    private let minInboxRefreshInterval: TimeInterval = 2

    // MARK: - Realtime (in-app inbox)

    /// In-app realtime listener for `direct_messages` INSERTs while the user is actively viewing the Chat tab (not inside a thread).
    /// This does **not** work when the app is backgrounded/killed; that requires APNs/push later.
    private var inboxChannel: RealtimeChannelV2?
    private var inboxListenTask: Task<Void, Never>?
    private var inboxThrottleTask: Task<Void, Never>?

    func currentUserIdIfSignedIn() async -> UUID? {
        try? await service.currentUserId()
    }

    /// Clears social UI state when the session ends (no network).
    func clearForLogout() async {
        await stopInboxRealtimeListener()
        friends = []
        incomingRequests = []
        outgoingRequests = []
        pendingBadgeCount = 0
        await setUnreadDirectMessageCountAndSyncAppIcon(0)
        errorMessage = nil
        requiresSignIn = true
        lastLoadAt = nil
        friendshipChipByOtherUserId = [:]
        currentUserAuthId = nil
        hidesFloatingTabBarForDirectChat = false
    }

    /// Starts/stops a lightweight in-app inbox listener for unread badge refresh.
    /// Call this from the Chat tab view layer when the Chat tab becomes visible or hidden.
    func setInboxRealtimeEnabled(_ enabled: Bool) {
        if enabled {
            startInboxRealtimeListenerIfNeeded()
        } else {
            Task { await stopInboxRealtimeListener() }
        }
    }

    private func startInboxRealtimeListenerIfNeeded() {
        guard inboxListenTask == nil, inboxChannel == nil else { return }
        guard requiresSignIn == false else { return }
        guard hidesFloatingTabBarForDirectChat == false else { return } // treat as "in thread" signal
        inboxListenTask = Task { [weak self] in
            guard let self else { return }
            await self.runInboxRealtimeListenerLoop()
        }
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

        let channel = supabase.channel("dm-inbox")
        inboxChannel = channel

        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "direct_messages"
        )

        do {
            try await channel.subscribeWithError()
            for await insertion in inserts {
                if Task.isCancelled { break }
                let row: DirectMessageRow
                do {
                    row = try insertion.decodeRecord(as: DirectMessageRow.self, decoder: JSONDecoder())
                } catch {
                    continue
                }

                if row.deleted_at != nil { continue }
                if row.sender_id == me { continue }

                // Throttle: coalesce multiple inserts into a single unread count refresh.
                inboxThrottleTask?.cancel()
                inboxThrottleTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 650_000_000)
                    } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    await self.refreshInboxSummaries()
                }
            }
        } catch {
            // Fail silently: this is an in-app enhancement only (no banners/alerts here).
        }

        await stopInboxRealtimeListener()
    }

    private func stopInboxRealtimeListener() async {
        inboxThrottleTask?.cancel()
        inboxThrottleTask = nil
        inboxListenTask?.cancel()
        inboxListenTask = nil

        if let ch = inboxChannel {
            await supabase.removeChannel(ch)
        }
        inboxChannel = nil
    }

    /// Refreshes the Chat tab badge for unread peer DMs (no friendship / request counts).
    func refreshUnreadDirectMessageCount() async {
        guard let me = try? await directChatService.currentUserId() else {
            await setUnreadDirectMessageCountAndSyncAppIcon(0)
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
            friends = []
            await setUnreadDirectMessageCountAndSyncAppIcon(0)
            return
        }
        do {
            let rows = try await directChatService.fetchInboxSummaries()
            let displays = rows.map { row -> FriendDisplay in
                let name = row.friend_display_name?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let displayName = (name?.isEmpty == false) ? name! : "Player"
                let preview = UserPreview(
                    id: row.friend_user_id,
                    displayName: displayName,
                    avatarURL: row.friend_avatar_url
                )

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

            friends = displays
            let totalUnread = displays.reduce(0) { $0 + $1.unreadCount }
            await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread)
            lastInboxLoadAt = Date()
            currentUserAuthId = me
        } catch {
            // Keep existing list on transient failures; unread badge may be stale until next refresh.
        }
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let me = try await service.currentUserId()
            async let accepted = service.fetchAcceptedFriendships(for: me)
            async let incoming = service.fetchIncomingPending(for: me)
            async let outgoing = service.fetchOutgoingPending(for: me)
            async let inbox = directChatService.fetchInboxSummaries()
            let (accRows, inRows, outRows, inboxRows) = try await (accepted, incoming, outgoing, inbox)

            let requestOtherIds = Set(inRows.map { $0.requester_id } + outRows.map { $0.addressee_id })

            let profiles = try await service.fetchProfiles(userIds: Array(requestOtherIds))
            let profileById: [UUID: UserProfileRow] = Dictionary(
                uniqueKeysWithValues: profiles.compactMap { row -> (UUID, UserProfileRow)? in
                    guard let id = row.id else { return nil }
                    return (id, row)
                }
            )

            friends = inboxRows.map { row -> FriendDisplay in
                let name = row.friend_display_name?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let displayName = (name?.isEmpty == false) ? name! : "Player"
                let preview = UserPreview(
                    id: row.friend_user_id,
                    displayName: displayName,
                    avatarURL: row.friend_avatar_url
                )

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

            incomingRequests = inRows.map { row in
                let preview = preview(for: row.requester_id, profileById: profileById)
                return IncomingRequestDisplay(friendship: row, requester: preview)
            }

            outgoingRequests = outRows.map { row in
                let preview = preview(for: row.addressee_id, profileById: profileById)
                return OutgoingRequestDisplay(friendship: row, addressee: preview)
            }

            pendingBadgeCount = incomingRequests.count
            requiresSignIn = false
            lastLoadAt = Date()
            lastInboxLoadAt = Date()
            currentUserAuthId = me
            applyFriendshipChipStates(
                me: me,
                accepted: accRows,
                incomingPending: inRows,
                outgoingPending: outRows
            )
            let totalUnread = friends.reduce(0) { $0 + $1.unreadCount }
            await setUnreadDirectMessageCountAndSyncAppIcon(totalUnread)
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
                requiresSignIn = true
                errorMessage = nil
                lastLoadAt = nil
                lastInboxLoadAt = nil
                await setUnreadDirectMessageCountAndSyncAppIcon(0)
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
        do {
            _ = try await service.rejectFriendRequest(requestId: item.friendship.id)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel(_ item: OutgoingRequestDisplay) async {
        do {
            _ = try await service.cancelFriendRequest(requestId: item.friendship.id)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendFriendRequest(to addresseeId: UUID) async {
        do {
            let me = try await service.currentUserId()
            try await service.sendFriendRequest(requesterId: me, addresseeId: addresseeId)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
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

    /// Sends a friend request from a comment row; optimistic Pending, then full refresh for badge + cache.
    func sendFriendRequestFromComments(to addresseeId: UUID) async {
        let previous = friendshipChipByOtherUserId[addresseeId]
        friendshipChipByOtherUserId[addresseeId] = .pending
        do {
            let me = try await service.currentUserId()
            try await service.sendFriendRequest(requesterId: me, addresseeId: addresseeId)
            await refresh()
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
        incomingPending: [FriendshipRow],
        outgoingPending: [FriendshipRow]
    ) {
        var next: [UUID: FriendshipChipKind] = [:]
        for row in accepted {
            let other = row.requester_id == me ? row.addressee_id : row.requester_id
            next[other] = .friends
        }
        for row in outgoingPending {
            let other = row.addressee_id
            if next[other] != .friends {
                next[other] = .pending
            }
        }
        for row in incomingPending {
            let other = row.requester_id
            if next[other] != .friends {
                next[other] = .pending
            }
        }
        friendshipChipByOtherUserId = next
    }

    private func preview(for userId: UUID, profileById: [UUID: UserProfileRow]) -> UserPreview {
        if let row = profileById[userId] {
            let name = row.display_name?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let resolved = (name?.isEmpty == false) ? name! : "Player"
            return UserPreview(id: userId, displayName: resolved, avatarURL: row.avatar_url)
        }
        return UserPreview(id: userId, displayName: "Player", avatarURL: nil)
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
