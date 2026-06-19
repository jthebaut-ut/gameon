import Foundation
import Supabase

struct ProGamePredictionSummary: Equatable, Sendable {
    let proGameID: String
    let participantCount: Int
    let totalCount: Int
    let winnerLeader: String?
    let winnerPercent: Int?
    let winnerPercents: [String: Int]
    let scoreMode: String?
    let scorePredictionTotal: Int
    let topScorePredictions: [VenueScorePredictionCrowdPick]
    let firstScoreLeader: String?
    let firstScorePercent: Int?
    let firstScorePercents: [String: Int]
    let participantAvatars: [VenuePredictionParticipantAvatar]
    let userPredictions: VenueEventUserPredictions?
    let userPredictionsLoaded: Bool

    static func empty(
        proGameID: String,
        userPredictions: VenueEventUserPredictions? = nil,
        userPredictionsLoaded: Bool = false
    ) -> ProGamePredictionSummary {
        ProGamePredictionSummary(
            proGameID: proGameID,
            participantCount: 0,
            totalCount: 0,
            winnerLeader: nil,
            winnerPercent: nil,
            winnerPercents: [:],
            scoreMode: nil,
            scorePredictionTotal: 0,
            topScorePredictions: [],
            firstScoreLeader: nil,
            firstScorePercent: nil,
            firstScorePercents: [:],
            participantAvatars: [],
            userPredictions: userPredictions,
            userPredictionsLoaded: userPredictionsLoaded
        )
    }
}

enum ProGamePredictionServiceError: LocalizedError {
    case missingUser
    case invalidPrediction

    var errorDescription: String? {
        switch self {
        case .missingUser:
            return "Sign in to make a prediction."
        case .invalidPrediction:
            return "Choose a prediction before saving."
        }
    }
}

final class ProGamePredictionService {
    static let shared = ProGamePredictionService()

    private let client: SupabaseClient
    private let cacheTTL: TimeInterval = 45
    private var summaryCache: [String: (loadedAt: Date, userID: UUID?, summary: ProGamePredictionSummary)] = [:]

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func fetchPredictionSummary(proGameIds: [String], forceRefresh: Bool = false) async -> [String: ProGamePredictionSummary] {
        let ids = Array(Set(proGameIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return [:] }

        let now = Date()
        let currentUserID = await currentUserIdIfAvailable()
        var resolved: [String: ProGamePredictionSummary] = [:]
        var idsToFetch: [String] = []
        for id in ids {
            if !forceRefresh,
               let cached = summaryCache[id],
               cached.userID == currentUserID,
               now.timeIntervalSince(cached.loadedAt) < cacheTTL {
                resolved[id] = cached.summary
            } else {
                idsToFetch.append(id)
            }
        }
        guard !idsToFetch.isEmpty else { return resolved }

        do {
            let rows: [ProGamePredictionRow] = try await client
                .from("pro_game_predictions")
                .select(Self.predictionSelect)
                .in("pro_game_id", values: idsToFetch)
                .execute()
                .value
            let avatars = await loadAvatars(for: rows)
            for proGameID in idsToFetch {
                let gameRows = rows.filter { $0.pro_game_id == proGameID }
                let summary = Self.buildSummary(
                    proGameID: proGameID,
                    rows: gameRows,
                    avatarsByUserID: avatars,
                    currentUserID: currentUserID
                )
                summaryCache[proGameID] = (loadedAt: Date(), userID: currentUserID, summary: summary)
                resolved[proGameID] = summary
            }
        } catch {
#if DEBUG
            print("[ProGamePredictionDebug] loadSummaryFailed=\(error.localizedDescription)")
#endif
            for proGameID in idsToFetch {
                if let cached = summaryCache[proGameID], cached.userID == currentUserID {
                    resolved[proGameID] = cached.summary
                }
            }
        }

        return resolved
    }

    func fetchUserPrediction(proGameId: String) async throws -> VenueEventUserPredictions {
        let userID = try await currentUserId()
        let rows: [ProGamePredictionRow] = try await client
            .from("pro_game_predictions")
            .select(Self.predictionSelect)
            .eq("pro_game_id", value: proGameId)
            .eq("user_id", value: userID.uuidString.lowercased())
            .execute()
            .value
        return Self.userPredictions(from: rows)
    }

    func upsertPrediction(
        proGameId: String,
        predictionType: VenueEventPredictionType,
        predictedWinner: String? = nil,
        predictedHomeScore: Int? = nil,
        predictedAwayScore: Int? = nil,
        predictedFirstScoreTeam: String? = nil
    ) async throws {
        let userID = try await currentUserId()
        let payload = ProGamePredictionUpsert(
            pro_game_id: proGameId,
            user_id: userID,
            prediction_type: predictionType.rawValue,
            predicted_winner: Self.trimmed(predictedWinner),
            predicted_home_score: predictedHomeScore.map { max(0, $0) },
            predicted_away_score: predictedAwayScore.map { max(0, $0) },
            predicted_first_score_team: Self.trimmed(predictedFirstScoreTeam)
        )
        guard payload.hasValue(for: predictionType) else {
            throw ProGamePredictionServiceError.invalidPrediction
        }

        try await client
            .from(Self.predictionTableName)
            .upsert(payload, onConflict: Self.predictionUpsertConflictTarget)
            .execute()
        summaryCache.removeValue(forKey: proGameId)
    }

    func deletePrediction(proGameId: String, predictionType: VenueEventPredictionType) async throws {
        let userID = try await currentUserId()
        try await client
            .from("pro_game_predictions")
            .delete()
            .eq("pro_game_id", value: proGameId)
            .eq("user_id", value: userID.uuidString.lowercased())
            .eq("prediction_type", value: predictionType.rawValue)
            .execute()
        summaryCache.removeValue(forKey: proGameId)
    }

    func deleteAllPredictionsForUser(proGameId: String) async throws {
        let userID = try await currentUserId()
        try await client
            .from("pro_game_predictions")
            .delete()
            .eq("pro_game_id", value: proGameId)
            .eq("user_id", value: userID.uuidString.lowercased())
            .execute()
        summaryCache.removeValue(forKey: proGameId)
    }

    func invalidate(proGameID: String) {
        summaryCache.removeValue(forKey: proGameID)
    }

    private func currentUserId() async throws -> UUID {
        do {
            return try await client.auth.session.user.id
        } catch {
            throw ProGamePredictionServiceError.missingUser
        }
    }

    private func currentUserIdIfAvailable() async -> UUID? {
        try? await currentUserId()
    }

    private func loadAvatars(for rows: [ProGamePredictionRow]) async -> [UUID: VenuePredictionParticipantAvatar] {
        let recentUserIDs = Self.recentParticipantIDs(from: rows)
        guard !recentUserIDs.isEmpty else { return [:] }

        do {
            let profiles: [ProGamePredictionProfileRow] = try await client
                .from("user_profiles")
                .select("id,display_name,username,avatar_url,avatar_thumbnail_url")
                .in("id", values: recentUserIDs.map { $0.uuidString.lowercased() })
                .execute()
                .value
            return Dictionary(uniqueKeysWithValues: profiles.map { profile in
                (
                    profile.id,
                    VenuePredictionParticipantAvatar(
                        id: profile.id,
                        displayName: profile.displayName,
                        avatarURL: profile.avatar_url,
                        avatarThumbnailURL: profile.avatar_thumbnail_url
                    )
                )
            })
        } catch {
            return [:]
        }
    }

    private static let predictionSelect =
        "id,pro_game_id,user_id,prediction_type,predicted_winner,predicted_home_score,predicted_away_score,predicted_first_score_team,created_at,updated_at"
    private static let predictionTableName = "pro_game_predictions"
    private static let predictionUpsertConflictTarget = "pro_game_id,user_id,prediction_type"

    private static func buildSummary(
        proGameID: String,
        rows: [ProGamePredictionRow],
        avatarsByUserID: [UUID: VenuePredictionParticipantAvatar],
        currentUserID: UUID?
    ) -> ProGamePredictionSummary {
        let winnerRows = rows.filter { $0.prediction_type == VenueEventPredictionType.winner.rawValue }
        let scoreRows = rows.filter { $0.prediction_type == VenueEventPredictionType.score.rawValue }
        let firstScoreRows = rows.filter { $0.prediction_type == VenueEventPredictionType.firstScoreTeam.rawValue }
        let winnerValues = winnerRows.compactMap { trimmed($0.predicted_winner) }
        let firstScoreValues = firstScoreRows.compactMap { trimmed($0.predicted_first_score_team) }
        let validScoreRows = scoreRows.filter { $0.predicted_home_score != nil && $0.predicted_away_score != nil }
        let validTotalCount = winnerValues.count + validScoreRows.count + firstScoreValues.count
        let participantCount = Set(rows.map(\.user_id)).count

#if DEBUG
        Self.logParticipantCountDebug(
            gameId: proGameID,
            predictionRows: rows.count,
            distinctUsers: participantCount,
            displayedFanCount: participantCount,
            winnerVotes: winnerValues.count,
            scoreVotes: validScoreRows.count,
            firstGoalVotes: firstScoreValues.count,
            predictionRecordCount: validTotalCount
        )
#endif

        let winner = leaderPercent(values: winnerValues, denominator: winnerValues.count)
        let winnerPercents = optionPercents(values: winnerValues, denominator: winnerValues.count)
        let scoreMode = modeScore(rows: scoreRows)
        let scoreCrowdPicks = topScorePredictions(rows: scoreRows)
        let firstScore = leaderPercent(values: firstScoreValues, denominator: firstScoreValues.count)
        let firstScorePercents = optionPercents(values: firstScoreValues, denominator: firstScoreValues.count)
        let avatars = recentParticipantIDs(from: rows)
            .compactMap { avatarsByUserID[$0] }
            .prefix(3)
        let userPredictions = currentUserID.flatMap { userID in
            let userRows = rows.filter { $0.user_id == userID }
            let predictions = Self.userPredictions(from: userRows)
            return predictions.hasAnyPrediction ? predictions : nil
        }

        return ProGamePredictionSummary(
            proGameID: proGameID,
            participantCount: participantCount,
            totalCount: validTotalCount,
            winnerLeader: winner?.label,
            winnerPercent: winner?.percent,
            winnerPercents: winnerPercents,
            scoreMode: scoreMode,
            scorePredictionTotal: validScoreRows.count,
            topScorePredictions: scoreCrowdPicks,
            firstScoreLeader: firstScore?.label,
            firstScorePercent: firstScore?.percent,
            firstScorePercents: firstScorePercents,
            participantAvatars: Array(avatars),
            userPredictions: userPredictions,
            userPredictionsLoaded: currentUserID != nil
        )
    }

    private static func userPredictions(from rows: [ProGamePredictionRow]) -> VenueEventUserPredictions {
        var result = VenueEventUserPredictions()
        for row in rows {
            switch row.prediction_type {
            case VenueEventPredictionType.winner.rawValue:
                result.winner = trimmed(row.predicted_winner)
            case VenueEventPredictionType.score.rawValue:
                result.homeScore = row.predicted_home_score
                result.awayScore = row.predicted_away_score
            case VenueEventPredictionType.firstScoreTeam.rawValue:
                result.firstScoreTeam = trimmed(row.predicted_first_score_team)
            default:
                continue
            }
        }
        return result
    }

    private static func recentParticipantIDs(from rows: [ProGamePredictionRow]) -> [UUID] {
        var seen = Set<UUID>()
        return rows
            .sorted { ($0.updated_at ?? $0.created_at ?? "") > ($1.updated_at ?? $1.created_at ?? "") }
            .compactMap { row in
                guard seen.insert(row.user_id).inserted else { return nil }
                return row.user_id
            }
    }

    private static func leaderPercent(values: [String], denominator: Int) -> (label: String, percent: Int)? {
        guard denominator > 0 else { return nil }
        let grouped = Dictionary(grouping: values, by: { $0 })
        guard let top = grouped.max(by: { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
            return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedDescending
        }) else { return nil }
        let percent = Int((Double(top.value.count) / Double(denominator) * 100).rounded())
        return (top.key, percent)
    }

    private static func optionPercents(values: [String], denominator: Int) -> [String: Int] {
        guard denominator > 0 else { return [:] }
        return Dictionary(grouping: values, by: { $0 }).mapValues { rows in
            Int((Double(rows.count) / Double(denominator) * 100).rounded())
        }
    }

    private static func modeScore(rows: [ProGamePredictionRow]) -> String? {
        let values = rows.compactMap { row -> String? in
            guard let home = row.predicted_home_score, let away = row.predicted_away_score else { return nil }
            return "\(home) - \(away)"
        }
        return Dictionary(grouping: values, by: { $0 })
            .max { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
                return lhs.key > rhs.key
            }?
            .key
    }

    private static func topScorePredictions(rows: [ProGamePredictionRow]) -> [VenueScorePredictionCrowdPick] {
        let values = rows.compactMap { row -> (home: Int, away: Int)? in
            guard let home = row.predicted_home_score, let away = row.predicted_away_score else { return nil }
            return (home, away)
        }
        let total = values.count
        guard total > 0 else { return [] }

        let grouped = Dictionary(grouping: values, by: { "\($0.home)-\($0.away)" })
        let ranked = grouped
            .compactMap { _, values -> VenueScorePredictionCrowdPick? in
                guard let first = values.first else { return nil }
                return VenueScorePredictionCrowdPick(
                    homeScore: first.home,
                    awayScore: first.away,
                    count: values.count,
                    percent: Int((Double(values.count) / Double(total) * 100).rounded()),
                    isOther: false
                )
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return (lhs.homeScore ?? 0) > (rhs.homeScore ?? 0)
            }

        let top = Array(ranked.prefix(3))
        let remainingCount = max(0, total - top.reduce(0) { $0 + $1.count })
        guard remainingCount > 0 else { return top }
        return top + [
            VenueScorePredictionCrowdPick(
                homeScore: nil,
                awayScore: nil,
                count: remainingCount,
                percent: Int((Double(remainingCount) / Double(total) * 100).rounded()),
                isOther: true
            )
        ]
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

#if DEBUG
    private static func logParticipantCountDebug(
        gameId: String,
        predictionRows: Int,
        distinctUsers: Int,
        displayedFanCount: Int,
        winnerVotes: Int,
        scoreVotes: Int,
        firstGoalVotes: Int,
        predictionRecordCount: Int
    ) {
        print("[ProPredictionDebug] gameId=\(gameId)")
        print("[ProPredictionDebug] predictionRows=\(predictionRows)")
        print("[ProPredictionDebug] distinctUsers=\(distinctUsers)")
        print("[ProPredictionDebug] displayedFanCount=\(displayedFanCount)")
        print("[ProPredictionDebug] winnerVotes=\(winnerVotes) scoreVotes=\(scoreVotes) firstGoalVotes=\(firstGoalVotes) predictionRecordCount=\(predictionRecordCount)")
    }
#endif
}

private struct ProGamePredictionRow: Decodable, Sendable {
    let id: UUID
    let pro_game_id: String
    let user_id: UUID
    let prediction_type: String
    let predicted_winner: String?
    let predicted_home_score: Int?
    let predicted_away_score: Int?
    let predicted_first_score_team: String?
    let created_at: String?
    let updated_at: String?
}

private struct ProGamePredictionUpsert: Encodable {
    let pro_game_id: String
    let user_id: UUID
    let prediction_type: String
    let predicted_winner: String?
    let predicted_home_score: Int?
    let predicted_away_score: Int?
    let predicted_first_score_team: String?

    func hasValue(for type: VenueEventPredictionType) -> Bool {
        switch type {
        case .winner:
            return predicted_winner != nil
        case .score:
            return predicted_home_score != nil && predicted_away_score != nil
        case .firstScoreTeam:
            return predicted_first_score_team != nil
        }
    }
}

private struct ProGamePredictionProfileRow: Decodable {
    let id: UUID
    let display_name: String?
    let username: String?
    let avatar_url: String?
    let avatar_thumbnail_url: String?

    var displayName: String {
        let name = display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        let handle = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return handle.isEmpty ? "Fan" : FanGeoHandleRules.displayHandle(stored: handle)
    }
}

extension LiveMatch {
    var supportsProGamePredictions: Bool {
        switch liveSportVisualType {
        case .soccer, .hockey:
            return true
        default:
            return false
        }
    }
}

extension SavedProGame {
    var supportsProGamePredictions: Bool {
        switch liveSportVisualType {
        case .soccer, .hockey:
            return true
        default:
            return false
        }
    }

    var proGamePredictionLockTime: Date {
        startTime.addingTimeInterval(10 * 60)
    }

    var proGamePredictionsAreLocked: Bool {
        Date() > proGamePredictionLockTime
    }

    var proGamePredictionTeams: VenueEventPredictionTeams {
        VenueEventPredictionTeams(home: homeTeam, away: awayTeam)
    }

    static func forPredictions(match: LiveMatch, savedGames: [SavedProGame]) -> SavedProGame {
        let key = stableKey(for: match)
        return savedGames.first { $0.stableKey == key } ?? SavedProGame(match: match)
    }
}
