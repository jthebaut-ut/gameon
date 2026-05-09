import Foundation
import Supabase

// MARK: - Report categories (stored as plain strings in `user_reports` / `conversation_reports` / `message_reports`)
// TODO: Align copy with in-app Community Guidelines / Terms of Service links when available.

enum ModerationReportCategory: String, CaseIterable, Identifiable {
    case spam = "spam"
    case harassment = "harassment"
    case fakeAccount = "fake_account"
    case inappropriate = "inappropriate"
    case other = "other"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .spam: return "Spam"
        case .harassment: return "Harassment"
        case .fakeAccount: return "Fake account"
        case .inappropriate: return "Inappropriate content"
        case .other: return "Other"
        }
    }
}

/// Lightweight moderation helpers used by Chat surfaces.
/// - Important: Client checks are UX-only. **Server-side RLS + RPC rate limits** are required for real enforcement.
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

    private struct UserReportInsert: Encodable {
        let reporter_user_id: UUID
        let reported_user_id: UUID
        let category: String
        let details: String?
    }

    private struct ConversationReportInsert: Encodable {
        let reporter_user_id: UUID
        let reported_user_id: UUID
        let conversation_id: UUID
        let category: String
        let details: String?
        let status: String
    }

    private struct MessageReportInsert: Encodable {
        let reporter_user_id: UUID
        let reported_user_id: UUID
        let message_id: UUID
        let message_text_snapshot: String
        let category: String
        let details: String?
        let status: String
    }

    func currentUserId() async throws -> UUID {
        let session = try await supabase.auth.session
        return session.user.id
    }

    /// Users I have blocked.
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

    /// Users who have blocked me (reverse direction).
    func fetchUsersWhoBlockedMeIds() async throws -> Set<UUID> {
        let me = try await currentUserId()
        let rows: [BlockedUserRow] = try await supabase
            .from("blocked_users")
            .select("blocker_user_id,created_at")
            .eq("blocked_user_id", value: me)
            .execute()
            .value
        return Set(rows.compactMap { $0.blocker_user_id })
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

    func reportUser(reportedUserId: UUID, category: ModerationReportCategory, details: String?) async throws {
        let me = try await currentUserId()
        let row = UserReportInsert(
            reporter_user_id: me,
            reported_user_id: reportedUserId,
            category: category.rawValue,
            details: details.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
        _ = try await supabase
            .from("user_reports")
            .insert(row)
            .execute()
    }

    func reportConversation(
        conversationId: UUID,
        otherUserId: UUID,
        category: ModerationReportCategory,
        details: String?
    ) async throws {
        let me = try await currentUserId()
        let row = ConversationReportInsert(
            reporter_user_id: me,
            reported_user_id: otherUserId,
            conversation_id: conversationId,
            category: category.rawValue,
            details: details.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
            status: "open"
        )
        _ = try await supabase
            .from("conversation_reports")
            .insert(row)
            .execute()
    }

    func reportMessage(
        messageId: UUID,
        reportedUserId: UUID,
        messageTextSnapshot: String,
        category: ModerationReportCategory,
        details: String?
    ) async throws {
        let me = try await currentUserId()
        let row = MessageReportInsert(
            reporter_user_id: me,
            reported_user_id: reportedUserId,
            message_id: messageId,
            message_text_snapshot: messageTextSnapshot,
            category: category.rawValue,
            details: details.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
            status: "open"
        )
        _ = try await supabase
            .from("message_reports")
            .insert(row)
            .execute()
        await incrementMessageReportCountBestEffort(messageId: messageId)
    }

    /// Best-effort increment of `direct_messages.report_count` for admin review queues.
    private func incrementMessageReportCountBestEffort(messageId: UUID) async {
        struct Row: Decodable { let report_count: Int? }
        struct Patch: Encodable { let report_count: Int }

        do {
            let rows: [Row] = try await supabase
                .from("direct_messages")
                .select("report_count")
                .eq("id", value: messageId)
                .limit(1)
                .execute()
                .value
            let current = rows.first?.report_count ?? 0
            _ = try await supabase
                .from("direct_messages")
                .update(Patch(report_count: current + 1))
                .eq("id", value: messageId)
                .execute()
        } catch {
            // Column may be missing until migration is applied; report row is still stored.
#if DEBUG
            print("Moderation: increment report_count skipped:", error)
#endif
        }
    }

    /// Best-effort lookup for display names/avatars/emails for blocked ids.
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
