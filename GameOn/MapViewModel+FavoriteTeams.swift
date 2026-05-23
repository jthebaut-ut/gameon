import Foundation

extension MapViewModel {
    /// Pulls favorite teams from Supabase into ``FavoriteTeamsStore`` AppStorage cache.
    func loadFavoriteTeamsFromSupabase(forceRefresh: Bool = false) async {
        if !forceRefresh, let inFlight = favoriteTeamsLoadTask {
#if DEBUG
            print("[StartupPrefetchDebug] favoriteTeams coalesced=true")
#endif
            await inFlight.value
            return
        }
        if !forceRefresh,
           let lastFavoriteTeamsLoadAt,
           Date().timeIntervalSince(lastFavoriteTeamsLoadAt) < 180 {
#if DEBUG
            print("[StartupPrefetchDebug] favoriteTeams cacheHit=true")
#endif
            return
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.loadFavoriteTeamsFromSupabaseNow()
        }
        favoriteTeamsLoadTask = task
        await task.value
        favoriteTeamsLoadTask = nil
    }

    private func loadFavoriteTeamsFromSupabaseNow() async {
        guard let uid = await MainActor.run(body: { currentUserAuthId }) else { return }

        var remoteSelection = await FavoriteTeamsSyncService.fetchTeamSelection(userId: uid)
        var remote = remoteSelection.teamIDs

        if remote.isEmpty {
            let localRaw = UserDefaults.standard.string(forKey: FavoriteTeamsStore.appStorageKey) ?? ""
            let localPrimary = UserDefaults.standard.string(forKey: FavoriteTeamsStore.primaryTeamIDAppStorageKey)
            let local = FavoriteTeamsStore.decodeIDs(from: localRaw)
                .filter { FavoriteTeamCatalog.team(id: $0) != nil }
            if !local.isEmpty {
#if DEBUG
                print(
                    "[FavoriteTeamsSyncDebug] migrate_local_to_server userId=\(uid.uuidString.lowercased()) count=\(local.count)"
                )
#endif
                _ = await FavoriteTeamsSyncService.replaceTeamSelection(
                    userId: uid,
                    teamIDs: local,
                    primaryTeamID: FavoriteTeamsStore.normalizedPrimaryTeamID(localPrimary, within: local)
                )
                remote = local
                remoteSelection = FavoriteTeamsSyncService.FavoriteTeamSelection(
                    teamIDs: local,
                    primaryTeamID: FavoriteTeamsStore.normalizedPrimaryTeamID(localPrimary, within: local)
                )
            }
        }

        let applied = remote
        let primary = FavoriteTeamsStore.normalizedPrimaryTeamID(remoteSelection.primaryTeamID, within: applied)
        await MainActor.run {
            FavoriteTeamsStore.writeToAppStorage(applied)
            FavoriteTeamsStore.writePrimaryTeamIDToAppStorage(primary)
            lastFavoriteTeamsLoadAt = Date()
        }
#if DEBUG
        print("[FavoriteTeamsSyncDebug] applied_local_cache userId=\(uid.uuidString.lowercased()) count=\(applied.count)")
#endif
    }

    /// Pushes catalog team IDs to Supabase (full replace). Local AppStorage should already be updated by the UI.
    @discardableResult
    func syncFavoriteTeamsToSupabase(teamIDs: [String], primaryTeamID: String? = nil) async -> Bool {
        guard let uid = await MainActor.run(body: { currentUserAuthId }) else {
#if DEBUG
            print("[FavoriteTeamsSyncDebug] sync_skipped reason=no_auth_user")
#endif
            return false
        }

        return await FavoriteTeamsSyncService.replaceTeamSelection(
            userId: uid,
            teamIDs: teamIDs,
            primaryTeamID: primaryTeamID
        )
    }
}
