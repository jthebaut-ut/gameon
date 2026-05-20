import Foundation
import Supabase

enum HomeCrowdService {
    static func loadSelfHomeCrowd(userId: UUID) async -> (venueId: UUID?, summary: HomeCrowdVenueSummary?) {
        struct Row: Decodable {
            let home_crowd_venue_id: UUID?
        }

        do {
            let rows: [Row] = try await supabase
                .from("user_profiles")
                .select("home_crowd_venue_id")
                .eq("id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            guard let venueId = rows.first?.home_crowd_venue_id else {
                print("[HomeCrowd] loadSelf venueId=nil")
                return (nil, nil)
            }

            if let summary = await fetchVenueSummary(venueId: venueId) {
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

        let summary: HomeCrowdVenueSummary = try await supabase
            .rpc("set_my_home_crowd_venue", params: Params(p_venue_id: venueId))
            .execute()
            .value

        print("[HomeCrowd] set venueId=\(venueId.uuidString.lowercased())")
        return summary
    }

    static func clearMyHomeCrowd() async throws {
        try await supabase
            .rpc("clear_my_home_crowd_venue")
            .execute()
        print("[HomeCrowd] clear")
    }

    private static func fetchVenueSummary(venueId: UUID) async -> HomeCrowdVenueSummary? {
        struct Params: Encodable {
            let p_venue_id: UUID
        }

        do {
            let summary: HomeCrowdVenueSummary? = try await supabase
                .rpc("home_crowd_venue_summary", params: Params(p_venue_id: venueId))
                .execute()
                .value
            return summary
        } catch {
            return await fetchVenueSummaryFromTable(venueId: venueId)
        }
    }

    private static func fetchVenueSummaryFromTable(venueId: UUID) async -> HomeCrowdVenueSummary? {
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
                thumbnailURL: thumb.isEmpty ? nil : thumb
            )
        } catch {
            return nil
        }
    }
}
