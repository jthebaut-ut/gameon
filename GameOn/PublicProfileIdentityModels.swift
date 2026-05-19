import Foundation

/// Compact venue chip for public profile cards (city only — no coordinates).
struct PublicProfileVenueCard: Equatable, Identifiable {
    let venueId: UUID?
    let venueName: String
    let cityLabel: String

    var id: String {
        venueId?.uuidString.lowercased() ?? "\(venueName)-\(cityLabel)"
    }
}

/// Mutual friend avatar for stacked display.
struct PublicProfileMutualFanAvatar: Equatable, Identifiable {
    let userId: UUID
    let displayName: String
    let avatarURL: String?

    var id: UUID { userId }
}

/// Interest row for the Open To card.
struct PublicProfileOpenToItem: Equatable, Identifiable {
    let id: String
    let title: String
    let systemImage: String
}

enum PublicProfileOpenToBuilder {
    static func items(
        favoriteTeams: [FavoriteTeam],
        venueCount: Int,
        pickupHostedCount: Int,
        pickupJoinedCount: Int
    ) -> [PublicProfileOpenToItem] {
        var items: [PublicProfileOpenToItem] = []
        var seenSports = Set<FavoriteTeamSport>()

        for team in favoriteTeams {
            seenSports.insert(team.sport)
        }

        if seenSports.contains(.basketball) || pickupHostedCount > 0 || pickupJoinedCount > 0 {
            items.append(
                PublicProfileOpenToItem(
                    id: "pickup_basketball",
                    title: "Pickup Basketball",
                    systemImage: FavoriteTeamSport.basketball.catalogSymbol
                )
            )
        }

        if seenSports.contains(.soccer) {
            items.append(
                PublicProfileOpenToItem(
                    id: "soccer_matches",
                    title: "Soccer Matches",
                    systemImage: FavoriteTeamSport.soccer.catalogSymbol
                )
            )
        }

        if !favoriteTeams.isEmpty || venueCount > 0 {
            items.append(
                PublicProfileOpenToItem(
                    id: "watch_parties",
                    title: "Watch Parties",
                    systemImage: "tv.and.mediabox"
                )
            )
        }

        for sport in FavoriteTeamSport.allCases where seenSports.contains(sport) {
            let token = sport.rawValue.lowercased().replacingOccurrences(of: " ", with: "_")
            guard !items.contains(where: { $0.id == "sport_\(token)" }) else { continue }
            if sport == .basketball || sport == .soccer { continue }
            items.append(
                PublicProfileOpenToItem(
                    id: "sport_\(token)",
                    title: sport.chipTitle,
                    systemImage: sport.catalogSymbol
                )
            )
        }

        if pickupHostedCount > 0,
           !items.contains(where: { $0.id == "pickup_host" }) {
            items.append(
                PublicProfileOpenToItem(
                    id: "pickup_host",
                    title: "Hosting Pickup Games",
                    systemImage: "person.3.sequence.fill"
                )
            )
        }

        return items
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
            return "FanGeo member since \(year)"
        }
        return "FanGeo member since \(monthName) \(year)"
    }
}
