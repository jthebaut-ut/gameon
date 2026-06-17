import Foundation

nonisolated enum ProGameNotificationFormatting {
    static let finalScoreTitle = "🏁 Final Score"
    static let kickoffStartingBody = "Starting now"
    static let kickoffLeadBodyPrefix = "Your saved Pro Game starts in"
    static let halftimeTitle = "⏱ Halftime"
    static let predictionResultTitle = "Prediction Results"

    static func formattedTeam(_ rawTeamName: String) -> String {
        let cleaned = ProGameTeamScoreIdentity.cleanTeamName(rawTeamName)
        guard !cleaned.isEmpty else { return "" }
        guard let flag = CountryFlagHelper.flag(for: cleaned, source: "ProGameNotification") else {
            return cleaned
        }
        return "\(flag) \(cleaned)"
    }

    static func flagEmoji(for rawTeamName: String) -> String? {
        let cleaned = ProGameTeamScoreIdentity.cleanTeamName(rawTeamName)
        guard !cleaned.isEmpty else { return nil }
        return CountryFlagHelper.flag(for: cleaned, source: "ProGameNotification")
    }

    static func matchupTitle(awayTeam: String, homeTeam: String) -> String {
        let away = formattedTeam(awayTeam)
        let home = formattedTeam(homeTeam)
        if away.isEmpty, home.isEmpty { return "Saved Pro Game" }
        if away.isEmpty { return home }
        if home.isEmpty { return away }
        return "\(away) vs \(home)"
    }

    static func kickoffHeaderTitle(sport: String) -> String {
        if let icon = sportIcon(for: LiveSportVisualType.normalize(sport)), !icon.isEmpty {
            return "\(icon) Kickoff"
        }
        return "Kickoff"
    }

    static func formatTextContainingTeamNames(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        for separator in [" vs ", " v ", " @ ", " at "] {
            guard let range = trimmed.range(of: separator, options: .caseInsensitive) else { continue }
            let away = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let home = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !away.isEmpty, !home.isEmpty else { continue }
            return matchupTitle(awayTeam: away, homeTeam: home)
        }

        return formattedTeam(trimmed)
    }

    static func logPushFlagDebug(
        notificationType: String,
        awayTeam: String?,
        homeTeam: String?,
        scoringTeam: String? = nil
    ) {
        let away = awayTeam?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let home = homeTeam?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        print("[PushFlagDebug] notificationType=\(notificationType)")
        print("[PushFlagDebug] homeTeam=\(home)")
        print("[PushFlagDebug] awayTeam=\(away)")
        print("[PushFlagDebug] homeFlag=\(flagEmoji(for: home) ?? "")")
        print("[PushFlagDebug] awayFlag=\(flagEmoji(for: away) ?? "")")
        if !home.isEmpty, flagEmoji(for: home) == nil {
            print("[PushFlagDebug] missingFlagFor=\(home)")
        }
        if !away.isEmpty, flagEmoji(for: away) == nil {
            print("[PushFlagDebug] missingFlagFor=\(away)")
        }
        if let scoringTeam {
            let cleaned = scoringTeam.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, flagEmoji(for: cleaned) == nil {
                print("[PushFlagDebug] missingFlagFor=\(cleaned)")
            }
        }
    }

    static func scoreline(awayTeam: String, awayScore: Int, homeTeam: String, homeScore: Int) -> String {
        "\(formattedTeam(awayTeam)) \(awayScore) - \(homeScore) \(formattedTeam(homeTeam))"
    }

    static func goalTitle(scoringTeam: String, sport: String) -> String {
        let team = formattedTeam(scoringTeam)
        let sportType = LiveSportVisualType.normalize(sport)
        switch sportType {
        case .soccer:
            return "⚽ GOAL! \(team)"
        case .hockey:
            return "🏒 GOAL! \(team)"
        default:
            if let icon = sportIcon(for: sportType), !icon.isEmpty {
                return "\(icon) \(team) scored"
            }
            return "\(team) scored"
        }
    }

    static func halftimeBody(awayTeam: String, awayScore: Int, homeTeam: String, homeScore: Int) -> String {
        scoreline(awayTeam: awayTeam, awayScore: awayScore, homeTeam: homeTeam, homeScore: homeScore)
    }

    static func predictionTeamReference(_ team: String) -> String {
        let trimmed = team.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.compare("Draw", options: .caseInsensitive) == .orderedSame
            || trimmed.compare("No goals", options: .caseInsensitive) == .orderedSame {
            return trimmed
        }
        return formattedTeam(trimmed)
    }

    static func sportIcon(for sportType: LiveSportVisualType) -> String? {
        switch sportType {
        case .soccer: return "⚽"
        case .hockey: return "🏒"
        case .basketball: return "🏀"
        case .baseball: return "⚾"
        case .nfl: return "🏈"
        default: return nil
        }
    }
}
