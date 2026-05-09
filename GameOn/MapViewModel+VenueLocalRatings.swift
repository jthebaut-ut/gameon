import Foundation

/// Client-side venue star ratings (UserDefaults). Merges with ``BarVenue/rating`` for display until a server model exists.
extension MapViewModel {

    private static let venueStarsDefaultsKey = "gameon.venueUserStars.v1"
    private static let venueRatingSaveCountsKey = "gameon.venueRatingSaveCounts.v1"

    func reloadVenueUserRatingsFromStorage() {
        venueUserStarRatings = Self.decodeUUIDIntDict(Self.venueStarsDefaultsKey)
        venueRatingContributionCount = Self.decodeUUIDIntDict(Self.venueRatingSaveCountsKey)
    }

    func saveUserVenueRating(venueID: UUID, stars: Int) {
        let clamped = min(5, max(1, stars))
        venueUserStarRatings[venueID] = clamped
        venueRatingContributionCount[venueID, default: 0] += 1
        Self.encodeUUIDIntDict(venueUserStarRatings, key: Self.venueStarsDefaultsKey)
        Self.encodeUUIDIntDict(venueRatingContributionCount, key: Self.venueRatingSaveCountsKey)
    }

    /// Blends server/static ``BarVenue/rating`` with the signed-in user’s saved stars when present.
    func mergedDisplayRating(for bar: BarVenue) -> Double {
        guard let stars = venueUserStarRatings[bar.id] else { return bar.rating }
        return (bar.rating * 0.42) + (Double(stars) * 0.58)
    }

    /// Stable-looking review total for UI (increments when the user saves a rating).
    func reviewCountDisplay(for bar: BarVenue) -> Int {
        let base = 10 + abs(bar.name.hashValue % 160)
        let extra = venueRatingContributionCount[bar.id] ?? 0
        return base + extra
    }

    private static func decodeUUIDIntDict(_ key: String) -> [UUID: Int] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        var out: [UUID: Int] = [:]
        for (k, v) in raw {
            if let id = UUID(uuidString: k) {
                out[id] = v
            }
        }
        return out
    }

    private static func encodeUUIDIntDict(_ dict: [UUID: Int], key: String) {
        let raw = Dictionary(uniqueKeysWithValues: dict.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
