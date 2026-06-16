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

    static func normalized(from raw: String?) -> MatchStatus {
        let status = normalizedStatusText(raw)
        guard !status.isEmpty else { return .scheduled }

        if status == "HT" || status == "HALF TIME" || status == "HALFTIME" {
            return .halfTime
        }

        if isFinalStatusText(status)
            || status.contains("FINAL")
            || status.contains("FINISHED")
            || status.contains("COMPLETED")
            || status.contains("COMPLETE")
            || status.contains("ENDED")
            || status.contains("FULL TIME")
            || status.contains("FULL_TIME")
            || status.contains("MATCH FINISHED")
            || status.contains("AFTER FULL TIME") {
            return .fullTime
        }

        if liveStatusTokens.contains(status)
            || status.contains("LIVE")
            || status.contains("IN PROGRESS")
            || status.contains("IN PLAY")
            || status.contains("PLAYING")
            || status.contains("ACTIVE")
            || status.contains("STARTED")
            || status.contains("EXTRA INNING")
            || status.contains("'")
            || status.contains("Q")
            || status.contains("PERIOD")
            || status.contains("INNING") {
            return .live
        }

        if scheduledStatusTokens.contains(status)
            || status.contains("SCHED")
            || status.contains("NOT STARTED") {
            return .scheduled
        }

        return .scheduled
    }

    private static let finalStatusTokens: Set<String> = [
        "FT",
        "FINAL",
        "FINAL TIME",
        "FULL TIME",
        "FULL_TIME",
        "FULLTIME",
        "COMPLETED",
        "COMPLETE",
        "FINISHED",
        "MATCH FINISHED",
        "MATCH_FINISHED",
        "AET",
        "PEN",
        "AFTER FULL TIME",
        "AFTER_FULL_TIME",
        "AFTER EXTRA TIME",
        "AFTER_EXTRA_TIME",
        "PENALTIES FINISHED",
        "PENALTIES_FINISHED",
        "AFTER PENALTIES",
        "ENDED",
        "END",
        "GAME OVER"
    ]

    private static let finalStatusLeadingTokens: Set<String> = [
        "FT",
        "FINAL",
        "FULLTIME",
        "COMPLETED",
        "COMPLETE",
        "ENDED",
        "FINISHED"
    ]

    private static let liveStatusTokens: Set<String> = [
        "LIVE",
        "1H",
        "2H",
        "ET",
        "BT",
        "P",
        "OT",
        "Q1",
        "Q2",
        "Q3",
        "Q4"
    ]

    private static let scheduledStatusTokens: Set<String> = [
        "NS",
        "TBD",
        "SCHEDULED",
        "POSTPONED",
        "DELAYED"
    ]

    private static func normalizedStatusText(_ raw: String?) -> String {
        let folded = (raw ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .uppercased()
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func isFinalStatusText(_ status: String) -> Bool {
        if finalStatusTokens.contains(status) { return true }
        guard let firstToken = status.split(separator: " ").first.map(String.init) else { return false }
        return finalStatusLeadingTokens.contains(firstToken)
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

nonisolated struct LiveLatestScoringEvent: Equatable {
    let displayText: String
    let eventSummary: String
    let scorer: String?
    let gameClock: String?
}

nonisolated struct LiveScoringEventResolution: Equatable {
    let latestEvent: LiveLatestScoringEvent?
    let fallbackReason: String?
}

nonisolated enum LiveScoringEventResolver {
    static func resolve(
        sportType: LiveSportVisualType,
        timelineEvents: [LiveTimelineEvent]
    ) -> LiveScoringEventResolution {
        guard !timelineEvents.isEmpty else {
            return LiveScoringEventResolution(latestEvent: nil, fallbackReason: "noTimelineEvents")
        }

        let indexedEvents = timelineEvents.enumerated()
        let candidates = indexedEvents.compactMap { index, event -> (index: Int, event: LiveTimelineEvent, scoringEvent: LiveLatestScoringEvent)? in
            guard let scoringEvent = scoringEvent(for: event, sportType: sportType) else { return nil }
            return (index, event, scoringEvent)
        }

        guard let latest = candidates.max(by: { lhs, rhs in
            let leftMinute = lhs.event.minuteValue ?? Int.min
            let rightMinute = rhs.event.minuteValue ?? Int.min
            if leftMinute != rightMinute { return leftMinute < rightMinute }
            return lhs.index < rhs.index
        }) else {
            return LiveScoringEventResolution(
                latestEvent: nil,
                fallbackReason: sportType == .basketball ? "basketballNoMeaningfulScoringSummary" : "noScoringEvent"
            )
        }

        return LiveScoringEventResolution(latestEvent: latest.scoringEvent, fallbackReason: nil)
    }

    private static func scoringEvent(
        for event: LiveTimelineEvent,
        sportType: LiveSportVisualType
    ) -> LiveLatestScoringEvent? {
        switch sportType {
        case .soccer:
            return soccerGoalEvent(event)
        case .hockey:
            return hockeyGoalEvent(event)
        case .nfl:
            return summaryScoringEvent(event, icon: "🏈")
        case .baseball:
            return summaryScoringEvent(event, icon: "⚾")
        case .basketball:
            guard meaningfulBasketballScoringSummary(event) else { return nil }
            return summaryScoringEvent(event, icon: "🏀", requiresScoringKeyword: false)
        default:
            return nil
        }
    }

    private static func soccerGoalEvent(_ event: LiveTimelineEvent) -> LiveLatestScoringEvent? {
        guard event.isGoal else { return nil }
        let scorer = event.playerDisplayName
        guard let scorer else { return nil }
        let clock = soccerMinuteText(for: event)
        let displayText = [scorer, clock].compactMap { $0 }.joined(separator: " ")
        return LiveLatestScoringEvent(
            displayText: "⚽ Goal: \(displayText)",
            eventSummary: eventSummary(for: event) ?? "Goal",
            scorer: scorer,
            gameClock: clock
        )
    }

    private static func hockeyGoalEvent(_ event: LiveTimelineEvent) -> LiveLatestScoringEvent? {
        guard event.isGoal else { return nil }
        let scorer = event.playerDisplayName
        guard let scorer else { return nil }
        let clock = hockeyClockText(for: event)
        let suffix = clock.map { " · \($0)" } ?? ""
        return LiveLatestScoringEvent(
            displayText: "🏒 Goal: \(scorer)\(suffix)",
            eventSummary: eventSummary(for: event) ?? "Goal",
            scorer: scorer,
            gameClock: clock
        )
    }

    private static func summaryScoringEvent(
        _ event: LiveTimelineEvent,
        icon: String,
        requiresScoringKeyword: Bool = true
    ) -> LiveLatestScoringEvent? {
        guard !requiresScoringKeyword || isScoringSummary(event) else { return nil }
        guard let summary = eventSummary(for: event) else { return nil }
        let clock = footballBaseballClockText(for: event)
        let displayText = [summary, clock.map { "· \($0)" }].compactMap { $0 }.joined(separator: " ")
        return LiveLatestScoringEvent(
            displayText: "\(icon) \(displayText)",
            eventSummary: summary,
            scorer: event.playerDisplayName,
            gameClock: clock
        )
    }

    private static func isScoringSummary(_ event: LiveTimelineEvent) -> Bool {
        let text = searchableText(for: event)
        let scoringTerms = [
            "goal",
            "touchdown",
            "field goal",
            "extra point",
            "two point",
            "2 point",
            "safety",
            "home run",
            "grand slam",
            "rbi",
            "scores",
            "scored",
            "sacrifice fly"
        ]
        return scoringTerms.contains { text.contains($0) }
    }

    private static func meaningfulBasketballScoringSummary(_ event: LiveTimelineEvent) -> Bool {
        let text = searchableText(for: event)
        let meaningfulTerms = [
            "buzzer",
            "game winner",
            "go ahead",
            "go-ahead",
            "lead change",
            "ties the game",
            "run",
            "milestone",
            "end of quarter",
            "end of period"
        ]
        return meaningfulTerms.contains { text.contains($0) }
    }

    private static func eventSummary(for event: LiveTimelineEvent) -> String? {
        [
            event.strComment,
            event.strTimelineDetail,
            event.strTimeline
        ]
            .compactMap(clean)
            .first { !$0.isEmpty && !["goal", "score"].contains($0.lowercased()) }
            ?? event.playerDisplayName
    }

    private static func soccerMinuteText(for event: LiveTimelineEvent) -> String? {
        if let minute = event.minuteValue, minute >= 0 {
            return "\(minute)'"
        }
        return firstMinuteText(in: searchableTextPreservingPunctuation(for: event))
    }

    private static func hockeyClockText(for event: LiveTimelineEvent) -> String? {
        let text = searchableTextPreservingPunctuation(for: event)
        let period = firstPeriodText(in: text)
        let clock = firstClockText(in: text)
        switch (period, clock) {
        case let (period?, clock?):
            return "\(period) \(clock)"
        case let (period?, nil):
            return period
        case let (nil, clock?):
            return clock
        case (nil, nil):
            return nil
        }
    }

    private static func footballBaseballClockText(for event: LiveTimelineEvent) -> String? {
        let text = searchableTextPreservingPunctuation(for: event)
        if let period = firstPeriodText(in: text), let clock = firstClockText(in: text) {
            return "\(period) \(clock)"
        }
        return firstPeriodText(in: text) ?? firstClockText(in: text) ?? soccerMinuteText(for: event)
    }

    private static func firstMinuteText(in text: String) -> String? {
        guard let match = text.range(of: #"(?<!\d)(\d{1,3})\s*['’]"#, options: .regularExpression) else {
            return nil
        }
        let raw = String(text[match])
        let minute = raw.filter(\.isNumber)
        return minute.isEmpty ? nil : "\(minute)'"
    }

    private static func firstClockText(in text: String) -> String? {
        guard let match = text.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) else {
            return nil
        }
        return String(text[match])
    }

    private static func firstPeriodText(in text: String) -> String? {
        let patterns = [
            #"\b(1st|2nd|3rd|4th|5th)\b"#,
            #"\b(?:period|per|p)\s*(\d)\b"#,
            #"\b(?:quarter|q)\s*(\d)\b"#,
            #"\b(?:inning|inn)\s*(\d+)\b"#
        ]
        for pattern in patterns {
            guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
                continue
            }
            let raw = String(text[match]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let digit = raw.first(where: \.isNumber) {
                return ordinalPeriodText(for: digit)
            }
            return raw
        }
        return nil
    }

    private static func ordinalPeriodText(for digit: Character) -> String {
        switch digit {
        case "1": return "1st"
        case "2": return "2nd"
        case "3": return "3rd"
        default: return "\(digit)th"
        }
    }

    private static func searchableText(for event: LiveTimelineEvent) -> String {
        searchableTextPreservingPunctuation(for: event)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func searchableTextPreservingPunctuation(for event: LiveTimelineEvent) -> String {
        [
            event.strTimeline,
            event.strTimelineDetail,
            event.strComment,
            event.strPlayer,
            event.strTeam,
            event.intTime
        ]
            .compactMap(clean)
            .joined(separator: " ")
    }

    private static func clean(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated struct LiveScoringTimelineEntry: Equatable {
    let teamName: String?
    let scorer: String
    let clock: String?
    let marker: String?

    var scorerClockText: String {
        var parts = [scorer]
        if let marker, !marker.isEmpty {
            parts.append(marker)
        }
        if let clock, !clock.isEmpty {
            parts.append(clock)
        }
        return parts.joined(separator: " ")
    }

    func timelineLineText(showTeamMarker: Bool) -> String {
        var parts: [String] = []
        if let clock, !clock.isEmpty {
            parts.append(clock)
        }

        var scorerLabel = scorer
        if let marker, !marker.isEmpty {
            scorerLabel += " \(marker)"
        }
        parts.append(scorerLabel)

        var line = parts.joined(separator: " ")
        if showTeamMarker,
           let teamName = teamName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !teamName.isEmpty,
           let flag = CountryFlagHelper.flag(for: teamName, source: "GoingPro"),
           !flag.isEmpty {
            line += " \(flag)"
        }
        return line
    }
}

nonisolated struct LiveScoringTimelineDisplayLine: Equatable {
    let text: String
}

nonisolated struct LiveScoringTimelineSummary: Equatable {
    let sportIcon: String
    let entries: [LiveScoringTimelineEntry]

    static let defaultMaxVisibleTimelineLines = 4

    var hasContent: Bool { !entries.isEmpty }

    var headingText: String { "\(sportIcon) Goals" }

    var goalScorersHeadingText: String { "🥅 Goal Scorers" }

    var compactDisplayText: String {
        entries.map(\.scorerClockText).joined(separator: " · ")
    }

    func timelineDisplay(
        homeTeam: String,
        awayTeam: String,
        maxVisible: Int = Self.defaultMaxVisibleTimelineLines
    ) -> (lines: [LiveScoringTimelineDisplayLine], overflowCount: Int) {
        let showTeamMarkers = shouldShowTeamMarkers()
        let allLines = entries.map { entry in
            LiveScoringTimelineDisplayLine(
                text: entry.timelineLineText(showTeamMarker: showTeamMarkers)
            )
        }
        guard allLines.count > maxVisible else {
            return (allLines, 0)
        }
        return (Array(allLines.prefix(maxVisible)), allLines.count - maxVisible)
    }

    func renderedTimelineSummaryText(
        homeTeam: String,
        awayTeam: String,
        maxVisible: Int = Self.defaultMaxVisibleTimelineLines
    ) -> String {
        let display = timelineDisplay(homeTeam: homeTeam, awayTeam: awayTeam, maxVisible: maxVisible)
        guard !display.lines.isEmpty else { return "none" }
        var parts = display.lines.map(\.text)
        if display.overflowCount > 0 {
            parts.append("+\(display.overflowCount) more goals")
        }
        return parts.joined(separator: " | ")
    }

    private func shouldShowTeamMarkers() -> Bool {
        let teams = Set(
            entries.compactMap { entry -> String? in
                guard let team = entry.teamName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !team.isEmpty else {
                    return nil
                }
                return LiveMatchFilters.normalizedSearchText(team)
            }
            .filter { !$0.isEmpty }
        )
        return teams.count >= 2
    }

    func teamGroupedLines(homeTeam: String, awayTeam: String) -> [String] {
        var grouped: [String: [String]] = [:]
        var teamOrder: [String] = []

        for entry in entries {
            let team = entry.teamName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = (team?.isEmpty == false ? team! : "Goals")
            if grouped[key] == nil {
                teamOrder.append(key)
                grouped[key] = []
            }
            grouped[key, default: []].append(entry.scorerClockText)
        }

        if teamOrder.count <= 1,
           teamOrder.first == "Goals" || teamOrder.isEmpty {
            return []
        }

        return teamOrder.map { team in
            let scorers = grouped[team]?.joined(separator: ", ") ?? ""
            return "\(team): \(scorers)"
        }
    }

    func shouldUseTeamGroupedLayout(homeTeam: String, awayTeam: String) -> Bool {
        !teamGroupedLines(homeTeam: homeTeam, awayTeam: awayTeam).isEmpty
    }
}

nonisolated enum LiveScoringTimelineBuilder {
    static func build(
        sportType: LiveSportVisualType,
        timelineEvents: [LiveTimelineEvent],
        homeTeam: String,
        awayTeam: String
    ) -> LiveScoringTimelineSummary? {
        let effectiveSportType = resolvedSportType(for: sportType, timelineEvents: timelineEvents)
        guard effectiveSportType == .soccer || effectiveSportType == .hockey else { return nil }
        guard !timelineEvents.isEmpty else { return nil }

        let sortedEvents = timelineEvents.sorted { lhs, rhs in
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

        let rawEntries = sortedEvents.compactMap { event -> LiveScoringTimelineEntry? in
            guard isScoringEvent(event, sportType: effectiveSportType) else { return nil }
            guard let scorer = event.playerDisplayName ?? fallbackScorerName(for: event) else { return nil }
            let clock = scoringClock(for: event, sportType: effectiveSportType)
            if effectiveSportType == .soccer || effectiveSportType == .hockey, clock == nil {
                return nil
            }
            return LiveScoringTimelineEntry(
                teamName: scoringTeamName(for: event, homeTeam: homeTeam, awayTeam: awayTeam),
                scorer: scorer,
                clock: clock,
                marker: effectiveSportType == .soccer ? soccerMarker(for: event) : nil
            )
        }

        let entries = deduplicatedScoringEntries(rawEntries)

        guard !entries.isEmpty else { return nil }
        return LiveScoringTimelineSummary(
            sportIcon: effectiveSportType == .hockey ? "🏒" : "⚽",
            entries: entries
        )
    }

    static func deduplicatedScoringEntries(_ entries: [LiveScoringTimelineEntry]) -> [LiveScoringTimelineEntry] {
        var seenKeys = [String: Int]()
        var deduped: [LiveScoringTimelineEntry] = []

        for entry in entries {
            let key = scoringEntryDedupeKey(entry)
            if let existingIndex = seenKeys[key] {
                deduped[existingIndex] = mergedScoringEntry(deduped[existingIndex], entry)
                continue
            }
            seenKeys[key] = deduped.count
            deduped.append(entry)
        }

        return deduped
    }

    private static func scoringEntryDedupeKey(_ entry: LiveScoringTimelineEntry) -> String {
        let team = normalizedTeamText(entry.teamName ?? "")
        let player = normalizedTeamText(entry.scorer)
        let minute = normalizedMinuteKey(entry.clock)
        return "\(team)|\(player)|\(minute)"
    }

    private static func normalizedMinuteKey(_ clock: String?) -> String {
        guard let clock else { return "" }
        let digits = clock.filter(\.isNumber)
        return digits.isEmpty ? normalizedTeamText(clock) : digits
    }

    private static func mergedScoringEntry(
        _ existing: LiveScoringTimelineEntry,
        _ duplicate: LiveScoringTimelineEntry
    ) -> LiveScoringTimelineEntry {
        LiveScoringTimelineEntry(
            teamName: existing.teamName ?? duplicate.teamName,
            scorer: existing.scorer,
            clock: existing.clock ?? duplicate.clock,
            marker: existing.marker ?? duplicate.marker
        )
    }

    private static func resolvedSportType(
        for sportType: LiveSportVisualType,
        timelineEvents: [LiveTimelineEvent]
    ) -> LiveSportVisualType {
        if sportType == .soccer || sportType == .hockey {
            return sportType
        }
        if timelineEvents.contains(where: \.isGoal) {
            return .soccer
        }
        return sportType
    }

    static func resolvedSportTypeForDebug(
        sportType: LiveSportVisualType,
        timelineEvents: [LiveTimelineEvent]
    ) -> LiveSportVisualType {
        resolvedSportType(for: sportType, timelineEvents: timelineEvents)
    }

    static func debugTeamName(
        for event: LiveTimelineEvent,
        homeTeam: String,
        awayTeam: String
    ) -> String? {
        scoringTeamName(for: event, homeTeam: homeTeam, awayTeam: awayTeam)
    }

    private static func fallbackScorerName(for event: LiveTimelineEvent) -> String? {
        let team = event.strTeam?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return team.isEmpty ? nil : team
    }

    private static func isScoringEvent(_ event: LiveTimelineEvent, sportType: LiveSportVisualType) -> Bool {
        let text = searchableText(for: event)
        if text.contains("miss") || text.contains("saved") { return false }
        switch sportType {
        case .soccer:
            return event.isGoal || text.contains("penalty")
        case .hockey:
            return event.isGoal
        default:
            return false
        }
    }

    private static func scoringTeamName(
        for event: LiveTimelineEvent,
        homeTeam: String,
        awayTeam: String
    ) -> String? {
        let homeFlag = event.strHome?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if ["yes", "true", "1", "home"].contains(homeFlag) { return homeTeam }
        if ["no", "false", "0", "away"].contains(homeFlag) { return awayTeam }

        guard let team = event.strTeam?.trimmingCharacters(in: .whitespacesAndNewlines),
              !team.isEmpty else {
            return nil
        }

        let normalizedTeam = normalizedTeamText(team)
        if normalizedTeam == normalizedTeamText(homeTeam) { return homeTeam }
        if normalizedTeam == normalizedTeamText(awayTeam) { return awayTeam }
        return team
    }

    private static func soccerMarker(for event: LiveTimelineEvent) -> String? {
        let text = searchableText(for: event)
        if text.contains("own goal") { return "(OG)" }
        if text.contains("penalty") { return "(P)" }
        return nil
    }

    private static func scoringClock(
        for event: LiveTimelineEvent,
        sportType: LiveSportVisualType
    ) -> String? {
        switch sportType {
        case .soccer:
            if let minute = event.minuteValue, minute >= 0 {
                return "\(minute)'"
            }
            return firstMinuteText(in: searchableTextPreservingPunctuation(for: event))
        case .hockey:
            return hockeyClockText(for: event)
        default:
            return nil
        }
    }

    private static func hockeyClockText(for event: LiveTimelineEvent) -> String? {
        let text = searchableTextPreservingPunctuation(for: event)
        let period = firstPeriodText(in: text)
        let clock = firstClockText(in: text)
        switch (period, clock) {
        case let (period?, clock?):
            return "\(period) \(clock)"
        case let (period?, nil):
            return period
        case let (nil, clock?):
            return clock
        case (nil, nil):
            return nil
        }
    }

    private static func firstMinuteText(in text: String) -> String? {
        guard let match = text.range(of: #"(?<!\d)(\d{1,3})\s*['’]"#, options: .regularExpression) else {
            return nil
        }
        let raw = String(text[match])
        let minute = raw.filter(\.isNumber)
        return minute.isEmpty ? nil : "\(minute)'"
    }

    private static func firstClockText(in text: String) -> String? {
        guard let match = text.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) else {
            return nil
        }
        return String(text[match])
    }

    private static func firstPeriodText(in text: String) -> String? {
        let patterns = [
            #"\b(1st|2nd|3rd|4th|5th)\b"#,
            #"\b(?:period|per|p)\s*(\d)\b"#,
            #"\b(?:quarter|q)\s*(\d)\b"#,
            #"\b(?:inning|inn)\s*(\d+)\b"#
        ]
        for pattern in patterns {
            guard let match = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
                continue
            }
            let raw = String(text[match]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let digit = raw.first(where: \.isNumber) {
                return ordinalPeriodText(for: digit)
            }
            return raw
        }
        return nil
    }

    private static func ordinalPeriodText(for digit: Character) -> String {
        switch digit {
        case "1": return "1st"
        case "2": return "2nd"
        case "3": return "3rd"
        default: return "\(digit)th"
        }
    }

    private static func normalizedTeamText(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func searchableText(for event: LiveTimelineEvent) -> String {
        searchableTextPreservingPunctuation(for: event)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func searchableTextPreservingPunctuation(for event: LiveTimelineEvent) -> String {
        [
            event.strTimeline,
            event.strTimelineDetail,
            event.strComment,
            event.strPlayer,
            event.strTeam,
            event.intTime
        ]
            .compactMap(clean)
            .joined(separator: " ")
    }

    private static func clean(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if DEBUG
nonisolated enum ScoringTimelineDebug {
    static func log(
        gameId: String,
        scoreHome: Int,
        scoreAway: Int,
        homeTeam: String,
        awayTeam: String,
        sportType: LiveSportVisualType,
        timelineEvents: [LiveTimelineEvent]
    ) {
        let effectiveSportType = LiveScoringTimelineBuilder.resolvedSportTypeForDebug(
            sportType: sportType,
            timelineEvents: timelineEvents
        )
        let rawGoalEvents = timelineEvents.filter { event in
            isRawGoalEvent(event, sportType: effectiveSportType)
        }
        let summary = LiveScoringTimelineBuilder.build(
            sportType: sportType,
            timelineEvents: timelineEvents,
            homeTeam: homeTeam,
            awayTeam: awayTeam
        )
        let goalEventCount = summary?.entries.count ?? 0
        let scoreTotal = scoreHome + scoreAway
        let duplicatesRemoved = max(0, rawGoalEvents.count - goalEventCount)

        print("[ScoringTimelineDebug] gameId=\(gameId)")
        print("[ScoringTimelineDebug] scoreHome=\(scoreHome)")
        print("[ScoringTimelineDebug] scoreAway=\(scoreAway)")
        print("[ScoringTimelineDebug] timelineCount=\(timelineEvents.count)")
        print("[ScoringTimelineDebug] goalEventCount=\(goalEventCount)")
        print("[ScoringTimelineDebug] scoreTotal=\(scoreTotal)")
        print("[ScoringTimelineDebug] renderedGoalCount=\(goalEventCount)")
        if duplicatesRemoved > 0 || goalEventCount > scoreTotal {
            print("[ScoringTimelineDebug] duplicateRemoved=true")
        }
        if duplicatesRemoved > 0 {
            print("[ScoringTimelineDebug] duplicatesRemoved=\(duplicatesRemoved)")
        }

        for event in rawGoalEvents {
            let team = LiveScoringTimelineBuilder.debugTeamName(
                for: event,
                homeTeam: homeTeam,
                awayTeam: awayTeam
            ) ?? event.strTeam ?? "unknown"
            print(
                "[ScoringTimelineDebug] player=\(event.playerDisplayName ?? "unknown") " +
                "minute=\(event.intTime ?? event.minuteText ?? "unknown") " +
                "team=\(team) " +
                "eventType=\(event.typeText)"
            )
        }

        for entry in summary?.entries ?? [] {
            print(
                "[ScoringTimelineDebug] rendered player=\(entry.scorer) " +
                "minute=\(entry.clock ?? "unknown") " +
                "team=\(entry.teamName ?? "unknown")"
            )
        }
    }

    private static func isRawGoalEvent(_ event: LiveTimelineEvent, sportType: LiveSportVisualType) -> Bool {
        let text = [
            event.strTimeline,
            event.strTimelineDetail,
            event.strComment
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        if text.contains("miss") || text.contains("saved") { return false }
        switch sportType {
        case .soccer:
            return event.isGoal || text.contains("penalty")
        case .hockey:
            return event.isGoal
        default:
            return event.isGoal
        }
    }
}
#endif

#if DEBUG
nonisolated enum LiveScoringEventDebug {
    static func log(
        gameId: String,
        eventId: String?,
        sport: String,
        sportType: LiveSportVisualType,
        homeTeam: String,
        awayTeam: String,
        timelineEvents: [LiveTimelineEvent],
        timelineFetched: Bool
    ) {
        let effectiveSportType = LiveScoringTimelineBuilder.resolvedSportTypeForDebug(
            sportType: sportType,
            timelineEvents: timelineEvents
        )
        let timelineCount = timelineEvents.count
        let summary = LiveScoringTimelineBuilder.build(
            sportType: sportType,
            timelineEvents: timelineEvents,
            homeTeam: homeTeam,
            awayTeam: awayTeam
        )
        let scoringEventsCount = summary?.entries.count ?? 0
        let renderedSummary = renderedSummaryText(
            summary: summary,
            homeTeam: homeTeam,
            awayTeam: awayTeam
        )
        let fallbackReason = fallbackReason(
            timelineCount: timelineCount,
            scoringEventsCount: scoringEventsCount,
            sportType: sportType,
            effectiveSportType: effectiveSportType,
            timelineEvents: timelineEvents
        )

        print("[LiveScoringEventDebug] gameId=\(gameId)")
        print("[LiveScoringEventDebug] timelineCount=\(timelineCount)")
        print("[LiveScoringEventDebug] scoringEventsCount=\(scoringEventsCount)")
        print("[LiveScoringEventDebug] renderedSummary=\(renderedSummary)")
        print("[LiveScoringEventDebug] fallbackReason=\(fallbackReason)")
        if timelineCount > 0, scoringEventsCount == 0 {
            print("[LiveScoringEventDebug] noGoalReason=\(noGoalReason(timelineEvents: timelineEvents, sportType: sportType))")
        }

        let providerEventId = providerEventIdUsedForTimeline(gameId: gameId, externalId: eventId)
        print("[ScoringEventDebug] provider=TheSportsDB")
        print("[ScoringEventDebug] savedGameId=\(gameId)")
        print("[ScoringEventDebug] liveMatchExternalId=\(eventId ?? "nil")")
        print("[ScoringEventDebug] providerEventIdUsedForTimeline=\(providerEventId ?? "nil")")
        print("[ScoringEventDebug] eventId=\(providerEventId ?? eventId ?? "nil")")
        print("[ScoringEventDebug] timelineFetched=\(timelineFetched)")
        print("[ScoringEventDebug] timelineCount=\(timelineCount)")
        print("[ScoringEventDebug] rawSample=\(rawSample(from: timelineEvents))")
        print("[ScoringEventDebug] scoringEventsCount=\(scoringEventsCount)")
        print("[ScoringEventDebug] fallbackReason=\(fallbackReason)")
        print("[ScoringEventDebug] sport=\(sport)")
        if let latest = summary?.entries.last {
            print("[ScoringEventDebug] scorer=\(latest.scorer)")
            print("[ScoringEventDebug] team=\(latest.teamName ?? "nil")")
            print("[ScoringEventDebug] minuteOrClock=\(latest.clock ?? "nil")")
        }
    }

    private static func renderedSummaryText(
        summary: LiveScoringTimelineSummary?,
        homeTeam: String,
        awayTeam: String
    ) -> String {
        guard let summary, summary.hasContent else { return "none" }
        return summary.renderedTimelineSummaryText(homeTeam: homeTeam, awayTeam: awayTeam)
    }

    private static func fallbackReason(
        timelineCount: Int,
        scoringEventsCount: Int,
        sportType: LiveSportVisualType,
        effectiveSportType: LiveSportVisualType,
        timelineEvents: [LiveTimelineEvent]
    ) -> String {
        if timelineCount == 0 {
            return "providerTimelineMissing"
        }
        if scoringEventsCount == 0 {
            if sportType != .soccer && sportType != .hockey && effectiveSportType != .soccer {
                return "unsupportedSportForScoring"
            }
            return noGoalReason(timelineEvents: timelineEvents, sportType: sportType)
        }
        return "none"
    }

    private static func noGoalReason(
        timelineEvents: [LiveTimelineEvent],
        sportType: LiveSportVisualType
    ) -> String {
        let rowTypes = Array(Set(timelineEvents.map(\.typeText)))
        let hasGoalText = timelineEvents.contains(where: \.isGoal)
        if hasGoalText {
            return "parserMissedGoalRows"
        }
        if rowTypes.allSatisfy({ type in
            let normalized = type.lowercased()
            return normalized.contains("subst") || normalized.contains("card")
        }) {
            return "nonGoalRowsOnly types=\(rowTypes.joined(separator: ","))"
        }
        return "noScoringSummary sport=\(sportType.rawValue) types=\(rowTypes.joined(separator: ","))"
    }

    private static func providerEventIdUsedForTimeline(gameId: String, externalId: String?) -> String? {
        let lowered = gameId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.hasPrefix("thesportsdb:") {
            let providerId = gameId.split(separator: ":").last.map(String.init) ?? ""
            if !providerId.isEmpty { return providerId }
        }
        let cleanedExternalId = externalId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleanedExternalId.isEmpty ? nil : cleanedExternalId
    }

    private static func rawSample(from events: [LiveTimelineEvent]) -> String {
        let scoring = events.first(where: { event in
            let text = "\(event.strTimeline ?? "") \(event.strTimelineDetail ?? "")".lowercased()
            return text.contains("goal")
        })
        let sample = scoring ?? events.first
        guard let sample else { return "null" }
        guard let data = try? JSONEncoder().encode(sample),
              let json = String(data: data, encoding: .utf8) else {
            return sample.id
        }
        return String(json.prefix(900))
    }
}
#endif

nonisolated enum LiveLeagueCountryResolver {
    static let presetCountries = [
        "Australia",
        "Canada",
        "England",
        "France",
        "Germany",
        "Italy",
        "Japan",
        "Mexico",
        "Spain",
        "United States"
    ]

    static func country(for league: String) -> String? {
        let normalized = normalizedLeagueText(league)
        guard !normalized.isEmpty else { return nil }

        let fallbackRules: [(country: String, fragments: [String])] = [
            ("Japan", ["japanese j1 league", "j1 league", "japanese j2 league", "j2 league"]),
            ("Australia", ["nbl1 central", "nbl1 east", "nbl1 north", "nbl1 south", "nbl1 west"]),
            ("United States", ["mls", "major league soccer", "nba", "mlb", "nhl", "nfl", "wnba", "usl"]),
            ("Mexico", ["liga mx"]),
            ("England", ["premier league", "english premier league"]),
            ("France", ["ligue 1", "french ligue 1"]),
            ("Spain", ["la liga", "spanish la liga"]),
            ("Germany", ["bundesliga", "german bundesliga"]),
            ("Italy", ["serie a", "italian serie a"])
        ]

        for rule in fallbackRules where rule.fragments.contains(where: { normalized.contains($0) }) {
            return rule.country
        }
        return nil
    }

    static func normalizedCountry(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }

        let lowercased = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
        switch lowercased {
        case "usa", "us", "u.s.", "u.s.a.", "united states of america":
            return "United States"
        case "uk", "eng", "england":
            return "England"
        default:
            return value
                .split(separator: " ")
                .map { word in
                    let lower = word.lowercased()
                    return lower.prefix(1).uppercased() + String(lower.dropFirst())
                }
                .joined(separator: " ")
        }
    }

    private static func normalizedLeagueText(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

nonisolated enum LiveLeagueCountryFilterPreference {
    static let appStorageKey = "liveLeagueCountryFilterSelection.v1"

    static func decode(from raw: String) -> Set<String> {
        Set(
            raw.split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    static func encode(_ countries: Set<String>) -> String {
        countries.sorted().joined(separator: "\n")
    }
}

nonisolated struct FeaturedEvent: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let slug: String
    let title: String
    let shortTitle: String?
    let icon: String?
    let sport: String?
    let includeKeywords: [String]
    let excludeKeywords: [String]
    let startDate: Date
    let endDate: Date
    let enabled: Bool
    let priority: Int

    var chipTitle: String {
        let label = (shortTitle ?? title).trimmingCharacters(in: .whitespacesAndNewlines)
        let symbol = icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if symbol.isEmpty { return label }
        return "\(symbol) \(label)"
    }

    var emptyStateTitle: String {
        isFifaWorldCupDefinition ? "FIFA World Cup" : title
    }

    var isFifaWorldCupDefinition: Bool {
        let normalizedSlug = LiveMatchFilters.normalizedSearchText(slug)
        let normalizedTitle = LiveMatchFilters.normalizedSearchText(title)
        let normalizedShortTitle = shortTitle.map(LiveMatchFilters.normalizedSearchText) ?? ""
        return [normalizedSlug, normalizedTitle, normalizedShortTitle].contains { value in
            value.contains("fifa") && (value.contains("world cup") || value.contains("wc"))
        }
    }

    static let fallbackFIFAWorldCup = FeaturedEvent(
        id: "fallback-fifa-world-cup",
        slug: "fifa-world-cup",
        title: "FIFA World Cup",
        shortTitle: "FIFA WC",
        icon: "🏆",
        sport: "Soccer",
        includeKeywords: [
            "fifa world cup",
            "fifa world cup qualifiers",
            "fifa world cup qualification",
            "fifa club world cup",
            "fifa women s world cup",
            "women s fifa world cup",
            "world cup qualifiers",
            "world cup qualification"
        ],
        excludeKeywords: [
            "fiba",
            "basketball world cup",
            "cricket world cup",
            "icc world cup",
            "t20 world cup",
            "rugby world cup",
            "hockey world cup",
            "american football",
            "nfl",
            "gridiron",
            "us football"
        ],
        startDate: .distantPast,
        endDate: .distantFuture,
        enabled: true,
        priority: Int.max
    )

    static let fallbackEvents = [fallbackFIFAWorldCup]

    enum CodingKeys: String, CodingKey {
        case id
        case slug
        case title
        case shortTitle = "short_title"
        case icon
        case sport
        case includeKeywords = "include_keywords"
        case excludeKeywords = "exclude_keywords"
        case startDate = "start_date"
        case endDate = "end_date"
        case enabled
        case priority
    }

    init(
        id: String,
        slug: String,
        title: String,
        shortTitle: String?,
        icon: String?,
        sport: String?,
        includeKeywords: [String],
        excludeKeywords: [String],
        startDate: Date,
        endDate: Date,
        enabled: Bool,
        priority: Int
    ) {
        self.id = id
        self.slug = slug
        self.title = title
        self.shortTitle = shortTitle
        self.icon = icon
        self.sport = sport
        self.includeKeywords = includeKeywords
        self.excludeKeywords = excludeKeywords
        self.startDate = startDate
        self.endDate = endDate
        self.enabled = enabled
        self.priority = priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleString(forKey: .id)
        slug = try container.decodeFlexibleString(forKey: .slug)
        title = try container.decodeFlexibleString(forKey: .title)
        shortTitle = try container.decodeFlexibleOptionalString(forKey: .shortTitle)
        icon = try container.decodeFlexibleOptionalString(forKey: .icon)
        sport = try container.decodeFlexibleOptionalString(forKey: .sport)
        includeKeywords = try container.decodeStringArrayIfPresent(forKey: .includeKeywords) ?? []
        excludeKeywords = try container.decodeStringArrayIfPresent(forKey: .excludeKeywords) ?? []
        startDate = try container.decodeFlexibleDate(forKey: .startDate)
        endDate = try container.decodeFlexibleDate(forKey: .endDate)
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? true
        priority = (try? container.decode(Int.self, forKey: .priority)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(slug, forKey: .slug)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(shortTitle, forKey: .shortTitle)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(sport, forKey: .sport)
        try container.encode(includeKeywords, forKey: .includeKeywords)
        try container.encode(excludeKeywords, forKey: .excludeKeywords)
        try container.encode(Self.dateOnlyFormatter.string(from: startDate), forKey: .startDate)
        try container.encode(Self.dateOnlyFormatter.string(from: endDate), forKey: .endDate)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(priority, forKey: .priority)
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    fileprivate static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = dateOnlyFormatter.date(from: trimmed) {
            return date
        }
        return SupabaseTimestampParsing.parseTimestamptz(trimmed)
    }
}

private extension KeyedDecodingContainer where K == FeaturedEvent.CodingKeys {
    nonisolated func decodeFlexibleString(forKey key: K) throws -> String {
        if let value = try? decode(String.self, forKey: key) {
            return value
        }
        if let value = try? decode(UUID.self, forKey: key) {
            return value.uuidString.lowercased()
        }
        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected string-compatible value.")
        )
    }

    nonisolated func decodeFlexibleOptionalString(forKey key: K) throws -> String? {
        guard contains(key), !(try decodeNil(forKey: key)) else { return nil }
        return try decodeFlexibleString(forKey: key)
    }

    nonisolated func decodeStringArrayIfPresent(forKey key: K) throws -> [String]? {
        guard contains(key), !(try decodeNil(forKey: key)) else { return nil }
        if let values = try? decode([String].self, forKey: key) {
            return values
        }
        if let value = try? decode(String.self, forKey: key) {
            return value
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return nil
    }

    nonisolated func decodeFlexibleDate(forKey key: K) throws -> Date {
        let raw = try decodeFlexibleString(forKey: key)
        if let date = FeaturedEvent.parseDate(raw) {
            return date
        }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Invalid date: \(raw)")
    }
}

nonisolated enum LiveMatchFilters {
    static func isFifaWorldCupMatch(_ match: LiveMatch) -> Bool {
        guard isSoccer(match) else { return false }

        let searchableText = [
            match.league,
            match.sourceLeagueName,
            match.leagueAlternate,
            match.eventName,
            "\(match.awayTeam) \(match.homeTeam)"
        ]
            .compactMap { $0 }
            .map(normalizedSearchText)
            .joined(separator: " ")

        let nonFifaWorldCupMarkers = [
            "fiba",
            "basketball world cup",
            "cricket world cup",
            "icc world cup",
            "t20 world cup",
            "rugby world cup",
            "hockey world cup",
            "american football",
            "nfl",
            "gridiron",
            "us football"
        ]
        if nonFifaWorldCupMarkers.contains(where: { searchableText.contains($0) }) {
            return false
        }

        if searchableText.contains("fifa") && searchableText.contains("world cup") {
            return true
        }
        if searchableText.contains("club world cup") {
            return true
        }
        if searchableText.contains("world cup qualifier") || searchableText.contains("world cup qualification") {
            return true
        }
        if searchableText.contains("men s world cup") || searchableText.contains("mens world cup") {
            return true
        }
        if searchableText.contains("women s world cup") || searchableText.contains("womens world cup") {
            return true
        }
        return false
    }

    static func matchesLeagueCountry(_ match: LiveMatch, selectedCountries: Set<String>) -> Bool {
        guard !selectedCountries.isEmpty else { return true }
        guard let country = match.leagueCountry else { return false }
        return selectedCountries.contains(country)
    }

    static func matchesFeaturedEvent(_ match: LiveMatch, featuredEvent: FeaturedEvent) -> Bool {
        if let featuredEventSlug = match.featuredEventSlug,
           normalizedSearchText(featuredEventSlug) == normalizedSearchText(featuredEvent.slug) {
            return true
        }

        if featuredEvent.isFifaWorldCupDefinition {
            return isFifaWorldCupMatch(match)
        }

        if let sport = featuredEvent.sport?.trimmingCharacters(in: .whitespacesAndNewlines), !sport.isEmpty {
            guard matchesSport(match, sport: sport) else { return false }
        }

        let searchableText = searchableText(for: match)
        let includeKeywords = featuredEvent.includeKeywords
            .map(normalizedSearchText)
            .filter { !$0.isEmpty }
        guard !includeKeywords.isEmpty else { return false }
        guard includeKeywords.contains(where: { searchableText.contains($0) }) else { return false }

        let excludeKeywords = featuredEvent.excludeKeywords
            .map(normalizedSearchText)
            .filter { !$0.isEmpty }
        return !excludeKeywords.contains(where: { searchableText.contains($0) })
    }

    static func filterByLeagueCountries(_ matches: [LiveMatch], selectedCountries: Set<String>) -> [LiveMatch] {
        guard !selectedCountries.isEmpty else { return matches }
        return matches.filter { matchesLeagueCountry($0, selectedCountries: selectedCountries) }
    }

    static func normalizedSearchText(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func searchableText(for match: LiveMatch) -> String {
        [
            match.sport,
            match.sourceSportName,
            match.league,
            match.sourceLeagueName,
            match.leagueAlternate,
            match.eventName,
            match.awayTeam,
            match.homeTeam
        ]
            .compactMap { $0 }
            .map(normalizedSearchText)
            .joined(separator: " ")
    }

    private static func matchesSport(_ match: LiveMatch, sport: String) -> Bool {
        let normalizedSport = normalizedSearchText(sport)
        guard !normalizedSport.isEmpty else { return true }
        if ["soccer", "football", "association football"].contains(normalizedSport) {
            return isSoccer(match)
        }
        let matchSports = [match.sport, match.sourceSportName]
            .compactMap { $0 }
            .map(normalizedSearchText)
        return matchSports.contains(normalizedSport)
            || LiveSportVisualType.normalize(sport) == match.liveSportVisualType
    }

    private static func isSoccer(_ match: LiveMatch) -> Bool {
        let sportFields = [match.sport, match.sourceSportName]
            .compactMap { $0 }
            .map(normalizedSearchText)
        let americanFootballMarkers = [
            "american football",
            "nfl",
            "gridiron",
            "us football"
        ]
        if sportFields.contains(where: { sport in americanFootballMarkers.contains(where: { sport.contains($0) }) }) {
            return false
        }
        if match.liveSportVisualType == .soccer { return true }
        return sportFields.contains { sport in
            sport == "soccer" || sport == "football" || sport.contains("association football")
        }
    }
}

nonisolated struct LiveMatch: Identifiable, Equatable, Codable {
    let id: String
    let source: String?
    let externalId: String?
    let sport: String
    let homeTeam: String
    let awayTeam: String
    let scoreHome: Int
    let scoreAway: Int
    let scoresAreAvailable: Bool
    let matchStatus: MatchStatus
    let rawMatchStatus: String?
    let minute: Int?
    let liveClockText: String?
    let league: String
    let sourceLeagueName: String?
    let eventName: String?
    let leagueAlternate: String?
    let sourceSportName: String?
    let startTime: Date
    let venueName: String?
    let venueCity: String?
    let venueLatitude: Double?
    let venueLongitude: Double?
    let leagueCountry: String?
    let tvBroadcasts: [LiveTVBroadcast]
    let timelineEvents: [LiveTimelineEvent]
    let featuredEventSlug: String?
    let homeTeamBadgeURL: String?
    let awayTeamBadgeURL: String?

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

    var latestScoringEventResolution: LiveScoringEventResolution {
        LiveScoringEventResolver.resolve(
            sportType: liveSportVisualType,
            timelineEvents: timelineEvents
        )
    }

    var latestScoringEvent: LiveLatestScoringEvent? {
        latestScoringEventResolution.latestEvent
    }

    var scoringTimelineSummary: LiveScoringTimelineSummary? {
        LiveScoringTimelineBuilder.build(
            sportType: liveSportVisualType,
            timelineEvents: timelineEvents,
            homeTeam: homeTeam,
            awayTeam: awayTeam
        )
    }

    var scoringEventsCount: Int {
        scoringTimelineSummary?.entries.count ?? 0
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
