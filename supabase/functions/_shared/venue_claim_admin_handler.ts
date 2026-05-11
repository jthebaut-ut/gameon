/**
 * Shared GET handler for venue-claim approve/reject Edge Functions.
 *
 * Token verification is isolated here — swap only this module if your signing algorithm differs.
 *
 * Env:
 * - SUPABASE_URL
 * - SUPABASE_SERVICE_ROLE_KEY — updates venue_claims (admin link must not rely on end-user JWT)
 * - ADMIN_VENUE_CLAIM_LINK_SECRET — HS256 secret for ?token= JWT (payload: claim_id, action)
 */
import { createClient } from "npm:@supabase/supabase-js@2"
import { jwtVerify } from "npm:jose@5"
import {
  ClaimApproveError,
  ensureVenueForApprovedClaim,
  type VenueClaimRecord,
} from "./venue_claim_approve_venue.ts"
import {
  htmlResponse,
  pageAlreadyProcessed,
  pageApproved,
  pageExpiredOrInvalid,
  pageExpiredToken,
  pageInvalidToken,
  pageRejected,
  pageVenueApprovalFailed,
} from "./venue_claim_admin_html.ts"

export type AdminRouteAction = "approve" | "reject"

function isUuid(s: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(s)
}

function isPendingStatus(status: string | null | undefined): boolean {
  const s = status?.trim().toLowerCase() ?? ""
  if (s === "approved") return false
  if (s.includes("reject")) return false
  return true
}

function isRejectedStatus(status: string | null | undefined): boolean {
  const s = status?.trim().toLowerCase() ?? ""
  return s.includes("reject")
}

function isApprovedStatus(status: string | null | undefined): boolean {
  const s = status?.trim().toLowerCase() ?? ""
  return s === "approved"
}

function statusLabel(status: string | null | undefined): string {
  const s = status?.trim().toLowerCase() ?? ""
  if (s === "approved") return "approved"
  if (s.includes("reject")) return "rejected"
  return status?.trim() || "pending"
}

function formatTimestamp(): string {
  return new Date().toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" })
}

function isJwtExpiredError(e: unknown): boolean {
  return (
    typeof e === "object" &&
    e !== null &&
    "code" in e &&
    (e as { code?: string }).code === "ERR_JWT_EXPIRED"
  )
}

/** Verify signed admin link JWT; throws on invalid signature, expiry, or bad payload. */
async function verifyAdminActionToken(
  token: string,
  expectedAction: AdminRouteAction,
): Promise<{ claim_id: string }> {
  const secret = Deno.env.get("ADMIN_VENUE_CLAIM_LINK_SECRET")?.trim()
  if (!secret) {
    console.error("venue_claim_admin: missing ADMIN_VENUE_CLAIM_LINK_SECRET")
    throw new Error("misconfigured")
  }

  const key = new TextEncoder().encode(secret)
  const { payload } = await jwtVerify(token, key, { algorithms: ["HS256"] })

  const claim_id = typeof payload.claim_id === "string" ? payload.claim_id.trim() : ""
  const action = typeof payload.action === "string" ? payload.action.trim().toLowerCase() : ""

  if (!isUuid(claim_id)) throw new Error("bad_payload")
  if (action !== expectedAction) throw new Error("action_mismatch")

  return { claim_id }
}

export async function handleVenueClaimAdminGet(
  req: Request,
  routeAction: AdminRouteAction,
): Promise<Response> {
  if (req.method !== "GET") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    })
  }

  const url = new URL(req.url)
  const token = url.searchParams.get("token")?.trim() ?? ""

  if (!token) {
    return htmlResponse(pageInvalidToken(), 400)
  }

  let claimId: string
  try {
    ;({ claim_id: claimId } = await verifyAdminActionToken(token, routeAction))
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    if (msg === "misconfigured") {
      return htmlResponse(pageExpiredOrInvalid(), 500)
    }
    if (isJwtExpiredError(e)) {
      return htmlResponse(pageExpiredToken(), 401)
    }
    return htmlResponse(pageInvalidToken(), 401)
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  if (!supabaseUrl || !serviceKey) {
    console.error("venue_claim_admin: missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY")
    return htmlResponse(pageExpiredOrInvalid(), 500)
  }

  const supabase = createClient(supabaseUrl, serviceKey)

  const { data: claimRaw, error: selErr } = await supabase
    .from("venue_claims")
    .select("*")
    .eq("id", claimId)
    .maybeSingle()

  if (selErr) {
    console.error("venue_claim_admin: select error", selErr)
    return htmlResponse(pageExpiredOrInvalid(), 500)
  }

  const claim = claimRaw as VenueClaimRecord | null
  if (!claim) {
    return htmlResponse(pageExpiredOrInvalid(), 404)
  }

  const venueName = (claim.venue_name ?? "").trim() || "Unknown venue"
  const cid = claim.id
  const ts = formatTimestamp()

  if (routeAction === "reject") {
    if (isRejectedStatus(claim.approval_status)) {
      return htmlResponse(
        pageRejected({ venueName, claimId: cid, timestamp: ts }),
        200,
      )
    }
    if (isApprovedStatus(claim.approval_status)) {
      return htmlResponse(
        pageAlreadyProcessed({
          venueName,
          claimId: cid,
          statusLabel: "approved",
        }),
        200,
      )
    }
    if (!isPendingStatus(claim.approval_status)) {
      return htmlResponse(
        pageAlreadyProcessed({
          venueName,
          claimId: cid,
          statusLabel: statusLabel(claim.approval_status),
        }),
        200,
      )
    }

    const { error: upErr } = await supabase
      .from("venue_claims")
      .update({ approval_status: "rejected", rejection_acknowledged_at: null })
      .eq("id", claimId)

    if (upErr) {
      console.error("venue_claim_admin: reject update error", upErr)
      return htmlResponse(pageExpiredOrInvalid(), 500)
    }

    return htmlResponse(
      pageRejected({ venueName, claimId: cid, timestamp: ts }),
      200,
    )
  }

  // approve — never show success until `ensureVenueForApprovedClaim` completes and DB verifies
  // `venue_claims.venue_id` + `public.venues` row (do not short-circuit on approval_status alone).
  console.log("[ClaimApprove] handler entered")

  if (!isPendingStatus(claim.approval_status) && !isApprovedStatus(claim.approval_status)) {
    return htmlResponse(
      pageAlreadyProcessed({
        venueName,
        claimId: cid,
        statusLabel: statusLabel(claim.approval_status),
      }),
      200,
    )
  }

  console.log("[ClaimApprove] calling ensureVenueForApprovedClaim")
  let outcome: { venueName: string; claimId: string; venueId: string }
  try {
    outcome = await ensureVenueForApprovedClaim(supabase, claim)
  } catch (e) {
    if (e instanceof ClaimApproveError) {
      console.error(
        "[ClaimApprove] ensureVenueForApprovedClaim threw",
        "code=",
        e.code,
        "detail=",
        e.detail ?? "(none)",
      )
      return htmlResponse(
        pageVenueApprovalFailed({
          claimId: cid,
          code: e.code,
          detail: e.detail,
        }),
        500,
      )
    }
    const msg = e instanceof Error ? e.message : String(e)
    const stack = e instanceof Error ? e.stack : undefined
    console.error("[ClaimApprove] ensureVenueForApprovedClaim unexpected error", msg, stack)
    return htmlResponse(
      pageVenueApprovalFailed({
        claimId: cid,
        code: "unexpected_error",
        detail: msg,
      }),
      500,
    )
  }

  console.log(`[ClaimApprove] ensure complete venue_id=${outcome.venueId}`)
  console.log("[ClaimApprove] returning pageApproved (DB linkage verified)")

  const ownerEmail = (claim.owner_email ?? "").trim()
  const businessIdRaw = claim.business_id != null ? String(claim.business_id).trim() : ""
  let businessDisplayName: string | null = null
  if (businessIdRaw.length > 0) {
    const { data: bizRow, error: bizErr } = await supabase
      .from("businesses")
      .select("display_name")
      .eq("id", businessIdRaw)
      .maybeSingle()
    if (!bizErr && bizRow && typeof (bizRow as { display_name?: unknown }).display_name === "string") {
      const dn = (bizRow as { display_name: string }).display_name.trim()
      businessDisplayName = dn.length > 0 ? dn : null
    }
  }

  return htmlResponse(
    pageApproved({
      venueName: outcome.venueName,
      claimId: outcome.claimId,
      venueId: outcome.venueId,
      timestamp: ts,
      ownerEmail,
      businessId: businessIdRaw.length > 0 ? businessIdRaw : null,
      businessDisplayName,
    }),
    200,
  )
}
