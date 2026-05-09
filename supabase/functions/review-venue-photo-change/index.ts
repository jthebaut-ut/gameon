import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

// IMPORTANT:
// This function is invoked from clickable email links opened in a normal browser.
// Deploy with:
//   supabase functions deploy review-venue-photo-change --no-verify-jwt
//
// Authorization is handled entirely by the HMAC-signed expiring token in query params.

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
  const datePart = new Intl.DateTimeFormat("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(d)
  const timePart = new Intl.DateTimeFormat("en-US", {
    hour: "numeric",
    minute: "2-digit",
  }).format(d)
  return `${datePart} at ${timePart.replace(/\u202F/g, " ")}`
}

serve(async (req) => {
  if (req.method === "HEAD") {
    return textResponse("", 200)
  }
  if (req.method !== "GET") {
    return textResponse("Method not allowed.\n", 405)
  }

  const url = new URL(req.url)
  const actionRaw = (url.searchParams.get("action") ?? "").trim().toLowerCase()
  const venueId = (url.searchParams.get("venue_id") ?? "").trim()
  const expRaw = (url.searchParams.get("exp") ?? "").trim()
  const sig = (url.searchParams.get("sig") ?? "").trim().toLowerCase()

  const action = actionRaw === "approve" ? "approve" : actionRaw === "reject" ? "reject" : ""
  if (!action || !venueId || !expRaw || !sig) {
    return textResponse("Invalid request. Missing or invalid parameters.\n", 400)
  }

  const exp = Number(expRaw)
  if (!Number.isFinite(exp) || exp <= 0) {
    return textResponse("Invalid request. Invalid expiration timestamp.\n", 400)
  }

  const now = Math.floor(Date.now() / 1000)
  if (now > exp) {
    return textResponse("Link expired. Please request a new email.\n", 401)
  }

  const secret = Deno.env.get("MODERATION_HMAC_SECRET")
  if (!secret) {
    return textResponse("Server misconfigured. Missing moderation secret.\n", 500)
  }

  const expected = await hmacSha256Hex(secret, `${action}:${venueId}:${exp}`)
  if (!constantTimeEqual(expected, sig)) {
    return textResponse("Unauthorized. This moderation link is invalid.\n", 401)
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? Deno.env.get("PROJECT_URL")
  const serviceRole = Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRole) {
    return textResponse("Server misconfigured. Missing Supabase service configuration.\n", 500)
  }

  const admin = createClient(supabaseUrl, serviceRole)

  const { data: venueRow, error: fetchErr } = await admin
    .from("venues")
    .select("venue_name, pending_cover_photo_url, pending_menu_photo_url")
    .eq("id", venueId)
    .maybeSingle()

  if (fetchErr || !venueRow) {
    return textResponse("Update failed. Could not load venue.\n", 502)
  }

  const venueName = (venueRow.venue_name ?? "Venue").trim() || "Venue"

  if (action === "approve") {
    const nextCover = venueRow.pending_cover_photo_url ?? null
    const nextMenu = venueRow.pending_menu_photo_url ?? null

    const { error } = await admin
      .from("venues")
      .update({
        cover_photo_url: nextCover ?? undefined,
        menu_photo_url: nextMenu ?? undefined,
        pending_cover_photo_url: null,
        pending_menu_photo_url: null,
        photo_review_status: "approved",
        photo_review_created_at: null,
      })
      .eq("id", venueId)

    if (error) {
      return textResponse(`Update failed. ${error.message}\n`, 502)
    }
  } else {
    const { error } = await admin
      .from("venues")
      .update({
        pending_cover_photo_url: null,
        pending_menu_photo_url: null,
        photo_review_status: "rejected",
        photo_review_created_at: null,
      })
      .eq("id", venueId)

    if (error) {
      return textResponse(`Update failed. ${error.message}\n`, 502)
    }
  }

  const verb = action === "approve" ? "approved" : "rejected"
  const when = formatActionTimestamp(new Date())
  return textResponse(
    `${venueName} photos ${verb} on ${when}.\nYou can close this tab.\n\nVenue ID: ${venueId}\n\nThis link was secured with an expiring action token.\n`,
    200,
  )
})

