import SwiftUI

struct CountryTheme {
    let canonicalName: String
    let regionCode: String?
    let colors: [Color]
    let accent: Color
    let textColors: [Color]
    let aliases: [String]

    nonisolated var flag: String? {
        regionCode.map(Self.flagEmoji)
    }

    static let fallback = CountryTheme(
        canonicalName: "FanGeo",
        regionCode: nil,
        colors: [
            Color(red: 0.02, green: 0.05, blue: 0.14),
            Color(red: 0.18, green: 0.08, blue: 0.46),
            Color(red: 0.19, green: 0.42, blue: 0.88)
        ],
        accent: Color(red: 0.32, green: 0.68, blue: 1.0),
        textColors: [
            Color(red: 0.67, green: 0.85, blue: 1.0),
            Color(red: 0.87, green: 0.74, blue: 1.0)
        ],
        aliases: []
    )

    static func resolve(_ rawName: String?) -> CountryTheme? {
        guard let rawName else { return nil }
        let normalizedName = normalize(rawName)
        guard !normalizedName.isEmpty else { return nil }

        if let direct = themesByAlias[normalizedName] {
            return direct
        }

        return themes.first { theme in
            theme.aliases.contains { alias in
                let normalizedAlias = normalize(alias)
                return normalizedName == normalizedAlias || normalizedName.hasSuffix(" \(normalizedAlias)")
            }
        }
    }

    private static let themesByAlias: [String: CountryTheme] = {
        themes.reduce(into: [String: CountryTheme]()) { result, theme in
            result[normalize(theme.canonicalName)] = theme
            if let regionCode = theme.regionCode {
                result[normalize(regionCode)] = theme
            }
            for alias in theme.aliases {
                result[normalize(alias)] = theme
            }
        }
    }()

    private static let themes: [CountryTheme] = [
        CountryTheme(canonicalName: "France", regionCode: "FR", colors: [Color(red: 0.00, green: 0.13, blue: 0.47), .white, Color(red: 0.86, green: 0.05, blue: 0.18)], accent: Color(red: 0.33, green: 0.66, blue: 1.0), textColors: [Color(red: 0.37, green: 0.72, blue: 1.0), .white, Color(red: 1.0, green: 0.23, blue: 0.31)], aliases: ["les bleus"]),
        CountryTheme(canonicalName: "Belgium", regionCode: "BE", colors: [.black, Color(red: 1.0, green: 0.83, blue: 0.05), Color(red: 0.86, green: 0.03, blue: 0.12)], accent: Color(red: 1.0, green: 0.77, blue: 0.12), textColors: [Color(red: 1.0, green: 0.88, blue: 0.22), Color(red: 1.0, green: 0.20, blue: 0.25)], aliases: ["belgie", "belgique"]),
        CountryTheme(canonicalName: "USA", regionCode: "US", colors: [Color(red: 0.03, green: 0.10, blue: 0.30), Color(red: 0.72, green: 0.05, blue: 0.16), .white], accent: Color(red: 0.18, green: 0.48, blue: 0.95), textColors: [Color(red: 0.55, green: 0.76, blue: 1.0), .white, Color(red: 1.0, green: 0.25, blue: 0.34)], aliases: ["united states", "united states of america", "america", "us", "u.s.", "u.s.a."]),
        CountryTheme(canonicalName: "Mexico", regionCode: "MX", colors: [Color(red: 0.00, green: 0.43, blue: 0.22), .white, Color(red: 0.78, green: 0.05, blue: 0.17)], accent: Color(red: 0.20, green: 0.72, blue: 0.38), textColors: [Color(red: 0.33, green: 0.88, blue: 0.52), .white, Color(red: 1.0, green: 0.30, blue: 0.34)], aliases: ["mexico", "mexico national team"]),
        CountryTheme(canonicalName: "Brazil", regionCode: "BR", colors: [Color(red: 0.00, green: 0.48, blue: 0.24), Color(red: 1.0, green: 0.85, blue: 0.06), Color(red: 0.04, green: 0.24, blue: 0.65)], accent: Color(red: 1.0, green: 0.82, blue: 0.05), textColors: [Color(red: 0.30, green: 0.90, blue: 0.40), Color(red: 1.0, green: 0.88, blue: 0.12)], aliases: ["brasil", "selecao"]),
        CountryTheme(canonicalName: "Bolivia", regionCode: "BO", colors: [Color(red: 0.00, green: 0.45, blue: 0.22), Color(red: 1.0, green: 0.82, blue: 0.08), Color(red: 0.76, green: 0.02, blue: 0.10)], accent: Color(red: 1.0, green: 0.78, blue: 0.10), textColors: [Color(red: 0.30, green: 0.88, blue: 0.44), Color(red: 1.0, green: 0.86, blue: 0.16), Color(red: 1.0, green: 0.28, blue: 0.32)], aliases: ["bolivia national team", "bol"]),
        CountryTheme(canonicalName: "Argentina", regionCode: "AR", colors: [Color(red: 0.42, green: 0.76, blue: 1.0), .white, Color(red: 0.20, green: 0.56, blue: 0.93)], accent: Color(red: 0.52, green: 0.80, blue: 1.0), textColors: [Color(red: 0.50, green: 0.78, blue: 1.0), .white], aliases: ["argentina national team"]),
        CountryTheme(canonicalName: "England", regionCode: "GB", colors: [.white, Color(red: 0.78, green: 0.02, blue: 0.16), Color(red: 0.07, green: 0.15, blue: 0.34)], accent: Color(red: 0.94, green: 0.12, blue: 0.24), textColors: [.white, Color(red: 1.0, green: 0.28, blue: 0.34)], aliases: ["england national team", "three lions"]),
        CountryTheme(canonicalName: "Spain", regionCode: "ES", colors: [Color(red: 0.75, green: 0.02, blue: 0.12), Color(red: 1.0, green: 0.78, blue: 0.08), Color(red: 0.55, green: 0.0, blue: 0.08)], accent: Color(red: 1.0, green: 0.72, blue: 0.12), textColors: [Color(red: 1.0, green: 0.82, blue: 0.15), Color(red: 1.0, green: 0.25, blue: 0.28)], aliases: ["espana", "españa"]),
        CountryTheme(canonicalName: "Germany", regionCode: "DE", colors: [.black, Color(red: 0.83, green: 0.04, blue: 0.12), Color(red: 1.0, green: 0.78, blue: 0.10)], accent: Color(red: 1.0, green: 0.76, blue: 0.14), textColors: [.white, Color(red: 1.0, green: 0.32, blue: 0.32), Color(red: 1.0, green: 0.82, blue: 0.16)], aliases: ["deutschland"]),
        CountryTheme(canonicalName: "Italy", regionCode: "IT", colors: [Color(red: 0.00, green: 0.50, blue: 0.24), .white, Color(red: 0.81, green: 0.05, blue: 0.15)], accent: Color(red: 0.20, green: 0.72, blue: 0.38), textColors: [Color(red: 0.34, green: 0.88, blue: 0.52), .white, Color(red: 1.0, green: 0.30, blue: 0.34)], aliases: ["italia", "azzurri"]),
        CountryTheme(canonicalName: "Portugal", regionCode: "PT", colors: [Color(red: 0.00, green: 0.40, blue: 0.20), Color(red: 0.76, green: 0.02, blue: 0.12), Color(red: 1.0, green: 0.82, blue: 0.10)], accent: Color(red: 0.85, green: 0.08, blue: 0.16), textColors: [Color(red: 0.34, green: 0.90, blue: 0.52), Color(red: 1.0, green: 0.25, blue: 0.30)], aliases: []),
        CountryTheme(canonicalName: "Netherlands", regionCode: "NL", colors: [Color(red: 1.0, green: 0.36, blue: 0.0), .white, Color(red: 0.04, green: 0.20, blue: 0.62)], accent: Color(red: 1.0, green: 0.42, blue: 0.08), textColors: [Color(red: 1.0, green: 0.56, blue: 0.15), .white], aliases: ["holland", "oranje"]),
        CountryTheme(canonicalName: "Croatia", regionCode: "HR", colors: [Color(red: 0.86, green: 0.02, blue: 0.12), .white, Color(red: 0.03, green: 0.21, blue: 0.58)], accent: Color(red: 0.94, green: 0.12, blue: 0.22), textColors: [Color(red: 1.0, green: 0.28, blue: 0.34), .white, Color(red: 0.42, green: 0.68, blue: 1.0)], aliases: ["hrvatska"]),
        CountryTheme(canonicalName: "Japan", regionCode: "JP", colors: [.white, Color(red: 0.76, green: 0.02, blue: 0.18), Color(red: 0.08, green: 0.10, blue: 0.16)], accent: Color(red: 0.88, green: 0.06, blue: 0.20), textColors: [.white, Color(red: 1.0, green: 0.24, blue: 0.38)], aliases: ["nippon"]),
        CountryTheme(canonicalName: "South Korea", regionCode: "KR", colors: [.white, Color(red: 0.78, green: 0.04, blue: 0.18), Color(red: 0.02, green: 0.20, blue: 0.56)], accent: Color(red: 0.28, green: 0.50, blue: 0.94), textColors: [.white, Color(red: 1.0, green: 0.24, blue: 0.34), Color(red: 0.46, green: 0.68, blue: 1.0)], aliases: ["korea", "republic of korea"]),
        CountryTheme(canonicalName: "Canada", regionCode: "CA", colors: [Color(red: 0.86, green: 0.02, blue: 0.12), .white, Color(red: 0.55, green: 0.0, blue: 0.08)], accent: Color(red: 0.94, green: 0.12, blue: 0.22), textColors: [Color(red: 1.0, green: 0.28, blue: 0.34), .white], aliases: []),
        CountryTheme(canonicalName: "Costa Rica", regionCode: "CR", colors: [Color(red: 0.00, green: 0.20, blue: 0.54), .white, Color(red: 0.80, green: 0.02, blue: 0.12)], accent: Color(red: 0.92, green: 0.08, blue: 0.20), textColors: [Color(red: 0.42, green: 0.68, blue: 1.0), .white, Color(red: 1.0, green: 0.28, blue: 0.34)], aliases: ["costa rica national team", "ticos"]),
        CountryTheme(canonicalName: "Morocco", regionCode: "MA", colors: [Color(red: 0.72, green: 0.02, blue: 0.12), Color(red: 0.00, green: 0.44, blue: 0.24), Color(red: 0.25, green: 0.02, blue: 0.08)], accent: Color(red: 0.16, green: 0.70, blue: 0.36), textColors: [Color(red: 1.0, green: 0.28, blue: 0.34), Color(red: 0.32, green: 0.86, blue: 0.48)], aliases: ["maroc"]),
        CountryTheme(canonicalName: "Saudi Arabia", regionCode: "SA", colors: [Color(red: 0.00, green: 0.43, blue: 0.24), .white, Color(red: 0.02, green: 0.12, blue: 0.08)], accent: Color(red: 0.20, green: 0.76, blue: 0.42), textColors: [Color(red: 0.32, green: 0.90, blue: 0.52), .white], aliases: ["saudi"]),
        CountryTheme(canonicalName: "Australia", regionCode: "AU", colors: [Color(red: 0.00, green: 0.18, blue: 0.46), Color(red: 1.0, green: 0.78, blue: 0.10), Color(red: 0.00, green: 0.44, blue: 0.28)], accent: Color(red: 1.0, green: 0.78, blue: 0.10), textColors: [Color(red: 0.45, green: 0.70, blue: 1.0), Color(red: 1.0, green: 0.84, blue: 0.18)], aliases: ["australia national team", "socceroos"]),
        CountryTheme(canonicalName: "Colombia", regionCode: "CO", colors: [Color(red: 1.0, green: 0.80, blue: 0.08), Color(red: 0.02, green: 0.20, blue: 0.62), Color(red: 0.78, green: 0.02, blue: 0.12)], accent: Color(red: 1.0, green: 0.78, blue: 0.10), textColors: [Color(red: 1.0, green: 0.86, blue: 0.16), Color(red: 0.42, green: 0.66, blue: 1.0), Color(red: 1.0, green: 0.28, blue: 0.34)], aliases: []),
        CountryTheme(canonicalName: "Uruguay", regionCode: "UY", colors: [Color(red: 0.35, green: 0.68, blue: 1.0), .white, Color(red: 1.0, green: 0.78, blue: 0.10)], accent: Color(red: 0.42, green: 0.72, blue: 1.0), textColors: [Color(red: 0.55, green: 0.80, blue: 1.0), .white], aliases: []),
        CountryTheme(canonicalName: "Chile", regionCode: "CL", colors: [Color(red: 0.02, green: 0.20, blue: 0.58), .white, Color(red: 0.82, green: 0.02, blue: 0.12)], accent: Color(red: 0.84, green: 0.08, blue: 0.20), textColors: [Color(red: 0.44, green: 0.68, blue: 1.0), .white, Color(red: 1.0, green: 0.28, blue: 0.34)], aliases: []),
        CountryTheme(canonicalName: "Peru", regionCode: "PE", colors: [Color(red: 0.78, green: 0.02, blue: 0.12), .white, Color(red: 0.52, green: 0.0, blue: 0.08)], accent: Color(red: 0.88, green: 0.08, blue: 0.18), textColors: [Color(red: 1.0, green: 0.28, blue: 0.34), .white], aliases: []),
        CountryTheme(canonicalName: "Switzerland", regionCode: "CH", colors: [Color(red: 0.86, green: 0.02, blue: 0.12), .white, Color(red: 0.55, green: 0.0, blue: 0.08)], accent: Color(red: 0.94, green: 0.12, blue: 0.20), textColors: [Color(red: 1.0, green: 0.28, blue: 0.34), .white], aliases: ["swiss"]),
        CountryTheme(canonicalName: "Denmark", regionCode: "DK", colors: [Color(red: 0.80, green: 0.02, blue: 0.12), .white, Color(red: 0.46, green: 0.0, blue: 0.08)], accent: Color(red: 0.92, green: 0.10, blue: 0.20), textColors: [Color(red: 1.0, green: 0.26, blue: 0.34), .white], aliases: []),
        CountryTheme(canonicalName: "Sweden", regionCode: "SE", colors: [Color(red: 0.00, green: 0.26, blue: 0.56), Color(red: 1.0, green: 0.80, blue: 0.08), Color(red: 0.00, green: 0.12, blue: 0.34)], accent: Color(red: 1.0, green: 0.78, blue: 0.10), textColors: [Color(red: 0.44, green: 0.68, blue: 1.0), Color(red: 1.0, green: 0.86, blue: 0.16)], aliases: []),
        CountryTheme(canonicalName: "Norway", regionCode: "NO", colors: [Color(red: 0.80, green: 0.02, blue: 0.12), .white, Color(red: 0.02, green: 0.14, blue: 0.42)], accent: Color(red: 0.90, green: 0.08, blue: 0.20), textColors: [Color(red: 1.0, green: 0.26, blue: 0.34), .white, Color(red: 0.44, green: 0.64, blue: 1.0)], aliases: []),
        CountryTheme(canonicalName: "Poland", regionCode: "PL", colors: [.white, Color(red: 0.82, green: 0.02, blue: 0.16), Color(red: 0.42, green: 0.0, blue: 0.08)], accent: Color(red: 0.92, green: 0.08, blue: 0.20), textColors: [.white, Color(red: 1.0, green: 0.26, blue: 0.34)], aliases: ["polska"]),
        CountryTheme(canonicalName: "Serbia", regionCode: "RS", colors: [Color(red: 0.78, green: 0.02, blue: 0.12), Color(red: 0.02, green: 0.20, blue: 0.62), .white], accent: Color(red: 0.84, green: 0.08, blue: 0.18), textColors: [Color(red: 1.0, green: 0.26, blue: 0.34), Color(red: 0.44, green: 0.66, blue: 1.0), .white], aliases: []),
        CountryTheme(canonicalName: "Turkey", regionCode: "TR", colors: [Color(red: 0.82, green: 0.02, blue: 0.12), .white, Color(red: 0.45, green: 0.0, blue: 0.08)], accent: Color(red: 0.94, green: 0.08, blue: 0.18), textColors: [Color(red: 1.0, green: 0.26, blue: 0.34), .white], aliases: ["turkiye", "türkiye"])
    ]

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    nonisolated private static func flagEmoji(forRegionCode regionCode: String) -> String {
        regionCode
            .uppercased()
            .unicodeScalars
            .compactMap { UnicodeScalar(127397 + $0.value) }
            .map(String.init)
            .joined()
    }
}
