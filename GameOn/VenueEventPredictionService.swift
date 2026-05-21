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

    var displayMatchup: String { "\(home) vs \(away)" }
    var options: [String] { [home, away] }
}

struct VenuePredictionParticipantAvatar: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let avatarURL: String?
    let avatarThumbnailURL: String?
}

struct VenueEventPredictionSummary: Equatable, Sendable {
    let venueEventID: UUID
    let totalCount: Int
    let winnerLeader: String?
    let winnerPercent: Int?
    let winnerPercents: [String: Int]
    let scoreMode: String?
    let firstScoreLeader: String?
    let firstScorePercent: Int?
    let firstScorePercents: [String: Int]
    let participantAvatars: [VenuePredictionParticipantAvatar]
    let winnerAvatarsByOption: [String: [VenuePredictionParticipantAvatar]]
    let firstScoreAvatarsByOption: [String: [VenuePredictionParticipantAvatar]]

    static func empty(eventID: UUID) -> VenueEventPredictionSummary {
        VenueEventPredictionSummary(
            venueEventID: eventID,
            totalCount: 0,
            winnerLeader: nil,
            winnerPercent: nil,
            winnerPercents: [:],
            scoreMode: nil,
            firstScoreLeader: nil,
            firstScorePercent: nil,
            firstScorePercents: [:],
            participantAvatars: [],
            winnerAvatarsByOption: [:],
            firstScoreAvatarsByOption: [:]
        )
    }
}

struct VenueEventUserPredictions: Equatable, Sendable {
    var winner: String?
    var homeScore: Int?
    var awayScore: Int?
    var firstScoreTeam: String?
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

final class VenueEventPredictionService {
    static let shared = VenueEventPredictionService()

    private let client: SupabaseClient
    private let cacheTTL: TimeInterval = 45
    private var summaryCache: [UUID: (loadedAt: Date, summary: VenueEventPredictionSummary)] = [:]

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func fetchPredictionSummary(venueEventIds: [UUID], forceRefresh: Bool = false) async -> [UUID: VenueEventPredictionSummary] {
        let ids = Array(Set(venueEventIds))
        guard !ids.isEmpty else { return [:] }

        let now = Date()
        var resolved: [UUID: VenueEventPredictionSummary] = [:]
        var idsToFetch: [UUID] = []
        for id in ids {
            if !forceRefresh,
               let cached = summaryCache[id],
               now.timeIntervalSince(cached.loadedAt) < cacheTTL {
                resolved[id] = cached.summary
            } else {
                idsToFetch.append(id)
            }
        }
        guard !idsToFetch.isEmpty else { return resolved }

        idsToFetch.forEach {
#if DEBUG
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
                let summary = Self.buildSummary(eventID: eventID, rows: eventRows, avatarsByUserID: avatars)
                summaryCache[eventID] = (Date(), summary)
                resolved[eventID] = summary
#if DEBUG
                print("[VenuePredictionDebug] summaryCount=\(summary.totalCount)")
                print("[VenuePredictionDebug] avatarsLoaded=\(summary.participantAvatars.count)")
                print("[VenuePredictionDebug] winnerPercent=\(summary.winnerPercent ?? 0)")
                print("[VenuePredictionDebug] scoreMode=\(summary.scoreMode ?? "none")")
                print("[VenuePredictionDebug] firstScorePercent=\(summary.firstScorePercent ?? 0)")
#endif
            }
        } catch {
#if DEBUG
            print("[VenuePredictionDebug] loadSummaryFailed=\(error.localizedDescription)")
#endif
            for eventID in idsToFetch {
                let summary = VenueEventPredictionSummary.empty(eventID: eventID)
                summaryCache[eventID] = (Date(), summary)
                resolved[eventID] = summary
            }
        }

        return resolved
    }

    func fetchUserPrediction(venueEventId: UUID) async throws -> VenueEventUserPredictions {
        let userID = try await currentUserId()
        let rows: [VenueEventPredictionRow] = try await client
            .from("venue_event_predictions")
            .select(Self.predictionSelect)
            .eq("venue_event_id", value: venueEventId.uuidString.lowercased())
            .eq("user_id", value: userID.uuidString.lowercased())
            .execute()
            .value
        return Self.userPredictions(from: rows)
    }

    func upsertPrediction(
        venueEventId: UUID,
        predictionType: VenueEventPredictionType,
        predictedWinner: String? = nil,
        predictedHomeScore: Int? = nil,
        predictedAwayScore: Int? = nil,
        predictedFirstScoreTeam: String? = nil
    ) async throws {
        let userID = try await currentUserId()
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
            throw VenueEventPredictionServiceError.invalidPrediction
        }

#if DEBUG
        print("[VenuePredictionDebug] upsertPrediction type=\(predictionType.rawValue)")
#endif
        try await client
            .from("venue_event_predictions")
            .upsert(payload, onConflict: "venue_event_id,user_id,prediction_type")
            .execute()
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

    private static func buildSummary(
        eventID: UUID,
        rows: [VenueEventPredictionRow],
        avatarsByUserID: [UUID: VenuePredictionParticipantAvatar]
    ) -> VenueEventPredictionSummary {
        let winnerRows = rows.filter { $0.prediction_type == VenueEventPredictionType.winner.rawValue }
        let scoreRows = rows.filter { $0.prediction_type == VenueEventPredictionType.score.rawValue }
        let firstScoreRows = rows.filter { $0.prediction_type == VenueEventPredictionType.firstScoreTeam.rawValue }

        let winner = leaderPercent(
            values: winnerRows.compactMap { trimmed($0.predicted_winner) },
            denominator: winnerRows.count
        )
        let winnerPercents = optionPercents(
            values: winnerRows.compactMap { trimmed($0.predicted_winner) },
            denominator: winnerRows.count
        )
        let scoreMode = modeScore(rows: scoreRows)
        let firstScore = leaderPercent(
            values: firstScoreRows.compactMap { trimmed($0.predicted_first_score_team) },
            denominator: firstScoreRows.count
        )
        let firstScorePercents = optionPercents(
            values: firstScoreRows.compactMap { trimmed($0.predicted_first_score_team) },
            denominator: firstScoreRows.count
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
        return VenueEventPredictionSummary(
            venueEventID: eventID,
            totalCount: rows.count,
            winnerLeader: winner?.label,
            winnerPercent: winner?.percent,
            winnerPercents: winnerPercents,
            scoreMode: scoreMode,
            firstScoreLeader: firstScore?.label,
            firstScorePercent: firstScore?.percent,
            firstScorePercents: firstScorePercents,
            participantAvatars: Array(avatars),
            winnerAvatarsByOption: winnerAvatars,
            firstScoreAvatarsByOption: firstScoreAvatars
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
