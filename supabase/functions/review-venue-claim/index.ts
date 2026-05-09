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

function textResponse(text: string, status = 200): Response {
  return new Response(text, {
    status,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
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

function plainPage(message: string, status = 200): Response {
  // Plain text response to avoid any HTML rendering quirks in email/browser clients.
  return textResponse(`${message}\n`, status)
}

serve(async (req) => {
  // Support HEAD for `curl -I` header debugging. HEAD must not perform approval/rejection mutations.
  if (req.method === "HEAD") {
    return textResponse("", 200)
  }
  if (req.method !== "GET") {
    return plainPage("Method not allowed.", 405)
  }

  const url = new URL(req.url)
  const actionRaw = (url.searchParams.get("action") ?? "").trim().toLowerCase()
  const claimId = (url.searchParams.get("claim_id") ?? "").trim()
  const expRaw = (url.searchParams.get("exp") ?? "").trim()
  const sig = (url.searchParams.get("sig") ?? "").trim().toLowerCase()

  const action = actionRaw === "approve" ? "approve" : actionRaw === "reject" ? "reject" : ""
  if (!action || !claimId || !expRaw || !sig) {
    return plainPage("Invalid request. Missing or invalid parameters.", 400)
  }

  const exp = Number(expRaw)
  if (!Number.isFinite(exp) || exp <= 0) {
    return plainPage("Invalid request. Invalid expiration timestamp.", 400)
  }

  const now = Math.floor(Date.now() / 1000)
  if (now > exp) {
    return plainPage("Link expired. This moderation link has expired. Please request a new email.", 401)
  }

  const secret = Deno.env.get("MODERATION_HMAC_SECRET")
  if (!secret) {
    return plainPage("Server misconfigured. Missing moderation secret.", 500)
  }

  const expected = await hmacSha256Hex(secret, `${action}:${claimId}:${exp}`)
  if (!constantTimeEqual(expected, sig)) {
    return plainPage("Unauthorized. This moderation link is invalid.", 401)
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? Deno.env.get("PROJECT_URL")
  const serviceRole = Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRole) {
    return plainPage("Server misconfigured. Missing Supabase service configuration.", 500)
  }

  // Service role stays server-side only.
  const admin = createClient(supabaseUrl, serviceRole)

  const approval_status = action === "approve" ? "approved" : "rejected"

  const { error } = await admin
    .from("venue_claims")
    .update({ approval_status })
    .eq("id", claimId)

  if (error) {
    return plainPage(`Update failed. Could not update venue claim. ${error.message}`, 502)
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

  return plainPage(
    `${venueName} ${verb} on ${when}.\nYou can close this tab.\n\nClaim ID: ${claimId}\n\nThis link was secured with an expiring action token.`,
    200,
  )
})

