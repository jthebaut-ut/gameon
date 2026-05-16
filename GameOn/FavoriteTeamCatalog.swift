import SwiftUI

// MARK: - Models

enum FavoriteTeamSport: String, CaseIterable, Identifiable, Codable, Hashable {
    case soccer = "Soccer"
    case basketball = "Basketball"
    case football = "Football"
    case baseball = "Baseball"
    case hockey = "Hockey"
    case racing = "Racing"
    case ncaa = "NCAA"

    var id: String { rawValue }

    var chipTitle: String {
        switch self {
        case .racing: return "Formula 1"
        case .ncaa: return "NCAA"
        default: return rawValue
        }
    }

    var catalogSymbol: String {
        switch self {
        case .soccer: return "soccerball"
        case .basketball: return "basketball.fill"
        case .football: return "football.fill"
        case .baseball: return "baseball.fill"
        case .hockey: return "hockey.puck.fill"
        case .racing: return "flag.checkered.2.crossed.fill"
        case .ncaa: return "building.columns.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .soccer: return Color(red: 0.2, green: 0.72, blue: 0.42)
        case .basketball: return Color(red: 0.95, green: 0.55, blue: 0.12)
        case .football: return Color(red: 0.55, green: 0.38, blue: 0.22)
        case .baseball: return Color(red: 0.78, green: 0.18, blue: 0.22)
        case .hockey: return Color(red: 0.18, green: 0.72, blue: 0.92)
        case .racing: return Color(red: 0.88, green: 0.12, blue: 0.16)
        case .ncaa: return Color(red: 0.52, green: 0.14, blue: 0.22)
        }
    }
}

/// Local catalog entry (text names only; logos are generated initials / SF Symbols — no third-party marks).
struct FavoriteTeam: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let sport: FavoriteTeamSport
    let league: String
    /// SF Symbol when initials are not used.
    let fallbackSymbol: String
    let badgeRed: Double
    let badgeGreen: Double
    let badgeBlue: Double

    var initials: String {
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    var badgeColor: Color {
        Color(red: badgeRed, green: badgeGreen, blue: badgeBlue)
    }

    var identityStyle: FanGeoTeamIdentityStyle {
        FanGeoTeamIdentityStyle.forSport(sport)
    }
}

// MARK: - Catalog

enum FavoriteTeamCatalog {
    static let all: [FavoriteTeam] =
        soccer + basketball + football + baseball + hockey + racing + ncaa

    static func team(id: String) -> FavoriteTeam? {
        all.first { $0.id == id }
    }

    static func teams(
        sport: FavoriteTeamSport?,
        search: String
    ) -> [FavoriteTeam] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.filter { team in
            if let sport, team.sport != sport { return false }
            if q.isEmpty { return true }
            if team.name.lowercased().contains(q) { return true }
            if team.league.lowercased().contains(q) { return true }
            if team.sport.rawValue.lowercased().contains(q) { return true }
            if team.sport.chipTitle.lowercased().contains(q) { return true }
            return false
        }
    }

    // MARK: Soccer (12)

    private static let soccer: [FavoriteTeam] = [
        team("soccer-arsenal", "Arsenal", .soccer, "Premier League", "soccerball", 0.78, 0.12, 0.14),
        team("soccer-chelsea", "Chelsea", .soccer, "Premier League", "soccerball", 0.12, 0.35, 0.72),
        team("soccer-liverpool", "Liverpool", .soccer, "Premier League", "soccerball", 0.78, 0.14, 0.18),
        team("soccer-man-utd", "Manchester United", .soccer, "Premier League", "soccerball", 0.78, 0.12, 0.16),
        team("soccer-real-madrid", "Real Madrid", .soccer, "La Liga", "soccerball", 0.95, 0.82, 0.22),
        team("soccer-barcelona", "Barcelona", .soccer, "La Liga", "soccerball", 0.72, 0.12, 0.28),
        team("soccer-bayern", "Bayern Munich", .soccer, "Bundesliga", "soccerball", 0.78, 0.12, 0.22),
        team("soccer-psg", "Paris Saint-Germain", .soccer, "Ligue 1", "soccerball", 0.12, 0.22, 0.48),
        team("soccer-inter", "Inter Milan", .soccer, "Serie A", "soccerball", 0.12, 0.42, 0.72),
        team("soccer-milan", "AC Milan", .soccer, "Serie A", "soccerball", 0.78, 0.12, 0.14),
        team("soccer-galaxy", "LA Galaxy", .soccer, "MLS", "soccerball", 0.12, 0.32, 0.62),
        team("soccer-atlanta", "Atlanta United", .soccer, "MLS", "soccerball", 0.78, 0.18, 0.22)
    ]

    // MARK: Basketball (12)

    private static let basketball: [FavoriteTeam] = [
        team("nba-lakers", "Los Angeles Lakers", .basketball, "NBA", "basketball.fill", 0.42, 0.18, 0.62),
        team("nba-celtics", "Boston Celtics", .basketball, "NBA", "basketball.fill", 0.12, 0.48, 0.28),
        team("nba-warriors", "Golden State Warriors", .basketball, "NBA", "basketball.fill", 0.22, 0.42, 0.72),
        team("nba-bulls", "Chicago Bulls", .basketball, "NBA", "basketball.fill", 0.78, 0.12, 0.18),
        team("nba-heat", "Miami Heat", .basketball, "NBA", "basketball.fill", 0.78, 0.32, 0.18),
        team("nba-knicks", "New York Knicks", .basketball, "NBA", "basketball.fill", 0.22, 0.42, 0.72),
        team("nba-mavericks", "Dallas Mavericks", .basketball, "NBA", "basketball.fill", 0.12, 0.42, 0.62),
        team("nba-nuggets", "Denver Nuggets", .basketball, "NBA", "basketball.fill", 0.22, 0.32, 0.52),
        team("nba-suns", "Phoenix Suns", .basketball, "NBA", "basketball.fill", 0.92, 0.42, 0.12),
        team("nba-bucks", "Milwaukee Bucks", .basketball, "NBA", "basketball.fill", 0.12, 0.48, 0.32),
        team("nba-nets", "Brooklyn Nets", .basketball, "NBA", "basketball.fill", 0.12, 0.12, 0.12),
        team("nba-spurs", "San Antonio Spurs", .basketball, "NBA", "basketball.fill", 0.32, 0.32, 0.38)
    ]

    // MARK: Football (12)

    private static let football: [FavoriteTeam] = [
        team("nfl-chiefs", "Kansas City Chiefs", .football, "NFL", "football.fill", 0.78, 0.18, 0.22),
        team("nfl-eagles", "Philadelphia Eagles", .football, "NFL", "football.fill", 0.12, 0.42, 0.32),
        team("nfl-cowboys", "Dallas Cowboys", .football, "NFL", "football.fill", 0.12, 0.22, 0.48),
        team("nfl-49ers", "San Francisco 49ers", .football, "NFL", "football.fill", 0.78, 0.22, 0.18),
        team("nfl-bills", "Buffalo Bills", .football, "NFL", "football.fill", 0.12, 0.32, 0.62),
        team("nfl-ravens", "Baltimore Ravens", .football, "NFL", "football.fill", 0.18, 0.12, 0.42),
        team("nfl-dolphins", "Miami Dolphins", .football, "NFL", "football.fill", 0.12, 0.52, 0.62),
        team("nfl-packers", "Green Bay Packers", .football, "NFL", "football.fill", 0.12, 0.42, 0.22),
        team("nfl-steelers", "Pittsburgh Steelers", .football, "NFL", "football.fill", 0.22, 0.22, 0.22),
        team("nfl-bengals", "Cincinnati Bengals", .football, "NFL", "football.fill", 0.78, 0.22, 0.12),
        team("nfl-lions", "Detroit Lions", .football, "NFL", "football.fill", 0.12, 0.42, 0.62),
        team("nfl-jets", "New York Jets", .football, "NFL", "football.fill", 0.12, 0.32, 0.22)
    ]

    // MARK: Baseball (12)

    private static let baseball: [FavoriteTeam] = [
        team("mlb-yankees", "New York Yankees", .baseball, "MLB", "baseball.fill", 0.12, 0.22, 0.42),
        team("mlb-red-sox", "Boston Red Sox", .baseball, "MLB", "baseball.fill", 0.78, 0.12, 0.18),
        team("mlb-dodgers", "Los Angeles Dodgers", .baseball, "MLB", "baseball.fill", 0.12, 0.32, 0.62),
        team("mlb-cubs", "Chicago Cubs", .baseball, "MLB", "baseball.fill", 0.12, 0.38, 0.72),
        team("mlb-braves", "Atlanta Braves", .baseball, "MLB", "baseball.fill", 0.78, 0.12, 0.22),
        team("mlb-astros", "Houston Astros", .baseball, "MLB", "baseball.fill", 0.78, 0.42, 0.18),
        team("mlb-phillies", "Philadelphia Phillies", .baseball, "MLB", "baseball.fill", 0.78, 0.12, 0.28),
        team("mlb-mets", "New York Mets", .baseball, "MLB", "baseball.fill", 0.18, 0.42, 0.72),
        team("mlb-cardinals", "St. Louis Cardinals", .baseball, "MLB", "baseball.fill", 0.78, 0.12, 0.16),
        team("mlb-giants", "San Francisco Giants", .baseball, "MLB", "baseball.fill", 0.78, 0.32, 0.18),
        team("mlb-padres", "San Diego Padres", .baseball, "MLB", "baseball.fill", 0.78, 0.52, 0.22),
        team("mlb-mariners", "Seattle Mariners", .baseball, "MLB", "baseball.fill", 0.12, 0.42, 0.58)
    ]

    // MARK: Hockey (12) — generic city + sport names, color-inspired only

    private static let hockey: [FavoriteTeam] = [
        team("nhl-vegas-hockey", "Vegas Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.78, 0.62, 0.18),
        team("nhl-dallas-hockey", "Dallas Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.12, 0.42, 0.62),
        team("nhl-boston-hockey", "Boston Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.78, 0.18, 0.22),
        team("nhl-detroit-hockey", "Detroit Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.78, 0.12, 0.18),
        team("nhl-tampa-hockey", "Tampa Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.12, 0.38, 0.72),
        team("nhl-colorado-hockey", "Colorado Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.52, 0.22, 0.62),
        team("nhl-chicago-hockey", "Chicago Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.78, 0.18, 0.22),
        team("nhl-toronto-hockey", "Toronto Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.12, 0.12, 0.12),
        team("nhl-edmonton-hockey", "Edmonton Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.22, 0.42, 0.72),
        team("nhl-montreal-hockey", "Montreal Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.78, 0.12, 0.22),
        team("nhl-pittsburgh-hockey", "Pittsburgh Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.78, 0.52, 0.12),
        team("nhl-seattle-hockey", "Seattle Hockey", .hockey, "Pro Hockey", "hockey.puck.fill", 0.18, 0.52, 0.58)
    ]

    // MARK: Racing (12) — country / region inspired, no team trademarks

    private static let racing: [FavoriteTeam] = [
        team("f1-italian-racing", "Italian Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.12, 0.16),
        team("f1-british-racing", "British Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.12, 0.22, 0.48),
        team("f1-german-racing", "German Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.22, 0.22, 0.22),
        team("f1-spanish-racing", "Spanish Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.22, 0.12),
        team("f1-monaco-racing", "Monaco Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.12, 0.18),
        team("f1-japanese-racing", "Japanese Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.12, 0.14),
        team("f1-american-racing", "American Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.12, 0.32, 0.62),
        team("f1-french-racing", "French Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.12, 0.38, 0.72),
        team("f1-dutch-racing", "Dutch Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.92, 0.42, 0.12),
        team("f1-austrian-racing", "Austrian Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.18, 0.22),
        team("f1-brazilian-racing", "Brazilian Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.12, 0.48, 0.28),
        team("f1-australian-racing", "Australian Racing", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.12, 0.42, 0.22)
    ]

    // MARK: NCAA (12) — collegiate-style names, palette only

    private static let ncaa: [FavoriteTeam] = [
        team("ncaa-utah-cfb", "Utah College Football", .ncaa, "College Football", "building.columns.fill", 0.78, 0.22, 0.12),
        team("ncaa-alabama-cfb", "Alabama College Football", .ncaa, "College Football", "building.columns.fill", 0.78, 0.12, 0.18),
        team("ncaa-ohio-cfb", "Ohio College Football", .ncaa, "College Football", "building.columns.fill", 0.78, 0.12, 0.16),
        team("ncaa-michigan-cfb", "Michigan College Football", .ncaa, "College Football", "building.columns.fill", 0.12, 0.22, 0.62),
        team("ncaa-texas-cfb", "Texas College Football", .ncaa, "College Football", "building.columns.fill", 0.52, 0.14, 0.22),
        team("ncaa-georgia-cfb", "Georgia College Football", .ncaa, "College Football", "building.columns.fill", 0.78, 0.12, 0.18),
        team("ncaa-oregon-cfb", "Oregon College Football", .ncaa, "College Football", "building.columns.fill", 0.12, 0.42, 0.22),
        team("ncaa-la-cbb", "Los Angeles College Basketball", .ncaa, "College Basketball", "building.columns.fill", 0.52, 0.14, 0.62),
        team("ncaa-duke-cbb", "Durham College Basketball", .ncaa, "College Basketball", "building.columns.fill", 0.12, 0.22, 0.48),
        team("ncaa-kansas-cbb", "Kansas College Basketball", .ncaa, "College Basketball", "building.columns.fill", 0.12, 0.32, 0.72),
        team("ncaa-kentucky-cbb", "Kentucky College Basketball", .ncaa, "College Basketball", "building.columns.fill", 0.12, 0.22, 0.48),
        team("ncaa-gonzaga-cbb", "Spokane College Basketball", .ncaa, "College Basketball", "building.columns.fill", 0.78, 0.12, 0.22)
    ]

    private static func team(
        _ id: String,
        _ name: String,
        _ sport: FavoriteTeamSport,
        _ league: String,
        _ symbol: String,
        _ r: Double,
        _ g: Double,
        _ b: Double
    ) -> FavoriteTeam {
        FavoriteTeam(
            id: id,
            name: name,
            sport: sport,
            league: league,
            fallbackSymbol: symbol,
            badgeRed: r,
            badgeGreen: g,
            badgeBlue: b
        )
    }
}

// MARK: - Local persistence (AppStorage)

enum FavoriteTeamsStore {
    static let appStorageKey = "gameon.profile.favoriteTeamIDs"

    static func decodeIDs(from raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func encodeIDs(_ ids: [String]) -> String {
        ids.joined(separator: ",")
    }

    static func resolvedTeams(from raw: String) -> [FavoriteTeam] {
        resolvedTeams(fromIDs: decodeIDs(from: raw))
    }

    static func resolvedTeams(fromIDs ids: [String]) -> [FavoriteTeam] {
        ids.compactMap { FavoriteTeamCatalog.team(id: $0) }
    }

    static func writeToAppStorage(_ ids: [String]) {
        UserDefaults.standard.set(encodeIDs(ids), forKey: appStorageKey)
    }
}
