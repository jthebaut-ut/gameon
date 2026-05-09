import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

function escapeHtml(raw: string): string {
  return raw
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&#39;")
}

function titleizeKey(key: string): string {
  return key
    .replaceAll("_", " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\b\w/g, (c) => c.toUpperCase())
}

function isEmptyValue(v: unknown): boolean {
  if (v === null || v === undefined) return true
  if (typeof v === "string") return v.trim().length === 0
  if (Array.isArray(v)) return v.length === 0 || v.every((x) => isEmptyValue(x))
  if (typeof v === "object") return Object.keys(v as Record<string, unknown>).length === 0
  return false
}

function stringifyValue(v: unknown): string {
  if (v === null || v === undefined) return ""
  if (typeof v === "string") return v.trim()
  if (typeof v === "number" || typeof v === "boolean") return String(v)
  if (Array.isArray(v)) {
    return v.map((x) => stringifyValue(x)).filter((s) => s.length > 0).join(", ")
  }
  try {
    return JSON.stringify(v)
  } catch {
    return String(v)
  }
}

function isFiniteNumberString(raw: string): boolean {
  if (!raw) return false
  const n = Number(raw)
  return Number.isFinite(n)
}

function bestMapsUrlFromPayload(body: Record<string, unknown>): string | null {
  // Prefer lat/lng if present (future-proof).
  const latKeys = ["lat", "latitude", "venue_lat", "venue_latitude", "owner_latitude"]
  const lngKeys = ["lng", "lon", "long", "longitude", "venue_lng", "venue_longitude", "owner_longitude"]

  const lat = latKeys.map((k) => stringifyValue(body[k])).find((v) => isFiniteNumberString(v))
  const lng = lngKeys.map((k) => stringifyValue(body[k])).find((v) => isFiniteNumberString(v))
  if (lat && lng) {
    const query = encodeURIComponent(`${Number(lat)},${Number(lng)}`)
    return `https://www.google.com/maps/search/?api=1&query=${query}`
  }

  // Fall back to address-like fields.
  const addressKeys = [
    "address",
    "full_address",
    "street_address",
    "venue_address",
    "ownerVenueAddress",
  ]
  const address = addressKeys.map((k) => stringifyValue(body[k])).find((v) => v.trim().length > 0)
  if (address) {
    const query = encodeURIComponent(address)
    return `https://www.google.com/maps/search/?api=1&query=${query}`
  }

  return null
}

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder()
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  )
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message))
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("")
}

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    })
  }

  // Auth gate: requires a valid Supabase user JWT in Authorization header.
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? Deno.env.get("PROJECT_URL")
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")
  if (!supabaseUrl || !anonKey) {
    return new Response(JSON.stringify({ error: "missing_supabase_env" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  const authHeader = req.headers.get("Authorization") ?? ""
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return new Response(JSON.stringify({ error: "missing_auth" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    })
  }

  const supabase = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  })

  const { data: userData, error: userErr } = await supabase.auth.getUser()
  if (userErr || !userData?.user) {
    return new Response(JSON.stringify({ error: "invalid_auth" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    })
  }

  let body: Record<string, unknown>
  try {
    const parsed = await req.json()
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return new Response(JSON.stringify({ error: "invalid_payload" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      })
    }
    body = parsed as Record<string, unknown>
  } catch {
    return new Response(JSON.stringify({ error: "invalid_json" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  const adminTo = Deno.env.get("ADMIN_EMAIL_TO")
  const resendKey = Deno.env.get("RESEND_API_KEY")
  const resendFrom = Deno.env.get("RESEND_FROM") ?? "GameOn <onboarding@resend.dev>"
  const moderationSecret = Deno.env.get("MODERATION_HMAC_SECRET")
  const functionsBaseUrl = Deno.env.get("FUNCTIONS_PUBLIC_BASE_URL")
  if (!adminTo || adminTo.trim().length === 0) {
    return new Response(JSON.stringify({ error: "missing_admin_email_to" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }
  if (!resendKey) {
    return new Response(JSON.stringify({ error: "missing_resend_key" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }
  if (!moderationSecret) {
    return new Response(JSON.stringify({ error: "missing_moderation_hmac_secret" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }
  if (!functionsBaseUrl || functionsBaseUrl.trim().length === 0) {
    return new Response(JSON.stringify({ error: "missing_functions_public_base_url" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  const venueName = stringifyValue(body["venue_name"] ?? body["venue"] ?? "Venue") || "Venue"
  const ownerEmail = stringifyValue(body["owner_email"] ?? userData.user.email ?? "")
  const createdAt = stringifyValue(body["created_at"] ?? new Date().toISOString())
  const status = stringifyValue(body["approval_status"] ?? "pending").toLowerCase() || "pending"
  const claimId = stringifyValue(body["claim_id"] ?? body["id"] ?? "")
  if (!claimId) {
    return new Response(JSON.stringify({ error: "missing_claim_id" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  const photoUrlsRaw = body["photo_urls"]
  const photoUrls = Array.isArray(photoUrlsRaw)
    ? photoUrlsRaw.map((u) => stringifyValue(u)).filter((u) => u.length > 0)
    : []

  const subject = `GameOn venue claim: ${venueName} (${status})`

  // Moderation action URLs (HMAC-signed, expiring).
  const exp = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60 // 7 days
  const approveMsg = `approve:${claimId}:${exp}`
  const rejectMsg = `reject:${claimId}:${exp}`
  const approveSig = await hmacSha256Hex(moderationSecret, approveMsg)
  const rejectSig = await hmacSha256Hex(moderationSecret, rejectMsg)
  const approveUrl =
    `${functionsBaseUrl.replace(/\/$/, "")}/review-venue-claim?action=approve&claim_id=${encodeURIComponent(claimId)}&exp=${exp}&sig=${approveSig}`
  const rejectUrl =
    `${functionsBaseUrl.replace(/\/$/, "")}/review-venue-claim?action=reject&claim_id=${encodeURIComponent(claimId)}&exp=${exp}&sig=${rejectSig}`

  const mapsUrl = bestMapsUrlFromPayload(body)

  // Render ALL non-empty fields automatically (future fields appear without changes).
  // We treat `photo_urls` specially (thumbnail grid) and omit `sig/exp` if ever passed.
  const rows = Object.entries(body)
    .filter(([k, v]) => k !== "photo_urls" && k !== "sig" && k !== "exp" && !isEmptyValue(v))
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => {
      const label = titleizeKey(k)
      const value = stringifyValue(v)
      const lowerKey = k.toLowerCase()
      const isAddressField = [
        "address",
        "full_address",
        "street_address",
        "venue_address",
        "ownervenueaddress",
      ].includes(lowerKey)
      const valueCell = (isAddressField && mapsUrl)
        ? `
            <a href="${escapeHtml(mapsUrl)}" style="color: #0b57d0; text-decoration: none;">
              ${escapeHtml(value || "—")}
            </a>
            <div style="margin-top: 6px; font-size: 12px;">
              <a href="${escapeHtml(mapsUrl)}" style="color: #0b57d0; text-decoration: none;">
                Open in Google Maps
              </a>
            </div>
          `
        : `${escapeHtml(value || "—")}`
      return `
        <tr>
          <td style="padding: 10px 12px; border: 1px solid #eee; width: 190px; color: #666; background: #fafafa; vertical-align: top;">
            <strong>${escapeHtml(label)}</strong>
          </td>
          <td style="padding: 10px 12px; border: 1px solid #eee; color: #111; vertical-align: top; white-space: pre-wrap;">
            ${valueCell}
          </td>
        </tr>
      `
    })
    .join("")

  const photoGrid = photoUrls.length
    ? `
      <h3 style="margin: 18px 0 10px 0; font-size: 16px;">Photos</h3>
      <div style="display: flex; flex-wrap: wrap; gap: 10px;">
        ${photoUrls
          .map((u) => {
            const safe = escapeHtml(u)
            return `
              <a href="${safe}" style="text-decoration: none; border: 1px solid #eee; border-radius: 12px; overflow: hidden; display: inline-block;">
                <img src="${safe}" alt="Photo" style="display: block; width: 160px; height: 120px; object-fit: cover; background: #f2f2f2;" />
              </a>
            `
          })
          .join("")}
      </div>
      <div style="margin-top: 10px; color: #555; font-size: 12px;">
        ${photoUrls
          .map((u) => `<div><a href="${escapeHtml(u)}">${escapeHtml(u)}</a></div>`)
          .join("")}
      </div>
    `
    : ""

  const html = `
    <div style="font-family: -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif; line-height: 1.4; background: #f6f7f9; padding: 22px;">
      <div style="max-width: 860px; margin: 0 auto;">
        <div style="background: #ffffff; border: 1px solid #e7e9ee; border-radius: 18px; overflow: hidden; box-shadow: 0 12px 28px rgba(0,0,0,0.06);">
          <div style="padding: 18px 20px; border-bottom: 1px solid #eee;">
            <div style="font-size: 12px; color: #666; letter-spacing: 0.02em;">GameOn Moderation</div>
            <div style="margin-top: 4px; font-size: 20px; font-weight: 700;">Venue claim submitted</div>
            <div style="margin-top: 6px; color: #444;">
              <strong>${escapeHtml(venueName)}</strong>
              <span style="color: #666;">• ${escapeHtml(status)}</span>
              <span style="color: #666;">• ${escapeHtml(createdAt)}</span>
            </div>
          </div>

          <div style="padding: 18px 20px;">
            <div style="display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 14px;">
              <a href="${escapeHtml(approveUrl)}" style="display: inline-block; padding: 12px 16px; background: #0b7a32; color: #fff; border-radius: 12px; text-decoration: none; font-weight: 700;">
                Approve
              </a>
              <a href="${escapeHtml(rejectUrl)}" style="display: inline-block; padding: 12px 16px; background: #b42318; color: #fff; border-radius: 12px; text-decoration: none; font-weight: 700;">
                Reject
              </a>
              <div style="align-self: center; color: #666; font-size: 12px;">
                Claim ID: <code style="font-family: ui-monospace, SFMono-Regular, Menlo, monospace;">${escapeHtml(claimId)}</code>
              </div>
            </div>

            <table style="border-collapse: collapse; width: 100%; font-size: 14px;">
              ${rows || `
                <tr><td style="padding: 14px; color: #666;">No claim fields provided.</td></tr>
              `}
            </table>

            ${photoGrid}
          </div>

          <div style="padding: 14px 20px; border-top: 1px solid #eee; color: #777; font-size: 12px;">
            Sent to ${escapeHtml(adminTo)} • Owner: ${escapeHtml(ownerEmail || "—")} • Function: <code>notify-venue-claim</code>
            <div style="margin-top: 6px;">
              <span style="color: #999;">TODO:</span> Consider enforcing this workflow server-side with a DB trigger + strict RLS to prevent bypass by modified clients.
            </div>
          </div>
        </div>
      </div>
    </div>
  `

  const text = Object.entries(body)
    .filter(([k, v]) => !isEmptyValue(v))
    .map(([k, v]) => `${k}: ${stringifyValue(v)}`)
    .join("\n") +
    `\n\nApprove: ${approveUrl}\nReject: ${rejectUrl}`

  const resendResp = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${resendKey}`,
    },
    body: JSON.stringify({
      from: resendFrom,
      to: [adminTo],
      subject,
      html,
      text,
    }),
  })

  if (!resendResp.ok) {
    const errText = await resendResp.text().catch(() => "")
    return new Response(
      JSON.stringify({ ok: false, error: "resend_failed", detail: errText }),
      { status: 502, headers: { "Content-Type": "application/json" } },
    )
  }

  return new Response(JSON.stringify({ ok: true }), {
    headers: { "Content-Type": "application/json" },
  })
})

