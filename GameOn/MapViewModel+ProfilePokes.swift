import Foundation

extension MapViewModel {
    private static let pokesBadgeRefreshLimit = 50

    func pokesAcknowledgedAtStorageKey(for authId: UUID) -> String {
        "profilePokesLastAcknowledgedAt.\(authId.uuidString.lowercased())"
    }

    var canReceiveProfilePokes: Bool {
        isLoggedIn && !isVenueOwnerLoggedIn && currentUserAuthId != nil
    }

    func acknowledgeIncomingPokes(reason: String) {
        guard canReceiveProfilePokes, let authId = currentUserAuthId else {
            hasUnseenPokes = false
            unseenPokesCount = 0
            return
        }
        let stamp = latestTrackedIncomingPokeAt ?? Date()
        UserDefaults.standard.set(stamp, forKey: pokesAcknowledgedAtStorageKey(for: authId))
        hasUnseenPokes = false
        unseenPokesCount = 0
        DebugLogGate.debug("[PokesBadge] acknowledged reason=\(reason)")
        DebugLogGate.debug("[PokesBadge] unseen count=0")
    }

    func applyIncomingPokesFetch(_ items: [ProfilePokeIncomingItem]) {
        guard canReceiveProfilePokes, let authId = currentUserAuthId else {
            hasUnseenPokes = false
            unseenPokesCount = 0
            latestTrackedIncomingPokeAt = nil
            return
        }

        latestTrackedIncomingPokeAt = Self.latestPokeDate(from: items)
        reconcileUnseenPokes(from: items, authId: authId)
    }

    func reconcileUnseenPokes(from items: [ProfilePokeIncomingItem]) {
        guard canReceiveProfilePokes, let authId = currentUserAuthId else {
            hasUnseenPokes = false
            unseenPokesCount = 0
            return
        }
        reconcileUnseenPokes(from: items, authId: authId)
    }

    private func reconcileUnseenPokes(from items: [ProfilePokeIncomingItem], authId: UUID) {
        let acknowledgedAt =
            UserDefaults.standard.object(forKey: pokesAcknowledgedAtStorageKey(for: authId)) as? Date
            ?? .distantPast
        let unseen = items.filter { item in
            guard let created = Self.latestPokeDate(from: [item]) else { return false }
            return created > acknowledgedAt
        }
        unseenPokesCount = unseen.count
        hasUnseenPokes = !unseen.isEmpty
        DebugLogGate.debug("[PokesBadge] unseen count=\(unseenPokesCount)")
    }

    func refreshUnseenPokesBadgeIfNeeded() async {
        guard canReceiveProfilePokes else {
            hasUnseenPokes = false
            unseenPokesCount = 0
            latestTrackedIncomingPokeAt = nil
            return
        }

        let service = ProfilePokesService()
        do {
            let items = try await service.fetchMyIncomingPokes(limit: Self.pokesBadgeRefreshLimit)
            applyIncomingPokesFetch(items)
        } catch {
            DebugLogGate.debug("[PokesBadge] refresh failed error=\(error.localizedDescription)")
        }
    }

    func clearUnseenPokesBadgeState() {
        hasUnseenPokes = false
        unseenPokesCount = 0
        latestTrackedIncomingPokeAt = nil
    }

    private static func latestPokeDate(from items: [ProfilePokeIncomingItem]) -> Date? {
        items.compactMap { FanPropsRelativeTime.parse($0.createdAt) }.max()
    }
}
