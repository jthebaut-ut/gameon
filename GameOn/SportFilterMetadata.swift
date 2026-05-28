import SwiftUI

/// Central definition for Discover/Calendar sport filter chips and ``MapViewModel`` icon/color helpers.
/// Canonical sport **names** for filters, pickers, and DB payloads live in ``AppSportCatalog``.
nonisolated enum SportFilterCatalog {

    struct ChipVisual {
        let emoji: String
        let systemImage: String
        let accent: Color
    }

    static let fallbackSystemImage = "sportscourt.fill"
    static let fallbackEmoji = "🏟️"
    static let fallbackAccent = Color(red: 0.22, green: 0.76, blue: 0.45)

    /// Resolve visuals for a chip label or any event ``SportsEvent/sport`` string.
    static func resolve(_ raw: String) -> ChipVisual {
        switch canonicalSportKey(for: raw) {
        case "all":
            return ChipVisual(emoji: "", systemImage: "square.grid.2x2.fill", accent: Color(red: 0.35, green: 0.38, blue: 0.45))
        case "soccer":
            return ChipVisual(emoji: "⚽", systemImage: "soccerball", accent: Color(red: 0.05, green: 0.55, blue: 0.28))
        case "basketball":
            return ChipVisual(emoji: "🏀", systemImage: "basketball.fill", accent: Color(red: 0.95, green: 0.45, blue: 0.12))
        case "football":
            return ChipVisual(emoji: "🏈", systemImage: "football.fill", accent: Color(red: 0.45, green: 0.32, blue: 0.18))
        case "baseball":
            return ChipVisual(emoji: "⚾", systemImage: "baseball.fill", accent: Color(red: 0.85, green: 0.15, blue: 0.18))
        case "hockey":
            return ChipVisual(emoji: "🏒", systemImage: "hockey.puck.fill", accent: Color(red: 0.12, green: 0.45, blue: 0.92))
        case "tennis":
            return ChipVisual(emoji: "🎾", systemImage: "tennisball.fill", accent: Color(red: 0.98, green: 0.82, blue: 0.08))
        case "badminton":
            return ChipVisual(emoji: "🏸", systemImage: "sportscourt.fill", accent: Color(red: 0.52, green: 0.72, blue: 0.18))
        case "golf":
            return ChipVisual(emoji: "⛳", systemImage: "figure.golf", accent: Color(red: 0.18, green: 0.62, blue: 0.32))
        case "volleyball":
            return ChipVisual(emoji: "🏐", systemImage: "volleyball.fill", accent: Color(red: 0.2, green: 0.75, blue: 0.88))
        case "pingpong":
            return ChipVisual(emoji: "🏓", systemImage: "figure.table.tennis", accent: Color(red: 0.55, green: 0.22, blue: 0.85))
        case "mma":
            return ChipVisual(emoji: "🥊", systemImage: "figure.boxing", accent: Color(red: 0.75, green: 0.12, blue: 0.18))
        case "boxing":
            return ChipVisual(emoji: "🥊", systemImage: "figure.boxing", accent: Color(red: 0.78, green: 0.15, blue: 0.12))
        case "wrestling":
            return ChipVisual(emoji: "🤼", systemImage: "figure.wrestling", accent: Color(red: 0.42, green: 0.35, blue: 0.72))
        case "racing":
            return ChipVisual(emoji: "🏎\u{FE0F}", systemImage: "flag.pattern.checkered", accent: Color(red: 0.92, green: 0.2, blue: 0.22))
        case "nascar":
            return ChipVisual(emoji: "🏁", systemImage: "flag.checkered.2.crossed", accent: Color(red: 0.18, green: 0.28, blue: 0.82))
        case "cricket":
            return ChipVisual(emoji: "🏏", systemImage: "cricket.ball.fill", accent: Color(red: 0.2, green: 0.35, blue: 0.75))
        case "rugby":
            return ChipVisual(emoji: "🏉", systemImage: "sportscourt.fill", accent: Color(red: 0.15, green: 0.42, blue: 0.28))
        case "softball":
            return ChipVisual(emoji: "🥎", systemImage: "circle.fill", accent: Color(red: 0.95, green: 0.55, blue: 0.2))
        case "cycling":
            return ChipVisual(emoji: "🚴", systemImage: "bicycle", accent: Color(red: 0.1, green: 0.52, blue: 0.78))
        case "running":
            return ChipVisual(emoji: "🏃", systemImage: "figure.run", accent: Color(red: 0.22, green: 0.62, blue: 0.42))
        case "pickleball":
            return ChipVisual(emoji: "🏓", systemImage: "figure.tennis", accent: Color(red: 0.35, green: 0.72, blue: 0.38))
        case "lacrosse":
            return ChipVisual(emoji: "🥍", systemImage: "sportscourt.fill", accent: Color(red: 0.28, green: 0.52, blue: 0.38))
        case "trackfield":
            return ChipVisual(emoji: "🏃", systemImage: "figure.track.and.field", accent: Color(red: 0.55, green: 0.42, blue: 0.82))
        case "motocross":
            return ChipVisual(emoji: "🏁", systemImage: "figure.outdoor.cycle", accent: Color(red: 0.55, green: 0.38, blue: 0.22))
        case "climbing":
            return ChipVisual(emoji: "🧗", systemImage: "figure.climbing", accent: Color(red: 0.35, green: 0.55, blue: 0.82))
        case "skateboarding":
            return ChipVisual(emoji: "🛹", systemImage: "figure.skateboarding", accent: Color(red: 0.45, green: 0.45, blue: 0.5))
        case "bowling":
            return ChipVisual(emoji: "🎳", systemImage: "figure.bowling", accent: Color(red: 0.72, green: 0.35, blue: 0.82))
        case "swimming":
            return ChipVisual(emoji: "🏊", systemImage: "figure.pool.swim", accent: Color(red: 0.12, green: 0.55, blue: 0.88))
        case "skiing":
            return ChipVisual(emoji: "⛷️", systemImage: "figure.skiing.downhill", accent: Color(red: 0.2, green: 0.55, blue: 0.92))
        case "esports":
            return ChipVisual(emoji: "🎮", systemImage: "gamecontroller.fill", accent: Color(red: 0.55, green: 0.28, blue: 0.92))
        case "handball":
            return ChipVisual(emoji: "🤾", systemImage: "figure.handball", accent: Color(red: 0.88, green: 0.42, blue: 0.18))
        case "more":
            return ChipVisual(emoji: "", systemImage: "ellipsis.circle.fill", accent: Color(red: 0.38, green: 0.4, blue: 0.48))
        default:
#if DEBUG
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.caseInsensitiveCompare("All") != .orderedSame {
                print("[SportCatalogDebug] unresolvedSport=\(trimmed)")
            }
#endif
            return fallback
        }
    }

    static var fallback: ChipVisual {
        ChipVisual(
            emoji: fallbackEmoji,
            systemImage: fallbackSystemImage,
            accent: fallbackAccent
        )
    }

    /// True when a free-text search should match this stored ``SportsEvent/sport`` (or venue primary sport) via catalog aliases — e.g. "tour de france" ↔ "Cycling".
    static func storedSport(_ stored: String, matchesSearchQuery rawQuery: String) -> Bool {
        let sport = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sport.isEmpty, !q.isEmpty else { return false }
        if sport.localizedCaseInsensitiveContains(q) { return true }
        if q.localizedCaseInsensitiveContains(sport) { return true }
        guard let sportKey = canonicalSportKey(for: sport) else { return false }
        if canonicalSportKey(for: q) == sportKey { return true }

        let normalizedQuery = normalizedSportText(q)
        for alias in aliases(for: sportKey) {
            let normalizedAlias = normalizedSportText(alias)
            if normalizedAlias.contains(normalizedQuery) || normalizedQuery.contains(normalizedAlias) {
                return true
            }
        }
        return false
    }

    static func isFallbackSport(_ raw: String) -> Bool {
        canonicalSportKey(for: raw) == nil
    }

    private static func canonicalSportKey(for raw: String) -> String? {
        let normalized = normalizedSportText(raw)
        guard !normalized.isEmpty else { return nil }
        guard !isNilLikeSportValue(normalized) else { return nil }
        if normalized == "all" { return "all" }

        if normalized.contains("soccer") || normalized.contains("mls") || normalized.contains("premier league") { return "soccer" }
        if normalized.contains("basketball") || normalized.contains("nba") { return "basketball" }
        if normalized.contains("football") || normalized.contains("nfl") || normalized.contains("ncaaf") { return "football" }
        if normalized.contains("baseball") || normalized.contains("mlb") { return "baseball" }
        if normalized.contains("hockey") || normalized.contains("nhl") { return "hockey" }
        if normalized.contains("softball") { return "softball" }
        if normalized.contains("mma") || normalized.contains("ufc") || normalized.contains("combat sport") { return "mma" }
        if normalized.contains("boxing") { return "boxing" }
        if normalized.contains("badminton") || normalized.contains("shuttlecock") { return "badminton" }
        if normalized.contains("table tennis") || normalized.contains("tabletennis") { return "pingpong" }
        if normalized.contains("tennis") { return "tennis" }
        if normalized.contains("golf") { return "golf" }
        if normalized.contains("motocross") { return "motocross" }
        if normalized.contains("racing")
            || normalized.contains("motogp")
            || normalized.contains("formula 1")
            || normalized.contains("formula1")
            || normalized.contains("formula one")
            || normalized == "f1" {
            return "racing"
        }
        if normalized.contains("cricket") { return "cricket" }
        if normalized.contains("rugby") { return "rugby" }
        if normalized.contains("volleyball") { return "volleyball" }
        if normalized.contains("ping pong") || normalized.contains("pingpong") { return "pingpong" }
        if normalized.contains("wrestling") { return "wrestling" }
        if normalized.contains("nascar") || normalized.contains("stock car") { return "nascar" }
        if normalized.contains("cycling")
            || normalized.contains("bicycle")
            || normalized.contains("biking")
            || normalized.contains("tour de france")
            || normalized.contains("giro")
            || normalized.contains("vuelta")
            || normalized.contains("bmx") {
            return "cycling"
        }
        if normalized.contains("running") || normalized.contains("marathon") { return "running" }
        if normalized.contains("pickleball") { return "pickleball" }
        if normalized.contains("lacrosse") { return "lacrosse" }
        if normalized.contains("track field") || normalized.contains("track and field") || normalized.contains("athletics") { return "trackfield" }
        if normalized.contains("climbing") || normalized.contains("bouldering") { return "climbing" }
        if normalized.contains("skateboard") { return "skateboarding" }
        if normalized.contains("bowling") { return "bowling" }
        if normalized.contains("swimming") || normalized == "swim" { return "swimming" }
        if normalized.contains("skiing") { return "skiing" }
        if normalized.contains("esports") || normalized.contains("e sports") || normalized.contains("gaming") { return "esports" }
        if normalized.contains("handball") { return "handball" }
        if normalized == "more" { return "more" }

        return nil
    }

    private static func normalizedSportText(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let separators = CharacterSet(charactersIn: "_-/|•:.,()[]{}&")
        let parts = lowered.components(separatedBy: separators).flatMap { chunk in
            chunk.components(separatedBy: .whitespacesAndNewlines)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func isNilLikeSportValue(_ normalized: String) -> Bool {
        switch normalized {
        case "nil", "null", "none", "unknown", "n a", "na", "deleted", "deleted sport":
            return true
        default:
            return false
        }
    }

    private static func aliases(for key: String) -> [String] {
        switch key {
        case "all": return ["all"]
        case "soccer": return ["soccer", "mls", "premier league"]
        case "basketball": return ["basketball", "nba"]
        case "football": return ["football", "nfl", "american football", "ncaaf", "college football"]
        case "baseball": return ["baseball", "mlb"]
        case "hockey": return ["hockey", "nhl", "ice hockey"]
        case "tennis": return ["tennis"]
        case "badminton": return ["badminton", "shuttlecock"]
        case "golf": return ["golf"]
        case "volleyball": return ["volleyball"]
        case "pingpong": return ["ping pong", "pingpong", "table tennis", "tabletennis"]
        case "mma": return ["mma", "ufc", "combat sports"]
        case "boxing": return ["boxing"]
        case "wrestling": return ["wrestling"]
        case "racing": return ["racing", "formula 1", "formula1", "formula one", "f1", "motogp"]
        case "nascar": return ["nascar", "stock car"]
        case "cricket": return ["cricket"]
        case "rugby": return ["rugby"]
        case "softball": return ["softball"]
        case "cycling": return ["cycling", "bicycle", "biking", "bike race", "tour de france", "giro", "vuelta", "bmx", "mountain biking", "mountainbiking"]
        case "running": return ["running", "run", "jogging", "road race", "marathon"]
        case "pickleball": return ["pickleball"]
        case "lacrosse": return ["lacrosse"]
        case "trackfield": return ["track field", "track and field", "trackfield", "athletics"]
        case "motocross": return ["motocross"]
        case "climbing": return ["climbing", "rock climbing", "bouldering"]
        case "skateboarding": return ["skateboarding", "skateboard"]
        case "bowling": return ["bowling"]
        case "swimming": return ["swimming", "swim"]
        case "skiing": return ["skiing", "alpine skiing"]
        case "esports": return ["esports", "e sports", "gaming"]
        case "handball": return ["handball"]
        case "more": return ["more"]
        default: return []
        }
    }
}

// MARK: - Live tab sport visuals

extension LiveSportVisualType {
    /// Canonical ``SportFilterCatalog`` lookup key for icons, accents, and Live filter chips.
    var sportFilterCatalogKey: String {
        switch self {
        case .soccer:
            return "Soccer"
        case .basketball:
            return "Basketball"
        case .hockey:
            return "Hockey"
        case .baseball:
            return "Baseball"
        case .nfl:
            return "Football"
        case .tennis:
            return "Tennis"
        case .badminton:
            return "badminton"
        case .golf:
            return "Golf"
        case .formula1:
            return "Formula 1"
        case .other:
            return "Sports"
        }
    }

    var filterChipLabel: String {
        AppSportCatalog.displayLabel(forSportToken: sportFilterCatalogKey)
    }

    var catalogVisual: SportFilterCatalog.ChipVisual {
        SportFilterCatalog.resolve(sportFilterCatalogKey)
    }

    var catalogAccent: Color {
        catalogVisual.accent
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
    /// When true, always uses SF Symbols (Live tab parity with premium cards).
    var preferSystemSymbol = false
    let action: () -> Void

    private var visual: SportFilterCatalog.ChipVisual {
        SportFilterCatalog.resolve(sport)
    }

    private var showsSystemSymbol: Bool {
        preferSystemSymbol || sport == "All" || visual.emoji.isEmpty
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 6) {
                chipIcon

                Text(displayTitle ?? sport)
                    .font(.system(size: isCompact ? 13 : 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, isCompact ? (sport == "All" ? 10 : 11) : (sport == "All" ? 11 : 12))
            .padding(.vertical, isCompact ? 0 : 1)
            .frame(height: isCompact ? 34 : 36, alignment: .center)
            .foregroundStyle(isSelected ? Color.white : FGColor.primaryText(colorScheme))
            .background {
                Group {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [visual.accent.opacity(0.98), visual.accent.opacity(0.76)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay {
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.14))
                                    .blendMode(.overlay)
                            }
                    } else {
                        ZStack {
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                            Capsule(style: .continuous)
                                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.72))
                            Capsule(style: .continuous)
                                .fill(visual.accent.opacity(colorScheme == .dark ? 0.10 : 0.065))
                        }
                    }
                }
            }
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.22) : visual.accent.opacity(colorScheme == .dark ? 0.26 : 0.20),
                        lineWidth: isSelected ? 1 : 0.9
                    )
            )
            .contentShape(Capsule(style: .continuous))
            .shadow(
                color: isSelected ? visual.accent.opacity(colorScheme == .dark ? 0.34 : 0.22) : .black.opacity(colorScheme == .dark ? 0.14 : 0.05),
                radius: isCompact ? (isSelected ? 10 : 5) : (isSelected ? 12 : 6),
                x: 0,
                y: isCompact ? (isSelected ? 4 : 2) : (isSelected ? 5 : 2.5)
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(displayTitle ?? sport)
    }

    @ViewBuilder
    private var chipIcon: some View {
        if showsSystemSymbol {
            Image(systemName: visual.systemImage)
                .font(.system(size: isCompact ? 14 : 15, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color.white : visual.accent)
                .shadow(color: isSelected ? visual.accent.opacity(0.35) : .clear, radius: isSelected ? 4 : 0)
        } else {
            Text(visual.emoji)
                .font(.system(size: isCompact ? 15 : 16))
                .baselineOffset(-0.35)
                .shadow(color: .black.opacity(0.03), radius: 0.5, x: 0, y: 0.5)
        }
    }
}

// MARK: - Sport artwork icon (matches chip catalog; local emoji/SF Symbol only)

/// Circular sport glyph with the same ``SportFilterCatalog`` visuals as ``SportFilterChip`` (gradient + emoji or symbol). No networking.
struct SportArtworkIconView: View {
    let sport: String
    /// Outer diameter; venue preview rows typically use 56–64pt.
    var diameter: CGFloat = 60
    /// When true, always uses SF Symbols (Live tab cards).
    var preferSystemSymbol = false

    private var visual: SportFilterCatalog.ChipVisual {
        SportFilterCatalog.resolve(sport)
    }

    private var isAllChip: Bool {
        sport.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("All") == .orderedSame
    }

    private var showsSystemSymbol: Bool {
        preferSystemSymbol || isAllChip || visual.emoji.isEmpty
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

            if showsSystemSymbol {
                Image(systemName: visual.systemImage)
                    .font(.system(size: diameter * 0.36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Text(visual.emoji)
                    .font(.system(size: diameter * 0.5))
                    .baselineOffset(-diameter * 0.02)
                    .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: visual.accent.opacity(0.32), radius: max(3, diameter * 0.07), x: 0, y: diameter * 0.035)
        .accessibilityLabel(sport)
    }
}
