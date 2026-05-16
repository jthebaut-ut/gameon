import Foundation
import Supabase

/// Supabase sync for shareable favorite teams (`user_favorite_teams`).
enum FavoriteTeamsSyncService {
    private static let table = "user_favorite_teams"

    struct TeamRow: Decodable {
        let team_id: String
        let created_at: String?
    }

    struct TeamInsert: Encodable {
        let user_id: UUID
        let team_id: String
    }

    /// Loads catalog-valid team IDs for a user (any authenticated reader).
    static func fetchTeamIDs(userId: UUID) async -> [String] {
        do {
            let rows: [TeamRow] = try await supabase
                .from(table)
                .select("team_id,created_at")
                .eq("user_id", value: userId.uuidString.lowercased())
                .order("created_at", ascending: true)
                .execute()
                .value

            let ids = rows
                .map(\.team_id)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { FavoriteTeamCatalog.team(id: $0) != nil }

#if DEBUG
            print(
                "[FavoriteTeamsSyncDebug] fetch userId=\(userId.uuidString.lowercased()) raw=\(rows.count) valid=\(ids.count)"
            )
#endif
            return ids
        } catch {
#if DEBUG
            print(
                "[FavoriteTeamsSyncDebug] fetch_failed userId=\(userId.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
#endif
            return []
        }
    }

    /// Replaces the current user's favorite teams with the given catalog IDs.
    static func replaceTeamIDs(userId: UUID, teamIDs: [String]) async -> Bool {
        let valid = Array(
            Set(
                teamIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .filter { FavoriteTeamCatalog.team(id: $0) != nil }
            )
        ).sorted()

#if DEBUG
        print(
            "[FavoriteTeamsSyncDebug] replace_start userId=\(userId.uuidString.lowercased()) count=\(valid.count)"
        )
#endif

        do {
            try await supabase
                .from(table)
                .delete()
                .eq("user_id", value: userId.uuidString.lowercased())
                .execute()

            if !valid.isEmpty {
                let payload = valid.map { TeamInsert(user_id: userId, team_id: $0) }
                try await supabase
                    .from(table)
                    .insert(payload)
                    .execute()
            }

#if DEBUG
            print(
                "[FavoriteTeamsSyncDebug] replace_success userId=\(userId.uuidString.lowercased()) count=\(valid.count)"
            )
#endif
            return true
        } catch {
#if DEBUG
            print(
                "[FavoriteTeamsSyncDebug] replace_failed userId=\(userId.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
#endif
            return false
        }
    }
}
