import Foundation
import Supabase
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Lightweight user surface (DM header, friend rows, navigation)

struct UserPreview: Identifiable, Hashable, Codable {
    let id: UUID
    let displayName: String
    let avatarURL: String?
    /// Smaller avatar for lists/chips; falls back to ``avatarURL`` in views when nil/empty.
    let avatarThumbnailURL: String?

    init(id: UUID, displayName: String, avatarURL: String?, avatarThumbnailURL: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.avatarThumbnailURL = avatarThumbnailURL
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

    func fetchOutgoingPending(for userId: UUID) async throws -> [FriendshipRow] {
        try await client
            .from("friendships")
            .select()
            .eq("requester_id", value: userId)
            .eq("status", value: "pending")
            .execute()
            .value
    }

    func fetchProfiles(userIds: [UUID]) async throws -> [UserProfileRow] {
        guard !userIds.isEmpty else { return [] }
        return try await client
            .from("user_profiles")
            .select()
            .in("id", values: userIds)
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
        try await client
            .from("friendships")
            .delete()
            .eq("id", value: requestId)
            .execute()
    }

    func cancelFriendRequest(requestId: UUID) async throws {
        try await client
            .from("friendships")
            .delete()
            .eq("id", value: requestId)
            .execute()
    }

    func sendFriendRequest(requesterId: UUID, addresseeId: UUID) async throws {
        struct Insert: Encodable {
            let requester_id: UUID
            let addressee_id: UUID
            let status: String
        }
        try await client
            .from("friendships")
            .insert(Insert(requester_id: requesterId, addressee_id: addresseeId, status: "pending"))
            .execute()
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
