import Foundation

nonisolated enum LiveSportVisualType: String, Codable, CaseIterable, Equatable {
    case soccer
    case basketball
    case hockey
    case baseball
    case nfl
    case tennis
    case golf
    case formula1
    case other

    var displayLabel: String {
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
        case .golf:
            return "Golf"
        case .formula1:
            return "Formula 1"
        case .other:
            return "Sports"
        }
    }

    static func normalize(_ rawSport: String?) -> LiveSportVisualType {
        let key = normalizedKey(rawSport)
        switch key {
        case "football", "soccer", "association football":
            return .soccer
        case "american football", "nfl", "gridiron", "us football":
            return .nfl
        case "basketball", "nba":
            return .basketball
        case "hockey", "ice hockey", "nhl":
            return .hockey
        case "baseball", "mlb":
            return .baseball
        case "tennis":
            return .tennis
        case "golf":
            return .golf
        case "formula 1", "formula1", "formula one", "f1", "racing", "motorsport", "motor sport":
            return .formula1
        default:
            return .other
        }
    }

    private static func normalizedKey(_ rawSport: String?) -> String {
        let raw = rawSport ?? ""
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let separated = folded
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
        return separated
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum MatchStatus: String, Codable, CaseIterable, Equatable {
    case live = "LIVE"
    case halfTime = "HT"
    case fullTime = "FT"
    case scheduled = "SCHEDULED"

    var isHappeningNow: Bool {
        self == .live || self == .halfTime
    }
}

nonisolated struct LiveMatch: Identifiable, Equatable, Codable {
    let id: String
    let sport: String
    let homeTeam: String
    let awayTeam: String
    let scoreHome: Int
    let scoreAway: Int
    let matchStatus: MatchStatus
    let minute: Int?
    let league: String
    let startTime: Date

    var liveSportVisualType: LiveSportVisualType {
        LiveSportVisualType.normalize(sport)
    }

    var liveSportDisplayLabel: String {
        liveSportVisualType.displayLabel
    }
}
