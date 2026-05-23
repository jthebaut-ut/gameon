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
    let primaryColorHex: String?
    let secondaryColorHex: String?
    let accentColorHex: String?
    let darkModeAdjustedColorHex: String?

    static let fallback = TeamTheme(
        rawName: "FanGeo",
        displayName: "FanGeo",
        flag: nil,
        colors: CountryTheme.fallback.colors,
        accent: CountryTheme.fallback.accent,
        textColors: CountryTheme.fallback.textColors,
        usesFallback: true,
        textColorHint: CountryTheme.fallback.textColors.first,
        shortName: nil,
        primaryColorHex: nil,
        secondaryColorHex: nil,
        accentColorHex: nil,
        darkModeAdjustedColorHex: nil
    )

    static func resolve(_ rawName: String?) -> TeamTheme {
        let cleanedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanedName.isEmpty else {
            return logResolvedTheme(fallback, requestedName: rawName ?? "")
        }
        let displayName = CountryFlagHelper.displayName(for: cleanedName)

        if let teamTheme = TeamThemeProvider.theme(for: cleanedName) {
            return logResolvedTheme(teamTheme, requestedName: cleanedName)
        }

        if let country = CountryTheme.resolve(cleanedName) {
            return logResolvedTheme(TeamTheme(
                rawName: cleanedName,
                displayName: country.canonicalName,
                flag: country.flag ?? CountryFlagHelper.flag(for: cleanedName),
                colors: country.colors,
                accent: country.accent,
                textColors: country.textColors,
                usesFallback: false,
                textColorHint: country.textColors.first,
                shortName: nil,
                primaryColorHex: nil,
                secondaryColorHex: nil,
                accentColorHex: nil,
                darkModeAdjustedColorHex: nil
            ), requestedName: cleanedName)
        }

        let fallback = CountryTheme.fallback
        return logResolvedTheme(TeamTheme(
            rawName: cleanedName,
            displayName: displayName,
            flag: CountryFlagHelper.flag(for: cleanedName),
            colors: fallback.colors,
            accent: fallback.accent,
            textColors: fallback.textColors,
            usesFallback: true,
            textColorHint: fallback.textColors.first,
            shortName: nil,
            primaryColorHex: nil,
            secondaryColorHex: nil,
            accentColorHex: nil,
            darkModeAdjustedColorHex: nil
        ), requestedName: cleanedName)
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

    private static func logResolvedTheme(_ theme: TeamTheme, requestedName: String) -> TeamTheme {
#if DEBUG
        print("[TeamThemeDebug] team=\(requestedName)")
        print("[TeamThemeDebug] primary=\(theme.primaryColorHex ?? "nil")")
        print("[TeamThemeDebug] secondary=\(theme.secondaryColorHex ?? "nil")")
        print("[TeamThemeDebug] fallbackUsed=\(theme.usesFallback)")
#endif
        return theme
    }
}

private enum TeamThemeProvider {
    static func theme(for rawName: String) -> TeamTheme? {
        guard let entry = TeamColorRegistry.color(for: rawName) else { return nil }
        let primary = TeamColorRegistry.colorFromHex(entry.primaryColorHex)
        let secondary = TeamColorRegistry.colorFromHex(entry.secondaryColorHex)
        let accentHex = entry.accentColorHex ?? entry.secondaryColorHex
        let accent = TeamColorRegistry.colorFromHex(accentHex)
        let textColorHint = bestTextColorHint(primaryHex: entry.primaryColorHex, secondaryHex: entry.secondaryColorHex, accentHex: accentHex)
        return TeamTheme(
            rawName: rawName,
            displayName: entry.displayName,
            flag: CountryFlagHelper.flag(for: entry.displayName),
            colors: [primary, secondary, accent],
            accent: accent,
            textColors: safeTextColors(primary: primary, secondary: secondary, accent: accent, textColorHint: textColorHint),
            usesFallback: false,
            textColorHint: textColorHint,
            shortName: entry.shortName,
            primaryColorHex: entry.primaryColorHex,
            secondaryColorHex: entry.secondaryColorHex,
            accentColorHex: entry.accentColorHex,
            darkModeAdjustedColorHex: entry.darkModeAdjustedColorHex
        )
    }

    private static func safeTextColors(primary: Color, secondary: Color, accent: Color, textColorHint: Color?) -> [Color] {
        [textColorHint ?? accent, secondary, primary, .white]
    }

    private static func bestTextColorHint(primaryHex: String, secondaryHex: String, accentHex: String) -> Color {
        let candidates = [primaryHex, secondaryHex, accentHex].filter { !$0.isEmpty }
        let best = candidates.first { relativeLuminance(hex: $0) <= 0.42 } ?? candidates.first ?? primaryHex
        return TeamColorRegistry.colorFromHex(best)
    }

    private static func relativeLuminance(hex: String) -> Double {
        let cleaned = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6,
              let value = Int(cleaned, radix: 16) else {
            return 0.0
        }
        let red = Double((value >> 16) & 0xff) / 255.0
        let green = Double((value >> 8) & 0xff) / 255.0
        let blue = Double(value & 0xff) / 255.0
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}
