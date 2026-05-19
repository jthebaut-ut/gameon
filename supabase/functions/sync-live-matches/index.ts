// Manual test: curl -X POST "$SUPABASE_URL/functions/v1/sync-live-matches" \
//   -H "Authorization: Bearer $SUPABASE_ANON_KEY" -H "Content-Type: application/json"
// Deploy: supabase functions deploy sync-live-matches

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const THESPORTSDB_V2_BASE = "https://www.thesportsdb.com/api/v2/json"

type MatchStatus = "LIVE" | "HT" | "FT" | "SCHEDULED"

type MatchWindow = {
  start: Date
  end: Date
  startISO: string
  endISO: string
}

type LiveMatchUpsert = {
  id: string
  source: string
  external_id: string
  sport: string
  home_team: string
  away_team: string
  score_home: number
  score_away: number
  match_status: MatchStatus
  minute: number | null
  league: string
  start_time: string
  payload: unknown
}

type SyncCounts = {
  sportsDBRaw: number
  sportsDBNormalized: number
  windowFiltered: number
  deduped: number
  upserted: number
  pruned: number
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  const supabaseUrl = Deno.env.get("PROJECT_URL") ?? Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ success: false, error: "Missing Supabase service env vars" }, 500)
  }

  try {
    const matchWindow = currentMatchWindow()
    const counts: SyncCounts = {
      sportsDBRaw: 0,
      sportsDBNormalized: 0,
      windowFiltered: 0,
      deduped: 0,
      upserted: 0,
      pruned: 0,
    }
    const fetchResult = await fetchNormalizedMatches(matchWindow, counts)
    const supabase = createClient(supabaseUrl, serviceRoleKey)

    counts.pruned = await pruneStaleMatches(supabase, matchWindow)

    if (fetchResult.matches.length > 0) {
      const { error } = await supabase
        .from("live_matches")
        .upsert(fetchResult.matches, { onConflict: "id" })

      if (error) {
        return json({ success: false, error: error.message }, 500)
      }
      counts.upserted = fetchResult.matches.length
    }

    return json({
      success: true,
      source: fetchResult.source,
      window: {
        start: matchWindow.startISO,
        end: matchWindow.endISO,
      },
      counts,
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    return json({ success: false, error: message }, 500)
  }
})

async function fetchNormalizedMatches(
  matchWindow: MatchWindow,
  counts: SyncCounts,
): Promise<{ source: string; matches: LiveMatchUpsert[] }> {
  const sportsDBKey = Deno.env.get("THESPORTSDB_API_KEY")?.trim()
  if (sportsDBKey) {
    const { available, matches: v2Matches } = await fetchTheSportsDBPremiumV2Matches(sportsDBKey, counts)
    if (available) {
      providerLog("using=TheSportsDBV2")
      const batched = normalizeMatchBatch(v2Matches, matchWindow, counts)
      providerLog(`totalNormalized=${batched.length}`)
      return { source: "thesportsdb", matches: batched }
    }
  } else {
    premiumLog("skipped reason=THESPORTSDB_API_KEY missing")
  }

  providerLog("fallback=TheSportsDBV1")
  const v1Matches = await fetchTheSportsDBV1Matches(matchWindow, counts)
  providerLog(`totalNormalized=${v1Matches.length}`)
  return { source: "thesportsdb", matches: v1Matches }
}

async function fetchTheSportsDBPremiumV2Matches(
  apiKey: string,
  counts: SyncCounts,
): Promise<{ available: boolean; matches: LiveMatchUpsert[] }> {
  const allMatches: LiveMatchUpsert[] = []
  let anySportSucceeded = false

  for (const sport of configuredSportsDBV2LivescoreSports()) {
    premiumLog(`fetch start sport=${sport}`)
    const url = `${THESPORTSDB_V2_BASE}/livescore/${encodeURIComponent(sport)}`
    try {
      const response = await fetch(url, {
        headers: { "X-API-KEY": apiKey },
      })
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`)
      }

      const data = await response.json()
      const rows = Array.isArray(data?.livescore) ? data.livescore : []
      anySportSucceeded = true
      counts.sportsDBRaw += rows.length
      premiumLog(`fetch success sport=${sport} count=${rows.length}`)

      for (const row of rows) {
        const normalized = normalizeSportsDBV2Livescore(row)
        if (normalized) allMatches.push(normalized)
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      premiumLog(`fetch failed sport=${sport} error=${message}`)
    }
  }

  counts.sportsDBNormalized += allMatches.length
  premiumLog(`normalized count=${allMatches.length}`)
  return { available: anySportSucceeded, matches: allMatches }
}

function normalizeSportsDBV2Livescore(event: Record<string, unknown>): LiveMatchUpsert | null {
  const externalId = String(event?.idEvent ?? "")
  const home = String(event?.strHomeTeam ?? "")
  const away = String(event?.strAwayTeam ?? "")
  const timestamp = combinedSportsDBStart(event?.dateEvent, event?.strEventTime)
  if (!externalId || !home || !away || !timestamp) return null

  const rawStatus = event?.strStatus ?? event?.strProgress
  const minute = numberOrNull(event?.strProgress) ?? minuteFromProgress(event?.strProgress)

  return {
    id: `thesportsdb:${externalId}`,
    source: "thesportsdb",
    external_id: externalId,
    sport: normalizeSportsDBSport(event?.strSport),
    home_team: home,
    away_team: away,
    score_home: numberOrZero(event?.intHomeScore),
    score_away: numberOrZero(event?.intAwayScore),
    match_status: normalizeSportsDBStatus(rawStatus),
    minute,
    league: String(event?.strLeague ?? "Sports"),
    start_time: timestamp,
    payload: event,
  }
}

async function fetchTheSportsDBV1Matches(
  matchWindow: MatchWindow,
  counts: SyncCounts,
): Promise<LiveMatchUpsert[]> {
  const apiKey = Deno.env.get("THESPORTSDB_API_KEY") ?? "123"
  debugLog(`thesportsdb_key=${redactedSecretDescription(apiKey)}`)

  const allMatches: LiveMatchUpsert[] = []
  for (const league of configuredSportsDBLiveLeagues()) {
    const encodedLeague = encodeURIComponent(league)
    const url = `https://www.thesportsdb.com/api/v1/json/${apiKey}/livescore.php?l=${encodedLeague}`
    const redactedURL = `https://www.thesportsdb.com/api/v1/json/redacted/livescore.php?l=${encodedLeague}`
    debugLog(`request_url=${redactedURL}`)
    const response = await fetch(url)
    debugLog(`response_status=${response.status}`)
    if (!response.ok) continue

    const raw = await response.text()
    debugLog(`raw_response=${rawPreview(raw)}`)
    const data = JSON.parse(raw)
    const events = Array.isArray(data?.events) ? data.events : []
    counts.sportsDBRaw += events.length
    debugLog(`raw_count=${events.length}`)
    let normalizedCount = 0
    for (const event of events) {
      const normalized = normalizeSportsDBEvent(event, league)
      if (normalized) {
        normalizedCount += 1
        allMatches.push(normalized)
      }
    }
    counts.sportsDBNormalized += normalizedCount
    debugLog(`filtered_count=${normalizedCount}`)
  }

  for (const leagueId of configuredSportsDBUpcomingLeagueIds()) {
    const encodedLeagueId = encodeURIComponent(leagueId)
    const url = `https://www.thesportsdb.com/api/v1/json/${apiKey}/eventsnextleague.php?id=${encodedLeagueId}`
    const redactedURL = `https://www.thesportsdb.com/api/v1/json/redacted/eventsnextleague.php?id=${encodedLeagueId}`
    debugLog(`request_url=${redactedURL}`)
    const response = await fetch(url)
    debugLog(`response_status=${response.status}`)
    if (!response.ok) continue

    const raw = await response.text()
    debugLog(`raw_response=${rawPreview(raw)}`)
    const data = JSON.parse(raw)
    const events = Array.isArray(data?.events) ? data.events : []
    counts.sportsDBRaw += events.length
    debugLog(`raw_count=${events.length}`)
    let normalizedCount = 0
    for (const event of events) {
      const normalized = normalizeSportsDBEvent(event, String(event?.strLeague ?? leagueId))
      if (normalized) {
        normalizedCount += 1
        allMatches.push(normalized)
      }
    }
    counts.sportsDBNormalized += normalizedCount
    debugLog(`filtered_count=${normalizedCount}`)
  }

  return normalizeMatchBatch(allMatches, matchWindow, counts)
}

function normalizeSportsDBEvent(event: Record<string, any>, fallbackLeague: string): LiveMatchUpsert | null {
  const externalId = String(event?.idEvent ?? "")
  const home = String(event?.strHomeTeam ?? "")
  const away = String(event?.strAwayTeam ?? "")
  const timestamp = event?.strTimestamp ?? combinedSportsDBStart(event?.dateEvent, event?.strTime)
  if (!externalId || !home || !away || !timestamp) return null

  const rawStatus = event?.strStatus ?? event?.strProgress
  const minute = numberOrNull(event?.intRound) ?? minuteFromProgress(event?.strProgress)

  return {
    id: `thesportsdb:${externalId}`,
    source: "thesportsdb",
    external_id: externalId,
    sport: normalizeSportsDBSport(event?.strSport),
    home_team: home,
    away_team: away,
    score_home: numberOrZero(event?.intHomeScore),
    score_away: numberOrZero(event?.intAwayScore),
    match_status: normalizeSportsDBStatus(rawStatus),
    minute,
    league: String(event?.strLeague ?? fallbackLeague),
    start_time: timestamp,
    payload: event,
  }
}

function normalizeMatchBatch(
  matches: LiveMatchUpsert[],
  matchWindow: MatchWindow,
  counts: SyncCounts,
): LiveMatchUpsert[] {
  const windowed = matches.filter((match) => isWithinMatchWindow(match.start_time, matchWindow))
  counts.windowFiltered += matches.length - windowed.length

  const latestById = new Map<string, LiveMatchUpsert>()
  for (const match of windowed) {
    latestById.set(match.id, match)
  }
  counts.deduped += windowed.length - latestById.size
  return [...latestById.values()].sort((lhs, rhs) => lhs.start_time.localeCompare(rhs.start_time))
}

async function pruneStaleMatches(
  supabase: ReturnType<typeof createClient>,
  matchWindow: MatchWindow,
): Promise<number> {
  const { data, error } = await supabase.rpc("prune_live_matches_cache", {
    window_start: matchWindow.startISO,
    window_end: matchWindow.endISO,
  })
  if (error) {
    const { count, error: deleteError } = await supabase
      .from("live_matches")
      .delete({ count: "exact" })
      .or(`start_time.lt.${matchWindow.startISO},start_time.gt.${matchWindow.endISO}`)

    if (deleteError) throw deleteError
    return count ?? 0
  }
  return typeof data === "number" ? data : 0
}

function currentMatchWindow(now = new Date()): MatchWindow {
  const start = new Date(now.getTime() - 2 * 60 * 60 * 1000)
  const end = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000)
  return {
    start,
    end,
    startISO: start.toISOString(),
    endISO: end.toISOString(),
  }
}

function configuredSportsDBV2LivescoreSports(): string[] {
  return envList("THESPORTSDB_V2_SPORTS", [
    "soccer",
    "basketball",
    "american_football",
    "baseball",
    "ice_hockey",
  ])
}

function configuredSportsDBLiveLeagues(): string[] {
  return envList("THESPORTSDB_LIVE_LEAGUES", ["NBA", "NFL", "MLB", "English Premier League"])
}

function configuredSportsDBUpcomingLeagueIds(): string[] {
  return envList("THESPORTSDB_UPCOMING_LEAGUE_IDS", ["4387", "4391", "4424", "4328"])
}

function envList(name: string, fallback: string[]): string[] {
  const configured = Deno.env.get(name)
  const values = configured?.split(",").map((value) => value.trim()).filter(Boolean)
  return values && values.length > 0 ? values : fallback
}

function isWithinMatchWindow(rawStart: string, matchWindow: MatchWindow): boolean {
  const start = new Date(rawStart)
  return Number.isFinite(start.getTime()) && start >= matchWindow.start && start <= matchWindow.end
}

function normalizeSportsDBStatus(raw: unknown): MatchStatus {
  const status = String(raw ?? "").trim().toUpperCase()
  if (status.includes("HALF") || status === "HT") return "HT"
  if (status.includes("FT") || status.includes("FINAL") || status.includes("FINISHED")) return "FT"
  if (["1H", "2H", "ET", "BT", "P", "OT", "Q1", "Q2", "Q3", "Q4", "LIVE"].includes(status)) return "LIVE"
  if (status.includes("LIVE") || status.includes("'") || status.includes("Q") || status.includes("PERIOD")) return "LIVE"
  if (status === "NS" || status.includes("SCHED")) return "SCHEDULED"
  return "SCHEDULED"
}

function normalizeSportsDBSport(raw: unknown): string {
  const sport = String(raw ?? "").trim()
  if (sport === "Basketball") return "NBA"
  if (sport === "American Football") return "NFL"
  if (sport === "Baseball") return "MLB"
  return sport || "Sports"
}

function combinedSportsDBStart(dateEvent: unknown, timeEvent: unknown): string | null {
  const date = String(dateEvent ?? "").trim()
  if (!date) return null
  const time = String(timeEvent ?? "00:00:00").split("+")[0].trim() || "00:00:00"
  return `${date}T${time}Z`
}

function minuteFromProgress(raw: unknown): number | null {
  const match = String(raw ?? "").match(/(\d+)/)
  return match ? numberOrNull(match[1]) : null
}

function numberOrZero(value: unknown): number {
  const number = Number(value)
  return Number.isFinite(number) ? number : 0
}

function numberOrNull(value: unknown): number | null {
  const number = Number(value)
  return Number.isFinite(number) ? number : null
}

function premiumLog(message: string): void {
  console.log(`[TheSportsDBPremium] ${message}`)
}

function providerLog(message: string): void {
  console.log(`[LiveSportsProvider] ${message}`)
}

function debugLog(message: string): void {
  console.log(`[LiveDebug] ${message}`)
}

function redactedSecretDescription(value: string | undefined): string {
  if (!value) return "missing"
  return `present(redacted,length=${value.length})`
}

function rawPreview(raw: string, limit = 4000): string {
  if (raw.length <= limit) return raw
  return `${raw.slice(0, limit)}…<truncated ${raw.length - limit} chars>`
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
}
