import Foundation

actor LiveSportsService {
    static let shared = LiveSportsService()

    /// Reads the cached Supabase table populated by `sync-live-matches` (API-Football primary,
    /// TheSportsDB fallback). The client does not poll or hold sports API credentials.
    private let cacheTTL: TimeInterval = 60
    private var cachedMatches: (fetchedAt: Date, matches: [LiveMatch])?
    private var inFlightFetch: Task<[LiveMatch], Error>?

    func fetchLiveMatches(forceRefresh: Bool = false) async throws -> [LiveMatch] {
        if !forceRefresh,
           let cachedMatches,
           Date().timeIntervalSince(cachedMatches.fetchedAt) < cacheTTL {
#if DEBUG
            print("[LiveDebug] cache_hit=true cached_count=\(cachedMatches.matches.count)")
#endif
            return cachedMatches.matches
        }

        if let inFlightFetch {
#if DEBUG
            print("[LiveDebug] awaiting_in_flight_fetch=true")
#endif
            return try await inFlightFetch.value
        }

#if DEBUG
        print("[LiveDebug] query_execution_started forceRefresh=\(forceRefresh)")
#endif
        let task = Task<[LiveMatch], Error> {
            try await Self.fetchLiveMatchesFromSupabase()
        }
        inFlightFetch = task
        defer { inFlightFetch = nil }

        let matches = try await task.value
        cachedMatches = (Date(), matches)
        return matches
    }

    private static func fetchLiveMatchesFromSupabase() async throws -> [LiveMatch] {
        let requestURL = try liveMatchesRequestURL()
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue(supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabasePublishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        logRequest(requestURL: requestURL, request: request)

#if DEBUG
        print("[LiveDebug] START FETCH")
        print("[LiveDebug] URL =", requestURL.absoluteString)
#endif
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

#if DEBUG
        print("[LiveDebug] status =", httpResponse.statusCode)
        print("[LiveDebug] raw_bytes =", data.count)
        print("[LiveDebug] raw_preview =", rawPreview(data))
        print("[LiveDebug] response_status=\(httpResponse.statusCode)")
        print("[LiveDebug] raw_response=\(rawPreview(data))")
#endif

        guard 200..<300 ~= httpResponse.statusCode else {
#if DEBUG
            print("[LiveDebug] raw_count=unavailable")
            print("[LiveDebug] filtered_count=0")
            print("[LiveDebug] final_count=0")
#endif
            throw LiveSportsServiceError.supabaseRequestFailed(statusCode: httpResponse.statusCode, body: rawPreview(data))
        }

        let rows: [LiveMatchRow]
        do {
            rows = try JSONDecoder().decode([LiveMatchRow].self, from: data)
        } catch {
#if DEBUG
            print("[LiveDebug] raw_count=decode_failed")
            print("[LiveDebug] filtered_count=0")
            print("[LiveDebug] final_count=0")
#endif
            throw error
        }
#if DEBUG
        print("[LiveDebug] rows_count =", rows.count)
        print("[LiveDebug] first_row =", rows.first as Any)
#endif
        let normalized = rows.compactMap(\.liveMatch)
        let matches = normalized.sorted { lhs, rhs in
            if lhs.matchStatus.isHappeningNow != rhs.matchStatus.isHappeningNow {
                return lhs.matchStatus.isHappeningNow && !rhs.matchStatus.isHappeningNow
            }
            if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
            return lhs.league.localizedCaseInsensitiveCompare(rhs.league) == .orderedAscending
        }

#if DEBUG
        print("[LiveDebug] normalized_count =", normalized.count)
        print("[LiveDebug] final_count =", matches.count)
        print("[LiveDebug] raw_count=\(rows.count)")
        logRowSamples(rows)
        print("[LiveDebug] filtered_count=\(normalized.count)")
        logMatchSamples(normalized)
        print("[LiveDebug] final_count=\(matches.count)")
#endif

        return matches
    }

    private static func liveMatchesRequestURL() throws -> URL {
        let now = Date()
        let windowStart = now.addingTimeInterval(-2 * 60 * 60)
        let windowEnd = now.addingTimeInterval(7 * 24 * 60 * 60)
        var components = URLComponents(
            url: supabaseProjectURL
                .appendingPathComponent("rest")
                .appendingPathComponent("v1")
                .appendingPathComponent("live_matches"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,sport,home_team,away_team,score_home,score_away,match_status,minute,league,start_time,updated_at"),
            URLQueryItem(name: "start_time", value: "gte.\(supabaseTimestampFormatter.string(from: windowStart))"),
            URLQueryItem(name: "start_time", value: "lte.\(supabaseTimestampFormatter.string(from: windowEnd))"),
            URLQueryItem(name: "order", value: "start_time.asc")
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private static let supabaseTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static func logRequest(requestURL: URL, request: URLRequest) {
#if DEBUG
        let redactedHeaders = [
            "apikey": redactedHeaderDescription(request.value(forHTTPHeaderField: "apikey")),
            "Authorization": redactedHeaderDescription(request.value(forHTTPHeaderField: "Authorization")),
            "Accept": request.value(forHTTPHeaderField: "Accept") ?? "missing"
        ]
        print("[LiveDebug] request_url=\(requestURL.absoluteString)")
        print("[LiveDebug] request_headers=\(redactedHeaders)")
#endif
    }

    private static func redactedHeaderDescription(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "missing" }
        return "present(redacted,length=\(value.count))"
    }

    private static func rawPreview(_ data: Data, limit: Int = 4_000) -> String {
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        guard raw.count > limit else { return raw }
        return "\(raw.prefix(limit))…<truncated \(raw.count - limit) chars>"
    }

#if DEBUG
    private static func logRowSamples(_ rows: [LiveMatchRow]) {
        for (index, row) in rows.prefix(2).enumerated() {
            print("[LiveDebug] raw_row_sample[\(index)]=\(row.debugSummary)")
        }
    }

    private static func logMatchSamples(_ matches: [LiveMatch]) {
        for (index, match) in matches.prefix(2).enumerated() {
            print("[LiveDebug] normalized_match_sample[\(index)]=id=\(match.id) sport=\(match.sport) status=\(match.matchStatus.rawValue) teams=\(match.awayTeam)@\(match.homeTeam) score=\(match.scoreAway)-\(match.scoreHome) start=\(supabaseTimestampFormatter.string(from: match.startTime))")
        }
    }
#endif
}

private enum LiveSportsServiceError: LocalizedError {
    case supabaseRequestFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case let .supabaseRequestFailed(statusCode, body):
            return "Supabase live_matches request failed with status \(statusCode): \(body)"
        }
    }
}

private nonisolated struct LiveMatchRow: Decodable {
    let id: String?
    let sport: String?
    let home_team: String?
    let away_team: String?
    let score_home: Int?
    let score_away: Int?
    let match_status: String?
    let minute: Int?
    let league: String?
    let start_time: String?

#if DEBUG
    var debugSummary: String {
        "id=\(id ?? "nil") sport=\(sport ?? "nil") status=\(match_status ?? "nil") teams=\(away_team ?? "nil")@\(home_team ?? "nil") score=\(Self.debugValue(score_away))-\(Self.debugValue(score_home)) minute=\(Self.debugValue(minute)) league=\(league ?? "nil") start=\(start_time ?? "nil")"
    }

    private static func debugValue(_ value: Int?) -> String {
        value.map { "\($0)" } ?? "nil"
    }
#endif

    var liveMatch: LiveMatch? {
        guard
            let id = Self.clean(id),
            let homeTeam = Self.clean(home_team),
            let awayTeam = Self.clean(away_team),
            let startRaw = Self.clean(start_time),
            let start = Self.parseSupabaseTimestamp(startRaw)
        else { return nil }

        let rawSport = Self.clean(sport)
        let visualType = LiveSportVisualType.normalize(rawSport)
        let normalizedSport = visualType.displayLabel
#if DEBUG
        print("[LiveSportNormalization] id=\(id) raw=\(rawSport ?? "nil") normalized=\(normalizedSport)")
        print("[LiveSportDetected] id=\(id) sportType=\(visualType.rawValue) label=\(normalizedSport)")
#endif

        return LiveMatch(
            id: id,
            sport: normalizedSport,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            scoreHome: score_home ?? 0,
            scoreAway: score_away ?? 0,
            matchStatus: Self.parseMatchStatus(match_status),
            minute: minute,
            league: Self.clean(league) ?? "Live",
            startTime: start
        )
    }

    private static func clean(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func parseMatchStatus(_ raw: String?) -> MatchStatus {
        switch clean(raw)?.uppercased() {
        case "LIVE", "1H", "2H", "ET", "BT", "P":
            return .live
        case "HT":
            return .halfTime
        case "FT", "AET", "PEN", "FINAL":
            return .fullTime
        default:
            return .scheduled
        }
    }

    private static func parseSupabaseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }

        return PickupGameModels.parseSupabaseTimestamptz(trimmed)
    }
}
