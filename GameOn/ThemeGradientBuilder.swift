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

@ViewBuilder
func safeVenueGameGradient(
    homeTheme: TeamTheme,
    awayTheme: TeamTheme,
    eventId: String,
    cardVariant: String = "venueGameCard"
) -> some View {
    SafeVenueGameGradient(
        homeTheme: homeTheme,
        awayTheme: awayTheme,
        eventId: eventId,
        cardVariant: cardVariant
    )
}

private struct SafeVenueGameGradient: View {
    @Environment(\.colorScheme) private var colorScheme

    let homeTheme: TeamTheme
    let awayTheme: TeamTheme
    let eventId: String
    let cardVariant: String

    var body: some View {
        let validation = gradientValidation(home: homeTheme, away: awayTheme)

        Group {
            if validation.canUseThemeGradient {
                ThemeGradientBuilder.stadiumBackground(home: homeTheme, away: awayTheme)
                    .onAppear {
#if DEBUG
                        print("[HeroGradientDebug] cardVariant=\(cardVariant) eventId=\(eventId) mode=safeThemeGradient")
#endif
                    }
            } else {
                fallbackGradient(home: homeTheme, away: awayTheme)
                    .onAppear {
#if DEBUG
                        print("[HeroGradientDebug] cardVariant=\(cardVariant) eventId=\(eventId) mode=fallback reason=\(validation.reason)")
#endif
                    }
            }
        }
    }

    private func gradientValidation(home: TeamTheme, away: TeamTheme) -> (canUseThemeGradient: Bool, reason: String) {
        guard !home.usesFallback else { return (false, "homeFallbackTheme") }
        guard !away.usesFallback else { return (false, "awayFallbackTheme") }
        guard home.colors.count >= 2 else { return (false, "homeMissingColors") }
        guard away.colors.count >= 2 else { return (false, "awayMissingColors") }
        guard !home.rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "homeMissingName")
        }
        guard !away.rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "awayMissingName")
        }
        return (true, "ok")
    }

    private func fallbackGradient(home: TeamTheme, away: TeamTheme) -> LinearGradient {
        LinearGradient(
            colors: [
                safeFallbackColor(for: home).opacity(colorScheme == .dark ? 0.32 : 0.18),
                FGColor.cardBackground(colorScheme),
                safeFallbackColor(for: away).opacity(colorScheme == .dark ? 0.28 : 0.16)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func safeFallbackColor(for theme: TeamTheme) -> Color {
        theme.usesFallback ? FGColor.accentGreen : theme.accentColor
    }
}

struct VenueMatchupCardView: View {
    @Environment(\.colorScheme) private var colorScheme

    let homeTheme: TeamTheme
    let awayTheme: TeamTheme
    let homeTitle: String
    let awayTitle: String
    let sportLabel: String
    let sportIconName: String
    let dateTimeText: String
    let statusTitle: String?
    let statusTint: Color
    let eventId: String
    let cardVariant: String
    let height: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            safeVenueGameGradient(
                homeTheme: homeTheme,
                awayTheme: awayTheme,
                eventId: eventId,
                cardVariant: cardVariant
            )

            premiumGlossOverlay

            HStack(alignment: .bottom) {
                teamFlagOrb(theme: homeTheme, title: safeHomeTitle, side: "home")
                Spacer(minLength: 36)
                teamFlagOrb(theme: awayTheme, title: safeAwayTitle, side: "away")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, -2)
            .frame(maxHeight: .infinity, alignment: .bottom)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    sportPill
                    Spacer(minLength: 10)
                    if let statusTitle = safeStatusTitle {
                        statusPill(statusTitle)
                    }
                }

                Spacer(minLength: 16)

                VStack(alignment: .leading, spacing: 8) {
                    matchupTitleText
                        .font(.system(size: titleFontSize, weight: .black, design: .rounded))
                        .tracking(0.45)
                        .lineLimit(2)
                        .minimumScaleFactor(0.62)
                        .shadow(color: .black.opacity(0.46), radius: 7, y: 3)
                        .shadow(color: homeTheme.accent.opacity(0.22), radius: 10, y: 3)

                    Text(safeDateTimeText)
                        .font(.system(size: dateFontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                        .shadow(color: .black.opacity(0.44), radius: 5, y: 2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.20 : 0.16), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.34 : 0.12), radius: 16, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onAppear {
#if DEBUG
            print("[HeroCardLayoutDebug] variant=\(cardVariant) eventId=\(eventId)")
#endif
        }
    }

    private var premiumGlossOverlay: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.10 : 0.18),
                    Color.clear,
                    Color.black.opacity(0.62)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [
                    Color.clear,
                    Color.white.opacity(0.24),
                    Color.clear
                ],
                startPoint: UnitPoint(x: 0.08, y: 0.98),
                endPoint: UnitPoint(x: 0.96, y: 0.02)
            )
            .blur(radius: 1.5)
            .opacity(0.72)

            RadialGradient(
                colors: [
                    homeTheme.accentColor.opacity(0.34),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 180
            )

            RadialGradient(
                colors: [
                    awayTheme.accentColor.opacity(0.28),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 18,
                endRadius: 170
            )
        }
    }

    private var sportPill: some View {
        HStack(spacing: 7) {
            Image(systemName: safeSportIconName)
                .font(.system(size: 14, weight: .black, design: .rounded))
            Text(safeSportLabel)
                .font(.system(size: 16, weight: .black, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.94))
        .textCase(.uppercase)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
            Capsule(style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.13 : 0.20))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.20), radius: 6, y: 3)
    }

    private func statusPill(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(statusTint.opacity(0.94))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                Capsule(style: .continuous)
                    .fill(statusTint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(statusTint.opacity(colorScheme == .dark ? 0.32 : 0.24), lineWidth: 1)
            }
    }

    private func teamFlagOrb(theme: TeamTheme, title: String, side: String) -> some View {
        let safeFlag = TeamTheme.safeFlag(theme.flag)
        let fallback = TeamTheme.safeFallbackText(
            rawName: theme.rawName,
            displayName: title,
            shortName: theme.shortName
        )

        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            safeThemeColor(theme, index: 0).opacity(0.96),
                            safeThemeColor(theme, index: 1).opacity(0.72),
                            Color.black.opacity(0.72)
                        ],
                        center: .top,
                        startRadius: 8,
                        endRadius: 74
                    )
                )
            Circle()
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)

            if let safeFlag {
                Text(safeFlag)
                    .font(.system(size: orbFlagFontSize))
                    .shadow(color: .black.opacity(0.26), radius: 4, y: 2)
            } else {
                Text(fallback.isEmpty ? "FG" : fallback)
                    .font(.system(size: orbInitialsFontSize, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.30), radius: 4, y: 2)
            }
        }
        .frame(width: orbSize, height: orbSize)
        .accessibilityHidden(true)
        .onAppear {
#if DEBUG
            print("[FlagRenderDebug] normalizedTeam=\(CountryTheme.normalize(theme.rawName.isEmpty ? title : theme.rawName))")
            print("[FlagRenderDebug] resolvedFlag=\(safeFlag ?? "nil")")
            print("[FlagRenderDebug] side=\(side) variant=\(cardVariant)")
#endif
        }
    }

    private var matchupTitleText: Text {
        var home = AttributedString(safeHomeTitle)
        home.foregroundColor = homeTheme.textColorHint ?? homeTheme.accentColor
        var separator = AttributedString(" vs ")
        separator.foregroundColor = .white.opacity(0.96)
        var away = AttributedString(safeAwayTitle)
        away.foregroundColor = awayTheme.textColorHint ?? awayTheme.accentColor
        home.append(separator)
        home.append(away)
        return Text(home)
    }

    private var safeHomeTitle: String {
        safeTitle(homeTitle, fallback: homeTheme.uppercaseTitle)
    }

    private var safeAwayTitle: String {
        safeTitle(awayTitle, fallback: awayTheme.uppercaseTitle)
    }

    private var safeSportLabel: String {
        let trimmed = sportLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "SPORT" : trimmed.uppercased()
    }

    private var safeDateTimeText: String {
        let trimmed = dateTimeText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Time TBD" : trimmed
    }

    private var safeStatusTitle: String? {
        let trimmed = statusTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "confirmed", "scheduled", "active":
            return nil
        case "cancelled", "canceled", "postponed", "live", "final":
            return trimmed
        default:
            return nil
        }
    }

    private var safeSportIconName: String {
        let trimmed = sportIconName.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed: Set<String> = [
            "sportscourt.fill",
            "soccerball",
            "basketball.fill",
            "football.fill",
            "baseball.fill",
            "hockey.puck.fill",
            "tennisball.fill",
            "figure.run",
            "flag.checkered",
            "trophy.fill"
        ]
        return allowed.contains(trimmed) ? trimmed : "sportscourt.fill"
    }

    private var titleFontSize: CGFloat {
        height >= 190 ? 30 : 25
    }

    private var dateFontSize: CGFloat {
        height >= 190 ? 17 : 15
    }

    private var orbSize: CGFloat {
        height >= 190 ? 88 : 66
    }

    private var orbFlagFontSize: CGFloat {
        height >= 190 ? 44 : 32
    }

    private var orbInitialsFontSize: CGFloat {
        height >= 190 ? 23 : 17
    }

    private func safeTitle(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed.uppercased() }
        let fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "TEAM" : fallback.uppercased()
    }

    private func safeThemeColor(_ theme: TeamTheme, index: Int) -> Color {
        guard !theme.usesFallback, theme.colors.indices.contains(index) else {
            return index == 0 ? FGColor.accentGreen : Color(red: 0.02, green: 0.05, blue: 0.14)
        }
        return theme.colors[index]
    }
}
