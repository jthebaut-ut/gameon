import Foundation

extension MapViewModel {
    /// Pulls favorite teams from Supabase into ``FavoriteTeamsStore`` AppStorage cache.
    func loadFavoriteTeamsFromSupabase() async {
        guard let uid = await MainActor.run(body: { currentUserAuthId }) else { return }

        var remote = await FavoriteTeamsSyncService.fetchTeamIDs(userId: uid)

        if remote.isEmpty {
            let localRaw = UserDefaults.standard.string(forKey: FavoriteTeamsStore.appStorageKey) ?? ""
            let local = FavoriteTeamsStore.decodeIDs(from: localRaw)
                .filter { FavoriteTeamCatalog.team(id: $0) != nil }
            if !local.isEmpty {
#if DEBUG
                print(
                    "[FavoriteTeamsSyncDebug] migrate_local_to_server userId=\(uid.uuidString.lowercased()) count=\(local.count)"
                )
#endif
                _ = await FavoriteTeamsSyncService.replaceTeamIDs(userId: uid, teamIDs: local)
                remote = local
            }
        }

        let applied = remote
        await MainActor.run {
            FavoriteTeamsStore.writeToAppStorage(applied)
        }
#if DEBUG
        print("[FavoriteTeamsSyncDebug] applied_local_cache userId=\(uid.uuidString.lowercased()) count=\(applied.count)")
#endif
    }

    /// Pushes catalog team IDs to Supabase (full replace). Local AppStorage should already be updated by the UI.
    @discardableResult
    func syncFavoriteTeamsToSupabase(teamIDs: [String]) async -> Bool {
        guard let uid = await MainActor.run(body: { currentUserAuthId }) else {
#if DEBUG
            print("[FavoriteTeamsSyncDebug] sync_skipped reason=no_auth_user")
#endif
            return false
        }

        return await FavoriteTeamsSyncService.replaceTeamIDs(userId: uid, teamIDs: teamIDs)
    }
}
