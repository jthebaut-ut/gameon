import Foundation
import Supabase

/// Lightweight moderation foundation (blocking + reporting).
/// Server-side enforcement (RLS + DB constraints/triggers) is still required for full protection.
/// This layer is intentionally small and used only where needed.
@MainActor
final class ModerationService {

    enum ReportCategory: String, CaseIterable, Identifiable {
        case spam = "Spam"
        case harassment = "Harassment"
        case fakeAccount = "Fake account"
        case inappropriateContent = "Inappropriate content"
        case other = "Other"

        var id: String { rawValue }
    }

    struct BlockedUsersRow: Decodable {
        let blocker_user_id: UUID?
        let blocked_user_id: UUID?
        let created_at: String?
    }

    struct BlockInsert: Encodable {
        let blocker_user_id: UUID
        let blocked_user_id: UUID
    }

    struct ReportInsert: Encodable {
        let reporter_user_id: UUID
        let reported_user_id: UUID
        let category: String
        let details: String?
    }

    func fetchBlockedUserIds(blockerUserId: UUID) async throws -> Set<UUID> {
        let rows: [BlockedUsersRow] = try await supabase
            .from("blocked_users")
            .select("blocked_user_id")
            .eq("blocker_user_id", value: blockerUserId)
            .execute()
            .value
        return Set(rows.compactMap { $0.blocked_user_id })
    }

    func block(blockerUserId: UUID, blockedUserId: UUID) async throws {
        try await supabase
            .from("blocked_users")
            .insert(BlockInsert(blocker_user_id: blockerUserId, blocked_user_id: blockedUserId))
            .execute()
    }

    func report(reporterUserId: UUID, reportedUserId: UUID, category: ReportCategory, details: String?) async throws {
        let trimmedDetails = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await supabase
            .from("user_reports")
            .insert(
                ReportInsert(
                    reporter_user_id: reporterUserId,
                    reported_user_id: reportedUserId,
                    category: category.rawValue,
                    details: (trimmedDetails?.isEmpty == false) ? trimmedDetails : nil
                )
            )
            .execute()
    }
}

