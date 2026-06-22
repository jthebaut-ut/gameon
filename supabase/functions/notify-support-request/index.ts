import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

/**
 * Sends support/contact emails to ADMIN_EMAIL_TO via Resend.
 *
 * Secrets: ADMIN_EMAIL_TO, RESEND_API_KEY, RESEND_FROM
 * Deploy: `supabase functions deploy notify-support-request`
 *
 * Caller identity (user id + email) comes from JWT (`auth.getUser()`), not the request body.
 */

interface Payload {
  category: string
  subject: string
  message: string
  app_version?: string | null
  client_timestamp?: string | null
}

const ALLOWED_CATEGORIES = new Set([
  "bug_report",
  "question",
  "feature_request",
  "account_issue",
  "business_support",
  "other",
])

const MAX_SUBJECT = 200
const MAX_MESSAGE = 1000

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

/** Lightweight blocklist aligned with app client checks (subset). */
function bodyLooksBlocked(s: string): boolean {
  const collapsed = s
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/0/g, "o")
    .replace(/1/g, "i")
    .replace(/3/g, "e")
    .replace(/4/g, "a")
    .replace(/5/g, "s")
    .replace(/7/g, "t")
    .replace(/8/g, "b")
    .replace(/\$/g, "s")
    .replace(/@/g, "a")
    .replace(/!/g, "i")
    .replace(/\+/g, "t")
  const letters = collapsed.replace(/[^a-z0-9]+/g, "")
  const blocked = [
    "fuck",
    "shit",
    "bitch",
    "bastard",
    "asshole",
    "motherfucker",
    "bullshit",
    "faggot",
    "nigger",
    "nigga",
    "spic",
    "chink",
    "kike",
    "wetback",
    "retard",
  ]
  for (const w of blocked) {
    if (letters.includes(w)) return true
  }
  return false
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
    console.error("notify-support-request: missing SUPABASE_URL or SUPABASE_ANON_KEY")
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

  const cat = (payload.category ?? "").trim()
  if (!ALLOWED_CATEGORIES.has(cat)) {
    return new Response(JSON.stringify({ error: "invalid_category" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  const subject = (payload.subject ?? "").trim()
  const message = (payload.message ?? "").trim()
  if (!subject || !message) {
    return new Response(JSON.stringify({ error: "missing_fields" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }
  if (subject.length > MAX_SUBJECT || message.length > MAX_MESSAGE) {
    return new Response(JSON.stringify({ error: "payload_too_large" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  if (bodyLooksBlocked(message) || bodyLooksBlocked(subject)) {
    return new Response(JSON.stringify({ error: "prohibited_content" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  const adminTo = Deno.env.get("ADMIN_EMAIL_TO")?.trim()
  const resendKey = Deno.env.get("RESEND_API_KEY")?.trim()
  const resendFrom = Deno.env.get("RESEND_FROM")?.trim()
  if (!adminTo || !resendKey || !resendFrom) {
    console.error("notify-support-request: missing ADMIN_EMAIL_TO, RESEND_API_KEY, or RESEND_FROM")
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  const reporterEmail = user.email?.trim() || ""
  const reporterEmailLine = reporterEmail.length > 0 ? reporterEmail : "(not on file)"
  const ts = (payload.client_timestamp?.trim() || new Date().toISOString())
  const appVer = (payload.app_version ?? "").trim() || "—"

  const html = `<!DOCTYPE html>
<html>
<body style="font-family:system-ui,-apple-system,sans-serif;line-height:1.55;color:#1a1a1a;max-width:640px">
  <h1 style="font-size:20px;font-weight:650;margin:0 0 18px;color:#0f172a">FanGeo support request</h1>
  <p style="margin:10px 0;font-size:15px">A signed-in user submitted a support message from the app.</p>
  <hr style="border:none;border-top:1px solid #e2e8f0;margin:18px 0"/>
  <table style="font-size:14px;border-collapse:collapse;width:100%">
    <tr><td style="padding:6px 0;vertical-align:top;width:160px"><strong>User ID</strong></td><td style="padding:6px 0">${escapeHtml(user.id)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>User email</strong></td><td style="padding:6px 0">${escapeHtml(reporterEmailLine)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Category</strong></td><td style="padding:6px 0">${escapeHtml(cat)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Subject</strong></td><td style="padding:6px 0">${escapeHtml(subject)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Timestamp</strong></td><td style="padding:6px 0">${escapeHtml(ts)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>App version</strong></td><td style="padding:6px 0">${escapeHtml(appVer)}</td></tr>
  </table>
  <p style="margin:14px 0 8px;font-size:14px"><strong>Message</strong></p>
  <p style="margin:0;font-size:14px;white-space:pre-wrap;background:#f8fafc;padding:12px 14px;border-radius:10px;border:1px solid #e2e8f0">${escapeHtml(message)}</p>
  <p style="margin-top:22px;font-size:12px;color:#64748b">Generated by FanGeo notify-support-request.</p>
</body>
</html>`

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: resendFrom,
      to: [adminTo],
      subject: `FanGeo support — ${cat} — ${subject.slice(0, 80)}${subject.length > 80 ? "…" : ""}`,
      html,
    }),
  })

  if (!res.ok) {
    const errText = await res.text()
    console.error("notify-support-request: Resend error", res.status, errText)
    return new Response(
      JSON.stringify({ ok: false, error: "email_send_failed" }),
      { status: 502, headers: { "Content-Type": "application/json" } },
    )
  }

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  })
})
