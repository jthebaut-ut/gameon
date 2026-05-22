import SwiftUI

enum ThemeGradientBuilder {
    static func stadiumBackground(home: TeamTheme?, away: TeamTheme?) -> some View {
        let home = home ?? .fallback
        let away = away ?? .fallback

        return LinearGradient(
            colors: stadiumBaseColors(home: home, away: away),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func textGradient(for theme: TeamTheme?) -> LinearGradient {
        let theme = theme ?? .fallback
        return LinearGradient(
            colors: safeTextColors(for: theme),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private static func stadiumBaseColors(home: TeamTheme, away: TeamTheme) -> [Color] {
        let darkNavy = Color(red: 0.015, green: 0.025, blue: 0.08)
        return [
            darkNavy,
            home.accent.opacity(0.86),
            away.accent.opacity(0.78),
            darkNavy
        ]
    }

    private static func safeTextColors(for theme: TeamTheme) -> [Color] {
        if !theme.textColors.isEmpty {
            return theme.textColors
        }
        let fallback = CountryTheme.fallback
        if !fallback.textColors.isEmpty {
            return fallback.textColors
        }
        return [theme.accent, .white]
    }

}
