import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

type Payload = {
  venue_name?: string
  owner_email?: string
  address?: string
  phone?: string
  website?: string
  description?: string
  photo_urls?: string[]
  created_at?: string
  approval_status?: string
}

function escapeHtml(raw: string): string {
  return raw
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&#39;")
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

  let body: Payload
  try {
    body = await req.json()
  } catch {
    return new Response(JSON.stringify({ error: "invalid_json" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    })
  }

  const adminTo = Deno.env.get("ADMIN_EMAIL_TO")
  const resendKey = Deno.env.get("RESEND_API_KEY")
  const resendFrom = Deno.env.get("RESEND_FROM") ?? "GameOn <onboarding@resend.dev>"
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

  const venueName = (body.venue_name ?? "Venue").trim()
  const ownerEmail = (body.owner_email ?? userData.user.email ?? "").trim()
  const createdAt = (body.created_at ?? new Date().toISOString()).trim()
  const status = (body.approval_status ?? "pending").trim().toLowerCase()

  const photoUrls = Array.isArray(body.photo_urls) ? body.photo_urls.filter(Boolean) : []

  const subject = `GameOn venue claim: ${venueName} (${status})`

  const lines: Array<[string, string]> = [
    ["Venue", venueName],
    ["Owner email", ownerEmail || "—"],
    ["Status", status],
    ["Submitted", createdAt],
    ["Address", (body.address ?? "").trim() || "—"],
    ["Phone", (body.phone ?? "").trim() || "—"],
    ["Website", (body.website ?? "").trim() || "—"],
    ["Description", (body.description ?? "").trim() || "—"],
  ]

  const html = `
    <div style="font-family: -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif; line-height: 1.4;">
      <h2 style="margin: 0 0 12px 0;">New venue claim submitted</h2>
      <p style="margin: 0 0 16px 0; color: #444;">
        A venue owner submitted a claim that needs review.
      </p>
      <table style="border-collapse: collapse; width: 100%; max-width: 720px;">
        ${lines
          .map(([k, v]) => {
            return `
              <tr>
                <td style="padding: 8px 10px; border: 1px solid #eee; width: 180px; color: #666;"><strong>${escapeHtml(
                  k,
                )}</strong></td>
                <td style="padding: 8px 10px; border: 1px solid #eee; color: #111;">${escapeHtml(
                  v,
                )}</td>
              </tr>
            `
          })
          .join("")}
      </table>
      ${
        photoUrls.length
          ? `
            <h3 style="margin: 18px 0 8px 0;">Photo URLs</h3>
            <ul style="margin: 0; padding-left: 18px;">
              ${photoUrls
                .map((u) => `<li><a href="${escapeHtml(u)}">${escapeHtml(u)}</a></li>`)
                .join("")}
            </ul>
          `
          : ""
      }
      <p style="margin-top: 18px; color: #777; font-size: 12px;">
        This email was sent by the <code>notify-venue-claim</code> Edge Function.
      </p>
    </div>
  `

  const text = lines.map(([k, v]) => `${k}: ${v}`).join("\n") +
    (photoUrls.length ? `\n\nPhoto URLs:\n${photoUrls.join("\n")}` : "") +
    `\n\nSent by notify-venue-claim Edge Function.`

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

