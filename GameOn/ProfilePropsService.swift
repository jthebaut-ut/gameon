import Foundation
import Supabase

/// Summary state for Fan Props on a public profile.
struct ProfilePropsSummary: Codable, Equatable, Sendable {
    let userID: UUID
    /// Count of Fan Props visible to the signed-in user under Supabase RLS.
    let count: Int
    let likedByCurrentUser: Bool
}

/// Lightweight user preview for the signed-in user's incoming Fan Props list.
struct ProfilePropUserPreview: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let displayName: String
    /// Stored without `@`, lowercase — nil when unset.
    let username: String?
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let createdAt: String?

    var publicHandleLine: String {
        let stored = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? "" : FanGeoHandleRules.displayHandle(stored: stored)
    }
}

enum ProfilePropsServiceError: LocalizedError, Equatable {
    case cannotGivePropsToSelf

    var errorDescription: String? {
        switch self {
        case .cannotGivePropsToSelf:
            return "You cannot give Fan Props to yourself."
        }
    }
}

/// Supabase service for profile Fan Props. The backing table is `profile_likes`, but app-facing naming stays Props.
final class ProfilePropsService {
    private let client: SupabaseClient

    private static let table = "profile_likes"
    private static let propsSelect = "liker_user_id,liked_user_id,created_at,source"
    private static let profileSelect = "id,display_name,username,avatar_url,avatar_thumbnail_url,admin_status"

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func currentUserId() async throws -> UUID {
        let session = try await client.auth.session
        return session.user.id
    }

    /// Fetches Fan Props summary visible to the signed-in user.
    func fetchSummary(for userID: UUID) async throws -> ProfilePropsSummary {
        let currentUserID = try await currentUserId()
        let targetID = userID.uuidString.lowercased()

        let visibleRows: [ProfilePropsRow] = try await client
            .from(Self.table)
            .select(Self.propsSelect)
            .eq("liked_user_id", value: targetID)
            .execute()
            .value

        let likedByCurrentUser: Bool
        if currentUserID == userID {
            likedByCurrentUser = false
        } else {
            let currentUserRow: [ProfilePropsRow] = try await client
                .from(Self.table)
                .select(Self.propsSelect)
                .eq("liker_user_id", value: currentUserID.uuidString.lowercased())
                .eq("liked_user_id", value: targetID)
                .limit(1)
                .execute()
                .value
            likedByCurrentUser = !currentUserRow.isEmpty
        }

        return ProfilePropsSummary(
            userID: userID,
            count: visibleRows.count,
            likedByCurrentUser: likedByCurrentUser
        )
    }

    /// Gives Fan Props to another profile. RLS handles block checks and ownership.
    func giveProps(to userID: UUID, source: String? = nil) async throws {
        let currentUserID = try await currentUserId()
        guard currentUserID != userID else {
            throw ProfilePropsServiceError.cannotGivePropsToSelf
        }

        let row = ProfilePropsUpsert(
            liker_user_id: currentUserID,
            liked_user_id: userID,
            source: Self.normalizedSource(source)
        )

        try await client
            .from(Self.table)
            .upsert(row, onConflict: "liker_user_id,liked_user_id")
            .execute()
    }

    /// Removes the signed-in user's Fan Props from another profile.
    func removeProps(from userID: UUID) async throws {
        let currentUserID = try await currentUserId()
        guard currentUserID != userID else { return }

        try await client
            .from(Self.table)
            .delete()
            .eq("liker_user_id", value: currentUserID.uuidString.lowercased())
            .eq("liked_user_id", value: userID.uuidString.lowercased())
            .execute()
    }

    /// Owner-only list of users who gave Fan Props to the signed-in profile.
    func fetchMyIncomingProps(limit: Int = 50) async throws -> [ProfilePropUserPreview] {
        let currentUserID = try await currentUserId()
        let cappedLimit = min(max(limit, 0), 100)
        guard cappedLimit > 0 else { return [] }

        let propRows: [ProfilePropsRow] = try await client
            .from(Self.table)
            .select(Self.propsSelect)
            .eq("liked_user_id", value: currentUserID.uuidString.lowercased())
            .order("created_at", ascending: false)
            .limit(cappedLimit)
            .execute()
            .value

        let likerIDs = Array(Set(propRows.map(\.liker_user_id)))
        guard !likerIDs.isEmpty else { return [] }

        let profileRows: [ProfilePropsProfileRow] = try await client
            .from("user_profiles")
            .select(Self.profileSelect)
            .in("id", values: likerIDs.map { $0.uuidString.lowercased() })
            .eq("admin_status", value: "active")
            .execute()
            .value

        let profilesByID = Dictionary(uniqueKeysWithValues: profileRows.map { ($0.id, $0) })

        return propRows.map { propRow in
            let profile = profilesByID[propRow.liker_user_id]
            return Self.preview(
                for: propRow.liker_user_id,
                profile: profile,
                createdAt: propRow.created_at
            )
        }
    }

    private static func preview(
        for userID: UUID,
        profile: ProfilePropsProfileRow?,
        createdAt: String?
    ) -> ProfilePropUserPreview {
        let displayName = profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let avatarURL = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_url)
        let avatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_thumbnail_url)

        return ProfilePropUserPreview(
            id: userID,
            displayName: displayName.isEmpty ? "Fan" : displayName,
            username: profile?.username,
            avatarURL: avatarURL.isEmpty ? nil : avatarURL,
            avatarThumbnailURL: avatarThumbnailURL.isEmpty ? nil : avatarThumbnailURL,
            createdAt: createdAt
        )
    }

    private static func normalizedSource(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }

    private struct ProfilePropsRow: Codable, Sendable {
        let liker_user_id: UUID
        let liked_user_id: UUID
        let created_at: String?
        let source: String?
    }

    private struct ProfilePropsUpsert: Encodable, Sendable {
        let liker_user_id: UUID
        let liked_user_id: UUID
        let source: String?
    }

    private struct ProfilePropsProfileRow: Decodable, Sendable {
        let id: UUID
        let display_name: String?
        let username: String?
        let avatar_url: String?
        let avatar_thumbnail_url: String?
        let admin_status: String?
    }
}
