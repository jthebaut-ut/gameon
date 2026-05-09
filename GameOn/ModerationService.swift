import Foundation
import Supabase

/// Lightweight moderation helpers used by Chat surfaces.
/// - Important: This is client-side convenience only. Ensure RLS policies enforce these rules server-side.
struct ModerationService {
    enum ModerationError: LocalizedError {
        case notSignedIn
        case unexpected

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in to manage blocked users."
            case .unexpected: return "Unable to complete request."
            }
        }
    }

    private struct BlockedUserRow: Decodable {
        let blocker_user_id: UUID?
        let blocked_user_id: UUID?
        let created_at: String?
    }

    private struct BlockedUserInsert: Encodable {
        let blocker_user_id: UUID
        let blocked_user_id: UUID
    }

    func currentUserId() async throws -> UUID {
        let session = try await supabase.auth.session
        return session.user.id
    }

    func fetchBlockedUserIds() async throws -> Set<UUID> {
        let me = try await currentUserId()
        let rows: [BlockedUserRow] = try await supabase
            .from("blocked_users")
            .select("blocked_user_id,created_at")
            .eq("blocker_user_id", value: me)
            .execute()
            .value
        return Set(rows.compactMap { $0.blocked_user_id })
    }

    func unblock(userId: UUID) async throws {
        let me = try await currentUserId()
        _ = try await supabase
            .from("blocked_users")
            .delete()
            .eq("blocker_user_id", value: me)
            .eq("blocked_user_id", value: userId)
            .execute()
    }

    func block(userId: UUID) async throws {
        let me = try await currentUserId()
        let row = BlockedUserInsert(blocker_user_id: me, blocked_user_id: userId)
        _ = try await supabase
            .from("blocked_users")
            .insert(row)
            .execute()
    }

    /// Best-effort lookup for display names/avatars/emails for blocked ids.
    /// Falls back gracefully if the table is missing or ids aren't present.
    func fetchUserPreviews(for userIds: [UUID]) async -> [UserPreview] {
        guard !userIds.isEmpty else { return [] }

        struct ProfileRow: Decodable {
            let id: UUID?
            let email: String?
            let display_name: String?
            let avatar_url: String?
        }

        do {
            let rows: [ProfileRow] = try await supabase
                .from("user_profiles")
                .select("id,email,display_name,avatar_url")
                .in("id", values: userIds)
                .execute()
                .value

            return rows.compactMap { row in
                guard let id = row.id else { return nil }
                let name = (row.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let display = !name.isEmpty ? name : (row.email?.split(separator: "@").first.map(String.init) ?? "Player")
                return UserPreview(id: id, displayName: display, avatarURL: row.avatar_url)
            }
        } catch {
            return []
        }
    }
}

