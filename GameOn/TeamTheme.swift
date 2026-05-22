import SwiftUI

struct TeamTheme {
    let rawName: String
    let displayName: String
    let flag: String?
    let colors: [Color]
    let accent: Color
    let textColors: [Color]
    let usesFallback: Bool

    static let fallback = TeamTheme(
        rawName: "FanGeo",
        displayName: "FanGeo",
        flag: nil,
        colors: CountryTheme.fallback.colors,
        accent: CountryTheme.fallback.accent,
        textColors: CountryTheme.fallback.textColors,
        usesFallback: true
    )

    static func resolve(_ rawName: String?) -> TeamTheme {
        let cleanedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanedName.isEmpty else {
            return fallback
        }
        let displayName = CountryFlagHelper.displayName(for: cleanedName)

        if let country = CountryTheme.resolve(cleanedName) {
            return TeamTheme(
                rawName: cleanedName,
                displayName: country.canonicalName,
                flag: country.flag ?? CountryFlagHelper.flag(for: cleanedName),
                colors: country.colors,
                accent: country.accent,
                textColors: country.textColors,
                usesFallback: false
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
            usesFallback: true
        )
    }

    var uppercaseTitle: String {
        displayName.uppercased()
    }

    var primaryColor: Color {
        colors.first ?? CountryTheme.fallback.accent
    }
}
