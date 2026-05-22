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
        if home.usesFallback && away.usesFallback {
            return safeFallbackColors(darkNavy: darkNavy)
        }

        return [
            home.primaryColor.opacity(0.92),
            home.secondaryColor.opacity(0.82),
            home.accentColor.opacity(0.58),
            darkNavy.opacity(0.96),
            darkNavy,
            away.accentColor.opacity(0.58),
            away.secondaryColor.opacity(0.82),
            away.primaryColor.opacity(0.92)
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

    private static func safeFallbackColors(darkNavy: Color) -> [Color] {
        let fallback = TeamTheme.fallback
        let base = fallback.colors.isEmpty ? CountryTheme.fallback.colors : fallback.colors
        guard !base.isEmpty else {
            return [darkNavy, Color(red: 0.18, green: 0.08, blue: 0.46), Color(red: 0.19, green: 0.42, blue: 0.88)]
        }
        return base
    }
}
