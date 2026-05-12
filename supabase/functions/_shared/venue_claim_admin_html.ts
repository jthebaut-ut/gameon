/**
 * Branded HTML pages for venue-claim admin approval links (browser GET responses).
 */

export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

function wrapPage(inner: string, accent: string, title: string): string {
  const escTitle = escapeHtml(title)
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>${escTitle} - FanGeo</title>
<style>
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 24px 16px;
    font-family: system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    line-height: 1.5;
    color: #0f172a;
    background: #f1f5f9;
  }
  .card {
    width: 100%;
    max-width: 440px;
    background: #ffffff;
    border-radius: 16px;
    box-shadow: 0 10px 40px rgba(15, 23, 42, 0.08), 0 2px 8px rgba(15, 23, 42, 0.06);
    padding: 28px 26px 26px;
    border-top: 4px solid ${accent};
  }
  .brand {
    font-size: 13px;
    font-weight: 700;
    letter-spacing: 0.04em;
    color: #64748b;
    text-transform: uppercase;
    margin-bottom: 14px;
  }
  h1 {
    font-size: 22px;
    font-weight: 700;
    margin: 0 0 12px;
    color: #0f172a;
  }
  .meta {
    font-size: 14px;
    color: #475569;
    margin: 10px 0;
  }
  .meta strong { color: #0f172a; }
  .msg {
    font-size: 15px;
    color: #334155;
    margin: 18px 0 12px;
  }
  .fine {
    font-size: 13px;
    color: #64748b;
    margin-top: 20px;
  }
</style>
</head>
<body>
${inner}
</body>
</html>`
}

/** Every browser HTML page from claim approve/reject/fail must send this so clients render markup (not plain text). */
function htmlPageResponseHeaders(): Headers {
  const h = new Headers()
  h.set("Content-Type", "text/html; charset=utf-8")
  h.set("Cache-Control", "no-store")
  return h
}

export function htmlResponse(html: string, status = 200): Response {
  return new Response(html, {
    status,
    headers: htmlPageResponseHeaders(),
  })
}

export function pageApproved(opts: {
  venueName: string
  claimId: string
  venueId: string
  timestamp: string
  ownerEmail: string
  businessId: string | null
  businessDisplayName: string | null
}): string {
  const venue = escapeHtml(opts.venueName)
  const cid = escapeHtml(opts.claimId)
  const vid = escapeHtml(opts.venueId)
  const ts = escapeHtml(opts.timestamp)
  const owner = escapeHtml(opts.ownerEmail)
  const name = opts.businessDisplayName?.trim()
  const bid = opts.businessId?.trim()
  const businessLine =
    name && name.length > 0
      ? escapeHtml(name)
      : bid && bid.length > 0
        ? escapeHtml(bid)
        : "-"

  const inner = `<div class="card">
  <div class="brand">FanGeo</div>
  <h1 style="color:#15803d">Venue approved</h1>
  <p class="meta"><strong>Approved venue</strong><br/>${venue}</p>
  <p class="meta"><strong>Business</strong><br/>${businessLine}</p>
  <p class="meta"><strong>Business owner</strong><br/>${owner}</p>
  <p class="meta"><strong>Approved on</strong><br/>${ts}</p>
  <p class="meta"><strong>Claim ID</strong><br/><span style="font-size:13px;word-break:break-all">${cid}</span></p>
  <p class="meta"><strong>Venue ID</strong><br/><span style="font-size:13px;word-break:break-all">${vid}</span></p>
  <p class="msg">This venue is now linked to the business account and can be managed in FanGeo.</p>
  <p class="fine">You may now close this tab.</p>
</div>`
  return wrapPage(inner, "#22c55e", "Venue approved")
}

export function pageRejected(opts: {
  venueName: string
  claimId: string
  timestamp: string
}): string {
  const venue = escapeHtml(opts.venueName)
  const cid = escapeHtml(opts.claimId)
  const ts = escapeHtml(opts.timestamp)
  const inner = `<div class="card">
  <div class="brand">FanGeo</div>
  <h1 style="color:#b91c1c">Location request rejected</h1>
  <p class="meta"><strong>Venue</strong><br/>${venue}</p>
  <p class="meta"><strong>Time</strong><br/>${ts}</p>
  <p class="meta"><strong>Claim ID</strong><br/><span style="font-size:13px;word-break:break-all">${cid}</span></p>
</div>`
  return wrapPage(inner, "#ef4444", "Location rejected")
}

/** Shared explanation text for expired + invalid token routes (spec §5). */
const expiredInvalidExplanation =
  "<p class=\"msg\">This approval link has expired or is invalid.</p>"

export function pageExpiredToken(): string {
  const inner = `<div class="card">
  <div class="brand">FanGeo</div>
  <h1 style="color:#c2410c">Link expired</h1>
  ${expiredInvalidExplanation}
  <p class="fine">If you still need to review this request, open the latest admin email or use your FanGeo admin tools.</p>
</div>`
  return wrapPage(inner, "#f97316", "Link expired")
}

export function pageInvalidToken(): string {
  const inner = `<div class="card">
  <div class="brand">FanGeo</div>
  <h1 style="color:#c2410c">Invalid link</h1>
  ${expiredInvalidExplanation}
  <p class="fine">If you still need to review this request, open the latest admin email or use your FanGeo admin tools.</p>
</div>`
  return wrapPage(inner, "#f97316", "Invalid link")
}

/** Legacy single-page variant (both titles folded into one). */
export function pageExpiredOrInvalid(): string {
  const inner = `<div class="card">
  <div class="brand">FanGeo</div>
  <h1 style="color:#c2410c">Link not usable</h1>
  ${expiredInvalidExplanation}
  <p class="fine">If you still need to review this request, open the latest admin email or use your FanGeo admin tools.</p>
</div>`
  return wrapPage(inner, "#f97316", "Link not usable")
}

export function pageAlreadyProcessed(opts: {
  venueName: string
  claimId: string
  statusLabel: string
}): string {
  const venue = escapeHtml(opts.venueName)
  const cid = escapeHtml(opts.claimId)
  const st = escapeHtml(opts.statusLabel)
  const inner = `<div class="card">
  <div class="brand">FanGeo</div>
  <h1 style="color:#0f172a">Already reviewed</h1>
  <p class="msg">This claim was already processed (${st}).</p>
  <p class="meta"><strong>Venue</strong><br/>${venue}</p>
  <p class="meta"><strong>Claim ID</strong><br/><span style="font-size:13px;word-break:break-all">${cid}</span></p>
  <p class="fine">You may now close this tab.</p>
</div>`
  return wrapPage(inner, "#64748b", "Already reviewed")
}

/** Venue insert/update or DB verification failed — do not show “approved” success. */
export function pageVenueApprovalFailed(opts: { claimId: string; code: string; detail?: string }): string {
  const cid = escapeHtml(opts.claimId)
  const code = escapeHtml(opts.code)
  const detail = opts.detail ? escapeHtml(opts.detail) : ""
  const inner = `<div class="card">
  <div class="brand">FanGeo</div>
  <h1 style="color:#b91c1c">Approval could not finish</h1>
  <p class="msg">The claim was <strong>not</strong> marked complete because a <code>public.venues</code> row could not be created or linked. Check Edge Function logs.</p>
  <p class="meta"><strong>Claim ID</strong><br/><span style="font-size:13px;word-break:break-all">${cid}</span></p>
  <p class="meta"><strong>Error code</strong><br/>${code}</p>
  ${detail ? `<p class="meta"><strong>Detail</strong><br/><span style="font-size:13px;word-break:break-all">${detail}</span></p>` : ""}
  <p class="fine">SQL check after a successful approve: <code>venue_claims.venue_id</code> must be NOT NULL and must reference an existing <code>public.venues.id</code>.</p>
</div>`
  return wrapPage(inner, "#ef4444", "Approval failed")
}
