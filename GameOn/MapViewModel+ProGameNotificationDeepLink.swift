import Foundation

extension MapViewModel {
    @MainActor
    func enqueueProGameNotificationDeepLink(matchID: String) {
        let trimmed = matchID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingProGameNotificationDeepLink = ProGameNotificationDeepLinkRequest(
            id: UUID(),
            matchID: trimmed
        )
        requestedMainTabRaw = "following"
    }

    @MainActor
    func clearPendingProGameNotificationDeepLink() {
        pendingProGameNotificationDeepLink = nil
    }

    /// Resolves a live match row for a pro game reminder notification `match_id`.
    func resolveLiveMatchForProGameNotificationDeepLink(matchID: String) -> LiveMatch? {
        let normalized = SavedProGame.normalizedHydrationToken(matchID)
        guard !normalized.isEmpty else { return nil }

        if let direct = liveMatches.first(where: { match in
            let matchToken = SavedProGame.normalizedHydrationToken(match.id)
            let stableToken = SavedProGame.normalizedHydrationToken(SavedProGame.stableKey(for: match))
            return matchToken == normalized || stableToken == normalized
        }) {
            return direct
        }

        guard let saved = savedProGames.first(where: { saved in
            SavedProGame.normalizedHydrationToken(saved.id) == normalized
                || SavedProGame.normalizedHydrationToken(saved.stableKey) == normalized
        }) else {
            return nil
        }

        return liveMatchForSavedProGameDeepLink(saved)
    }

    private func liveMatchForSavedProGameDeepLink(_ saved: SavedProGame) -> LiveMatch? {
        liveMatches.first(where: { SavedProGame.directlyMatchesSavedProGame($0, saved) })
    }
}
