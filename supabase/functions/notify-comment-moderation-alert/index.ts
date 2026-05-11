import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

/**
 * Sends a one-time Resend email when a venue-event comment hits the report threshold and is auto-hidden.
 *
 * Secrets (Supabase project / `supabase secrets set`):
 *   ADMIN_EMAIL_TO, RESEND_API_KEY, RESEND_FROM
 * Auto-provided on hosted projects:
 *   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
 *
 * Deploy: `supabase functions deploy notify-comment-moderation-alert`
 *
 * Caller must send a valid user JWT (Authorization: Bearer). Database reads/writes use the service role.
 */

interface Payload {
  comment_id: string
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

const MAX_COMMENT_LEN = 8000

function truncateText(s: string): string {
  const t = s.trim()
  if (t.length <= MAX_COMMENT_LEN) return t
  return `${t.slice(0, MAX_COMMENT_LEN)}… [truncated]`
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
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""

  if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey) {
    console.error("notify-comment-moderation-alert: missing SUPABASE_URL, SUPABASE_ANON_KEY, or SUPABASE_SERVICE_ROLE_KEY")
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  const userClient = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  })

  const { data: { user }, error: authErr } = await userClient.auth.getUser()
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

  const commentId = payload.comment_id?.trim()
  if (!commentId) {
    return new Response(JSON.stringify({ error: "missing_comment_id" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  const admin = createClient(supabaseUrl, serviceRoleKey)

  const adminTo = Deno.env.get("ADMIN_EMAIL_TO")?.trim()
  const resendKey = Deno.env.get("RESEND_API_KEY")?.trim()
  const resendFrom = Deno.env.get("RESEND_FROM")?.trim()
  if (!adminTo || !resendKey || !resendFrom) {
    console.error("notify-comment-moderation-alert: missing ADMIN_EMAIL_TO, RESEND_API_KEY, or RESEND_FROM")
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  const nowIso = new Date().toISOString()

  const { data: claimed, error: claimErr } = await admin
    .from("venue_event_comments")
    .update({ moderation_alert_sent_at: nowIso })
    .eq("id", commentId)
    .is("moderation_alert_sent_at", null)
    .gte("moderation_report_count", 3)
    .eq("is_moderation_hidden", true)
    .select(
      "id,comment,user_email,venue_event_id,moderation_report_count,moderation_last_reported_at,moderation_alert_sent_at,is_moderation_hidden",
    )
    .maybeSingle()

  if (claimErr) {
    console.error("notify-comment-moderation-alert: claim update failed", claimErr)
    return new Response(JSON.stringify({ ok: false, error: "claim_failed" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  if (!claimed) {
    return new Response(JSON.stringify({ ok: true, skipped: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    })
  }

  const venueEventId = claimed.venue_event_id as string | null
  let venueName = "—"
  let eventTitle = "—"
  if (venueEventId) {
    const { data: ev } = await admin
      .from("venue_events")
      .select("venue_name,event_title")
      .eq("id", venueEventId)
      .maybeSingle()
    if (ev) {
      venueName = (ev.venue_name as string | null)?.trim() || venueName
      eventTitle = (ev.event_title as string | null)?.trim() || eventTitle
    }
  }

  const { data: reportRows } = await admin
    .from("comment_reports")
    .select("reporter_email,created_at")
    .eq("comment_id", commentId)
    .order("created_at", { ascending: true })

  const reporterLines: string[] = []
  if (reportRows && reportRows.length > 0) {
    for (const r of reportRows) {
      const em = (r.reporter_email as string | null)?.trim() || "(unknown)"
      const at = (r.created_at as string | null)?.trim() || ""
      reporterLines.push(`${escapeHtml(em)} @ ${escapeHtml(at)}`)
    }
  } else {
    reporterLines.push("(no report rows)")
  }

  const commentText = truncateText((claimed.comment as string | null) ?? "")
  const authorEmail = (claimed.user_email as string | null)?.trim() || "—"
  const reportCount = String(
    typeof claimed.moderation_report_count === "number" ? claimed.moderation_report_count : "—",
  )
  const lastReported = (claimed.moderation_last_reported_at as string | null)?.trim() || nowIso

  const html = `<!DOCTYPE html>
<html>
<body style="font-family:system-ui,-apple-system,sans-serif;line-height:1.55;color:#1a1a1a;max-width:720px">
  <h1 style="font-size:20px;font-weight:650;margin:0 0 18px;color:#0f172a">[GameOn Moderation] Comment Auto-Hidden</h1>
  <p style="margin:10px 0 16px;font-size:15px">This comment was automatically hidden after reaching the report threshold.</p>
  <hr style="border:none;border-top:1px solid #e2e8f0;margin:18px 0"/>
  <table style="font-size:14px;border-collapse:collapse;width:100%">
    <tr><td style="padding:6px 0;vertical-align:top;width:200px"><strong>Comment ID</strong></td><td style="padding:6px 0">${escapeHtml(commentId)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Event ID</strong></td><td style="padding:6px 0">${escapeHtml(venueEventId ?? "—")}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Venue name</strong></td><td style="padding:6px 0">${escapeHtml(venueName)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Game / event title</strong></td><td style="padding:6px 0">${escapeHtml(eventTitle)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Report count</strong></td><td style="padding:6px 0">${escapeHtml(reportCount)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Comment author (email on row)</strong></td><td style="padding:6px 0">${escapeHtml(authorEmail)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Last reported at</strong></td><td style="padding:6px 0">${escapeHtml(lastReported)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Alert timestamp</strong></td><td style="padding:6px 0">${escapeHtml(nowIso)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Invoker user ID</strong></td><td style="padding:6px 0">${escapeHtml(user.id)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Invoker email</strong></td><td style="padding:6px 0">${escapeHtml(user.email?.trim() || "(not on file)")}</td></tr>
  </table>
  <p style="margin:16px 0 8px;font-size:14px"><strong>Comment text</strong></p>
  <p style="margin:0;font-size:14px;white-space:pre-wrap;background:#f8fafc;padding:12px 14px;border-radius:10px;border:1px solid #e2e8f0">${escapeHtml(commentText.length > 0 ? commentText : "(empty)")}</p>
  <p style="margin:16px 0 8px;font-size:14px"><strong>Reporters (email, time)</strong></p>
  <ul style="margin:0;padding-left:20px;font-size:14px">
    ${reporterLines.map((line) => `<li style="margin:6px 0">${line}</li>`).join("")}
  </ul>
  <p style="margin-top:22px;font-size:12px;color:#64748b">This message was generated by the GameOn moderation notification service.</p>
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
      subject: "[GameOn Moderation] Comment Auto-Hidden",
      html,
    }),
  })

  if (!res.ok) {
    const errText = await res.text()
    console.error("notify-comment-moderation-alert: Resend error", res.status, errText)
    await admin
      .from("venue_event_comments")
      .update({ moderation_alert_sent_at: null })
      .eq("id", commentId)
      .eq("moderation_alert_sent_at", nowIso)
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
