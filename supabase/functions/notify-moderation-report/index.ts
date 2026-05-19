import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

/**
 * Admin email for DM moderation reports (user / conversation / message).
 *
 * Secrets (set via `supabase secrets set`):
 *   ADMIN_EMAIL_TO, RESEND_API_KEY, RESEND_FROM
 * Auto-provided on hosted projects:
 *   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
 *
 * Deploy: `supabase functions deploy notify-moderation-report`
 *
 * Caller JWT validates the reporter. Conversation-report emails read the bounded
 * `conversation_reports.message_snapshot` from the database (never full DM history).
 */

type ReportType = "user" | "conversation" | "message"

/** Client may send `reporter_user_id`; it is ignored — reporter is always `auth.getUser()` from the JWT. */
interface Payload {
  report_id?: string | null
  report_type: ReportType
  reported_user_id: string
  category: string
  details?: string | null
  created_at?: string | null
  conversation_id?: string | null
  message_id?: string | null
  message_text_snapshot?: string | null
  review_window_start?: string | null
  review_window_end?: string | null
  conversation_message_snapshot?: ConversationMessageSnapshot[] | null
  /** @deprecated Ignored; use JWT subject only. */
  reporter_user_id?: string | null
}

interface ConversationMessageSnapshot {
  id?: string | null
  conversation_id?: string | null
  sender_id?: string | null
  body?: string | null
  created_at?: string | null
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
const MAX_SNAPSHOT_MESSAGES = 80

interface ConversationReportRow {
  id: string
  reporter_user_id: string
  reported_user_id: string
  conversation_id: string
  category: string
  details: string | null
  review_window_start: string | null
  review_window_end: string | null
  message_snapshot: ConversationMessageSnapshot[] | null
  admin_review_consent_granted: boolean | null
  created_at: string | null
}

interface ProfileNameRow {
  id: string
  display_name: string | null
  username: string | null
}

function truncateSnapshot(s: string): string {
  const t = s.trim()
  if (t.length <= MAX_SNAPSHOT_LEN) return t
  return `${t.slice(0, MAX_SNAPSHOT_LEN)}… [truncated]`
}

function parseTimestampMs(value: string | null | undefined): number | null {
  if (!value?.trim()) return null
  const ms = Date.parse(value.trim())
  return Number.isNaN(ms) ? null : ms
}

function formatDisplayTimestamp(iso: string | null | undefined): string {
  const ms = parseTimestampMs(iso)
  if (ms == null) return "—"
  try {
    return new Date(ms).toLocaleString("en-US", {
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "numeric",
      minute: "2-digit",
      hour12: true,
    })
  } catch {
    return iso?.trim() || "—"
  }
}

function normalizeSnapshotMessages(raw: unknown): ConversationMessageSnapshot[] {
  if (!Array.isArray(raw)) return []
  return raw.filter((item): item is ConversationMessageSnapshot => {
    return item != null && typeof item === "object"
  })
}

function filterSnapshotToReviewWindow(
  messages: ConversationMessageSnapshot[],
  windowStart: string | null | undefined,
  windowEnd: string | null | undefined,
): ConversationMessageSnapshot[] {
  const startMs = parseTimestampMs(windowStart)
  const endMs = parseTimestampMs(windowEnd)
  if (startMs == null || endMs == null) return messages
  return messages.filter((m) => {
    const createdMs = parseTimestampMs(m.created_at)
    if (createdMs == null) return false
    return createdMs >= startMs && createdMs <= endMs
  })
}

function displayLabelForSender(
  senderId: string | null | undefined,
  reporterUserId: string,
  reportedUserId: string,
  nameByUserId: Map<string, string>,
): string {
  const id = (senderId ?? "").trim()
  if (!id) return "Unknown"
  const profileName = nameByUserId.get(id)
  if (profileName) return profileName
  if (id === reporterUserId) return "Reporter"
  if (id === reportedUserId) return "Reported user"
  return `User ${id.slice(0, 8)}`
}

async function fetchDisplayNames(
  admin: ReturnType<typeof createClient>,
  userIds: string[],
): Promise<Map<string, string>> {
  const unique = [...new Set(userIds.filter((id) => id.trim().length > 0))]
  const map = new Map<string, string>()
  if (unique.length === 0) return map

  const { data, error } = await admin
    .from("user_profiles")
    .select("id,display_name,username")
    .in("id", unique)

  if (error) {
    console.error("notify-moderation-report: profile name lookup failed", error.message)
    return map
  }

  for (const row of (data ?? []) as ProfileNameRow[]) {
    const display = (row.display_name ?? "").trim()
    const username = (row.username ?? "").trim()
    const label = display || (username ? `@${username}` : "")
    if (label) map.set(row.id, label)
  }
  return map
}

function renderApprovedConversationSnapshot(
  messages: ConversationMessageSnapshot[],
  reporterUserId: string,
  reportedUserId: string,
  nameByUserId: Map<string, string>,
): string {
  if (!Array.isArray(messages) || messages.length === 0) {
    return "(No messages in the user-approved review window.)"
  }

  const sorted = [...messages].sort((a, b) => {
    const aMs = parseTimestampMs(a.created_at) ?? 0
    const bMs = parseTimestampMs(b.created_at) ?? 0
    return aMs - bMs
  })

  const limited = sorted.slice(0, MAX_SNAPSHOT_MESSAGES)
  const lines: string[] = []
  for (const m of limited) {
    const ts = formatDisplayTimestamp(m.created_at)
    const sender = displayLabelForSender(m.sender_id, reporterUserId, reportedUserId, nameByUserId)
    const body = (m.body ?? "")
      .replace(/\r\n/g, "\n")
      .replace(/\r/g, "\n")
      .trim() || "(empty message)"
    lines.push(`[${ts}]\n${sender}:\n${body}`)
  }
  if (sorted.length > MAX_SNAPSHOT_MESSAGES) {
    lines.push(`… [${sorted.length - MAX_SNAPSHOT_MESSAGES} additional message(s) omitted for length]`)
  }
  return lines.join("\n\n")
}

async function loadConversationReportSnapshot(
  admin: ReturnType<typeof createClient>,
  reportId: string,
  reporterUserId: string,
): Promise<ConversationReportRow | null> {
  const { data, error } = await admin
    .from("conversation_reports")
    .select(
      "id,reporter_user_id,reported_user_id,conversation_id,category,details,review_window_start,review_window_end,message_snapshot,admin_review_consent_granted,created_at",
    )
    .eq("id", reportId)
    .eq("reporter_user_id", reporterUserId)
    .eq("admin_review_consent_granted", true)
    .maybeSingle()

  if (error) {
    console.error("notify-moderation-report: conversation_reports load failed", error.message)
    return null
  }
  return data as ConversationReportRow | null
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
    if (!payload.report_id?.trim()) {
      return new Response(JSON.stringify({ error: "report_id_required" }), {
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

  const reportIdLine = payload.report_id?.trim()
    ? `<p style="margin:8px 0"><strong>Report ID:</strong> ${escapeHtml(payload.report_id!.trim())}</p>`
    : ""

  const msgLine = payload.message_id?.trim()
    ? `<p style="margin:8px 0"><strong>Message ID:</strong> ${escapeHtml(payload.message_id!.trim())}</p>`
    : ""

  let windowStart = (payload.review_window_start ?? "").trim()
  let windowEnd = (payload.review_window_end ?? "").trim()
  let conversationContextSection = ""

  if (payload.report_type === "conversation") {
    const reportId = payload.report_id!.trim()
    let snapshotMessages: ConversationMessageSnapshot[] = []
    let reporterUserId = user.id
    let reportedUserId = payload.reported_user_id.trim()

    const admin = serviceRoleKey ? createClient(supabaseUrl, serviceRoleKey) : null

    if (admin) {
      const reportRow = await loadConversationReportSnapshot(admin, reportId, user.id)
      if (reportRow) {
        windowStart = (reportRow.review_window_start ?? windowStart).trim()
        windowEnd = (reportRow.review_window_end ?? windowEnd).trim()
        reporterUserId = reportRow.reporter_user_id
        reportedUserId = reportRow.reported_user_id
        const rawSnapshot = normalizeSnapshotMessages(reportRow.message_snapshot)
        snapshotMessages = filterSnapshotToReviewWindow(rawSnapshot, windowStart, windowEnd)
        console.log(
          `[PrivateReportEmail] report_id=${reportId} snapshot_total=${rawSnapshot.length} snapshot_in_window=${snapshotMessages.length}`,
        )
      } else {
        console.error(
          `notify-moderation-report: missing conversation_reports row report_id=${reportId} reporter=${user.id}`,
        )
      }
    } else {
      console.error("notify-moderation-report: SUPABASE_SERVICE_ROLE_KEY unset — cannot load message_snapshot from DB")
      snapshotMessages = filterSnapshotToReviewWindow(
        normalizeSnapshotMessages(payload.conversation_message_snapshot),
        windowStart,
        windowEnd,
      )
    }

    const nameIds = [
      reporterUserId,
      reportedUserId,
      ...snapshotMessages.map((m) => (m.sender_id ?? "").trim()).filter(Boolean),
    ]
    const nameByUserId = admin ? await fetchDisplayNames(admin, nameIds) : new Map<string, string>()

    const rendered = renderApprovedConversationSnapshot(
      snapshotMessages,
      reporterUserId,
      reportedUserId,
      nameByUserId,
    )
    const bounded = rendered.length > MAX_CONVERSATION_CONTEXT_LEN
      ? `${rendered.slice(0, MAX_CONVERSATION_CONTEXT_LEN)}… [truncated]`
      : rendered

    const windowFromDisplay = formatDisplayTimestamp(windowStart)
    const windowToDisplay = formatDisplayTimestamp(windowEnd)

    conversationContextSection =
      `<p style="margin:18px 0 6px;font-size:14px"><strong>Conversation review window:</strong></p>` +
      `<p style="margin:0 0 4px;font-size:14px">From: ${escapeHtml(windowFromDisplay)}</p>` +
      `<p style="margin:0 0 10px;font-size:14px">To: ${escapeHtml(windowToDisplay)}</p>` +
      `<p style="margin:0 0 8px;font-size:13px;color:#475569">Only messages included in the user-approved review window are shown.</p>` +
      `<p style="margin:14px 0 8px;font-size:14px"><strong>Approved conversation snapshot:</strong></p>` +
      `<p style="margin:0;font-size:13px;white-space:pre-wrap;background:#f8fafc;padding:12px 14px;border-radius:10px;border:1px solid #e2e8f0;font-family:ui-monospace,monospace">${
        escapeHtml(bounded)
      }</p>`
  }

  const reviewWindowSection = ""

  const adminReviewBaseUrl = Deno.env.get("ADMIN_REPORT_REVIEW_BASE_URL")?.trim() ?? ""
  const reportReviewLink = adminReviewBaseUrl && payload.report_id?.trim()
    ? `${adminReviewBaseUrl.replace(/\/+$/, "")}/${encodeURIComponent(payload.report_id.trim())}`
    : ""
  const reportReviewLinkLine = reportReviewLink
    ? `<p style="margin:8px 0"><strong>Admin review:</strong> <a href="${escapeHtml(reportReviewLink)}">${escapeHtml(reportReviewLink)}</a></p>`
    : ""

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
  ${reportIdLine}
  ${convLine}
  ${msgLine}
  ${reviewWindowSection}
  ${reportReviewLinkLine}
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
