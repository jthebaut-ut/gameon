import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

const JOB_LOG_PREFIX = "[ExpiredCleanupJob]"
const CLEANUP_LIMIT = 500

Deno.serve(async (req) => {
  const startedAt = Date.now()
  console.log(`${JOB_LOG_PREFIX} started`)

  if (req.method !== "POST") {
    return json({ success: false, error: "method_not_allowed" }, 405, startedAt)
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ??
    Deno.env.get("PROJECT_URL") ??
    ""
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
    Deno.env.get("SERVICE_ROLE_KEY") ??
    ""
  if (!supabaseUrl || !serviceRoleKey) {
    const error = "server_misconfigured"
    console.error(`${JOB_LOG_PREFIX} error`, error)
    return json({ success: false, error }, 500, startedAt)
  }

  const bearerToken = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "").trim()
  if (bearerToken !== serviceRoleKey) {
    const error = "unauthorized"
    console.error(`${JOB_LOG_PREFIX} error`, error)
    return json({ success: false, error }, 401, startedAt)
  }

  try {
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
      },
    })

    const { data, error } = await admin.rpc("cleanup_expired_game_social_phase2", {
      p_now: new Date().toISOString(),
      p_limit: CLEANUP_LIMIT,
      p_dry_run: false,
    })

    if (error) throw error

    const body = {
      success: true,
      summary: data,
    }
    console.log(`${JOB_LOG_PREFIX} result`, JSON.stringify(body))
    return json(body, 200, startedAt)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    console.error(`${JOB_LOG_PREFIX} error`, message)
    return json({ success: false, error: message }, 500, startedAt)
  }
})

function json(body: unknown, status: number, startedAt: number): Response {
  const durationMs = Date.now() - startedAt
  console.log(`${JOB_LOG_PREFIX} durationMs`, durationMs)

  return new Response(JSON.stringify({ ...asRecord(body), durationMs }), {
    status,
    headers: { "Content-Type": "application/json" },
  })
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : { value }
}
