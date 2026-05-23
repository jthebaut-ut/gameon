import Foundation
import Supabase

/// PostgREST + RPC for 1:1 direct chat. Does not touch ``MapViewModel``.
///
/// **Schema note:** When migration `20260510_0001_private_messaging_safety.sql` (or equivalent) is applied,
/// `direct_messages.is_deleted` is used to hide moderated rows. Until then, queries fall back to `deleted_at`-only filtering
/// so chat keeps working if the column is missing.
final class DirectChatService {

    private let client: SupabaseClient

    /// Minimal columns for list/decoding (avoid `select()` wildcard at scale).
    private static let directMessageListColumns =
        "id,conversation_id,sender_id,body,created_at,deleted_at,report_count,is_deleted"

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    /// Inbox summaries for Chat → Friends (one row per accepted friend).
    func fetchInboxSummaries() async throws -> [DmInboxSummaryRow] {
        try await client
            .rpc("get_dm_inbox_summaries")
            .execute()
            .value
    }

    /// Ensures a `direct_conversations` row exists for the current user and friend (accepted friendship required).
    func startDirectConversation(friendUserId: UUID) async throws -> UUID {
        struct Params: Encodable {
            let p_friend_user_id: UUID
        }

        let data = try await client
            .rpc("start_direct_conversation", params: Params(p_friend_user_id: friendUserId))
            .execute()
            .data

        return try Self.decodeUUIDFromRPCData(data)
    }

    /// Looks up an existing 1:1 conversation without creating a new one. This keeps old DMs readable
    /// when the friendship row is no longer accepted, such as after account deletion cleanup.
    func fetchExistingConversationId(peerUserId: UUID) async throws -> UUID? {
        let me = try await currentUserId()
        let meId = me.uuidString.lowercased()
        let peerId = peerUserId.uuidString.lowercased()
        let filter = "and(user_a_id.eq.\(meId),user_b_id.eq.\(peerId)),and(user_a_id.eq.\(peerId),user_b_id.eq.\(meId))"
        let rows: [DirectConversationIdRow] = try await client
            .from("direct_conversations")
            .select("id")
            .or(filter)
            .limit(1)
            .execute()
            .value
        return rows.first?.id
    }

    /// Clears/hides conversation history for participants (same RPC as in-app “Clear chat history”). Server defines semantics.
    func clearDirectConversation(conversationId: UUID) async throws {
        struct Params: Encodable {
            let p_conversation_id: UUID
        }
        try await client
            .rpc("clear_direct_conversation", params: Params(p_conversation_id: conversationId))
            .execute()
    }

    /// Latest `limit` messages, oldest-first for natural scrolling (key-ordered by `created_at`, `id` DESC server-side).
    func fetchLatestMessages(conversationId: UUID, limit: Int = 50) async throws -> [DirectMessageRow] {
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        #endif
        let rows: [DirectMessageRow]
        do {
            rows = try await fetchLatestMessagesWithIsDeletedFilter(conversationId: conversationId, limit: limit)
        } catch {
            if Self.shouldFallbackToLegacyDirectMessagesQuery(error) {
                rows = try await fetchLatestMessagesDeletedAtOnly(conversationId: conversationId, limit: limit)
            } else {
                throw error
            }
        }
        #if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print("[DMPagination] initial load: \(String(format: "%.1f", ms))ms rows=\(rows.count) limit=\(limit)")
        #endif
        return rows
    }

    /// Older messages strictly before `(beforeCreatedAt, beforeMessageId)` in `(created_at DESC, id DESC)` order.
    /// Returns oldest-first within the page (ready to prepend to an existing oldest-first timeline).
    func fetchOlderMessages(
        conversationId: UUID,
        beforeCreatedAt: Date,
        beforeMessageId: UUID,
        limit: Int = 50
    ) async throws -> [DirectMessageRow] {
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        #endif
        let rows: [DirectMessageRow]
        do {
            rows = try await fetchOlderMessagesWithIsDeletedFilter(
                conversationId: conversationId,
                beforeCreatedAt: beforeCreatedAt,
                beforeMessageId: beforeMessageId,
                limit: limit
            )
        } catch {
            if Self.shouldFallbackToLegacyDirectMessagesQuery(error) {
                rows = try await fetchOlderMessagesDeletedAtOnly(
                    conversationId: conversationId,
                    beforeCreatedAt: beforeCreatedAt,
                    beforeMessageId: beforeMessageId,
                    limit: limit
                )
            } else {
                throw error
            }
        }
        #if DEBUG
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print("[DMPagination] older page: \(String(format: "%.1f", ms))ms rows=\(rows.count) limit=\(limit)")
        #endif
        return rows
    }

    /// Messages strictly after `(afterCreatedAt, afterMessageId)` in chronological order (oldest-first).
    /// Uses the same PostgREST keyset pattern as ``fetchOlderMessages`` / ``keysetOlderThanOrFilter``.
    func fetchMessagesNewerThanAnchor(
        conversationId: UUID,
        afterCreatedAt: Date,
        afterMessageId: UUID,
        limit: Int = 50
    ) async throws -> [DirectMessageRow] {
        let rows: [DirectMessageRow]
        do {
            rows = try await fetchNewerMessagesWithIsDeletedFilter(
                conversationId: conversationId,
                afterCreatedAt: afterCreatedAt,
                afterMessageId: afterMessageId,
                limit: limit
            )
        } catch {
            if Self.shouldFallbackToLegacyDirectMessagesQuery(error) {
                rows = try await fetchNewerMessagesDeletedAtOnly(
                    conversationId: conversationId,
                    afterCreatedAt: afterCreatedAt,
                    afterMessageId: afterMessageId,
                    limit: limit
                )
            } else {
                throw error
            }
        }
        return rows
    }

    /// Fetches only the user-selected moderation review window for a private conversation report.
    func fetchMessagesForReportSnapshot(conversationId: UUID, from start: Date, to end: Date) async throws -> [DirectMessageRow] {
        do {
            return try await fetchMessagesForReportSnapshotWithIsDeletedFilter(
                conversationId: conversationId,
                from: start,
                to: end
            )
        } catch {
            if Self.shouldFallbackToLegacyDirectMessagesQuery(error) {
                return try await fetchMessagesForReportSnapshotDeletedAtOnly(
                    conversationId: conversationId,
                    from: start,
                    to: end
                )
            }
            throw error
        }
    }

    func sendMessage(
        conversationId: UUID,
        senderId: UUID,
        body: String,
        diagnosticCorrelationId: UUID? = nil
    ) async throws -> DirectMessageRow {
#if DEBUG
        if let c = diagnosticCorrelationId {
            DMRealtimeDiagnostics.log(
                "phase=db_insert_start correlation=\(c.uuidString.lowercased()) conversation=\(conversationId.uuidString.lowercased())"
            )
        }
#endif
        let insert = DirectMessageInsert(
            conversation_id: conversationId,
            sender_id: senderId,
            body: body
        )
        let row: DirectMessageRow = try await client
            .from("direct_messages")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
#if DEBUG
        if let c = diagnosticCorrelationId {
            DMRealtimeDiagnostics.log(
                "phase=db_insert_completed correlation=\(c.uuidString.lowercased()) messageId=\(row.id.uuidString.lowercased()) serverCreatedAt=\(row.created_at ?? "nil")"
            )
        }
#endif
        return row
    }

    func currentUserId() async throws -> UUID {
        let session = try await client.auth.session
        return session.user.id
    }

    /// Upserts the current user’s read cursor for a conversation (`conversation_read_state` PK).
    func markConversationRead(conversationId: UUID, userId: UUID, lastReadAt: Date) async throws {
        let row = ConversationReadStateUpsert(
            conversation_id: conversationId,
            user_id: userId,
            last_read_at: Self.isoTimestamp(lastReadAt)
        )
        try await client
            .from("conversation_read_state")
            .upsert(row, onConflict: "conversation_id,user_id")
            .execute()
    }

    // MARK: - Realtime (direct thread only)

    /// Same INSERT filter shape as inbox realtime when scoped: `conversation_id=eq.<uuid>` (matches ``RealtimePostgresFilter`` encoding).
    /// RLS still gates which rows reach the client; this narrows the postgres_changes binding like `RealtimePostgresFilter.in(...)` does for the inbox.
    static func directMessagesThreadRealtimeFilterDescription(conversationId: UUID) -> String {
        "conversation_id=eq.\(conversationId.uuidString.lowercased())"
    }

    /// Stable topic (hyphenated, inbox-style) + filtered postgres INSERT on ``public.direct_messages`` for one conversation.
    func directMessagesInsertChannel(conversationId: UUID) -> (RealtimeChannelV2, AsyncStream<InsertAction>) {
        let cidLower = conversationId.uuidString.lowercased()
        let channel = client.channel("dm-thread-\(cidLower)")
        let filter = RealtimePostgresFilter.eq("conversation_id", value: cidLower)
        let stream = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "direct_messages",
            filter: filter
        )
        return (channel, stream)
    }

    func removeRealtimeChannel(_ channel: RealtimeChannelV2) async {
        await client.removeChannel(channel)
    }

    /// Total unread peer messages for the signed-in user. Prefers single RPC ``get_dm_unread_total`` (50k-scale);
    /// falls back to per-conversation counts if the RPC is missing or errors.
    func fetchUnreadDirectMessageCount(currentUserId me: UUID) async throws -> Int {
        do {
            let response = try await client.rpc("get_dm_unread_total").execute()
            let total = try Self.decodeIntFromRPCData(response.data)
            return max(0, total)
        } catch {
            return try await fetchUnreadDirectMessageCountFanOut(currentUserId: me)
        }
    }

    /// Legacy path: one PostgREST count per conversation (O(#conversations) round-trips). Kept only as RPC fallback.
    private func fetchUnreadDirectMessageCountFanOut(currentUserId me: UUID) async throws -> Int {
        let conversationIds = try await fetchMyConversationIds(userId: me)
        if conversationIds.isEmpty { return 0 }

        let readRows: [ConversationReadStateRow] = try await client
            .from("conversation_read_state")
            .select()
            .eq("user_id", value: me)
            .in("conversation_id", values: conversationIds)
            .execute()
            .value

        var readThrough: [UUID: Date] = [:]
        for row in readRows {
            guard let cid = row.conversation_id else { continue }
            if let raw = row.last_read_at, let d = Self.parseISO8601(raw) {
                readThrough[cid] = d
            }
        }

        let supabase = client
        return try await withThrowingTaskGroup(of: Int.self) { group in
            for cid in conversationIds {
                let threshold = readThrough[cid] ?? Date(timeIntervalSince1970: 0)
                group.addTask {
                    try await Self.countUnreadPeerMessagesWithFallback(
                        client: supabase,
                        conversationId: cid,
                        readerId: me,
                        after: threshold
                    )
                }
            }
            var sum = 0
            for try await n in group {
                sum += n
            }
            return sum
        }
    }

    /// Conversation ids the current user participates in (same logic as unread fan-out).
    /// Used by Chat inbox Realtime to optionally scope `postgresChange` filters when the list is small.
    func fetchMyDirectConversationIds(userId: UUID) async throws -> [UUID] {
        try await fetchMyConversationIds(userId: userId)
    }

    private func fetchMyConversationIds(userId: UUID) async throws -> [UUID] {
        let filter = "user_a_id.eq.\(userId.uuidString.lowercased()),user_b_id.eq.\(userId.uuidString.lowercased())"
        let rows: [DirectConversationIdRow] = try await client
            .from("direct_conversations")
            .select("id")
            .or(filter)
            .execute()
            .value
        return rows.compactMap(\.id)
    }

    /// PostgREST `or` for keyset “older than” `(created_at, id)` when listing in `created_at DESC, id DESC` order.
    private static func keysetOlderThanOrFilter(createdAt: Date, messageId: UUID) -> String {
        let iso = isoTimestamp(createdAt)
        let uid = messageId.uuidString.lowercased()
        return "created_at.lt.\(iso),and(created_at.eq.\(iso),id.lt.\(uid))"
    }

    /// PostgREST `or` for keyset “newer than” `(created_at, id)` when listing in `created_at ASC, id ASC` order.
    private static func keysetNewerThanOrFilter(createdAt: Date, messageId: UUID) -> String {
        let iso = isoTimestamp(createdAt)
        let uid = messageId.uuidString.lowercased()
        return "created_at.gt.\(iso),and(created_at.eq.\(iso),id.gt.\(uid))"
    }

    private func fetchLatestMessagesWithIsDeletedFilter(conversationId: UUID, limit: Int) async throws -> [DirectMessageRow] {
        let rows: [DirectMessageRow] = try await client
            .from("direct_messages")
            .select(Self.directMessageListColumns)
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .or("is_deleted.is.null,is_deleted.eq.false")
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows.reversed()
    }

    private func fetchLatestMessagesDeletedAtOnly(conversationId: UUID, limit: Int) async throws -> [DirectMessageRow] {
        let rows: [DirectMessageRow] = try await client
            .from("direct_messages")
            .select(Self.directMessageListColumns)
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows.reversed()
    }

    private func fetchOlderMessagesWithIsDeletedFilter(
        conversationId: UUID,
        beforeCreatedAt: Date,
        beforeMessageId: UUID,
        limit: Int
    ) async throws -> [DirectMessageRow] {
        let rows: [DirectMessageRow] = try await client
            .from("direct_messages")
            .select(Self.directMessageListColumns)
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .or("is_deleted.is.null,is_deleted.eq.false")
            .or(Self.keysetOlderThanOrFilter(createdAt: beforeCreatedAt, messageId: beforeMessageId))
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows.reversed()
    }

    private func fetchOlderMessagesDeletedAtOnly(
        conversationId: UUID,
        beforeCreatedAt: Date,
        beforeMessageId: UUID,
        limit: Int
    ) async throws -> [DirectMessageRow] {
        let rows: [DirectMessageRow] = try await client
            .from("direct_messages")
            .select(Self.directMessageListColumns)
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .or(Self.keysetOlderThanOrFilter(createdAt: beforeCreatedAt, messageId: beforeMessageId))
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows.reversed()
    }

    private func fetchNewerMessagesWithIsDeletedFilter(
        conversationId: UUID,
        afterCreatedAt: Date,
        afterMessageId: UUID,
        limit: Int
    ) async throws -> [DirectMessageRow] {
        let rows: [DirectMessageRow] = try await client
            .from("direct_messages")
            .select(Self.directMessageListColumns)
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .or("is_deleted.is.null,is_deleted.eq.false")
            .or(Self.keysetNewerThanOrFilter(createdAt: afterCreatedAt, messageId: afterMessageId))
            .order("created_at", ascending: true)
            .order("id", ascending: true)
            .limit(limit)
            .execute()
            .value
        return rows
    }

    private func fetchNewerMessagesDeletedAtOnly(
        conversationId: UUID,
        afterCreatedAt: Date,
        afterMessageId: UUID,
        limit: Int
    ) async throws -> [DirectMessageRow] {
        let rows: [DirectMessageRow] = try await client
            .from("direct_messages")
            .select(Self.directMessageListColumns)
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .or(Self.keysetNewerThanOrFilter(createdAt: afterCreatedAt, messageId: afterMessageId))
            .order("created_at", ascending: true)
            .order("id", ascending: true)
            .limit(limit)
            .execute()
            .value
        return rows
    }

    private func fetchMessagesForReportSnapshotWithIsDeletedFilter(
        conversationId: UUID,
        from start: Date,
        to end: Date
    ) async throws -> [DirectMessageRow] {
        let rows: [DirectMessageRow] = try await client
            .from("direct_messages")
            .select(Self.directMessageListColumns)
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .or("is_deleted.is.null,is_deleted.eq.false")
            .gte("created_at", value: Self.isoTimestamp(start))
            .lte("created_at", value: Self.isoTimestamp(end))
            .order("created_at", ascending: true)
            .order("id", ascending: true)
            .execute()
            .value
        return rows
    }

    private func fetchMessagesForReportSnapshotDeletedAtOnly(
        conversationId: UUID,
        from start: Date,
        to end: Date
    ) async throws -> [DirectMessageRow] {
        let rows: [DirectMessageRow] = try await client
            .from("direct_messages")
            .select(Self.directMessageListColumns)
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .gte("created_at", value: Self.isoTimestamp(start))
            .lte("created_at", value: Self.isoTimestamp(end))
            .order("created_at", ascending: true)
            .order("id", ascending: true)
            .execute()
            .value
        return rows
    }

    /// Postgres / PostgREST errors when `is_deleted` has not been migrated yet.
    private static func shouldFallbackToLegacyDirectMessagesQuery(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        if text.contains("is_deleted") {
            if text.contains("does not exist") { return true }
            if text.contains("undefined column") { return true }
            if text.contains("42703") { return true } // undefined_column
        }
        return false
    }

    private static func countUnreadPeerMessagesWithFallback(
        client: SupabaseClient,
        conversationId: UUID,
        readerId: UUID,
        after threshold: Date
    ) async throws -> Int {
        do {
            return try await countUnreadPeerMessagesWithIsDeleted(
                client: client,
                conversationId: conversationId,
                readerId: readerId,
                after: threshold
            )
        } catch {
            if shouldFallbackToLegacyDirectMessagesQuery(error) {
                return try await countUnreadPeerMessagesDeletedAtOnly(
                    client: client,
                    conversationId: conversationId,
                    readerId: readerId,
                    after: threshold
                )
            }
            throw error
        }
    }

    private static func countUnreadPeerMessagesWithIsDeleted(
        client: SupabaseClient,
        conversationId: UUID,
        readerId: UUID,
        after threshold: Date
    ) async throws -> Int {
        let iso = isoTimestamp(threshold)
        let response = try await client
            .from("direct_messages")
            .select("id", count: .exact)
            .eq("conversation_id", value: conversationId)
            .neq("sender_id", value: readerId)
            .is("deleted_at", value: nil)
            .or("is_deleted.is.null,is_deleted.eq.false")
            .gt("created_at", value: iso)
            .execute()
        return response.count ?? 0
    }

    private static func countUnreadPeerMessagesDeletedAtOnly(
        client: SupabaseClient,
        conversationId: UUID,
        readerId: UUID,
        after threshold: Date
    ) async throws -> Int {
        let iso = isoTimestamp(threshold)
        let response = try await client
            .from("direct_messages")
            .select("id", count: .exact)
            .eq("conversation_id", value: conversationId)
            .neq("sender_id", value: readerId)
            .is("deleted_at", value: nil)
            .gt("created_at", value: iso)
            .execute()
        return response.count ?? 0
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: raw) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: raw)
    }

    /// PostgREST often returns a scalar UUID as a JSON string (quoted).
    /// Decodes a scalar integer returned by PostgREST RPC (JSON number, possibly quoted).
    private static func decodeIntFromRPCData(_ data: Data) throws -> Int {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw DirectChatServiceError.unexpectedRPCPayload
        }
        let stripped = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard let n = Int(stripped) else {
            throw DirectChatServiceError.unexpectedRPCPayload
        }
        return n
    }

    private static func decodeUUIDFromRPCData(_ data: Data) throws -> UUID {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw DirectChatServiceError.unexpectedRPCPayload
        }
        let stripped = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard let u = UUID(uuidString: stripped) else {
            throw DirectChatServiceError.unexpectedRPCPayload
        }
        return u
    }
}

private struct DirectMessageInsert: Encodable {
    let conversation_id: UUID
    let sender_id: UUID
    let body: String
}

private struct DirectConversationIdRow: Decodable {
    let id: UUID?
}

private struct ConversationReadStateRow: Decodable {
    let conversation_id: UUID?
    let user_id: UUID?
    let last_read_at: String?
}

private struct ConversationReadStateUpsert: Encodable {
    let conversation_id: UUID
    let user_id: UUID
    let last_read_at: String
}

enum DirectChatServiceError: LocalizedError {
    case unexpectedRPCPayload

    var errorDescription: String? {
        switch self {
        case .unexpectedRPCPayload:
            return "Could not read conversation id from the server."
        }
    }
}
