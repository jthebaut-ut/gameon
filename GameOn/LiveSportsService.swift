import Foundation
import Supabase

/// Last client-side fetch diagnostics for Live tab DEBUG empty states.
struct LiveMatchesFetchDiagnostics: Equatable {
    let provider: String
    let requestURL: String
    let rawCount: Int
    let decodedCount: Int
    let liveCount: Int
    let todayScheduledCount: Int
    let apiError: String?
    let cacheSyncAttempted: Bool
}

actor LiveSportsService {
    static let shared = LiveSportsService()

    /// Reads the cached Supabase table populated by `sync-live-matches` (TheSportsDB v2/v1).
    /// The client does not hold sports API credentials; optional edge sync refreshes the cache.
    static let providerDescription = "supabase:live_matches (TheSportsDB via sync-live-matches)"

    private let cacheTTL: TimeInterval = 60
    private let cacheSyncCooldown: TimeInterval = 55
    private var cachedMatches: (fetchedAt: Date, matches: [LiveMatch])?
    private var inFlightFetch: Task<[LiveMatch], Error>?
    private var lastCacheSyncAt: Date?
    private(set) var lastFetchDiagnostics: LiveMatchesFetchDiagnostics?

    func fetchLiveMatches(forceRefresh: Bool = false) async throws -> [LiveMatch] {
#if DEBUG
        print("[LiveDebug] refreshStarted forceRefresh=\(forceRefresh)")
        print("[LiveDebug] timezone=\(TimeZone.current.identifier)")
        print("[LiveDebug] provider=\(Self.providerDescription)")
#endif
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
        let task = Task<[LiveMatch], Error> { [forceRefresh] in
            let syncAttempted = await self.triggerCacheSyncIfNeeded(force: forceRefresh)
            return try await self.fetchLiveMatchesFromSupabase(cacheSyncAttempted: syncAttempted)
        }
        inFlightFetch = task
        defer { inFlightFetch = nil }

        let matches = try await task.value
        cachedMatches = (Date(), matches)
        return matches
    }

    private func triggerCacheSyncIfNeeded(force: Bool) async -> Bool {
        let now = Date()
        if !force,
           let lastCacheSyncAt,
           now.timeIntervalSince(lastCacheSyncAt) < cacheSyncCooldown {
            return false
        }
        lastCacheSyncAt = now
#if DEBUG
        print("[LiveDebug] cacheSyncStarted")
#endif
        struct SyncResponse: Decodable {
            let success: Bool?
            let source: String?
            let error: String?
        }
        do {
            let response: SyncResponse = try await supabase.functions.invoke(
                "sync-live-matches",
                options: FunctionInvokeOptions(method: .post)
            )
#if DEBUG
            print(
                "[LiveDebug] cacheSyncFinished success=\(response.success ?? false) source=\(response.source ?? "nil") error=\(response.error ?? "nil")"
            )
#endif
        } catch {
#if DEBUG
            print("[LiveDebug] apiError=cache_sync \(error.localizedDescription)")
#endif
        }
        return true
    }

    private func fetchLiveMatchesFromSupabase(cacheSyncAttempted: Bool) async throws -> [LiveMatch] {
        let requestURL = try await Self.liveMatchesRequestURL()
        let publishableKey = await supabasePublishableKey
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Self.logRequest(requestURL: requestURL, request: request)

#if DEBUG
        print("[LiveDebug] requestURL=\(requestURL.absoluteString)")
#endif
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
#if DEBUG
            print("[LiveDebug] apiError=\(error.localizedDescription)")
#endif
            lastFetchDiagnostics = LiveMatchesFetchDiagnostics(
                provider: Self.providerDescription,
                requestURL: requestURL.absoluteString,
                rawCount: 0,
                decodedCount: 0,
                liveCount: 0,
                todayScheduledCount: 0,
                apiError: error.localizedDescription,
                cacheSyncAttempted: cacheSyncAttempted
            )
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

#if DEBUG
        print("[LiveDebug] response_status=\(httpResponse.statusCode)")
        print("[LiveDebug] raw_bytes=\(data.count)")
#endif

        guard 200..<300 ~= httpResponse.statusCode else {
            let apiError = "HTTP \(httpResponse.statusCode): \(Self.rawPreview(data))"
#if DEBUG
            print("[LiveDebug] apiError=\(apiError)")
            print("[LiveDebug] rawCount=0 decodedCount=0 liveCount=0 todayCount=0")
#endif
            lastFetchDiagnostics = LiveMatchesFetchDiagnostics(
                provider: Self.providerDescription,
                requestURL: requestURL.absoluteString,
                rawCount: 0,
                decodedCount: 0,
                liveCount: 0,
                todayScheduledCount: 0,
                apiError: apiError,
                cacheSyncAttempted: cacheSyncAttempted
            )
            throw LiveSportsServiceError.supabaseRequestFailed(statusCode: httpResponse.statusCode, body: Self.rawPreview(data))
        }

        let rows: [LiveMatchRow]
        do {
            rows = try JSONDecoder().decode([LiveMatchRow].self, from: data)
        } catch {
#if DEBUG
            print("[LiveDebug] apiError=decode \(error.localizedDescription)")
#endif
            lastFetchDiagnostics = LiveMatchesFetchDiagnostics(
                provider: Self.providerDescription,
                requestURL: requestURL.absoluteString,
                rawCount: 0,
                decodedCount: 0,
                liveCount: 0,
                todayScheduledCount: 0,
                apiError: error.localizedDescription,
                cacheSyncAttempted: cacheSyncAttempted
            )
            throw error
        }

        let normalized = rows.compactMap(\.liveMatch)
        let decodeDropped = rows.count - normalized.count
        if decodeDropped > 0 {
#if DEBUG
            print("[LiveDebug] filteredOut reason=row_decode_failed count=\(decodeDropped)")
#endif
        }
        let deduped = Self.deduplicateLiveMatches(normalized)
        let matches = deduped.sorted { lhs, rhs in
            if lhs.matchStatus.isHappeningNow != rhs.matchStatus.isHappeningNow {
                return lhs.matchStatus.isHappeningNow && !rhs.matchStatus.isHappeningNow
            }
            if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
            return lhs.league.localizedCaseInsensitiveCompare(rhs.league) == .orderedAscending
        }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let liveCount = matches.filter(\.matchStatus.isHappeningNow).count
        let todayScheduledCount = matches.filter {
            $0.matchStatus == .scheduled && cal.isDate($0.startTime, inSameDayAs: today)
        }.count
        let scheduledNotLive = matches.filter { !$0.matchStatus.isHappeningNow && $0.matchStatus != .fullTime }.count
        if scheduledNotLive > 0 {
#if DEBUG
            print("[LiveDebug] filteredOut reason=not_live_or_halftime count=\(scheduledNotLive) (Live tab shows LIVE/HT only)")
#endif
        }

#if DEBUG
        print("[LiveDebug] rawCount=\(rows.count)")
        print("[LiveDebug] decodedCount=\(normalized.count)")
        print("[LiveDebug] liveCount=\(liveCount)")
        print("[LiveDebug] todayCount=\(todayScheduledCount)")
        Self.logRowSamples(rows)
        Self.logMatchSamples(deduped)
#endif

        lastFetchDiagnostics = LiveMatchesFetchDiagnostics(
            provider: Self.providerDescription,
            requestURL: requestURL.absoluteString,
            rawCount: rows.count,
            decodedCount: normalized.count,
            liveCount: liveCount,
            todayScheduledCount: todayScheduledCount,
            apiError: nil,
            cacheSyncAttempted: cacheSyncAttempted
        )

        return matches
    }

    private static func deduplicateLiveMatches(_ matches: [LiveMatch]) -> [LiveMatch] {
        var seenProviderKeys = Set<String>()
        var seenNormalizedKeys = Set<String>()
        var deduped: [LiveMatch] = []

        for match in matches {
            let providerKey = normalizedProviderMatchKey(match.id)
            let normalizedKey = normalizedFixtureKey(for: match)

            if !providerKey.isEmpty, seenProviderKeys.contains(providerKey) {
#if DEBUG
                print("[LiveDedupDebug] duplicate_removed=providerMatchId:\(providerKey)")
#endif
                continue
            }

            if seenNormalizedKeys.contains(normalizedKey) {
#if DEBUG
                print("[LiveDedupDebug] duplicate_removed=normalizedFixture:\(normalizedKey)")
#endif
                continue
            }

            if !providerKey.isEmpty {
                seenProviderKeys.insert(providerKey)
            }
            seenNormalizedKeys.insert(normalizedKey)
            deduped.append(match)
        }

        return deduped
    }

    private static func normalizedProviderMatchKey(_ raw: String) -> String {
        normalizeDedupComponent(raw)
    }

    private static func normalizedFixtureKey(for match: LiveMatch) -> String {
        [
            normalizeDedupComponent(match.sport),
            normalizeDedupComponent(match.league),
            normalizeDedupComponent(match.homeTeam),
            normalizeDedupComponent(match.awayTeam),
            normalizedStartMinute(match.startTime)
        ].joined(separator: "|")
    }

    private static func normalizedStartMinute(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970 / 60))
    }

    private static func normalizeDedupComponent(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\s\-_]+"#, with: " ", options: .regularExpression)
    }

    private static func liveMatchesRequestURL() async throws -> URL {
        let now = Date()
        let windowStart = now.addingTimeInterval(-2 * 60 * 60)
        let windowEnd = now.addingTimeInterval(7 * 24 * 60 * 60)
        let projectURL = await supabaseProjectURL
        var components = URLComponents(
            url: projectURL
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
            let start = SupabaseTimestampParsing.parseTimestamptz(startRaw)
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
        let status = clean(raw)?.uppercased() ?? ""
        if status.contains("HALF") || status == "HT" { return .halfTime }
        if status.contains("FT") || status.contains("FINAL") || status.contains("FINISHED") || status == "AET" || status == "PEN" {
            return .fullTime
        }
        if ["LIVE", "1H", "2H", "ET", "BT", "P", "OT", "Q1", "Q2", "Q3", "Q4"].contains(status) {
            return .live
        }
        if status.contains("LIVE")
            || status.contains("IN PROGRESS")
            || status.contains("IN PLAY")
            || status.contains("IN-PLAY")
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
        if status == "NS" || status.contains("SCHED") || status.contains("NOT STARTED") {
            return .scheduled
        }
        return .scheduled
    }

}
