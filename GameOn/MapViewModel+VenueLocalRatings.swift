import Foundation

/// Client-side venue star ratings (UserDefaults). Only shows rating UI when the app has a real saved value.
extension MapViewModel {

    private static let venueStarsDefaultsKey = "gameon.venueUserStars.v1"
    private static let venueRatingSaveCountsKey = "gameon.venueRatingSaveCounts.v1"

    func reloadVenueUserRatingsFromStorage() {
        venueUserStarRatings = Self.decodeUUIDIntDict(Self.venueStarsDefaultsKey)
        venueRatingContributionCount = Self.decodeUUIDIntDict(Self.venueRatingSaveCountsKey)
    }

    func saveUserVenueRating(venueID: UUID, stars: Int) {
        guard canRateVenues else {
            logBusinessUserGateBlocked(action: "rateVenue")
            return
        }
        let clamped = min(5, max(1, stars))
        venueUserStarRatings[venueID] = clamped
        venueRatingContributionCount[venueID, default: 0] += 1
        Self.encodeUUIDIntDict(venueUserStarRatings, key: Self.venueStarsDefaultsKey)
        Self.encodeUUIDIntDict(venueRatingContributionCount, key: Self.venueRatingSaveCountsKey)
    }

    /// Returns the locally saved star rating when a real client-side value exists.
    func mergedDisplayRating(for bar: BarVenue) -> Double? {
        guard let stars = venueUserStarRatings[bar.id] else { return nil }
        return Double(stars)
    }

    /// Returns a real locally tracked rating count instead of a seeded fallback.
    func reviewCountDisplay(for bar: BarVenue) -> Int {
        guard venueUserStarRatings[bar.id] != nil else { return 0 }
        return max(venueRatingContributionCount[bar.id] ?? 0, 1)
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
