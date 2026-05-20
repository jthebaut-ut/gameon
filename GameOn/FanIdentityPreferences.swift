import Foundation
import SwiftUI

// MARK: - Open To catalog (Pickup sports + social activities)

struct FanOpenToActivityDefinition: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let isSocial: Bool

    func tint(colorScheme: ColorScheme) -> Color {
        FanOpenToCatalog.tint(for: id, colorScheme: colorScheme)
    }
}

enum FanOpenToSocialID {
    static let watchParties = "watch_parties"
    static let sportsBars = "sports_bars"
    static let meetLocalFans = "meet_local_fans"
}

/// Open To options: same sport tokens as Pickup Games (`AppSportCatalog`) plus fixed social activities.
enum FanOpenToCatalog {
    /// Authoritative pickup sport list (same as pickup game create/edit form).
    static var pickupSportTokens: [String] {
        AppSportCatalog.formPickerSportsOrdered
    }

    static let socialActivities: [FanOpenToActivityDefinition] = [
        FanOpenToActivityDefinition(id: FanOpenToSocialID.watchParties, title: "Watch Parties", systemImage: "tv.and.mediabox.fill", isSocial: true),
        FanOpenToActivityDefinition(id: FanOpenToSocialID.sportsBars, title: "Sports Bars", systemImage: "wineglass.fill", isSocial: true),
        FanOpenToActivityDefinition(id: FanOpenToSocialID.meetLocalFans, title: "Meeting Local Fans", systemImage: "person.2.wave.2.fill", isSocial: true)
    ]

    static var sportActivities: [FanOpenToActivityDefinition] {
        pickupSportTokens.map { token in
            let visual = SportFilterCatalog.resolve(token)
            return FanOpenToActivityDefinition(
                id: token,
                title: AppSportCatalog.displayLabel(forSportToken: token),
                systemImage: visual.systemImage,
                isSocial: false
            )
        }
    }

    static var all: [FanOpenToActivityDefinition] {
        socialActivities + sportActivities
    }

    static func definition(id: String) -> FanOpenToActivityDefinition? {
        all.first { $0.id == id }
    }

    static func definitions(ids: [String]) -> [FanOpenToActivityDefinition] {
        ids.compactMap { definition(id: $0) }
    }

    static func tint(for id: String, colorScheme: ColorScheme) -> Color {
        if id == FanOpenToSocialID.watchParties {
            return Color(red: 0.98, green: 0.67, blue: 0.33)
        }
        if id == FanOpenToSocialID.sportsBars {
            return Color(red: 0.72, green: 0.28, blue: 0.52)
        }
        if id == FanOpenToSocialID.meetLocalFans {
            return FGColor.accentBlue
        }
        return SportFilterCatalog.resolve(id).accent
    }

    static func publicDisplayItems(from itemIDs: [String]) -> [PublicProfileOpenToItem] {
        definitions(ids: itemIDs).map { def in
            PublicProfileOpenToItem(
                id: def.id,
                title: def.title,
                systemImage: def.systemImage,
                tint: tint(for: def.id, colorScheme: .light),
                isSocial: def.isSocial
            )
        }
    }

    /// Maps legacy Open To ids / booleans to canonical pickup tokens or social ids.
    static func canonicalItemID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if definition(id: trimmed) != nil { return trimmed }
        if let mapped = legacyOpenToIDMap[trimmed] { return mapped }
        if pickupSportTokens.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return pickupSportTokens.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        }
        for category in AppSportCatalog.SportCatalog.groupedCategories {
            for row in category.rows {
                if row.label.caseInsensitiveCompare(trimmed) == .orderedSame
                    || row.selection.caseInsensitiveCompare(trimmed) == .orderedSame {
                    return row.selection
                }
            }
        }
        return nil
    }

    static func canonicalizeItemIDs(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in raw {
            guard let id = canonicalItemID(item), seen.insert(id).inserted else { continue }
            out.append(id)
        }
        return out
    }

    private static let legacyOpenToIDMap: [String: String] = [
        "pickup_basketball": "NBA",
        "pickup_soccer": "Soccer",
        "soccer_matches": "Soccer",
        "pickup_football": "NFL",
        "pickup_baseball": "Baseball",
        "pickup_tennis": "Tennis",
        "pickup_golf": "Golf",
        "pickup_hockey": "NHL",
        "running_fitness": "Running",
        "combat_sports": "UFC",
        "racing": "Formula 1",
        "meet_local_fans": FanOpenToSocialID.meetLocalFans,
        "open_to_meeting_local_fans": FanOpenToSocialID.meetLocalFans
    ]

    static func idsFromLegacyBooleans(
        watchParties: Bool?,
        pickupBasketball: Bool?,
        soccerMatches: Bool?,
        meetingLocalFans: Bool?
    ) -> [String] {
        var ids: [String] = []
        if pickupBasketball == true { ids.append("NBA") }
        if soccerMatches == true { ids.append("Soccer") }
        if watchParties == true { ids.append(FanOpenToSocialID.watchParties) }
        if meetingLocalFans == true { ids.append(FanOpenToSocialID.meetLocalFans) }
        return canonicalizeItemIDs(ids)
    }
}

// MARK: - Stored preferences (JSONB)

/// Stored in `user_profiles.fan_identity_preferences`.
struct FanIdentityPreferences: Codable, Equatable, Sendable {
    var openToItems: [String]

    /// Decoded only; never written on save.
    private var personalityTags: [String]?

    /// True when JSON included `open_to_items` (including an empty array after save).
    private(set) var openToItemsKeyPresent: Bool = false

    private var openToWatchParties: Bool?
    private var openToPickupBasketball: Bool?
    private var openToSoccerMatches: Bool?
    private var openToMeetingLocalFans: Bool?

    init(openToItems: [String] = []) {
        self.openToItems = FanOpenToCatalog.canonicalizeItemIDs(openToItems)
        self.personalityTags = nil
        self.openToWatchParties = nil
        self.openToPickupBasketball = nil
        self.openToSoccerMatches = nil
        self.openToMeetingLocalFans = nil
    }

    private enum CodingKeys: String, CodingKey {
        case openToItems = "open_to_items"
        case openToItemsCamelCase = "openToItems"
        case personalityTags = "personality_tags"
        case openToWatchParties = "open_to_watch_parties"
        case openToPickupBasketball = "open_to_pickup_basketball"
        case openToSoccerMatches = "open_to_soccer_matches"
        case openToMeetingLocalFans = "open_to_meeting_local_fans"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openToItemsKeyPresent = c.contains(.openToItems) || c.contains(.openToItemsCamelCase)
        var rawItems = (try? c.decode([String].self, forKey: .openToItems)) ?? []
        if rawItems.isEmpty {
            rawItems = (try? c.decode([String].self, forKey: .openToItemsCamelCase)) ?? []
        }
        openToItems = FanOpenToCatalog.canonicalizeItemIDs(rawItems)
        personalityTags = try? c.decode([String].self, forKey: .personalityTags)
        openToWatchParties = try? c.decode(Bool.self, forKey: .openToWatchParties)
        openToPickupBasketball = try? c.decode(Bool.self, forKey: .openToPickupBasketball)
        openToSoccerMatches = try? c.decode(Bool.self, forKey: .openToSoccerMatches)
        openToMeetingLocalFans = try? c.decode(Bool.self, forKey: .openToMeetingLocalFans)

        if openToItems.isEmpty {
            let legacy = FanOpenToCatalog.idsFromLegacyBooleans(
                watchParties: openToWatchParties,
                pickupBasketball: openToPickupBasketball,
                soccerMatches: openToSoccerMatches,
                meetingLocalFans: openToMeetingLocalFans
            )
            if !legacy.isEmpty {
                openToItems = legacy
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(FanOpenToCatalog.canonicalizeItemIDs(openToItems), forKey: .openToItems)
    }

    mutating func markOpenToSaved() {
        openToItemsKeyPresent = true
    }

    static let empty = FanIdentityPreferences()

    var resolvedOpenToItemIDs: [String] {
        FanOpenToCatalog.canonicalizeItemIDs(openToItems)
    }

    var hasExplicitOpenToConfiguration: Bool {
        openToItemsKeyPresent
            || openToWatchParties != nil
            || openToPickupBasketball != nil
            || openToSoccerMatches != nil
            || openToMeetingLocalFans != nil
    }
}

/// Interest chip for public Open To grid.
struct PublicProfileOpenToItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let tint: Color
    let isSocial: Bool

    init(id: String, title: String, systemImage: String, tint: Color = FGColor.accentBlue, isSocial: Bool = false) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.isSocial = isSocial
    }
}

enum PublicProfileOpenToBuilder {
    /// Public profile shows only explicitly saved Open To items (no inference).
    static func items(
        preferences: FanIdentityPreferences,
        favoriteTeams: [FavoriteTeam],
        venueCount: Int,
        pickupHostedCount: Int,
        pickupJoinedCount: Int
    ) -> [PublicProfileOpenToItem] {
        _ = favoriteTeams
        _ = venueCount
        _ = pickupHostedCount
        _ = pickupJoinedCount
        let ids = preferences.resolvedOpenToItemIDs
        guard !ids.isEmpty else { return [] }
        return FanOpenToCatalog.publicDisplayItems(from: ids)
    }
}

enum PublicProfileMemberSinceFormatter {
    /// Public hero line, e.g. "FanGeo member since May 2026" or "FanGeo member since 2026".
    static func label(from raw: String?) -> String? {
        fanGeoMemberSinceLabel(from: raw)
    }

    static func fanGeoMemberSinceLabel(from raw: String?) -> String? {
        guard let raw,
              let date = SupabaseTimestampParsing.parseTimestamptz(raw) else {
            return nil
        }
        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let monthSymbols = calendar.monthSymbols
        let monthName = (1...12).contains(month) ? monthSymbols[month - 1] : ""
        if monthName.isEmpty {
            return "FanGeo member since \(year)"
        }
        return "FanGeo member since \(monthName) \(year)"
    }
}
