import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { handleVenueClaimAdminGet } from "../_shared/venue_claim_admin_handler.ts"

/**
 * Browser GET (email link): approve a `venue_claims` row and ensure a linked `public.venues` row.
 *
 * - Pending + `venue_id` null → inserts `venues` from claim fields, sets `venue_claims.venue_id`, `approval_status=approved`.
 * - Pending + `venue_id` set → updates that `venues` row (business_id, owner_email, admin_status active, listing fields).
 * - Already approved + `venue_id` set → idempotent success HTML (no duplicate venue).
 * - Already approved + `venue_id` null → repair: insert venue and set `venue_id` only.
 *
 * Query: `token` — HS256 JWT signed with `ADMIN_VENUE_CLAIM_LINK_SECRET`.
 * Payload must include `claim_id` (uuid) and `action`: `"approve"`.
 *
 * Deploy: `supabase functions deploy venue-claim-approve`
 */

Deno.serve(async (req) => {
  const response = await handleVenueClaimAdminGet(req, "approve")

  const priorType = (response.headers.get("Content-Type") ?? "").toLowerCase()
  if (priorType.includes("application/json")) {
    return response
  }

  const html = await response.text()

  return new Response(html, {
    status: response.status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
    },
  })
})
