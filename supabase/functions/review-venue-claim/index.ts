import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

// IMPORTANT DEPLOY NOTE:
// This function is invoked from clickable email links opened in a normal browser.
// It MUST be deployed with Supabase JWT verification disabled, otherwise the platform
// returns `UNAUTHORIZED_NO_AUTH_HEADER` before this code runs.
//
// Required deploy command:
//   supabase functions deploy review-venue-claim --no-verify-jwt
//
// Authorization for this endpoint is handled entirely by the HMAC-signed expiring token
// in query params (action + claim_id + exp + sig). Do not add JWT requirements here.

function escapeHtml(raw: string): string {
  return raw
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&#39;")
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

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let out = 0
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return out === 0
}

function htmlResponse(html: string, status = 200): Response {
  return new Response(html, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  })
}

function formatActionTimestamp(d: Date): string {
  // Example: May 9, 2026 at 1:52 AM
  const datePart = new Intl.DateTimeFormat("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(d)
  const timePart = new Intl.DateTimeFormat("en-US", {
    hour: "numeric",
    minute: "2-digit",
  }).format(d)
  // Some runtimes emit a narrow no-break space (U+202F) before AM/PM; normalize to a plain space.
  const normalizedTime = timePart.replace(/\u202F/g, " ")
  return `${datePart} at ${normalizedTime}`
}

function htmlPage(title: string, message: string, small?: string, status = 200): Response {
  const html = `
    <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>${escapeHtml(title)}</title>
      </head>
      <body style="margin:0; background:#f6f7f9; font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
        <div style="max-width:720px; margin:40px auto; padding:0 16px;">
          <div style="background:#fff; border:1px solid #e7e9ee; border-radius:18px; padding:18px 20px; box-shadow:0 12px 28px rgba(0,0,0,0.06);">
            <div style="font-size:12px; color:#666; letter-spacing:0.02em;">GameOn Moderation</div>
            <div style="margin-top:6px; font-size:20px; font-weight:800;">${escapeHtml(title)}</div>
            <div style="margin-top:10px; color:#333; font-size:14px; line-height:1.45;">${escapeHtml(message)}</div>
            ${
              small && small.trim().length
                ? `<div style="margin-top:10px; color:#777; font-size:12px;">${escapeHtml(small)}</div>`
                : ""
            }
          </div>
          <div style="margin-top:12px; color:#888; font-size:12px;">
            This link is secured with an expiring action token.
          </div>
        </div>
      </body>
    </html>
  `
  return htmlResponse(html, status)
}

serve(async (req) => {
  if (req.method !== "GET") {
    return htmlPage("Method not allowed", "This endpoint only supports GET requests.", undefined, 405)
  }

  const url = new URL(req.url)
  const actionRaw = (url.searchParams.get("action") ?? "").trim().toLowerCase()
  const claimId = (url.searchParams.get("claim_id") ?? "").trim()
  const expRaw = (url.searchParams.get("exp") ?? "").trim()
  const sig = (url.searchParams.get("sig") ?? "").trim().toLowerCase()

  const action = actionRaw === "approve" ? "approve" : actionRaw === "reject" ? "reject" : ""
  if (!action || !claimId || !expRaw || !sig) {
    return htmlPage("Invalid request", "Missing or invalid parameters.", undefined, 400)
  }

  const exp = Number(expRaw)
  if (!Number.isFinite(exp) || exp <= 0) {
    return htmlPage("Invalid request", "Invalid expiration timestamp.", undefined, 400)
  }

  const now = Math.floor(Date.now() / 1000)
  if (now > exp) {
    return htmlPage("Link expired", "This moderation link has expired. Please request a new email.", undefined, 401)
  }

  const secret = Deno.env.get("MODERATION_HMAC_SECRET")
  if (!secret) {
    return htmlPage("Server misconfigured", "Missing moderation secret.", undefined, 500)
  }

  const expected = await hmacSha256Hex(secret, `${action}:${claimId}:${exp}`)
  if (!constantTimeEqual(expected, sig)) {
    return htmlPage("Unauthorized", "This moderation link is invalid.", undefined, 401)
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? Deno.env.get("PROJECT_URL")
  const serviceRole = Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRole) {
    return htmlPage("Server misconfigured", "Missing Supabase service configuration.", undefined, 500)
  }

  // Service role stays server-side only.
  const admin = createClient(supabaseUrl, serviceRole)

  const approval_status = action === "approve" ? "approved" : "rejected"

  const { error } = await admin
    .from("venue_claims")
    .update({ approval_status })
    .eq("id", claimId)

  if (error) {
    return htmlPage("Update failed", `Could not update venue claim. ${error.message}`, undefined, 502)
  }

  // Fetch venue name for a clear confirmation message.
  const { data: claimRow } = await admin
    .from("venue_claims")
    .select("venue_name")
    .eq("id", claimId)
    .maybeSingle()

  const venueName = (claimRow?.venue_name ?? "Venue").trim() || "Venue"
  const when = formatActionTimestamp(new Date())
  const verb = approval_status === "approved" ? "approved" : "rejected"

  return htmlPage(
    verb === "approved" ? "Venue approved successfully" : "Venue rejected",
    `${venueName} ${verb} on ${when}`,
    `Claim ID: ${claimId}`,
    200,
  )
})

