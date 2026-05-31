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
            await refreshBusinessFavoriteTeamProGames(businessId: businessId)
        }
        return saved
    }

    @MainActor
    func refreshBusinessFavoriteTeamProGames(businessId: UUID? = nil, windowDays: Int = 30) async {
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

        do {
            let matches = try await LiveSportsService.shared.fetchLiveMatches(windowDays: windowDays)
            businessFavoriteTeamProGames = Self.favoriteTeamProGames(from: matches, favoriteTeams: teams)
            mergeBusinessFavoriteTeamMatchesIntoLiveMatches(matches)
        } catch {
#if DEBUG
            print("[BusinessFavoriteTeams] proGameFetchFailed error=\(error.localizedDescription)")
#endif
            businessFavoriteTeamProGames = Self.favoriteTeamProGames(from: liveMatches, favoriteTeams: teams)
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
        liveMatches = byKey.values.sorted {
            if $0.startTime == $1.startTime { return $0.id < $1.id }
            return $0.startTime < $1.startTime
        }
    }
}
