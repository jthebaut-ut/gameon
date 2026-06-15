import Foundation

extension MapViewModel {
    @MainActor
    func loadBusinessFavoriteTeams(businessId: UUID? = nil, force: Bool = false) async {
        guard hasAuthenticatedVenueOwnerSession else {
            businessFavoriteTeamIDs = []
            businessFavoriteTeamProGames = []
            return
        }
        guard let businessId = businessId ?? currentBusinessIdForAddLocation() else {
            businessFavoriteTeamIDs = []
            businessFavoriteTeamProGames = []
            return
        }
        if !force, businessFavoriteTeamsLoadedBusinessId == businessId {
            return
        }

        let ids = await BusinessFavoriteTeamsSyncService.fetchTeamIDs(businessId: businessId)
        businessFavoriteTeamIDs = Set(ids)
        businessFavoriteTeamsLoadedBusinessId = businessId
    }

    @MainActor
    func replaceBusinessFavoriteTeams(businessId: UUID? = nil, teamIDs: Set<String>) async -> Bool {
        guard hasAuthenticatedVenueOwnerSession,
              let businessId = businessId ?? currentBusinessIdForAddLocation() else {
            businessFavoriteTeamIDs = []
            businessFavoriteTeamProGames = []
            return false
        }

        let valid = Set(teamIDs.filter { FavoriteTeamCatalog.team(id: $0) != nil })
        businessFavoriteTeamIDs = valid
        businessFavoriteTeamsLoadedBusinessId = businessId
        let saved = await BusinessFavoriteTeamsSyncService.replaceTeamIDs(
            businessId: businessId,
            teamIDs: Array(valid)
        )
        if saved {
            await refreshBusinessFavoriteTeamProGames(businessId: businessId, forceRefresh: true)
        }
        return saved
    }

    @MainActor
    func refreshBusinessFavoriteTeamProGames(
        businessId: UUID? = nil,
        windowDays: Int = 30,
        forceRefresh: Bool = false
    ) async {
        guard hasAuthenticatedVenueOwnerSession else {
            businessFavoriteTeamProGames = []
            return
        }
        let resolvedBusinessId = businessId ?? currentBusinessIdForAddLocation()
        if let resolvedBusinessId {
            await loadBusinessFavoriteTeams(businessId: resolvedBusinessId)
        }

        let teams = FavoriteTeamsStore.resolvedTeams(fromIDs: Array(businessFavoriteTeamIDs).sorted())
        guard !teams.isEmpty else {
            businessFavoriteTeamProGames = []
            return
        }

        let refreshKey = [
            resolvedBusinessId?.uuidString.lowercased() ?? "noBusiness",
            "\(windowDays)",
            Array(businessFavoriteTeamIDs).sorted().joined(separator: ",")
        ].joined(separator: "|")
        if !forceRefresh,
           lastBusinessFavoriteTeamProGamesRefreshKey == refreshKey,
           let lastBusinessFavoriteTeamProGamesRefreshAt {
            let age = Date().timeIntervalSince(lastBusinessFavoriteTeamProGamesRefreshAt)
            if age < 45, !businessFavoriteTeamProGames.contains(where: { $0.game.matchStatus.isHappeningNow }) {
#if DEBUG
                print("[TabPerfDebug] cacheAge=\(String(format: "%.1f", age)) tab=going source=businessFavoriteTeamProGames")
                print("[TabPerfDebug] usedCachedData=true tab=going source=businessFavoriteTeamProGames")
                print("[TabPerfDebug] refreshSkippedReason=fresh tab=going source=businessFavoriteTeamProGames")
#endif
                return
            }
        }
        if !forceRefresh, let existing = businessFavoriteTeamProGamesRefreshTask {
#if DEBUG
            print("[TabPerfDebug] refreshCoalesced=true tab=going source=businessFavoriteTeamProGames")
#endif
            await existing.value
            return
        }

        let startedAt = Date()
#if DEBUG
        print("[TabPerfDebug] refreshStarted=going source=businessFavoriteTeamProGames force=\(forceRefresh)")
#endif
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshBusinessFavoriteTeamProGamesNow(
                teams: teams,
                windowDays: windowDays,
                refreshKey: refreshKey
            )
        }
        businessFavoriteTeamProGamesRefreshTask = task
        await task.value
        businessFavoriteTeamProGamesRefreshTask = nil
#if DEBUG
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("[TabPerfDebug] refreshDurationMs=\(ms) tab=going source=businessFavoriteTeamProGames")
#endif
    }

    private func refreshBusinessFavoriteTeamProGamesNow(
        teams: [FavoriteTeam],
        windowDays: Int,
        refreshKey: String
    ) async {
        do {
            let matches = try await LiveSportsService.shared.fetchLiveMatches(windowDays: windowDays)
            let previous = businessFavoriteTeamProGames
            let autoFollowMatches = Self.favoriteTeamProGames(from: matches, favoriteTeams: teams)
            businessFavoriteTeamProGames = autoFollowMatches
            handleFavoriteTeamProGameStatusUpdates(
                previous: previous,
                current: autoFollowMatches,
                reason: "businessFavoriteTeamAutoFollowFetch"
            )
            await syncFavoriteTeamProGameSubscriptions(autoFollowMatches, reason: "businessFavoriteTeamAutoFollowFetch")
            mergeBusinessFavoriteTeamMatchesIntoLiveMatches(matches)
            lastBusinessFavoriteTeamProGamesRefreshAt = Date()
            lastBusinessFavoriteTeamProGamesRefreshKey = refreshKey
        } catch {
#if DEBUG
            print("[BusinessFavoriteTeams] proGameFetchFailed error=\(error.localizedDescription)")
#endif
            let previous = businessFavoriteTeamProGames
            let autoFollowMatches = Self.favoriteTeamProGames(from: liveMatches, favoriteTeams: teams)
            businessFavoriteTeamProGames = autoFollowMatches
            handleFavoriteTeamProGameStatusUpdates(
                previous: previous,
                current: autoFollowMatches,
                reason: "businessFavoriteTeamAutoFollowFallback"
            )
            await syncFavoriteTeamProGameSubscriptions(autoFollowMatches, reason: "businessFavoriteTeamAutoFollowFallback")
        }
    }

    @MainActor
    func clearBusinessFavoriteTeamState() {
        businessFavoriteTeamIDs = []
        businessFavoriteTeamProGames = []
        businessFavoriteTeamsLoadedBusinessId = nil
    }

    private func mergeBusinessFavoriteTeamMatchesIntoLiveMatches(_ matches: [LiveMatch]) {
        guard !matches.isEmpty else { return }
        var byKey = Dictionary(uniqueKeysWithValues: liveMatches.map { (SavedProGame.stableKey(for: $0), $0) })
        for match in matches {
            byKey[SavedProGame.stableKey(for: match)] = match
        }
        let merged = byKey.values.sorted {
            if $0.startTime == $1.startTime { return $0.id < $1.id }
            return $0.startTime < $1.startTime
        }
        handleSavedProGameStatusUpdates(from: matches, reason: "businessFavoriteTeamWindowMerge")
        liveMatches = merged
    }
}
