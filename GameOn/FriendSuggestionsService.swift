import Foundation
import Supabase

/// Public-safe profile payload returned by the friend suggestions RPC.
struct FriendSuggestionProfile: Identifiable, Decodable, Hashable, Sendable {
    let userID: UUID
    let email: String?
    let displayName: String?
    /// Stored handle without requiring UI formatting; falls back to `username` when the RPC returns that column.
    let handle: String?
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let bio: String?
    let sharedFavoriteTeamsCount: Int
    let sharedEventInterestCount: Int
    let sharedPickupGameCount: Int
    let score: Double
    let reasonType: String?
    let reasonLabel: String?

    var id: UUID { userID }

    private enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case email
        case displayName = "display_name"
        case handle
        case username
        case avatarURL = "avatar_url"
        case avatarThumbnailURL = "avatar_thumbnail_url"
        case bio
        case sharedFavoriteTeamsCount = "shared_favorite_teams_count"
        case sharedEventInterestCount = "shared_event_interest_count"
        case sharedPickupGameCount = "shared_pickup_game_count"
        case score
        case reasonType = "reason_type"
        case reasonLabel = "reason_label"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        userID = try Self.decodeUUID(from: container, preferredKey: .userID, fallbackKey: .id)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        handle = try container.decodeIfPresent(String.self, forKey: .handle)
            ?? container.decodeIfPresent(String.self, forKey: .username)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
            ?? container.decodeIfPresent(String.self, forKey: .avatarThumbnailURL)
        avatarThumbnailURL = try container.decodeIfPresent(String.self, forKey: .avatarThumbnailURL)
        bio = try container.decodeIfPresent(String.self, forKey: .bio)
        sharedFavoriteTeamsCount = Self.decodeIntIfPresent(from: container, forKey: .sharedFavoriteTeamsCount) ?? 0
        sharedEventInterestCount = Self.decodeIntIfPresent(from: container, forKey: .sharedEventInterestCount) ?? 0
        sharedPickupGameCount = Self.decodeIntIfPresent(from: container, forKey: .sharedPickupGameCount) ?? 0
        score = Self.decodeDoubleIfPresent(from: container, forKey: .score) ?? 0
        reasonType = try container.decodeIfPresent(String.self, forKey: .reasonType)
        reasonLabel = try container.decodeIfPresent(String.self, forKey: .reasonLabel)
    }

    private static func decodeUUID(
        from container: KeyedDecodingContainer<CodingKeys>,
        preferredKey: CodingKeys,
        fallbackKey: CodingKeys
    ) throws -> UUID {
        if let uuid = try? container.decodeIfPresent(UUID.self, forKey: preferredKey) {
            return uuid
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: preferredKey),
           let uuid = UUID(uuidString: raw) {
            return uuid
        }
        if let uuid = try? container.decodeIfPresent(UUID.self, forKey: fallbackKey) {
            return uuid
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: fallbackKey),
           let uuid = UUID(uuidString: raw) {
            return uuid
        }

        throw DecodingError.keyNotFound(
            preferredKey,
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Expected UUID-compatible friend suggestion user_id."
            )
        )
    }

    private static func decodeIntIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(raw)
        }
        return nil
    }

    private static func decodeDoubleIfPresent(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(raw)
        }
        return nil
    }
}

/// Service-only wrapper for profile friend suggestions. UI and friendship flows remain separate.
final class FriendSuggestionsService {
    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    nonisolated static let defaultFetchPoolLimit = 30
    nonisolated static let defaultDisplayLimit = 10

    func fetchSuggestions(
        limit: Int = defaultFetchPoolLimit,
        radiusMiles: Double = 45,
        centerLat: Double? = nil,
        centerLng: Double? = nil
    ) async throws -> [FriendSuggestionProfile] {
        #if DEBUG
        let centerLatDescription = centerLat.map { String($0) } ?? "nil"
        let centerLngDescription = centerLng.map { String($0) } ?? "nil"
        print(
            "[FriendSuggestionsService] fetch start limit=\(limit) radiusMiles=\(radiusMiles) centerLat=\(centerLatDescription) centerLng=\(centerLngDescription)"
        )
        #endif

        struct Params: Encodable {
            let p_limit: Int
            let p_radius_miles: Double
            let p_center_lat: Double?
            let p_center_lng: Double?
        }

        do {
            let rows: [FriendSuggestionProfile] = try await client
                .rpc(
                    "get_profile_friend_suggestions",
                    params: Params(
                        p_limit: limit,
                        p_radius_miles: radiusMiles,
                        p_center_lat: centerLat,
                        p_center_lng: centerLng
                    )
                )
                .execute()
                .value

            #if DEBUG
            print("[FriendSuggestionsService] fetch success count=\(rows.count)")
            #endif

            return rows
        } catch {
            #if DEBUG
            print("[FriendSuggestionsService] fetch failed error=\(error.localizedDescription)")
            #endif
            throw error
        }
    }

    func dismissSuggestion(dismissedUserId: UUID) async throws {
        let session = try await client.auth.session
        let viewerId = session.user.id

        struct Row: Encodable {
            let user_id: UUID
            let dismissed_user_id: UUID
        }

        try await client
            .from("suggested_fan_dismissals")
            .upsert(Row(user_id: viewerId, dismissed_user_id: dismissedUserId), onConflict: "user_id,dismissed_user_id")
            .execute()
    }
}
