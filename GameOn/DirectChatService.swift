import Foundation
import Supabase

/// PostgREST + RPC for 1:1 direct chat. Does not touch ``MapViewModel``.
///
/// **Schema note:** When migration `20260510_0001_private_messaging_safety.sql` (or equivalent) is applied,
/// `direct_messages.is_deleted` is used to hide moderated rows. Until then, queries fall back to `deleted_at`-only filtering
/// so chat keeps working if the column is missing.
final class DirectChatService {

    private let client: SupabaseClient

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

    /// Clears/hides conversation history for participants (same RPC as in-app “Clear chat history”). Server defines semantics.
    func clearDirectConversation(conversationId: UUID) async throws {
        struct Params: Encodable {
            let p_conversation_id: UUID
        }
        try await client
            .rpc("clear_direct_conversation", params: Params(p_conversation_id: conversationId))
            .execute()
    }

    /// Latest `limit` messages, oldest-first for natural scrolling.
    func fetchLatestMessages(conversationId: UUID, limit: Int = 50) async throws -> [DirectMessageRow] {
        do {
            return try await fetchLatestMessagesWithIsDeletedFilter(conversationId: conversationId, limit: limit)
        } catch {
            if Self.shouldFallbackToLegacyDirectMessagesQuery(error) {
                return try await fetchLatestMessagesDeletedAtOnly(conversationId: conversationId, limit: limit)
            }
            throw error
        }
    }

    func sendMessage(conversationId: UUID, senderId: UUID, body: String) async throws -> DirectMessageRow {
        let insert = DirectMessageInsert(
            conversation_id: conversationId,
            sender_id: senderId,
            body: body
        )
        return try await client
            .from("direct_messages")
            .insert(insert)
            .select()
            .single()
            .execute()
            .value
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

    /// Postgres INSERTs for this conversation. Unsubscribe with ``removeRealtimeChannel`` when the thread closes.
    func directMessagesInsertChannel(conversationId: UUID) -> (RealtimeChannelV2, AsyncStream<InsertAction>) {
        let channel = client.channel("dm:\(conversationId.uuidString.lowercased())")
        let stream = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "direct_messages",
            filter: .eq("conversation_id", value: conversationId.uuidString.lowercased())
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

    private func fetchLatestMessagesWithIsDeletedFilter(conversationId: UUID, limit: Int) async throws -> [DirectMessageRow] {
        let rows: [DirectMessageRow] = try await client
            .from("direct_messages")
            .select()
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .or("is_deleted.is.null,is_deleted.eq.false")
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows.reversed()
    }

    private func fetchLatestMessagesDeletedAtOnly(conversationId: UUID, limit: Int) async throws -> [DirectMessageRow] {
        let rows: [DirectMessageRow] = try await client
            .from("direct_messages")
            .select()
            .eq("conversation_id", value: conversationId)
            .is("deleted_at", value: nil)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows.reversed()
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
