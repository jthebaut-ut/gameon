import Foundation
import Supabase
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Lightweight user surface (DM header, friend rows, navigation)

struct UserPreview: Identifiable, Hashable, Codable {
    let id: UUID
    let displayName: String
    let email: String?
    let avatarURL: String?
    /// Smaller avatar for lists/chips; falls back to ``avatarURL`` in views when nil/empty.
    let avatarThumbnailURL: String?
    let isBusinessAccount: Bool

    init(
        id: UUID,
        displayName: String,
        email: String? = nil,
        avatarURL: String?,
        avatarThumbnailURL: String? = nil,
        isBusinessAccount: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.avatarURL = avatarURL
        self.avatarThumbnailURL = avatarThumbnailURL
        self.isBusinessAccount = isBusinessAccount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case email
        case avatarURL
        case avatarThumbnailURL
        case isBusinessAccount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        avatarThumbnailURL = try container.decodeIfPresent(String.self, forKey: .avatarThumbnailURL)
        isBusinessAccount = try container.decodeIfPresent(Bool.self, forKey: .isBusinessAccount) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try container.encodeIfPresent(avatarThumbnailURL, forKey: .avatarThumbnailURL)
        try container.encode(isBusinessAccount, forKey: .isBusinessAccount)
    }

    var isBusinessIdentity: Bool {
        isBusinessAccount
    }
}

// MARK: - PostgREST rows (`friendships`, `direct_messages`, inbox RPC)

struct FriendshipRow: Codable, Hashable, Identifiable {
    let id: UUID
    let requester_id: UUID
    let addressee_id: UUID
    let status: String?
    let responded_at: String?
    let created_at: String?
    /// When set, addressee dismissed this **declined** row from their incoming list (soft hide).
    let addressee_cleared_at: String?
    /// When set, requester dismissed this **declined** row from their sent list (soft hide).
    let requester_cleared_at: String?

    init(
        id: UUID,
        requester_id: UUID,
        addressee_id: UUID,
        status: String?,
        responded_at: String?,
        created_at: String?,
        addressee_cleared_at: String? = nil,
        requester_cleared_at: String? = nil
    ) {
        self.id = id
        self.requester_id = requester_id
        self.addressee_id = addressee_id
        self.status = status
        self.responded_at = responded_at
        self.created_at = created_at
        self.addressee_cleared_at = addressee_cleared_at
        self.requester_cleared_at = requester_cleared_at
    }

    private enum CodingKeys: String, CodingKey {
        case id, requester_id, addressee_id, status, responded_at, created_at
        case addressee_cleared_at, requester_cleared_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        requester_id = try c.decode(UUID.self, forKey: .requester_id)
        addressee_id = try c.decode(UUID.self, forKey: .addressee_id)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        responded_at = try c.decodeIfPresent(String.self, forKey: .responded_at)
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
        addressee_cleared_at = try c.decodeIfPresent(String.self, forKey: .addressee_cleared_at)
        requester_cleared_at = try c.decodeIfPresent(String.self, forKey: .requester_cleared_at)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(requester_id, forKey: .requester_id)
        try c.encode(addressee_id, forKey: .addressee_id)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(responded_at, forKey: .responded_at)
        try c.encodeIfPresent(created_at, forKey: .created_at)
        try c.encodeIfPresent(addressee_cleared_at, forKey: .addressee_cleared_at)
        try c.encodeIfPresent(requester_cleared_at, forKey: .requester_cleared_at)
    }

    var isPendingStatus: Bool { (status ?? "").lowercased() == "pending" }
    var isDeclinedStatus: Bool { (status ?? "").lowercased() == "declined" }
    var isCancelledStatus: Bool { (status ?? "").lowercased() == "cancelled" }

    func withDeclinedNow(respondedAt: String) -> FriendshipRow {
        FriendshipRow(
            id: id,
            requester_id: requester_id,
            addressee_id: addressee_id,
            status: "declined",
            responded_at: respondedAt,
            created_at: created_at,
            addressee_cleared_at: addressee_cleared_at,
            requester_cleared_at: requester_cleared_at
        )
    }

    func withAddresseeClearedNow(clearedAt: String) -> FriendshipRow {
        FriendshipRow(
            id: id,
            requester_id: requester_id,
            addressee_id: addressee_id,
            status: status,
            responded_at: responded_at,
            created_at: created_at,
            addressee_cleared_at: clearedAt,
            requester_cleared_at: requester_cleared_at
        )
    }

    func withRequesterClearedNow(clearedAt: String) -> FriendshipRow {
        FriendshipRow(
            id: id,
            requester_id: requester_id,
            addressee_id: addressee_id,
            status: status,
            responded_at: responded_at,
            created_at: created_at,
            addressee_cleared_at: addressee_cleared_at,
            requester_cleared_at: clearedAt
        )
    }
}

struct DirectMessageRow: Codable, Hashable, Identifiable {
    let id: UUID
    let conversation_id: UUID?
    let sender_id: UUID
    let body: String
    let created_at: String?
    let deleted_at: String?
    /// Moderation metadata (optional for older rows / pre-migration).
    let report_count: Int?
    let is_deleted: Bool?
}

struct DmInboxSummaryRow: Codable, Hashable {
    let friend_user_id: UUID
    let friend_display_name: String?
    let friend_avatar_url: String?
    /// Present when RPC / view exposes `user_profiles.avatar_thumbnail_url` for the friend.
    let friend_avatar_thumbnail_url: String?
    let friend_email: String?
    let friend_is_business: Bool?
    let friend_business_display_name: String?
    let last_message_body: String?
    let last_message_sender_id: UUID?
    let last_message_created_at: String?
    let unread_count: Int?
}

// MARK: - Friend graph (PostgREST on `friendships`)

final class FriendshipService {

    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func currentUserId() async throws -> UUID {
        let session = try await client.auth.session
        return session.user.id
    }

    func fetchAcceptedFriendships(for userId: UUID) async throws -> [FriendshipRow] {
        let uid = userId.uuidString.lowercased()
        let filter = "requester_id.eq.\(uid),addressee_id.eq.\(uid)"
        return try await client
            .from("friendships")
            .select()
            .or(filter)
            .eq("status", value: "accepted")
            .execute()
            .value
    }

    func fetchIncomingPending(for userId: UUID) async throws -> [FriendshipRow] {
        try await client
            .from("friendships")
            .select()
            .eq("addressee_id", value: userId)
            .eq("status", value: "pending")
            .execute()
            .value
    }

    /// Pending plus **declined** rows the addressee has not cleared yet (soft-dismiss).
    func fetchIncomingFriendRequestsVisible(for userId: UUID) async throws -> [FriendshipRow] {
        async let pending: [FriendshipRow] = client
            .from("friendships")
            .select()
            .eq("addressee_id", value: userId)
            .eq("status", value: "pending")
            .execute()
            .value
        async let declined: [FriendshipRow] = client
            .from("friendships")
            .select()
            .eq("addressee_id", value: userId)
            .eq("status", value: "declined")
            .is("addressee_cleared_at", value: nil)
            .execute()
            .value
        let rows = try await pending + declined
        return rows.sorted {
            ($0.created_at ?? "") > ($1.created_at ?? "")
        }
    }

    func fetchOutgoingPending(for userId: UUID) async throws -> [FriendshipRow] {
        try await client
            .from("friendships")
            .select()
            .eq("requester_id", value: userId)
            .eq("status", value: "pending")
            .execute()
            .value
    }

    /// Pending plus **declined** rows the requester has not cleared yet.
    func fetchOutgoingFriendRequestsVisible(for userId: UUID) async throws -> [FriendshipRow] {
        async let pending: [FriendshipRow] = client
            .from("friendships")
            .select()
            .eq("requester_id", value: userId)
            .eq("status", value: "pending")
            .execute()
            .value
        async let declined: [FriendshipRow] = client
            .from("friendships")
            .select()
            .eq("requester_id", value: userId)
            .eq("status", value: "declined")
            .is("requester_cleared_at", value: nil)
            .execute()
            .value
        let rows = try await pending + declined
        return rows.sorted {
            ($0.created_at ?? "") > ($1.created_at ?? "")
        }
    }

    func fetchProfiles(userIds: [UUID]) async throws -> [UserProfileRow] {
        guard !userIds.isEmpty else { return [] }
        return try await client
            .from("user_profiles")
            .select()
            .in("id", values: userIds)
            .eq("admin_status", value: "active")
            .execute()
            .value
    }

    @discardableResult
    func acceptFriendRequest(requestId: UUID) async throws -> FriendshipRow {
        struct Patch: Encodable {
            let status: String
            let responded_at: String
        }
        let responded = ISO8601DateFormatter().string(from: Date())
        return try await client
            .from("friendships")
            .update(Patch(status: "accepted", responded_at: responded))
            .eq("id", value: requestId)
            .select()
            .single()
            .execute()
            .value
    }

    func rejectFriendRequest(requestId: UUID) async throws {
        struct Params: Encodable {
            let p_id: UUID
        }
        try await client
            .rpc("decline_friend_request", params: Params(p_id: requestId))
            .execute()
    }

    func clearFriendRequestView(requestId: UUID) async throws {
        struct Params: Encodable {
            let p_id: UUID
        }
        try await client
            .rpc("clear_friend_request_view", params: Params(p_id: requestId))
            .execute()
    }

    func cancelFriendRequest(requestId: UUID) async throws {
        struct Params: Encodable {
            let p_id: UUID
        }
        try await client
            .rpc("cancel_outgoing_friend_request", params: Params(p_id: requestId))
            .execute()
    }

    func sendFriendRequest(requesterId: UUID, addresseeId: UUID) async throws {
        let me = try await currentUserId()
        guard me == requesterId else {
            struct Mismatch: Error {}
            throw Mismatch()
        }
        struct Params: Encodable {
            let p_addressee: UUID
        }
        try await client
            .rpc("friendship_ensure_pending", params: Params(p_addressee: addresseeId))
            .execute()
    }

    /// Normalized add-friend lookup query: `lower(trim(raw))` (email or avatar/display name).
    static func normalizedFriendLookupQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Server resolves normalized email (first) or ``display_name_normalized`` → `user_profiles.id`, then inserts pending friendship.
    func sendFriendRequestByLookup(normalizedQuery: String) async throws {
        struct Params: Encodable {
            let p_query: String
        }
        try await client
            .rpc("send_friend_request_by_lookup", params: Params(p_query: normalizedQuery))
            .execute()
    }

    /// Maps PostgREST / Postgres errors from ``sendFriendRequestByLookup`` to stable user-visible strings.
    static func userFacingAddFriendLookupError(_ error: Error) -> String {
        let raw = error.localizedDescription
        let s = raw.lowercased()
        if raw.contains("No GameOn account found with that email or avatar name.")
            || raw.contains("No FanGeo account found with that email or avatar name.") {
            return "No FanGeo account found with that email or avatar name."
        }
        if raw.contains("You cannot add yourself.") {
            return "You cannot add yourself."
        }
        if raw.contains("Friend request already exists.") {
            return "Friend request already exists."
        }
        if raw.contains("You can't send a friend request to this user.")
            || raw.contains("You can’t send a friend request to this user.") {
            return "You can’t send a friend request to this user."
        }
        if raw.contains("Enter an email or avatar name.") {
            return "Enter an email or avatar name."
        }
        // Legacy server messages (older RPC) — normalize copy.
        if raw.contains("No GameOn account found with that email.")
            || raw.contains("No FanGeo account found with that email.") {
            return "No FanGeo account found with that email or avatar name."
        }
        if raw.contains("You can't send a friend request to yourself.")
            || raw.contains("You can’t send a friend request to yourself.") {
            return "You cannot add yourself."
        }
        if raw.contains("A friend request already exists with this person.") {
            return "Friend request already exists."
        }
        if raw.contains("Enter an email address.") {
            return "Enter an email or avatar name."
        }
        if s.contains("23505") || s.contains("duplicate key") || s.contains("unique constraint") {
            return "Friend request already exists."
        }
        if s.contains("could not find the function")
            || s.contains("schema cache")
            || s.contains("pgrst202") {
            return "Add friend isn’t available on the server yet. Please update the app or try again later."
        }
        return raw
    }
}

// MARK: - App icon badge (foreground)

enum AppIconBadgeSync {
    @MainActor
    static func apply(count: Int) async {
        let clamped = max(0, count)
        #if canImport(UIKit)
        await MainActor.run {
            UIApplication.shared.applicationIconBadgeNumber = clamped
        }
        #endif
    }
}
