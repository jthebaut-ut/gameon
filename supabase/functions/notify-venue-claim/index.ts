import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"
import { SignJWT } from "npm:jose@5"

/**
 * Sends admin email when a venue_claim row is created (Discover claim, owner onboarding, or new location request).
 *
 * Secrets: ADMIN_EMAIL_TO, RESEND_API_KEY, RESEND_FROM
 * One-click Approve/Reject (preferred): set `ADMIN_VENUE_CLAIM_LINK_SECRET` (same HS256 secret as
 * `venue-claim-approve` / `venue-claim-reject`). Buttons use:
 *   `{SUPABASE_URL}/functions/v1/venue-claim-approve?token=<jwt>` and `.../venue-claim-reject?token=<jwt>`.
 * Legacy: `ADMIN_VENUE_CLAIM_APPROVE_URL_TEMPLATE` / `..._REJECT_...` with `{claim_id}` — any
 * `review-venue-claim` path is rewritten to `venue-claim-approve` / `venue-claim-reject` (still needs
 * `?token=` for those Edge handlers unless you use a custom gateway).
 *
 * Deploy: `supabase functions deploy notify-venue-claim`
 */

interface Payload {
  claim_id: string
  business_id?: string | null
  venue_id?: string | null
  /** `new_location` | `discover_claim` | `owner_venue_claim` */
  claim_kind: string
  owner_email: string
  venue_name: string
  venue_address: string
  venue_city: string
  venue_state: string
  venue_country?: string | null
  venue_zip_code: string
  venue_phone: string
  venue_website: string
  venue_description: string
  venue_features: string
  screen_count: number
  serves_food: boolean
  has_wifi: boolean
  has_garden: boolean
  has_projector: boolean
  pet_friendly: boolean
  family_friendly: boolean
  parking_available: boolean
  proof_note: string
  cover_photo_url: string
  menu_photo_url: string
  photo_urls: string[]
  created_at: string
  approval_status: string
  business_name?: string | null
  previous_status?: string | null
  new_status?: string | null
  cancelled_at?: string | null
  cancellation_note?: string | null
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

/** When service role is configured, warn admins if other rows share the same venue_identity_key. */
async function duplicateAdminWarningHtml(
  supabaseUrl: string,
  serviceRoleKey: string,
  claimId: string,
): Promise<string> {
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } })
  const { data: crow, error: rowErr } = await admin
    .from("venue_claims")
    .select("venue_identity_key")
    .eq("id", claimId)
    .maybeSingle()
  if (rowErr || !crow?.venue_identity_key) return ""
  const key = String(crow.venue_identity_key).trim()
  if (!key) return ""

  const { count: otherClaims, error: cErr } = await admin
    .from("venue_claims")
    .select("id", { count: "exact", head: true })
    .eq("venue_identity_key", key)
    .neq("id", claimId)
  if (cErr) return ""

  const { count: nonActiveVenues, error: vErr } = await admin
    .from("venues")
    .select("id", { count: "exact", head: true })
    .eq("venue_identity_key", key)
    .neq("admin_status", "active")
  if (vErr) return ""

  const oc = otherClaims ?? 0
  const nv = nonActiveVenues ?? 0
  if (oc === 0 && nv === 0) return ""

  return (
    `<p style="margin:14px 0;padding:12px 14px;background:#fffbeb;border:1px solid #fcd34d;border-radius:10px;font-size:14px;color:#92400e">` +
    `<strong>Possible duplicate:</strong> this submission matches the same normalized location signature as ` +
    `<strong>${escapeHtml(String(oc))}</strong> other claim(s) and <strong>${escapeHtml(String(nv))}</strong> non-active venue row(s). ` +
    `Review before approving.</p>`
  )
}

function expandClaimUrlTemplate(tpl: string, claimId: string): string {
  return tpl.replace(/\{claim_id\}/g, claimId)
}

/** Legacy env pointed at `review-venue-claim`; handlers are `venue-claim-approve` / `venue-claim-reject`. */
function fixLegacyReviewVenueClaimUrl(template: string, route: "approve" | "reject"): string {
  const fn = route === "approve" ? "venue-claim-approve" : "venue-claim-reject"
  return template
    .replace(/\/functions\/v1\/review-venue-claim\b/g, `/functions/v1/${fn}`)
    .replace(/\breview-venue-claim\b/g, fn)
}

async function signedVenueClaimAdminActionUrl(
  supabaseUrl: string,
  linkSecret: string,
  claimId: string,
  route: "approve" | "reject",
): Promise<string> {
  const key = new TextEncoder().encode(linkSecret)
  const action = route
  const token = await new SignJWT({ claim_id: claimId, action })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setExpirationTime("7d")
    .sign(key)
  const base = supabaseUrl.replace(/\/$/, "")
  const path = route === "approve" ? "venue-claim-approve" : "venue-claim-reject"
  return `${base}/functions/v1/${path}?token=${encodeURIComponent(token)}`
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    })
  }

  const authHeader = req.headers.get("Authorization")
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    })
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? ""
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? ""
  if (!supabaseUrl || !supabaseAnonKey) {
    console.error("notify-venue-claim: missing SUPABASE_URL or SUPABASE_ANON_KEY")
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  })

  const { data: { user }, error: authErr } = await supabase.auth.getUser()
  if (authErr || !user) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    })
  }

  let payload: Payload
  try {
    payload = await req.json()
  } catch {
    return new Response(JSON.stringify({ error: "invalid_json" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  const jwtEmail = (user.email ?? "").trim().toLowerCase()
  const bodyEmail = (payload.owner_email ?? "").trim().toLowerCase()
  if (!payload.claim_id?.trim() || !bodyEmail) {
    return new Response(JSON.stringify({ error: "missing_fields" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  if (jwtEmail !== bodyEmail) {
    console.warn("notify-venue-claim: owner_email mismatch jwt vs payload")
    return new Response(JSON.stringify({ error: "owner_email_mismatch" }), {
      status: 403,
      headers: { "Content-Type": "application/json" },
    })
  }

  const kind = (payload.claim_kind ?? "").trim()
  const isCancellation = kind === "cancelled_before_review"

  const adminTo = Deno.env.get("ADMIN_EMAIL_TO")?.trim()
  const resendKey = Deno.env.get("RESEND_API_KEY")?.trim()
  const resendFrom = Deno.env.get("RESEND_FROM")?.trim()
  if ((!adminTo && !isCancellation) || !resendKey || !resendFrom) {
    console.error("notify-venue-claim: missing ADMIN_EMAIL_TO, RESEND_API_KEY, or RESEND_FROM")
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  let headline = "Venue claim submitted"
  let intro =
    "A business owner submitted a venue claim. Review and approve or reject in your admin workflow."

  if (isCancellation) {
    headline = "Venue request cancelled before review"
    intro =
      "The business owner cancelled this venue request before approval/rejection."
  } else if (kind === "new_location") {
    headline = "New location request"
    intro =
      "A business owner submitted a new location request under their business account. It is pending admin review."
  } else if (kind === "discover_claim") {
    headline = "Discover — Claim this business"
    intro =
      "A user started a venue claim from Discover. It is pending admin review."
  }

  const approveTplRaw = Deno.env.get("ADMIN_VENUE_CLAIM_APPROVE_URL_TEMPLATE")?.trim()
  const rejectTplRaw = Deno.env.get("ADMIN_VENUE_CLAIM_REJECT_URL_TEMPLATE")?.trim()
  const linkSecret = Deno.env.get("ADMIN_VENUE_CLAIM_LINK_SECRET")?.trim()
  const cid = payload.claim_id.trim()

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ?? ""
  let duplicateAdminBanner = ""
  if (isCancellation) {
    duplicateAdminBanner = ""
  } else if (serviceRoleKey) {
    duplicateAdminBanner = await duplicateAdminWarningHtml(supabaseUrl, serviceRoleKey, cid)
  } else {
    console.warn(
      "notify-venue-claim: SUPABASE_SERVICE_ROLE_KEY unset — skipping duplicate-signature admin warning (set for richer admin email)",
    )
  }

  let actionRow = ""

  if (isCancellation) {
    actionRow = ""
  } else if (linkSecret) {
    const approveUrl = escapeHtml(await signedVenueClaimAdminActionUrl(supabaseUrl, linkSecret, cid, "approve"))
    const rejectUrl = escapeHtml(await signedVenueClaimAdminActionUrl(supabaseUrl, linkSecret, cid, "reject"))
    console.log(
      "notify-venue-claim: using signed venue-claim-approve / venue-claim-reject URLs (ADMIN_VENUE_CLAIM_LINK_SECRET set)",
    )
    actionRow =
      `<p style="margin:18px 0 8px;font-size:14px"><a href="${approveUrl}" style="display:inline-block;padding:10px 16px;background:#0f172a;color:#fff;text-decoration:none;border-radius:10px;font-weight:650;margin-right:10px">Approve</a>` +
      `<a href="${rejectUrl}" style="display:inline-block;padding:10px 16px;background:#64748b;color:#fff;text-decoration:none;border-radius:10px;font-weight:650">Reject</a></p>`
  } else if (approveTplRaw && rejectTplRaw) {
    const approveTpl = fixLegacyReviewVenueClaimUrl(approveTplRaw, "approve")
    const rejectTpl = fixLegacyReviewVenueClaimUrl(rejectTplRaw, "reject")
    const approveUrl = escapeHtml(expandClaimUrlTemplate(approveTpl, cid))
    const rejectUrl = escapeHtml(expandClaimUrlTemplate(rejectTpl, cid))
    console.warn(
      "notify-venue-claim: ADMIN_VENUE_CLAIM_LINK_SECRET unset — using URL templates (ensure ?token= JWT matches venue-claim-approve / venue-claim-reject handlers)",
    )
    actionRow =
      `<p style="margin:18px 0 8px;font-size:14px"><a href="${approveUrl}" style="display:inline-block;padding:10px 16px;background:#0f172a;color:#fff;text-decoration:none;border-radius:10px;font-weight:650;margin-right:10px">Approve</a>` +
      `<a href="${rejectUrl}" style="display:inline-block;padding:10px 16px;background:#64748b;color:#fff;text-decoration:none;border-radius:10px;font-weight:650">Reject</a></p>`
  } else {
    actionRow =
      `<p style="margin:14px 0;font-size:13px;color:#64748b">Configure <code>ADMIN_VENUE_CLAIM_LINK_SECRET</code> for one-click Approve/Reject (signed links to <code>venue-claim-approve</code> / <code>venue-claim-reject</code>), or set both <code>ADMIN_VENUE_CLAIM_APPROVE_URL_TEMPLATE</code> and <code>ADMIN_VENUE_CLAIM_REJECT_URL_TEMPLATE</code>.</p>`
  }

  const bizLine =
    payload.business_id?.trim()
      ? `<tr><td style="padding:6px 0;vertical-align:top;width:180px"><strong>business_id</strong></td><td style="padding:6px 0">${escapeHtml(payload.business_id!.trim())}</td></tr>`
      : ""

  const businessNameLine =
    payload.business_name?.trim()
      ? `<tr><td style="padding:6px 0;vertical-align:top;width:180px"><strong>Business name</strong></td><td style="padding:6px 0">${escapeHtml(payload.business_name!.trim())}</td></tr>`
      : ""

  const venueLine =
    payload.venue_id?.trim()
      ? `<tr><td style="padding:6px 0;vertical-align:top"><strong>venue_id</strong></td><td style="padding:6px 0">${escapeHtml(payload.venue_id!.trim())}</td></tr>`
      : `<tr><td style="padding:6px 0;vertical-align:top"><strong>venue_id</strong></td><td style="padding:6px 0"><em>(none — new location / not linked yet)</em></td></tr>`

  const venueCountryTail = (() => {
    const c = (payload.venue_country ?? "").trim()
    return c.length > 0 ? ` · ${escapeHtml(c)}` : ""
  })()

  const cancellationRows = isCancellation
    ? `
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Previous status</strong></td><td style="padding:6px 0">${escapeHtml((payload.previous_status ?? payload.approval_status ?? "").trim() || "pending")}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>New status</strong></td><td style="padding:6px 0">${escapeHtml((payload.new_status ?? payload.approval_status ?? "cancelled").trim() || "cancelled")}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Cancelled timestamp</strong></td><td style="padding:6px 0">${escapeHtml((payload.cancelled_at ?? new Date().toISOString()).trim())}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Note</strong></td><td style="padding:6px 0">${escapeHtml((payload.cancellation_note ?? "The business owner cancelled this venue request before approval/rejection.").trim())}</td></tr>`
    : ""

  const html = `<!DOCTYPE html>
<html>
<body style="font-family:system-ui,-apple-system,sans-serif;line-height:1.55;color:#1a1a1a;max-width:720px">
  <h1 style="font-size:20px;font-weight:650;margin:0 0 12px;color:#0f172a">${escapeHtml(headline)}</h1>
  <p style="margin:0 0 16px;font-size:15px">${intro}</p>
  ${duplicateAdminBanner}
  <p style="margin:0 0 10px;font-size:14px"><strong>Business owner email:</strong> ${escapeHtml(payload.owner_email.trim())}</p>
  <p style="margin:0 0 18px;font-size:14px;color:#475569"><strong>Status:</strong> ${isCancellation ? escapeHtml((payload.new_status ?? payload.approval_status ?? "cancelled").trim() || "cancelled") : `pending admin review (${escapeHtml(payload.approval_status || "pending")})`}</p>
  ${actionRow}
  <hr style="border:none;border-top:1px solid #e2e8f0;margin:18px 0"/>
  <table style="font-size:14px;border-collapse:collapse;width:100%">
    <tr><td style="padding:6px 0;vertical-align:top;width:180px"><strong>claim_id</strong></td><td style="padding:6px 0">${escapeHtml(cid)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>claim_kind</strong></td><td style="padding:6px 0">${escapeHtml(kind)}</td></tr>
    ${businessNameLine}
    ${bizLine}
    ${venueLine}
    ${cancellationRows}
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Venue</strong></td><td style="padding:6px 0">${escapeHtml(payload.venue_name)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Address</strong></td><td style="padding:6px 0">${escapeHtml(payload.venue_address)}, ${escapeHtml(payload.venue_city)}, ${escapeHtml(payload.venue_state)} ${escapeHtml(payload.venue_zip_code)}${venueCountryTail}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Phone</strong></td><td style="padding:6px 0">${escapeHtml(payload.venue_phone)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Website</strong></td><td style="padding:6px 0">${escapeHtml(payload.venue_website || "—")}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Screen count</strong></td><td style="padding:6px 0">${escapeHtml(String(payload.screen_count))}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Features (text)</strong></td><td style="padding:6px 0">${escapeHtml(payload.venue_features)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Amenities</strong></td><td style="padding:6px 0">food=${payload.serves_food} wifi=${payload.has_wifi} patio=${payload.has_garden} projector=${payload.has_projector} pet=${payload.pet_friendly} family=${payload.family_friendly} parking=${payload.parking_available}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Cover photo</strong></td><td style="padding:6px 0"><a href="${escapeHtml(payload.cover_photo_url)}">${escapeHtml(payload.cover_photo_url)}</a></td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Menu photo</strong></td><td style="padding:6px 0">${payload.menu_photo_url?.trim() ? `<a href="${escapeHtml(payload.menu_photo_url)}">${escapeHtml(payload.menu_photo_url)}</a>` : "—"}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Created</strong></td><td style="padding:6px 0">${escapeHtml(payload.created_at || "")}</td></tr>
  </table>
  <p style="margin:14px 0 8px;font-size:14px"><strong>Description</strong></p>
  <p style="margin:0;font-size:14px;white-space:pre-wrap;background:#f8fafc;padding:12px 14px;border-radius:10px;border:1px solid #e2e8f0">${escapeHtml(payload.venue_description)}</p>
  <p style="margin:14px 0 8px;font-size:14px"><strong>Proof note</strong></p>
  <p style="margin:0;font-size:14px;white-space:pre-wrap;background:#f8fafc;padding:12px 14px;border-radius:10px;border:1px solid #e2e8f0">${escapeHtml(payload.proof_note)}</p>
  <p style="margin-top:22px;font-size:12px;color:#64748b">Generated by FanGeo notify-venue-claim · submitter user id ${escapeHtml(user.id)}</p>
</body>
</html>`

  const subjectPrefix =
    isCancellation
      ? "Venue request cancelled before review"
      : kind === "new_location"
      ? "FanGeo — New location request"
      : kind === "discover_claim"
        ? "FanGeo — Discover venue claim"
        : "FanGeo — Venue claim"
  const emailSubject = isCancellation
    ? "Venue request cancelled before review"
    : `${subjectPrefix} — ${payload.venue_name.slice(0, 60)}`
  const emailTo = isCancellation ? "support@fangeosports.com" : (adminTo ?? "")

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: resendFrom,
      to: [emailTo],
      subject: emailSubject,
      html,
    }),
  })

  if (!res.ok) {
    const errText = await res.text()
    console.error("notify-venue-claim: Resend error", res.status, errText)
    return new Response(JSON.stringify({ ok: false, error: "email_send_failed", detail: errText.slice(0, 500) }), {
      status: 502,
      headers: { "Content-Type": "application/json" },
    })
  }

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  })
})
