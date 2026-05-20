import Foundation
import Supabase

struct ProfileStatsCounts: Equatable {
    let pickupGamesCount: Int
    let venueGamesCount: Int
    let favoriteTeamsCount: Int
    let friendsCount: Int

    static let empty = ProfileStatsCounts(
        pickupGamesCount: 0,
        venueGamesCount: 0,
        favoriteTeamsCount: 0,
        friendsCount: 0
    )
}

actor ProfileStatsService {
    static let shared = ProfileStatsService()

    private let cacheTTL: TimeInterval = 300
    private var cache: [UUID: (loadedAt: Date, counts: ProfileStatsCounts)] = [:]

    func loadStats(userId: UUID, userEmail: String, forceRefresh: Bool = false) async -> ProfileStatsCounts {
        if !forceRefresh,
           let cached = cache[userId],
           Date().timeIntervalSince(cached.loadedAt) < cacheTTL {
            return cached.counts
        }

        async let pickupGames = loadPickupGamesCount(userId: userId)
        async let venueGames = loadVenueGamesCount(userEmail: userEmail)
        async let favoriteTeams = loadFavoriteTeamsCount(userId: userId)
        async let friends = loadFriendsCount(userId: userId)

        let counts = await ProfileStatsCounts(
            pickupGamesCount: pickupGames,
            venueGamesCount: venueGames,
            favoriteTeamsCount: favoriteTeams,
            friendsCount: friends
        )
        cache[userId] = (Date(), counts)
        return counts
    }

    func invalidate(userId: UUID) {
        cache.removeValue(forKey: userId)
    }

    private func loadPickupGamesCount(userId: UUID) async -> Int {
        struct Row: Decodable {
            let pickup_game_id: UUID?
        }

        do {
            let rows: [Row] = try await supabase
                .from("pickup_game_requests")
                .select("pickup_game_id")
                .eq("requester_user_id", value: userId.uuidString.lowercased())
                .eq("status", value: "approved")
                .limit(1_000)
                .execute()
                .value

            return Set(rows.compactMap(\.pickup_game_id)).count
        } catch {
#if DEBUG
            print("[ProfileStatsDebug] pickupGamesCountLoadFailed=\(error.localizedDescription)")
#endif
            return 0
        }
    }

    private func loadVenueGamesCount(userEmail: String) async -> Int {
        struct Row: Decodable {
            let venue_event_id: UUID?
        }

        let normalizedEmail = OwnerBusinessEmail.normalized(userEmail)
        guard OwnerBusinessEmail.isValidStrict(normalizedEmail) else { return 0 }

        do {
            let rows: [Row] = try await supabase
                .from("venue_event_interests")
                .select("venue_event_id")
                .eq("user_email", value: normalizedEmail)
                .limit(1_000)
                .execute()
                .value

            return Set(rows.compactMap(\.venue_event_id)).count
        } catch {
#if DEBUG
            print("[ProfileStatsDebug] venueGamesCountLoadFailed=\(error.localizedDescription)")
#endif
            return 0
        }
    }

    private func loadFavoriteTeamsCount(userId: UUID) async -> Int {
        let ids = await FavoriteTeamsSyncService.fetchTeamIDs(userId: userId)
        return Set(ids).count
    }

    private func loadFriendsCount(userId: UUID) async -> Int {
        do {
            let rows = try await FriendshipService().fetchAcceptedFriendships(for: userId)
            let friendIds = rows.compactMap { row -> UUID? in
                if row.requester_id == userId { return row.addressee_id }
                if row.addressee_id == userId { return row.requester_id }
                return nil
            }
            return Set(friendIds).count
        } catch {
#if DEBUG
            print("[ProfileStatsDebug] friendsCountLoadFailed=\(error.localizedDescription)")
#endif
            return 0
        }
    }
}
