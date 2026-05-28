import Foundation
import Supabase

/// Client preflight + user-facing copy for ``check_venue_claim_duplicate`` / duplicate insert errors.
enum VenueClaimDuplicateCheck {
    struct RpcParams: Encodable {
        enum CodingKeys: String, CodingKey {
            case p_business_id
            case p_owner_email
            case p_venue_name
            case p_venue_address
            case p_venue_city
            case p_venue_state
            case p_venue_zip
            case p_exclude_claim_id
        }

        let p_business_id: UUID?
        let p_owner_email: String
        let p_venue_name: String
        let p_venue_address: String
        let p_venue_city: String
        let p_venue_state: String
        let p_venue_zip: String
        let p_exclude_claim_id: UUID?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let p_business_id {
                try container.encode(p_business_id, forKey: .p_business_id)
            } else {
                try container.encodeNil(forKey: .p_business_id)
            }
            try container.encode(p_owner_email, forKey: .p_owner_email)
            try container.encode(p_venue_name, forKey: .p_venue_name)
            try container.encode(p_venue_address, forKey: .p_venue_address)
            try container.encode(p_venue_city, forKey: .p_venue_city)
            try container.encode(p_venue_state, forKey: .p_venue_state)
            try container.encode(p_venue_zip, forKey: .p_venue_zip)
            if let p_exclude_claim_id {
                try container.encode(p_exclude_claim_id, forKey: .p_exclude_claim_id)
            } else {
                try container.encodeNil(forKey: .p_exclude_claim_id)
            }
        }

        var debugPayload: String {
            [
                "p_business_id=\(p_business_id?.uuidString.lowercased() ?? "null")",
                "p_owner_email=\(p_owner_email)",
                "p_venue_name=\(p_venue_name)",
                "p_venue_address=\(p_venue_address)",
                "p_venue_city=\(p_venue_city)",
                "p_venue_state=\(p_venue_state)",
                "p_venue_zip=\(p_venue_zip)",
                "p_exclude_claim_id=\(p_exclude_claim_id?.uuidString.lowercased() ?? "null")"
            ].joined(separator: " ")
        }
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
            return "This location may already be claimed. Please contact FanGeo Support if this is your business."
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
#if DEBUG
            print("[VenueDuplicateCheckDebug] rpcName=check_venue_claim_duplicate")
            print("[VenueDuplicateCheckDebug] resultCode=\(code)")
            print("[VenueDuplicateCheckDebug] rpcParams=\(params.debugPayload)")
#endif
            return userMessage(forRpcCode: code)
        } catch {
#if DEBUG
            logRpcError(error, params: params)
#endif

            return "Could not verify whether this location is a duplicate. Check your connection and try again."
        }
    }

    private static func logRpcError(_ error: Error, params: RpcParams) {
        print("[VenueDuplicateCheckDebug] rpcName=check_venue_claim_duplicate")
        if let postgrestError = error as? PostgrestError {
            print("[VenueDuplicateCheckDebug] PostgrestError.code=\(postgrestError.code ?? "nil")")
            print("[VenueDuplicateCheckDebug] PostgrestError.message=\(postgrestError.message)")
            print("[VenueDuplicateCheckDebug] PostgrestError.detail=\(postgrestError.detail ?? "nil")")
            print("[VenueDuplicateCheckDebug] PostgrestError.hint=\(postgrestError.hint ?? "nil")")
        } else {
            print("[VenueDuplicateCheckDebug] PostgrestError.code=nil")
            print("[VenueDuplicateCheckDebug] PostgrestError.message=\(error.localizedDescription)")
            print("[VenueDuplicateCheckDebug] PostgrestError.detail=nil")
            print("[VenueDuplicateCheckDebug] PostgrestError.hint=nil")
        }
        let nsError = error as NSError
        print("[VenueDuplicateCheckDebug] NSError.domain=\(nsError.domain)")
        print("[VenueDuplicateCheckDebug] NSError.code=\(nsError.code)")
        print("[VenueDuplicateCheckDebug] NSError.userInfo=\(String(describing: nsError.userInfo))")
        print("[VenueDuplicateCheckDebug] rpcParams=\(params.debugPayload)")
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
