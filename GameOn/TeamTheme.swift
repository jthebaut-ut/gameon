import SwiftUI

struct TeamTheme {
    let rawName: String
    let displayName: String
    let flag: String?
    let colors: [Color]
    let accent: Color
    let textColors: [Color]
    let usesFallback: Bool
    let textColorHint: Color?
    let shortName: String?

    static let fallback = TeamTheme(
        rawName: "FanGeo",
        displayName: "FanGeo",
        flag: nil,
        colors: CountryTheme.fallback.colors,
        accent: CountryTheme.fallback.accent,
        textColors: CountryTheme.fallback.textColors,
        usesFallback: true,
        textColorHint: CountryTheme.fallback.textColors.first,
        shortName: nil
    )

    static func resolve(_ rawName: String?) -> TeamTheme {
        let cleanedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanedName.isEmpty else {
            return fallback
        }
        let displayName = CountryFlagHelper.displayName(for: cleanedName)

        if let teamTheme = TeamThemeProvider.theme(for: cleanedName) {
            return teamTheme
        }

        if let country = CountryTheme.resolve(cleanedName) {
            return TeamTheme(
                rawName: cleanedName,
                displayName: country.canonicalName,
                flag: country.flag ?? CountryFlagHelper.flag(for: cleanedName),
                colors: country.colors,
                accent: country.accent,
                textColors: country.textColors,
                usesFallback: false,
                textColorHint: country.textColors.first,
                shortName: nil
            )
        }

        let fallback = CountryTheme.fallback
        return TeamTheme(
            rawName: cleanedName,
            displayName: displayName,
            flag: CountryFlagHelper.flag(for: cleanedName),
            colors: fallback.colors,
            accent: fallback.accent,
            textColors: fallback.textColors,
            usesFallback: true,
            textColorHint: fallback.textColors.first,
            shortName: nil
        )
    }

    var uppercaseTitle: String {
        (shortName ?? displayName).uppercased()
    }

    var primaryColor: Color {
        colors.first ?? CountryTheme.fallback.accent
    }

    var secondaryColor: Color {
        colors.dropFirst().first ?? primaryColor
    }

    var accentColor: Color {
        accent
    }
}

private enum TeamThemeProvider {
    static func theme(for rawName: String) -> TeamTheme? {
        let key = CountryTheme.normalize(rawName)
        guard !key.isEmpty else { return nil }
        return themesByAlias[key]
    }

    private static let themesByAlias: [String: TeamTheme] = {
        var result: [String: TeamTheme] = [:]
        for entry in teamEntries {
            let theme = entry.theme
            result[CountryTheme.normalize(theme.displayName)] = theme
            if let shortName = theme.shortName {
                result[CountryTheme.normalize(shortName)] = theme
            }
            for alias in entry.aliases {
                result[CountryTheme.normalize(alias)] = theme
            }
        }
        return result
    }()

    private static let teamEntries: [(theme: TeamTheme, aliases: [String])] = [
        // NBA
        entry("Los Angeles Lakers", c(85, 37, 130), c(253, 185, 39), shortName: "Lakers", aliases: ["LA Lakers"]),
        entry("Boston Celtics", c(0, 122, 51), .white, shortName: "Celtics"),
        entry("Golden State Warriors", c(29, 66, 138), c(255, 199, 44), shortName: "Warriors", aliases: ["GS Warriors"]),
        entry("Chicago Bulls", c(206, 17, 65), .black, shortName: "Bulls"),
        entry("Miami Heat", .black, c(152, 0, 46), shortName: "Heat"),
        entry("New York Knicks", c(245, 132, 38), c(0, 107, 182), shortName: "Knicks", aliases: ["NY Knicks"]),
        entry("Dallas Mavericks", c(0, 83, 188), c(187, 196, 202), accent: c(0, 43, 92), shortName: "Mavericks", aliases: ["Mavs"]),
        entry("Phoenix Suns", c(29, 17, 96), c(229, 95, 32), shortName: "Suns"),
        entry("Denver Nuggets", c(13, 34, 64), c(255, 198, 39), shortName: "Nuggets"),
        entry("San Antonio Spurs", .black, c(196, 206, 211), shortName: "Spurs"),

        // NFL
        entry("Kansas City Chiefs", c(227, 24, 55), c(255, 184, 28), shortName: "Chiefs", aliases: ["KC Chiefs"]),
        entry("Dallas Cowboys", c(0, 34, 68), c(134, 147, 151), shortName: "Cowboys"),
        entry("Green Bay Packers", c(24, 48, 40), c(255, 184, 28), shortName: "Packers"),
        entry("San Francisco 49ers", c(170, 0, 0), c(173, 153, 93), shortName: "49ers", aliases: ["SF 49ers", "Niners"]),
        entry("Pittsburgh Steelers", .black, c(255, 182, 18), shortName: "Steelers"),
        entry("Philadelphia Eagles", c(0, 76, 84), c(165, 172, 175), shortName: "Eagles"),
        entry("New York Giants", c(1, 35, 82), c(163, 13, 45), shortName: "Giants", aliases: ["NY Giants"]),
        entry("Miami Dolphins", c(0, 142, 151), c(252, 76, 2), shortName: "Dolphins"),
        entry("Las Vegas Raiders", .black, c(165, 172, 175), shortName: "Raiders", aliases: ["LV Raiders", "Oakland Raiders"]),
        entry("Buffalo Bills", c(0, 51, 141), c(198, 12, 48), shortName: "Bills"),

        // MLB
        entry("Los Angeles Dodgers", c(0, 90, 156), .white, shortName: "Dodgers", aliases: ["LA Dodgers"]),
        entry("New York Yankees", c(12, 35, 64), .white, shortName: "Yankees", aliases: ["NY Yankees"]),
        entry("Boston Red Sox", c(189, 48, 57), c(12, 35, 64), shortName: "Red Sox"),
        entry("San Francisco Giants", c(253, 90, 30), .black, shortName: "Giants", aliases: ["SF Giants"]),
        entry("Chicago Cubs", c(14, 51, 134), c(204, 52, 51), shortName: "Cubs"),
        entry("St. Louis Cardinals", c(196, 30, 58), c(12, 35, 64), shortName: "Cardinals", aliases: ["Saint Louis Cardinals"]),
        entry("Atlanta Braves", c(19, 39, 79), c(206, 17, 65), shortName: "Braves"),
        entry("Houston Astros", c(0, 45, 98), c(235, 110, 31), shortName: "Astros"),
        entry("New York Mets", c(0, 45, 114), c(252, 89, 16), shortName: "Mets", aliases: ["NY Mets"]),
        entry("Seattle Mariners", c(12, 44, 86), c(0, 92, 92), shortName: "Mariners"),

        // NHL
        entry("Vegas Golden Knights", c(185, 151, 91), .black, shortName: "Golden Knights", aliases: ["VGK"]),
        entry("Colorado Avalanche", c(111, 38, 61), c(35, 97, 146), shortName: "Avalanche", aliases: ["Avs"]),
        entry("Toronto Maple Leafs", c(0, 32, 91), .white, shortName: "Maple Leafs", aliases: ["Leafs"]),
        entry("Boston Bruins", .black, c(252, 181, 20), shortName: "Bruins"),
        entry("New York Rangers", c(0, 56, 168), c(206, 17, 38), shortName: "Rangers", aliases: ["NY Rangers"]),
        entry("Montreal Canadiens", c(175, 30, 45), c(25, 33, 104), shortName: "Canadiens", aliases: ["Habs"]),
        entry("Chicago Blackhawks", c(207, 10, 44), .black, shortName: "Blackhawks"),
        entry("Detroit Red Wings", c(206, 17, 38), .white, shortName: "Red Wings"),
        entry("Edmonton Oilers", c(4, 30, 66), c(252, 76, 2), shortName: "Oilers"),
        entry("Seattle Kraken", c(0, 83, 99), c(153, 217, 217), shortName: "Kraken"),

        // Soccer clubs
        entry("Real Madrid", .white, c(190, 156, 92), accent: c(10, 35, 80), textColorHint: c(190, 156, 92), shortName: "Real Madrid"),
        entry("Barcelona", c(0, 77, 152), c(165, 0, 68), shortName: "Barcelona", aliases: ["FC Barcelona", "Barca", "Barça"]),
        entry("PSG", c(0, 35, 82), c(218, 41, 28), shortName: "PSG", aliases: ["Paris Saint-Germain", "Paris Saint Germain"]),
        entry("Arsenal", c(239, 1, 7), .white, shortName: "Arsenal"),
        entry("Chelsea", c(3, 70, 148), .white, shortName: "Chelsea"),
        entry("Liverpool", c(200, 16, 46), c(0, 178, 169), shortName: "Liverpool"),
        entry("Manchester City", c(108, 171, 221), .white, shortName: "Man City", aliases: ["Man City"]),
        entry("Manchester United", c(218, 41, 28), .black, shortName: "Man United", aliases: ["Man Utd", "Man United"]),
        entry("Bayern Munich", c(220, 5, 45), c(0, 82, 159), shortName: "Bayern", aliases: ["FC Bayern", "Bayern München", "Bayern Munchen"]),
        entry("Borussia Dortmund", c(253, 225, 0), .black, shortName: "Dortmund", aliases: ["BVB"]),
        entry("Juventus", .black, .white, shortName: "Juventus"),
        entry("AC Milan", c(251, 9, 48), .black, shortName: "AC Milan"),
        entry("Inter Milan", c(0, 75, 160), .black, shortName: "Inter", aliases: ["Internazionale", "Inter"]),
        entry("Ajax", c(214, 0, 28), .white, shortName: "Ajax"),
        entry("Benfica", c(228, 0, 43), .white, shortName: "Benfica"),
        entry("Porto", c(0, 82, 155), .white, shortName: "Porto", aliases: ["FC Porto"]),
        entry("Inter Miami", c(255, 183, 197), .black, shortName: "Inter Miami")
    ]

    private static func entry(
        _ displayName: String,
        _ primary: Color,
        _ secondary: Color,
        accent: Color? = nil,
        textColorHint: Color? = nil,
        shortName: String? = nil,
        aliases: [String] = []
    ) -> (theme: TeamTheme, aliases: [String]) {
        let resolvedAccent = accent ?? secondary
        let textColors = safeTextColors(primary: primary, secondary: secondary, accent: resolvedAccent, textColorHint: textColorHint)
        return (
            TeamTheme(
                rawName: displayName,
                displayName: displayName,
                flag: nil,
                colors: [primary, secondary, resolvedAccent],
                accent: resolvedAccent,
                textColors: textColors,
                usesFallback: false,
                textColorHint: textColorHint ?? textColors.first,
                shortName: shortName
            ),
            aliases
        )
    }

    private static func safeTextColors(primary: Color, secondary: Color, accent: Color, textColorHint: Color?) -> [Color] {
        [textColorHint ?? accent, secondary, primary, .white]
    }

    private static func c(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red / 255.0, green: green / 255.0, blue: blue / 255.0)
    }
}
