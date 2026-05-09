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
            HStack(spacing: 7) {
                if sport == "All" {
                    Image(systemName: visual.systemImage)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(isSelected ? Color.white : visual.accent)
                } else if !visual.emoji.isEmpty {
                    Text(visual.emoji)
                        .font(.title3)
                        .shadow(color: .black.opacity(0.06), radius: 0.5, x: 0, y: 0.5)
                } else {
                    Image(systemName: visual.systemImage)
                        .font(.body.weight(.bold))
                        .foregroundStyle(visual.accent)
                }

                Text(sport)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
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
                        isSelected ? Color.white.opacity(0.22) : visual.accent.opacity(0.38),
                        lineWidth: isSelected ? 1 : 1
                    )
            )
            .shadow(color: isSelected ? visual.accent.opacity(0.35) : .black.opacity(0.06), radius: isSelected ? 8 : 3, x: 0, y: isSelected ? 3 : 1)
        }
        .buttonStyle(.plain)
    }
}
