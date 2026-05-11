import Foundation
import Supabase

// MARK: - Report categories (stored as plain strings in `user_reports` / `conversation_reports` / `message_reports`)
// TODO: Align copy with in-app Community Guidelines / Terms of Service links when available.

/// Thrown only from ``ModerationService/reportConversation(conversationId:otherUserId:category:details:recentContextForModerationEmail:)`` for client-safe handling.
enum ModerationConversationReportError: LocalizedError, Equatable {
    case duplicateOpenReport
    case detailsTooLong(max: Int)
    case detailsProhibitedContent

    var errorDescription: String? {
        switch self {
        case .duplicateOpenReport:
            return "You already reported this conversation. GameOn administration will review it."
        case .detailsTooLong(let max):
            return "Details may be at most \(max) characters."
        case .detailsProhibitedContent:
            return ModerationService.profanityRejectionUserMessage()
        }
    }
}

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

    /// User-visible copy when a report insert fails (missing migration, RLS, etc.).
    static func userFacingReportSubmitError(_ error: Error) -> String {
        let raw = error.localizedDescription
        let s = raw.lowercased()
        if s.contains("could not find the table")
            || (s.contains("relation") && s.contains("does not exist"))
            || s.contains("schema cache") || s.contains("pgrst205")
            || s.contains("42p01") {
            return "Reporting isn’t available on the server yet. Please try again after an update, or contact support if this continues."
        }
        if s.contains("42703") || s.contains("undefined column") || (s.contains("column") && s.contains("does not exist")) {
            return "The reporting database isn’t fully updated yet. Please try again later or contact support."
        }
        if s.contains("user_reports") || s.contains("conversation_reports") || s.contains("message_reports")
            || s.contains("venue_reports") {
            return "We couldn’t save your report. This feature may still be rolling out—please try again later."
        }
        if s.contains("permission denied") || s.contains("new row violates row-level security") || s.contains("rls") {
            return "We couldn’t save your report. Please sign in again or contact support if this keeps happening."
        }
        return raw
    }

    static func logReportSubmitFailure(_ error: Error, context: String) {
#if DEBUG
        print("Moderation: report insert failed [\(context)]:", error)
#endif
    }

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

    private struct VenueReportInsert: Encodable {
        let reporter_user_id: UUID
        let venue_id: UUID
        let category: String
        let details: String?
        let status: String
    }

    /// Edge function derives reporter from JWT (`auth.getUser()`); do not send client `reporter_user_id`.
    private struct NotifyModerationReportPayload: Encodable {
        let report_type: String
        let reported_user_id: UUID
        let category: String
        let details: String?
        let created_at: String
        let conversation_id: UUID?
        let message_id: UUID?
        let message_text_snapshot: String?
        /// Admin email only: recent DM lines for conversation reports (not stored in `conversation_reports`).
        let conversation_recent_context: String?
    }

    private struct NotifyModerationReportResponse: Decodable {
        let ok: Bool?
        let error: String?
    }

    private struct NotifyCommentModerationAlertPayload: Encodable {
        let comment_id: String
    }

    private struct NotifyCommentModerationAlertResponse: Decodable {
        let ok: Bool?
        let skipped: Bool?
        let error: String?
    }

    private static let moderationReportNotifyISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Fire-and-forget admin email via Edge Function; must run only after the report row is stored.
    private func notifyModerationReportBestEffort(
        reportType: String,
        reportedUserId: UUID,
        category: ModerationReportCategory,
        details: String?,
        conversationId: UUID? = nil,
        messageId: UUID? = nil,
        messageTextSnapshot: String? = nil,
        conversationRecentContext: String? = nil
    ) {
        let createdAt = Self.moderationReportNotifyISO.string(from: Date()) ?? ""
        let detailsCopy = details
        let categoryRaw = category.rawValue
        let contextCopy = conversationRecentContext
        Task.detached { [supabase] in
#if DEBUG
            print("Moderation: notify-moderation-report fire-and-forget started (type=\(reportType))")
#endif
            let payload = NotifyModerationReportPayload(
                report_type: reportType,
                reported_user_id: reportedUserId,
                category: categoryRaw,
                details: detailsCopy,
                created_at: createdAt,
                conversation_id: conversationId,
                message_id: messageId,
                message_text_snapshot: messageTextSnapshot,
                conversation_recent_context: contextCopy
            )
            do {
                let response: NotifyModerationReportResponse = try await supabase.functions.invoke(
                    "notify-moderation-report",
                    options: FunctionInvokeOptions(method: .post, body: payload)
                )
#if DEBUG
                print("Moderation: notify-moderation-report finished ok=\(response.ok ?? false) error=\(response.error ?? "nil")")
#endif
            } catch let error as FunctionsError {
#if DEBUG
                if case let .httpError(status, data) = error {
                    let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                    print("Moderation: notify-moderation-report email notify failed httpError status=\(status) body=\(body)")
                } else {
                    print("Moderation: notify-moderation-report email notify failed FunctionsError:", error)
                }
#endif
            } catch {
#if DEBUG
                print("Moderation: notify-moderation-report email notify failed:", error)
#endif
            }
        }
    }

    /// Fire-and-forget admin email when a comment crosses the auto-hide report threshold (Edge Function sends at most once per comment).
    func notifyCommentModerationAlertBestEffort(commentId: UUID) {
        let idCopy = commentId
        Task.detached { [supabase] in
#if DEBUG
            print("Moderation: notify-comment-moderation-alert fire-and-forget comment=\(idCopy.uuidString)")
#endif
            let payload = NotifyCommentModerationAlertPayload(comment_id: idCopy.uuidString)
            do {
                let response: NotifyCommentModerationAlertResponse = try await supabase.functions.invoke(
                    "notify-comment-moderation-alert",
                    options: FunctionInvokeOptions(method: .post, body: payload)
                )
#if DEBUG
                print(
                    "Moderation: notify-comment-moderation-alert finished ok=\(response.ok ?? false) skipped=\(response.skipped ?? false) error=\(response.error ?? "nil")"
                )
#endif
            } catch let error as FunctionsError {
#if DEBUG
                if case let .httpError(status, data) = error {
                    let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                    print("Moderation: notify-comment-moderation-alert failed httpError status=\(status) body=\(body)")
                } else {
                    print("Moderation: notify-comment-moderation-alert failed FunctionsError:", error)
                }
#endif
            } catch {
#if DEBUG
                print("Moderation: notify-comment-moderation-alert failed:", error)
#endif
            }
        }
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
        notifyModerationReportBestEffort(
            reportType: "user",
            reportedUserId: reportedUserId,
            category: category,
            details: row.details,
            conversationRecentContext: nil
        )
    }

    /// Max length for optional conversation report details (client + server aligned).
    static let conversationReportDetailsMaxCharacters = 500

    private static func isPostgresUniqueViolation(_ error: Error) -> Bool {
        if let pe = error as? PostgrestError, pe.code == "23505" {
            return true
        }
        let blob = "\(error.localizedDescription) \(String(describing: error))".lowercased()
        if blob.contains("23505") || blob.contains("duplicate key") || blob.contains("unique constraint") {
            return true
        }
        if let pe = error as? PostgrestError {
            let detail = "\(pe.message) \(pe.detail ?? "") \(pe.hint ?? "")".lowercased()
            if detail.contains("duplicate") || detail.contains("unique") || detail.contains("23505") {
                return true
            }
        }
        return false
    }

    /// Normalizes optional report details: empty → `nil`, enforces length and profanity (empty allowed).
    private static func normalizedConversationReportDetails(_ raw: String?) throws -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return nil }
        if trimmed.count > Self.conversationReportDetailsMaxCharacters {
            throw ModerationConversationReportError.detailsTooLong(max: Self.conversationReportDetailsMaxCharacters)
        }
        if Self.containsProfanity(trimmed) {
            throw ModerationConversationReportError.detailsProhibitedContent
        }
        return trimmed
    }

    func reportConversation(
        conversationId: UUID,
        otherUserId: UUID,
        category: ModerationReportCategory,
        details: String?,
        recentContextForModerationEmail: String?
    ) async throws {
        let me = try await currentUserId()
        let normalizedDetails = try Self.normalizedConversationReportDetails(details)
        let row = ConversationReportInsert(
            reporter_user_id: me,
            reported_user_id: otherUserId,
            conversation_id: conversationId,
            category: category.rawValue,
            details: normalizedDetails,
            status: "open"
        )
        do {
            _ = try await supabase
                .from("conversation_reports")
                .insert(row)
                .execute()
        } catch {
            if Self.isPostgresUniqueViolation(error) {
                throw ModerationConversationReportError.duplicateOpenReport
            }
            throw error
        }

#if DEBUG
        print("[DMReport] conversation report submitted conversation=\(conversationId.uuidString)")
#endif

        let boundedContext: String? = {
            guard let raw = recentContextForModerationEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            if raw.count > 14_000 {
                return String(raw.prefix(14_000)) + "\n… [truncated]"
            }
            return raw
        }()

        notifyModerationReportBestEffort(
            reportType: "conversation",
            reportedUserId: otherUserId,
            category: category,
            details: row.details,
            conversationId: conversationId,
            conversationRecentContext: boundedContext
        )

#if DEBUG
        print("[DMReport] moderation email queued conversation=\(conversationId.uuidString)")
#endif
    }

    func reportMessage(
        messageId: UUID,
        reportedUserId: UUID,
        messageTextSnapshot: String,
        category: ModerationReportCategory,
        details: String?,
        conversationId: UUID? = nil
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
        notifyModerationReportBestEffort(
            reportType: "message",
            reportedUserId: reportedUserId,
            category: category,
            details: row.details,
            conversationId: conversationId,
            messageId: messageId,
            messageTextSnapshot: messageTextSnapshot,
            conversationRecentContext: nil
        )
        await incrementMessageReportCountBestEffort(messageId: messageId)
    }

    func reportVenue(venueId: UUID, category: ModerationReportCategory, details: String?) async throws {
        let me = try await currentUserId()
        let row = VenueReportInsert(
            reporter_user_id: me,
            venue_id: venueId,
            category: category.rawValue,
            details: details.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
            status: "open"
        )
        _ = try await supabase
            .from("venue_reports")
            .insert(row)
            .execute()
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
            let next = current + 1
            if next >= Self.hiddenAfterReportsThreshold {
                struct PatchHide: Encodable {
                    let report_count: Int
                    let is_deleted: Bool
                }
                _ = try await supabase
                    .from("direct_messages")
                    .update(PatchHide(report_count: next, is_deleted: true))
                    .eq("id", value: messageId)
                    .execute()
            } else {
                _ = try await supabase
                    .from("direct_messages")
                    .update(Patch(report_count: next))
                    .eq("id", value: messageId)
                    .execute()
            }
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

        do {
            let previewsById = try await SocialIdentityService().fetchUserPreviews(for: userIds)
            return userIds.compactMap { previewsById[$0] }
        } catch {
            return []
        }
    }
}
