import Foundation
import SwiftUI

// MARK: - Open To catalog

struct FanOpenToActivityDefinition: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String

    func tint(colorScheme: ColorScheme) -> Color {
        FanOpenToCatalog.tint(for: id, colorScheme: colorScheme)
    }
}

enum FanOpenToCatalog {
    static let all: [FanOpenToActivityDefinition] = [
        FanOpenToActivityDefinition(id: "pickup_basketball", title: "Pickup Basketball", systemImage: "basketball.fill"),
        FanOpenToActivityDefinition(id: "soccer_matches", title: "Soccer Matches", systemImage: "soccerball"),
        FanOpenToActivityDefinition(id: "watch_parties", title: "Watch Parties", systemImage: "tv.and.mediabox.fill"),
        FanOpenToActivityDefinition(id: "pickup_soccer", title: "Pickup Soccer", systemImage: "soccerball"),
        FanOpenToActivityDefinition(id: "pickup_football", title: "Pickup Football", systemImage: "football.fill"),
        FanOpenToActivityDefinition(id: "pickup_baseball", title: "Pickup Baseball", systemImage: "baseball.fill"),
        FanOpenToActivityDefinition(id: "pickup_tennis", title: "Pickup Tennis", systemImage: "tennisball.fill"),
        FanOpenToActivityDefinition(id: "pickup_golf", title: "Pickup Golf", systemImage: "figure.golf"),
        FanOpenToActivityDefinition(id: "pickup_hockey", title: "Pickup Hockey", systemImage: "hockey.puck.fill"),
        FanOpenToActivityDefinition(id: "running_fitness", title: "Running / Fitness", systemImage: "figure.run"),
        FanOpenToActivityDefinition(id: "combat_sports", title: "Combat Sports", systemImage: "figure.boxing"),
        FanOpenToActivityDefinition(id: "racing", title: "Racing", systemImage: "flag.checkered.2.crossed.fill"),
        FanOpenToActivityDefinition(id: "meet_local_fans", title: "Meet Local Fans", systemImage: "person.2.wave.2.fill")
    ]

    static func definition(id: String) -> FanOpenToActivityDefinition? {
        all.first { $0.id == id }
    }

    static func definitions(ids: [String]) -> [FanOpenToActivityDefinition] {
        ids.compactMap { definition(id: $0) }
    }

    static func tint(for id: String, colorScheme: ColorScheme) -> Color {
        switch id {
        case "pickup_basketball", "pickup_tennis":
            return FavoriteTeamSport.basketball.accentColor
        case "soccer_matches", "pickup_soccer":
            return FavoriteTeamSport.soccer.accentColor
        case "watch_parties":
            return Color(red: 0.98, green: 0.67, blue: 0.33)
        case "pickup_football":
            return FavoriteTeamSport.football.accentColor
        case "pickup_baseball":
            return FavoriteTeamSport.baseball.accentColor
        case "pickup_golf":
            return FavoriteTeamSport.golf.accentColor
        case "pickup_hockey":
            return FavoriteTeamSport.hockey.accentColor
        case "running_fitness":
            return FGColor.accentGreen
        case "combat_sports":
            return FavoriteTeamSport.combat.accentColor
        case "racing":
            return FavoriteTeamSport.racing.accentColor
        case "meet_local_fans":
            return FGColor.accentBlue
        default:
            return FGColor.accentBlue
        }
    }

    static func publicDisplayItems(from itemIDs: [String]) -> [PublicProfileOpenToItem] {
        definitions(ids: itemIDs).map { def in
            PublicProfileOpenToItem(
                id: def.id,
                title: def.title,
                systemImage: def.systemImage,
                tint: tint(for: def.id, colorScheme: .light)
            )
        }
    }

    /// Maps legacy boolean prefs into `open_to_items` ids.
    static func idsFromLegacyBooleans(
        watchParties: Bool?,
        pickupBasketball: Bool?,
        soccerMatches: Bool?,
        meetingLocalFans: Bool?
    ) -> [String] {
        var ids: [String] = []
        if pickupBasketball == true { ids.append("pickup_basketball") }
        if soccerMatches == true { ids.append("soccer_matches") }
        if watchParties == true { ids.append("watch_parties") }
        if meetingLocalFans == true { ids.append("meet_local_fans") }
        return ids
    }
}

// MARK: - Stored preferences (JSONB)

/// Stored in `user_profiles.fan_identity_preferences`.
struct FanIdentityPreferences: Codable, Equatable, Sendable {
    var openToItems: [String]
    var personalityTags: [String]

    /// True when JSON included `open_to_items` (including an empty array after save).
    private(set) var openToItemsKeyPresent: Bool = false

    /// Legacy boolean fields — read-only for backward compatibility.
    private var openToWatchParties: Bool?
    private var openToPickupBasketball: Bool?
    private var openToSoccerMatches: Bool?
    private var openToMeetingLocalFans: Bool?

    init(openToItems: [String] = [], personalityTags: [String] = []) {
        self.openToItems = openToItems
        self.personalityTags = personalityTags
        self.openToWatchParties = nil
        self.openToPickupBasketball = nil
        self.openToSoccerMatches = nil
        self.openToMeetingLocalFans = nil
    }

    private enum CodingKeys: String, CodingKey {
        case openToItems = "open_to_items"
        case personalityTags = "personality_tags"
        case openToWatchParties = "open_to_watch_parties"
        case openToPickupBasketball = "open_to_pickup_basketball"
        case openToSoccerMatches = "open_to_soccer_matches"
        case openToMeetingLocalFans = "open_to_meeting_local_fans"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openToItemsKeyPresent = c.contains(.openToItems)
        openToItems = try c.decodeIfPresent([String].self, forKey: .openToItems) ?? []
        personalityTags = try c.decodeIfPresent([String].self, forKey: .personalityTags) ?? []
        openToWatchParties = try c.decodeIfPresent(Bool.self, forKey: .openToWatchParties)
        openToPickupBasketball = try c.decodeIfPresent(Bool.self, forKey: .openToPickupBasketball)
        openToSoccerMatches = try c.decodeIfPresent(Bool.self, forKey: .openToSoccerMatches)
        openToMeetingLocalFans = try c.decodeIfPresent(Bool.self, forKey: .openToMeetingLocalFans)

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
        try c.encode(openToItems, forKey: .openToItems)
        try c.encode(personalityTags, forKey: .personalityTags)
    }

    mutating func markOpenToSaved() {
        openToItemsKeyPresent = true
    }

    static let empty = FanIdentityPreferences()

    /// Item ids to show on public profile (explicit list only).
    var resolvedOpenToItemIDs: [String] {
        openToItems.filter { FanOpenToCatalog.definition(id: $0) != nil }
    }

    var hasExplicitOpenToConfiguration: Bool {
        openToItemsKeyPresent
            || openToWatchParties != nil
            || openToPickupBasketball != nil
            || openToSoccerMatches != nil
            || openToMeetingLocalFans != nil
    }
}

// MARK: - Personality tags

enum FanPersonalityTag: String, CaseIterable, Identifiable, Hashable {
    case loud
    case dieHard = "die_hard"
    case statsNerd = "stats_nerd"
    case casual
    case trashTalker = "trash_talker"
    case optimistic
    case superSocial = "super_social"
    case rivalryFriendly = "rivalry_friendly"
    case hostEnergy = "host_energy"
    case familyFriendly = "family_friendly"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .loud: return "Loud"
        case .dieHard: return "Die-hard"
        case .statsNerd: return "Stats nerd"
        case .casual: return "Casual"
        case .trashTalker: return "Trash talker"
        case .optimistic: return "Optimistic"
        case .superSocial: return "Super social"
        case .rivalryFriendly: return "Rivalry friendly"
        case .hostEnergy: return "Host energy"
        case .familyFriendly: return "Family friendly"
        }
    }
}

/// Interest chip for public Open To grid.
struct PublicProfileOpenToItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let tint: Color

    init(id: String, title: String, systemImage: String, tint: Color = FGColor.accentBlue) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }
}

enum PublicProfileOpenToBuilder {
    /// Public profile shows only explicitly saved `open_to_items` (after legacy migration on decode).
    static func items(
        preferences: FanIdentityPreferences,
        favoriteTeams: [FavoriteTeam],
        venueCount: Int,
        pickupHostedCount: Int,
        pickupJoinedCount: Int
    ) -> [PublicProfileOpenToItem] {
        let ids = preferences.resolvedOpenToItemIDs
        if !ids.isEmpty {
            return FanOpenToCatalog.publicDisplayItems(from: ids)
        }

        // Users who never set prefs: optional light inference (no toggle UI).
        guard !preferences.hasExplicitOpenToConfiguration else { return [] }

        var inferred: [String] = []
        var seenSports = Set(favoriteTeams.map(\.sport))
        if seenSports.contains(.basketball) || pickupHostedCount > 0 || pickupJoinedCount > 0 {
            inferred.append("pickup_basketball")
        }
        if seenSports.contains(.soccer) {
            inferred.append("soccer_matches")
        }
        if !favoriteTeams.isEmpty || venueCount > 0 {
            inferred.append("watch_parties")
        }
        return FanOpenToCatalog.publicDisplayItems(from: inferred)
    }
}

enum PublicProfileMemberSinceFormatter {
    static func label(from raw: String?) -> String? {
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
            return "Member since \(year)"
        }
        return "Member since \(monthName) \(year)"
    }
}
