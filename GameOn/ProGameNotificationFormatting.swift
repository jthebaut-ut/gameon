import Foundation

nonisolated enum ProGameNotificationFormatting {
    static let finalScoreTitle = "🏁 Final Score"
    static let kickoffStartingBody = "Starting now"
    static let kickoffLeadBodyPrefix = "Your saved Pro Game starts in"
    static let halftimeTitle = "⏱ Halftime"
    static let predictionResultTitle = "Prediction Results"

    static func formattedTeam(_ rawTeamName: String, source: String = "ProGameNotification") -> String {
        let cleaned = ProGameTeamScoreIdentity.cleanTeamName(rawTeamName)
        guard !cleaned.isEmpty else { return "" }
        guard let flag = CountryFlagHelper.flag(for: cleaned, source: source)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !flag.isEmpty else {
            if source.localizedCaseInsensitiveContains("calendar") {
                print("[CalendarFlagDebug] missingFlagFor=\(cleaned)")
            }
            return cleaned
        }
        return "\(flag) \(cleaned)"
    }

    static func flagEmoji(for rawTeamName: String, source: String = "ProGameNotification") -> String? {
        let cleaned = ProGameTeamScoreIdentity.cleanTeamName(rawTeamName)
        guard !cleaned.isEmpty else { return nil }
        return CountryFlagHelper.flag(for: cleaned, source: source)
    }

    static func matchupTitle(awayTeam: String, homeTeam: String, source: String = "ProGameNotification") -> String {
        let away = formattedTeam(awayTeam, source: source)
        let home = formattedTeam(homeTeam, source: source)
        let title: String
        if away.isEmpty, home.isEmpty {
            title = "Saved Pro Game"
        } else if away.isEmpty {
            title = home
        } else if home.isEmpty {
            title = away
        } else {
            title = "\(away) vs \(home)"
        }
        if source.localizedCaseInsensitiveContains("calendar") {
            CountryFlagHelper.logCalendarMatchupFlagDebug(
                awayTeam: awayTeam,
                homeTeam: homeTeam,
                finalTitle: title,
                source: source
            )
        }
        return title
    }

    static func kickoffHeaderTitle(sport: String) -> String {
        if let icon = sportIcon(for: LiveSportVisualType.normalize(sport)), !icon.isEmpty {
            return "\(icon) Kickoff"
        }
        return "Kickoff"
    }

    static func formatTextContainingTeamNames(_ text: String, source: String = "ProGameNotification") -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        for separator in [" vs ", " v ", " @ ", " at "] {
            guard let range = trimmed.range(of: separator, options: .caseInsensitive) else { continue }
            let away = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let home = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !away.isEmpty, !home.isEmpty else { continue }
            return matchupTitle(awayTeam: away, homeTeam: home, source: source)
        }

        return formattedTeam(trimmed, source: source)
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

    static func cardNotificationTitle(cardType: LiveCardEventType) -> String {
        "\(cardType.emoji) \(cardType.notificationTitleLabel)"
    }

    static func cardNotificationBody(
        cardType: LiveCardEventType,
        minuteText: String?,
        playerName: String?,
        teamName: String?
    ) -> String {
        let clock = normalizedCardNotificationClock(minuteText)
        let player = playerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let team = ProGameTeamScoreIdentity.cleanTeamName(teamName ?? "")

        switch cardType {
        case .yellow:
            if !player.isEmpty, !team.isEmpty {
                return "\(clock) \(player) (\(team))"
            }
            if !player.isEmpty {
                return "\(clock) \(player)"
            }
            if !team.isEmpty {
                return "\(clock) \(team) received a yellow card."
            }
            return "\(clock) Yellow card"
        case .red, .secondYellow:
            if !player.isEmpty, !team.isEmpty {
                return "\(clock) \(player) (\(team))"
            }
            if !player.isEmpty {
                return "\(clock) \(player)"
            }
            if !team.isEmpty {
                return "\(clock) \(team) received a red card."
            }
            return "\(clock) Red card"
        }
    }

    private static func normalizedCardNotificationClock(_ minuteText: String?) -> String {
        let trimmed = minuteText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "?" }
        if trimmed.hasSuffix("'") || trimmed.hasSuffix("’") {
            return trimmed.replacingOccurrences(of: "’", with: "'")
        }
        return "\(trimmed)'"
    }
}
