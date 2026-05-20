import Foundation

/// Avatar row for fans sharing the same Home Crowd venue.
struct HomeCrowdFanAvatar: Equatable, Codable, Sendable, Identifiable {
    let userId: UUID
    let displayName: String
    let avatarURL: String?

    var id: UUID { userId }

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }

    init(userId: UUID, displayName: String, avatarURL: String?) {
        self.userId = userId
        self.displayName = displayName
        self.avatarURL = avatarURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(UUID.self, forKey: .userId)
        let name = (try c.decodeIfPresent(String.self, forKey: .displayName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = name.isEmpty ? "Fan" : name
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
    }
}

/// Public-safe summary of a fan's Home Crowd venue + community at that venue.
struct HomeCrowdVenueSummary: Equatable, Codable, Sendable {
    let venueId: UUID
    let name: String
    let locationLabel: String
    let thumbnailURL: String?
    let setAtRaw: String?
    let fanCount: Int
    let fanAvatars: [HomeCrowdFanAvatar]

    private enum CodingKeys: String, CodingKey {
        case venueId = "venue_id"
        case name
        case locationLabel = "city_label"
        case thumbnailURL = "thumbnail_url"
        case setAtRaw = "home_crowd_set_at"
        case fanCount = "home_crowd_fan_count"
        case fanAvatars = "home_crowd_fan_avatars"
    }

    init(
        venueId: UUID,
        name: String,
        locationLabel: String,
        thumbnailURL: String?,
        setAtRaw: String? = nil,
        fanCount: Int = 0,
        fanAvatars: [HomeCrowdFanAvatar] = []
    ) {
        self.venueId = venueId
        self.name = name
        self.locationLabel = locationLabel
        self.thumbnailURL = thumbnailURL
        self.setAtRaw = setAtRaw
        self.fanCount = fanCount
        self.fanAvatars = fanAvatars
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        venueId = try c.decode(UUID.self, forKey: .venueId)
        name = (try c.decodeIfPresent(String.self, forKey: .name) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        locationLabel = (try c.decodeIfPresent(String.self, forKey: .locationLabel) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        setAtRaw = Self.decodeFlexibleTimestamp(from: c, forKey: .setAtRaw)
        fanCount = (try? c.decode(Int.self, forKey: .fanCount)) ?? 0
        fanAvatars = (try? c.decode([HomeCrowdFanAvatar].self, forKey: .fanAvatars)) ?? []
    }

    /// Lenient decode for nested RPC JSON (snake/camel keys, timestamptz variants, partial avatar rows).
    static func decodeLenient(from decoder: Decoder) -> HomeCrowdVenueSummary? {
        guard let c = try? decoder.container(keyedBy: LenientCodingKeys.self) else { return nil }

        guard let venueId = decodeUUID(from: c, keys: ["venue_id", "venueId"]) else { return nil }

        let name = decodeString(from: c, keys: ["name"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }

        let locationLabel = decodeString(from: c, keys: ["city_label", "cityLabel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let thumbnailURL = decodeString(from: c, keys: ["thumbnail_url", "thumbnailUrl"])
        let setAtRaw = decodeTimestamp(from: c, keys: ["home_crowd_set_at", "homeCrowdSetAt"])
        let fanCount = decodeInt(from: c, keys: ["home_crowd_fan_count", "homeCrowdFanCount"]) ?? 0
        let fanAvatars = decodeFanAvatars(from: c, keys: ["home_crowd_fan_avatars", "homeCrowdFanAvatars"])

        return HomeCrowdVenueSummary(
            venueId: venueId,
            name: name,
            locationLabel: locationLabel,
            thumbnailURL: thumbnailURL,
            setAtRaw: setAtRaw,
            fanCount: fanCount,
            fanAvatars: fanAvatars
        )
    }

    private struct LenientCodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func decodeString(
        from c: KeyedDecodingContainer<LenientCodingKeys>,
        keys: [String]
    ) -> String? {
        for key in keys {
            if let k = LenientCodingKeys(stringValue: key),
               let value = try? c.decode(String.self, forKey: k) {
                return value
            }
        }
        return nil
    }

    private static func decodeUUID(
        from c: KeyedDecodingContainer<LenientCodingKeys>,
        keys: [String]
    ) -> UUID? {
        for key in keys {
            guard let k = LenientCodingKeys(stringValue: key) else { continue }
            if let id = try? c.decode(UUID.self, forKey: k) { return id }
            if let raw = try? c.decode(String.self, forKey: k),
               let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return id
            }
        }
        return nil
    }

    private static func decodeInt(
        from c: KeyedDecodingContainer<LenientCodingKeys>,
        keys: [String]
    ) -> Int? {
        for key in keys {
            guard let k = LenientCodingKeys(stringValue: key) else { continue }
            if let value = try? c.decode(Int.self, forKey: k) { return value }
        }
        return nil
    }

    private static func decodeTimestamp(
        from c: KeyedDecodingContainer<LenientCodingKeys>,
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let k = LenientCodingKeys(stringValue: key),
                  let raw = try? c.decode(String.self, forKey: k) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func decodeFanAvatars(
        from c: KeyedDecodingContainer<LenientCodingKeys>,
        keys: [String]
    ) -> [HomeCrowdFanAvatar] {
        for key in keys {
            guard let k = LenientCodingKeys(stringValue: key),
                  let avatars = try? c.decode([HomeCrowdFanAvatar].self, forKey: k) else { continue }
            return avatars
        }
        return []
    }

    private static func decodeFlexibleTimestamp<K: CodingKey>(
        from c: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> String? {
        if let raw = try? c.decode(String.self, forKey: key) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(venueId, forKey: .venueId)
        try c.encode(name, forKey: .name)
        try c.encode(locationLabel, forKey: .locationLabel)
        try c.encodeIfPresent(thumbnailURL, forKey: .thumbnailURL)
        try c.encodeIfPresent(setAtRaw, forKey: .setAtRaw)
        try c.encode(fanCount, forKey: .fanCount)
        try c.encode(fanAvatars, forKey: .fanAvatars)
    }

    var asPublicProfileVenueCard: PublicProfileVenueCard {
        PublicProfileVenueCard(
            venueId: venueId,
            venueName: name,
            cityLabel: locationLabel,
            thumbnailURL: thumbnailURL
        )
    }

    var resolvedFanAvatars: [PublicProfileMutualFanAvatar] {
        fanAvatars.map {
            PublicProfileMutualFanAvatar(
                userId: $0.userId,
                displayName: $0.displayName,
                avatarURL: ImageDisplayURL.canonicalStorageURLString($0.avatarURL)
            )
        }
    }
}

enum HomeCrowdSinceFormatter {
    static func regularSinceLine(from raw: String?) -> String? {
        guard let raw, let date = SupabaseTimestampParsing.parseTimestamptz(raw) else { return nil }
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let monthSymbols = calendar.monthSymbols
        let monthName = (1...12).contains(month) ? monthSymbols[month - 1] : ""
        if monthName.isEmpty {
            return "Regular since \(year)"
        }
        return "Regular since \(monthName) \(year)"
    }

    static func yourHomeCrowdSinceLine(from raw: String?) -> String? {
        guard let raw, let date = SupabaseTimestampParsing.parseTimestamptz(raw) else { return nil }
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let monthSymbols = calendar.monthSymbols
        let monthName = (1...12).contains(month) ? monthSymbols[month - 1] : ""
        if monthName.isEmpty {
            return "Your home crowd since \(year)"
        }
        return "Your home crowd since \(monthName) \(year)"
    }

    static func homeCrowdSinceLine(from raw: String?) -> String? {
        guard let raw, let date = SupabaseTimestampParsing.parseTimestamptz(raw) else { return nil }
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let monthSymbols = calendar.monthSymbols
        let monthName = (1...12).contains(month) ? monthSymbols[month - 1] : ""
        if monthName.isEmpty {
            return "Home crowd since \(year)"
        }
        return "Home crowd since \(monthName) \(year)"
    }
}

enum HomeCrowdFanCountFormatter {
    static func publicLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        if count == 1 { return "1 fan calls this home" }
        return "\(count) fans call this home"
    }

    static func selfLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        if count == 1 { return "1 fan calls this home" }
        let others = max(0, count - 1)
        if others == 1 { return "You and 1 fan call this home" }
        return "You and \(others) fans call this home"
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
