import Foundation
import Supabase

/// Supabase sync for business-owned favorite teams (`business_favorite_teams`).
enum BusinessFavoriteTeamsSyncService {
    private static let table = "business_favorite_teams"

    struct TeamRow: Decodable {
        let team_id: String
        let created_at: String?
    }

    struct TeamInsert: Encodable {
        let business_id: UUID
        let team_id: String
    }

    static func fetchTeamIDs(businessId: UUID) async -> [String] {
        do {
            let rows: [TeamRow] = try await supabase
                .from(table)
                .select("team_id,created_at")
                .eq("business_id", value: businessId.uuidString.lowercased())
                .order("created_at", ascending: true)
                .execute()
                .value

            let ids = rows
                .map(\.team_id)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { FavoriteTeamCatalog.team(id: $0) != nil }

#if DEBUG
            print("[BusinessFavoriteTeams] fetch businessId=\(businessId.uuidString.lowercased()) raw=\(rows.count) valid=\(ids.count)")
#endif
            return ids
        } catch {
#if DEBUG
            print("[BusinessFavoriteTeams] fetch_failed businessId=\(businessId.uuidString.lowercased()) error=\(error.localizedDescription)")
#endif
            return []
        }
    }

    static func replaceTeamIDs(businessId: UUID, teamIDs: [String]) async -> Bool {
        let valid = Array(
            Set(
                teamIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .filter { FavoriteTeamCatalog.team(id: $0) != nil }
            )
        ).sorted()

        do {
            try await supabase
                .from(table)
                .delete()
                .eq("business_id", value: businessId.uuidString.lowercased())
                .execute()

            if !valid.isEmpty {
                let payload = valid.map { TeamInsert(business_id: businessId, team_id: $0) }
                try await supabase
                    .from(table)
                    .insert(payload)
                    .execute()
            }

#if DEBUG
            print("[BusinessFavoriteTeams] replace_success businessId=\(businessId.uuidString.lowercased()) count=\(valid.count)")
#endif
            return true
        } catch {
#if DEBUG
            print("[BusinessFavoriteTeams] replace_failed businessId=\(businessId.uuidString.lowercased()) error=\(error.localizedDescription)")
#endif
            return false
        }
    }
}
