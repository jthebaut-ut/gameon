import Foundation
import Supabase

/// Centralized Fan Level / XP reads and awards via `award_fan_xp` RPC.
enum FanXPSource {
    static let favoriteVenue = "favorite_venue"
    static let venueEventInterest = "venue_event_interest"
    static let pickupCreate = "pickup_create"
    static let pickupJoinApproved = "pickup_join_approved"
    static let pickupComplete = "pickup_complete"
    static let friendConnected = "friend_connected"

    static func rewardSubtitle(for source: String) -> String {
        switch source {
        case favoriteVenue: return "Venue Saved"
        case venueEventInterest: return "Game Plan Updated"
        case pickupCreate: return "Pickup Created"
        case pickupJoinApproved: return "Pickup Joined"
        case pickupComplete: return "Pickup Completed"
        case friendConnected: return "Friend Connected"
        default: return "Fan Activity"
        }
    }

    /// Legacy plain string (social toast); prefer ``FanXPRewardOverlayManager``.
    static func toastLabel(for source: String, amount: Int) -> String {
        "+\(amount) XP · \(rewardSubtitle(for: source))"
    }
}

struct FanXPAwardResult: Decodable {
    let awarded: Bool?
    let duplicate: Bool?
    let total_xp: Int?
    let level: Int?
    let title: String?
    let xp_gained: Int?
}

struct FanXPService {
    private let client: SupabaseClient

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    func loadUserXP(userId: UUID) async -> FanXPState {
        struct Row: Decodable {
            let total_xp: Int
            let level: Int
            let title: String
        }

        do {
            let rows: [Row] = try await client
                .from("user_xp")
                .select("total_xp,level,title")
                .eq("user_id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            if let row = rows.first {
                return FanXPState(
                    totalXP: row.total_xp,
                    level: row.level,
                    title: row.title
                )
            }
        } catch {
#if DEBUG
            print("[FanXPDebug] loadUserXP failed userId=\(userId.uuidString) error=\(error.localizedDescription)")
#endif
        }

        _ = try? await client.rpc("ensure_user_xp_row", params: EnsureRowParams(p_user_id: userId)).execute()
        return .rookie
    }

    @discardableResult
    func awardXP(
        userId: UUID,
        amount: Int,
        source: String,
        sourceId: UUID? = nil,
        sourceKey: String = ""
    ) async -> FanXPAwardResult? {
        guard amount > 0 else { return nil }

#if DEBUG
        print("[FanXPDebug] awardRequested source=\(source) amount=\(amount) userId=\(userId.uuidString) sourceId=\(sourceId?.uuidString ?? "nil") sourceKey=\(sourceKey)")
#endif

        struct Params: Encodable {
            let p_user_id: UUID
            let p_amount: Int
            let p_source: String
            let p_source_id: UUID?
            let p_source_key: String
        }

        do {
            let result: FanXPAwardResult = try await client
                .rpc(
                    "award_fan_xp",
                    params: Params(
                        p_user_id: userId,
                        p_amount: amount,
                        p_source: source,
                        p_source_id: sourceId,
                        p_source_key: sourceKey
                    )
                )
                .execute()
                .value

            if result.duplicate == true || result.awarded == false {
#if DEBUG
                print("[FanXPDebug] duplicateSkipped source=\(source) totalXP=\(result.total_xp ?? -1)")
#endif
            } else if result.awarded == true {
#if DEBUG
                print("[FanXPDebug] xpAwarded source=\(source) gained=\(result.xp_gained ?? amount)")
                print("[FanXPDebug] totalXP=\(result.total_xp ?? -1)")
                print("[FanXPDebug] level=\(result.level ?? -1)")
                print("[FanXPDebug] title=\(result.title ?? "")")
#endif
            }
            return result
        } catch {
#if DEBUG
            print("[FanXPDebug] awardFailed source=\(source) error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    private struct EnsureRowParams: Encodable {
        let p_user_id: UUID
    }
}
