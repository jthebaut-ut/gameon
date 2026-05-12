import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

/**
 * Admin email for DM moderation reports (user / conversation / message).
 *
 * Secrets (set via `supabase secrets set`):
 *   ADMIN_EMAIL_TO, RESEND_API_KEY, RESEND_FROM
 *
 * Deploy: `supabase functions deploy notify-moderation-report`
 *
 * Uses anon key + caller JWT only (no service role).
 * Reporter identity in the email always comes from `auth.getUser()` (JWT), not the request body.
 */

type ReportType = "user" | "conversation" | "message"

/** Client may send `reporter_user_id`; it is ignored — reporter is always `auth.getUser()` from the JWT. */
interface Payload {
  report_type: ReportType
  reported_user_id: string
  category: string
  details?: string | null
  created_at?: string | null
  conversation_id?: string | null
  message_id?: string | null
  message_text_snapshot?: string | null
  /** Admin email only: bounded recent DM lines for `conversation` reports (not persisted on row). */
  conversation_recent_context?: string | null
  /** @deprecated Ignored; use JWT subject only. */
  reporter_user_id?: string | null
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

const MAX_SNAPSHOT_LEN = 4000
const MAX_CONVERSATION_CONTEXT_LEN = 12000

function truncateSnapshot(s: string): string {
  const t = s.trim()
  if (t.length <= MAX_SNAPSHOT_LEN) return t
  return `${t.slice(0, MAX_SNAPSHOT_LEN)}… [truncated]`
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
    console.error("notify-moderation-report: missing SUPABASE_URL or SUPABASE_ANON_KEY")
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

  const validTypes: ReportType[] = ["user", "conversation", "message"]
  if (!payload.report_type || !validTypes.includes(payload.report_type)) {
    return new Response(JSON.stringify({ error: "invalid_report_type" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  if (!payload.reported_user_id?.trim() || !payload.category?.trim()) {
    return new Response(JSON.stringify({ error: "missing_fields" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  if (payload.report_type === "conversation") {
    const cid = payload.conversation_id?.trim()
    if (!cid) {
      return new Response(JSON.stringify({ error: "conversation_id_required" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      })
    }
  }

  if (payload.report_type === "message") {
    const mid = payload.message_id?.trim()
    if (!mid) {
      return new Response(JSON.stringify({ error: "message_id_required" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      })
    }
  }

  const adminTo = Deno.env.get("ADMIN_EMAIL_TO")?.trim()
  const resendKey = Deno.env.get("RESEND_API_KEY")?.trim()
  const resendFrom = Deno.env.get("RESEND_FROM")?.trim()
  if (!adminTo || !resendKey || !resendFrom) {
    console.error("notify-moderation-report: missing ADMIN_EMAIL_TO, RESEND_API_KEY, or RESEND_FROM")
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    })
  }

  const createdAt = (payload.created_at?.trim() || new Date().toISOString())
  const reporterEmail = user.email?.trim() || ""
  const reporterEmailLine = reporterEmail.length > 0 ? reporterEmail : "(not on file)"

  const detailsRaw = (payload.details ?? "").trim()
  const detailsLine = detailsRaw.length > 0 ? detailsRaw : "—"

  let snapshotSection = ""
  if (payload.report_type === "message") {
    const snap = truncateSnapshot((payload.message_text_snapshot ?? "").trim())
    const snapDisplay = snap.length > 0 ? snap : "(empty message)"
    snapshotSection = `<p style="margin:8px 0"><strong>Message text (snapshot):</strong><br/><span style="white-space:pre-wrap">${escapeHtml(snapDisplay)}</span></p>`
  }

  const convLine = payload.conversation_id?.trim()
    ? `<p style="margin:8px 0"><strong>Conversation ID:</strong> ${escapeHtml(payload.conversation_id!.trim())}</p>`
    : ""

  const msgLine = payload.message_id?.trim()
    ? `<p style="margin:8px 0"><strong>Message ID:</strong> ${escapeHtml(payload.message_id!.trim())}</p>`
    : ""

  let conversationContextSection = ""
  if (payload.report_type === "conversation") {
    const rawCtx = (payload.conversation_recent_context ?? "").trim()
    if (rawCtx.length > 0) {
      const bounded = rawCtx.length > MAX_CONVERSATION_CONTEXT_LEN
        ? `${rawCtx.slice(0, MAX_CONVERSATION_CONTEXT_LEN)}… [truncated]`
        : rawCtx
      conversationContextSection =
        `<p style="margin:14px 0 8px;font-size:14px"><strong>Recent messages (moderator context)</strong></p>` +
        `<p style="margin:0;font-size:13px;white-space:pre-wrap;background:#0f172a0a;padding:12px 14px;border-radius:10px;border:1px solid #e2e8f0;font-family:ui-monospace,monospace">${
          escapeHtml(bounded)
        }</p>`
    }
  }

  const html = `<!DOCTYPE html>
<html>
<body style="font-family:system-ui,-apple-system,sans-serif;line-height:1.55;color:#1a1a1a;max-width:640px">
  <h1 style="font-size:20px;font-weight:650;margin:0 0 18px;color:#0f172a">FanGeo moderation report</h1>
  <p style="margin:10px 0;font-size:15px">A user submitted a report that needs manual review.</p>
  <hr style="border:none;border-top:1px solid #e2e8f0;margin:18px 0"/>
  <table style="font-size:14px;border-collapse:collapse;width:100%">
    <tr><td style="padding:6px 0;vertical-align:top;width:160px"><strong>Report type</strong></td><td style="padding:6px 0">${escapeHtml(payload.report_type)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Category</strong></td><td style="padding:6px 0">${escapeHtml(payload.category.trim())}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Created at</strong></td><td style="padding:6px 0">${escapeHtml(createdAt)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Reporter user ID</strong></td><td style="padding:6px 0">${escapeHtml(user.id)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Reporter email</strong></td><td style="padding:6px 0">${escapeHtml(reporterEmailLine)}</td></tr>
    <tr><td style="padding:6px 0;vertical-align:top"><strong>Reported user ID</strong></td><td style="padding:6px 0">${escapeHtml(payload.reported_user_id.trim())}</td></tr>
  </table>
  <p style="margin:14px 0 8px;font-size:14px"><strong>Details</strong></p>
  <p style="margin:0;font-size:14px;white-space:pre-wrap;background:#f8fafc;padding:12px 14px;border-radius:10px;border:1px solid #e2e8f0">${escapeHtml(detailsLine)}</p>
  ${convLine}
  ${msgLine}
  ${snapshotSection}
  ${conversationContextSection}
  <p style="margin-top:22px;font-size:12px;color:#64748b">This message was generated by the FanGeo moderation notification service.</p>
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
      subject: `FanGeo moderation report — ${payload.report_type}`,
      html,
    }),
  })

  if (!res.ok) {
    const errText = await res.text()
    console.error("notify-moderation-report: Resend error", res.status, errText)
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
