import SwiftUI

/// Central definition for Discover/Calendar sport filter chips and ``MapViewModel`` icon/color helpers.
/// Canonical sport **names** for filters, pickers, and DB payloads live in ``AppSportCatalog``.
nonisolated enum SportFilterCatalog {

    struct ChipVisual {
        let emoji: String
        let systemImage: String
        let accent: Color
    }

    private struct Definition {
        let aliases: [String]
        let emoji: String
        let systemImage: String
        let accent: Color
    }

    private static let definitions: [Definition] = [
        Definition(aliases: ["soccer", "mls", "premier league"], emoji: "⚽", systemImage: "soccerball", accent: Color(red: 0.05, green: 0.55, blue: 0.28)),
        Definition(aliases: ["nba", "basketball"], emoji: "🏀", systemImage: "basketball.fill", accent: Color(red: 0.95, green: 0.45, blue: 0.12)),
        Definition(aliases: ["nfl", "football", "american football"], emoji: "🏈", systemImage: "football.fill", accent: Color(red: 0.45, green: 0.32, blue: 0.18)),
        Definition(aliases: ["mlb", "baseball"], emoji: "⚾", systemImage: "baseball.fill", accent: Color(red: 0.85, green: 0.15, blue: 0.18)),
        Definition(aliases: ["nhl", "hockey", "ice hockey"], emoji: "🏒", systemImage: "hockey.puck.fill", accent: Color(red: 0.12, green: 0.45, blue: 0.92)),
        Definition(aliases: ["tennis"], emoji: "🎾", systemImage: "tennisball.fill", accent: Color(red: 0.98, green: 0.82, blue: 0.08)),
        Definition(aliases: ["golf"], emoji: "⛳", systemImage: "figure.golf", accent: Color(red: 0.18, green: 0.62, blue: 0.32)),
        Definition(aliases: ["volleyball"], emoji: "🏐", systemImage: "volleyball.fill", accent: Color(red: 0.2, green: 0.75, blue: 0.88)),
        Definition(aliases: ["ping pong", "pingpong", "table tennis", "tabletennis"], emoji: "🏓", systemImage: "figure.table.tennis", accent: Color(red: 0.55, green: 0.22, blue: 0.85)),
        Definition(aliases: ["ufc", "mma", "combat sports"], emoji: "🥊", systemImage: "figure.boxing", accent: Color(red: 0.75, green: 0.12, blue: 0.18)),
        Definition(aliases: ["boxing"], emoji: "🥊", systemImage: "figure.boxing", accent: Color(red: 0.78, green: 0.15, blue: 0.12)),
        Definition(aliases: ["wrestling"], emoji: "🤼", systemImage: "figure.wrestling", accent: Color(red: 0.42, green: 0.35, blue: 0.72)),
        Definition(aliases: ["formula 1", "formula1", "f1", "racing", "formula one"], emoji: "🏎\u{FE0F}", systemImage: "flag.pattern.checkered", accent: Color(red: 0.92, green: 0.2, blue: 0.22)),
        Definition(aliases: ["nascar", "stock car"], emoji: "🏁", systemImage: "flag.checkered.2.crossed", accent: Color(red: 0.18, green: 0.28, blue: 0.82)),
        Definition(aliases: ["cricket"], emoji: "🏏", systemImage: "cricket.ball.fill", accent: Color(red: 0.2, green: 0.35, blue: 0.75)),
        Definition(aliases: ["rugby"], emoji: "🏉", systemImage: "sportscourt.fill", accent: Color(red: 0.15, green: 0.42, blue: 0.28)),
        Definition(aliases: ["softball"], emoji: "🥎", systemImage: "circle.fill", accent: Color(red: 0.95, green: 0.55, blue: 0.2)),
        Definition(
            aliases: [
                "cycling",
                "bicycle",
                "biking",
                "bike race",
                "tour de france",
                "giro",
                "vuelta",
                "bmx",
                "mountain biking",
                "mountainbiking"
            ],
            emoji: "🚴",
            systemImage: "bicycle",
            accent: Color(red: 0.1, green: 0.52, blue: 0.78)
        ),
        Definition(aliases: ["running", "run", "jogging", "road race", "marathon"], emoji: "🏃", systemImage: "figure.run", accent: Color(red: 0.22, green: 0.62, blue: 0.42)),
        Definition(aliases: ["pickleball"], emoji: "🏓", systemImage: "figure.tennis", accent: Color(red: 0.35, green: 0.72, blue: 0.38)),
        Definition(aliases: ["lacrosse"], emoji: "🥍", systemImage: "sportscourt.fill", accent: Color(red: 0.28, green: 0.52, blue: 0.38)),
        Definition(
            aliases: ["track & field", "track and field", "trackfield", "athletics"],
            emoji: "🏃",
            systemImage: "figure.track.and.field",
            accent: Color(red: 0.55, green: 0.42, blue: 0.82)
        ),
        Definition(aliases: ["motogp"], emoji: "🏍️", systemImage: "flag.checkered.2.crossed", accent: Color(red: 0.92, green: 0.22, blue: 0.28)),
        Definition(aliases: ["motocross"], emoji: "🏁", systemImage: "figure.outdoor.cycle", accent: Color(red: 0.55, green: 0.38, blue: 0.22)),
        Definition(aliases: ["climbing", "rock climbing", "bouldering"], emoji: "🧗", systemImage: "figure.climbing", accent: Color(red: 0.35, green: 0.55, blue: 0.82)),
        Definition(aliases: ["skateboarding", "skateboard"], emoji: "🛹", systemImage: "figure.skateboarding", accent: Color(red: 0.45, green: 0.45, blue: 0.5)),
        Definition(aliases: ["bowling"], emoji: "🎳", systemImage: "figure.bowling", accent: Color(red: 0.72, green: 0.35, blue: 0.82)),
        Definition(aliases: ["swimming", "swim"], emoji: "🏊", systemImage: "figure.pool.swim", accent: Color(red: 0.12, green: 0.55, blue: 0.88)),
        Definition(aliases: ["skiing", "alpine skiing"], emoji: "⛷️", systemImage: "figure.skiing.downhill", accent: Color(red: 0.2, green: 0.55, blue: 0.92)),
        Definition(aliases: ["esports", "e-sports", "gaming"], emoji: "🎮", systemImage: "gamecontroller.fill", accent: Color(red: 0.55, green: 0.28, blue: 0.92)),
        Definition(aliases: ["handball"], emoji: "🤾", systemImage: "figure.handball", accent: Color(red: 0.88, green: 0.42, blue: 0.18)),
        Definition(aliases: ["more"], emoji: "", systemImage: "ellipsis.circle.fill", accent: Color(red: 0.38, green: 0.4, blue: 0.48))
    ]

    private static let allVisual = ChipVisual(
        emoji: "",
        systemImage: "square.grid.2x2.fill",
        accent: Color(red: 0.35, green: 0.38, blue: 0.45)
    )

    private static let fallbackVisual = ChipVisual(
        emoji: "",
        systemImage: "sportscourt.fill",
        accent: Color.accentColor
    )

    /// Resolve visuals for a chip label or any event ``SportsEvent/sport`` string.
    static func resolve(_ raw: String) -> ChipVisual {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("All") == .orderedSame {
            return allVisual
        }
        let key = trimmed.lowercased()
        for def in definitions {
            if def.aliases.contains(key) {
                return ChipVisual(emoji: def.emoji, systemImage: def.systemImage, accent: def.accent)
            }
        }
        return fallbackVisual
    }

    /// True when a free-text search should match this stored ``SportsEvent/sport`` (or venue primary sport) via catalog aliases — e.g. "tour de france" ↔ "Cycling".
    static func storedSport(_ stored: String, matchesSearchQuery rawQuery: String) -> Bool {
        let sport = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sport.isEmpty, !q.isEmpty else { return false }
        if sport.localizedCaseInsensitiveContains(q) { return true }
        if q.localizedCaseInsensitiveContains(sport) { return true }
        guard let def = definition(matchingStoredSport: sport) else { return false }
        let ql = q.lowercased()
        for a in def.aliases {
            if a.lowercased().localizedCaseInsensitiveContains(ql) { return true }
            if ql.localizedCaseInsensitiveContains(a) { return true }
        }
        return false
    }

    private static func definition(matchingStoredSport sport: String) -> Definition? {
        let key = sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return definitions.first { def in
            def.aliases.contains { alias in
                alias == key || sport.localizedCaseInsensitiveCompare(alias) == .orderedSame
            }
        }
    }
}

/// Horizontal filter chip (Discover + Calendar).
struct SportFilterChip: View {
    @Environment(\.colorScheme) private var colorScheme

    let sport: String
    /// When set, shown instead of ``sport`` while chip visuals still resolve from ``sport`` (e.g. label "Basketball" with selection token `NBA`).
    var displayTitle: String? = nil
    let isSelected: Bool
    var isCompact = false
    let action: () -> Void

    private var visual: SportFilterCatalog.ChipVisual {
        SportFilterCatalog.resolve(sport)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 5) {
                if sport == "All" {
                    Image(systemName: visual.systemImage)
                        .font(.system(size: isCompact ? 14 : 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white : visual.accent)
                } else if !visual.emoji.isEmpty {
                    Text(visual.emoji)
                        .font(.system(size: isCompact ? 15 : 16))
                        .baselineOffset(-0.35)
                        .shadow(color: .black.opacity(0.03), radius: 0.5, x: 0, y: 0.5)
                } else {
                    Image(systemName: visual.systemImage)
                        .font(.system(size: isCompact ? 14 : 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(visual.accent)
                }

                Text(displayTitle ?? sport)
                    .font(.system(size: isCompact ? 13 : 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, isCompact ? (sport == "All" ? 9 : 10) : (sport == "All" ? 10 : 11))
            .frame(height: isCompact ? 33 : 35, alignment: .center)
            .foregroundStyle(isSelected ? Color.white : FGColor.primaryText(colorScheme))
            .background {
                Group {
                    if isSelected {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [visual.accent.opacity(0.96), visual.accent.opacity(0.78)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    } else {
                        ZStack {
                            Capsule()
                                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.92 : 0.98))
                            Capsule()
                                .fill(visual.accent.opacity(colorScheme == .dark ? 0.08 : 0.055))
                        }
                    }
                }
            }
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.18) : visual.accent.opacity(colorScheme == .dark ? 0.24 : 0.18),
                        lineWidth: isSelected ? 0.95 : 0.85
                    )
            )
            .contentShape(Capsule())
            .shadow(
                color: isSelected ? visual.accent.opacity(0.18) : .black.opacity(colorScheme == .dark ? 0.12 : 0.045),
                radius: isCompact ? (isSelected ? 8 : 4) : (isSelected ? 10 : 5),
                x: 0,
                y: isCompact ? (isSelected ? 3 : 1.5) : (isSelected ? 4 : 2)
            )
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(displayTitle ?? sport)
    }
}

// MARK: - Sport artwork icon (matches chip catalog; local emoji/SF Symbol only)

/// Circular sport glyph with the same ``SportFilterCatalog`` visuals as ``SportFilterChip`` (gradient + emoji or symbol). No networking.
struct SportArtworkIconView: View {
    let sport: String
    /// Outer diameter; venue preview rows typically use 56–64pt.
    var diameter: CGFloat = 60

    private var visual: SportFilterCatalog.ChipVisual {
        SportFilterCatalog.resolve(sport)
    }

    private var isAllChip: Bool {
        sport.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("All") == .orderedSame
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [visual.accent, visual.accent.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                )

            if isAllChip {
                Image(systemName: visual.systemImage)
                    .font(.system(size: diameter * 0.36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else if !visual.emoji.isEmpty {
                Text(visual.emoji)
                    .font(.system(size: diameter * 0.5))
                    .baselineOffset(-diameter * 0.02)
                    .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
            } else {
                Image(systemName: visual.systemImage)
                    .font(.system(size: diameter * 0.36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: visual.accent.opacity(0.32), radius: max(3, diameter * 0.07), x: 0, y: diameter * 0.035)
        .accessibilityLabel(sport)
    }
}
