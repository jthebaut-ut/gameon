import Foundation

/// Public-safe summary of a fan's Home Crowd venue.
struct HomeCrowdVenueSummary: Equatable, Codable, Sendable {
    let venueId: UUID
    let name: String
    let locationLabel: String
    let thumbnailURL: String?

    private enum CodingKeys: String, CodingKey {
        case venueId = "venue_id"
        case name
        case locationLabel = "city_label"
        case thumbnailURL = "thumbnail_url"
    }

    init(venueId: UUID, name: String, locationLabel: String, thumbnailURL: String?) {
        self.venueId = venueId
        self.name = name
        self.locationLabel = locationLabel
        self.thumbnailURL = thumbnailURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        venueId = try c.decode(UUID.self, forKey: .venueId)
        name = (try c.decodeIfPresent(String.self, forKey: .name) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        locationLabel = (try c.decodeIfPresent(String.self, forKey: .locationLabel) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(venueId, forKey: .venueId)
        try c.encode(name, forKey: .name)
        try c.encode(locationLabel, forKey: .locationLabel)
        try c.encodeIfPresent(thumbnailURL, forKey: .thumbnailURL)
    }

    var asPublicProfileVenueCard: PublicProfileVenueCard {
        PublicProfileVenueCard(
            venueId: venueId,
            venueName: name,
            cityLabel: locationLabel,
            thumbnailURL: thumbnailURL
        )
    }
}

enum HomeCrowdLocationLabel {
    static func from(bar: BarVenue) -> String {
        let trimmed = bar.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let parts = trimmed.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if parts.count >= 2 {
            return parts[parts.count - 2]
        }
        return parts.first ?? trimmed
    }

    static func from(address: String?, city: String?) -> String {
        let cityTrim = (city ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !cityTrim.isEmpty { return cityTrim }
        return from(address: address ?? "")
    }

    static func from(address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let parts = trimmed.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if parts.count >= 2 {
            return parts[parts.count - 2]
        }
        return parts.first ?? trimmed
    }
}
