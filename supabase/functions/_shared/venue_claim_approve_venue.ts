/**
 * Approve a `venue_claims` row: insert or sync `public.venues`, then atomically set
 * `approval_status = 'approved'` and `venue_id` on the claim. Throws on any failure.
 */
import type { SupabaseClient } from "npm:@supabase/supabase-js@2"

export interface VenueClaimRecord {
  id: string
  owner_email: string | null
  business_id: string | null
  venue_id: string | null
  venue_name: string | null
  venue_address: string | null
  venue_city: string | null
  venue_state: string | null
  venue_country: string | null
  venue_zip_code: string | null
  venue_phone: string | null
  venue_website: string | null
  venue_description: string | null
  venue_features: string | null
  screen_count: number | string | null
  serves_food: boolean | null
  has_wifi: boolean | null
  has_garden: boolean | null
  has_projector: boolean | null
  pet_friendly: boolean | null
  cover_photo_url: string | null
  menu_photo_url: string | null
  approval_status: string | null
  rejection_acknowledged_at?: string | null
}

/** Thrown when venue insert/update, claim update, or post-write verification fails. */
export class ClaimApproveError extends Error {
  readonly code: string
  readonly detail?: string

  constructor(message: string, code: string, detail?: string) {
    super(message)
    this.name = "ClaimApproveError"
    this.code = code
    this.detail = detail
  }
}

function norm(s: string | null | undefined): string {
  return (s ?? "").trim()
}

function isApprovedStatus(status: string | null | undefined): boolean {
  return norm(status).toLowerCase() === "approved"
}

function screenCountClamp(raw: number | string | null | undefined): number {
  const n = typeof raw === "number" ? raw : Number.parseInt(String(raw ?? "1"), 10)
  if (Number.isNaN(n)) return 1
  return Math.max(1, Math.min(99, n))
}

/** Columns on `public.venues` (claim uses `venue_*` / `venue_zip_code` / `venue_features`). */
function venuePayloadFromClaim(claim: VenueClaimRecord, ownerUserIdFromBusiness: string | null): Record<string, unknown> {
  const cover = norm(claim.cover_photo_url)
  const menu = norm(claim.menu_photo_url)
  return {
    owner_email: norm(claim.owner_email),
    business_id: norm(claim.business_id) || null,
    admin_status: "active",
    photo_review_status: "approved",
    venue_name: norm(claim.venue_name) || "Venue",
    address: norm(claim.venue_address),
    city: norm(claim.venue_city),
    state: norm(claim.venue_state),
    country: norm(claim.venue_country) || "USA",
    zip_code: norm(claim.venue_zip_code),
    phone: norm(claim.venue_phone),
    website: norm(claim.venue_website),
    description: norm(claim.venue_description),
    features: norm(claim.venue_features),
    screen_count: screenCountClamp(claim.screen_count),
    serves_food: !!claim.serves_food,
    has_wifi: !!claim.has_wifi,
    has_garden: !!claim.has_garden,
    has_projector: !!claim.has_projector,
    pet_friendly: !!claim.pet_friendly,
    latitude: null,
    longitude: null,
    cover_photo_url: cover.length > 0 ? cover : "",
    menu_photo_url: menu.length > 0 ? menu : "",
    cover_photo_thumbnail_url: null,
    menu_photo_thumbnail_url: null,
    ...(ownerUserIdFromBusiness ? { owner_user_id: ownerUserIdFromBusiness } : {}),
  }
}

async function businessOwnerUserIdForVenue(
  supabase: SupabaseClient,
  businessId: string,
): Promise<string | null> {
  const bid = norm(businessId)
  if (!bid) return null
  const { data, error } = await supabase.from("businesses").select("owner_user_id").eq("id", bid).maybeSingle()
  if (error || !data) return null
  const v = (data as { owner_user_id?: string | null }).owner_user_id
  if (v == null) return null
  const s = String(v).trim()
  return s.length ? s : null
}

function logVenuePayloadKeys(label: string, row: Record<string, unknown>) {
  const keys = Object.keys(row).sort().join(",")
  console.log(`[ClaimApprove] venue payload keys (${label})=${keys}`)
}

/** True if a row exists in `public.venues` for this id. */
async function venueRowExists(supabase: SupabaseClient, venueId: string): Promise<boolean> {
  const { data, error } = await supabase.from("venues").select("id").eq("id", venueId).maybeSingle()
  if (error) return false
  return data?.id != null
}

/**
 * After writes: `venue_claims.venue_id` NOT NULL, `approval_status` approved, and `public.venues` has a row.
 * Matches manual checks:
 *   select id, venue_id, approval_status from public.venue_claims where id = '<claim_id>';
 *   select * from public.venues where id = '<venue_id>';
 */
export async function verifyLinkageOrThrow(supabase: SupabaseClient, claimId: string): Promise<string> {
  console.log(
    `[ClaimApprove] verification SQL: select id, venue_id, approval_status from public.venue_claims where id = '${claimId}'`,
  )

  const { data: cRow, error: e1 } = await supabase
    .from("venue_claims")
    .select("id, venue_id, approval_status")
    .eq("id", claimId)
    .maybeSingle()

  if (e1) {
    const detail = JSON.stringify(e1)
    console.error("[ClaimApprove] verification FAILED", "claim_fetch_failed", detail)
    throw new ClaimApproveError("Could not read venue_claims after approve.", "claim_fetch_failed", detail)
  }

  const vid = cRow?.venue_id != null ? String(cRow.venue_id).trim() : ""
  const st = norm(cRow?.approval_status).toLowerCase()
  if (!vid) {
    console.error(
      "[ClaimApprove] verification FAILED: venue_id is NULL (expected NOT NULL)",
      `claim_id=${claimId}`,
    )
    throw new ClaimApproveError("venue_claims.venue_id is NULL after approve.", "venue_id_null_after_approve")
  }
  if (st !== "approved") {
    console.error(
      "[ClaimApprove] verification FAILED: approval_status is not approved",
      `claim_id=${claimId} approval_status=${cRow?.approval_status ?? "nil"}`,
    )
    throw new ClaimApproveError("venue_claims.approval_status is not approved after approve.", "approval_status_mismatch")
  }

  console.log(`[ClaimApprove] verification SQL: select * from public.venues where id = '${vid}'`)

  const { data: vRow, error: e2 } = await supabase.from("venues").select("*").eq("id", vid).maybeSingle()

  if (e2) {
    const detail = JSON.stringify(e2)
    console.error("[ClaimApprove] verification FAILED", "venue_row_fetch_failed", detail)
    throw new ClaimApproveError("Could not read public.venues for linked venue_id.", "venue_row_fetch_failed", detail)
  }

  if (!vRow) {
    console.error(
      "[ClaimApprove] verification FAILED: no row in public.venues for venue_id=",
      vid,
      `claim_id=${claimId}`,
    )
    throw new ClaimApproveError("No matching public.venues row for venue_claims.venue_id.", "venue_row_missing")
  }

  console.log(`[ClaimApprove] verification passed claim_id=${claimId} venue_id=${vid}`)
  return vid
}

export type ApproveVenueSuccess = { venueName: string; claimId: string; venueId: string }

/**
 * Approve + link: always persist `approval_status = 'approved'` and `venue_id` together on the claim
 * after ensuring a `public.venues` row exists (insert new or update existing linked row).
 */
export async function ensureVenueForApprovedClaim(
  supabase: SupabaseClient,
  claim: VenueClaimRecord,
): Promise<ApproveVenueSuccess> {
  const cid = claim.id
  const biz = norm(claim.business_id)
  const approved = isApprovedStatus(claim.approval_status)
  let existingVid = norm(claim.venue_id)
  const ownerUserIdFromBiz = await businessOwnerUserIdForVenue(supabase, biz)
  const claimStatusBefore = (claim.approval_status ?? "").trim() || "(empty)"
  const ownerEmailLog = norm(claim.owner_email) || "nil"

  console.log(`[VenueApprovalDebug] claimId=${cid}`)
  console.log(`[VenueApprovalDebug] claimStatusBefore=${claimStatusBefore}`)
  console.log(`[VenueApprovalDebug] businessId=${biz || "nil"}`)
  console.log(`[VenueApprovalDebug] ownerEmail=${ownerEmailLog}`)
  console.log(`[VenueApprovalDebug] ownerUserId=${ownerUserIdFromBiz ?? "nil"}`)

  console.log(
    `[ClaimApprove] loaded claim id=${cid} approval_status=${claimStatusBefore} venue_id=${existingVid || "NULL"} business_id=${biz || "nil"}`,
  )

  // Idempotent: already approved, linked, venues row present
  if (approved && existingVid) {
    const exists = await venueRowExists(supabase, existingVid)
    if (exists) {
      try {
        const venueId = await verifyLinkageOrThrow(supabase, cid)
        console.log(`[VenueApprovalDebug] createdVenueId=`)
        console.log(`[VenueApprovalDebug] updatedVenueId=${venueId}`)
        console.log(`[ClaimApprove] idempotent ok venue_id=${venueId}`)
        return {
          venueName: norm(claim.venue_name) || "Venue",
          claimId: cid,
          venueId,
        }
      } catch {
        console.warn(`[ClaimApprove] claim looked linked but verification failed; re-running approve flow claim_id=${cid}`)
        existingVid = ""
      }
    } else {
      console.warn(
        `[ClaimApprove] claim has venue_id=${existingVid} but no venues row; will insert new venue claim_id=${cid}`,
      )
      existingVid = ""
    }
  }

  const payload = venuePayloadFromClaim(claim, ownerUserIdFromBiz)

  if (existingVid && (await venueRowExists(supabase, existingVid))) {
    console.log(`[VenueApprovalDebug] updatedVenueId=${existingVid}`)
    console.log(`[VenueApprovalDebug] createdVenueId=`)
    console.log(`[ClaimApprove] branch=update_existing_venue venue_id=${existingVid}`)
    const updateRow: Record<string, unknown> = {
      ...payload,
      business_id: biz || null,
    }
    logVenuePayloadKeys("update", updateRow)

    const { error: upVenueErr } = await supabase
      .from("venues")
      .update(updateRow)
      .eq("id", existingVid)

    if (upVenueErr) {
      const detail = JSON.stringify(upVenueErr)
      console.error("[ClaimApprove] venue update error", detail)
      throw new ClaimApproveError("Venue row update failed.", "venue_update_failed", detail)
    }

    const { error: upClaimErr } = await supabase
      .from("venue_claims")
      .update({ approval_status: "approved", venue_id: existingVid })
      .eq("id", cid)

    if (upClaimErr) {
      const detail = JSON.stringify(upClaimErr)
      console.error("[ClaimApprove] venue_claims update error", detail)
      throw new ClaimApproveError("venue_claims update failed.", "claim_update_failed", detail)
    }

    console.log("[ClaimApprove] update claim venue_id success")
    const venueId = await verifyLinkageOrThrow(supabase, cid)
    return {
      venueName: String(payload.venue_name),
      claimId: cid,
      venueId,
    }
  }

  console.log("[ClaimApprove] insert venue start")
  const insertRow: Record<string, unknown> = {
    id: crypto.randomUUID(),
    ...payload,
    business_id: biz || null,
  }
  logVenuePayloadKeys("insert", insertRow)

  const { data: inserted, error: insErr } = await supabase
    .from("venues")
    .insert(insertRow)
    .select("id")
    .single()

  if (insErr || !inserted?.id) {
    const detail = insErr ? JSON.stringify(insErr) : "no_row_returned"
    console.error("[ClaimApprove] venue insert error", detail)
    throw new ClaimApproveError("Venue insert failed.", "venue_insert_failed", detail)
  }

  const newId = String(inserted.id)
  console.log(`[VenueApprovalDebug] createdVenueId=${newId}`)
  console.log(`[VenueApprovalDebug] updatedVenueId=`)
  console.log(`[ClaimApprove] insert venue success venue_id=${newId}`)

  const { error: upClaimErr } = await supabase
    .from("venue_claims")
    .update({ approval_status: "approved", venue_id: newId })
    .eq("id", cid)

  if (upClaimErr) {
    const detail = JSON.stringify(upClaimErr)
    console.error("[ClaimApprove] venue_claims update after insert error", detail)
    throw new ClaimApproveError("venue_claims update failed after venue insert.", "claim_link_failed", detail)
  }

  console.log("[ClaimApprove] update claim venue_id success")

  const venueId = await verifyLinkageOrThrow(supabase, cid)
  return {
    venueName: String(payload.venue_name),
    claimId: cid,
    venueId,
  }
}
