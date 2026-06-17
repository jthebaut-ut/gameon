import SwiftUI

struct ProGameLeagueChipVisual: Equatable {
    let emoji: String
    let accent: Color
}

nonisolated enum ProGameLeagueChipVisualResolver {
    static func visual(for sportType: LiveSportVisualType) -> ProGameLeagueChipVisual {
        switch sportType {
        case .soccer:
            return ProGameLeagueChipVisual(
                emoji: "⚽",
                accent: Color(red: 0.05, green: 0.55, blue: 0.28)
            )
        case .hockey:
            return ProGameLeagueChipVisual(
                emoji: "🏒",
                accent: Color(red: 0.12, green: 0.45, blue: 0.92)
            )
        case .basketball:
            return ProGameLeagueChipVisual(
                emoji: "🏀",
                accent: Color(red: 0.95, green: 0.45, blue: 0.12)
            )
        case .baseball:
            return ProGameLeagueChipVisual(
                emoji: "⚾",
                accent: Color(red: 0.85, green: 0.15, blue: 0.18)
            )
        case .nfl:
            return ProGameLeagueChipVisual(
                emoji: "🏈",
                accent: Color(red: 0.52, green: 0.28, blue: 0.78)
            )
        case .tennis:
            return ProGameLeagueChipVisual(
                emoji: "🎾",
                accent: Color(red: 0.08, green: 0.62, blue: 0.58)
            )
        default:
            let catalog = sportType.catalogVisual
            let emoji = catalog.emoji.isEmpty ? "🏟️" : catalog.emoji
            return ProGameLeagueChipVisual(emoji: emoji, accent: sportType.catalogAccent)
        }
    }
}

nonisolated extension LiveSportVisualType {
    /// Sport-aware emoji + tint for Pro Game league chips.
    var proGameLeagueChipVisual: ProGameLeagueChipVisual {
        ProGameLeagueChipVisualResolver.visual(for: self)
    }

    var defaultProGameLeagueChipLabel: String {
        switch self {
        case .soccer:
            return "Soccer"
        case .basketball:
            return "NBA"
        case .hockey:
            return "NHL"
        case .baseball:
            return "MLB"
        case .nfl:
            return "NFL"
        case .tennis:
            return "Tennis"
        default:
            return filterChipLabel
        }
    }

    func proGameLeagueChipLabel(featuredEvent: FeaturedEvent?, league: String) -> String {
        if let featuredEvent {
            let label = featuredEvent.leagueChipLabel
            if !label.isEmpty {
                return label
            }
        }

        let trimmedLeague = league.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLeague.isEmpty {
            if let compact = Self.compactLeagueChipLabel(trimmedLeague, sportType: self) {
                return compact
            }
            if trimmedLeague.count <= 16 {
                return trimmedLeague
            }
        }

        return defaultProGameLeagueChipLabel
    }

    private static func compactLeagueChipLabel(_ league: String, sportType: LiveSportVisualType) -> String? {
        let normalized = LiveMatchFilters.normalizedSearchText(league)
        if normalized.contains("fifa") && normalized.contains("world cup") {
            return "FIFA WC"
        }
        if normalized.contains("wimbledon") {
            return "Wimbledon"
        }
        if normalized.contains("stanley cup") {
            return "Stanley Cup"
        }
        if normalized.contains("super bowl") {
            return "Super Bowl"
        }
        if normalized.contains("nba") {
            return "NBA"
        }
        if normalized.contains("nhl") {
            return "NHL"
        }
        if normalized.contains("mlb") {
            return "MLB"
        }
        if normalized.contains("nfl") {
            return "NFL"
        }

        switch sportType {
        case .basketball where normalized.contains("basketball"):
            return "NBA"
        case .hockey where normalized.contains("hockey"):
            return "NHL"
        case .baseball where normalized.contains("baseball"):
            return "MLB"
        case .nfl where normalized.contains("football"):
            return "NFL"
        default:
            return nil
        }
    }
}

struct ProGameLeagueChip: View {
    let sportType: LiveSportVisualType
    var featuredEvent: FeaturedEvent?
    var league: String = ""

    @Environment(\.colorScheme) private var colorScheme

    private var visual: ProGameLeagueChipVisual {
        sportType.proGameLeagueChipVisual
    }

    private var label: String {
        sportType.proGameLeagueChipLabel(featuredEvent: featuredEvent, league: league)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(visual.emoji)
                .font(.caption2)
                .accessibilityHidden(true)

            Text(label)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(visual.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(visual.accent.opacity(colorScheme == .dark ? 0.18 : 0.10))
        )
        .accessibilityLabel("\(label), \(sportType.displayLabel)")
    }
}
