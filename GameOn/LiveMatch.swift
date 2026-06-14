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

        if finalStatusTokens.contains(status)
            || status.contains("FINAL")
            || status.contains("FINISHED")
            || status.contains("COMPLETED")
            || status.contains("FULL TIME")
            || status.contains("MATCH FINISHED") {
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
        "FULLTIME",
        "COMPLETED",
        "COMPLETE",
        "FINISHED",
        "MATCH FINISHED",
        "AET",
        "PEN",
        "AFTER EXTRA TIME",
        "AFTER PENALTIES",
        "ENDED",
        "END",
        "GAME OVER"
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
