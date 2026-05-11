import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { handleVenueClaimAdminGet } from "../_shared/venue_claim_admin_handler.ts"

/**
 * Browser GET (email link): reject a pending `venue_claims` row.
 *
 * Query: `token` — HS256 JWT signed with `ADMIN_VENUE_CLAIM_LINK_SECRET`.
 * Payload must include `claim_id` (uuid) and `action`: `"reject"`.
 *
 * Deploy: `supabase functions deploy venue-claim-reject`
 */

Deno.serve(async (req) => {
  const response = await handleVenueClaimAdminGet(req, "reject")

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
