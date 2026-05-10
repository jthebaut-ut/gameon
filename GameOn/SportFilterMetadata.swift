import SwiftUI

/// Central definition for Discover/Calendar sport filter chips and ``MapViewModel`` icon/color helpers.
enum SportFilterCatalog {

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
        Definition(aliases: ["ufc", "mma", "boxing"], emoji: "🥊", systemImage: "figure.boxing", accent: Color(red: 0.75, green: 0.12, blue: 0.18)),
        Definition(aliases: ["formula 1", "formula1", "f1", "racing", "formula one"], emoji: "🏎\u{FE0F}", systemImage: "flag.pattern.checkered", accent: Color(red: 0.92, green: 0.2, blue: 0.22)),
        Definition(aliases: ["cricket"], emoji: "🏏", systemImage: "cricket.ball.fill", accent: Color(red: 0.2, green: 0.35, blue: 0.75)),
        Definition(aliases: ["rugby"], emoji: "🏉", systemImage: "sportscourt.fill", accent: Color(red: 0.15, green: 0.42, blue: 0.28)),
        Definition(aliases: ["softball"], emoji: "🥎", systemImage: "circle.fill", accent: Color(red: 0.95, green: 0.55, blue: 0.2))
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
}

/// Horizontal filter chip (Discover + Calendar).
struct SportFilterChip: View {
    let sport: String
    let isSelected: Bool
    let action: () -> Void

    private var visual: SportFilterCatalog.ChipVisual {
        SportFilterCatalog.resolve(sport)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 2) {
                if sport == "All" {
                    Image(systemName: visual.systemImage)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white : visual.accent)
                } else if !visual.emoji.isEmpty {
                    Text(visual.emoji)
                        .font(.system(size: 17))
                        .baselineOffset(-0.5)
                        .shadow(color: .black.opacity(0.03), radius: 0.5, x: 0, y: 0.5)
                } else {
                    Image(systemName: visual.systemImage)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(visual.accent)
                }

                Text(sport)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 5)
            .frame(height: 39, alignment: .center)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background {
                Group {
                    if isSelected {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [visual.accent, visual.accent.opacity(0.78)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    } else {
                        ZStack {
                            Capsule()
                                .fill(.ultraThinMaterial)
                            Capsule()
                                .fill(visual.accent.opacity(0.08))
                        }
                    }
                }
            }
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.22) : visual.accent.opacity(0.36),
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
            .shadow(color: isSelected ? visual.accent.opacity(0.26) : .black.opacity(0.045), radius: isSelected ? 5 : 2, x: 0, y: isSelected ? 2 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sport)
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
