import Foundation
import Combine
import Supabase
import SwiftUI

nonisolated struct SavedProGame: Identifiable, Codable, Equatable {
    let id: String
    let source: String?
    let externalId: String?
    let homeTeam: String
    let awayTeam: String
    let league: String
    let sport: String
    let startTime: Date
    let matchStatus: MatchStatus
    let scoreHome: Int
    let scoreAway: Int
    let featuredEventSlug: String?
    let tvSummary: String?
    let rawMatchStatus: String?
    let minute: Int?
    let liveClockText: String?
    let timelineEvents: [LiveTimelineEvent]?
    let savedAt: Date

    init(
        id: String,
        source: String?,
        externalId: String?,
        homeTeam: String,
        awayTeam: String,
        league: String,
        sport: String,
        startTime: Date,
        matchStatus: MatchStatus,
        scoreHome: Int,
        scoreAway: Int,
        featuredEventSlug: String?,
        tvSummary: String?,
        rawMatchStatus: String? = nil,
        minute: Int? = nil,
        liveClockText: String? = nil,
        timelineEvents: [LiveTimelineEvent]? = nil,
        savedAt: Date
    ) {
        self.id = id
        self.source = source
        self.externalId = externalId
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.league = league
        self.sport = sport
        self.startTime = startTime
        self.matchStatus = matchStatus
        self.scoreHome = scoreHome
        self.scoreAway = scoreAway
        self.featuredEventSlug = featuredEventSlug
        self.tvSummary = tvSummary
        self.rawMatchStatus = rawMatchStatus
        self.minute = minute
        self.liveClockText = liveClockText
        self.timelineEvents = timelineEvents
        self.savedAt = savedAt
    }

    init(match: LiveMatch, savedAt: Date = Date()) {
        self.id = match.id
        self.source = match.source
        self.externalId = match.externalId
        self.homeTeam = match.homeTeam
        self.awayTeam = match.awayTeam
        self.league = match.league
        self.sport = match.sport
        self.startTime = match.startTime
        self.matchStatus = match.matchStatus
        self.scoreHome = match.scoreHome
        self.scoreAway = match.scoreAway
        self.featuredEventSlug = match.featuredEventSlug
        self.tvSummary = match.tvDisplayText
        self.rawMatchStatus = match.rawMatchStatus
        self.minute = match.minute
        self.liveClockText = match.liveClockText
        self.timelineEvents = match.timelineEvents
        self.savedAt = savedAt
    }

    var liveSportVisualType: LiveSportVisualType {
        LiveSportVisualType.normalize(sport)
    }

    var latestScoringEventResolution: LiveScoringEventResolution {
        LiveScoringEventResolver.resolve(
            sportType: liveSportVisualType,
            timelineEvents: timelineEvents ?? []
        )
    }

    var latestScoringEvent: LiveLatestScoringEvent? {
        latestScoringEventResolution.latestEvent
    }

    var scoringTimelineSummary: LiveScoringTimelineSummary? {
        LiveScoringTimelineBuilder.build(
            sportType: liveSportVisualType,
            timelineEvents: timelineEvents ?? [],
            homeTeam: homeTeam,
            awayTeam: awayTeam
        )
    }

    var scoringEventsCount: Int {
        scoringTimelineSummary?.entries.count ?? 0
    }

    var firstScoringEvent: LiveFirstScoringEvent? {
        LiveScoringTimelineBuilder.resolveFirstScoringEvent(
            sportType: liveSportVisualType,
            timelineEvents: timelineEvents ?? [],
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            scoreAway: scoreAway,
            scoreHome: scoreHome
        )
    }

    var firstScoringTeam: String? {
        firstScoringEvent?.teamName
    }

    var firstScoringMinute: Int? {
        firstScoringEvent?.minute
    }

    var goalScorersCardTimelineSummary: LiveScoringTimelineSummary? {
        LiveScoringTimelineBuilder.buildForGoalScorersCard(
            sportType: liveSportVisualType,
            timelineEvents: timelineEvents ?? [],
            homeTeam: homeTeam,
            awayTeam: awayTeam
        )
    }

    var resolvedGoalDisplaySummary: LiveScoringTimelineSummary? {
        LiveScoringTimelineBuilder.resolvedGoalDisplaySummary(
            sportType: liveSportVisualType,
            timelineEvents: timelineEvents ?? [],
            scoreAway: scoreAway,
            scoreHome: scoreHome,
            awayTeam: awayTeam,
            homeTeam: homeTeam,
            flagSource: "GoingPro"
        )
    }

    var rawScoringTimelineEventsCount: Int {
        LiveScoringTimelineBuilder.countScoringTimelineEvents(
            sportType: liveSportVisualType,
            timelineEvents: timelineEvents ?? []
        )
    }

    var goalScorersCardRenderedEventCount: Int {
        goalScorersCardTimelineSummary?.entries.count ?? 0
    }

    var resolvedProviderExternalId: String? {
        if let externalId = externalId?.trimmingCharacters(in: .whitespacesAndNewlines), !externalId.isEmpty {
            if let numeric = Self.numericProviderId(from: externalId) {
                return numeric
            }
            return externalId
        }
        return Self.numericProviderId(from: id) ?? Self.numericProviderId(from: stableKey)
    }

    static func directHydrationLookupIds(for saved: SavedProGame) -> [String] {
        var ids = Set<String>()
        func add(_ raw: String?) {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            ids.insert(trimmed)
        }

        add(saved.id)
        add(saved.stableKey)
        add(saved.externalId)
        if let providerId = saved.resolvedProviderExternalId {
            add(providerId)
            add("thesportsdb:\(providerId)")
            if let source = saved.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
                add("\(source):\(providerId)")
            }
        }
        return Array(ids)
    }

    static func directlyMatchesSavedProGame(_ match: LiveMatch, _ saved: SavedProGame) -> Bool {
        let matchId = normalizedHydrationToken(match.id)
        let savedId = normalizedHydrationToken(saved.id)
        let savedStableKey = normalizedHydrationToken(saved.stableKey)
        if !matchId.isEmpty, matchId == savedId || matchId == savedStableKey {
            return true
        }

        if let source = saved.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
           let externalId = saved.resolvedProviderExternalId,
           match.source?.caseInsensitiveCompare(source) == .orderedSame {
            let matchExternal = normalizedHydrationToken(match.externalId)
            let savedExternal = normalizedHydrationToken(externalId)
            if matchExternal == savedExternal { return true }
        }

        if let providerId = saved.resolvedProviderExternalId {
            let matchExternal = normalizedHydrationToken(match.externalId)
            if matchExternal == normalizedHydrationToken(providerId) { return true }
        }

        return SavedProGame.stableKey(for: match) == saved.stableKey
    }

    static func normalizedHydrationToken(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased() ?? ""
    }

    private static func numericProviderId(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isNumber) { return trimmed }
        if let suffix = trimmed.split(separator: ":").last {
            let candidate = String(suffix)
            if candidate.allSatisfy(\.isNumber) { return candidate }
        }
        return nil
    }

    var stableKey: String {
        Self.stableKey(
            id: id,
            source: source,
            externalId: externalId,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            league: league,
            startTime: startTime
        )
    }

    static func stableKey(for match: LiveMatch) -> String {
        stableKey(
            id: match.id,
            source: match.source,
            externalId: match.externalId,
            homeTeam: match.homeTeam,
            awayTeam: match.awayTeam,
            league: match.league,
            startTime: match.startTime
        )
    }

    private static func stableKey(
        id: String,
        source: String?,
        externalId: String?,
        homeTeam: String,
        awayTeam: String,
        league: String,
        startTime: Date
    ) -> String {
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedId.isEmpty { return trimmedId }
        let sourcePart = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let externalPart = externalId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sourcePart.isEmpty, !externalPart.isEmpty {
            return "\(sourcePart):\(externalPart)"
        }
        let participantPart = [awayTeam, homeTeam, league]
            .map { LiveMatchFilters.normalizedSearchText($0) }
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        return "derived:\(participantPart):\(Int(startTime.timeIntervalSince1970))"
    }
}

extension SavedProGame {
    nonisolated var isFinal: Bool { matchStatus == .fullTime }

    nonisolated var finalScoreSummary: String {
        ProGameNotificationFormatting.scoreline(
            awayTeam: awayTeam,
            awayScore: scoreAway,
            homeTeam: homeTeam,
            homeScore: scoreHome
        )
    }

    nonisolated static func displaySort(_ lhs: SavedProGame, _ rhs: SavedProGame) -> Bool {
        let lhsRank = displayStatusRank(lhs.matchStatus)
        let rhsRank = displayStatusRank(rhs.matchStatus)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        if lhs.savedAt != rhs.savedAt { return lhs.savedAt > rhs.savedAt }
        return lhs.stableKey < rhs.stableKey
    }

    nonisolated private static func displayStatusRank(_ status: MatchStatus) -> Int {
        if status.isHappeningNow { return 0 }
        if status == .scheduled { return 1 }
        if status == .fullTime { return 2 }
        return 3
    }

    nonisolated static func freshestSnapshot(_ lhs: SavedProGame, _ rhs: SavedProGame) -> SavedProGame {
        let lhsRank = freshnessRank(lhs.matchStatus)
        let rhsRank = freshnessRank(rhs.matchStatus)
        if lhsRank != rhsRank { return lhsRank > rhsRank ? lhs : rhs }
        return lhs.savedAt >= rhs.savedAt ? lhs : rhs
    }

    nonisolated private static func freshnessRank(_ status: MatchStatus) -> Int {
        if status == .fullTime { return 3 }
        if status.isHappeningNow { return 2 }
        if status == .scheduled { return 1 }
        return 0
    }
}

nonisolated enum ProGamesFavoriteTeamAutoFollowPreference {
    static let enabledKey = "gameon.proGames.favoriteTeams.autoFollowEnabled.v1"
    static let windowDaysKey = "gameon.proGames.favoriteTeams.windowDays.v1"

    enum Window: Int, CaseIterable, Identifiable {
        case next7 = 7
        case next30 = 30
        case next90 = 90

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .next7:
                return "Next 7 days"
            case .next30:
                return "Next 30 days"
            case .next90:
                return "Next 90 days"
            }
        }

        static func resolved(rawValue: Int) -> Window {
            Window(rawValue: rawValue) ?? .next30
        }
    }
}

nonisolated struct FavoriteTeamProGame: Identifiable, Equatable {
    let game: SavedProGame
    let favoriteTeamID: String
    let favoriteTeamName: String

    var id: String { game.stableKey }
    var favoriteTeamReason: String { favoriteTeamName }
}

extension MapViewModel {
    private static let savedProGamesLegacyGlobalDefaultsKey = "gameon.savedProGames.v1"
    private static let savedProGamesGuestDefaultsKey = "gameon.savedProGames.guest.v1"
    private static let deliveredSavedProGameFinalNotificationsKey = "gameon.savedProGameFinalNotifications.v1"
    private static let deliveredSavedProGameHalftimeNotificationsKey = "gameon.savedProGameHalftimeNotifications.v1"
    private static let deliveredSavedProGamePredictionResultNotificationsKey = "gameon.savedProGamePredictionResultNotifications.v1"
    private static let deliveredSavedProGameScoreNotificationsKey = "gameon.savedProGameScoreNotifications.v1"
    private static let deliveredSavedProGameCardNotificationsKey = "gameon.savedProGameCardNotifications.v1"
    private static let savedProGameScoreUpdatePreferencesKey = "gameon.savedProGameScoreUpdatePreferences.v1"
    private static let legacySportDefaultsMigrationKeyPrefix = "gameon.savedProGameScoreUpdatePreferences.legacySportDefaultsMigrated.v1"
    private static let legacyProGameScoreUpdateDefaults: [(key: String, sportTokens: [String], defaultValue: Bool)] = [
        ("proGameSoccerScoreUpdateNotifications", ["soccer", "football"], true),
        ("proGameBasketballScoreUpdateNotifications", ["basketball", "nba"], false),
        ("proGameFootballScoreUpdateNotifications", ["american football", "nfl", "gridiron", "us football"], false),
        ("proGameBaseballScoreUpdateNotifications", ["baseball", "mlb"], false),
        ("proGameHockeyScoreUpdateNotifications", ["hockey", "nhl", "ice hockey"], false),
        ("proGameTennisScoreUpdateNotifications", ["tennis"], false),
        ("proGameGolfScoreUpdateNotifications", ["golf"], false),
        ("proGameRacingScoreUpdateNotifications", ["racing", "formula", "f1", "motorsport"], false),
        ("proGameCombatScoreUpdateNotifications", ["combat", "mma", "ufc", "boxing"], false)
    ]
    private static let savedProGamesSelectColumns = "live_match_id,source,external_id,home_team,away_team,league,sport,start_time,match_status,score_home,score_away,featured_event_slug,tv_summary,score_alerts_enabled,created_at"

    private struct SavedProGameHydrationMatch {
        let match: LiveMatch
        let matchedBy: String
    }

    func reloadSavedProGamesFromStorage() {
        if let userID = currentUserAuthId {
            reloadSavedProGamesFromStorage(for: userID)
        } else {
            logLegacySavedProGamesCacheIfPresent(context: "signedOut")
            savedProGames = []
        }
    }

    func reloadSavedProGamesFromStorage(for userID: UUID) {
        logLegacySavedProGamesCacheIfPresent(context: "authenticatedIgnored")
        savedProGames = Self.decodeSavedProGames(storageKey: Self.savedProGamesDefaultsKey(for: userID))
        ensureSavedProGameScoreUpdatePreferencesExist(for: savedProGames)
    }

    func clearSavedProGamesForSessionBoundary() {
        savedProGames = []
        savedProGamesFetchTask?.cancel()
        savedProGamesFetchTask = nil
        lastSavedProGamesFetchAt = nil
        lastSavedProGamesFetchUserId = nil
    }

    func fetchSavedProGames(forceRefresh: Bool = false, reason: String = "ordinary") async {
        guard let userID = currentUserAuthId, isAuthenticatedForSocialFeatures else {
            clearSavedProGamesForSessionBoundary()
            return
        }

        let scopedCacheKey = Self.savedProGamesDefaultsKey(for: userID)
        let localSnapshots = Self.decodeSavedProGames(storageKey: scopedCacheKey)
        if savedProGames.isEmpty || forceRefresh {
            savedProGames = localSnapshots
            ensureSavedProGameScoreUpdatePreferencesExist(for: localSnapshots)
        }

        if !forceRefresh,
           lastSavedProGamesFetchUserId == userID,
           let lastSavedProGamesFetchAt {
            let age = Date().timeIntervalSince(lastSavedProGamesFetchAt)
            if age < 45 {
#if DEBUG
                print("[TabPerfDebug] cacheAge=\(String(format: "%.1f", age)) tab=going source=savedProGames")
                print("[TabPerfDebug] usedCachedData=true tab=going source=savedProGames")
                print("[TabPerfDebug] refreshSkippedReason=fresh tab=going source=savedProGames reason=\(reason)")
#endif
                skipProGamesCalendarReconcileAtStartup(reason: "savedProGamesFresh:\(reason)")
                if LaunchBootstrapState.didBecomeAppReady {
                    scheduleDeferredProGamesAppleCalendarReconcileAfterAppReady(
                        reason: "savedProGamesFresh:\(reason)",
                        replaceExisting: true
                    )
                }
                return
            }
        }

        if !forceRefresh, let existing = savedProGamesFetchTask {
#if DEBUG
            print("[TabPerfDebug] refreshCoalesced=true tab=going source=savedProGames reason=\(reason)")
#endif
            await existing.value
            return
        }

        let startedAt = Date()
#if DEBUG
        print("[TabPerfDebug] refreshStarted=going source=savedProGames force=\(forceRefresh) reason=\(reason)")
#endif

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchSavedProGamesFromRemote(
                userID: userID,
                localSnapshots: localSnapshots,
                reason: reason
            )
        }
        savedProGamesFetchTask = task
        await task.value
        savedProGamesFetchTask = nil
#if DEBUG
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("[TabPerfDebug] refreshDurationMs=\(ms) tab=going source=savedProGames reason=\(reason)")
#endif
    }

    private func fetchSavedProGamesFromRemote(
        userID: UUID,
        localSnapshots: [SavedProGame],
        reason _: String
    ) async {
        do {
            let rows: [SavedProGameSupabaseRow] = try await supabase
                .from("saved_pro_games")
                .select(Self.savedProGamesSelectColumns)
                .eq("user_id", value: userID.uuidString.lowercased())
                .order("start_time", ascending: true)
                .execute()
                .value

            let remoteSnapshots = rows.compactMap(\.savedProGame)
            applyRemoteSavedProGameScoreAlertPreferences(rows)
            let remoteKeys = Set(remoteSnapshots.map(\.stableKey))
            let merged = Self.mergedSavedProGames(local: localSnapshots, remote: remoteSnapshots)
            guard currentUserAuthId == userID else {
#if DEBUG
                print("[SavedProGames] fetchDiscarded reason=sessionChanged userId=\(userID.uuidString.lowercased())")
#endif
                return
            }
            savedProGames = merged
            ensureSavedProGameScoreUpdatePreferencesExist(for: merged)
            persistSavedProGames(for: userID)
            lastSavedProGamesFetchAt = Date()
            lastSavedProGamesFetchUserId = userID
            await reconcileSavedProGameReminders(reason: "savedProGamesFetch")
            skipProGamesCalendarReconcileAtStartup(reason: "savedProGamesFetch")
            if LaunchBootstrapState.didBecomeAppReady {
                scheduleDeferredProGamesAppleCalendarReconcileAfterAppReady(
                    reason: "savedProGamesFetch",
                    replaceExisting: true
                )
            }

            for snapshot in localSnapshots where !remoteKeys.contains(snapshot.stableKey) {
                guard currentUserAuthId == userID else { return }
                do {
                    try await upsertSavedProGameToSupabase(snapshot, userID: userID)
                } catch {
#if DEBUG
                    print("[SavedProGames] localBackfillFailed id=\(snapshot.stableKey) error=\(error.localizedDescription)")
#endif
                }
            }
        } catch {
#if DEBUG
            print("[SavedProGames] fetchFailed error=\(error.localizedDescription)")
#endif
            guard currentUserAuthId == userID else { return }
            if savedProGames.isEmpty {
                savedProGames = localSnapshots
                ensureSavedProGameScoreUpdatePreferencesExist(for: localSnapshots)
            }
            skipProGamesCalendarReconcileAtStartup(reason: "savedProGamesFetchFallback")
            if LaunchBootstrapState.didBecomeAppReady {
                scheduleDeferredProGamesAppleCalendarReconcileAfterAppReady(
                    reason: "savedProGamesFetchFallback",
                    replaceExisting: true
                )
            }
        }
    }

    func refreshGoingProGames(reason: String) async {
#if DEBUG
        print("[GoingProRefreshDebug] refresh started reason=\(reason)")
#endif
        var previousSnapshots: [String: SavedProGame] = [:]
        for savedGame in savedProGames {
            previousSnapshots[savedGame.stableKey] = currentSavedProGameSnapshot(savedGame)
        }
        var refreshedMatches: [LiveMatch] = []
        var liveSyncSucceeded = false

        do {
            refreshedMatches = try await LiveSportsService.shared.fetchLiveMatches(forceRefresh: true)
            let directHydrationMatches = try await LiveSportsService.shared.fetchLiveMatchesForSavedProGameHydration(savedProGames)
            refreshedMatches = Self.mergeLiveMatches(refreshedMatches, with: directHydrationMatches)
            liveSyncSucceeded = true
            mergeGoingProRefreshMatchesIntoLiveMatches(refreshedMatches)
        } catch {
#if DEBUG
            print("[GoingProRefreshDebug] live sync error=\(error.localizedDescription)")
#endif
            refreshedMatches = liveMatches
        }

#if DEBUG
        print("[GoingProRefreshDebug] live sync success=\(liveSyncSucceeded)")
#endif
        await fetchSavedProGames(forceRefresh: true, reason: "goingProRefresh:\(reason)")
#if DEBUG
        print("[GoingProRefreshDebug] saved games fetched=\(savedProGames.count)")
#endif
        let uiUpdated = handleSavedProGameStatusUpdates(
            from: refreshedMatches,
            reason: "goingProRefresh:\(reason)"
        )

#if DEBUG
        for saved in savedProGames {
            let previous = previousSnapshots[saved.stableKey]
            print("[GoingProRefreshDebug] hydrated game=\(saved.stableKey)")
            print("[GoingProRefreshDebug] old score=\(previous.map { "\($0.scoreAway)-\($0.scoreHome)" } ?? "nil")")
            print("[GoingProRefreshDebug] new score=\(saved.scoreAway)-\(saved.scoreHome)")
            print("[GoingProRefreshDebug] status=\(saved.matchStatus.rawValue)")
            print("[GoingProRefreshDebug] savedAfterStatus=\(saved.matchStatus.rawValue)")
            print("[GoingProRefreshDebug] finalCardState=\(saved.isFinal)")
        }
        print("[GoingProRefreshDebug] UI updated=\(uiUpdated)")
#endif
    }

    func isProGameSaved(_ match: LiveMatch) -> Bool {
        let key = SavedProGame.stableKey(for: match)
        return savedProGames.contains { $0.stableKey == key }
    }

    func toggleSavedProGame(_ match: LiveMatch) {
        if isProGameSaved(match) {
            unsaveProGame(id: SavedProGame.stableKey(for: match))
            showSocialActionToast("Removed from Pro Games.", isError: false)
        } else {
            saveProGame(match)
            showSocialActionToast("Saved to Going.", isError: false)
        }
    }

    func saveProGame(_ match: LiveMatch) {
        let snapshot = SavedProGame(match: match)
        savedProGames.removeAll { $0.stableKey == snapshot.stableKey }
        savedProGames.append(snapshot)
        setSavedProGameScoreUpdatesEnabled(
            true,
            for: snapshot,
            sendsChange: false
        )
        sortSavedProGames()
        persistSavedProGames()
        Task { [weak self] in
            guard let self else { return }
            await self.scheduleProGameReminderIfPossible(snapshot)
            await self.syncSavedProGameToAppleCalendar(
                snapshot,
                action: "save",
                forceBypassFreshness: true
            )
        }

        guard let userID = currentUserAuthId, isAuthenticatedForSocialFeatures else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.upsertSavedProGameToSupabase(snapshot, userID: userID)
            } catch {
#if DEBUG
                print("[SavedProGames] saveRemoteFailed id=\(snapshot.stableKey) error=\(error.localizedDescription)")
#endif
            }
        }
    }

    func unsaveProGame(id: String) {
        let savedGame = savedProGames.first { $0.stableKey == id || $0.id == id }
        let remoteLiveMatchId = savedGame?.id ?? id
        let reminderIdentifier = savedGame?.stableKey ?? id
        savedProGames.removeAll { $0.stableKey == id || $0.id == id }
        clearSavedProGameScoreUpdatePreference(identifier: reminderIdentifier)
        persistSavedProGames()
        Task { [weak self] in
            guard let self else { return }
            await self.cancelProGameReminder(savedGameIdentifier: reminderIdentifier)
            await GameReminderNotificationService.shared.cancelProGameFinalNotification(identifier: reminderIdentifier)
            await GameReminderNotificationService.shared.cancelProGameHalftimeNotification(identifier: reminderIdentifier)
            await GameReminderNotificationService.shared.cancelProGamePredictionResultNotification(identifier: reminderIdentifier)
            await GameReminderNotificationService.shared.cancelProGameScoreUpdateNotifications(identifier: reminderIdentifier)
            await self.removeSavedProGameFromAppleCalendar(
                identifier: reminderIdentifier,
                action: "remove",
                forceBypassFreshness: true
            )
            await self.deleteProGamePredictionsForUnsave(proGameId: reminderIdentifier)
        }

        guard let userID = currentUserAuthId, isAuthenticatedForSocialFeatures else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.deleteSavedProGameFromSupabase(liveMatchId: remoteLiveMatchId, userID: userID)
            } catch {
#if DEBUG
                print("[SavedProGames] deleteRemoteFailed id=\(remoteLiveMatchId) error=\(error.localizedDescription)")
#endif
            }
        }
    }

    func removeSavedProGame(id: String) {
        unsaveProGame(id: id)
    }

    func currentSavedProGameSnapshot(_ saved: SavedProGame) -> SavedProGame {
        guard let hydration = freshestLiveMatch(for: saved) else {
            let fallback = staleLiveFinalCandidateDisplaySnapshot(for: saved, reason: "currentSnapshot")
#if DEBUG
            logSavedProGameHydrationDebug(saved: saved, hydration: nil, merged: fallback ?? saved)
#endif
            return fallback ?? saved
        }
        let merged = hydratedSavedProGame(saved, with: hydration.match)
#if DEBUG
        logSavedProGameHydrationDebug(saved: saved, hydration: hydration, merged: merged)
#endif
        return merged
    }

    func savedProGameDisplayStatusDebugSource(for saved: SavedProGame) -> (game: SavedProGame, source: String) {
        guard let hydration = freshestLiveMatch(for: saved) else {
            if let fallback = staleLiveFinalCandidateDisplaySnapshot(for: saved, reason: "displayStatusDebug") {
                return (fallback, "stale live fallback")
            }
            return (saved, "saved row")
        }
        return (hydratedSavedProGame(saved, with: hydration.match), hydration.matchedBy)
    }

    private func freshestLiveMatch(for saved: SavedProGame) -> SavedProGameHydrationMatch? {
        freshestLiveMatch(for: saved, in: liveMatches)
    }

    private func freshestLiveMatch(for saved: SavedProGame, in candidateMatches: [LiveMatch]) -> SavedProGameHydrationMatch? {
        let savedId = SavedProGame.normalizedHydrationToken(saved.id)
        let savedStableKey = SavedProGame.normalizedHydrationToken(saved.stableKey)
        if let direct = candidateMatches.first(where: { match in
            let matchId = SavedProGame.normalizedHydrationToken(match.id)
            return !matchId.isEmpty && (matchId == savedId || matchId == savedStableKey)
        }) {
            return SavedProGameHydrationMatch(match: direct, matchedBy: "directId")
        }

        if let source = saved.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
           let externalId = saved.resolvedProviderExternalId,
           let externalMatch = candidateMatches.first(where: { match in
               guard match.source?.caseInsensitiveCompare(source) == .orderedSame else { return false }
               let matchExternal = SavedProGame.normalizedHydrationToken(match.externalId)
               return matchExternal == SavedProGame.normalizedHydrationToken(externalId)
           }) {
            return SavedProGameHydrationMatch(match: externalMatch, matchedBy: "directExternalId")
        }

        if let providerId = saved.resolvedProviderExternalId,
           let externalMatch = candidateMatches.first(where: { match in
               SavedProGame.normalizedHydrationToken(match.externalId) == SavedProGame.normalizedHydrationToken(providerId)
           }) {
            return SavedProGameHydrationMatch(match: externalMatch, matchedBy: "directExternalId")
        }

        if let exact = candidateMatches.first(where: { SavedProGame.stableKey(for: $0) == saved.stableKey }) {
            return SavedProGameHydrationMatch(match: exact, matchedBy: "stableKey")
        }

        if let source = saved.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
           let externalId = saved.externalId?.trimmingCharacters(in: .whitespacesAndNewlines), !externalId.isEmpty,
           let externalMatch = candidateMatches.first(where: { match in
               match.source?.caseInsensitiveCompare(source) == .orderedSame
                   && match.externalId?.caseInsensitiveCompare(externalId) == .orderedSame
           }) {
            return SavedProGameHydrationMatch(match: externalMatch, matchedBy: "source+externalId")
        }

        let savedIdentifiers = savedProGameHydrationIdentifiers(
            id: saved.id,
            externalId: saved.externalId,
            source: saved.source
        )
        if !savedIdentifiers.isEmpty,
           let providerMatch = candidateMatches.first(where: { match in
               !savedIdentifiers.isDisjoint(with: savedProGameHydrationIdentifiers(
                   id: match.id,
                   externalId: match.externalId,
                   source: match.source
               ))
           }) {
            return SavedProGameHydrationMatch(match: providerMatch, matchedBy: "providerId")
        }

        let savedAway = LiveMatchFilters.normalizedSearchText(saved.awayTeam)
        let savedHome = LiveMatchFilters.normalizedSearchText(saved.homeTeam)
        let savedLeague = LiveMatchFilters.normalizedSearchText(saved.league)
        let savedSport = LiveSportVisualType.normalize(saved.sport)
        guard !savedAway.isEmpty, !savedHome.isEmpty else { return nil }

        let fallbackMatches = candidateMatches.filter { match in
            let matchAway = LiveMatchFilters.normalizedSearchText(match.awayTeam)
            let matchHome = LiveMatchFilters.normalizedSearchText(match.homeTeam)
            guard matchAway == savedAway, matchHome == savedHome else { return false }

            let startsNearSavedTime = abs(match.startTime.timeIntervalSince(saved.startTime)) <= 6 * 60 * 60
            let sameDay = Calendar.current.isDate(match.startTime, inSameDayAs: saved.startTime)
            guard startsNearSavedTime || sameDay else { return false }

            guard savedSport == LiveSportVisualType.normalize(match.sport) else { return false }

            let matchLeague = LiveMatchFilters.normalizedSearchText(match.league)
            if !savedLeague.isEmpty, !matchLeague.isEmpty, savedLeague != matchLeague {
                return startsNearSavedTime
            }
            return true
        }
        guard fallbackMatches.count == 1, let fallback = fallbackMatches.first else { return nil }
        return SavedProGameHydrationMatch(match: fallback, matchedBy: "teams+date")
    }

    private func hydratedSavedProGame(_ saved: SavedProGame, with match: LiveMatch) -> SavedProGame {
        SavedProGame(
            id: saved.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? match.id : saved.id,
            source: saved.source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? saved.source : match.source,
            externalId: saved.externalId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? saved.externalId : match.externalId,
            homeTeam: match.homeTeam,
            awayTeam: match.awayTeam,
            league: match.league,
            sport: match.sport,
            startTime: match.startTime,
            matchStatus: match.matchStatus,
            scoreHome: match.scoreHome,
            scoreAway: match.scoreAway,
            featuredEventSlug: match.featuredEventSlug ?? saved.featuredEventSlug,
            tvSummary: match.tvDisplayText ?? saved.tvSummary,
            rawMatchStatus: match.rawMatchStatus,
            minute: match.minute ?? saved.minute,
            liveClockText: match.liveClockText ?? saved.liveClockText,
            timelineEvents: Self.preferredTimelineEvents(from: match, saved: saved),
            savedAt: saved.savedAt
        )
    }

    private static func preferredTimelineEvents(from match: LiveMatch, saved: SavedProGame) -> [LiveTimelineEvent]? {
        let merged = mergeTimelineEvents(match.timelineEvents, saved.timelineEvents ?? [])
        return merged.isEmpty ? nil : merged
    }

    private static func mergeTimelineEvents(
        _ matchEvents: [LiveTimelineEvent],
        _ savedEvents: [LiveTimelineEvent]
    ) -> [LiveTimelineEvent] {
        var byKey: [String: LiveTimelineEvent] = [:]
        for event in matchEvents + savedEvents {
            byKey[event.id] = event
        }
        return Array(byKey.values)
    }

    private func staleLiveFinalCandidateDisplaySnapshot(for saved: SavedProGame, reason: String) -> SavedProGame? {
        guard isStaleLiveFinalCandidate(saved) else { return nil }
#if DEBUG
        print("[GoingProRefreshDebug] staleFinalCandidate=true id=\(saved.stableKey) reason=\(reason) elapsedHours=\(String(format: "%.1f", Date().timeIntervalSince(saved.startTime) / 3600)) score=\(saved.scoreAway)-\(saved.scoreHome) savedStatus=\(saved.matchStatus.rawValue)")
#endif
        return SavedProGame(
            id: saved.id,
            source: saved.source,
            externalId: saved.externalId,
            homeTeam: saved.homeTeam,
            awayTeam: saved.awayTeam,
            league: saved.league,
            sport: saved.sport,
            startTime: saved.startTime,
            matchStatus: .fullTime,
            scoreHome: saved.scoreHome,
            scoreAway: saved.scoreAway,
            featuredEventSlug: saved.featuredEventSlug,
            tvSummary: saved.tvSummary,
            rawMatchStatus: saved.rawMatchStatus ?? "STALE_LIVE_FALLBACK",
            minute: saved.minute,
            liveClockText: saved.liveClockText,
            timelineEvents: saved.timelineEvents,
            savedAt: saved.savedAt
        )
    }

    private func isStaleLiveFinalCandidate(_ saved: SavedProGame, now: Date = Date()) -> Bool {
        guard saved.matchStatus.isHappeningNow else { return false }
        guard saved.scoreHome > 0 || saved.scoreAway > 0 else { return false }
        return now.timeIntervalSince(saved.startTime) >= staleLiveFinalCandidateThreshold(for: saved)
    }

    private func staleLiveFinalCandidateThreshold(for saved: SavedProGame) -> TimeInterval {
        switch saved.liveSportVisualType {
        case .soccer:
            return 3 * 60 * 60
        case .basketball, .hockey:
            return 4 * 60 * 60
        case .baseball, .nfl:
            return 5 * 60 * 60
        default:
            return 4 * 60 * 60
        }
    }

    private func savedProGameHydrationIdentifiers(id: String, externalId: String?, source: String?) -> Set<String> {
        var identifiers = Set<String>()
        for raw in [id, externalId].compactMap({ $0 }) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            insertSavedProGameHydrationIdentifier(trimmed, into: &identifiers)
            if let last = trimmed.split(separator: ":").last {
                insertSavedProGameHydrationIdentifier(String(last), into: &identifiers)
            }
            if let source {
                let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalizedSource.isEmpty {
                    insertSavedProGameHydrationIdentifier("\(normalizedSource):\(trimmed)", into: &identifiers)
                }
            }
        }
        return identifiers
    }

    private func insertSavedProGameHydrationIdentifier(_ raw: String, into identifiers: inout Set<String>) {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        guard !normalized.isEmpty else { return }
        identifiers.insert(normalized)
    }

#if DEBUG
    private func logSavedProGameHydrationDebug(
        saved: SavedProGame,
        hydration: SavedProGameHydrationMatch?,
        merged: SavedProGame
    ) {
        guard SavedProGameStatusDiagnostics.enabled else { return }
        let fresh = hydration?.match
        let matchedBy = hydration?.matchedBy ?? "none"
        print("[SavedProGameHydrationDebug] directIdLookupAttempt=\(saved.stableKey)")
        print("[SavedProGameHydrationDebug] directIdLookupFound=\(matchedBy == "directId")")
        print("[SavedProGameHydrationDebug] directExternalIdLookupFound=\(matchedBy == "directExternalId")")
        print("[SavedProGameHydrationDebug] liveMatchRowTimelineCount=\(fresh?.timelineEvents.count ?? 0)")
        print("[SavedProGameHydrationDebug] mergedTimelineCount=\(merged.timelineEvents?.count ?? 0)")
        print("[SavedProGameHydrationDebug] mergedScoringEventsCount=\(merged.scoringEventsCount)")
        print(
            "[SavedProGameHydrationDebug] " +
            "savedId=\(saved.stableKey) " +
            "providerId=\(saved.resolvedProviderExternalId ?? saved.externalId ?? saved.id) " +
            "teams=\"\(saved.awayTeam) at \(saved.homeTeam)\" " +
            "savedStatus=\(saved.matchStatus.rawValue) " +
            "freshStatus=\(fresh?.matchStatus.rawValue ?? "nil") " +
            "mergedStatus=\(merged.matchStatus.rawValue) " +
            "score=\(merged.scoreAway)-\(merged.scoreHome) " +
            "matchedBy=\(matchedBy) " +
            "freshTimelineCount=\(fresh?.timelineEvents.count ?? 0)"
        )
        logProGameFinalDebug(rawProviderStatus: fresh?.rawMatchStatus, normalizedStatus: merged.matchStatus)
    }

    private func logProGameFinalDebug(rawProviderStatus: String?, normalizedStatus: MatchStatus) {
        print("[ProGameFinalDebug] rawProviderStatus=\(rawProviderStatus ?? "nil")")
        print("[ProGameFinalDebug] normalizedStatus=\(normalizedStatus.rawValue)")
        print("[ProGameFinalDebug] isFinal=\(normalizedStatus == .fullTime)")
    }

    private func logProScoreRefreshDebug(
        saved: SavedProGame,
        previous: SavedProGame,
        fetched: SavedProGameHydrationMatch?,
        updated: SavedProGame,
        cacheUpdated: Bool,
        savedCardHydrated: Bool,
        reason: String
    ) {
        let fetchedMatch = fetched?.match
        print(
            "[ProScoreRefreshDebug] " +
            "gameId=\(saved.stableKey) " +
            "providerId=\(fetchedMatch?.externalId ?? fetchedMatch?.id ?? saved.externalId ?? saved.id) " +
            "teams=\"\(saved.awayTeam) at \(saved.homeTeam)\" " +
            "oldScore=\(savedProGameScoreToken(for: previous)) " +
            "fetchedScore=\(fetchedMatch.map { "\($0.scoreAway)-\($0.scoreHome)" } ?? "nil") " +
            "providerStatus=\(fetchedMatch?.rawMatchStatus ?? "nil") " +
            "savedBeforeStatus=\(saved.matchStatus.rawValue) " +
            "liveStatus=\(fetchedMatch?.matchStatus.rawValue ?? "nil") " +
            "normalizedStatus=\(updated.matchStatus.rawValue) " +
            "savedAfterStatus=\(updated.matchStatus.rawValue) " +
            "cacheUpdated=\(cacheUpdated) " +
            "savedCardHydrated=\(savedCardHydrated) " +
            "matchedBy=\(fetched?.matchedBy ?? "none") " +
            "reason=\(reason)"
        )
    }

    private func logProScoreNotificationDebug(
        game: SavedProGame,
        previous: SavedProGame,
        enabled: Bool,
        sent: Bool,
        skipReason: String?,
        reason: String
    ) {
        print(
            "[ProScoreNotificationDebug] " +
            "gameId=\(game.stableKey) " +
            "oldScore=\(savedProGameScoreToken(for: previous)) " +
            "newScore=\(savedProGameScoreToken(for: game)) " +
            "scoreUpdatesEnabled=\(enabled) " +
            "notification=\(sent ? "sent" : "skipped") " +
            "skipReason=\(skipReason ?? "none") " +
            "reason=\(reason)"
        )
    }
#endif

    @discardableResult
    func handleSavedProGameStatusUpdates(from matches: [LiveMatch], reason: String) -> Bool {
        guard !savedProGames.isEmpty else { return false }
        guard !matches.isEmpty else {
#if DEBUG
            for saved in savedProGames {
                print("[GoingProRefreshDebug] liveMatchFound=false id=\(saved.stableKey)")
                print("[GoingProRefreshDebug] hydrationSkippedReason=no_live_matches id=\(saved.stableKey)")
                _ = staleLiveFinalCandidateDisplaySnapshot(for: saved, reason: "\(reason):noLiveMatches")
            }
#endif
            return false
        }

        var changedSavedSnapshots = false
        var calendarSyncCandidates: [SavedProGame] = []

        for savedIndex in savedProGames.indices {
            let previousSavedSnapshot = savedProGames[savedIndex]
            let previousDisplaySnapshot = currentSavedProGameSnapshot(previousSavedSnapshot)
            guard let hydration = freshestLiveMatch(for: previousSavedSnapshot, in: matches) else {
#if DEBUG
                print("[GoingProRefreshDebug] liveMatchFound=false id=\(previousSavedSnapshot.stableKey)")
                print("[GoingProRefreshDebug] hydrationSkippedReason=no_matching_live_match id=\(previousSavedSnapshot.stableKey)")
                _ = staleLiveFinalCandidateDisplaySnapshot(for: previousSavedSnapshot, reason: "\(reason):noMatchingLiveMatch")
                logProScoreRefreshDebug(
                    saved: previousSavedSnapshot,
                    previous: previousDisplaySnapshot,
                    fetched: nil,
                    updated: previousDisplaySnapshot,
                    cacheUpdated: false,
                    savedCardHydrated: false,
                    reason: reason
                )
#endif
                continue
            }

            let updatedSnapshot = hydratedSavedProGame(previousSavedSnapshot, with: hydration.match)
#if DEBUG
            print("[GoingProRefreshDebug] liveMatchFound=true id=\(previousSavedSnapshot.stableKey) matchedBy=\(hydration.matchedBy)")
            print("[GoingProRefreshDebug] hydrationSkippedReason=none id=\(previousSavedSnapshot.stableKey)")
            logProScoreRefreshDebug(
                saved: previousSavedSnapshot,
                previous: previousDisplaySnapshot,
                fetched: hydration,
                updated: updatedSnapshot,
                cacheUpdated: updatedSnapshot != previousSavedSnapshot,
                savedCardHydrated: true,
                reason: reason
            )
#endif
            if updatedSnapshot != previousSavedSnapshot {
                savedProGames[savedIndex] = updatedSnapshot
                changedSavedSnapshots = true
                if savedProGameCalendarFieldsChanged(from: previousSavedSnapshot, to: updatedSnapshot) {
                    calendarSyncCandidates.append(updatedSnapshot)
                }
                if savedProGamePersistentFieldsChanged(from: previousSavedSnapshot, to: updatedSnapshot) {
                    persistHydratedSavedProGameToBackend(
                        updatedSnapshot,
                        previous: previousSavedSnapshot,
                        liveStatus: hydration.match.matchStatus,
                        reason: reason
                    )
                }
            }

            if savedProGameScoreDidChange(from: previousDisplaySnapshot, to: updatedSnapshot) {
                deliverSavedProGameScoreUpdateNotificationIfNeeded(updatedSnapshot, previous: previousDisplaySnapshot, reason: reason)
            }

            deliverSavedProGameCardNotificationsIfNeeded(
                updatedSnapshot,
                previous: previousDisplaySnapshot,
                alertsEnabled: savedProGameScoreUpdatesEnabled(for: updatedSnapshot),
                reason: reason
            )

            if previousDisplaySnapshot.matchStatus == .live,
               updatedSnapshot.matchStatus == .halfTime {
                deliverSavedProGameHalftimeNotificationIfNeeded(updatedSnapshot, reason: reason)
            }

            guard updatedSnapshot.isFinal else { continue }
            guard previousDisplaySnapshot.matchStatus != .fullTime else { continue }
            deliverSavedProGameFinalNotificationIfNeeded(updatedSnapshot, reason: reason)
            Task { [weak self] in
                await self?.deliverSavedProGamePredictionResultNotificationIfNeeded(updatedSnapshot, reason: reason)
            }
        }

        if changedSavedSnapshots {
            sortSavedProGames()
            persistSavedProGames()
            guard !calendarSyncCandidates.isEmpty else { return changedSavedSnapshots }
            let gamesToSync = calendarSyncCandidates
            Task { [weak self] in
                guard let self else { return }
                guard notificationSettingsStore.syncGoingGamesToAppleCalendar,
                      notificationSettingsStore.syncSavedProGamesToAppleCalendar else {
                    return
                }
                for game in gamesToSync {
                    await self.syncSavedProGameToAppleCalendar(
                        game,
                        action: "statusUpdate:\(reason)",
                        forceBypassFreshness: true
                    )
                }
            }
        }
        return changedSavedSnapshots
    }

    private func savedProGameCalendarFieldsChanged(from previous: SavedProGame, to updated: SavedProGame) -> Bool {
        previous.startTime != updated.startTime
            || previous.league != updated.league
            || previous.homeTeam != updated.homeTeam
            || previous.awayTeam != updated.awayTeam
    }

    private func savedProGamePersistentFieldsChanged(from previous: SavedProGame, to updated: SavedProGame) -> Bool {
        previous.id != updated.id
            || previous.source != updated.source
            || previous.externalId != updated.externalId
            || previous.homeTeam != updated.homeTeam
            || previous.awayTeam != updated.awayTeam
            || previous.league != updated.league
            || previous.sport != updated.sport
            || previous.startTime != updated.startTime
            || previous.matchStatus != updated.matchStatus
            || previous.scoreHome != updated.scoreHome
            || previous.scoreAway != updated.scoreAway
            || previous.featuredEventSlug != updated.featuredEventSlug
            || previous.tvSummary != updated.tvSummary
    }

    private func persistHydratedSavedProGameToBackend(
        _ updated: SavedProGame,
        previous: SavedProGame,
        liveStatus: MatchStatus,
        reason: String
    ) {
        guard let userID = currentUserAuthId, isAuthenticatedForSocialFeatures else { return }
#if DEBUG
        print("[GoingProRefreshDebug] savedBeforeStatus=\(previous.matchStatus.rawValue)")
        print("[GoingProRefreshDebug] liveStatus=\(liveStatus.rawValue)")
        print("[GoingProRefreshDebug] normalizedStatus=\(updated.matchStatus.rawValue)")
        print("[GoingProRefreshDebug] savedAfterStatus=\(updated.matchStatus.rawValue)")
#endif
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.upsertSavedProGameToSupabase(updated, userID: userID)
#if DEBUG
                print("[GoingProRefreshDebug] savedStatusPersisted=true id=\(updated.stableKey) reason=\(reason)")
#endif
            } catch {
#if DEBUG
                print("[GoingProRefreshDebug] savedStatusPersisted=false id=\(updated.stableKey) reason=\(reason) error=\(error.localizedDescription)")
#endif
            }
        }
    }

    func refreshFavoriteTeamProGames(
        enabled: Bool,
        windowDays: Int,
        favoriteTeamIDsRaw: String,
        forceRefresh: Bool = false
    ) async {
        guard enabled else {
            favoriteTeamProGames = []
            return
        }

        let favoriteTeams = FavoriteTeamsStore
            .resolvedTeams(from: favoriteTeamIDsRaw)
        guard !favoriteTeams.isEmpty else {
            favoriteTeamProGames = []
            return
        }

        let refreshKey = "\(windowDays)|\(favoriteTeamIDsRaw)"
        if !forceRefresh,
           lastFavoriteTeamProGamesRefreshKey == refreshKey,
           let lastFavoriteTeamProGamesRefreshAt {
            let age = Date().timeIntervalSince(lastFavoriteTeamProGamesRefreshAt)
            if age < 45, !favoriteTeamProGames.contains(where: { $0.game.matchStatus.isHappeningNow }) {
#if DEBUG
                print("[TabPerfDebug] cacheAge=\(String(format: "%.1f", age)) tab=going source=favoriteTeamProGames")
                print("[TabPerfDebug] usedCachedData=true tab=going source=favoriteTeamProGames")
                print("[TabPerfDebug] refreshSkippedReason=fresh tab=going source=favoriteTeamProGames")
#endif
                return
            }
        }
        if !forceRefresh, let existing = favoriteTeamProGamesRefreshTask {
#if DEBUG
            print("[TabPerfDebug] refreshCoalesced=true tab=going source=favoriteTeamProGames")
#endif
            await existing.value
            return
        }

        let startedAt = Date()
#if DEBUG
        print("[TabPerfDebug] refreshStarted=going source=favoriteTeamProGames force=\(forceRefresh)")
#endif
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshFavoriteTeamProGamesNow(
                favoriteTeams: favoriteTeams,
                windowDays: windowDays,
                refreshKey: refreshKey
            )
        }
        favoriteTeamProGamesRefreshTask = task
        await task.value
        favoriteTeamProGamesRefreshTask = nil
#if DEBUG
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("[TabPerfDebug] refreshDurationMs=\(ms) tab=going source=favoriteTeamProGames")
#endif
    }

    private func refreshFavoriteTeamProGamesNow(
        favoriteTeams: [FavoriteTeam],
        windowDays: Int,
        refreshKey: String
    ) async {
        do {
            let matches = try await LiveSportsService.shared.fetchLiveMatches(windowDays: windowDays)
            let previous = favoriteTeamProGames
            let autoFollowMatches = Self.favoriteTeamProGames(from: matches, favoriteTeams: favoriteTeams)
            favoriteTeamProGames = autoFollowMatches
            handleFavoriteTeamProGameStatusUpdates(
                previous: previous,
                current: autoFollowMatches,
                reason: "favoriteTeamAutoFollowFetch"
            )
            await syncFavoriteTeamProGameSubscriptions(autoFollowMatches, reason: "favoriteTeamAutoFollowFetch")
            mergeFavoriteTeamWindowMatchesIntoLiveMatches(matches)
            lastFavoriteTeamProGamesRefreshAt = Date()
            lastFavoriteTeamProGamesRefreshKey = refreshKey
        } catch {
#if DEBUG
            print("[SavedProGames] favoriteTeamAutoFollowFetchFailed error=\(error.localizedDescription)")
#endif
            let previous = favoriteTeamProGames
            let autoFollowMatches = Self.favoriteTeamProGames(from: liveMatches, favoriteTeams: favoriteTeams)
            favoriteTeamProGames = autoFollowMatches
            handleFavoriteTeamProGameStatusUpdates(
                previous: previous,
                current: autoFollowMatches,
                reason: "favoriteTeamAutoFollowFallback"
            )
            await syncFavoriteTeamProGameSubscriptions(autoFollowMatches, reason: "favoriteTeamAutoFollowFallback")
        }
    }

    private func upsertSavedProGameToSupabase(_ snapshot: SavedProGame, userID: UUID) async throws {
        let userIDString = userID.uuidString.lowercased()
        let existingRows: [SavedProGameRemoteIdentityRow] = try await supabase
            .from("saved_pro_games")
            .select("live_match_id")
            .eq("user_id", value: userIDString)
            .eq("live_match_id", value: snapshot.stableKey)
            .limit(1)
            .execute()
            .value

        if existingRows.isEmpty {
            try await supabase
                .from("saved_pro_games")
                .insert(SavedProGameInsertRow(
                    snapshot: snapshot,
                    userID: userID,
                    scoreAlertsEnabled: savedProGameScoreUpdatesEnabled(for: snapshot)
                ))
                .execute()
        } else {
            try await supabase
                .from("saved_pro_games")
                .update(SavedProGameUpdatePatch(snapshot: snapshot))
                .eq("user_id", value: userIDString)
                .eq("live_match_id", value: snapshot.stableKey)
                .execute()
        }
    }

    private func deleteSavedProGameFromSupabase(liveMatchId: String, userID: UUID) async throws {
        try await supabase
            .from("saved_pro_games")
            .delete()
            .eq("user_id", value: userID.uuidString.lowercased())
            .eq("live_match_id", value: liveMatchId)
            .execute()
    }

    private func sortSavedProGames() {
        savedProGames.sort(by: SavedProGame.displaySort)
    }

    private func deliverSavedProGameFinalNotificationIfNeeded(_ game: SavedProGame, reason: String) {
        guard notificationSettingsStore.proGameFinalScoreNotifications else {
#if DEBUG
            print("[ProGameNotificationDebug] finalDisabled id=\(game.stableKey) reason=\(reason)")
#endif
            return
        }

        let token = savedProGameFinalNotificationToken(for: game)
        var delivered = Set(UserDefaults.standard.stringArray(forKey: Self.deliveredSavedProGameFinalNotificationsKey) ?? [])
        guard delivered.insert(token).inserted else {
#if DEBUG
            print("[ProGameNotificationDebug] finalAlreadyDelivered id=\(game.stableKey) reason=\(reason)")
#endif
            return
        }
        UserDefaults.standard.set(Array(delivered).sorted(), forKey: Self.deliveredSavedProGameFinalNotificationsKey)

        let body = game.finalScoreSummary
        showSocialActionToast("\(ProGameNotificationFormatting.finalScoreTitle)\n\(body)", isError: false)
#if DEBUG
        print("[ProGameNotificationDebug] finalObserved id=\(game.stableKey) reason=\(reason) body=\(body)")
#endif
        Task {
            await GameReminderNotificationService.shared.scheduleProGameFinalNotification(
                for: ProGameFinalNotificationEvent(
                    identifier: game.stableKey,
                    body: body,
                    awayTeam: game.awayTeam,
                    homeTeam: game.homeTeam
                )
            )
        }
    }

    private func deliverSavedProGameHalftimeNotificationIfNeeded(_ game: SavedProGame, reason: String) {
        guard savedProGameScoreUpdatesEnabled(for: game) else { return }

        let token = savedProGameHalftimeNotificationToken(for: game)
        var delivered = Set(UserDefaults.standard.stringArray(forKey: Self.deliveredSavedProGameHalftimeNotificationsKey) ?? [])
        guard delivered.insert(token).inserted else { return }
        UserDefaults.standard.set(Array(delivered).sorted(), forKey: Self.deliveredSavedProGameHalftimeNotificationsKey)

        let body = ProGameNotificationFormatting.halftimeBody(
            awayTeam: game.awayTeam,
            awayScore: game.scoreAway,
            homeTeam: game.homeTeam,
            homeScore: game.scoreHome
        )
        showSocialActionToast("\(ProGameNotificationFormatting.halftimeTitle)\n\(body)", isError: false)
        Task {
            await GameReminderNotificationService.shared.scheduleProGameHalftimeNotification(
                for: ProGameHalftimeNotificationEvent(
                    identifier: game.stableKey,
                    body: body,
                    awayTeam: game.awayTeam,
                    homeTeam: game.homeTeam
                )
            )
        }
    }

    private func deliverSavedProGamePredictionResultNotificationIfNeeded(_ game: SavedProGame, reason: String) async {
        guard game.supportsProGamePredictions else { return }

        if proGamePredictionSummaries[game.stableKey]?.userPredictionsLoaded != true {
            await loadProGamePredictionSummaries(proGameIds: [game.stableKey], forceRefresh: true)
        }

        guard let summary = proGamePredictionSummaries[game.stableKey],
              let predictions = summary.userPredictions,
              predictions.hasAnyPrediction else { return }

        let token = savedProGamePredictionResultNotificationToken(for: game)
        var delivered = Set(UserDefaults.standard.stringArray(forKey: Self.deliveredSavedProGamePredictionResultNotificationsKey) ?? [])
        guard delivered.insert(token).inserted else { return }
        UserDefaults.standard.set(Array(delivered).sorted(), forKey: Self.deliveredSavedProGamePredictionResultNotificationsKey)

        let body = savedProGamePredictionResultBody(for: game, predictions: predictions)
        guard !body.isEmpty else { return }

        showSocialActionToast("\(ProGameNotificationFormatting.predictionResultTitle)\n\(body)", isError: false)
        await GameReminderNotificationService.shared.scheduleProGamePredictionResultNotification(
            for: ProGamePredictionResultNotificationEvent(
                identifier: game.stableKey,
                body: body,
                awayTeam: game.awayTeam,
                homeTeam: game.homeTeam
            )
        )
    }

    private func savedProGamePredictionResultBody(for game: SavedProGame, predictions: VenueEventUserPredictions) -> String {
        var lines = [
            ProGameNotificationFormatting.scoreline(
                awayTeam: game.awayTeam,
                awayScore: game.scoreAway,
                homeTeam: game.homeTeam,
                homeScore: game.scoreHome
            ),
        ]

        if let predictedWinner = predictions.winner?.trimmingCharacters(in: .whitespacesAndNewlines),
           !predictedWinner.isEmpty {
            let actualWinner = savedProGameActualWinner(for: game)
            let pick = ProGameNotificationFormatting.predictionTeamReference(predictedWinner)
            let actual = ProGameNotificationFormatting.predictionTeamReference(actualWinner)
            if predictedWinner.caseInsensitiveCompare(actualWinner) == .orderedSame {
                lines.append("Winner: \(pick) ✓")
            } else {
                lines.append("Winner: \(pick) · Final: \(actual)")
            }
        }

        if let predictedAway = predictions.awayScore, let predictedHome = predictions.homeScore {
            let pick = ProGameNotificationFormatting.scoreline(
                awayTeam: game.awayTeam,
                awayScore: predictedAway,
                homeTeam: game.homeTeam,
                homeScore: predictedHome
            )
            if predictedAway == game.scoreAway, predictedHome == game.scoreHome {
                lines.append("Score: \(pick) ✓")
            } else {
                lines.append("Score: \(pick)")
            }
        }

        if let firstScoreTeam = predictions.firstScoreTeam?.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstScoreTeam.isEmpty {
            lines.append("First goal: \(ProGameNotificationFormatting.predictionTeamReference(firstScoreTeam))")
        }

        return lines.joined(separator: "\n")
    }

    private func savedProGameActualWinner(for game: SavedProGame) -> String {
        if game.scoreAway > game.scoreHome { return game.awayTeam }
        if game.scoreHome > game.scoreAway { return game.homeTeam }
        return "Draw"
    }

    private func savedProGameHalftimeNotificationToken(for game: SavedProGame) -> String {
        let userScope = currentUserAuthId?.uuidString.lowercased() ?? "guest"
        return "\(userScope)|\(game.stableKey)|\(MatchStatus.halfTime.rawValue)"
    }

    private func savedProGamePredictionResultNotificationToken(for game: SavedProGame) -> String {
        let userScope = currentUserAuthId?.uuidString.lowercased() ?? "guest"
        return "\(userScope)|\(game.stableKey)|prediction-result"
    }

    private func deliverSavedProGameScoreUpdateNotificationIfNeeded(_ game: SavedProGame, previous: SavedProGame, reason: String) {
        // Local score alerts are best-effort while FanGeo is running. They fire only after
        // the app refreshes and observes a changed score; reliable closed-app score alerts
        // require a backend APNs pipeline that polls live games and dedupes delivered scorelines.
        // Backend design: run a scheduled Supabase Edge Function every 1-2 minutes, compare
        // current provider scores against the last delivered scoreline for users who saved the
        // game with Score Updates enabled, send APNs pushes, then persist delivered score tokens.
        let oldScore = savedProGameScoreToken(for: previous)
        let newScore = savedProGameScoreToken(for: game)
        guard game.matchStatus.isHappeningNow else {
#if DEBUG
            logProScoreNotificationDebug(
                game: game,
                previous: previous,
                enabled: savedProGameScoreUpdatesEnabled(for: game),
                sent: false,
                skipReason: game.isFinal ? "gameFinal" : "notLive",
                reason: reason
            )
#endif
            return
        }
        let scoreUpdatesEnabled = savedProGameScoreUpdatesEnabled(for: game)
        guard scoreUpdatesEnabled else {
#if DEBUG
            logProScoreNotificationDebug(
                game: game,
                previous: previous,
                enabled: false,
                sent: false,
                skipReason: "scoreUpdatesOff",
                reason: reason
            )
#endif
            return
        }

        let token = savedProGameScoreNotificationToken(for: game)
        var delivered = Set(UserDefaults.standard.stringArray(forKey: Self.deliveredSavedProGameScoreNotificationsKey) ?? [])
        guard delivered.insert(token).inserted else {
#if DEBUG
            print("[ProScoreNotificationDebug] gameId=\(game.stableKey) oldScore=\(oldScore) newScore=\(newScore) scoreUpdatesEnabled=true notification=skipped skipReason=duplicateScoreline reason=\(reason)")
#endif
            return
        }
        UserDefaults.standard.set(Array(delivered).sorted(), forKey: Self.deliveredSavedProGameScoreNotificationsKey)

        let title = savedProGameScoreUpdateTitle(for: game, previous: previous)
        let body = game.finalScoreSummary
        showSocialActionToast("\(title)\n\(body)", isError: false)
#if DEBUG
        logProScoreNotificationDebug(
            game: game,
            previous: previous,
            enabled: true,
            sent: true,
            skipReason: nil,
            reason: reason
        )
#endif
        Task {
            await GameReminderNotificationService.shared.scheduleProGameScoreUpdateNotification(
                for: ProGameScoreUpdateNotificationEvent(
                    identifier: game.stableKey,
                    scoreToken: savedProGameScoreToken(for: game),
                    title: title,
                    body: body,
                    awayTeam: game.awayTeam,
                    homeTeam: game.homeTeam
                )
            )
        }
    }

    private func savedProGameScoreDidChange(from previous: SavedProGame, to updated: SavedProGame) -> Bool {
        previous.scoreHome != updated.scoreHome || previous.scoreAway != updated.scoreAway
    }

    private func savedProGameScoreUpdateTitle(for game: SavedProGame, previous: SavedProGame) -> String {
        let awayDelta = game.scoreAway - previous.scoreAway
        let homeDelta = game.scoreHome - previous.scoreHome
        if awayDelta > 0, homeDelta <= 0 {
            return ProGameNotificationFormatting.goalTitle(scoringTeam: game.awayTeam, sport: game.sport)
        }
        if homeDelta > 0, awayDelta <= 0 {
            return ProGameNotificationFormatting.goalTitle(scoringTeam: game.homeTeam, sport: game.sport)
        }
        return "Score update"
    }

    private func savedProGameFinalNotificationToken(for game: SavedProGame) -> String {
        let userScope = currentUserAuthId?.uuidString.lowercased() ?? "guest"
        return "\(userScope)|\(game.stableKey)|\(MatchStatus.fullTime.rawValue)"
    }

    private func savedProGameScoreNotificationToken(for game: SavedProGame) -> String {
        let userScope = currentUserAuthId?.uuidString.lowercased() ?? "guest"
        return "\(userScope)|\(game.stableKey)|score|\(savedProGameScoreToken(for: game))"
    }

    private func savedProGameScoreToken(for game: SavedProGame) -> String {
        "\(game.scoreAway)-\(game.scoreHome)"
    }

    private func savedProGameCardNotificationToken(for gameId: String, eventKey: String) -> String {
        let userScope = currentUserAuthId?.uuidString.lowercased() ?? "guest"
        return "\(userScope)|\(gameId)|card|\(eventKey)"
    }

    private func savedProGameCardEvents(for game: SavedProGame) -> [LiveCardTimelineEntry] {
        LiveCardTimelineBuilder.cardEvents(
            sportType: game.liveSportVisualType,
            timelineEvents: game.timelineEvents ?? [],
            homeTeam: game.homeTeam,
            awayTeam: game.awayTeam,
            gameId: game.stableKey,
            provider: game.source
        )
    }

    private func deliverSavedProGameCardNotificationsIfNeeded(
        _ game: SavedProGame,
        previous: SavedProGame,
        alertsEnabled: Bool,
        reason: String
    ) {
        guard game.matchStatus.isHappeningNow else { return }

        guard alertsEnabled else {
            print("[ProGameCardNotificationDebug] gameId=\(game.stableKey) cardType=unknown eventKey=unknown notificationSent=false dedupeHit=false skipReason=scoreUpdatesOff reason=\(reason)")
            return
        }

        let previousKeys = Set(savedProGameCardEvents(for: previous).map(\.stableEventKey))
        let newCards = savedProGameCardEvents(for: game).filter { !previousKeys.contains($0.stableEventKey) }
        guard !newCards.isEmpty else { return }

        for card in newCards {
            deliverSavedProGameCardNotification(card, game: game, reason: reason)
        }
    }

    private func deliverSavedProGameCardNotification(
        _ card: LiveCardTimelineEntry,
        game: SavedProGame,
        reason: String
    ) {
        let token = savedProGameCardNotificationToken(for: game.stableKey, eventKey: card.stableEventKey)
        var delivered = Set(UserDefaults.standard.stringArray(forKey: Self.deliveredSavedProGameCardNotificationsKey) ?? [])
        guard delivered.insert(token).inserted else {
            print("[ProGameCardNotificationDebug] gameId=\(game.stableKey) cardType=\(card.cardType.stableToken) eventKey=\(card.stableEventKey) notificationSent=false dedupeHit=true reason=\(reason)")
            return
        }
        UserDefaults.standard.set(Array(delivered).sorted(), forKey: Self.deliveredSavedProGameCardNotificationsKey)

        let title = ProGameNotificationFormatting.cardNotificationTitle(cardType: card.cardType)
        let body = ProGameNotificationFormatting.cardNotificationBody(
            cardType: card.cardType,
            minuteText: card.minuteText,
            playerName: card.playerName,
            teamName: card.teamName
        )
        if card.teamName == nil {
            print("[ProGameCardNotificationDebug] gameId=\(game.stableKey) cardType=\(card.cardType.stableToken) eventKey=\(card.stableEventKey) notificationSent=pending teamFallback=true reason=\(reason)")
        }
        showSocialActionToast("\(title)\n\(body)", isError: false)

        Task {
            await GameReminderNotificationService.shared.scheduleProGameCardNotification(
                for: ProGameCardNotificationEvent(
                    identifier: game.stableKey,
                    eventKey: card.stableEventKey,
                    title: title,
                    body: body,
                    awayTeam: game.awayTeam,
                    homeTeam: game.homeTeam,
                    cardType: card.cardType
                )
            )
        }
    }

    func savedProGameScoreUpdatesEnabled(for game: SavedProGame) -> Bool {
        if let stored = savedProGameScoreUpdatePreference(for: game.stableKey) {
            return stored
        }
        return legacySportDefaultForUnmigratedSavedGame(game)
    }

    func favoriteTeamProGameScoreUpdatesEnabled(for game: SavedProGame) -> Bool {
        let override = favoriteTeamProGameAlertOverride(for: game)
        if override.explicitlyEnablesAlerts {
            return true
        }
        if override.explicitlyDisablesAlerts {
            return false
        }
        return notificationSettingsStore.favoriteTeamProGameAlertsEnabled
    }

    func setSavedProGameScoreUpdatesEnabled(_ enabled: Bool, for game: SavedProGame) {
        if enabled {
            Task {
                _ = await GameReminderNotificationService.shared.requestAuthorizationIfNeeded()
            }
        }
        setSavedProGameScoreUpdatesEnabled(enabled, for: game, sendsChange: true)
    }

    func handleFavoriteTeamProGameStatusUpdates(
        previous: [FavoriteTeamProGame],
        current: [FavoriteTeamProGame],
        reason: String
    ) {
        guard !previous.isEmpty, !current.isEmpty else { return }
        let previousByKey = Dictionary(uniqueKeysWithValues: previous.map { ($0.game.stableKey, $0.game) })

        for item in current {
            guard let previousGame = previousByKey[item.game.stableKey] else { continue }
            let updatedGame = item.game
            guard updatedGame != previousGame else { continue }

            if savedProGameScoreDidChange(from: previousGame, to: updatedGame) {
                guard favoriteTeamProGameScoreUpdatesEnabled(for: updatedGame) else {
#if DEBUG
                    logProScoreNotificationDebug(
                        game: updatedGame,
                        previous: previousGame,
                        enabled: false,
                        sent: false,
                        skipReason: "scoreUpdatesOff",
                        reason: reason
                    )
#endif
                    continue
                }
                deliverSavedProGameScoreUpdateNotificationIfNeeded(
                    updatedGame,
                    previous: previousGame,
                    reason: reason
                )
            }

            deliverSavedProGameCardNotificationsIfNeeded(
                updatedGame,
                previous: previousGame,
                alertsEnabled: favoriteTeamProGameScoreUpdatesEnabled(for: updatedGame),
                reason: reason
            )

            if previousGame.matchStatus == .live,
               updatedGame.matchStatus == .halfTime,
               favoriteTeamProGameScoreUpdatesEnabled(for: updatedGame) {
                deliverSavedProGameHalftimeNotificationIfNeeded(updatedGame, reason: reason)
            }

            guard updatedGame.isFinal else { continue }
            guard previousGame.matchStatus != .fullTime else { continue }
            guard favoriteTeamProGameScoreUpdatesEnabled(for: updatedGame) else {
#if DEBUG
                logProScoreNotificationDebug(
                    game: updatedGame,
                    previous: previousGame,
                    enabled: false,
                    sent: false,
                    skipReason: "teamAlertsMutedOrOff",
                    reason: reason
                )
#endif
                continue
            }
            deliverSavedProGameFinalNotificationIfNeeded(updatedGame, reason: reason)
            Task { [weak self] in
                await self?.deliverSavedProGamePredictionResultNotificationIfNeeded(updatedGame, reason: reason)
            }
        }
    }

    private func setSavedProGameScoreUpdatesEnabled(_ enabled: Bool, for game: SavedProGame, sendsChange: Bool) {
        var preferences = savedProGameScoreUpdatePreferences()
        preferences[savedProGameScoreUpdatePreferenceToken(for: game.stableKey)] = enabled
        UserDefaults.standard.set(preferences, forKey: Self.savedProGameScoreUpdatePreferencesKey)
        if sendsChange {
            Task { [weak self] in
                await self?.syncProGameScoreAlertPreferenceToBackend(enabled, for: game)
            }
            objectWillChange.send()
        }
    }

    private func applyRemoteSavedProGameScoreAlertPreferences(_ rows: [SavedProGameSupabaseRow]) {
        guard !rows.isEmpty else { return }
        var preferences = savedProGameScoreUpdatePreferences()
        var changed = false
        for row in rows {
            guard let enabled = row.score_alerts_enabled else { continue }
            let token = savedProGameScoreUpdatePreferenceToken(for: row.live_match_id)
            if preferences[token] != enabled {
                preferences[token] = enabled
                changed = true
            }
        }
        if changed {
            UserDefaults.standard.set(preferences, forKey: Self.savedProGameScoreUpdatePreferencesKey)
        }
    }

    private func ensureSavedProGameScoreUpdatePreferencesExist(for games: [SavedProGame]) {
        guard !games.isEmpty else { return }
        var preferences = savedProGameScoreUpdatePreferences()
        var changed = false
        for game in games {
            let token = savedProGameScoreUpdatePreferenceToken(for: game.stableKey)
            guard preferences[token] == nil else { continue }
            preferences[token] = legacySportDefaultForUnmigratedSavedGame(game)
            changed = true
        }
        if changed {
            UserDefaults.standard.set(preferences, forKey: Self.savedProGameScoreUpdatePreferencesKey)
        }
        markLegacySportDefaultsMigratedIfNeeded()
    }

    private func clearSavedProGameScoreUpdatePreference(identifier: String) {
        var preferences = savedProGameScoreUpdatePreferences()
        preferences.removeValue(forKey: savedProGameScoreUpdatePreferenceToken(for: identifier))
        UserDefaults.standard.set(preferences, forKey: Self.savedProGameScoreUpdatePreferencesKey)
    }

    private func savedProGameScoreUpdatePreference(for identifier: String) -> Bool? {
        savedProGameScoreUpdatePreferences()[savedProGameScoreUpdatePreferenceToken(for: identifier)]
    }

    private func savedProGameScoreUpdatePreferences() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: Self.savedProGameScoreUpdatePreferencesKey) as? [String: Bool] ?? [:]
    }

    private func savedProGameScoreUpdatePreferenceToken(for identifier: String) -> String {
        let userScope = currentUserAuthId?.uuidString.lowercased() ?? "guest"
        return "\(userScope)|\(identifier)"
    }

    private func legacySportDefaultForUnmigratedSavedGame(_ game: SavedProGame) -> Bool {
        guard !UserDefaults.standard.bool(forKey: legacySportDefaultsMigrationKey()) else { return false }
        return legacyProGameScoreUpdateDefault(for: game.sport)
    }

    private func legacyProGameScoreUpdateDefault(for rawSport: String) -> Bool {
        let normalized = LiveMatchFilters.normalizedSearchText(rawSport)
        guard !normalized.isEmpty else { return false }

        guard let legacy = Self.legacyProGameScoreUpdateDefaults.first(where: { entry in
            entry.sportTokens.contains { normalized.contains($0) || $0.contains(normalized) }
        }) else {
            return false
        }

        if UserDefaults.standard.object(forKey: legacy.key) == nil {
            return legacy.defaultValue
        }
        return UserDefaults.standard.bool(forKey: legacy.key)
    }

    private func markLegacySportDefaultsMigratedIfNeeded() {
        let key = legacySportDefaultsMigrationKey()
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        for legacy in Self.legacyProGameScoreUpdateDefaults {
            UserDefaults.standard.removeObject(forKey: legacy.key)
        }
    }

    private func legacySportDefaultsMigrationKey() -> String {
        let userScope = currentUserAuthId?.uuidString.lowercased() ?? "guest"
        return "\(Self.legacySportDefaultsMigrationKeyPrefix).\(userScope)"
    }

    private func persistSavedProGames() {
        if let userID = currentUserAuthId {
            persistSavedProGames(for: userID)
        } else {
            persistSavedProGames(storageKey: Self.savedProGamesGuestDefaultsKey)
        }
    }

    private func persistSavedProGames(for userID: UUID) {
        persistSavedProGames(storageKey: Self.savedProGamesDefaultsKey(for: userID))
    }

    private func persistSavedProGames(storageKey: String) {
        if let data = try? JSONEncoder().encode(savedProGames) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private static func mergedSavedProGames(local: [SavedProGame], remote: [SavedProGame]) -> [SavedProGame] {
        var byKey = Dictionary(uniqueKeysWithValues: remote.map { ($0.stableKey, $0) })
        for snapshot in local {
            if let existing = byKey[snapshot.stableKey] {
                byKey[snapshot.stableKey] = SavedProGame.freshestSnapshot(existing, snapshot)
            } else {
                byKey[snapshot.stableKey] = snapshot
            }
        }
        return byKey.values.sorted(by: SavedProGame.displaySort)
    }

    static func favoriteTeamProGames(
        from matches: [LiveMatch],
        favoriteTeams: [FavoriteTeam]
    ) -> [FavoriteTeamProGame] {
        var seen = Set<String>()
        return matches.compactMap { match -> FavoriteTeamProGame? in
            guard let team = favoriteTeams.first(where: {
                FavoriteTeamLiveMatcher.matchesLiveMatch($0, homeTeam: match.homeTeam, awayTeam: match.awayTeam)
            }) else {
                return nil
            }
            let game = SavedProGame(match: match)
            guard seen.insert(game.stableKey).inserted else { return nil }
            return FavoriteTeamProGame(game: game, favoriteTeamID: team.id, favoriteTeamName: team.name)
        }
        .sorted { SavedProGame.displaySort($0.game, $1.game) }
    }

    private func mergeFavoriteTeamWindowMatchesIntoLiveMatches(_ matches: [LiveMatch]) {
        guard !matches.isEmpty else { return }
        var byKey = Dictionary(uniqueKeysWithValues: liveMatches.map { (SavedProGame.stableKey(for: $0), $0) })
        for match in matches {
            byKey[SavedProGame.stableKey(for: match)] = match
        }
        let merged = byKey.values.sorted {
            if $0.startTime == $1.startTime { return $0.id < $1.id }
            return $0.startTime < $1.startTime
        }
        handleSavedProGameStatusUpdates(from: matches, reason: "favoriteTeamWindowMerge")
        liveMatches = merged
    }

    private func mergeGoingProRefreshMatchesIntoLiveMatches(_ matches: [LiveMatch]) {
        guard !matches.isEmpty else { return }
        liveMatches = Self.mergeLiveMatches(liveMatches, with: matches)
        invalidateCalendarTabEventsListCache()
    }

    private static func mergeLiveMatches(_ base: [LiveMatch], with additional: [LiveMatch]) -> [LiveMatch] {
        var byKey: [String: LiveMatch] = [:]
        for match in base {
            byKey[SavedProGame.stableKey(for: match)] = match
        }
        for match in additional {
            byKey[SavedProGame.stableKey(for: match)] = match
        }
        return byKey.values.sorted {
            if $0.matchStatus.isHappeningNow != $1.matchStatus.isHappeningNow {
                return $0.matchStatus.isHappeningNow && !$1.matchStatus.isHappeningNow
            }
            if $0.startTime == $1.startTime { return $0.id < $1.id }
            return $0.startTime < $1.startTime
        }
    }

    private static func savedProGamesDefaultsKey(for userID: UUID) -> String {
        "gameon.savedProGames.\(userID.uuidString.lowercased()).v1"
    }

    private static func decodeSavedProGames(storageKey: String) -> [SavedProGame] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([SavedProGame].self, from: data) else {
            return []
        }
        return decoded.sorted {
            SavedProGame.displaySort($0, $1)
        }
    }

    private func logLegacySavedProGamesCacheIfPresent(context: String) {
#if DEBUG
        guard UserDefaults.standard.data(forKey: Self.savedProGamesLegacyGlobalDefaultsKey) != nil else { return }
        print("[SavedProGames] legacyGlobalCacheDetected context=\(context) key=\(Self.savedProGamesLegacyGlobalDefaultsKey) action=ignoredForAuthenticatedUsers")
#else
        _ = context
#endif
    }
}

private nonisolated struct SavedProGameSupabaseRow: Decodable {
    let live_match_id: String
    let source: String?
    let external_id: String?
    let home_team: String
    let away_team: String
    let league: String?
    let sport: String?
    let start_time: String
    let match_status: String?
    let score_home: Int?
    let score_away: Int?
    let featured_event_slug: String?
    let tv_summary: String?
    let score_alerts_enabled: Bool?
    let created_at: String?

    var savedProGame: SavedProGame? {
        guard let start = SupabaseTimestampParsing.parseTimestamptz(start_time) else { return nil }
        let savedAt = created_at.flatMap(SupabaseTimestampParsing.parseTimestamptz) ?? Date()
        return SavedProGame(
            id: live_match_id,
            source: Self.clean(source),
            externalId: Self.clean(external_id),
            homeTeam: home_team.trimmingCharacters(in: .whitespacesAndNewlines),
            awayTeam: away_team.trimmingCharacters(in: .whitespacesAndNewlines),
            league: Self.clean(league) ?? "Pro Game",
            sport: Self.clean(sport) ?? "Sports",
            startTime: start,
            matchStatus: MatchStatus.normalized(from: match_status),
            scoreHome: score_home ?? 0,
            scoreAway: score_away ?? 0,
            featuredEventSlug: Self.clean(featured_event_slug),
            tvSummary: Self.clean(tv_summary),
            rawMatchStatus: Self.clean(match_status),
            minute: nil,
            liveClockText: nil,
            timelineEvents: nil,
            savedAt: savedAt
        )
    }

    private static func clean(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private nonisolated struct SavedProGameRemoteIdentityRow: Decodable {
    let live_match_id: String
}

private nonisolated struct SavedProGameInsertRow: Encodable {
    let user_id: String
    let live_match_id: String
    let source: String?
    let external_id: String?
    let home_team: String
    let away_team: String
    let league: String?
    let sport: String?
    let start_time: String
    let match_status: String
    let score_home: Int
    let score_away: Int
    let featured_event_slug: String?
    let tv_summary: String?
    let score_alerts_enabled: Bool
    let final_score_alerts_enabled: Bool
    let last_notified_scoreline: String?
    let snapshot: [String: String?]

    init(snapshot: SavedProGame, userID: UUID, scoreAlertsEnabled: Bool) {
        self.user_id = userID.uuidString.lowercased()
        self.live_match_id = snapshot.stableKey
        self.source = Self.clean(snapshot.source)
        self.external_id = Self.clean(snapshot.externalId)
        self.home_team = snapshot.homeTeam
        self.away_team = snapshot.awayTeam
        self.league = Self.clean(snapshot.league)
        self.sport = Self.clean(snapshot.sport)
        self.start_time = SupabaseTimestampParsing.encodeTimestamptz(snapshot.startTime)
        self.match_status = snapshot.matchStatus.rawValue
        self.score_home = snapshot.scoreHome
        self.score_away = snapshot.scoreAway
        self.featured_event_slug = Self.clean(snapshot.featuredEventSlug)
        self.tv_summary = Self.clean(snapshot.tvSummary)
        self.score_alerts_enabled = scoreAlertsEnabled
        self.final_score_alerts_enabled = true
        self.last_notified_scoreline = "\(snapshot.scoreAway)-\(snapshot.scoreHome)"
        self.snapshot = [
            "id": snapshot.id,
            "source": snapshot.source,
            "external_id": snapshot.externalId,
            "home_team": snapshot.homeTeam,
            "away_team": snapshot.awayTeam,
            "league": snapshot.league,
            "sport": snapshot.sport,
            "start_time": SupabaseTimestampParsing.encodeTimestamptz(snapshot.startTime),
            "match_status": snapshot.matchStatus.rawValue,
            "featured_event_slug": snapshot.featuredEventSlug,
            "tv_summary": snapshot.tvSummary
        ]
    }

    private static func clean(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private nonisolated struct SavedProGameUpdatePatch: Encodable {
    let source: String?
    let external_id: String?
    let home_team: String
    let away_team: String
    let league: String?
    let sport: String?
    let start_time: String
    let match_status: String
    let score_home: Int
    let score_away: Int
    let featured_event_slug: String?
    let tv_summary: String?
    let snapshot: [String: String?]

    init(snapshot: SavedProGame) {
        self.source = Self.clean(snapshot.source)
        self.external_id = Self.clean(snapshot.externalId)
        self.home_team = snapshot.homeTeam
        self.away_team = snapshot.awayTeam
        self.league = Self.clean(snapshot.league)
        self.sport = Self.clean(snapshot.sport)
        self.start_time = SupabaseTimestampParsing.encodeTimestamptz(snapshot.startTime)
        self.match_status = snapshot.matchStatus.rawValue
        self.score_home = snapshot.scoreHome
        self.score_away = snapshot.scoreAway
        self.featured_event_slug = Self.clean(snapshot.featuredEventSlug)
        self.tv_summary = Self.clean(snapshot.tvSummary)
        self.snapshot = [
            "id": snapshot.id,
            "source": snapshot.source,
            "external_id": snapshot.externalId,
            "home_team": snapshot.homeTeam,
            "away_team": snapshot.awayTeam,
            "league": snapshot.league,
            "sport": snapshot.sport,
            "start_time": SupabaseTimestampParsing.encodeTimestamptz(snapshot.startTime),
            "match_status": snapshot.matchStatus.rawValue,
            "featured_event_slug": snapshot.featuredEventSlug,
            "tv_summary": snapshot.tvSummary
        ]
    }

    private static func clean(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ProGameFeaturedBadgeIdentity {
    let mark: String
    let caption: String?
    let systemImage: String
    let primary: Color
    let secondary: Color
    let foreground: Color

    static func resolve(event: FeaturedEvent?, slug: String?) -> ProGameFeaturedBadgeIdentity? {
        let rawValues = [
            slug,
            event?.slug,
            event?.title,
            event?.shortTitle
        ]
        let normalizedValues = rawValues
            .compactMap { $0 }
            .map(normalized)
            .filter { !$0.isEmpty }
        let haystack = normalizedValues.joined(separator: " ")
        guard !haystack.isEmpty else { return nil }

        if haystack.contains("fifa") && haystack.contains("world cup") {
            return ProGameFeaturedBadgeIdentity(
                mark: "FIFA\nWC",
                caption: "Cup",
                systemImage: "soccerball",
                primary: Color(red: 0.05, green: 0.55, blue: 0.28),
                secondary: Color(red: 0.12, green: 0.62, blue: 0.38),
                foreground: .white
            )
        }
        if haystack.contains("roland garros") || haystack.contains("french open") {
            return ProGameFeaturedBadgeIdentity(
                mark: "RG",
                caption: "Clay",
                systemImage: "tennisball.fill",
                primary: Color(red: 0.70, green: 0.26, blue: 0.10),
                secondary: Color(red: 0.98, green: 0.66, blue: 0.26),
                foreground: .white
            )
        }
        if haystack.contains("wimbledon") {
            return ProGameFeaturedBadgeIdentity(
                mark: "W",
                caption: "SW19",
                systemImage: "tennisball.fill",
                primary: Color(red: 0.18, green: 0.35, blue: 0.22),
                secondary: Color(red: 0.48, green: 0.20, blue: 0.58),
                foreground: .white
            )
        }
        if haystack.contains("us open") || haystack.contains("u s open") {
            return ProGameFeaturedBadgeIdentity(
                mark: "US\nOPEN",
                caption: nil,
                systemImage: "tennisball.fill",
                primary: Color(red: 0.03, green: 0.18, blue: 0.48),
                secondary: Color(red: 0.08, green: 0.48, blue: 0.86),
                foreground: .white
            )
        }
        if haystack.contains("nba finals") {
            return ProGameFeaturedBadgeIdentity(
                mark: "NBA\nFINALS",
                caption: nil,
                systemImage: "basketball.fill",
                primary: Color(red: 0.05, green: 0.16, blue: 0.45),
                secondary: Color(red: 0.86, green: 0.12, blue: 0.18),
                foreground: .white
            )
        }
        if haystack.contains("stanley cup") {
            return ProGameFeaturedBadgeIdentity(
                mark: "SCF",
                caption: "Cup",
                systemImage: "hockey.puck.fill",
                primary: Color(red: 0.09, green: 0.10, blue: 0.12),
                secondary: Color(red: 0.72, green: 0.76, blue: 0.82),
                foreground: .white
            )
        }
        if haystack.contains("super bowl") {
            return ProGameFeaturedBadgeIdentity(
                mark: "SB",
                caption: "NFL",
                systemImage: "football.fill",
                primary: Color(red: 0.02, green: 0.12, blue: 0.34),
                secondary: Color(red: 0.78, green: 0.10, blue: 0.16),
                foreground: .white
            )
        }

        return generic(event: event, slug: slug)
    }

    private static func generic(event: FeaturedEvent?, slug: String?) -> ProGameFeaturedBadgeIdentity? {
        let title = [
            event?.shortTitle,
            event?.title,
            slug
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
        guard !title.isEmpty else { return nil }

        return ProGameFeaturedBadgeIdentity(
            mark: abbreviation(for: title),
            caption: "Event",
            systemImage: "star.fill",
            primary: Color(red: 0.12, green: 0.15, blue: 0.28),
            secondary: FGColor.accentYellow,
            foreground: .white
        )
    }

    private static func abbreviation(for title: String) -> String {
        let words = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "PRO" }
        if words.count == 1 {
            return String(words[0].prefix(6)).uppercased()
        }
        return words.prefix(3).compactMap { $0.first }.map { String($0) }.joined().uppercased()
    }

    nonisolated private static func normalized(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct ProGameSportBadgeView: View {
    let sportType: LiveSportVisualType
    var diameter: CGFloat = 56
    var featuredEvent: FeaturedEvent?
    var featuredEventSlug: String?
    var isFeatured = false

    @Environment(\.colorScheme) private var colorScheme

    private var featuredBadge: ProGameFeaturedBadgeIdentity? {
        ProGameFeaturedBadgeIdentity.resolve(event: featuredEvent, slug: featuredEventSlug)
    }

    private var accent: Color {
        featuredBadge?.primary ?? sportType.catalogAccent
    }

    private var secondaryAccent: Color {
        if let featuredBadge { return featuredBadge.secondary }
        switch sportType {
        case .soccer:
            return Color(red: 0.18, green: 0.74, blue: 0.42)
        case .basketball:
            return Color.orange
        case .nfl:
            return Color(red: 0.70, green: 0.46, blue: 0.24)
        case .hockey:
            return FGColor.accentBlue
        case .baseball:
            return Color(red: 0.12, green: 0.31, blue: 0.72)
        case .tennis:
            return Color(red: 0.72, green: 0.86, blue: 0.18)
        default:
            return sportType.catalogAccent
        }
    }

    private var premiumSportSymbol: String {
        switch sportType {
        case .soccer:
            return "figure.soccer"
        case .basketball:
            return "figure.basketball"
        case .hockey:
            return "figure.hockey"
        case .baseball:
            return "figure.baseball"
        case .nfl:
            return "figure.american.football"
        case .tennis:
            return "figure.tennis"
        case .badminton:
            return "sportscourt.fill"
        case .golf:
            return "figure.golf"
        case .formula1:
            return "flag.checkered.2.crossed"
        case .breakdance, .ballet:
            return "figure.dance"
        case .other:
            return "sportscourt.fill"
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(colorScheme == .dark ? 0.92 : 0.84),
                            secondaryAccent.opacity(colorScheme == .dark ? 0.76 : 0.62),
                            Color(.secondarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.30 : 0.86)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.28 : 0.62), lineWidth: 1.4)

            Circle()
                .strokeBorder(accent.opacity(colorScheme == .dark ? 0.74 : 0.42), lineWidth: 0.8)
                .padding(2)

            Capsule()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.30))
                .frame(width: diameter * 0.46, height: max(1.2, diameter * 0.035))
                .rotationEffect(.degrees(-34))
                .offset(x: -diameter * 0.09, y: -diameter * 0.18)

            if let featuredBadge {
                featuredEventArtwork(featuredBadge)
            } else {
                premiumSportArtwork
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(
            color: accent.opacity((featuredBadge != nil || isFeatured) ? (colorScheme == .dark ? 0.34 : 0.20) : (colorScheme == .dark ? 0.22 : 0.10)),
            radius: (featuredBadge != nil || isFeatured) ? 12 : 8,
            y: 3
        )
        .accessibilityHidden(true)
    }

    private func featuredEventArtwork(_ badge: ProGameFeaturedBadgeIdentity) -> some View {
        VStack(spacing: max(1, diameter * 0.035)) {
            Image(systemName: badge.systemImage)
                .font(.system(size: max(8, diameter * 0.19), weight: .black))
                .foregroundStyle(badge.foreground.opacity(0.92))

            Text(badge.mark)
                .font(.system(size: max(10, diameter * (badge.mark.contains("\n") ? 0.19 : 0.27)), weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
                .lineSpacing(-1)
                .minimumScaleFactor(0.58)
                .foregroundStyle(badge.foreground)
                .shadow(color: Color.black.opacity(0.16), radius: 1, y: 1)

            if let caption = badge.caption {
                Text(caption.uppercased())
                    .font(.system(size: max(6, diameter * 0.10), weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.65)
                    .foregroundStyle(badge.foreground.opacity(0.86))
            }
        }
        .padding(.horizontal, diameter * 0.12)
    }

    private var premiumSportArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: diameter * 0.18, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.26))
                .frame(width: diameter * 0.58, height: diameter * 0.58)
                .rotationEffect(.degrees(-8))

            Image(systemName: premiumSportSymbol)
                .font(.system(size: max(18, diameter * 0.42), weight: .black))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white.opacity(colorScheme == .dark ? 0.96 : 0.98))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.16), radius: 3, y: 1)
        }
    }
}
