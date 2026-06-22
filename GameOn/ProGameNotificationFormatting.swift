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
            return playerMatchEventTitle(emojiAndEventLabel: "⚽ GOAL!", playerTeamName: scoringTeam)
        case .hockey:
            return playerMatchEventTitle(emojiAndEventLabel: "🏒 GOAL!", playerTeamName: scoringTeam)
        default:
            if let icon = sportIcon(for: sportType), !icon.isEmpty {
                return "\(icon) \(team) scored"
            }
            return "\(team) scored"
        }
    }

    /// Shared title for player-based match notifications: `🟨 Yellow Card • 🇦🇹 Austria`
    static func playerMatchEventTitle(emojiAndEventLabel: String, playerTeamName: String?) -> String {
        let label = emojiAndEventLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let teamName = resolvedNotificationTeamName(playerTeamName) else {
            return label
        }
        let team = formattedTeam(teamName)
        guard !team.isEmpty else { return label }
        return "\(label) • \(team)"
    }

    /// Shared body for player-based match notifications.
    /// Line 1: player (optionally prefixed by minute). Line 2: matchup or custom score summary.
    static func playerMatchEventBody(
        playerName: String?,
        minuteText: String?,
        awayTeam: String,
        homeTeam: String,
        scoreSummaryLine: String? = nil
    ) -> String {
        let player = playerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secondLine = scoreSummaryLine?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? matchupTitle(awayTeam: awayTeam, homeTeam: homeTeam)

        if !player.isEmpty {
            let firstLine: String
            if let minute = normalizedGoalMinute(minuteText) {
                firstLine = "\(minute) \(player)"
            } else {
                firstLine = player
            }
            if !secondLine.isEmpty {
                return "\(firstLine)\n\(secondLine)"
            }
            return firstLine
        }

        if !secondLine.isEmpty {
            return secondLine
        }
        return ""
    }

    static func homeFirstScoreline(
        homeTeam: String,
        homeScore: Int,
        awayTeam: String,
        awayScore: Int,
        source: String = "ProGameNotification"
    ) -> String {
        "\(formattedTeam(homeTeam, source: source)) \(homeScore) - \(awayScore) \(formattedTeam(awayTeam, source: source))"
    }

    static func validGoalScorerName(_ raw: String?, scoringTeam: String) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard normalizedTeamToken(raw) != normalizedTeamToken(scoringTeam) else { return nil }
        return raw
    }

    static func goalNotificationFirstLine(minuteText: String?, scorerName: String?) -> String {
        let minute = normalizedGoalMinute(minuteText)
        let scorer = scorerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scorer, !scorer.isEmpty {
            if let minute {
                return "\(minute) \(scorer)"
            }
            return scorer
        }
        if let minute {
            return "\(minute) Goal"
        }
        return "Goal"
    }

    static func goalNotificationBody(
        minuteText: String?,
        scorerName: String?,
        homeTeam: String,
        homeScore: Int,
        awayTeam: String,
        awayScore: Int
    ) -> String {
        let firstLine = goalNotificationFirstLine(minuteText: minuteText, scorerName: scorerName)
        let secondLine = homeFirstScoreline(
            homeTeam: homeTeam,
            homeScore: homeScore,
            awayTeam: awayTeam,
            awayScore: awayScore
        )
        return "\(firstLine)\n\(secondLine)"
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

    static func scoreCorrectionTitle(rulingReason: String?) -> String {
        let reason = rulingReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reason.isEmpty else { return "Goal ruled out" }
        return "Goal ruled out for \(reason)"
    }

    static func scoreCorrectionBody(
        correctedTeam: String,
        homeTeam: String,
        homeScore: Int,
        awayTeam: String,
        awayScore: Int
    ) -> String {
        let team = formattedTeam(correctedTeam)
        let home = formattedTeam(homeTeam)
        let away = formattedTeam(awayTeam)
        return "\(team) goal was ruled out. Score remains \(home) \(homeScore)–\(awayScore) \(away)."
    }

    static func goalRuledOutReason(
        previousTimeline: [LiveTimelineEvent]?,
        updatedTimeline: [LiveTimelineEvent]?
    ) -> String? {
        let haystack = timelineNotificationHaystack(previousTimeline, updatedTimeline)
        guard !haystack.isEmpty else { return nil }
        if haystack.contains("offside") { return "offside" }
        if haystack.contains("handball") { return "handball" }
        if haystack.contains("foul") { return "foul" }
        if haystack.contains("var") || haystack.contains("video assistant") { return "VAR" }
        if haystack.contains("disallowed")
            || haystack.contains("ruled out")
            || haystack.contains("no goal")
            || haystack.contains("cancelled goal")
            || haystack.contains("canceled goal") {
            return "VAR"
        }
        return nil
    }

    private static func timelineNotificationHaystack(
        _ previousTimeline: [LiveTimelineEvent]?,
        _ updatedTimeline: [LiveTimelineEvent]?
    ) -> String {
        let events = (updatedTimeline ?? []) + (previousTimeline ?? [])
        return events
            .map {
                [
                    $0.strTimeline,
                    $0.strTimelineDetail,
                    $0.strComment,
                    $0.strTeam,
                    $0.strPlayer
                ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    static func cardNotificationTitle(cardType: LiveCardEventType, teamName: String? = nil) -> String {
        guard resolvedNotificationTeamName(teamName) != nil else {
            return "\(cardType.emoji) \(cardType.notificationTitleLabel)"
        }
        return playerMatchEventTitle(
            emojiAndEventLabel: "\(cardType.emoji) \(cardEventDisplayTitle(cardType))",
            playerTeamName: teamName
        )
    }

    static func cardNotificationBody(
        cardType: LiveCardEventType,
        minuteText: String?,
        playerName: String?,
        teamName: String?,
        awayTeam: String,
        homeTeam: String
    ) -> String {
        guard resolvedNotificationTeamName(teamName) != nil else {
            return legacyCardNotificationBody(
                cardType: cardType,
                minuteText: minuteText,
                playerName: playerName,
                teamName: teamName
            )
        }

        let player = playerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !player.isEmpty {
            return playerMatchEventBody(
                playerName: player,
                minuteText: nil,
                awayTeam: awayTeam,
                homeTeam: homeTeam
            )
        }

        let matchup = matchupTitle(awayTeam: awayTeam, homeTeam: homeTeam)
        if !matchup.isEmpty {
            return matchup
        }

        return legacyCardNotificationBody(
            cardType: cardType,
            minuteText: minuteText,
            playerName: playerName,
            teamName: teamName
        )
    }

    private static func legacyCardNotificationBody(
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

    private static func cardEventDisplayTitle(_ cardType: LiveCardEventType) -> String {
        switch cardType {
        case .yellow:
            return "Yellow Card"
        case .red, .secondYellow:
            return "Red Card"
        }
    }

    private static func resolvedNotificationTeamName(_ raw: String?) -> String? {
        let cleaned = ProGameTeamScoreIdentity.cleanTeamName(raw ?? "")
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func normalizedCardNotificationClock(_ minuteText: String?) -> String {
        normalizedGoalMinute(minuteText) ?? "?"
    }

    private static func normalizedGoalMinute(_ minuteText: String?) -> String? {
        let trimmed = minuteText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("'") || trimmed.hasSuffix("’") {
            return trimmed.replacingOccurrences(of: "’", with: "'")
        }
        if trimmed.contains(":") || trimmed.range(of: #"\d(?:st|nd|rd|th)\b"#, options: .regularExpression) != nil {
            return trimmed
        }
        return "\(trimmed)'"
    }

    private static func normalizedTeamToken(_ value: String) -> String {
        ProGameTeamScoreIdentity.cleanTeamName(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
