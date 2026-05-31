import CoreLocation
import Foundation

nonisolated enum LiveSportVisualType: String, Codable, CaseIterable, Equatable {
    case soccer
    case basketball
    case hockey
    case baseball
    case nfl
    case tennis
    case badminton
    case golf
    case formula1
    case breakdance
    case ballet
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
        case .badminton:
            return "Badminton"
        case .golf:
            return "Golf"
        case .formula1:
            return "Formula 1"
        case .breakdance:
            return "Break Dance"
        case .ballet:
            return "Ballet"
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
        case "badminton", "shuttlecock":
            return .badminton
        case "golf":
            return .golf
        case "formula 1", "formula1", "formula one", "f1", "racing", "motorsport", "motor sport":
            return .formula1
        case "break dance", "breakdance", "break dancing", "breakdancing", "breaking":
            return .breakdance
        case "ballet":
            return .ballet
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

nonisolated struct LiveTVBroadcast: Codable, Equatable {
    let idEvent: String?
    let strCountry: String?
    let strEventCountry: String?
    let strChannel: String?
    let strLogo: String?
    let strTime: String?
    let dateEvent: String?
    let strTimeStamp: String?
}

nonisolated struct LiveTimelineEvent: Codable, Equatable, Identifiable {
    let idTimeline: String?
    let idEvent: String?
    let strTimeline: String?
    let strTimelineDetail: String?
    let strHome: String?
    let idPlayer: String?
    let strPlayer: String?
    let idAssist: String?
    let strAssist: String?
    let intTime: String?
    let idTeam: String?
    let strTeam: String?
    let strComment: String?
    let dateEvent: String?
    let strSeason: String?

    var id: String {
        idTimeline ?? "\(idEvent ?? "event")-\(strTimeline ?? "timeline")-\(intTime ?? "time")-\(strPlayer ?? strTeam ?? "row")"
    }

    var minuteValue: Int? {
        guard let intTime else { return nil }
        return Int(intTime.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var minuteText: String? {
        guard let minuteValue else { return nil }
        return "\(minuteValue)’"
    }

    var playerDisplayName: String? {
        let player = strPlayer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return player.isEmpty ? nil : player
    }

    var assistDisplayName: String? {
        let assist = strAssist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return assist.isEmpty ? nil : assist
    }

    var typeText: String {
        let detail = strTimelineDetail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !detail.isEmpty { return detail }
        let timeline = strTimeline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return timeline.isEmpty ? "Event" : timeline
    }

    var isGoal: Bool {
        let type = "\(strTimeline ?? "") \(strTimelineDetail ?? "")".lowercased()
        return type.contains("goal")
    }

    var isCard: Bool {
        let type = "\(strTimeline ?? "") \(strTimelineDetail ?? "")".lowercased()
        return type.contains("card")
    }

    var isSubstitution: Bool {
        let type = "\(strTimeline ?? "") \(strTimelineDetail ?? "")".lowercased()
        return type.contains("subst") || type.contains("substitution")
    }
}

nonisolated struct LiveMatch: Identifiable, Equatable, Codable {
    let id: String
    let sport: String
    let homeTeam: String
    let awayTeam: String
    let scoreHome: Int
    let scoreAway: Int
    let scoresAreAvailable: Bool
    let matchStatus: MatchStatus
    let minute: Int?
    let league: String
    let startTime: Date
    let venueName: String?
    let venueCity: String?
    let venueLatitude: Double?
    let venueLongitude: Double?
    let tvBroadcasts: [LiveTVBroadcast]
    let timelineEvents: [LiveTimelineEvent]

    var liveSportVisualType: LiveSportVisualType {
        LiveSportVisualType.normalize(sport)
    }

    var liveSportDisplayLabel: String {
        liveSportVisualType.displayLabel
    }

    var tvDisplayText: String? {
        var seen = Set<String>()
        let channels = tvBroadcasts.compactMap { broadcast -> String? in
            let channel = broadcast.strChannel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !channel.isEmpty else { return nil }
            let key = channel.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return channel
        }
        guard !channels.isEmpty else { return nil }
        let visible = channels.prefix(2).joined(separator: ", ")
        let overflow = channels.count - 2
        return overflow > 0 ? "TV: \(visible) +\(overflow)" : "TV: \(visible)"
    }

    var sortedTimelineEvents: [LiveTimelineEvent] {
        timelineEvents.sorted { lhs, rhs in
            switch (lhs.minuteValue, rhs.minuteValue) {
            case let (left?, right?):
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.id < rhs.id
            }
        }
    }

    var goalTimelineEvents: [LiveTimelineEvent] {
        sortedTimelineEvents.filter(\.isGoal)
    }

    var cardTimelineEvents: [LiveTimelineEvent] {
        sortedTimelineEvents.filter(\.isCard)
    }

    var substitutionTimelineEvents: [LiveTimelineEvent] {
        sortedTimelineEvents.filter(\.isSubstitution)
    }

    var scorerSummaryText: String? {
        let goals = goalTimelineEvents.compactMap { event -> String? in
            guard let player = event.playerDisplayName else { return nil }
            if let minute = event.minuteText {
                return "\(player) \(minute)"
            }
            return player
        }
        guard !goals.isEmpty else { return nil }
        let visible = goals.prefix(3).joined(separator: ", ")
        let overflow = goals.count - 3
        return overflow > 0 ? "Goals: \(visible) +\(overflow)" : "Goals: \(visible)"
    }

    var venueCoordinate: CLLocationCoordinate2D? {
        guard let venueLatitude,
              let venueLongitude else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: venueLatitude, longitude: venueLongitude)
        guard CLLocationCoordinate2DIsValid(coordinate),
              abs(venueLatitude) > 0.0001,
              abs(venueLongitude) > 0.0001 else {
            return nil
        }
        return coordinate
    }
}
