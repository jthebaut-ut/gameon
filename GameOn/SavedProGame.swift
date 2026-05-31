import Foundation
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
        self.savedAt = savedAt
    }

    var liveSportVisualType: LiveSportVisualType {
        LiveSportVisualType.normalize(sport)
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
    private static let savedProGamesDefaultsKey = "gameon.savedProGames.v1"
    private static let savedProGamesSelectColumns = "live_match_id,source,external_id,home_team,away_team,league,sport,start_time,match_status,score_home,score_away,featured_event_slug,tv_summary,created_at"

    func reloadSavedProGamesFromStorage() {
        savedProGames = Self.decodeSavedProGames()
    }

    func fetchSavedProGames() async {
        guard let userID = currentUserAuthId, isAuthenticatedForSocialFeatures else {
            reloadSavedProGamesFromStorage()
            return
        }

        let localSnapshots = savedProGames.isEmpty ? Self.decodeSavedProGames() : savedProGames
        do {
            let rows: [SavedProGameSupabaseRow] = try await supabase
                .from("saved_pro_games")
                .select(Self.savedProGamesSelectColumns)
                .eq("user_id", value: userID.uuidString.lowercased())
                .order("start_time", ascending: true)
                .execute()
                .value

            let remoteSnapshots = rows.compactMap(\.savedProGame)
            let remoteKeys = Set(remoteSnapshots.map(\.stableKey))
            let merged = Self.mergedSavedProGames(local: localSnapshots, remote: remoteSnapshots)
            savedProGames = merged
            persistSavedProGames()

            for snapshot in localSnapshots where !remoteKeys.contains(snapshot.stableKey) {
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
            if savedProGames.isEmpty {
                savedProGames = localSnapshots
            }
        }
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
        sortSavedProGames()
        persistSavedProGames()

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
        let remoteLiveMatchId = savedProGames.first { $0.stableKey == id || $0.id == id }?.id ?? id
        savedProGames.removeAll { $0.stableKey == id || $0.id == id }
        persistSavedProGames()

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
        guard let match = liveMatches.first(where: { SavedProGame.stableKey(for: $0) == saved.stableKey }) else {
            return saved
        }
        return SavedProGame(match: match, savedAt: saved.savedAt)
    }

    func refreshFavoriteTeamProGames(
        enabled: Bool,
        windowDays: Int,
        favoriteTeamIDsRaw: String
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

        do {
            let matches = try await LiveSportsService.shared.fetchLiveMatches(windowDays: windowDays)
            let autoFollowMatches = Self.favoriteTeamProGames(from: matches, favoriteTeams: favoriteTeams)
            favoriteTeamProGames = autoFollowMatches
            mergeFavoriteTeamWindowMatchesIntoLiveMatches(matches)
        } catch {
#if DEBUG
            print("[SavedProGames] favoriteTeamAutoFollowFetchFailed error=\(error.localizedDescription)")
#endif
            let autoFollowMatches = Self.favoriteTeamProGames(from: liveMatches, favoriteTeams: favoriteTeams)
            favoriteTeamProGames = autoFollowMatches
        }
    }

    private func upsertSavedProGameToSupabase(_ snapshot: SavedProGame, userID: UUID) async throws {
        try await supabase
            .from("saved_pro_games")
            .upsert(SavedProGameUpsertRow(snapshot: snapshot, userID: userID), onConflict: "user_id,live_match_id")
            .execute()
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
        savedProGames.sort {
            if $0.startTime == $1.startTime { return $0.savedAt > $1.savedAt }
            return $0.startTime < $1.startTime
        }
    }

    private func persistSavedProGames() {
        if let data = try? JSONEncoder().encode(savedProGames) {
            UserDefaults.standard.set(data, forKey: Self.savedProGamesDefaultsKey)
        }
    }

    private static func mergedSavedProGames(local: [SavedProGame], remote: [SavedProGame]) -> [SavedProGame] {
        var byKey = Dictionary(uniqueKeysWithValues: remote.map { ($0.stableKey, $0) })
        for snapshot in local where byKey[snapshot.stableKey] == nil {
            byKey[snapshot.stableKey] = snapshot
        }
        return byKey.values.sorted {
            if $0.startTime == $1.startTime { return $0.savedAt > $1.savedAt }
            return $0.startTime < $1.startTime
        }
    }

    private static func favoriteTeamProGames(
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
        .sorted {
            if $0.game.startTime == $1.game.startTime {
                return $0.game.stableKey < $1.game.stableKey
            }
            return $0.game.startTime < $1.game.startTime
        }
    }

    private func mergeFavoriteTeamWindowMatchesIntoLiveMatches(_ matches: [LiveMatch]) {
        guard !matches.isEmpty else { return }
        var byKey = Dictionary(uniqueKeysWithValues: liveMatches.map { (SavedProGame.stableKey(for: $0), $0) })
        for match in matches {
            byKey[SavedProGame.stableKey(for: match)] = match
        }
        liveMatches = byKey.values.sorted {
            if $0.startTime == $1.startTime { return $0.id < $1.id }
            return $0.startTime < $1.startTime
        }
    }

    private static func decodeSavedProGames() -> [SavedProGame] {
        guard let data = UserDefaults.standard.data(forKey: savedProGamesDefaultsKey),
              let decoded = try? JSONDecoder().decode([SavedProGame].self, from: data) else {
            return []
        }
        return decoded.sorted {
            if $0.startTime == $1.startTime { return $0.savedAt > $1.savedAt }
            return $0.startTime < $1.startTime
        }
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
            matchStatus: MatchStatus(rawValue: Self.clean(match_status)?.uppercased() ?? "") ?? .scheduled,
            scoreHome: score_home ?? 0,
            scoreAway: score_away ?? 0,
            featuredEventSlug: Self.clean(featured_event_slug),
            tvSummary: Self.clean(tv_summary),
            savedAt: savedAt
        )
    }

    private static func clean(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private nonisolated struct SavedProGameUpsertRow: Encodable {
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
    let snapshot: [String: String?]

    init(snapshot: SavedProGame, userID: UUID) {
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

struct ProGameSportBadgeView: View {
    let sportType: LiveSportVisualType
    var diameter: CGFloat = 56
    var isFeatured = false

    @Environment(\.colorScheme) private var colorScheme

    private var visual: SportFilterCatalog.ChipVisual {
        sportType.catalogVisual
    }

    private var accent: Color {
        sportType.catalogAccent
    }

    private var secondaryAccent: Color {
        switch sportType {
        case .soccer:
            return FGColor.accentGreen
        case .basketball:
            return Color.orange
        case .nfl:
            return Color(red: 0.66, green: 0.42, blue: 0.20)
        case .hockey:
            return FGColor.accentBlue
        case .baseball:
            return Color(red: 0.12, green: 0.31, blue: 0.72)
        case .tennis:
            return Color(red: 0.72, green: 0.86, blue: 0.18)
        default:
            return visual.accent
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(colorScheme == .dark ? 0.36 : 0.24),
                                secondaryAccent.opacity(colorScheme == .dark ? 0.22 : 0.14),
                                Color(.secondarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.38 : 0.80)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .strokeBorder(accent.opacity(colorScheme == .dark ? 0.62 : 0.42), lineWidth: 1.2)

                sportGlyph
                    .font(.system(size: max(18, diameter * 0.44), weight: .heavy))
                    .foregroundStyle(accent)
                    .shadow(color: accent.opacity(colorScheme == .dark ? 0.28 : 0.14), radius: 4, y: 1)

                sportDetail
                    .opacity(0.86)
            }
            .frame(width: diameter, height: diameter)
            .overlay {
                if isFeatured {
                    Circle()
                        .strokeBorder(FGColor.accentYellow.opacity(colorScheme == .dark ? 0.48 : 0.34), lineWidth: 1)
                }
            }
            .shadow(color: isFeatured ? FGColor.accentYellow.opacity(colorScheme == .dark ? 0.26 : 0.14) : .clear, radius: 8, y: 2)

            if isFeatured {
                Image(systemName: "trophy.fill")
                    .font(.system(size: max(9, diameter * 0.19), weight: .bold))
                    .foregroundStyle(FGColor.accentYellow)
                    .frame(width: max(18, diameter * 0.34), height: max(18, diameter * 0.34))
                    .background(Color(.systemBackground), in: Circle())
                    .overlay(Circle().strokeBorder(FGColor.accentYellow.opacity(0.45), lineWidth: 0.8))
                    .offset(x: 1, y: 1)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var sportGlyph: some View {
        Image(systemName: visual.systemImage)
    }

    @ViewBuilder
    private var sportDetail: some View {
        switch sportType {
        case .soccer:
            Circle()
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.30 : 0.42), lineWidth: 1)
                .frame(width: diameter * 0.25, height: diameter * 0.25)
                .offset(x: diameter * 0.17, y: -diameter * 0.17)
        case .basketball:
            VStack(spacing: diameter * 0.10) {
                Capsule().fill(Color.white.opacity(0.30)).frame(width: diameter * 0.42, height: 1)
                Capsule().fill(Color.white.opacity(0.24)).frame(width: diameter * 0.30, height: 1)
            }
            .rotationEffect(.degrees(-28))
            .offset(x: diameter * 0.10, y: diameter * 0.06)
        case .nfl:
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: diameter * 0.34, height: 2)
                .rotationEffect(.degrees(-24))
                .offset(x: diameter * 0.04, y: diameter * 0.12)
        case .hockey:
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: diameter * 0.44, height: 2)
                .rotationEffect(.degrees(-35))
                .offset(x: diameter * 0.08, y: diameter * 0.12)
        case .baseball:
            HStack(spacing: diameter * 0.24) {
                Capsule().fill(Color.white.opacity(0.24)).frame(width: 2, height: diameter * 0.30)
                Capsule().fill(Color.white.opacity(0.24)).frame(width: 2, height: diameter * 0.30)
            }
            .rotationEffect(.degrees(18))
        case .tennis:
            Circle()
                .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)
                .frame(width: diameter * 0.34, height: diameter * 0.34)
                .offset(x: diameter * 0.12, y: -diameter * 0.10)
        default:
            EmptyView()
        }
    }
}
