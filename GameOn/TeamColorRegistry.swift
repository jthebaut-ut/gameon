import SwiftUI

struct CanonicalTeamColor: Hashable {
    let id: String
    let displayName: String
    let primaryColorHex: String
    let secondaryColorHex: String
    let accentColorHex: String?
    let darkModeAdjustedColorHex: String?
    let shortName: String?
    let aliases: [String]
}

enum TeamColorRegistry {
    static func color(for rawName: String) -> CanonicalTeamColor? {
        let key = normalize(rawName)
        guard !key.isEmpty else { return nil }
        return colorsByAlias[key]
    }

    static func color(id: String) -> CanonicalTeamColor? {
        colorsByID[normalize(id)]
    }

    static func colorFromHex(_ hex: String) -> Color {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6,
              let value = Int(cleaned, radix: 16) else {
            return CountryTheme.fallback.accent
        }
        let red = Double((value >> 16) & 0xff) / 255.0
        let green = Double((value >> 8) & 0xff) / 255.0
        let blue = Double(value & 0xff) / 255.0
        return Color(red: red, green: green, blue: blue)
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private static let colorsByID: [String: CanonicalTeamColor] = {
        Dictionary(uniqueKeysWithValues: entries.map { (normalize($0.id), $0) })
    }()

    private static let colorsByAlias: [String: CanonicalTeamColor] = {
        var result: [String: CanonicalTeamColor] = [:]
        for entry in entries {
            let names = [entry.id, entry.displayName, entry.shortName].compactMap { $0 } + entry.aliases
            for name in names {
                result[normalize(name)] = entry
            }
        }
        return result
    }()

    private static func e(
        _ id: String,
        _ displayName: String,
        _ primary: String,
        _ secondary: String,
        accent: String? = nil,
        dark: String? = nil,
        shortName: String? = nil,
        aliases: [String] = []
    ) -> CanonicalTeamColor {
        CanonicalTeamColor(
            id: id,
            displayName: displayName,
            primaryColorHex: primary,
            secondaryColorHex: secondary,
            accentColorHex: accent,
            darkModeAdjustedColorHex: dark,
            shortName: shortName,
            aliases: aliases
        )
    }

    private static let entries: [CanonicalTeamColor] = [
        // National teams
        e("country-argentina-soccer", "Argentina", "#43A1D5", "#FFFFFF", accent: "#D5B048", shortName: "ARG", aliases: ["Argentina National Team", "Argentina Football", "Argentina Soccer"]),
        e("country-brazil-soccer", "Brazil", "#FFDF00", "#009739", accent: "#002776", shortName: "BRA", aliases: ["Brazil National Team", "Brasil"]),
        e("country-canada-soccer", "Canada", "#C5281C", "#FFFFFF", accent: "#000000", shortName: "CAN", aliases: ["Canada National Team", "Canada Soccer"]),
        e("country-mexico-soccer", "Mexico", "#00933B", "#F5313E", accent: "#FFFFFF", shortName: "MEX", aliases: ["Mexico National Team", "El Tri"]),
        e("country-usa-soccer", "United States", "#3C3B6E", "#B22234", accent: "#FFFFFF", shortName: "USA", aliases: ["USA", "USMNT", "USWNT", "United States National Team", "United States of America"]),
        e("country-france-soccer", "France", "#002395", "#ED2939", accent: "#FFFFFF", shortName: "FRA", aliases: ["France National Team", "French National Team"]),
        e("country-england-soccer", "England", "#FFFFFF", "#CF142B", accent: "#00247D", shortName: "ENG", aliases: ["England National Team"]),
        e("country-spain-soccer", "Spain", "#AA151B", "#F1BF00", accent: "#0039F0", shortName: "ESP", aliases: ["Spain National Team"]),
        e("country-germany-soccer", "Germany", "#000000", "#DD0000", accent: "#FFCE00", shortName: "GER", aliases: ["Germany National Team", "Deutschland"]),
        e("country-italy-soccer", "Italy", "#0066B3", "#FFFFFF", accent: "#008C45", shortName: "ITA", aliases: ["Italy National Team", "Azzurri"]),
        e("country-portugal-soccer", "Portugal", "#006600", "#FF0000", accent: "#FFFF00", shortName: "POR", aliases: ["Portugal National Team"]),
        e("country-netherlands-soccer", "Netherlands", "#FF4F00", "#21468B", accent: "#FFFFFF", shortName: "NED", aliases: ["Netherlands National Team", "Holland"]),
        e("country-japan-soccer", "Japan", "#BC002D", "#FFFFFF", shortName: "JPN", aliases: ["Japan National Team"]),
        e("country-south-korea-soccer", "South Korea", "#CD2E3A", "#0047A0", accent: "#FFFFFF", shortName: "KOR", aliases: ["Korea", "South Korea National Team"]),
        e("country-australia-soccer", "Australia", "#FFCD00", "#00843D", accent: "#00205B", shortName: "AUS", aliases: ["Australia National Team", "Socceroos"]),
        e("country-morocco-soccer", "Morocco", "#C1272D", "#006233", shortName: "MAR", aliases: ["Morocco National Team"]),

        // NBA
        e("nba-lakers", "Los Angeles Lakers", "#552583", "#FDB927", accent: "#000000", shortName: "Lakers", aliases: ["LA Lakers", "LAL"]),
        e("nba-celtics", "Boston Celtics", "#007A33", "#FFFFFF", accent: "#BA9653", shortName: "Celtics", aliases: ["BOS"]),
        e("nba-warriors", "Golden State Warriors", "#1D428A", "#FFC72C", shortName: "Warriors", aliases: ["GS Warriors", "GSW"]),
        e("nba-bulls", "Chicago Bulls", "#CE1141", "#000000", shortName: "Bulls", aliases: ["CHI Bulls"]),
        e("nba-heat", "Miami Heat", "#98002E", "#F9A01B", accent: "#000000", shortName: "Heat"),
        e("nba-knicks", "New York Knicks", "#006BB6", "#F58426", shortName: "Knicks", aliases: ["NY Knicks"]),
        e("nba-mavericks", "Dallas Mavericks", "#00538C", "#B8C4CA", accent: "#002B5E", shortName: "Mavericks", aliases: ["Mavs"]),
        e("nba-nuggets", "Denver Nuggets", "#0E2240", "#FEC524", accent: "#8B2131", shortName: "Nuggets"),
        e("nba-suns", "Phoenix Suns", "#1D1160", "#E56020", shortName: "Suns"),
        e("nba-bucks", "Milwaukee Bucks", "#00471B", "#EEE1C6", accent: "#0077C0", shortName: "Bucks"),
        e("nba-nets", "Brooklyn Nets", "#000000", "#FFFFFF", shortName: "Nets"),
        e("nba-spurs", "San Antonio Spurs", "#000000", "#C4CED4", shortName: "Spurs"),
        e("nba-raptors", "Toronto Raptors", "#CE1141", "#000000", accent: "#A1A1A4", shortName: "Raptors"),
        e("nba-76ers", "Philadelphia 76ers", "#006BB6", "#ED174C", shortName: "76ers", aliases: ["Sixers", "Philadelphia 76ers"]),

        // NFL
        e("nfl-chiefs", "Kansas City Chiefs", "#E31837", "#FFB81C", shortName: "Chiefs", aliases: ["KC Chiefs"]),
        e("nfl-cowboys", "Dallas Cowboys", "#041E42", "#869397", shortName: "Cowboys"),
        e("nfl-packers", "Green Bay Packers", "#203731", "#FFB612", shortName: "Packers"),
        e("nfl-49ers", "San Francisco 49ers", "#AA0000", "#B3995D", shortName: "49ers", aliases: ["SF 49ers", "Niners"]),
        e("nfl-steelers", "Pittsburgh Steelers", "#FFB612", "#000000", shortName: "Steelers"),
        e("nfl-eagles", "Philadelphia Eagles", "#004C54", "#A5ACAF", shortName: "Eagles"),
        e("nfl-giants", "New York Giants", "#0B2265", "#A71930", shortName: "Giants", aliases: ["NY Giants"]),
        e("nfl-dolphins", "Miami Dolphins", "#008E97", "#FC4C02", shortName: "Dolphins"),
        e("nfl-raiders", "Las Vegas Raiders", "#000000", "#A5ACAF", shortName: "Raiders", aliases: ["LV Raiders", "Oakland Raiders"]),
        e("nfl-bills", "Buffalo Bills", "#00338D", "#C60C30", shortName: "Bills"),
        e("nfl-ravens", "Baltimore Ravens", "#241773", "#9E7C0C", accent: "#000000", shortName: "Ravens"),
        e("nfl-lions", "Detroit Lions", "#0076B6", "#B0B7BC", shortName: "Lions"),
        e("nfl-jets", "New York Jets", "#125740", "#FFFFFF", shortName: "Jets", aliases: ["NY Jets"]),

        // MLB
        e("mlb-dodgers", "Los Angeles Dodgers", "#005A9C", "#FFFFFF", accent: "#EF3E42", shortName: "Dodgers", aliases: ["LA Dodgers"]),
        e("mlb-yankees", "New York Yankees", "#0C2340", "#FFFFFF", accent: "#C4CED3", shortName: "Yankees", aliases: ["NY Yankees"]),
        e("mlb-red-sox", "Boston Red Sox", "#BD3039", "#0C2340", shortName: "Red Sox"),
        e("mlb-giants", "San Francisco Giants", "#FD5A1E", "#000000", shortName: "Giants", aliases: ["SF Giants"]),
        e("mlb-cubs", "Chicago Cubs", "#0E3386", "#CC3433", shortName: "Cubs"),
        e("mlb-cardinals", "St. Louis Cardinals", "#C41E3A", "#0C2340", shortName: "Cardinals", aliases: ["Saint Louis Cardinals"]),
        e("mlb-braves", "Atlanta Braves", "#13274F", "#CE1141", shortName: "Braves"),
        e("mlb-astros", "Houston Astros", "#002D62", "#EB6E1F", shortName: "Astros"),
        e("mlb-mets", "New York Mets", "#002D72", "#FF5910", shortName: "Mets", aliases: ["NY Mets"]),
        e("mlb-mariners", "Seattle Mariners", "#0C2C56", "#005C5C", shortName: "Mariners"),
        e("mlb-phillies", "Philadelphia Phillies", "#E81828", "#002D72", shortName: "Phillies"),
        e("mlb-padres", "San Diego Padres", "#2F241D", "#FFC425", shortName: "Padres"),

        // NHL
        e("nhl-golden-knights", "Vegas Golden Knights", "#B4975A", "#333F42", accent: "#000000", shortName: "Golden Knights", aliases: ["VGK", "Vegas Hockey"]),
        e("nhl-avalanche", "Colorado Avalanche", "#6F263D", "#236192", shortName: "Avalanche", aliases: ["Avs", "Colorado Hockey"]),
        e("nhl-maple-leafs", "Toronto Maple Leafs", "#00205B", "#FFFFFF", shortName: "Maple Leafs", aliases: ["Leafs", "Toronto Hockey"]),
        e("nhl-bruins", "Boston Bruins", "#000000", "#FFB81C", shortName: "Bruins", aliases: ["Boston Hockey"]),
        e("nhl-rangers", "New York Rangers", "#0038A8", "#CE1126", shortName: "Rangers", aliases: ["NY Rangers", "New York Hockey"]),
        e("nhl-canadiens", "Montreal Canadiens", "#AF1E2D", "#192168", shortName: "Canadiens", aliases: ["Habs", "Montreal Hockey"]),
        e("nhl-blackhawks", "Chicago Blackhawks", "#CF0A2C", "#000000", shortName: "Blackhawks", aliases: ["Chicago Hockey"]),
        e("nhl-red-wings", "Detroit Red Wings", "#CE1126", "#FFFFFF", shortName: "Red Wings", aliases: ["Detroit Hockey"]),
        e("nhl-oilers", "Edmonton Oilers", "#041E42", "#FF4C00", shortName: "Oilers", aliases: ["Edmonton Hockey"]),
        e("nhl-kraken", "Seattle Kraken", "#001628", "#99D9D9", accent: "#E9072B", shortName: "Kraken", aliases: ["Seattle Hockey"]),
        e("nhl-utah", "Utah Hockey", "#71AFE5", "#010101", accent: "#FFFFFF", shortName: "Utah", aliases: ["Utah Mammoth", "Utah Hockey Club"]),

        // Soccer clubs: Europe
        e("soccer-real-madrid", "Real Madrid", "#FFFFFF", "#FEBE10", accent: "#00529F", shortName: "Real Madrid", aliases: ["Real Madrid CF"]),
        e("soccer-barcelona", "Barcelona", "#004D98", "#A50044", accent: "#EDBB00", shortName: "Barcelona", aliases: ["FC Barcelona", "Barca", "Barça"]),
        e("soccer-psg", "Paris Saint-Germain", "#004170", "#DA291C", accent: "#CEAB5D", shortName: "PSG", aliases: ["PSG", "Paris Saint Germain", "Paris SG"]),
        e("soccer-arsenal", "Arsenal", "#EF0107", "#FFFFFF", accent: "#9C824A", shortName: "Arsenal", aliases: ["Arsenal FC"]),
        e("soccer-chelsea", "Chelsea", "#034694", "#FFFFFF", accent: "#DBA111", shortName: "Chelsea"),
        e("soccer-liverpool", "Liverpool", "#C8102E", "#00B2A9", accent: "#F6EB61", shortName: "Liverpool"),
        e("soccer-manchester-city", "Manchester City", "#6CABDD", "#FFFFFF", accent: "#1C2C5B", shortName: "Man City", aliases: ["Man City"]),
        e("soccer-manchester-united", "Manchester United", "#DA291C", "#000000", accent: "#FBE122", shortName: "Man United", aliases: ["Man Utd", "Manchester Utd"]),
        e("soccer-tottenham", "Tottenham", "#132257", "#FFFFFF", shortName: "Tottenham", aliases: ["Spurs", "Tottenham Hotspur"]),
        e("soccer-bayern-munich", "Bayern Munich", "#DC052D", "#0066B2", shortName: "Bayern", aliases: ["FC Bayern", "Bayern München", "Bayern Munchen"]),
        e("soccer-dortmund", "Borussia Dortmund", "#FDE100", "#000000", shortName: "Dortmund", aliases: ["BVB"]),
        e("soccer-juventus", "Juventus", "#000000", "#FFFFFF", accent: "#F2C94C", shortName: "Juventus"),
        e("soccer-ac-milan", "AC Milan", "#FB090B", "#000000", shortName: "AC Milan", aliases: ["Milan"]),
        e("soccer-inter-milan", "Inter Milan", "#0068A8", "#000000", shortName: "Inter", aliases: ["Internazionale", "Inter"]),
        e("soccer-napoli", "Napoli", "#12A0D7", "#FFFFFF", shortName: "Napoli"),
        e("soccer-roma", "Roma", "#8E1F2F", "#F0BC42", shortName: "Roma", aliases: ["AS Roma"]),
        e("soccer-benfica", "Benfica", "#E83030", "#FFFFFF", accent: "#FFD100", shortName: "Benfica"),
        e("soccer-porto", "Porto", "#0055A4", "#FFFFFF", shortName: "Porto", aliases: ["FC Porto"]),
        e("soccer-ajax", "Ajax", "#D2122E", "#FFFFFF", shortName: "Ajax"),
        e("soccer-marseille", "Marseille", "#2FAEE0", "#FFFFFF", shortName: "Marseille", aliases: ["Olympique Marseille"]),

        // MLS / Liga MX
        e("soccer-lafc", "LAFC", "#000000", "#C39E6D", shortName: "LAFC", aliases: ["Los Angeles FC"]),
        e("soccer-la-galaxy", "LA Galaxy", "#00245D", "#FFD200", accent: "#FFFFFF", shortName: "Galaxy", aliases: ["LA Galaxy"]),
        e("soccer-inter-miami", "Inter Miami", "#F7B5CD", "#000000", shortName: "Inter Miami", aliases: ["Inter Miami CF"]),
        e("soccer-seattle-sounders", "Seattle Sounders", "#5D9731", "#005595", shortName: "Sounders", aliases: ["Seattle Sounders"]),
        e("soccer-atlanta-united", "Atlanta United", "#A19060", "#80000A", accent: "#000000", shortName: "Atlanta", aliases: ["Atlanta United"]),
        e("soccer-toronto-fc", "Toronto FC", "#B81137", "#455560", shortName: "Toronto FC"),
        e("soccer-cf-montreal", "CF Montreal", "#0055A4", "#000000", accent: "#FFFFFF", shortName: "CF Montreal", aliases: ["CF Montréal", "Montreal"]),
        e("soccer-real-salt-lake", "Real Salt Lake", "#B30838", "#013A81", accent: "#FDC82F", shortName: "RSL"),
        e("soccer-portland-timbers", "Portland Timbers", "#004812", "#D69A2D", shortName: "Timbers"),
        e("soccer-club-america", "Club America", "#F6EB14", "#001E62", accent: "#ED1C24", shortName: "América", aliases: ["Club América", "America"]),
        e("soccer-chivas", "Chivas", "#ED1C24", "#003B70", accent: "#FFFFFF", shortName: "Chivas", aliases: ["Guadalajara"]),
        e("soccer-tigres", "Tigres", "#F9D616", "#002D62", shortName: "Tigres", aliases: ["Tigres UANL"]),
        e("soccer-monterrey", "Monterrey", "#003B70", "#FFFFFF", shortName: "Monterrey"),
        e("soccer-pumas", "Pumas", "#0B2341", "#C69214", shortName: "Pumas", aliases: ["Pumas UNAM"]),
        e("soccer-cruz-azul", "Cruz Azul", "#005EB8", "#ED1C24", accent: "#FFFFFF", shortName: "Cruz Azul"),
        e("soccer-toluca", "Toluca", "#D71920", "#FFFFFF", shortName: "Toluca"),
        e("soccer-leon", "Leon", "#00843D", "#FFFFFF", shortName: "Leon", aliases: ["León"]),
        e("soccer-pachuca", "Pachuca", "#00539B", "#FFFFFF", shortName: "Pachuca")
    ]
}
