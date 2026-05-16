import Foundation
import Supabase

extension MapViewModel {

    func pickupCreatorTrustStats(for creatorUserId: UUID) -> PickupCreatorPublicRatingStats? {
        pickupCreatorPublicRatingStatsByUserId[creatorUserId]
    }

    func hasSubmittedPickupCreatorRating(for pickupGameId: UUID) -> Bool {
        pickupGameIdsWithMyCreatorRating.contains(pickupGameId)
    }

    /// Loads aggregate organizer stats and whether the current user already rated this game (Following / Discover detail).
    func refreshPickupCreatorRatingUIContext(pickupGameId: UUID, creatorUserId: UUID) async {
        await loadPickupOrganizerTrustStatsForPickupDetail(creatorUserId: creatorUserId)
        await refreshMyPickupCreatorRatingsForPickupGames(pickupGameIds: [pickupGameId])
    }

    /// Fetches `pickup_creator_public_rating_stats` for the organizer; retries once if the cache is still empty (network / decode hiccup).
    func loadPickupOrganizerTrustStatsForPickupDetail(creatorUserId: UUID) async {
        await refreshPickupCreatorPublicRatingStats(creatorUserIds: [creatorUserId])
        if pickupCreatorTrustStats(for: creatorUserId) == nil {
            await refreshPickupCreatorPublicRatingStatsForcing(creatorUserIds: [creatorUserId])
        }
        await MainActor.run {
            if self.pickupCreatorTrustStats(for: creatorUserId) == nil {
                self.pickupCreatorPublicRatingStatsByUserId[creatorUserId] = PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
            }
#if DEBUG
            PickupOrganizerRatingDebug.log(
                creatorUserId: creatorUserId,
                stats: self.pickupCreatorTrustStats(for: creatorUserId)
            )
#endif
        }
    }

    func refreshPickupCreatorPublicRatingStats(creatorUserIds: [UUID]) async {
        let unique = Array(Set(creatorUserIds))
        guard !unique.isEmpty else { return }

        var pairs: [(UUID, PickupCreatorPublicRatingStats?)] = []
        pairs.reserveCapacity(unique.count)
        await withTaskGroup(of: (UUID, PickupCreatorPublicRatingStats?).self) { group in
            for cid in unique {
                group.addTask {
                    let stats = await Self.fetchPickupCreatorPublicRatingStats(for: cid)
                    return (cid, stats)
                }
            }
            for await p in group {
                pairs.append(p)
            }
        }

        await MainActor.run {
            for (cid, stats) in pairs {
                if let stats {
                    self.pickupCreatorPublicRatingStatsByUserId[cid] = stats
                } else {
                    self.pickupCreatorPublicRatingStatsByUserId.removeValue(forKey: cid)
                }
            }
        }
    }

    /// Clears cached aggregates for the given creators, then refetches (e.g. after submitting a rating).
    func refreshPickupCreatorPublicRatingStatsForcing(creatorUserIds: [UUID]) async {
        let unique = Array(Set(creatorUserIds))
        guard !unique.isEmpty else { return }
        await MainActor.run {
            for cid in unique {
                self.pickupCreatorPublicRatingStatsByUserId.removeValue(forKey: cid)
            }
        }
        await refreshPickupCreatorPublicRatingStats(creatorUserIds: unique)
    }

    func refreshMyPickupCreatorRatingsForPickupGames(pickupGameIds: [UUID]) async {
        guard canFanUsePickupGamesUI, let uid = currentUserAuthId else {
            await MainActor.run { pickupGameIdsWithMyCreatorRating = [] }
            return
        }
        let unique = Array(Set(pickupGameIds))
        guard !unique.isEmpty else { return }

        struct IdRow: Decodable {
            let pickup_game_id: UUID
        }

        do {
            let rows: [IdRow] = try await supabase
                .from("pickup_game_creator_ratings")
                .select("pickup_game_id")
                .eq("rater_user_id", value: uid.uuidString.lowercased())
                .in("pickup_game_id", values: unique.map { $0.uuidString.lowercased() })
                .execute()
                .value
            let ids = Set(rows.map(\.pickup_game_id))
            await MainActor.run {
                for id in unique where ids.contains(id) {
                    self.pickupGameIdsWithMyCreatorRating.insert(id)
                }
            }
        } catch {
#if DEBUG
            print("[PickupCreatorRating] load existing ratings failed:", error)
#endif
        }
    }

    @discardableResult
    func submitPickupCreatorRating(
        pickupGameId: UUID,
        creatorUserId: UUID,
        rating: Int,
        feedback: String?
    ) async -> Bool {
        guard let rater = currentUserAuthId else {
            PickupCreatorRatingDebug.log(
                pickupGameId: pickupGameId,
                creatorUserId: creatorUserId,
                raterUserId: nil,
                rating: rating,
                submitSucceeded: false,
                alreadyRated: nil
            )
            return false
        }

        let trimmedFeedback = feedback?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(1000)
        let feedbackOut: String? = (trimmedFeedback?.isEmpty == true) ? nil : String(trimmedFeedback!)

        let payload = PickupGameCreatorRatingUpsert(
            pickup_game_id: pickupGameId,
            creator_user_id: creatorUserId,
            rater_user_id: rater,
            rating: min(5, max(1, rating)),
            feedback: feedbackOut
        )

        let alreadyRated = hasSubmittedPickupCreatorRating(for: pickupGameId)
        PickupCreatorRatingDebug.log(
            pickupGameId: pickupGameId,
            creatorUserId: creatorUserId,
            raterUserId: rater,
            rating: payload.rating,
            submitSucceeded: nil,
            alreadyRated: alreadyRated
        )

        do {
            try await supabase
                .from("pickup_game_creator_ratings")
                .upsert(payload, onConflict: "pickup_game_id,rater_user_id")
                .execute()
            _ = await MainActor.run {
                self.pickupGameIdsWithMyCreatorRating.insert(pickupGameId)
            }
            await refreshPickupCreatorPublicRatingStatsForcing(creatorUserIds: [creatorUserId])
            PickupCreatorRatingDebug.log(
                pickupGameId: pickupGameId,
                creatorUserId: creatorUserId,
                raterUserId: rater,
                rating: payload.rating,
                submitSucceeded: true,
                alreadyRated: false
            )
            if !alreadyRated {
                await awardFanXP(
                    userId: rater,
                    amount: 15,
                    source: FanXPSource.pickupComplete,
                    sourceId: pickupGameId
                )
            }
            return true
        } catch {
            let msg = String(describing: error).lowercased()
            let dup = msg.contains("duplicate") || msg.contains("unique") || msg.contains("23505")
            PickupCreatorRatingDebug.log(
                pickupGameId: pickupGameId,
                creatorUserId: creatorUserId,
                raterUserId: rater,
                rating: payload.rating,
                submitSucceeded: false,
                alreadyRated: dup
            )
#if DEBUG
            print("[PickupCreatorRating] submit failed:", error)
#endif
            if dup {
                _ = await MainActor.run {
                    self.pickupGameIdsWithMyCreatorRating.insert(pickupGameId)
                }
            }
            return false
        }
    }

    nonisolated private static func fetchPickupCreatorPublicRatingStats(for creatorUserId: UUID) async -> PickupCreatorPublicRatingStats? {
        struct Params: Encodable {
            let p_creator_user_id: UUID
        }
        do {
            let rows: [PickupCreatorPublicRatingStatsRPCRow] = try await supabase
                .rpc("pickup_creator_public_rating_stats", params: Params(p_creator_user_id: creatorUserId))
                .execute()
                .value
            if let first = rows.first, let stats = first.toPublicStats() {
                return stats
            }
            return PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
        } catch {
#if DEBUG
            print("[PickupCreatorRating] RPC stats failed creator=\(creatorUserId):", error)
#endif
            return nil
        }
    }
}
