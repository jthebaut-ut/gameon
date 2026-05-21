import Foundation
import Supabase
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

// MARK: - Lightweight user surface (DM header, friend rows, navigation)

struct UserPreview: Identifiable, Hashable, Codable {
    let id: UUID
    let displayName: String
    /// Stored without `@`, lowercase — nil when unset.
    let username: String?
    let email: String?
    let avatarURL: String?
    /// Smaller avatar for lists/chips; falls back to ``avatarURL`` in views when nil/empty.
    let avatarThumbnailURL: String?
    let isBusinessAccount: Bool

    init(
        id: UUID,
        displayName: String,
        username: String? = nil,
        email: String? = nil,
        avatarURL: String?,
        avatarThumbnailURL: String? = nil,
        isBusinessAccount: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.username = username
        self.email = email
        self.avatarURL = avatarURL
        self.avatarThumbnailURL = avatarThumbnailURL
        self.isBusinessAccount = isBusinessAccount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case username
        case email
        case avatarURL
        case avatarThumbnailURL
        case isBusinessAccount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        avatarThumbnailURL = try container.decodeIfPresent(String.self, forKey: .avatarThumbnailURL)
        isBusinessAccount = try container.decodeIfPresent(Bool.self, forKey: .isBusinessAccount) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try container.encodeIfPresent(avatarThumbnailURL, forKey: .avatarThumbnailURL)
        try container.encode(isBusinessAccount, forKey: .isBusinessAccount)
    }

    var isBusinessIdentity: Bool {
        isBusinessAccount
    }

    /// Public @handle line — uses stored username or temporary email-prefix fallback (never persisted).
    var publicHandleLine: String {
        let stored = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty {
            return FanGeoHandleRules.displayHandle(stored: stored)
        }
        return FanGeoHandleRules.temporaryFallbackHandle(email: email ?? "")
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
    /// `user` (default) or `business` — see migration `20260701_0001_friendships_business_entity_chat.sql`.
    let requester_entity_type: String?
    let addressee_entity_type: String?

    init(
        id: UUID,
        requester_id: UUID,
        addressee_id: UUID,
        status: String?,
        responded_at: String?,
        created_at: String?,
        addressee_cleared_at: String? = nil,
        requester_cleared_at: String? = nil,
        requester_entity_type: String? = nil,
        addressee_entity_type: String? = nil
    ) {
        self.id = id
        self.requester_id = requester_id
        self.addressee_id = addressee_id
        self.status = status
        self.responded_at = responded_at
        self.created_at = created_at
        self.addressee_cleared_at = addressee_cleared_at
        self.requester_cleared_at = requester_cleared_at
        self.requester_entity_type = requester_entity_type
        self.addressee_entity_type = addressee_entity_type
    }

    private enum CodingKeys: String, CodingKey {
        case id, requester_id, addressee_id, status, responded_at, created_at
        case addressee_cleared_at, requester_cleared_at
        case requester_entity_type, addressee_entity_type
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
        requester_entity_type = try c.decodeIfPresent(String.self, forKey: .requester_entity_type)
        addressee_entity_type = try c.decodeIfPresent(String.self, forKey: .addressee_entity_type)
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
        try c.encodeIfPresent(requester_entity_type, forKey: .requester_entity_type)
        try c.encodeIfPresent(addressee_entity_type, forKey: .addressee_entity_type)
    }

    var requesterIsBusiness: Bool {
        (requester_entity_type ?? "user").lowercased() == "business"
    }

    var addresseeIsBusiness: Bool {
        (addressee_entity_type ?? "user").lowercased() == "business"
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
            requester_cleared_at: requester_cleared_at,
            requester_entity_type: requester_entity_type,
            addressee_entity_type: addressee_entity_type
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
            requester_cleared_at: requester_cleared_at,
            requester_entity_type: requester_entity_type,
            addressee_entity_type: addressee_entity_type
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
            requester_cleared_at: clearedAt,
            requester_entity_type: requester_entity_type,
            addressee_entity_type: addressee_entity_type
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

/// Result of Add Friend lookup (manual search sheet): drives green / orange / red copy in ``AddFriendGlassSheet``.
enum AddFriendLookupOutcome: Equatable {
    case success
    case informational(String)
    case error(String)
}

/// Existing friendship row state for a lookup target (after refresh).
enum FriendLookupExistingRelation: Equatable {
    case none
    case accepted
    case pendingOutgoing
    case pendingIncoming
    case declinedVisible
}

/// Social entity kind for Add Friend pending checks (`user_profiles` or `businesses`).
enum FriendSocialEntityKind: String, Equatable {
    case fanUser = "fan_user"
    case businessUser = "business_user"
    case business = "business"
}

struct FriendSocialEntity: Equatable {
    let id: UUID
    let kind: FriendSocialEntityKind
}

/// Add Friend / chat search hit: `entityId` is `user_profiles.id` or `businesses.id`.
enum AddFriendEntityType: String, Equatable, Hashable {
    case user
    case business
}

struct AddFriendSearchTarget: Identifiable, Hashable {
    let entityType: AddFriendEntityType
    /// `user_profiles.id` (user) or `businesses.id` (business).
    let entityId: UUID
    let displayName: String
    let username: String?
    let avatarURL: String?
    let avatarThumbnailURL: String?
    /// Internal only (duplicate-email detection); not shown in search UI.
    let matchedEmail: String?

    var id: String { "\(entityType.rawValue)-\(entityId.uuidString.lowercased())" }

    var kindLabel: String {
        switch entityType {
        case .user: return "User"
        case .business: return "Business"
        }
    }

    var listTitle: String { displayName }

    var publicHandleLine: String {
        let stored = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty {
            return FanGeoHandleRules.displayHandle(stored: stored)
        }
        return ""
    }

    var socialEntityKind: FriendSocialEntityKind {
        switch entityType {
        case .user: return .fanUser
        case .business: return .business
        }
    }
}

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

    /// Fan user → active ``businesses`` row (`friendship_ensure_pending_to_business`; requires migration `20260701_0001`).
    func sendFriendRequestToBusiness(requesterId: UUID, businessId: UUID) async throws {
        let me = try await currentUserId()
        guard me == requesterId else {
            struct Mismatch: Error {}
            throw Mismatch()
        }
        struct Params: Encodable {
            let p_business_id: UUID
        }
        try await client
            .rpc("friendship_ensure_pending_to_business", params: Params(p_business_id: businessId))
            .execute()
    }

    /// Normalized add-friend lookup query: `lower(trim(raw))` (email or display name).
    static func normalizedFriendLookupQuery(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasPrefix("@") {
            s.removeFirst()
        }
        return s
    }

    private static func escapeForIlike(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// `lower(trim)` plus underscore→space so `JT_bar` matches `JT Bar`.
    static func normalizedBusinessDisplayNameForLookup(_ raw: String) -> String {
        let lowered = normalizedFriendLookupQuery(raw)
        let spaced = lowered.replacingOccurrences(of: "_", with: " ")
        return spaced
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// PostgREST `ilike` pattern: tokenize canonical display name with `%` between tokens (`jt_bar` → `%jt%bar%`).
    private static func businessDisplayNameIlikePattern(normalizedQuery n: String) -> String {
        let tokens = normalizedBusinessDisplayNameForLookup(n)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let first = tokens.first else { return "%" }
        if tokens.count == 1 {
            return "%\(escapeForIlike(first))%"
        }
        return "%" + tokens.map { escapeForIlike($0) }.joined(separator: "%") + "%"
    }

    private static func businessOwnerEmailMatches(query normalizedQuery: String, ownerEmail: String) -> Bool {
        let q = normalizedFriendLookupQuery(normalizedQuery)
        let e = OwnerBusinessEmail.normalized(ownerEmail)
        guard OwnerBusinessEmail.isValidStrict(e) else { return false }
        if q.contains("@") {
            return e == q
        }
        return e.contains(q)
    }

    private static func businessDisplayNameMatches(query normalizedQuery: String, displayName: String) -> Bool {
        let q = normalizedBusinessDisplayNameForLookup(normalizedQuery)
        let d = normalizedBusinessDisplayNameForLookup(displayName)
        guard !q.isEmpty, !d.isEmpty else { return false }
        return d == q || d.contains(q)
    }

    /// Auth users who own an active `businesses` row (`owner_user_id`), for friend lookup when `user_profiles.is_business_account` is absent.
    private func profileIdsWithActiveBusinessOwnerRole(_ ids: [UUID]) async throws -> Set<UUID> {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [] }
        struct R: Decodable { let owner_user_id: UUID? }
        let rows: [R] = try await client
            .from("businesses")
            .select("owner_user_id")
            .in("owner_user_id", values: unique.map { $0.uuidString.lowercased() })
            .eq("admin_status", value: "active")
            .execute()
            .value
        return Set(rows.compactMap(\.owner_user_id))
    }

    /// Searches fan ``user_profiles`` and ``businesses`` for Add Friend (does not collapse different entities that share an email).
    func searchAddFriendTargets(normalizedQuery raw: String, excludingUserId: UUID?) async throws -> [AddFriendSearchTarget] {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !n.isEmpty else { return [] }

#if DEBUG
        print("[AddFriendSearchDebug] query=\(n)")
#endif

        struct FanProfileRow: Decodable {
            let id: UUID
            let is_business_account: Bool?
            let email: String?
            let display_name: String?
            let username: String?
            let avatar_url: String?
            let avatar_thumbnail_url: String?
            let created_at: String?

            func isFanProfileExcludingBusinessOwners(businessAuthProfileIds: Set<UUID>) -> Bool {
                if is_business_account == true { return false }
                return !businessAuthProfileIds.contains(id)
            }
        }

        let fanSelect =
            "id,email,display_name,username,avatar_url,avatar_thumbnail_url,created_at"

        var results: [AddFriendSearchTarget] = []
        var seenKeys = Set<String>()

        let ilikePattern = "%\(Self.escapeForIlike(n))%"
        let businessSelect = "id,display_name,owner_email,owner_user_id,admin_status,created_at"

        let exactUsernameRows: [FanProfileRow] = (try? await client
            .from("user_profiles")
            .select(fanSelect)
            .eq("admin_status", value: "active")
            .ilike("username", pattern: n)
            .limit(24)
            .execute()
            .value) ?? []

        let partialUsernameRows: [FanProfileRow] = (try? await client
            .from("user_profiles")
            .select(fanSelect)
            .eq("admin_status", value: "active")
            .ilike("username", pattern: ilikePattern)
            .limit(24)
            .execute()
            .value) ?? []

        let emailFanRows: [FanProfileRow] = (try? await client
            .from("user_profiles")
            .select(fanSelect)
            .eq("admin_status", value: "active")
            .ilike("email", pattern: ilikePattern)
            .limit(24)
            .execute()
            .value) ?? []

        let normFanRows: [FanProfileRow] = (try? await client
            .from("user_profiles")
            .select(fanSelect)
            .eq("admin_status", value: "active")
            .eq("display_name_normalized", value: n)
            .limit(24)
            .execute()
            .value) ?? []

        let ilikeFanRows: [FanProfileRow] = (try? await client
            .from("user_profiles")
            .select(fanSelect)
            .eq("admin_status", value: "active")
            .ilike("display_name", pattern: ilikePattern)
            .limit(24)
            .execute()
            .value) ?? []

        let fanProfileIds = Array(
            Set(
                exactUsernameRows.map(\.id)
                    + partialUsernameRows.map(\.id)
                    + emailFanRows.map(\.id)
                    + normFanRows.map(\.id)
                    + ilikeFanRows.map(\.id)
            )
        )
        let businessAuthProfileIds = (try? await profileIdsWithActiveBusinessOwnerRole(fanProfileIds)) ?? []

        func appendFan(_ row: FanProfileRow, matchedEmail: String?, matchKind: String) {
            guard row.isFanProfileExcludingBusinessOwners(businessAuthProfileIds: businessAuthProfileIds) else { return }
            if let ex = excludingUserId, row.id == ex { return }
            let key = "user-\(row.id.uuidString.lowercased())"
            guard seenKeys.insert(key).inserted else { return }
            let display = trimmedNonEmpty(row.display_name)
            let storedHandle = trimmedNonEmpty(row.username)
            let emailNorm = Self.normalizedFriendLookupQuery(row.email ?? "")
            let name: String
            if !display.isEmpty {
                name = display
            } else if !storedHandle.isEmpty {
                name = FanGeoHandleRules.displayHandle(stored: storedHandle)
            } else if !emailNorm.isEmpty {
                name = emailNorm.split(separator: "@").first.map(String.init) ?? "Player"
            } else {
                name = "Player"
            }
            let emailOut = matchedEmail
            let handleStored = storedHandle.isEmpty ? nil : FanGeoHandleRules.normalizeForStorage(storedHandle)
            results.append(
                AddFriendSearchTarget(
                    entityType: .user,
                    entityId: row.id,
                    displayName: name,
                    username: handleStored,
                    avatarURL: row.avatar_url,
                    avatarThumbnailURL: row.avatar_thumbnail_url,
                    matchedEmail: emailOut
                )
            )
#if DEBUG
            print("[FriendSearchIdentityDebug] matchKind=\(matchKind) entity_id=\(row.id.uuidString) display=\(name) handle=\(handleStored ?? "nil")")
#endif
        }

        func appendBusiness(_ row: BusinessRow, matchedEmail: String?) {
            let key = "business-\(row.id.uuidString.lowercased())"
            guard seenKeys.insert(key).inserted else { return }
            let emailNorm = OwnerBusinessEmail.normalized(row.owner_email ?? "")
            let display = trimmedNonEmpty(row.display_name)
            let name = display.isEmpty ? (emailNorm.isEmpty ? "Business" : emailNorm) : display
            let emailOut = matchedEmail ?? (OwnerBusinessEmail.isValidStrict(emailNorm) ? emailNorm : nil)
            results.append(
                AddFriendSearchTarget(
                    entityType: .business,
                    entityId: row.id,
                    displayName: name,
                    username: nil,
                    avatarURL: nil,
                    avatarThumbnailURL: nil,
                    matchedEmail: emailOut
                )
            )
#if DEBUG
            print(
                "[AddFriendSearchDebug] businessMatched id=\(row.id.uuidString) display_name=\(display) owner_email=\(emailNorm)"
            )
#endif
        }

        for row in exactUsernameRows {
            appendFan(row, matchedEmail: nil, matchKind: "username_exact")
        }

        for row in partialUsernameRows where !exactUsernameRows.contains(where: { $0.id == row.id }) {
            appendFan(row, matchedEmail: nil, matchKind: "username_partial")
        }

        for row in emailFanRows where Self.normalizedFriendLookupQuery(row.email ?? "") == n {
            appendFan(row, matchedEmail: n, matchKind: "email_exact")
        }

        for row in normFanRows { appendFan(row, matchedEmail: nil, matchKind: "display_name_normalized") }

        for row in ilikeFanRows { appendFan(row, matchedEmail: nil, matchKind: "display_name_partial") }

        var businessCandidates: [BusinessRow] = []
        var businessFetchError: String?

        func mergeBusinessRows(_ rows: [BusinessRow]) {
            for row in rows where !businessCandidates.contains(where: { $0.id == row.id }) {
                businessCandidates.append(row)
            }
        }

        func fetchBusinesses(_ label: String, _ fetch: () async throws -> [BusinessRow]) async {
            do {
                let rows = try await fetch()
                mergeBusinessRows(rows)
#if DEBUG
                print("[AddFriendSearchDebug] businessFetch \(label) count=\(rows.count)")
#endif
            } catch {
                businessFetchError = businessFetchError ?? error.localizedDescription
#if DEBUG
                print("[AddFriendSearchDebug] businessFetch \(label) failed: \(error.localizedDescription)")
#endif
            }
        }

        if n.contains("@"), OwnerBusinessEmail.isValidStrict(n) {
            await fetchBusinesses("owner_email.eq") {
                try await client
                    .from("businesses")
                    .select(businessSelect)
                    .eq("admin_status", value: "active")
                    .eq("owner_email", value: n)
                    .limit(24)
                    .execute()
                    .value
            }
        }

        await fetchBusinesses("owner_email.ilike") {
            try await client
                .from("businesses")
                .select(businessSelect)
                .eq("admin_status", value: "active")
                .ilike("owner_email", pattern: ilikePattern)
                .limit(24)
                .execute()
                .value
        }

        let businessNamePattern = Self.businessDisplayNameIlikePattern(normalizedQuery: n)
        await fetchBusinesses("display_name.ilike.tokens") {
            try await client
                .from("businesses")
                .select(businessSelect)
                .eq("admin_status", value: "active")
                .ilike("display_name", pattern: businessNamePattern)
                .limit(24)
                .execute()
                .value
        }

        let canonicalDisplay = Self.normalizedBusinessDisplayNameForLookup(n)
        if canonicalDisplay != n {
            let spacedPattern = "%\(Self.escapeForIlike(canonicalDisplay))%"
            await fetchBusinesses("display_name.ilike.spaced") {
                try await client
                    .from("businesses")
                    .select(businessSelect)
                    .eq("admin_status", value: "active")
                    .ilike("display_name", pattern: spacedPattern)
                    .limit(24)
                    .execute()
                    .value
            }
        }

#if DEBUG
        print("[AddFriendSearchDebug] businessRawCount=\(businessCandidates.count)")
        if let businessFetchError {
            print("[AddFriendSearchDebug] businessFetchError=\(businessFetchError)")
        }
#endif

        let businessMatched = businessCandidates.filter { row in
            Self.businessOwnerEmailMatches(query: n, ownerEmail: row.owner_email ?? "")
                || Self.businessDisplayNameMatches(query: n, displayName: row.display_name)
        }

#if DEBUG
        print("[AddFriendSearchDebug] businessAfterFilterCount=\(businessMatched.count)")
#endif

        for row in businessMatched {
            let emailNorm = OwnerBusinessEmail.normalized(row.owner_email ?? "")
            let matchedEmail = Self.businessOwnerEmailMatches(query: n, ownerEmail: row.owner_email ?? "")
                ? (OwnerBusinessEmail.isValidStrict(emailNorm) ? emailNorm : nil)
                : nil
            appendBusiness(row, matchedEmail: matchedEmail)
        }

        results.sort { a, b in
            if a.entityType != b.entityType {
                return a.entityType == .user && b.entityType == .business
            }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }

#if DEBUG
        let emails = results.compactMap(\.matchedEmail)
        if Set(emails).count < emails.count {
            print("[AddFriendSearchDebug] duplicateEmailDifferentEntity=true resultCount=\(results.count)")
        }
#endif

        return results
    }

    private func trimmedNonEmpty(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Resolves an active **regular fan** ``user_profiles`` id (excludes business-only rows). Order: @handle → email → ``display_name_normalized`` → ``display_name``.
    func resolveActiveUserIdForFriendLookup(normalizedQuery: String) async throws -> UUID? {
        let n = Self.normalizedFriendLookupQuery(normalizedQuery)
        guard !n.isEmpty else { return nil }

#if DEBUG
        print("[FriendSearchIdentityDebug] lookupQuery=\(n)")
#endif

        struct FriendLookupProfileRow: Decodable {
            let id: UUID
            let is_business_account: Bool?
            let email: String?
            let display_name: String?
            let username: String?
            let created_at: String?

            func isRegularFanExcludingBusinessOwners(_ businessAuthIds: Set<UUID>) -> Bool {
                if is_business_account == true { return false }
                return !businessAuthIds.contains(id)
            }
        }

        let lookupSelect = "id,email,display_name,username,created_at"

        func logMatchedEntities(_ rows: [FriendLookupProfileRow], stage: String, businessAuthIds: Set<UUID>) {
#if DEBUG
            let summary = rows.map { r in
                let biz = businessAuthIds.contains(r.id) ? "owner" : "fan"
                return "\(r.id.uuidString)(\(biz))"
            }.joined(separator: ",")
            print("[FriendSearchIdentityDebug] matchedEntities stage=\(stage) count=\(rows.count) ids=\(summary)")
#endif
        }

        let usernameCandidates: [FriendLookupProfileRow] = (try? await client
            .from("user_profiles")
            .select(lookupSelect)
            .eq("admin_status", value: "active")
            .ilike("username", pattern: n)
            .limit(24)
            .execute()
            .value) ?? []

        let usernameBizIds = try await profileIdsWithActiveBusinessOwnerRole(usernameCandidates.map(\.id))
        let usernameMatches = usernameCandidates.filter {
            $0.isRegularFanExcludingBusinessOwners(usernameBizIds)
        }
        logMatchedEntities(usernameMatches, stage: "username_exact", businessAuthIds: usernameBizIds)
        if let picked = usernameMatches.first {
#if DEBUG
            print("[FriendSearchIdentityDebug] selectedRegularUser=\(picked.id.uuidString)")
#endif
            return picked.id
        }

        let emailCandidates: [FriendLookupProfileRow] = try await client
            .from("user_profiles")
            .select(lookupSelect)
            .eq("admin_status", value: "active")
            .ilike("email", pattern: n)
            .limit(24)
            .execute()
            .value

        let emailBizIds = try await profileIdsWithActiveBusinessOwnerRole(emailCandidates.map(\.id))

        let emailNormMatches = emailCandidates.filter {
            Self.normalizedFriendLookupQuery($0.email ?? "") == n
        }
        logMatchedEntities(emailNormMatches, stage: "email", businessAuthIds: emailBizIds)

        let fanEmailMatches = emailNormMatches
            .filter { $0.isRegularFanExcludingBusinessOwners(emailBizIds) }
            .sorted { ($0.created_at ?? "") < ($1.created_at ?? "") }

        let excludedBusiness = emailNormMatches.filter { !$0.isRegularFanExcludingBusinessOwners(emailBizIds) }
#if DEBUG
        if !excludedBusiness.isEmpty {
            print("[FriendIdentityDebug] excludedBusinessEntity=\(excludedBusiness.map(\.id.uuidString).joined(separator: ","))")
        }
        if emailNormMatches.count > 1 {
            print("[FriendIdentityDebug] duplicateEmailConflict=true emailRowCount=\(emailNormMatches.count) regularFanRowCount=\(fanEmailMatches.count)")
        } else if !fanEmailMatches.isEmpty, !excludedBusiness.isEmpty {
            print("[FriendIdentityDebug] duplicateEmailConflict=true mixedFanAndBusinessSameEmail")
        }
#endif
        if let picked = fanEmailMatches.first {
#if DEBUG
            print("[FriendIdentityDebug] selectedRegularUser=\(picked.id.uuidString)")
#endif
            return picked.id
        }

        let normalizedNameRows: [FriendLookupProfileRow] = try await client
            .from("user_profiles")
            .select(lookupSelect)
            .eq("admin_status", value: "active")
            .eq("display_name_normalized", value: n)
            .limit(24)
            .execute()
            .value
        let nameNormBizIds = try await profileIdsWithActiveBusinessOwnerRole(normalizedNameRows.map(\.id))
        logMatchedEntities(normalizedNameRows, stage: "display_name_normalized", businessAuthIds: nameNormBizIds)
        let fanNormMatches = normalizedNameRows
            .filter { $0.isRegularFanExcludingBusinessOwners(nameNormBizIds) }
            .sorted { ($0.created_at ?? "") < ($1.created_at ?? "") }
        if let picked = fanNormMatches.first {
#if DEBUG
            print("[FriendIdentityDebug] selectedRegularUser=\(picked.id.uuidString)")
#endif
            return picked.id
        }

        let displayNameRows: [FriendLookupProfileRow] = try await client
            .from("user_profiles")
            .select(lookupSelect)
            .eq("admin_status", value: "active")
            .ilike("display_name", pattern: n)
            .limit(24)
            .execute()
            .value
        let displayBizIds = try await profileIdsWithActiveBusinessOwnerRole(displayNameRows.map(\.id))
        logMatchedEntities(displayNameRows, stage: "display_name_ilike", businessAuthIds: displayBizIds)
        let fanDisplayMatches = displayNameRows
            .filter { $0.isRegularFanExcludingBusinessOwners(displayBizIds) }
            .filter { Self.normalizedFriendLookupQuery($0.display_name ?? "") == n }
            .sorted { ($0.created_at ?? "") < ($1.created_at ?? "") }
        if let picked = fanDisplayMatches.first {
#if DEBUG
            print("[FriendIdentityDebug] selectedRegularUser=\(picked.id.uuidString)")
#endif
            return picked.id
        }

#if DEBUG
        print("[FriendIdentityDebug] selectedRegularUser=nil")
#endif
        return nil
    }

    /// Any friendship rows between two fan users (all statuses; legacy user↔user rows).
    func fetchFriendshipsBetween(me: UUID, other: UUID) async throws -> [FriendshipRow] {
        let meS = me.uuidString.lowercased()
        let otherS = other.uuidString.lowercased()
        let filter = "and(requester_id.eq.\(meS),addressee_id.eq.\(otherS)),and(requester_id.eq.\(otherS),addressee_id.eq.\(meS))"
        return try await client
            .from("friendships")
            .select()
            .or(filter)
            .execute()
            .value
    }

    /// Friendship rows between a fan user and a ``businesses`` target (entity-aware).
    func fetchFriendshipsBetweenUserAndBusiness(me: UUID, businessId: UUID) async throws -> [FriendshipRow] {
        let meS = me.uuidString.lowercased()
        let bizS = businessId.uuidString.lowercased()
        let filter =
            "and(requester_id.eq.\(meS),addressee_id.eq.\(bizS),addressee_entity_type.eq.business)," +
            "and(requester_id.eq.\(bizS),addressee_id.eq.\(meS),requester_entity_type.eq.business)"
        return try await client
            .from("friendships")
            .select()
            .or(filter)
            .execute()
            .value
    }

    func fetchFriendships(for target: AddFriendSearchTarget, me: UUID) async throws -> [FriendshipRow] {
        switch target.entityType {
        case .user:
            return try await fetchFriendshipsBetween(me: me, other: target.entityId)
        case .business:
            return try await fetchFriendshipsBetweenUserAndBusiness(me: me, businessId: target.entityId)
        }
    }

    static func entityKind(isBusinessAccount: Bool?) -> FriendSocialEntityKind {
        isBusinessAccount == true ? .businessUser : .fanUser
    }

    /// Active `user_profiles` row → social entity (Add Friend pending matching).
    func fetchSocialEntity(userId: UUID) async throws -> FriendSocialEntity? {
        struct BizRow: Decodable { let id: UUID }
        let bizRows: [BizRow] = try await client
            .from("businesses")
            .select("id")
            .eq("owner_user_id", value: userId)
            .eq("admin_status", value: "active")
            .limit(1)
            .execute()
            .value
        if !bizRows.isEmpty {
            return FriendSocialEntity(id: userId, kind: .businessUser)
        }

        struct Row: Decodable { let id: UUID }
        let rows: [Row] = try await client
            .from("user_profiles")
            .select("id")
            .eq("id", value: userId)
            .eq("admin_status", value: "active")
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else { return nil }
        return FriendSocialEntity(id: row.id, kind: .fanUser)
    }

    /// Pending friendship for an Add Friend target, if any (exact entity pair).
    func findPendingFriendship(requesterId: UUID, target: AddFriendSearchTarget) async throws -> FriendshipRow? {
        let rows = try await fetchFriendships(for: target, me: requesterId)
        return rows.first(where: \.isPendingStatus)
    }

    /// Pending row with a *different* active profile that shares the same normalized email (legacy fan + business).
    func findPendingFriendshipWithOtherProfileSharingEmail(
        requesterId: UUID,
        excludePeerUserId: UUID,
        normalizedEmail: String
    ) async throws -> (friendship: FriendshipRow, other: FriendSocialEntity)? {
        let n = normalizedEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard n.contains("@") else { return nil }

        struct Row: Decodable {
            let id: UUID
            let email: String?
        }

        let candidates: [Row] = try await client
            .from("user_profiles")
            .select("id,email")
            .eq("admin_status", value: "active")
            .ilike("email", pattern: n)
            .limit(24)
            .execute()
            .value

        let emailMatches = candidates.filter {
            Self.normalizedFriendLookupQuery($0.email ?? "") == n
        }

        let businessAuthIds = try await profileIdsWithActiveBusinessOwnerRole(emailMatches.map(\.id))

        for row in emailMatches where row.id != excludePeerUserId {
            guard let pending = try await findPendingFriendship(
                requesterId: requesterId,
                target: AddFriendSearchTarget(
                    entityType: .user,
                    entityId: row.id,
                    displayName: "",
                    username: nil,
                    avatarURL: nil,
                    avatarThumbnailURL: nil,
                    matchedEmail: nil
                )
            ) else {
                continue
            }
            let kind: FriendSocialEntityKind = businessAuthIds.contains(row.id) ? .businessUser : .fanUser
            let other = FriendSocialEntity(id: row.id, kind: kind)
            return (pending, other)
        }
        return nil
    }

#if DEBUG
    static func logPendingRelationshipDebug(
        requester: FriendSocialEntity,
        target: FriendSocialEntity,
        matchedPending: Bool,
        friendshipId: UUID? = nil
    ) {
        print("[PendingRelationshipDebug] requesterEntityType=\(requester.kind.rawValue)")
        print("[PendingRelationshipDebug] requesterEntityId=\(requester.id.uuidString)")
        print("[PendingRelationshipDebug] targetEntityType=\(target.kind.rawValue)")
        print("[PendingRelationshipDebug] targetEntityId=\(target.id.uuidString)")
        print("[PendingRelationshipDebug] matchedPendingRelationship=\(matchedPending)\(friendshipId.map { " friendshipId=\($0.uuidString)" } ?? "")")
    }
#endif

    static func classifyExistingRelation(me: UUID, rows: [FriendshipRow]) -> FriendLookupExistingRelation {
        if rows.contains(where: { ($0.status ?? "").lowercased() == "accepted" }) {
            return .accepted
        }
        if rows.contains(where: { row in
            row.isPendingStatus && row.requester_id == me
        }) {
            return .pendingOutgoing
        }
        if rows.contains(where: { row in
            row.isPendingStatus && row.addressee_id == me
        }) {
            return .pendingIncoming
        }
        if rows.contains(where: { row in
            guard row.isDeclinedStatus else { return false }
            if row.requester_id == me { return row.requester_cleared_at == nil }
            if row.addressee_id == me { return row.addressee_cleared_at == nil }
            return false
        }) {
            return .declinedVisible
        }
        return .none
    }

    static func userFacingMessageForExistingRelation(_ relation: FriendLookupExistingRelation) -> String? {
        switch relation {
        case .accepted:
            return "You are already friends — check Friends."
        case .pendingOutgoing, .pendingIncoming, .declinedVisible:
            return "Request already pending — check Requests."
        case .none:
            return nil
        }
    }

    static func isDuplicateFriendLookupError(_ error: Error) -> Bool {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("friend request already exists") { return true }
        if raw.contains("a friend request already exists") { return true }
        if raw.contains("23505") || raw.contains("duplicate key") || raw.contains("unique constraint") {
            return true
        }
        return false
    }

    /// Server resolves normalized email, ``display_name_normalized``, or ``display_name`` → `user_profiles.id`, then ``friendship_ensure_pending``.
    func sendFriendRequestByLookup(normalizedQuery: String) async throws {
#if DEBUG
        print("[FriendSearchDebug] rpc send_friend_request_by_lookup begin normalized=\(normalizedQuery)")
#endif
        struct Params: Encodable {
            let p_query: String
        }
        try await client
            .rpc("send_friend_request_by_lookup", params: Params(p_query: normalizedQuery))
            .execute()
#if DEBUG
        print("[FriendSearchDebug] rpc send_friend_request_by_lookup success")
#endif
    }

    /// Maps PostgREST / Postgres errors from ``sendFriendRequestByLookup`` to stable user-visible strings.
    static func userFacingAddFriendLookupError(_ error: Error) -> String {
        let raw = error.localizedDescription
        let s = raw.lowercased()

        if s.contains("column") && s.contains("does not exist") && s.contains("user_profiles") {
#if DEBUG
            print("[FriendSearchDebug] schema_fallback=missing_user_profiles_column raw=\(raw)")
#endif
            return "Add friend lookup isn’t available on this server yet. Please update the app or try again later."
        }

        if raw.contains("No GameOn account found with that email or avatar name.")
            || raw.contains("No FanGeo account found with that email or avatar name.")
            || raw.contains("No FanGeo account found with that email or display name.")
            || raw.contains("No GameOn account found with that email or display name.") {
            return "No FanGeo account found with that email or display name."
        }
        if raw.contains("You cannot add yourself.") {
            return "You cannot add yourself."
        }
        if raw.contains("Friend request already exists.") {
            return raw
        }
        if raw.contains("You can't send a friend request to this user.")
            || raw.contains("You can’t send a friend request to this user.") {
            return "You can’t send a friend request to this user."
        }
        if raw.contains("Enter an email or avatar name.")
            || raw.contains("Enter an email or display name.") {
            return "Enter an email or display name."
        }
        if raw.contains("No GameOn account found with that email.")
            || raw.contains("No FanGeo account found with that email.") {
            return "No FanGeo account found with that email or display name."
        }
        if raw.contains("You can't send a friend request to yourself.")
            || raw.contains("You can’t send a friend request to yourself.") {
            return "You cannot add yourself."
        }
        if raw.contains("A friend request already exists with this person.") {
            return raw
        }
        if raw.contains("Enter an email address.") {
            return "Enter an email or display name."
        }
        if s.contains("23505") || s.contains("duplicate key") || s.contains("unique constraint") {
#if DEBUG
            print("[FriendSearchDebug] duplicate_detection_path=postgres_unique_violation")
#endif
            return raw
        }
        if s.contains("could not find the function")
            || s.contains("schema cache")
            || s.contains("pgrst202") {
            return "Add friend isn’t available on the server yet. Please update the app or try again later."
        }
        return raw
    }

    static func isPendingLikeRelation(_ relation: FriendLookupExistingRelation) -> Bool {
        switch relation {
        case .pendingOutgoing, .pendingIncoming, .declinedVisible:
            return true
        case .none, .accepted:
            return false
        }
    }

    /// Classifies a mapped lookup error for sheet coloring (green only on success path in caller).
    static func addFriendLookupOutcome(
        for error: Error,
        verifiedRelationForTarget: FriendLookupExistingRelation = .none
    ) -> AddFriendLookupOutcome {
        let raw = error.localizedDescription
        let message = userFacingAddFriendLookupError(error)

        if isDuplicateFriendLookupError(error), !isPendingLikeRelation(verifiedRelationForTarget) {
#if DEBUG
            print("[FriendSearchDebug] duplicate_suppressed_pending_message verifiedRelation=\(verifiedRelationForTarget)")
#endif
            let fallback = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if fallback.isEmpty || fallback == raw {
                return .error("Couldn't send friend request. Please try again.")
            }
            return .error(fallback)
        }

        if message == "You can’t send a friend request to this user."
            || message == "You can't send a friend request to this user."
            || message == "Add friend isn’t available on the server yet. Please update the app or try again later."
            || message == "Add friend lookup isn’t available on this server yet. Please update the app or try again later." {
#if DEBUG
            print("[FriendSearchDebug] outcome_class=error message=\(message)")
#endif
            return .error(message)
        }

        if message == "You cannot add yourself." {
#if DEBUG
            print("[FriendSearchDebug] self_add_detection=userFacing mapped=\(message)")
#endif
            return .informational("Cannot add yourself. Use another fan’s email or display name.")
        }

        if message == "Request already pending — check Requests."
            || message == "You are already friends — check Friends." {
#if DEBUG
            print("[FriendSearchDebug] duplicate_detection_path=userFacing mapped=\(message)")
#endif
            return .informational(message)
        }

        if message.contains("No FanGeo account found") {
#if DEBUG
            print("[FriendSearchDebug] matched_rows_count=0 (lookup miss)")
#endif
            return .informational(message)
        }

        if message.hasPrefix("Enter an email") {
            return .informational(message)
        }

#if DEBUG
        print("[FriendSearchDebug] outcome_class=error_unclassified raw=\(raw) mapped=\(message)")
#endif
        return .error(message)
    }
}

// MARK: - App icon badge (foreground)

enum AppIconBadgeSync {
    @MainActor
    static func apply(count: Int) async {
        let clamped = max(0, count)
        #if canImport(UIKit)
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(clamped)
        } catch {
            // Best-effort: ignore badge failures (permission, unsupported environment, etc.).
        }
        #endif
    }
}
