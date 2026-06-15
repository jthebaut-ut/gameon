import Foundation
import Supabase

enum VenueEventPredictionType: String, CaseIterable, Identifiable, Codable, Sendable {
    case winner
    case score
    case firstScoreTeam = "first_score_team"

    var id: String { rawValue }
}

struct VenueEventPredictionTeams: Equatable, Sendable {
    let home: String
    let away: String

    init(home: String, away: String) {
        let safeHome = Self.safeTeamName(home, fallback: "Home")
        let safeAway = Self.safeTeamName(away, fallback: "Away")
        self.home = safeHome
        self.away = safeAway == safeHome ? "Away" : safeAway
    }

    var displayMatchup: String { "\(home) vs \(away)" }
    var options: [String] { [home, away] }

    private static func safeTeamName(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || $0.value == 0xfffd
        }) else {
            return fallback
        }
        return trimmed
    }
}

struct VenuePredictionParticipantAvatar: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let avatarURL: String?
    let avatarThumbnailURL: String?
}

struct VenueScorePredictionCrowdPick: Identifiable, Equatable, Sendable {
    let homeScore: Int?
    let awayScore: Int?
    let count: Int
    let percent: Int
    let isOther: Bool

    var id: String {
        if isOther { return "other" }
        return "\(homeScore ?? -1)-\(awayScore ?? -1)"
    }
}

struct VenueEventPredictionSummary: Equatable, Sendable {
    let venueEventID: UUID
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
    let winnerAvatarsByOption: [String: [VenuePredictionParticipantAvatar]]
    let firstScoreAvatarsByOption: [String: [VenuePredictionParticipantAvatar]]
    let userPredictions: VenueEventUserPredictions?
    let userPredictionsLoaded: Bool

    static func empty(
        eventID: UUID,
        userPredictions: VenueEventUserPredictions? = nil,
        userPredictionsLoaded: Bool = false
    ) -> VenueEventPredictionSummary {
        VenueEventPredictionSummary(
            venueEventID: eventID,
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
            winnerAvatarsByOption: [:],
            firstScoreAvatarsByOption: [:],
            userPredictions: userPredictions,
            userPredictionsLoaded: userPredictionsLoaded
        )
    }
}

struct VenueEventUserPredictions: Equatable, Sendable {
    var winner: String?
    var homeScore: Int?
    var awayScore: Int?
    var firstScoreTeam: String?

    var hasAnyPrediction: Bool {
        winner != nil
            || (homeScore != nil && awayScore != nil)
            || firstScoreTeam != nil
    }
}

enum VenueEventPredictionServiceError: LocalizedError {
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

enum VenueEventPredictionUserMessage {
    static let inactiveGame = "This game is no longer active."
    static let saveFailed = "Couldn’t save your pick. Please try again."

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return message == "cancelled"
            || message == "canceled"
            || message.contains("task was cancelled")
            || message.contains("task was canceled")
    }

    static func message(for error: Error) -> String {
        isCancellation(error) ? saveFailed : error.localizedDescription
    }
}

final class VenueEventPredictionService {
    static let shared = VenueEventPredictionService()

    private let client: SupabaseClient
    private let cacheTTL: TimeInterval = 45
    private var summaryCache: [UUID: (loadedAt: Date, userID: UUID?, summary: VenueEventPredictionSummary)] = [:]

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func fetchPredictionSummary(venueEventIds: [UUID], forceRefresh: Bool = false) async -> [UUID: VenueEventPredictionSummary] {
        let ids = Array(Set(venueEventIds))
        guard !ids.isEmpty else { return [:] }

        let now = Date()
        let currentUserID = await currentUserIdIfAvailable()
        var resolved: [UUID: VenueEventPredictionSummary] = [:]
        var idsToFetch: [UUID] = []
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

        idsToFetch.forEach {
#if DEBUG
            print("[PredictionDebug] load eventId=\($0.uuidString.lowercased())")
            print("[VenuePredictionDebug] loadSummary eventId=\($0.uuidString.lowercased())")
#endif
        }

        do {
            let rows: [VenueEventPredictionRow] = try await client
                .from("venue_event_predictions")
                .select(Self.predictionSelect)
                .in("venue_event_id", values: idsToFetch.map { $0.uuidString.lowercased() })
                .execute()
                .value
            let avatars = await loadAvatars(for: rows)
            for eventID in idsToFetch {
                let eventRows = rows.filter { $0.venue_event_id == eventID }
                let summary = Self.buildSummary(
                    eventID: eventID,
                    rows: eventRows,
                    avatarsByUserID: avatars,
                    currentUserID: currentUserID
                )
                summaryCache[eventID] = (loadedAt: Date(), userID: currentUserID, summary: summary)
                resolved[eventID] = summary
#if DEBUG
                print("[PredictionDebug] aggregateLoaded=true eventId=\(eventID.uuidString.lowercased()) total=\(summary.totalCount)")
                print("[PredictionDebug] userPredictionLoaded=\(summary.userPredictions?.hasAnyPrediction == true) eventId=\(eventID.uuidString.lowercased())")
                print("[VenuePredictionDebug] summaryCount=\(summary.totalCount)")
                print("[VenuePredictionDebug] avatarsLoaded=\(summary.participantAvatars.count)")
                print("[VenuePredictionDebug] winnerPercent=\(summary.winnerPercent ?? 0)")
                print("[VenuePredictionDebug] scoreMode=\(summary.scoreMode ?? "none")")
                print("[VenuePredictionDebug] firstScorePercent=\(summary.firstScorePercent ?? 0)")
                print("[PredictionDebug] votesLoaded=\(summary.totalCount)")
                print("[PredictionDebug] emptyState=\(summary.totalCount == 0)")
                print("[ScorePredictionDebug] aggregateLoaded=\(!summary.topScorePredictions.isEmpty)")
                print("[ScorePredictionDebug] aggregateTotal=\(summary.scorePredictionTotal)")
                if let topScore = summary.topScorePredictions.first, !topScore.isOther {
                    print("[ScorePredictionDebug] topScore=\(topScore.homeScore ?? 0)-\(topScore.awayScore ?? 0):\(topScore.percent)")
                }
#endif
            }
        } catch {
#if DEBUG
            print("[VenuePredictionDebug] loadSummaryFailed=\(error.localizedDescription)")
            print("[PredictionDebug] error=\(error.localizedDescription)")
#endif
            for eventID in idsToFetch {
                if let cached = summaryCache[eventID], cached.userID == currentUserID {
                    resolved[eventID] = cached.summary
                }
            }
        }

        return resolved
    }

    func fetchUserPrediction(venueEventId: UUID) async throws -> VenueEventUserPredictions {
#if DEBUG
        print("[PredictionDebug] load eventId=\(venueEventId.uuidString.lowercased())")
#endif
        let userID = try await currentUserId()
        let rows: [VenueEventPredictionRow] = try await client
            .from("venue_event_predictions")
            .select(Self.predictionSelect)
            .eq("venue_event_id", value: venueEventId.uuidString.lowercased())
            .eq("user_id", value: userID.uuidString.lowercased())
            .execute()
            .value
        let predictions = Self.userPredictions(from: rows)
#if DEBUG
        print("[PredictionDebug] userPredictionLoaded=\(predictions.hasAnyPrediction) eventId=\(venueEventId.uuidString.lowercased())")
#endif
        return predictions
    }

    func upsertPrediction(
        venueEventId: UUID,
        predictionType: VenueEventPredictionType,
        predictedWinner: String? = nil,
        predictedHomeScore: Int? = nil,
        predictedAwayScore: Int? = nil,
        predictedFirstScoreTeam: String? = nil
    ) async throws {
        let debugChoice = Self.predictionDebugChoice(
            predictionType: predictionType,
            predictedWinner: predictedWinner,
            predictedHomeScore: predictedHomeScore,
            predictedAwayScore: predictedAwayScore,
            predictedFirstScoreTeam: predictedFirstScoreTeam
        )
        let userID: UUID
        do {
            userID = try await currentUserId()
        } catch {
#if DEBUG
            Self.logPredictionVoteWriteFailure(
                error,
                venueEventId: venueEventId,
                userID: nil,
                predictionType: predictionType,
                choice: debugChoice
            )
#endif
            throw error
        }
        let payload = VenueEventPredictionUpsert(
            venue_event_id: venueEventId,
            user_id: userID,
            prediction_type: predictionType.rawValue,
            predicted_winner: Self.trimmed(predictedWinner),
            predicted_home_score: predictedHomeScore.map { max(0, $0) },
            predicted_away_score: predictedAwayScore.map { max(0, $0) },
            predicted_first_score_team: Self.trimmed(predictedFirstScoreTeam)
        )
        guard payload.hasValue(for: predictionType) else {
            let error = VenueEventPredictionServiceError.invalidPrediction
#if DEBUG
            Self.logPredictionVoteWriteFailure(
                error,
                venueEventId: venueEventId,
                userID: userID,
                predictionType: predictionType,
                choice: debugChoice
            )
#endif
            throw error
        }

#if DEBUG
        print("[VenuePredictionDebug] upsertPrediction type=\(predictionType.rawValue)")
        Self.logPredictionVoteWriteAttempt(
            venueEventId: venueEventId,
            userID: userID,
            predictionType: predictionType,
            choice: debugChoice
        )
#endif
        do {
            try await client
                .from(Self.predictionTableName)
                .upsert(payload, onConflict: Self.predictionUpsertConflictTarget)
                .execute()
        } catch {
#if DEBUG
            Self.logPredictionVoteWriteFailure(
                error,
                venueEventId: venueEventId,
                userID: userID,
                predictionType: predictionType,
                choice: debugChoice
            )
#endif
            throw error
        }
#if DEBUG
        print("[PredictionDebug] voteSaved=true eventId=\(venueEventId.uuidString.lowercased()) type=\(predictionType.rawValue)")
        print("[PredictionDebug] voteUpserted=true eventId=\(venueEventId.uuidString.lowercased()) type=\(predictionType.rawValue)")
#endif
        summaryCache.removeValue(forKey: venueEventId)
    }

    func deletePrediction(venueEventId: UUID, predictionType: VenueEventPredictionType) async throws {
        let userID = try await currentUserId()
        try await client
            .from("venue_event_predictions")
            .delete()
            .eq("venue_event_id", value: venueEventId.uuidString.lowercased())
            .eq("user_id", value: userID.uuidString.lowercased())
            .eq("prediction_type", value: predictionType.rawValue)
            .execute()
#if DEBUG
        print("[PredictionDebug] voteSaved=true eventId=\(venueEventId.uuidString.lowercased()) type=\(predictionType.rawValue) deleted=true")
#endif
        summaryCache.removeValue(forKey: venueEventId)
    }

    func invalidate(eventID: UUID) {
        summaryCache.removeValue(forKey: eventID)
    }

    private func currentUserId() async throws -> UUID {
        do {
            let session = try await client.auth.session
            return session.user.id
        } catch {
            throw VenueEventPredictionServiceError.missingUser
        }
    }

    private func currentUserIdIfAvailable() async -> UUID? {
        try? await currentUserId()
    }

    private func loadAvatars(for rows: [VenueEventPredictionRow]) async -> [UUID: VenuePredictionParticipantAvatar] {
        let recentUserIDs = Self.recentParticipantIDs(from: rows)
        guard !recentUserIDs.isEmpty else { return [:] }

        do {
            let profiles: [VenuePredictionProfileRow] = try await client
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
#if DEBUG
            print("[VenuePredictionDebug] avatarsLoadFailed=\(error.localizedDescription)")
#endif
            return [:]
        }
    }

    private static let predictionSelect =
        "id,venue_event_id,user_id,prediction_type,predicted_winner,predicted_home_score,predicted_away_score,predicted_first_score_team,created_at,updated_at"
    private static let predictionTableName = "venue_event_predictions"
    private static let predictionUpsertAction = "upsert"
    private static let predictionUpsertConflictTarget = "venue_event_id,user_id,prediction_type"
    private static let predictionUpsertUniqueConstraintName = "venue_event_predictions_unique_user_type"

#if DEBUG
    private static func logPredictionVoteWriteAttempt(
        venueEventId: UUID,
        userID: UUID,
        predictionType: VenueEventPredictionType,
        choice: String
    ) {
        print("[PredictionVoteDebug] table=\(predictionTableName)")
        print("[PredictionVoteDebug] action=\(predictionUpsertAction)")
        print("[PredictionVoteDebug] conflictTarget=\(predictionUpsertConflictTarget)")
        print("[PredictionVoteDebug] expectedUniqueConstraint=\(predictionUpsertUniqueConstraintName)")
        print("[PredictionVoteDebug] eventId=\(venueEventId.uuidString.lowercased())")
        print("[PredictionVoteDebug] userId=\(userID.uuidString.lowercased())")
        print("[PredictionVoteDebug] predictionType=\(predictionType.rawValue)")
        print("[PredictionVoteDebug] choice=\(choice)")
    }

    private static func logPredictionVoteWriteFailure(
        _ error: Error,
        venueEventId: UUID,
        userID: UUID?,
        predictionType: VenueEventPredictionType,
        choice: String
    ) {
        let localizedError = error as? LocalizedError
        let nsError = error as NSError

        print("[PredictionVoteDebug] table=\(predictionTableName)")
        print("[PredictionVoteDebug] action=\(predictionUpsertAction)")
        print("[PredictionVoteDebug] conflictTarget=\(predictionUpsertConflictTarget)")
        print("[PredictionVoteDebug] expectedUniqueConstraint=\(predictionUpsertUniqueConstraintName)")
        print("[PredictionVoteDebug] eventId=\(venueEventId.uuidString.lowercased())")
        print("[PredictionVoteDebug] userId=\(userID?.uuidString.lowercased() ?? "nil")")
        print("[PredictionVoteDebug] predictionType=\(predictionType.rawValue)")
        print("[PredictionVoteDebug] choice=\(choice)")
        print("[PredictionVoteDebug] errorDescription=\(localizedError?.errorDescription ?? "nil")")
        print("[PredictionVoteDebug] localizedDescription=\(error.localizedDescription)")
        print("[PredictionVoteDebug] rawError=\(String(reflecting: error))")
        print("[PredictionVoteDebug] nsErrorDomain=\(nsError.domain)")
        print("[PredictionVoteDebug] nsErrorCode=\(nsError.code)")
        print("[PredictionVoteDebug] nsErrorUserInfo=\(nsError.userInfo)")
    }
#endif

    private static func predictionDebugChoice(
        predictionType: VenueEventPredictionType,
        predictedWinner: String?,
        predictedHomeScore: Int?,
        predictedAwayScore: Int?,
        predictedFirstScoreTeam: String?
    ) -> String {
        switch predictionType {
        case .winner:
            return trimmed(predictedWinner) ?? "nil"
        case .score:
            let home = predictedHomeScore.map(String.init) ?? "nil"
            let away = predictedAwayScore.map(String.init) ?? "nil"
            return "\(home)-\(away)"
        case .firstScoreTeam:
            return trimmed(predictedFirstScoreTeam) ?? "nil"
        }
    }

    private static func buildSummary(
        eventID: UUID,
        rows: [VenueEventPredictionRow],
        avatarsByUserID: [UUID: VenuePredictionParticipantAvatar],
        currentUserID: UUID?
    ) -> VenueEventPredictionSummary {
        let winnerRows = rows.filter { $0.prediction_type == VenueEventPredictionType.winner.rawValue }
        let scoreRows = rows.filter { $0.prediction_type == VenueEventPredictionType.score.rawValue }
        let firstScoreRows = rows.filter { $0.prediction_type == VenueEventPredictionType.firstScoreTeam.rawValue }
        let winnerValues = winnerRows.compactMap { trimmed($0.predicted_winner) }
        let firstScoreValues = firstScoreRows.compactMap { trimmed($0.predicted_first_score_team) }
        let validScoreRows = scoreRows.filter { $0.predicted_home_score != nil && $0.predicted_away_score != nil }
        let validTotalCount = winnerValues.count + validScoreRows.count + firstScoreValues.count

        let winner = leaderPercent(
            values: winnerValues,
            denominator: winnerValues.count
        )
        let winnerPercents = optionPercents(
            values: winnerValues,
            denominator: winnerValues.count
        )
        let scoreMode = modeScore(rows: scoreRows)
        let scoreCrowdPicks = topScorePredictions(rows: scoreRows)
        let scorePredictionTotal = validScoreRows.count
        let firstScore = leaderPercent(
            values: firstScoreValues,
            denominator: firstScoreValues.count
        )
        let firstScorePercents = optionPercents(
            values: firstScoreValues,
            denominator: firstScoreValues.count
        )
        let avatars = recentParticipantIDs(from: rows)
            .compactMap { avatarsByUserID[$0] }
            .prefix(3)
        let winnerAvatars = avatarsByOption(
            rows: winnerRows,
            value: { trimmed($0.predicted_winner) },
            avatarsByUserID: avatarsByUserID
        )
        let firstScoreAvatars = avatarsByOption(
            rows: firstScoreRows,
            value: { trimmed($0.predicted_first_score_team) },
            avatarsByUserID: avatarsByUserID
        )
        let userPredictions = currentUserID.flatMap { userID in
            let userRows = rows.filter { $0.user_id == userID }
            let predictions = Self.userPredictions(from: userRows)
            return predictions.hasAnyPrediction ? predictions : nil
        }
        return VenueEventPredictionSummary(
            venueEventID: eventID,
            totalCount: validTotalCount,
            winnerLeader: winner?.label,
            winnerPercent: winner?.percent,
            winnerPercents: winnerPercents,
            scoreMode: scoreMode,
            scorePredictionTotal: scorePredictionTotal,
            topScorePredictions: scoreCrowdPicks,
            firstScoreLeader: firstScore?.label,
            firstScorePercent: firstScore?.percent,
            firstScorePercents: firstScorePercents,
            participantAvatars: Array(avatars),
            winnerAvatarsByOption: winnerAvatars,
            firstScoreAvatarsByOption: firstScoreAvatars,
            userPredictions: userPredictions,
            userPredictionsLoaded: currentUserID != nil
        )
    }

    private static func userPredictions(from rows: [VenueEventPredictionRow]) -> VenueEventUserPredictions {
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

    private static func recentParticipantIDs(from rows: [VenueEventPredictionRow]) -> [UUID] {
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

    private static func avatarsByOption(
        rows: [VenueEventPredictionRow],
        value: (VenueEventPredictionRow) -> String?,
        avatarsByUserID: [UUID: VenuePredictionParticipantAvatar]
    ) -> [String: [VenuePredictionParticipantAvatar]] {
        Dictionary(grouping: rows, by: { value($0) ?? "" }).reduce(into: [:]) { result, entry in
            guard !entry.key.isEmpty else { return }
            var seen = Set<UUID>()
            result[entry.key] = entry.value
                .sorted { ($0.updated_at ?? $0.created_at ?? "") > ($1.updated_at ?? $1.created_at ?? "") }
                .compactMap { row in
                    guard seen.insert(row.user_id).inserted else { return nil }
                    return avatarsByUserID[row.user_id]
                }
        }
    }

    private static func modeScore(rows: [VenueEventPredictionRow]) -> String? {
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

    private static func topScorePredictions(rows: [VenueEventPredictionRow]) -> [VenueScorePredictionCrowdPick] {
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
                let lhsHome = lhs.homeScore ?? 0
                let rhsHome = rhs.homeScore ?? 0
                if lhsHome != rhsHome { return lhsHome > rhsHome }
                return (lhs.awayScore ?? 0) > (rhs.awayScore ?? 0)
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
}

private struct VenueEventPredictionRow: Decodable, Sendable {
    let id: UUID
    let venue_event_id: UUID
    let user_id: UUID
    let prediction_type: String
    let predicted_winner: String?
    let predicted_home_score: Int?
    let predicted_away_score: Int?
    let predicted_first_score_team: String?
    let created_at: String?
    let updated_at: String?
}

private struct VenueEventPredictionUpsert: Encodable {
    let venue_event_id: UUID
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

private struct VenuePredictionProfileRow: Decodable {
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
