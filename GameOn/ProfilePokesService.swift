import Foundation
import Supabase

/// Aggregate poke state for a profile (from ``get_profile_poke_summary``).
struct ProfilePokeSummary: Codable, Equatable, Sendable {
    let totalPokes: Int
    let uniquePokers: Int
    let viewerLastPokedAt: String?
    let viewerCanPokeNow: Bool
    let viewerCooldownEndsAt: String?

    enum CodingKeys: String, CodingKey {
        case totalPokes = "total_pokes"
        case uniquePokers = "unique_pokers"
        case viewerLastPokedAt = "viewer_last_poked_at"
        case viewerCanPokeNow = "viewer_can_poke_now"
        case viewerCooldownEndsAt = "viewer_cooldown_ends_at"
    }

    init(
        totalPokes: Int,
        uniquePokers: Int,
        viewerLastPokedAt: String?,
        viewerCanPokeNow: Bool,
        viewerCooldownEndsAt: String?
    ) {
        self.totalPokes = totalPokes
        self.uniquePokers = uniquePokers
        self.viewerLastPokedAt = viewerLastPokedAt
        self.viewerCanPokeNow = viewerCanPokeNow
        self.viewerCooldownEndsAt = viewerCooldownEndsAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalPokes = Self.decodeInt(from: c, forKey: .totalPokes)
        uniquePokers = Self.decodeInt(from: c, forKey: .uniquePokers)
        viewerLastPokedAt = try c.decodeIfPresent(String.self, forKey: .viewerLastPokedAt)
        viewerCanPokeNow = try c.decodeIfPresent(Bool.self, forKey: .viewerCanPokeNow) ?? false
        viewerCooldownEndsAt = try c.decodeIfPresent(String.self, forKey: .viewerCooldownEndsAt)
    }

    private static func decodeInt(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int {
        if let value = try? container.decode(Int.self, forKey: key) { return max(0, value) }
        if let value = try? container.decode(Int64.self, forKey: key) { return max(0, Int(value)) }
        if let string = try? container.decode(String.self, forKey: key), let value = Int(string) { return max(0, value) }
        return 0
    }
}

/// Result of ``ProfilePokesService/pokeProfile(targetUserId:)`` (from ``poke_profile``).
struct ProfilePokeActionResult: Equatable, Sendable {
    let pokeId: UUID?
    let createdAt: String?
    let viewerCanPokeNow: Bool
    let viewerCooldownEndsAt: String?

    var succeeded: Bool { pokeId != nil }
}

/// One incoming poke event for the signed-in recipient.
struct ProfilePokeIncomingItem: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let pokerUserId: UUID
    let pokedUserId: UUID
    let createdAt: String?
    let source: String?
    let pokerDisplayName: String
    let pokerUsername: String?
    let pokerAvatarURL: String?
    let pokerAvatarThumbnailURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case pokerUserId = "poker_user_id"
        case pokedUserId = "poked_user_id"
        case createdAt = "created_at"
        case source
        case pokerDisplayName = "poker_display_name"
        case pokerUsername = "poker_username"
        case pokerAvatarURL = "poker_avatar_url"
        case pokerAvatarThumbnailURL = "poker_avatar_thumbnail_url"
    }

    var publicHandleLine: String {
        let stored = pokerUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? "" : FanGeoHandleRules.displayHandle(stored: stored)
    }

    var relativePokedLabel: String {
        FanPropsRelativeTime.label(from: createdAt)
    }
}

enum ProfilePokesServiceError: LocalizedError, Equatable {
    case cannotPokeSelf
    case onCooldown(until: String?)
    case rpcFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotPokeSelf:
            return "You cannot poke yourself."
        case .onCooldown(let until):
            if let until, !until.isEmpty {
                return "You can poke again after \(until)."
            }
            return "You can poke again in a few minutes."
        case .rpcFailed(let message):
            return message
        }
    }
}

/// Repeatable profile Pokes (``profile_pokes``). Fan Props / ``ProfilePropsService`` remain unchanged.
final class ProfilePokesService {
    private let client: SupabaseClient

    private static let table = "profile_pokes"
    private static let pokeSelect = "id,poker_user_id,poked_user_id,created_at,source"
    private static let profileSelect = "id,display_name,username,avatar_url,avatar_thumbnail_url,admin_status"

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func currentUserId() async throws -> UUID {
        let session = try await client.auth.session
        return session.user.id
    }

    /// Sends a poke via ``poke_profile`` (15-minute cooldown per pair).
    func pokeProfile(targetUserId: UUID) async throws -> ProfilePokeActionResult {
        let target = targetUserId.uuidString.lowercased()
        DebugLogGate.debug("[PokesDebug] poke start target=\(target)")

        struct Params: Encodable {
            let p_target_user_id: UUID
        }

        struct Row: Decodable {
            let poke_id: UUID?
            let created_at: String?
            let viewer_can_poke_now: Bool?
            let viewer_cooldown_ends_at: String?
        }

        let rows: [Row]
        do {
            rows = try await client
                .rpc("poke_profile", params: Params(p_target_user_id: targetUserId))
                .execute()
                .value
        } catch {
            DebugLogGate.debug("[PokesDebug] poke failed error=\(error.localizedDescription)")
            throw ProfilePokesServiceError.rpcFailed(error.localizedDescription)
        }

        guard let row = rows.first else {
            throw ProfilePokesServiceError.rpcFailed("Empty poke response.")
        }

        let result = ProfilePokeActionResult(
            pokeId: row.poke_id,
            createdAt: row.created_at,
            viewerCanPokeNow: row.viewer_can_poke_now ?? false,
            viewerCooldownEndsAt: row.viewer_cooldown_ends_at
        )

        if let pokeId = result.pokeId {
            DebugLogGate.debug("[PokesDebug] poke success id=\(pokeId.uuidString.lowercased())")
        } else if let until = result.viewerCooldownEndsAt {
            DebugLogGate.debug("[PokesDebug] poke cooldown until=\(until)")
            throw ProfilePokesServiceError.onCooldown(until: until)
        } else {
            DebugLogGate.debug("[PokesDebug] poke cooldown until=unknown")
            throw ProfilePokesServiceError.onCooldown(until: nil)
        }

        return result
    }

    /// Public-safe poke summary for a profile.
    func fetchPokeSummary(targetUserId: UUID) async throws -> ProfilePokeSummary {
        let target = targetUserId.uuidString.lowercased()
        DebugLogGate.debug("[PokesDebug] summary target=\(target)")

        struct Params: Encodable {
            let p_target_user_id: UUID
        }

        let rows: [ProfilePokeSummary] = try await client
            .rpc("get_profile_poke_summary", params: Params(p_target_user_id: targetUserId))
            .execute()
            .value

        guard let summary = rows.first else {
            return ProfilePokeSummary(
                totalPokes: 0,
                uniquePokers: 0,
                viewerLastPokedAt: nil,
                viewerCanPokeNow: false,
                viewerCooldownEndsAt: nil
            )
        }

        DebugLogGate.debug(
            "[PokesDebug] summary target=\(target) total=\(summary.totalPokes) unique=\(summary.uniquePokers) canPoke=\(summary.viewerCanPokeNow)"
        )
        return summary
    }

    /// Incoming poke events for the signed-in user (newest first).
    func fetchMyIncomingPokes(limit: Int = 50) async throws -> [ProfilePokeIncomingItem] {
        let currentUserID = try await currentUserId()
        DebugLogGate.debug("[PokesDebug] incoming start user=\(currentUserID.uuidString.lowercased())")

        let cappedLimit = min(max(limit, 0), 100)
        guard cappedLimit > 0 else {
            DebugLogGate.debug("[PokesDebug] incoming count=0")
            return []
        }

        let pokeRows: [ProfilePokeRow]
        do {
            pokeRows = try await client
                .from(Self.table)
                .select(Self.pokeSelect)
                .eq("poked_user_id", value: currentUserID.uuidString.lowercased())
                .order("created_at", ascending: false)
                .limit(cappedLimit)
                .execute()
                .value
        } catch {
            DebugLogGate.debug("[PokesDebug] incoming failed error=\(error.localizedDescription)")
            throw error
        }

        let pokerIDs = Array(Set(pokeRows.map(\.poker_user_id)))
        let profilesByID = await fetchPokerProfilesByID(pokerIDs)

        let items = pokeRows.map { row in
            Self.incomingItem(from: row, profilesByID: profilesByID)
        }

        DebugLogGate.debug("[PokesDebug] incoming count=\(items.count)")
        return items
    }

    private func fetchPokerProfilesByID(_ pokerIDs: [UUID]) async -> [UUID: ProfilePokeProfileRow] {
        guard !pokerIDs.isEmpty else { return [:] }
        do {
            let profileRows: [ProfilePokeProfileRow] = try await client
                .from("user_profiles")
                .select(Self.profileSelect)
                .in("id", values: pokerIDs.map { $0.uuidString.lowercased() })
                .execute()
                .value
            var profilesByID: [UUID: ProfilePokeProfileRow] = [:]
            profilesByID.reserveCapacity(profileRows.count)
            for row in profileRows {
                profilesByID[row.id] = row
            }
            return profilesByID
        } catch {
            DebugLogGate.debug("[PokesDebug] incoming likerProfiles failed error=\(error.localizedDescription)")
            return [:]
        }
    }

    private static func incomingItem(
        from row: ProfilePokeRow,
        profilesByID: [UUID: ProfilePokeProfileRow]
    ) -> ProfilePokeIncomingItem {
        let profile = profilesByID[row.poker_user_id]
        let displayName = profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let avatarURL = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_url)
        let avatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_thumbnail_url)

        return ProfilePokeIncomingItem(
            id: row.id,
            pokerUserId: row.poker_user_id,
            pokedUserId: row.poked_user_id,
            createdAt: row.created_at,
            source: row.source,
            pokerDisplayName: displayName.isEmpty ? "Fan" : displayName,
            pokerUsername: profile?.username,
            pokerAvatarURL: avatarURL.isEmpty ? nil : avatarURL,
            pokerAvatarThumbnailURL: avatarThumbnailURL.isEmpty ? nil : avatarThumbnailURL
        )
    }

    private struct ProfilePokeRow: Codable, Sendable {
        let id: UUID
        let poker_user_id: UUID
        let poked_user_id: UUID
        let created_at: String?
        let source: String?
    }

    private struct ProfilePokeProfileRow: Decodable, Sendable {
        let id: UUID
        let display_name: String?
        let username: String?
        let avatar_url: String?
        let avatar_thumbnail_url: String?
        let admin_status: String?
    }
}
