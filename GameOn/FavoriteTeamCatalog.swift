import SwiftUI

// MARK: - Models

enum FavoriteTeamSport: String, CaseIterable, Identifiable, Codable, Hashable {
    case soccer = "Soccer"
    case basketball = "Basketball"
    case football = "Football"
    case tennis = "Tennis"
    case baseball = "Baseball"
    case hockey = "Hockey"
    case golf = "Golf"
    case combat = "Combat Sports"
    case racing = "Racing"
    case ncaa = "NCAA"

    var id: String { rawValue }

    var chipTitle: String {
        switch self {
        case .racing: return "Racing"
        case .combat: return "Combat"
        case .ncaa: return "NCAA"
        default: return rawValue
        }
    }

    var catalogSymbol: String {
        switch self {
        case .soccer: return "soccerball"
        case .basketball: return "basketball.fill"
        case .football: return "football.fill"
        case .tennis: return "tennisball.fill"
        case .baseball: return "baseball.fill"
        case .hockey: return "hockey.puck.fill"
        case .golf: return "figure.golf"
        case .combat: return "figure.boxing"
        case .racing: return "flag.checkered.2.crossed.fill"
        case .ncaa: return "building.columns.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .soccer: return Color(red: 0.2, green: 0.72, blue: 0.42)
        case .basketball: return Color(red: 0.95, green: 0.55, blue: 0.12)
        case .football: return Color(red: 0.55, green: 0.38, blue: 0.22)
        case .tennis: return Color(red: 0.62, green: 0.82, blue: 0.18)
        case .baseball: return Color(red: 0.78, green: 0.18, blue: 0.22)
        case .hockey: return Color(red: 0.18, green: 0.72, blue: 0.92)
        case .golf: return Color(red: 0.18, green: 0.62, blue: 0.32)
        case .combat: return Color(red: 0.62, green: 0.18, blue: 0.18)
        case .racing: return Color(red: 0.88, green: 0.12, blue: 0.16)
        case .ncaa: return Color(red: 0.52, green: 0.14, blue: 0.22)
        }
    }

    var discoverSportToken: String {
        switch self {
        case .basketball: return "NBA"
        case .football: return "NFL"
        case .hockey: return "NHL"
        case .combat: return "UFC"
        case .racing: return "Formula 1"
        default: return chipTitle
        }
    }
}

func sportIcon(for sportName: String) -> String {
    let normalized = sportName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.contains("soccer") || normalized.contains("mls") || normalized.contains("premier") {
        return "⚽️"
    }
    if normalized.contains("basketball") || normalized.contains("nba") {
        return "🏀"
    }
    if normalized.contains("football") || normalized.contains("nfl") {
        return "🏈"
    }
    if normalized.contains("baseball") || normalized.contains("mlb") {
        return "⚾️"
    }
    if normalized.contains("hockey") || normalized.contains("nhl") {
        return "🏒"
    }
    if normalized.contains("tennis") {
        return "🎾"
    }
    if normalized.contains("golf") {
        return "⛳️"
    }
    if normalized.contains("combat") || normalized.contains("mma") || normalized.contains("ufc") || normalized.contains("boxing") {
        return "🥊"
    }
    if normalized.contains("racing") || normalized.contains("formula") || normalized.contains("f1") {
        return "🏎️"
    }
    if normalized.contains("volleyball") {
        return "🏐"
    }
    if normalized.contains("cricket") {
        return "🏏"
    }
    if normalized.contains("rugby") {
        return "🏉"
    }
    return "🏟️"
}

func sportAccentColor(for sportName: String) -> Color {
    let normalized = sportName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.contains("soccer") || normalized.contains("mls") || normalized.contains("premier") {
        return Color(red: 0.18, green: 0.74, blue: 0.38)
    }
    if normalized.contains("basketball") || normalized.contains("nba") {
        return Color(red: 0.96, green: 0.48, blue: 0.12)
    }
    if normalized.contains("football") || normalized.contains("nfl") {
        return Color(red: 0.68, green: 0.46, blue: 0.20)
    }
    if normalized.contains("baseball") || normalized.contains("mlb") {
        return Color(red: 0.82, green: 0.16, blue: 0.22)
    }
    if normalized.contains("hockey") || normalized.contains("nhl") {
        return Color(red: 0.20, green: 0.78, blue: 0.96)
    }
    if normalized.contains("golf") {
        return Color(red: 0.05, green: 0.62, blue: 0.35)
    }
    if normalized.contains("tennis") {
        return Color(red: 0.72, green: 0.90, blue: 0.14)
    }
    if normalized.contains("combat") || normalized.contains("mma") || normalized.contains("ufc") || normalized.contains("boxing") {
        return Color(red: 0.76, green: 0.12, blue: 0.14)
    }
    if normalized.contains("racing") || normalized.contains("formula") || normalized.contains("f1") {
        return Color(red: 0.92, green: 0.10, blue: 0.14)
    }
    if normalized.contains("volleyball") {
        return Color(red: 0.94, green: 0.34, blue: 0.28)
    }
    if normalized.contains("cricket") {
        return Color(red: 0.10, green: 0.68, blue: 0.54)
    }
    if normalized.contains("rugby") {
        return Color(red: 0.48, green: 0.18, blue: 0.13)
    }
    return Color(red: 0.12, green: 0.64, blue: 0.72)
}

enum FavoriteTeamKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case team = "team"
    case nationalTeam = "national_team"
    case player = "player"
    case tournament = "tournament"
    case driver = "driver"
    case fighter = "fighter"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .team: return "Team"
        case .nationalTeam: return "National Team"
        case .player: return "Player"
        case .tournament: return "League/Tournament"
        case .driver: return "Driver"
        case .fighter: return "Fighter"
        }
    }
}

struct FavoriteTeamCategory: Identifiable, Hashable {
    let id: String
    let title: String
}

/// Local catalog entry (text names only; logos are generated initials / SF Symbols — no third-party marks).
struct FavoriteTeam: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let sport: FavoriteTeamSport
    let league: String
    let region: String
    let kind: FavoriteTeamKind
    let shortCode: String?
    let searchAliases: [String]
    /// SF Symbol when initials are not used.
    let fallbackSymbol: String
    let badgeRed: Double
    let badgeGreen: Double
    let badgeBlue: Double

    var initials: String {
        if let shortCode, !shortCode.isEmpty {
            return shortCode
        }
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
        soccer + basketball + football + baseball + hockey + golf + racing + tennis + combat + ncaa + favoritePlayers + favoriteTournaments

    static let selectorSports: [FavoriteTeamSport] = [
        .soccer,
        .basketball,
        .football,
        .tennis,
        .baseball,
        .hockey,
        .golf,
        .combat,
        .racing
    ]

    static var defaultSport: FavoriteTeamSport {
        selectorSports.first { !categories(for: $0).isEmpty } ?? .soccer
    }

    static func defaultCategoryID(for sport: FavoriteTeamSport) -> String? {
        categories(for: sport).first?.id
    }

    static func team(id: String) -> FavoriteTeam? {
        all.first { $0.id == id }
    }

    static func teams(
        sport: FavoriteTeamSport?,
        search: String,
        region: String? = nil,
        kind: FavoriteTeamKind? = nil
    ) -> [FavoriteTeam] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.filter { team in
            if let sport, team.sport != sport { return false }
            if let region, team.region != region { return false }
            if let kind, team.kind != kind { return false }
            if q.isEmpty { return true }
            if team.name.lowercased().contains(q) { return true }
            if team.league.lowercased().contains(q) { return true }
            if team.region.lowercased().contains(q) { return true }
            if team.kind.rawValue.lowercased().contains(q) { return true }
            if team.kind.displayTitle.lowercased().contains(q) { return true }
            if team.shortCode?.lowercased().contains(q) == true { return true }
            if team.searchAliases.contains(where: { $0.lowercased().contains(q) }) { return true }
            if team.sport.rawValue.lowercased().contains(q) { return true }
            if team.sport.chipTitle.lowercased().contains(q) { return true }
            return false
        }
    }

    static func teams(
        sport: FavoriteTeamSport,
        categoryID: String?,
        region: String? = nil,
        search: String = ""
    ) -> [FavoriteTeam] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.filter { team in
            guard sportMatches(team, selectedSport: sport) else { return false }
            if let categoryID, !categoryMatches(team, categoryID: categoryID) { return false }
            if let region, team.region != region { return false }
            if q.isEmpty { return true }
            return matchesSearch(team, query: q)
        }
    }

    static func searchTeams(_ search: String) -> [FavoriteTeam] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { matchesSearch($0, query: q) }
    }

    static func regions(for sport: FavoriteTeamSport?) -> [String] {
        let teams = all.filter { team in
            if let sport {
                return team.sport == sport
            }
            return true
        }
        return Array(Set(teams.map(\.region))).sorted()
    }

    static func regions(for sport: FavoriteTeamSport, categoryID: String?) -> [String] {
        let teams = teams(sport: sport, categoryID: categoryID)
        let knownRegions = Set(["Europe", "North America", "South America", "Asia", "Africa", "Oceania"])
        let order = ["Europe", "North America", "South America", "Asia", "Africa", "Oceania"]
        let regions = Set(teams.map(\.region).filter { knownRegions.contains($0) })
        return order.filter { regions.contains($0) }
    }

    static func categories(for sport: FavoriteTeamSport) -> [FavoriteTeamCategory] {
        categoryDefinitions(for: sport).filter { category in
            all.contains { team in
                sportMatches(team, selectedSport: sport) && categoryMatches(team, categoryID: category.id)
            }
        }
    }

    static func sectionGroups(for teams: [FavoriteTeam]) -> [(title: String, teams: [FavoriteTeam])] {
        let grouped = Dictionary(grouping: teams) { team in
            team.region
        }
        return grouped
            .map { title, teams in
                (title: title, teams: teams.sorted { $0.name < $1.name })
            }
            .sorted { $0.title < $1.title }
    }

    private static func sportMatches(_ team: FavoriteTeam, selectedSport: FavoriteTeamSport) -> Bool {
        if selectedSport == .basketball, team.sport == .ncaa { return true }
        return team.sport == selectedSport
    }

    private static func categoryDefinitions(for sport: FavoriteTeamSport) -> [FavoriteTeamCategory] {
        switch sport {
        case .soccer:
            return [
                FavoriteTeamCategory(id: "soccer-clubs", title: "Clubs"),
                FavoriteTeamCategory(id: "soccer-national-teams", title: "National Teams"),
                FavoriteTeamCategory(id: "soccer-players", title: "Players"),
                FavoriteTeamCategory(id: "soccer-tournaments", title: "Tournaments")
            ]
        case .basketball:
            return [
                FavoriteTeamCategory(id: "basketball-nba", title: "NBA"),
                FavoriteTeamCategory(id: "basketball-ncaa", title: "NCAA"),
                FavoriteTeamCategory(id: "basketball-national-teams", title: "National Teams"),
                FavoriteTeamCategory(id: "basketball-players", title: "Players")
            ]
        case .football:
            return [
                FavoriteTeamCategory(id: "football-nfl", title: "NFL"),
                FavoriteTeamCategory(id: "football-players", title: "Players"),
                FavoriteTeamCategory(id: "football-tournaments", title: "Leagues")
            ]
        case .tennis:
            return [
                FavoriteTeamCategory(id: "tennis-players", title: "Players"),
                FavoriteTeamCategory(id: "tennis-tournaments", title: "Tournaments")
            ]
        case .baseball:
            return [
                FavoriteTeamCategory(id: "baseball-mlb", title: "MLB"),
                FavoriteTeamCategory(id: "baseball-players", title: "Players"),
                FavoriteTeamCategory(id: "baseball-tournaments", title: "Leagues")
            ]
        case .hockey:
            return [
                FavoriteTeamCategory(id: "hockey-teams", title: "Teams")
            ]
        case .golf:
            return [
                FavoriteTeamCategory(id: "golf-players", title: "Players"),
                FavoriteTeamCategory(id: "golf-tournaments", title: "Tournaments")
            ]
        case .combat:
            return [
                FavoriteTeamCategory(id: "combat-fighters", title: "Fighters"),
                FavoriteTeamCategory(id: "combat-promotions", title: "Promotions")
            ]
        case .racing:
            return [
                FavoriteTeamCategory(id: "racing-teams", title: "Teams"),
                FavoriteTeamCategory(id: "racing-drivers", title: "Drivers"),
                FavoriteTeamCategory(id: "racing-series", title: "Series")
            ]
        case .ncaa:
            return [
                FavoriteTeamCategory(id: "basketball-ncaa", title: "NCAA")
            ]
        }
    }

    private static func categoryMatches(_ team: FavoriteTeam, categoryID: String) -> Bool {
        switch categoryID {
        case "soccer-clubs":
            return team.sport == .soccer && team.kind == .team
        case "soccer-national-teams":
            return team.sport == .soccer && team.kind == .nationalTeam
        case "soccer-players":
            return team.sport == .soccer && team.kind == .player
        case "soccer-tournaments":
            return team.sport == .soccer && team.kind == .tournament
        case "basketball-nba":
            return team.sport == .basketball && (team.league == "NBA" || team.id == "league-nba")
        case "basketball-ncaa":
            return team.sport == .ncaa
        case "basketball-national-teams":
            return team.sport == .basketball && team.kind == .nationalTeam
        case "basketball-players":
            return team.sport == .basketball && team.kind == .player
        case "football-nfl":
            return team.sport == .football && team.kind == .team
        case "football-players":
            return team.sport == .football && team.kind == .player
        case "football-tournaments":
            return team.sport == .football && team.kind == .tournament
        case "tennis-players":
            return team.sport == .tennis && team.kind == .player
        case "tennis-tournaments":
            return team.sport == .tennis && team.kind == .tournament
        case "baseball-mlb":
            return team.sport == .baseball && team.kind == .team
        case "baseball-players":
            return team.sport == .baseball && team.kind == .player
        case "baseball-tournaments":
            return team.sport == .baseball && team.kind == .tournament
        case "hockey-teams":
            return team.sport == .hockey
        case "golf-players":
            return team.sport == .golf && team.kind == .player
        case "golf-tournaments":
            return team.sport == .golf && team.kind == .tournament
        case "combat-fighters":
            return team.sport == .combat && team.kind == .fighter
        case "combat-promotions":
            return team.sport == .combat && team.kind == .tournament
        case "racing-teams":
            return team.sport == .racing && team.kind == .team
        case "racing-drivers":
            return team.sport == .racing && team.kind == .driver
        case "racing-series":
            return team.sport == .racing && team.kind == .tournament
        default:
            return false
        }
    }

    private static func matchesSearch(_ team: FavoriteTeam, query q: String) -> Bool {
        if team.name.lowercased().contains(q) { return true }
        if team.league.lowercased().contains(q) { return true }
        if team.region.lowercased().contains(q) { return true }
        if team.kind.rawValue.lowercased().contains(q) { return true }
        if team.kind.displayTitle.lowercased().contains(q) { return true }
        if team.shortCode?.lowercased().contains(q) == true { return true }
        if team.searchAliases.contains(where: { $0.lowercased().contains(q) }) { return true }
        if team.sport.rawValue.lowercased().contains(q) { return true }
        if team.sport.chipTitle.lowercased().contains(q) { return true }
        return categorySearchTerms(for: team).contains { $0.lowercased().contains(q) }
    }

    private static func categorySearchTerms(for team: FavoriteTeam) -> [String] {
        var terms: [String] = []
        for sport in selectorSports where sportMatches(team, selectedSport: sport) {
            for category in categoryDefinitions(for: sport) where categoryMatches(team, categoryID: category.id) {
                terms.append(category.title)
            }
        }
        return terms
    }

    // MARK: Soccer (54)

    private static let soccer: [FavoriteTeam] = [
        team("soccer-juventus", "Juventus", .soccer, "Serie A", "soccerball", 0.18, 0.18, 0.18, region: "Europe", kind: .team, shortCode: "JUV", aliases: ["Juventus FC"]),
        team("soccer-milan", "AC Milan", .soccer, "Serie A", "soccerball", 0.78, 0.12, 0.14, region: "Europe", kind: .team, shortCode: "ACM", aliases: ["Milan"]),
        team("soccer-inter", "Inter Milan", .soccer, "Serie A", "soccerball", 0.12, 0.42, 0.72, region: "Europe", kind: .team, shortCode: "INT", aliases: ["Inter"]),
        team("soccer-napoli", "Napoli", .soccer, "Serie A", "soccerball", 0.12, 0.42, 0.82, region: "Europe", kind: .team, shortCode: "NAP"),
        team("soccer-roma", "Roma", .soccer, "Serie A", "soccerball", 0.72, 0.18, 0.18, region: "Europe", kind: .team, shortCode: "ROM"),
        team("soccer-real-madrid", "Real Madrid", .soccer, "La Liga", "soccerball", 0.95, 0.82, 0.22, region: "Europe", kind: .team, shortCode: "RMA", aliases: ["Real Madrid CF"]),
        team("soccer-barcelona", "Barcelona", .soccer, "La Liga", "soccerball", 0.72, 0.12, 0.28, region: "Europe", kind: .team, shortCode: "BAR", aliases: ["FC Barcelona", "Barça"]),
        team("soccer-atletico-madrid", "Atlético Madrid", .soccer, "La Liga", "soccerball", 0.78, 0.12, 0.18, region: "Europe", kind: .team, shortCode: "ATM", aliases: ["Atletico Madrid"]),
        team("soccer-man-utd", "Manchester United", .soccer, "Premier League", "soccerball", 0.78, 0.12, 0.16, region: "Europe", kind: .team, shortCode: "MUN", aliases: ["Man United", "Man Utd"]),
        team("soccer-man-city", "Manchester City", .soccer, "Premier League", "soccerball", 0.32, 0.66, 0.88, region: "Europe", kind: .team, shortCode: "MCI", aliases: ["Man City"]),
        team("soccer-liverpool", "Liverpool", .soccer, "Premier League", "soccerball", 0.78, 0.14, 0.18, region: "Europe", kind: .team, shortCode: "LIV"),
        team("soccer-chelsea", "Chelsea", .soccer, "Premier League", "soccerball", 0.12, 0.35, 0.72, region: "Europe", kind: .team, shortCode: "CHE"),
        team("soccer-arsenal", "Arsenal", .soccer, "Premier League", "soccerball", 0.78, 0.12, 0.14, region: "Europe", kind: .team, shortCode: "ARS", aliases: ["Arsenal FC"]),
        team("soccer-tottenham", "Tottenham", .soccer, "Premier League", "soccerball", 0.12, 0.22, 0.52, region: "Europe", kind: .team, shortCode: "TOT", aliases: ["Spurs"]),
        team("soccer-bayern", "Bayern Munich", .soccer, "Bundesliga", "soccerball", 0.78, 0.12, 0.22, region: "Europe", kind: .team, shortCode: "BAY", aliases: ["Bayern München", "FC Bayern Munich", "FC Bayern"]),
        team("soccer-dortmund", "Borussia Dortmund", .soccer, "Bundesliga", "soccerball", 0.92, 0.72, 0.12, region: "Europe", kind: .team, shortCode: "BVB", aliases: ["Dortmund"]),
        team("soccer-psg", "Paris Saint-Germain", .soccer, "Ligue 1", "soccerball", 0.12, 0.22, 0.48, region: "Europe", kind: .team, shortCode: "PSG", aliases: ["PSG", "Paris SG", "Paris Saint Germain", "Paris Saint-Germain FC"]),
        team("soccer-marseille", "Marseille", .soccer, "Ligue 1", "soccerball", 0.12, 0.52, 0.76, region: "Europe", kind: .team, shortCode: "OM"),
        team("soccer-benfica", "Benfica", .soccer, "Primeira Liga", "soccerball", 0.78, 0.12, 0.16, region: "Europe", kind: .team, shortCode: "BEN"),
        team("soccer-porto", "Porto", .soccer, "Primeira Liga", "soccerball", 0.12, 0.32, 0.72, region: "Europe", kind: .team, shortCode: "POR"),
        team("soccer-ajax", "Ajax", .soccer, "Eredivisie", "soccerball", 0.78, 0.12, 0.16, region: "Europe", kind: .team, shortCode: "AJX"),
        team("soccer-lafc", "LAFC", .soccer, "MLS", "soccerball", 0.16, 0.16, 0.16, region: "North America", kind: .team, shortCode: "LAFC", aliases: ["Los Angeles FC"]),
        team("soccer-galaxy", "LA Galaxy", .soccer, "MLS", "soccerball", 0.12, 0.32, 0.62, region: "North America", kind: .team, shortCode: "LAG"),
        team("soccer-inter-miami", "Inter Miami", .soccer, "MLS", "soccerball", 0.92, 0.42, 0.62, region: "North America", kind: .team, shortCode: "MIA", aliases: ["Inter Miami CF", "Club Internacional de Fútbol Miami"]),
        team("soccer-nycfc", "New York City FC", .soccer, "MLS", "soccerball", 0.12, 0.48, 0.82, region: "North America", kind: .team, shortCode: "NYC", aliases: ["NYCFC"]),
        team("soccer-atlanta", "Atlanta United", .soccer, "MLS", "soccerball", 0.78, 0.18, 0.22, region: "North America", kind: .team, shortCode: "ATL"),
        team("soccer-seattle", "Seattle Sounders", .soccer, "MLS", "soccerball", 0.12, 0.52, 0.28, region: "North America", kind: .team, shortCode: "SEA"),
        team("soccer-toronto", "Toronto FC", .soccer, "MLS", "soccerball", 0.78, 0.12, 0.16, region: "North America", kind: .team, shortCode: "TOR"),
        team("soccer-cf-montreal", "CF Montréal", .soccer, "MLS", "soccerball", 0.12, 0.22, 0.52, region: "North America", kind: .team, shortCode: "MTL", aliases: ["CF Montreal", "Montreal"]),
        team("soccer-club-america", "Club América", .soccer, "Liga MX", "soccerball", 0.92, 0.78, 0.16, region: "North America", kind: .team, shortCode: "AME", aliases: ["Club America", "America"]),
        team("soccer-chivas", "Chivas", .soccer, "Liga MX", "soccerball", 0.78, 0.12, 0.18, region: "North America", kind: .team, shortCode: "GDL", aliases: ["Guadalajara"]),
        team("soccer-tigres", "Tigres", .soccer, "Liga MX", "soccerball", 0.92, 0.72, 0.12, region: "North America", kind: .team, shortCode: "TIG"),
        team("soccer-monterrey", "Monterrey", .soccer, "Liga MX", "soccerball", 0.12, 0.32, 0.62, region: "North America", kind: .team, shortCode: "MTY"),
        team("soccer-pumas", "Pumas", .soccer, "Liga MX", "soccerball", 0.12, 0.22, 0.52, region: "North America", kind: .team, shortCode: "PUM"),
        team("soccer-france", "France", .soccer, "National Team", "soccerball", 0.12, 0.28, 0.68, region: "National Teams", kind: .nationalTeam, shortCode: "FRA", aliases: ["France National Team", "French National Team"]),
        team("soccer-usa", "United States", .soccer, "National Team", "soccerball", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "USA", aliases: ["USA", "USMNT", "USWNT", "United States of America", "United States National Team"]),
        team("soccer-mexico", "Mexico", .soccer, "National Team", "soccerball", 0.12, 0.52, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "MEX", aliases: ["Mexico National Team", "Mexican National Team"]),
        team("soccer-canada", "Canada", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.16, region: "National Teams", kind: .nationalTeam, shortCode: "CAN"),
        team("soccer-argentina", "Argentina", .soccer, "National Team", "soccerball", 0.32, 0.64, 0.88, region: "National Teams", kind: .nationalTeam, shortCode: "ARG"),
        team("soccer-brazil", "Brazil", .soccer, "National Team", "soccerball", 0.12, 0.52, 0.28, region: "National Teams", kind: .nationalTeam, shortCode: "BRA"),
        team("soccer-england", "England", .soccer, "National Team", "soccerball", 0.72, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "ENG"),
        team("soccer-spain", "Spain", .soccer, "National Team", "soccerball", 0.78, 0.18, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "ESP"),
        team("soccer-germany", "Germany", .soccer, "National Team", "soccerball", 0.18, 0.18, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "GER", aliases: ["Deutschland"]),
        team("soccer-italy", "Italy", .soccer, "National Team", "soccerball", 0.12, 0.32, 0.72, region: "National Teams", kind: .nationalTeam, shortCode: "ITA"),
        team("soccer-portugal", "Portugal", .soccer, "National Team", "soccerball", 0.72, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "POR"),
        team("soccer-netherlands", "Netherlands", .soccer, "National Team", "soccerball", 0.92, 0.42, 0.12, region: "National Teams", kind: .nationalTeam, shortCode: "NED", aliases: ["Holland"]),
        team("soccer-japan", "Japan", .soccer, "National Team", "soccerball", 0.78, 0.12, 0.16, region: "National Teams", kind: .nationalTeam, shortCode: "JPN"),
        team("soccer-south-korea", "South Korea", .soccer, "National Team", "soccerball", 0.12, 0.28, 0.68, region: "National Teams", kind: .nationalTeam, shortCode: "KOR", aliases: ["Korea"]),
        team("soccer-australia", "Australia", .soccer, "National Team", "soccerball", 0.12, 0.42, 0.22, region: "National Teams", kind: .nationalTeam, shortCode: "AUS"),
        team("soccer-morocco", "Morocco", .soccer, "National Team", "soccerball", 0.72, 0.12, 0.18, region: "National Teams", kind: .nationalTeam, shortCode: "MAR")
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

    // MARK: Golf (players and tournaments; text-only identities)

    private static let golf: [FavoriteTeam] = [
        team("golf-scottie-scheffler", "Scottie Scheffler", .golf, "Golf", "figure.golf", 0.18, 0.62, 0.32, region: "Favorite Players", kind: .player, shortCode: "SS", aliases: ["Scheffler"]),
        team("golf-rory-mcilroy", "Rory McIlroy", .golf, "Golf", "figure.golf", 0.12, 0.42, 0.72, region: "Favorite Players", kind: .player, shortCode: "RM", aliases: ["McIlroy"]),
        team("golf-tiger-woods", "Tiger Woods", .golf, "Golf", "figure.golf", 0.18, 0.18, 0.18, region: "Favorite Players", kind: .player, shortCode: "TW", aliases: ["Tiger"]),
        team("golf-nelly-korda", "Nelly Korda", .golf, "Golf", "figure.golf", 0.78, 0.32, 0.52, region: "Favorite Players", kind: .player, shortCode: "NK", aliases: ["Korda"]),
        team("golf-lydia-ko", "Lydia Ko", .golf, "Golf", "figure.golf", 0.42, 0.18, 0.62, region: "Favorite Players", kind: .player, shortCode: "LK", aliases: ["Ko"]),
        team("golf-masters", "The Masters", .golf, "Golf Major", "figure.golf", 0.12, 0.48, 0.28, region: "Tournaments", kind: .tournament, shortCode: "MAS", aliases: ["Masters"]),
        team("golf-us-open", "U.S. Open Golf", .golf, "Golf Major", "figure.golf", 0.12, 0.32, 0.72, region: "Tournaments", kind: .tournament, shortCode: "USO", aliases: ["US Open Golf"]),
        team("golf-the-open", "The Open", .golf, "Golf Major", "figure.golf", 0.22, 0.42, 0.32, region: "Tournaments", kind: .tournament, shortCode: "OPEN", aliases: ["British Open", "Open Championship"]),
        team("golf-ryder-cup", "Ryder Cup", .golf, "Golf Tournament", "figure.golf", 0.78, 0.18, 0.22, region: "Tournaments", kind: .tournament, shortCode: "RC")
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

    // MARK: Tennis (players and tournaments; text-only identities)

    private static let tennis: [FavoriteTeam] = [
        team("tennis-carlos-alcaraz", "Carlos Alcaraz", .tennis, "Tennis", "tennisball.fill", 0.62, 0.82, 0.18, region: "Favorite Players", kind: .player, shortCode: "CA", aliases: ["Alcaraz"]),
        team("tennis-novak-djokovic", "Novak Djokovic", .tennis, "Tennis", "tennisball.fill", 0.22, 0.42, 0.72, region: "Favorite Players", kind: .player, shortCode: "ND", aliases: ["Djokovic"]),
        team("tennis-jannik-sinner", "Jannik Sinner", .tennis, "Tennis", "tennisball.fill", 0.92, 0.42, 0.12, region: "Favorite Players", kind: .player, shortCode: "JS", aliases: ["Sinner"]),
        team("tennis-iga-swiatek", "Iga Swiatek", .tennis, "Tennis", "tennisball.fill", 0.78, 0.18, 0.22, region: "Favorite Players", kind: .player, shortCode: "IS", aliases: ["Swiatek"]),
        team("tennis-aryna-sabalenka", "Aryna Sabalenka", .tennis, "Tennis", "tennisball.fill", 0.52, 0.22, 0.72, region: "Favorite Players", kind: .player, shortCode: "AS", aliases: ["Sabalenka"]),
        team("tennis-coco-gauff", "Coco Gauff", .tennis, "Tennis", "tennisball.fill", 0.12, 0.52, 0.42, region: "Favorite Players", kind: .player, shortCode: "CG", aliases: ["Gauff"]),
        team("tennis-naomi-osaka", "Naomi Osaka", .tennis, "Tennis", "tennisball.fill", 0.78, 0.32, 0.52, region: "Favorite Players", kind: .player, shortCode: "NO", aliases: ["Osaka"]),
        team("tennis-rafael-nadal", "Rafael Nadal", .tennis, "Tennis", "tennisball.fill", 0.78, 0.32, 0.12, region: "Favorite Players", kind: .player, shortCode: "RN", aliases: ["Nadal"]),
        team("tennis-serena-williams", "Serena Williams", .tennis, "Tennis", "tennisball.fill", 0.42, 0.18, 0.62, region: "Favorite Players", kind: .player, shortCode: "SW", aliases: ["Serena"]),
        team("tennis-australian-open", "Australian Open", .tennis, "Tennis Major", "tennisball.fill", 0.12, 0.48, 0.82, region: "Tournaments", kind: .tournament, shortCode: "AO"),
        team("tennis-roland-garros", "Roland Garros", .tennis, "Tennis Major", "tennisball.fill", 0.82, 0.36, 0.14, region: "Tournaments", kind: .tournament, shortCode: "RG", aliases: ["French Open"]),
        team("tennis-wimbledon", "Wimbledon", .tennis, "Tennis Major", "tennisball.fill", 0.24, 0.52, 0.28, region: "Tournaments", kind: .tournament, shortCode: "WIM"),
        team("tennis-us-open", "US Open Tennis", .tennis, "Tennis Major", "tennisball.fill", 0.12, 0.28, 0.68, region: "Tournaments", kind: .tournament, shortCode: "USO", aliases: ["U.S. Open"])
    ]

    // MARK: Combat Sports (fighters; text-only identities)

    private static let combat: [FavoriteTeam] = [
        team("fighter-jon-jones", "Jon Jones", .combat, "Combat Sports", "figure.boxing", 0.28, 0.28, 0.32, region: "Fighters", kind: .fighter, shortCode: "JJ"),
        team("fighter-amanda-nunes", "Amanda Nunes", .combat, "Combat Sports", "figure.boxing", 0.78, 0.42, 0.18, region: "Fighters", kind: .fighter, shortCode: "AN"),
        team("fighter-islam-makhachev", "Islam Makhachev", .combat, "Combat Sports", "figure.boxing", 0.12, 0.42, 0.32, region: "Fighters", kind: .fighter, shortCode: "IM"),
        team("fighter-alex-pereira", "Alex Pereira", .combat, "Combat Sports", "figure.boxing", 0.72, 0.18, 0.18, region: "Fighters", kind: .fighter, shortCode: "AP"),
        team("fighter-katie-taylor", "Katie Taylor", .combat, "Combat Sports", "figure.boxing", 0.12, 0.48, 0.36, region: "Fighters", kind: .fighter, shortCode: "KT"),
        team("fighter-claressa-shields", "Claressa Shields", .combat, "Combat Sports", "figure.boxing", 0.42, 0.18, 0.62, region: "Fighters", kind: .fighter, shortCode: "CS")
    ]

    // MARK: Favorite Players / Drivers (text-only identities)

    private static let favoritePlayers: [FavoriteTeam] = [
        team("player-lionel-messi", "Lionel Messi", .soccer, "Soccer", "person.fill", 0.32, 0.64, 0.88, region: "Favorite Players", kind: .player, shortCode: "LM", aliases: ["Messi"]),
        team("player-cristiano-ronaldo", "Cristiano Ronaldo", .soccer, "Soccer", "person.fill", 0.72, 0.12, 0.18, region: "Favorite Players", kind: .player, shortCode: "CR", aliases: ["Ronaldo", "CR7"]),
        team("player-kylian-mbappe", "Kylian Mbappe", .soccer, "Soccer", "person.fill", 0.12, 0.28, 0.68, region: "Favorite Players", kind: .player, shortCode: "KM", aliases: ["Mbappe"]),
        team("player-lebron-james", "LeBron James", .basketball, "Basketball", "person.fill", 0.42, 0.18, 0.62, region: "Favorite Players", kind: .player, shortCode: "LJ", aliases: ["LeBron"]),
        team("player-stephen-curry", "Stephen Curry", .basketball, "Basketball", "person.fill", 0.22, 0.42, 0.72, region: "Favorite Players", kind: .player, shortCode: "SC", aliases: ["Steph Curry", "Curry"]),
        team("player-caitlin-clark", "Caitlin Clark", .basketball, "Basketball", "person.fill", 0.78, 0.32, 0.12, region: "Favorite Players", kind: .player, shortCode: "CC", aliases: ["Clark"]),
        team("player-patrick-mahomes", "Patrick Mahomes", .football, "Football", "person.fill", 0.78, 0.18, 0.22, region: "Favorite Players", kind: .player, shortCode: "PM", aliases: ["Mahomes"]),
        team("player-shohei-ohtani", "Shohei Ohtani", .baseball, "Baseball", "person.fill", 0.12, 0.32, 0.62, region: "Favorite Players", kind: .player, shortCode: "SO", aliases: ["Ohtani"]),
        team("driver-max-verstappen", "Max Verstappen", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.12, 0.22, 0.48, region: "Drivers", kind: .driver, shortCode: "MV", aliases: ["Verstappen"]),
        team("driver-lewis-hamilton", "Lewis Hamilton", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.62, 0.22, 0.72, region: "Drivers", kind: .driver, shortCode: "LH", aliases: ["Hamilton"]),
        team("driver-charles-leclerc", "Charles Leclerc", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.12, 0.16, region: "Drivers", kind: .driver, shortCode: "CL", aliases: ["Leclerc"]),
        team("driver-lando-norris", "Lando Norris", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.92, 0.42, 0.12, region: "Drivers", kind: .driver, shortCode: "LN", aliases: ["Norris"])
    ]

    // MARK: Leagues / Tournaments (text-only identities)

    private static let favoriteTournaments: [FavoriteTeam] = [
        team("league-nba", "NBA", .basketball, "Basketball League", "basketball.fill", 0.22, 0.42, 0.72, region: "Leagues & Tournaments", kind: .tournament, shortCode: "NBA", aliases: ["National Basketball Association"]),
        team("league-nfl", "NFL", .football, "Football League", "football.fill", 0.12, 0.32, 0.62, region: "Leagues & Tournaments", kind: .tournament, shortCode: "NFL", aliases: ["National Football League"]),
        team("league-mlb", "MLB", .baseball, "Baseball League", "baseball.fill", 0.78, 0.12, 0.18, region: "Leagues & Tournaments", kind: .tournament, shortCode: "MLB", aliases: ["Major League Baseball"]),
        team("league-mls", "MLS", .soccer, "Soccer League", "soccerball", 0.12, 0.48, 0.82, region: "Leagues & Tournaments", kind: .tournament, shortCode: "MLS", aliases: ["Major League Soccer"]),
        team("league-premier-league", "Premier League", .soccer, "Soccer League", "soccerball", 0.42, 0.18, 0.62, region: "Leagues & Tournaments", kind: .tournament, shortCode: "PL"),
        team("tournament-world-cup", "FIFA World Cup", .soccer, "Soccer Tournament", "soccerball", 0.12, 0.52, 0.28, region: "Leagues & Tournaments", kind: .tournament, shortCode: "FWC", aliases: ["World Cup"]),
        team("tournament-champions-league", "Champions League", .soccer, "Soccer Tournament", "soccerball", 0.12, 0.22, 0.48, region: "Leagues & Tournaments", kind: .tournament, shortCode: "UCL", aliases: ["UEFA Champions League"]),
        team("league-formula-one", "Formula 1", .racing, "Open Wheel", "flag.checkered.2.crossed.fill", 0.78, 0.12, 0.16, region: "Leagues & Tournaments", kind: .tournament, shortCode: "F1", aliases: ["F1"]),
        team("tournament-march-madness", "March Madness", .ncaa, "College Basketball Tournament", "building.columns.fill", 0.12, 0.32, 0.72, region: "Leagues & Tournaments", kind: .tournament, shortCode: "MM"),
        team("tournament-college-football-playoff", "College Football Playoff", .ncaa, "College Football Tournament", "building.columns.fill", 0.78, 0.42, 0.18, region: "Leagues & Tournaments", kind: .tournament, shortCode: "CFP")
    ]

    private static func team(
        _ id: String,
        _ name: String,
        _ sport: FavoriteTeamSport,
        _ league: String,
        _ symbol: String,
        _ r: Double,
        _ g: Double,
        _ b: Double,
        region: String? = nil,
        kind: FavoriteTeamKind = .team,
        shortCode: String? = nil,
        aliases: [String] = []
    ) -> FavoriteTeam {
        FavoriteTeam(
            id: id,
            name: name,
            sport: sport,
            league: league,
            region: region ?? league,
            kind: kind,
            shortCode: shortCode,
            searchAliases: aliases,
            fallbackSymbol: symbol,
            badgeRed: r,
            badgeGreen: g,
            badgeBlue: b
        )
    }
}

// MARK: - Live tab team matching

enum FavoriteTeamLiveMatcher {
    private static let genericTokens: Set<String> = [
        "club",
        "city",
        "football",
        "basketball",
        "hockey",
        "racing",
        "sport",
        "sports",
        "college",
        "united",
        "real",
        "inter",
        "atletico",
        "athletic",
        "sporting",
        "national",
        "team"
    ]

    /// Normalized aliases for matching live feed home/away names (catalog entries only).
    static func matchAliases(for team: FavoriteTeam) -> [String] {
        var unique: [String] = []
        func add(_ raw: String) {
            let normalized = normalizedSearchText(raw)
            guard !normalized.isEmpty, !unique.contains(normalized) else { return }
            unique.append(normalized)
        }

        add(team.name)
        if let shortCode = team.shortCode {
            add(shortCode)
        }
        for alias in team.searchAliases {
            add(alias)
        }

        return unique.sorted { $0.count > $1.count }
    }

    static func matchesLiveMatch(_ team: FavoriteTeam, homeTeam: String, awayTeam: String) -> Bool {
        let participants = [homeTeam, awayTeam]
        return matchAliases(for: team).contains { alias in
            participants.contains { matchesAlias(alias, inParticipantName: $0) }
        }
    }

    static func matchesVenueEventTitle(_ team: FavoriteTeam, title: String) -> Bool {
        let normalizedTitle = normalizedSearchText(title)
        guard !normalizedTitle.isEmpty else { return false }
        return matchAliases(for: team).contains { alias in
            matchesAlias(alias, inParticipantName: normalizedTitle)
        }
    }

    private static func matchesAlias(_ alias: String, inParticipantName participant: String) -> Bool {
        let normalizedParticipant = normalizedSearchText(participant)
        guard !normalizedParticipant.isEmpty else { return false }

        if alias.count <= 2 { return false }
        if genericTokens.contains(alias) { return false }

        if normalizedParticipant == alias {
            return true
        }

        if alias.contains(" ") {
            return containsPhrase(alias, in: normalizedParticipant)
        }

        if alias.count <= 4 {
            return normalizedParticipant
                .split(separator: " ")
                .map(String.init)
                .contains(alias)
        }

        return containsPhrase(alias, in: normalizedParticipant)
    }

    private static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        if text == phrase { return true }
        if text.hasPrefix("\(phrase) ") { return true }
        if text.hasSuffix(" \(phrase)") { return true }
        return text.contains(" \(phrase) ")
    }

    private static func normalizedSearchText(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Local persistence (AppStorage)

enum FavoriteTeamsStore {
    static let appStorageKey = "gameon.profile.favoriteTeamIDs"
    static let primaryTeamIDAppStorageKey = "gameon.profile.primaryFavoriteTeamID"

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

    static func normalizedPrimaryTeamID(_ raw: String?, within ids: [String]) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, ids.contains(trimmed), FavoriteTeamCatalog.team(id: trimmed) != nil else {
            return ids.first { FavoriteTeamCatalog.team(id: $0) != nil }
        }
        return trimmed
    }

    static func writePrimaryTeamIDToAppStorage(_ teamID: String?) {
        let trimmed = teamID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: primaryTeamIDAppStorageKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: primaryTeamIDAppStorageKey)
        }
    }
}
