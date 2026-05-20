import Foundation
import Supabase

/// Decodes nullable home-crowd jsonb from dedicated public RPCs.
private struct HomeCrowdRPCPayload: Decodable {
    let summary: HomeCrowdVenueSummary?

    init(from decoder: Decoder) throws {
        if (try? decoder.singleValueContainer().decodeNil()) == true {
            summary = nil
            return
        }
        summary = HomeCrowdVenueSummary.decodeLenient(from: decoder)
    }
}

enum HomeCrowdService {
    static func loadSelfHomeCrowd(userId: UUID) async -> (venueId: UUID?, summary: HomeCrowdVenueSummary?) {
        struct Row: Decodable {
            let home_crowd_venue_id: UUID?
            let home_crowd_set_at: String?
        }

        do {
            let rows: [Row] = try await supabase
                .from("user_profiles")
                .select("home_crowd_venue_id,home_crowd_set_at")
                .eq("id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            guard let venueId = rows.first?.home_crowd_venue_id else {
                print("[HomeCrowd] loadSelf venueId=nil")
                return (nil, nil)
            }

            let setAt = rows.first?.home_crowd_set_at
            if let summary = await fetchVenueSummary(
                venueId: venueId,
                setAt: setAt,
                excludeUserId: userId
            ) {
                print("[HomeCrowd] loadSelf venueId=\(venueId.uuidString.lowercased())")
                return (venueId, summary)
            }

            print("[HomeCrowd] loadSelf venueId=\(venueId.uuidString.lowercased()) summary_missing")
            return (venueId, nil)
        } catch {
            print("[HomeCrowd] loadSelf failed error=\(error.localizedDescription)")
            return (nil, nil)
        }
    }

    static func setMyHomeCrowd(venueId: UUID) async throws -> HomeCrowdVenueSummary {
        struct Params: Encodable {
            let p_venue_id: UUID
        }

        HomeCrowdDebugLog.logSetPayload(venueId: venueId)

        do {
            let summary: HomeCrowdVenueSummary = try await supabase
                .rpc("set_my_home_crowd_venue", params: Params(p_venue_id: venueId))
                .execute()
                .value

            HomeCrowdDebugLog.logSetSuccess(venueId: venueId)
            print("[HomeCrowd] set venueId=\(venueId.uuidString.lowercased())")
            return summary
        } catch {
            HomeCrowdDebugLog.logSetError(error)
            throw error
        }
    }

    static func clearMyHomeCrowd() async throws {
        print("[HomeCrowdDebug] setPayload venueId=cleared")
        do {
            try await supabase
                .rpc("clear_my_home_crowd_venue")
                .execute()
            print("[HomeCrowdDebug] setSuccess venueId=cleared")
            HomeCrowdDebugLog.logVerifySelf(venueId: nil, setAt: nil)
            print("[HomeCrowd] clear")
        } catch {
            HomeCrowdDebugLog.logSetError(error)
            throw error
        }
    }

    static func verifySelfHomeCrowdVenueId(userId: UUID) async -> UUID? {
        struct Row: Decodable {
            let home_crowd_venue_id: UUID?
            let home_crowd_set_at: String?
        }

        do {
            let rows: [Row] = try await supabase
                .from("user_profiles")
                .select("home_crowd_venue_id, home_crowd_set_at")
                .eq("id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            let row = rows.first
            HomeCrowdDebugLog.logVerifySelf(venueId: row?.home_crowd_venue_id, setAt: row?.home_crowd_set_at)
            return row?.home_crowd_venue_id
        } catch {
            HomeCrowdDebugLog.logVerifySelf(venueId: nil, setAt: nil)
            return nil
        }
    }

    /// Public identity fallback: full home crowd summary for another fan (SECURITY DEFINER RPC).
    static func fetchPublicHomeCrowdForFan(targetUserId: UUID) async -> HomeCrowdVenueSummary? {
        struct Params: Encodable {
            let p_target_user_id: UUID
        }

        do {
            let payload: HomeCrowdRPCPayload? = try await supabase
                .rpc("get_public_fan_home_crowd", params: Params(p_target_user_id: targetUserId))
                .execute()
                .value
            if let summary = payload?.summary {
                print(
                    "[HomeCrowdDebug] publicRpcHomeCrowd= venueId=\(summary.venueId.uuidString.lowercased()) name=\(summary.name) source=dedicated_rpc"
                )
                return summary
            }
            print("[HomeCrowdDebug] publicRpcHomeCrowd= null source=dedicated_rpc")
            return nil
        } catch {
            print(
                "[HomeCrowdDebug] publicRpcHomeCrowd= dedicated_rpc_failed error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    struct PublicHomeCrowdPointer: Decodable {
        let venue_id: UUID
        let home_crowd_set_at: String?
    }

    static func fetchPublicHomeCrowdPointer(targetUserId: UUID) async -> PublicHomeCrowdPointer? {
        struct Params: Encodable {
            let p_target_user_id: UUID
        }

        do {
            let pointer: PublicHomeCrowdPointer? = try await supabase
                .rpc("get_public_fan_home_crowd_pointer", params: Params(p_target_user_id: targetUserId))
                .execute()
                .value
            if let pointer {
                print(
                    "[HomeCrowdDebug] publicHomeCrowdPointer venueId=\(pointer.venue_id.uuidString.lowercased())"
                )
            }
            return pointer
        } catch {
            print(
                "[HomeCrowdDebug] publicHomeCrowdPointer failed error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    static func fetchVenueSummaryForPublicProfile(
        venueId: UUID,
        setAt: String?,
        excludeUserId: UUID
    ) async -> HomeCrowdVenueSummary? {
        if let summary = await fetchVenueSummary(
            venueId: venueId,
            setAt: setAt,
            excludeUserId: excludeUserId
        ) {
            return summary
        }
        return await fetchVenueSummaryFromTable(venueId: venueId, setAt: setAt)
    }

    private static func fetchVenueSummary(
        venueId: UUID,
        setAt: String?,
        excludeUserId: UUID?
    ) async -> HomeCrowdVenueSummary? {
        struct Params: Encodable {
            let p_venue_id: UUID
            let p_set_at: String?
            let p_exclude_user_id: UUID?
        }

        do {
            let summary: HomeCrowdVenueSummary? = try await supabase
                .rpc(
                    "home_crowd_venue_summary",
                    params: Params(
                        p_venue_id: venueId,
                        p_set_at: setAt,
                        p_exclude_user_id: excludeUserId
                    )
                )
                .execute()
                .value
            return summary
        } catch {
            return await fetchVenueSummaryFromTable(venueId: venueId, setAt: setAt)
        }
    }

    static func fetchVenueSummaryFromTable(
        venueId: UUID,
        setAt: String?
    ) async -> HomeCrowdVenueSummary? {
        struct VenueRow: Decodable {
            let id: UUID
            let venue_name: String?
            let city: String?
            let address: String?
            let cover_photo_url: String?
            let cover_photo_thumbnail_url: String?
        }

        do {
            let rows: [VenueRow] = try await supabase
                .from("venues")
                .select("id,venue_name,city,address,cover_photo_url,cover_photo_thumbnail_url")
                .eq("id", value: venueId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            guard let row = rows.first else { return nil }
            let name = (row.venue_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let thumb = ImageDisplayURL.canonicalStorageURLString(
                row.cover_photo_thumbnail_url ?? row.cover_photo_url
            )
            return HomeCrowdVenueSummary(
                venueId: row.id,
                name: name,
                locationLabel: HomeCrowdLocationLabel.from(address: row.address, city: row.city),
                thumbnailURL: thumb.isEmpty ? nil : thumb,
                setAtRaw: setAt,
                fanCount: 0,
                fanAvatars: []
            )
        } catch {
            return nil
        }
    }
}
