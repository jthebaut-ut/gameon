import Foundation
import Supabase

/// Client preflight + user-facing copy for ``check_venue_claim_duplicate`` / duplicate insert errors.
enum VenueClaimDuplicateCheck {
    struct RpcParams: Encodable {
        let p_business_id: UUID?
        let p_owner_email: String
        let p_venue_name: String
        let p_venue_address: String
        let p_venue_city: String
        let p_venue_state: String
        let p_venue_zip: String
        let p_exclude_claim_id: UUID?
    }

    private struct CodeRow: Decodable {
        let code: String
    }

    /// Returns a user-visible error when the location is a duplicate; `nil` when `ok` or RPC returned no row.
    static func userMessage(forRpcCode code: String) -> String? {
        switch code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ok", "":
            return nil
        case "duplicate_venue_same_business":
            return "This location already exists for your business."
        case "duplicate_claim_pending":
            return "This location request is already pending review."
        case "duplicate_venue_other_business":
            return "This location may already be claimed. Please contact GameOn Support if this is your business."
        default:
            return nil
        }
    }

    /// Preflight duplicate check (server authoritative; trigger still enforces on insert).
    static func rpcPreflight(
        supabase: SupabaseClient,
        businessId: UUID?,
        ownerEmail: String,
        venueName: String,
        venueAddress: String,
        venueCity: String,
        venueState: String,
        venueZip: String,
        excludeClaimId: UUID? = nil
    ) async -> String? {
        let params = RpcParams(
            p_business_id: businessId,
            p_owner_email: ownerEmail,
            p_venue_name: venueName,
            p_venue_address: venueAddress,
            p_venue_city: venueCity,
            p_venue_state: venueState,
            p_venue_zip: venueZip,
            p_exclude_claim_id: excludeClaimId
        )
        do {
            let rows: [CodeRow] = try await supabase
                .rpc("check_venue_claim_duplicate", params: params)
                .execute()
                .value
            let code = rows.first?.code ?? "ok"
            return userMessage(forRpcCode: code)
        } catch {
#if DEBUG
            print("[VenueDuplicate] RPC check failed: \(error)")
#endif
            return "Could not verify whether this location is a duplicate. Check your connection and try again."
        }
    }

    /// Maps Postgres trigger messages and unique violations to the same copy as RPC.
    static func userMessageIfKnownInsertError(_ error: Error) -> String? {
        let blob = "\(error)".lowercased()
            + " "
            + (error as NSError).localizedDescription.lowercased()
        if blob.contains("duplicate_venue_same_business") {
            return userMessage(forRpcCode: "duplicate_venue_same_business")
        }
        if blob.contains("duplicate_claim_pending") {
            return userMessage(forRpcCode: "duplicate_claim_pending")
        }
        if blob.contains("duplicate_venue_other_business") {
            return userMessage(forRpcCode: "duplicate_venue_other_business")
        }
        if blob.contains("idx_venues_unique_identity_active") {
            return userMessage(forRpcCode: "duplicate_venue_other_business")
        }
        if blob.contains("idx_venue_claims_unique_open_identity")
            || blob.contains("23505")
            || blob.contains("duplicate key")
            || blob.contains("unique constraint") {
            return userMessage(forRpcCode: "duplicate_claim_pending")
        }
        return nil
    }
}
