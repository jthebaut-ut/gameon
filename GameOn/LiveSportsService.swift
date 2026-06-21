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
    private let featuredEventsCacheTTL: TimeInterval = 5 * 60
    private var cachedMatches: (fetchedAt: Date, matches: [LiveMatch])?
    private var cachedFeaturedEvents: (fetchedAt: Date, events: [FeaturedEvent])?
    private var inFlightFetch: Task<[LiveMatch], Error>?
    private var inFlightRead: Task<[LiveMatch], Error>?
    private var inFlightBackgroundSync: Task<[LiveMatch], Error>?
    private var inFlightFeaturedEventsFetch: Task<[FeaturedEvent], Never>?
    private var lastCacheSyncAt: Date?
    private(set) var lastFetchDiagnostics: LiveMatchesFetchDiagnostics?

    func fetchLiveMatches(forceRefresh: Bool = false) async throws -> [LiveMatch] {
#if DEBUG
        print("[LiveDebug] refreshStarted forceRefresh=\(forceRefresh)")
        print("[LiveDebug] timezone=\(TimeZone.current.identifier)")
        print("[LiveDebug] provider=\(Self.providerDescription)")
#endif
        if forceRefresh {
            return try await fetchLiveMatchesSyncThenRead(force: true)
        }

        if let cachedMatches,
           Date().timeIntervalSince(cachedMatches.fetchedAt) < cacheTTL {
#if DEBUG
            print("[LiveDebug] cache_hit=true cached_count=\(cachedMatches.matches.count)")
#endif
            return cachedMatches.matches
        }

        return try await fetchLiveMatchesReadOnly()
    }

    /// Automatic Live loads: sync-live-matches (if cooldown expired) then re-read. Coalesced across callers.
    func fetchLiveMatchesAfterBackgroundSyncIfNeeded() async throws -> [LiveMatch]? {
        guard shouldScheduleBackgroundSync() else {
#if DEBUG
            print("[LiveDebug] backgroundSyncSkipped reason=syncCooldownFresh")
#endif
            return nil
        }

        if let inFlightBackgroundSync {
#if DEBUG
            print("[LiveDebug] backgroundSyncCoalesced=true")
#endif
            return try await inFlightBackgroundSync.value
        }

#if DEBUG
        print("[LiveDebug] backgroundSyncStarted")
#endif
        let task = Task<[LiveMatch], Error> {
            let syncAttempted = await self.triggerCacheSyncIfNeeded(force: false)
            return try await self.fetchLiveMatchesFromSupabase(cacheSyncAttempted: syncAttempted)
        }
        inFlightBackgroundSync = task
        defer { inFlightBackgroundSync = nil }

        let matches = try await task.value
        cachedMatches = (Date(), matches)
#if DEBUG
        print("[LiveDebug] backgroundSyncFinished count=\(matches.count)")
#endif
        return matches
    }

    private func fetchLiveMatchesSyncThenRead(force: Bool) async throws -> [LiveMatch] {
        if let inFlightFetch {
#if DEBUG
            print("[LiveDebug] awaiting_in_flight_fetch=true force=\(force)")
#endif
            return try await inFlightFetch.value
        }

#if DEBUG
        print("[LiveDebug] query_execution_started forceRefresh=\(force)")
#endif
        let task = Task<[LiveMatch], Error> { [force] in
            let syncAttempted = await self.triggerCacheSyncIfNeeded(force: force)
            return try await self.fetchLiveMatchesFromSupabase(cacheSyncAttempted: syncAttempted)
        }
        inFlightFetch = task
        defer { inFlightFetch = nil }

        let matches = try await task.value
        cachedMatches = (Date(), matches)
        return matches
    }

    private func fetchLiveMatchesReadOnly() async throws -> [LiveMatch] {
        if let inFlightRead {
#if DEBUG
            print("[LiveDebug] awaiting_in_flight_read=true")
#endif
            return try await inFlightRead.value
        }

#if DEBUG
        print("[LiveDebug] readFirstStarted sync=false")
#endif
        let task = Task<[LiveMatch], Error> {
            try await self.fetchLiveMatchesFromSupabase(cacheSyncAttempted: false)
        }
        inFlightRead = task
        defer { inFlightRead = nil }

        let matches = try await task.value
        cachedMatches = (Date(), matches)
#if DEBUG
        print("[LiveDebug] readFirstFinished count=\(matches.count)")
#endif
        return matches
    }

    private func shouldScheduleBackgroundSync() -> Bool {
        let now = Date()
        if let lastCacheSyncAt,
           now.timeIntervalSince(lastCacheSyncAt) < cacheSyncCooldown {
            return false
        }
        return true
    }

    func fetchActiveFeaturedEvents(forceRefresh: Bool = false) async -> [FeaturedEvent] {
        if !forceRefresh,
           let cachedFeaturedEvents,
           Date().timeIntervalSince(cachedFeaturedEvents.fetchedAt) < featuredEventsCacheTTL {
            return cachedFeaturedEvents.events
        }

        if let inFlightFeaturedEventsFetch {
            return await inFlightFeaturedEventsFetch.value
        }

        let staleEvents = cachedFeaturedEvents?.events
        let task = Task<[FeaturedEvent], Never> {
            do {
                return try await Self.fetchFeaturedEventsFromSupabase()
            } catch {
#if DEBUG
                print("[FeaturedEventsDebug] fetch_failed error=\(error.localizedDescription)")
#endif
                return staleEvents ?? FeaturedEvent.fallbackEvents
            }
        }
        inFlightFeaturedEventsFetch = task
        let events = await task.value
        inFlightFeaturedEventsFetch = nil
        cachedFeaturedEvents = (Date(), events)
        return events
    }

    func fetchLiveMatches(
        on selectedDate: Date,
        sportFilter: String? = nil,
        forceRefresh: Bool = false
    ) async throws -> [LiveMatch] {
        let requestURL = try await Self.liveMatchesRequestURL(selectedDate: selectedDate)
        let matches = try await fetchLiveMatchesFromSupabase(requestURL: requestURL, cacheSyncAttempted: false)
        let sport = sportFilter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return matches
            .filter { match in
                guard !sport.isEmpty, sport.localizedCaseInsensitiveCompare("All") != .orderedSame else {
                    return true
                }
                return match.sport.localizedCaseInsensitiveCompare(sport) == .orderedSame
                    || SportFilterCatalog.storedSport(match.sport, matchesSearchQuery: sport)
            }
            .sorted { lhs, rhs in
                if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
                return "\(lhs.awayTeam) \(lhs.homeTeam)".localizedCaseInsensitiveCompare("\(rhs.awayTeam) \(rhs.homeTeam)") == .orderedAscending
            }
    }

    func fetchLiveMatches(windowDays: Int) async throws -> [LiveMatch] {
        try await fetchLiveMatches(windowDays: windowDays, sportFilter: nil)
    }

    func fetchLiveMatches(windowDays: Int, sportFilter: String?) async throws -> [LiveMatch] {
        let calendar = Calendar.current
        let now = Date()
        let windowStart = calendar.startOfDay(for: now)
        let clampedDays = min(max(windowDays, 7), 90)
        let windowEnd = calendar.date(byAdding: .day, value: clampedDays, to: windowStart)
            ?? now.addingTimeInterval(TimeInterval(clampedDays * 24 * 60 * 60))
        let requestURL = try await Self.liveMatchesRequestURL(
            windowStart: windowStart,
            windowEnd: windowEnd,
            upperBoundOperator: "lt",
            sportFilter: sportFilter
        )
        let matches = try await fetchLiveMatchesFromSupabase(requestURL: requestURL, cacheSyncAttempted: false)
        let sport = sportFilter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return matches.filter { match in
            guard !sport.isEmpty, sport.localizedCaseInsensitiveCompare("All") != .orderedSame else {
                return true
            }
            return match.sport.localizedCaseInsensitiveCompare(sport) == .orderedSame
                || SportFilterCatalog.storedSport(match.sport, matchesSearchQuery: sport)
        }
    }

    func fetchLiveMatches(liveMatchIds: [String]) async throws -> [LiveMatch] {
        let ids = Array(
            Set(
                liveMatchIds
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        guard !ids.isEmpty else { return [] }

        let requestURL = try await Self.liveMatchesByIdsRequestURL(ids: ids)
        return try await fetchLiveMatchesFromSupabase(requestURL: requestURL, cacheSyncAttempted: false)
    }

    func fetchLiveMatches(source: String, externalId: String) async throws -> [LiveMatch] {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExternalId = externalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty, !normalizedExternalId.isEmpty else { return [] }

        let requestURL = try await Self.liveMatchesBySourceExternalRequestURL(
            source: normalizedSource,
            externalId: normalizedExternalId
        )
        return try await fetchLiveMatchesFromSupabase(requestURL: requestURL, cacheSyncAttempted: false)
    }

    func fetchLiveMatchesForSavedProGameHydration(_ savedGames: [SavedProGame]) async throws -> [LiveMatch] {
        guard !savedGames.isEmpty else { return [] }

        var merged: [LiveMatch] = []
        var seenKeys = Set<String>()

        func absorb(_ matches: [LiveMatch]) {
            for match in matches {
                let key = SavedProGame.stableKey(for: match)
                guard seenKeys.insert(key).inserted else { continue }
                merged.append(match)
            }
        }

        func alreadyMatched(_ saved: SavedProGame) -> Bool {
            merged.contains { SavedProGame.directlyMatchesSavedProGame($0, saved) }
        }

        for saved in savedGames {
            let idsToFetch = orderedUniqueHydrationIds(for: saved)
            let externalIdsToFetch = orderedUniqueHydrationExternalIds(for: saved)
            let source = saved.source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? saved.source!.trimmingCharacters(in: .whitespacesAndNewlines)
                : "thesportsdb"

            logSavedProHydrationQueryPlan(
                saved: saved,
                idsToFetch: idsToFetch,
                externalIdsToFetch: externalIdsToFetch,
                source: source
            )

            if alreadyMatched(saved) { continue }

            for id in idsToFetch where !alreadyMatched(saved) {
                absorb(try await fetchLiveMatchesByExactId(id))
            }

            if !alreadyMatched(saved) {
                for externalId in externalIdsToFetch {
                    absorb(try await fetchLiveMatchesBySourceExternal(source: source, externalId: externalId))
                    if alreadyMatched(saved) { break }
                }
            }

            if !alreadyMatched(saved), source.caseInsensitiveCompare("thesportsdb") != .orderedSame {
                for externalId in externalIdsToFetch {
                    absorb(try await fetchLiveMatchesBySourceExternal(source: "thesportsdb", externalId: externalId))
                    if alreadyMatched(saved) { break }
                }
            }

            if !alreadyMatched(saved) {
                absorb(
                    try await fetchLiveMatchesHydrationOR(
                        idsToFetch: idsToFetch,
                        externalIdsToFetch: externalIdsToFetch,
                        source: source
                    )
                )
            }
        }

        return merged
    }

    private func orderedUniqueHydrationIds(for saved: SavedProGame) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func add(_ raw: String?) {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            ordered.append(trimmed)
        }

        add(saved.stableKey)
        add(saved.id)
        for candidate in SavedProGame.directHydrationLookupIds(for: saved) {
            add(candidate)
        }
        return ordered
    }

    private func orderedUniqueHydrationExternalIds(for saved: SavedProGame) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func add(_ raw: String?) {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            ordered.append(trimmed)
        }

        add(saved.resolvedProviderExternalId)
        add(saved.externalId)
        if let suffix = saved.id.split(separator: ":").last.map(String.init) {
            add(suffix)
        }
        return ordered
    }

    private func fetchLiveMatchesByExactId(_ id: String) async throws -> [LiveMatch] {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        logSavedProHydrationFetch(
            idsToFetch: trimmed,
            externalIdsToFetch: "",
            source: "",
            lookup: "directId"
        )

        let rows: [LiveMatchRow] = try await supabase
            .from("live_matches")
            .select(Self.liveMatchesSelectColumns)
            .eq("id", value: trimmed)
            .limit(1)
            .execute()
            .value

        logSavedProHydrationFetchResult(
            lookup: "directId",
            idsToFetch: trimmed,
            externalIdsToFetch: "",
            source: "",
            rows: rows
        )
        return normalizedLiveMatches(from: rows)
    }

    private func fetchLiveMatchesBySourceExternal(source: String, externalId: String) async throws -> [LiveMatch] {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExternalId = externalId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty, !normalizedExternalId.isEmpty else { return [] }

        logSavedProHydrationFetch(
            idsToFetch: "",
            externalIdsToFetch: normalizedExternalId,
            source: normalizedSource,
            lookup: "directExternalId"
        )

        let rows: [LiveMatchRow] = try await supabase
            .from("live_matches")
            .select(Self.liveMatchesSelectColumns)
            .eq("source", value: normalizedSource)
            .eq("external_id", value: normalizedExternalId)
            .limit(5)
            .execute()
            .value

        logSavedProHydrationFetchResult(
            lookup: "directExternalId",
            idsToFetch: "",
            externalIdsToFetch: normalizedExternalId,
            source: normalizedSource,
            rows: rows
        )
        return normalizedLiveMatches(from: rows)
    }

    private func fetchLiveMatchesHydrationOR(
        idsToFetch: [String],
        externalIdsToFetch: [String],
        source: String
    ) async throws -> [LiveMatch] {
        var clauses: [String] = []
        for id in idsToFetch {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            clauses.append("id.eq.\(postgrestQuotedValue(trimmed))")
        }
        for externalId in externalIdsToFetch {
            let trimmed = externalId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            clauses.append("external_id.eq.\(postgrestQuotedValue(trimmed))")
            let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedSource.isEmpty {
                clauses.append(
                    "and(source.eq.\(postgrestQuotedValue(normalizedSource)),external_id.eq.\(postgrestQuotedValue(trimmed)))"
                )
            }
        }

        let uniqueClauses = Array(Set(clauses))
        guard !uniqueClauses.isEmpty else { return [] }

        let orFilter = uniqueClauses.joined(separator: ",")
        logSavedProHydrationFetch(
            idsToFetch: idsToFetch.joined(separator: "|"),
            externalIdsToFetch: externalIdsToFetch.joined(separator: "|"),
            source: source,
            lookup: "or(\(orFilter))"
        )

        let rows: [LiveMatchRow] = try await supabase
            .from("live_matches")
            .select(Self.liveMatchesSelectColumns)
            .or(orFilter)
            .limit(10)
            .execute()
            .value

        logSavedProHydrationFetchResult(
            lookup: "or",
            idsToFetch: idsToFetch.joined(separator: "|"),
            externalIdsToFetch: externalIdsToFetch.joined(separator: "|"),
            source: source,
            rows: rows
        )
        return normalizedLiveMatches(from: rows)
    }

    private func normalizedLiveMatches(from rows: [LiveMatchRow]) -> [LiveMatch] {
        Self.deduplicateLiveMatches(rows.compactMap(\.liveMatch))
    }

    private func postgrestQuotedValue(_ raw: String) -> String {
        if raw.range(of: #"^[A-Za-z0-9_\-]+$"#, options: .regularExpression) != nil {
            return raw
        }
        return "\"\(raw.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func logSavedProHydrationQueryPlan(
        saved: SavedProGame,
        idsToFetch: [String],
        externalIdsToFetch: [String],
        source: String
    ) {
#if DEBUG
        print("[SavedProGameHydrationDebug] savedId=\(saved.stableKey)")
        print("[SavedProGameHydrationDebug] providerId=\(saved.resolvedProviderExternalId ?? saved.externalId ?? saved.id)")
        print("[SavedProGameHydrationDebug] idsToFetch=\(idsToFetch.joined(separator: ","))")
        print("[SavedProGameHydrationDebug] externalIdsToFetch=\(externalIdsToFetch.joined(separator: ","))")
        print("[SavedProGameHydrationDebug] source=\(source)")
#endif
    }

    private func logSavedProHydrationFetch(
        idsToFetch: String,
        externalIdsToFetch: String,
        source: String,
        lookup: String
    ) {
#if DEBUG
        print("[SavedProGameHydrationDebug] lookup=\(lookup)")
        print("[SavedProGameHydrationDebug] idsToFetch=\(idsToFetch)")
        print("[SavedProGameHydrationDebug] externalIdsToFetch=\(externalIdsToFetch)")
        print("[SavedProGameHydrationDebug] source=\(source)")
#endif
    }

    private func logSavedProHydrationFetchResult(
        lookup: String,
        idsToFetch: String,
        externalIdsToFetch: String,
        source: String,
        rows: [LiveMatchRow]
    ) {
#if DEBUG
        print("[SavedProGameHydrationDebug] rawSupabaseRowsReturned=\(rows.count) lookup=\(lookup)")
        print("[SavedProGameHydrationDebug] idsToFetch=\(idsToFetch)")
        print("[SavedProGameHydrationDebug] externalIdsToFetch=\(externalIdsToFetch)")
        print("[SavedProGameHydrationDebug] source=\(source)")
        for (index, row) in rows.prefix(3).enumerated() {
            print(
                "[SavedProGameHydrationDebug] row[\(index)] id=\(row.id ?? "nil") " +
                "source=\(row.source ?? "nil") external_id=\(row.external_id ?? "nil") " +
                "status=\(row.match_status ?? "nil") teams=\(row.away_team ?? "nil")@\(row.home_team ?? "nil") " +
                "timelineCount=\(row.timeline_events?.count ?? 0)"
            )
        }
#endif
    }

    private func sourceOrProviderIsTheSportsDB(_ saved: SavedProGame) -> Bool {
        if saved.source?.caseInsensitiveCompare("thesportsdb") == .orderedSame { return true }
        return saved.id.lowercased().hasPrefix("thesportsdb:")
            || saved.stableKey.lowercased().hasPrefix("thesportsdb:")
    }

    func fetchLiveMatchDateDots(around month: Date) async throws -> Set<Date> {
        let requestURL = try await Self.liveMatchDateDotsRequestURL(around: month)
        let publishableKey = await supabasePublishableKey
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw LiveSportsServiceError.supabaseRequestFailed(statusCode: httpResponse.statusCode, body: Self.rawPreview(data))
        }

        let rows = try JSONDecoder().decode([LiveMatchDateDotRow].self, from: data)
        let calendar = Calendar.current
        return Set(rows.compactMap { row in
            guard let start = SupabaseTimestampParsing.parseTimestamptz(row.start_time) else { return nil }
            return calendar.startOfDay(for: start)
        })
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

    private func fetchLiveMatchesFromSupabase(
        requestURL: URL? = nil,
        cacheSyncAttempted: Bool
    ) async throws -> [LiveMatch] {
        let resolvedRequestURL: URL
        if let providedRequestURL = requestURL {
            resolvedRequestURL = providedRequestURL
        } else {
            resolvedRequestURL = try await Self.liveMatchesRequestURL()
        }
        let publishableKey = await supabasePublishableKey
        var request = URLRequest(url: resolvedRequestURL)
        request.httpMethod = "GET"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Self.logRequest(requestURL: resolvedRequestURL, request: request)

#if DEBUG
        print("[LiveDebug] requestURL=\(resolvedRequestURL.absoluteString)")
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
                requestURL: resolvedRequestURL.absoluteString,
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
                requestURL: resolvedRequestURL.absoluteString,
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
                requestURL: resolvedRequestURL.absoluteString,
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
            requestURL: resolvedRequestURL.absoluteString,
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
        let windowStart = now.addingTimeInterval(-24 * 60 * 60)
        let windowEnd = now.addingTimeInterval(7 * 24 * 60 * 60)
        return try await liveMatchesRequestURL(windowStart: windowStart, windowEnd: windowEnd, upperBoundOperator: "lte")
    }

    private static func liveMatchesRequestURL(selectedDate: Date) async throws -> URL {
        let calendar = Calendar.current
        let windowStart = calendar.startOfDay(for: selectedDate)
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: windowStart) ?? selectedDate.addingTimeInterval(24 * 60 * 60)
        return try await liveMatchesRequestURL(windowStart: windowStart, windowEnd: windowEnd, upperBoundOperator: "lt")
    }

    private static func liveMatchDateDotsRequestURL(around month: Date) async throws -> URL {
        let calendar = Calendar.current
        let windowStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? calendar.startOfDay(for: month)
        let windowEnd = calendar.date(byAdding: .month, value: 1, to: windowStart) ?? windowStart.addingTimeInterval(31 * 24 * 60 * 60)
        let projectURL = await supabaseProjectURL
        var components = URLComponents(
            url: projectURL
                .appendingPathComponent("rest")
                .appendingPathComponent("v1")
                .appendingPathComponent("live_matches"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "start_time"),
            URLQueryItem(name: "start_time", value: "gte.\(supabaseTimestampFormatter.string(from: windowStart))"),
            URLQueryItem(name: "start_time", value: "lt.\(supabaseTimestampFormatter.string(from: windowEnd))"),
            URLQueryItem(name: "order", value: "start_time.asc")
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private static func liveMatchesRequestURL(
        windowStart: Date,
        windowEnd: Date,
        upperBoundOperator: String,
        sportFilter: String? = nil
    ) async throws -> URL {
        let projectURL = await supabaseProjectURL
        var components = URLComponents(
            url: projectURL
                .appendingPathComponent("rest")
                .appendingPathComponent("v1")
                .appendingPathComponent("live_matches"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "select", value: "id,source,external_id,sport,home_team,away_team,score_home,score_away,match_status,minute,league,start_time,updated_at,payload,tv_broadcasts,timeline_events,featured_event_slug"),
            URLQueryItem(name: "start_time", value: "gte.\(supabaseTimestampFormatter.string(from: windowStart))"),
            URLQueryItem(name: "start_time", value: "\(upperBoundOperator).\(supabaseTimestampFormatter.string(from: windowEnd))"),
            URLQueryItem(name: "order", value: "start_time.asc")
        ]
        let sport = sportFilter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sport.isEmpty, sport.localizedCaseInsensitiveCompare("All") != .orderedSame {
            queryItems.append(URLQueryItem(name: "sport", value: "ilike.*\(sport)*"))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private static let liveMatchesSelectColumns = "id,source,external_id,sport,home_team,away_team,score_home,score_away,match_status,minute,league,start_time,updated_at,payload,tv_broadcasts,timeline_events,featured_event_slug"

    private static func postgrestInFilter(values: [String]) -> String {
        let quoted = values.map { value in
            "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "in.(\(quoted.joined(separator: ",")))"
    }

    private static func liveMatchesByIdsRequestURL(ids: [String]) async throws -> URL {
        let projectURL = await supabaseProjectURL
        var components = URLComponents(
            url: projectURL
                .appendingPathComponent("rest")
                .appendingPathComponent("v1")
                .appendingPathComponent("live_matches"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: liveMatchesSelectColumns),
            URLQueryItem(name: "id", value: postgrestInFilter(values: ids)),
            URLQueryItem(name: "order", value: "start_time.asc")
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private static func liveMatchesBySourceExternalRequestURL(
        source: String,
        externalId: String
    ) async throws -> URL {
        let projectURL = await supabaseProjectURL
        var components = URLComponents(
            url: projectURL
                .appendingPathComponent("rest")
                .appendingPathComponent("v1")
                .appendingPathComponent("live_matches"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: liveMatchesSelectColumns),
            URLQueryItem(name: "source", value: "eq.\(source)"),
            URLQueryItem(name: "external_id", value: "eq.\(externalId)"),
            URLQueryItem(name: "order", value: "start_time.asc")
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private static func fetchFeaturedEventsFromSupabase() async throws -> [FeaturedEvent] {
        let requestURL = try await featuredEventsRequestURL()
        let publishableKey = await supabasePublishableKey
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

#if DEBUG
        print("[FeaturedEventsDebug] requestURL=\(requestURL.absoluteString)")
#endif
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw LiveSportsServiceError.supabaseRequestFailed(statusCode: httpResponse.statusCode, body: rawPreview(data))
        }
        let decoder = JSONDecoder()
        let rows = try decoder.decode([FeaturedEvent].self, from: data)
#if DEBUG
        print("[FeaturedEventsDebug] activeCount=\(rows.count)")
#endif
        return rows.filter(\.enabled).sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func featuredEventsRequestURL() async throws -> URL {
        let projectURL = await supabaseProjectURL
        let today = featuredEventDateFormatter.string(from: Date())
        var components = URLComponents(
            url: projectURL
                .appendingPathComponent("rest")
                .appendingPathComponent("v1")
                .appendingPathComponent("featured_events"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,slug,title,short_title,icon,sport,include_keywords,exclude_keywords,start_date,end_date,enabled,priority"),
            URLQueryItem(name: "enabled", value: "eq.true"),
            URLQueryItem(name: "start_date", value: "lte.\(today)"),
            URLQueryItem(name: "end_date", value: "gte.\(today)"),
            URLQueryItem(name: "order", value: "priority.desc")
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

    private static let featuredEventDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
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
            print("[LiveDebug] normalized_match_sample[\(index)]=id=\(match.id) sport=\(match.sport) status=\(match.matchStatus.rawValue) teams=\(match.awayTeam)@\(match.homeTeam) score=\(match.scoreAway)-\(match.scoreHome) start=\(supabaseTimestampFormatter.string(from: match.startTime)) venue=\(match.venueName ?? "nil") city=\(match.venueCity ?? "nil") lat=\(match.venueLatitude.map(String.init(describing:)) ?? "nil") lon=\(match.venueLongitude.map(String.init(describing:)) ?? "nil")")
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
    let source: String?
    let external_id: String?
    let sport: String?
    let home_team: String?
    let away_team: String?
    let score_home: Int?
    let score_away: Int?
    let match_status: String?
    let minute: Int?
    let league: String?
    let start_time: String?
    let payload: [String: LiveMatchPayloadValue]?
    let tv_broadcasts: [LiveTVBroadcast]?
    let timeline_events: [LiveTimelineEvent]?
    let featured_event_slug: String?

    private enum CodingKeys: String, CodingKey {
        case id, source, external_id, sport, home_team, away_team, score_home, score_away
        case match_status, minute, league, start_time, payload, tv_broadcasts
        case timeline_events, featured_event_slug
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        external_id = try container.decodeIfPresent(String.self, forKey: .external_id)
        sport = try container.decodeIfPresent(String.self, forKey: .sport)
        home_team = try container.decodeIfPresent(String.self, forKey: .home_team)
        away_team = try container.decodeIfPresent(String.self, forKey: .away_team)
        score_home = try container.decodeIfPresent(Int.self, forKey: .score_home)
        score_away = try container.decodeIfPresent(Int.self, forKey: .score_away)
        match_status = try container.decodeIfPresent(String.self, forKey: .match_status)
        minute = try container.decodeIfPresent(Int.self, forKey: .minute)
        league = try container.decodeIfPresent(String.self, forKey: .league)
        start_time = try container.decodeIfPresent(String.self, forKey: .start_time)
        payload = try container.decodeIfPresent([String: LiveMatchPayloadValue].self, forKey: .payload)
        tv_broadcasts = try container.decodeIfPresent([LiveTVBroadcast].self, forKey: .tv_broadcasts)
        timeline_events = Self.decodeLossyTimelineEvents(from: container)
        featured_event_slug = try container.decodeIfPresent(String.self, forKey: .featured_event_slug)
    }

    private static func decodeLossyTimelineEvents(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [LiveTimelineEvent]? {
        guard container.contains(.timeline_events) else { return nil }
        if (try? container.decodeNil(forKey: .timeline_events)) == true { return nil }
        if let events = try? container.decode([LiveTimelineEvent].self, forKey: .timeline_events) {
            return events
        }
        guard var array = try? container.nestedUnkeyedContainer(forKey: .timeline_events) else {
            return nil
        }
        var events: [LiveTimelineEvent] = []
        while !array.isAtEnd {
            let elementDecoder = try? array.superDecoder()
            if let elementDecoder, let event = try? LiveTimelineEvent(from: elementDecoder) {
                events.append(event)
            }
        }
        return events
    }

#if DEBUG
    var debugSummary: String {
        "id=\(id ?? "nil") sport=\(sport ?? "nil") status=\(match_status ?? "nil") teams=\(away_team ?? "nil")@\(home_team ?? "nil") score=\(Self.debugValue(score_away))-\(Self.debugValue(score_home)) minute=\(Self.debugValue(minute)) league=\(league ?? "nil") start=\(start_time ?? "nil") venue=\(venueName ?? "nil") city=\(venueCity ?? "nil") lat=\(venueLatitude.map(String.init(describing:)) ?? "nil") lon=\(venueLongitude.map(String.init(describing:)) ?? "nil")"
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
        let title = "\(awayTeam) at \(homeTeam)"
        let decodedVenue = venueName
        let decodedCity = venueCity
        let payloadLeague = Self.firstString(in: payload, keys: ["strLeague", "league"])
        let payloadSport = Self.firstString(in: payload, keys: ["strSport", "sport"])
        let normalizedStatus = MatchStatus.normalized(from: match_status)
#if DEBUG
        print("[LiveSportNormalization] id=\(id) raw=\(rawSport ?? "nil") normalized=\(normalizedSport)")
        print("[LiveSportDetected] id=\(id) sportType=\(visualType.rawValue) label=\(normalizedSport)")
        print("[ProGameFinalDebug] rawProviderStatus=\(match_status ?? "nil")")
        print("[ProGameFinalDebug] normalizedStatus=\(normalizedStatus.rawValue)")
        print("[ProGameFinalDebug] isFinal=\(normalizedStatus == .fullTime)")
        print("[LiveVenueDebug] provider=\(payloadProviderDebugDescription)")
        print("[LiveVenueDebug] title=\(title)")
        print("[LiveVenueDebug] decodedVenue=\(decodedVenue ?? "nil")")
        print("[LiveVenueDebug] decodedCity=\(decodedCity ?? "nil")")
        print("[LiveVenueDebug] normalizedVenue=\(decodedVenue ?? "nil")")
        print("[LiveVenueDebug] normalizedCity=\(decodedCity ?? "nil")")
        print("[LiveVenueDebug] latitude=\(venueLatitude.map(String.init(describing:)) ?? "nil")")
        print("[LiveVenueDebug] longitude=\(venueLongitude.map(String.init(describing:)) ?? "nil")")
        print("[LiveVenueDebug] rawVenuePayload=\(rawVenuePayloadDebugDescription)")
#endif
        let providerClockText = Self.firstString(
            in: payload,
            keys: [
                "strProgress",
                "strClock",
                "clock",
                "gameClock",
                "periodClock",
                "displayClock",
                "strCurrentPeriod",
                "currentPeriod",
                "period"
            ]
        )

        return LiveMatch(
            id: id,
            source: Self.clean(source),
            externalId: Self.clean(external_id),
            sport: normalizedSport,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            scoreHome: score_home ?? 0,
            scoreAway: score_away ?? 0,
            scoresAreAvailable: score_home != nil && score_away != nil,
            matchStatus: normalizedStatus,
            rawMatchStatus: Self.clean(match_status),
            minute: minute,
            liveClockText: providerClockText,
            league: Self.clean(league) ?? "Live",
            sourceLeagueName: payloadLeague,
            eventName: eventName,
            leagueAlternate: leagueAlternate,
            sourceSportName: payloadSport ?? rawSport,
            startTime: start,
            venueName: decodedVenue,
            venueCity: decodedCity,
            venueLatitude: venueLatitude,
            venueLongitude: venueLongitude,
            leagueCountry: leagueCountry,
            tvBroadcasts: tv_broadcasts ?? [],
            timelineEvents: timeline_events ?? [],
            featuredEventSlug: Self.clean(featured_event_slug),
            homeTeamBadgeURL: Self.firstString(
                in: payload,
                keys: ["strHomeTeamBadge", "homeTeamBadge", "strHomeBadge"]
            ),
            awayTeamBadgeURL: Self.firstString(
                in: payload,
                keys: ["strAwayTeamBadge", "awayTeamBadge", "strAwayBadge"]
            )
        )
    }

    private var venueName: String? {
        Self.firstString(
            in: payload,
            keys: [
                "strVenue",
                "venue",
                "venueName",
                "strStadium",
                "stadium",
                "strArena",
                "arena",
                "locationName"
            ],
            paths: [
                ["venue", "name"],
                ["venue", "strVenue"],
                ["venue", "venueName"],
                ["stadium", "name"],
                ["stadium", "strStadium"],
                ["arena", "name"],
                ["arena", "strArena"],
                ["location", "name"],
                ["location", "venueName"]
            ]
        )
    }

    private var eventName: String? {
        Self.firstString(
            in: payload,
            keys: ["strEvent", "event", "eventName", "name"],
            paths: [
                ["event", "name"],
                ["fixture", "name"]
            ]
        )
    }

    private var leagueAlternate: String? {
        Self.firstString(
            in: payload,
            keys: ["strLeagueAlternate", "leagueAlternate", "league_alternate"],
            paths: [
                ["league", "alternate"],
                ["league", "strLeagueAlternate"]
            ]
        )
    }

    private var venueCity: String? {
        Self.firstString(
            in: payload,
            keys: [
                "strCity",
                "city",
                "venueCity",
                "strLocation",
                "location",
                "strVenueLocation",
                "venueLocation"
            ],
            paths: [
                ["venue", "city"],
                ["venue", "strCity"],
                ["venue", "venueCity"],
                ["stadium", "city"],
                ["stadium", "strCity"],
                ["arena", "city"],
                ["arena", "strCity"],
                ["location", "city"],
                ["location", "strCity"]
            ]
        )
    }

    private var venueLatitude: Double? {
        Self.firstDouble(
            in: payload,
            keys: [
                "venueLatitude",
                "venue_latitude",
                "strVenueLatitude",
                "stadiumLatitude",
                "strStadiumLatitude",
                "locationLatitude",
                "latitude",
                "lat"
            ],
            paths: [
                ["venue", "lat"],
                ["venue", "latitude"],
                ["stadium", "lat"],
                ["stadium", "latitude"],
                ["arena", "lat"],
                ["arena", "latitude"],
                ["location", "lat"],
                ["location", "latitude"],
                ["location", "coordinates", "lat"],
                ["location", "coordinates", "latitude"]
            ]
        )
    }

    private var venueLongitude: Double? {
        Self.firstDouble(
            in: payload,
            keys: [
                "venueLongitude",
                "venue_longitude",
                "venueLng",
                "strVenueLongitude",
                "stadiumLongitude",
                "strStadiumLongitude",
                "locationLongitude",
                "longitude",
                "lng",
                "lon"
            ],
            paths: [
                ["venue", "lng"],
                ["venue", "lon"],
                ["venue", "longitude"],
                ["stadium", "lng"],
                ["stadium", "lon"],
                ["stadium", "longitude"],
                ["arena", "lng"],
                ["arena", "lon"],
                ["arena", "longitude"],
                ["location", "lng"],
                ["location", "lon"],
                ["location", "longitude"],
                ["location", "coordinates", "lng"],
                ["location", "coordinates", "lon"],
                ["location", "coordinates", "longitude"]
            ]
        )
    }

    private var leagueCountry: String? {
        let explicitCountry = Self.firstString(
            in: payload,
            keys: [
                "strCountry",
                "strLeagueCountry",
                "strEventCountry",
                "country",
                "league country",
                "league_country",
                "leagueCountry",
                "competition country",
                "competition_country",
                "competitionCountry"
            ],
            paths: [
                ["league", "country"],
                ["competition", "country"],
                ["event", "country"]
            ]
        )
        if let country = LiveLeagueCountryResolver.normalizedCountry(explicitCountry) {
            return country
        }
        return LiveLeagueCountryResolver.country(for: Self.clean(league) ?? "")
    }

#if DEBUG
    private var payloadProviderDebugDescription: String {
        Self.firstString(
            in: payload,
            keys: [
                "provider",
                "source",
                "external_source",
                "strSource",
                "apiProvider"
            ],
            paths: [
                ["provider", "name"],
                ["source", "name"],
                ["meta", "provider"],
                ["meta", "source"]
            ]
        ) ?? "supabase:live_matches/TheSportsDB"
    }

    private var rawVenuePayloadDebugDescription: String {
        guard let payload else { return "nil" }
        let subset = payload.filter { key, _ in
            let lowered = key.lowercased()
            return lowered.contains("venue")
                || lowered.contains("stadium")
                || lowered.contains("arena")
                || lowered.contains("city")
                || lowered.contains("location")
        }
        guard !subset.isEmpty else { return "{}" }
        return LiveMatchPayloadValue.debugJSONString(for: subset)
    }
#endif

    private static func clean(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func firstString(
        in payload: [String: LiveMatchPayloadValue]?,
        keys: [String],
        paths: [[String]] = []
    ) -> String? {
        guard let payload else { return nil }
        let lowercased = lowercasedPayload(payload)
        for key in keys {
            guard let value = lowercased[key.lowercased()]?.stringValue else { continue }
            let cleaned = clean(value)
            if let cleaned { return cleaned }
        }
        for path in paths {
            guard let value = value(in: lowercased, path: path)?.stringValue else { continue }
            let cleaned = clean(value)
            if let cleaned { return cleaned }
        }
        return nil
    }

    private static func firstDouble(
        in payload: [String: LiveMatchPayloadValue]?,
        keys: [String],
        paths: [[String]]
    ) -> Double? {
        guard let payload else { return nil }
        let lowercased = lowercasedPayload(payload)
        for key in keys {
            guard let value = lowercased[key.lowercased()]?.doubleValue else { continue }
            return value
        }
        for path in paths {
            guard let value = value(in: lowercased, path: path)?.doubleValue else { continue }
            return value
        }
        return nil
    }

    private static func lowercasedPayload(_ payload: [String: LiveMatchPayloadValue]) -> [String: LiveMatchPayloadValue] {
        var lowercased: [String: LiveMatchPayloadValue] = [:]
        for (key, value) in payload {
            lowercased[key.lowercased()] = value
        }
        return lowercased
    }

    private static func value(
        in payload: [String: LiveMatchPayloadValue],
        path: [String]
    ) -> LiveMatchPayloadValue? {
        guard let first = path.first else { return nil }
        guard let value = payload[first.lowercased()] else { return nil }
        guard path.count > 1 else { return value }
        guard case .object(let nested) = value else { return nil }
        return Self.value(in: lowercasedPayload(nested), path: Array(path.dropFirst()))
    }

}

private nonisolated indirect enum LiveMatchPayloadValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: LiveMatchPayloadValue])
    case array([LiveMatchPayloadValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: LiveMatchPayloadValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([LiveMatchPayloadValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        case .object, .array, .null:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .string(let value):
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .bool, .object, .array, .null:
            return nil
        }
    }

#if DEBUG
    static func debugJSONString(for object: [String: LiveMatchPayloadValue]) -> String {
        let jsonObject = object.mapValues { $0.debugObject }
        guard JSONSerialization.isValidJSONObject(jsonObject),
              let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]),
              let raw = String(data: data, encoding: .utf8) else {
            return "\(jsonObject)"
        }
        return raw
    }

    private var debugObject: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues { $0.debugObject }
        case .array(let value):
            return value.map { $0.debugObject }
        case .null:
            return NSNull()
        }
    }
#endif
}

private nonisolated struct LiveMatchDateDotRow: Decodable {
    let start_time: String
}
