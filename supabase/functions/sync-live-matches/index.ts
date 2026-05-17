import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

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
  apiFootballRaw: number
  apiFootballNormalized: number
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
      apiFootballRaw: 0,
      apiFootballNormalized: 0,
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
  const apiFootballKey = Deno.env.get("API_FOOTBALL_KEY") ?? Deno.env.get("API_FOOTBALL_API_KEY")
  if (apiFootballKey) {
    debugLog(`api_football_key=${redactedSecretDescription(apiFootballKey)}`)
    try {
      const apiFootballMatches = await fetchApiFootballMatches(apiFootballKey, matchWindow, counts)
      if (apiFootballMatches.length > 0) {
        debugLog(`final_count=${apiFootballMatches.length}`)
        return { source: "api-football", matches: apiFootballMatches }
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      debugLog(`api_football_error=${message}`)
    }
  } else {
    debugLog("api_football_key=missing")
  }

  const sportsDBMatches = await fetchTheSportsDBMatches(matchWindow, counts)
  debugLog(`final_count=${sportsDBMatches.length}`)
  return { source: "thesportsdb", matches: sportsDBMatches }
}

async function fetchApiFootballMatches(
  apiKey: string,
  matchWindow: MatchWindow,
  counts: SyncCounts,
): Promise<LiveMatchUpsert[]> {
  const [liveMatches, upcomingMatches] = await Promise.all([
    fetchApiFootballFixtureURL(
      "https://v3.football.api-sports.io/fixtures?live=all",
      apiKey,
      counts,
    ),
    fetchApiFootballFixtureURL(
      apiFootballUpcomingURL(matchWindow),
      apiKey,
      counts,
    ),
  ])

  return normalizeMatchBatch([...liveMatches, ...upcomingMatches], matchWindow, counts)
}

async function fetchApiFootballFixtureURL(
  url: string,
  apiKey: string,
  counts: SyncCounts,
): Promise<LiveMatchUpsert[]> {
  debugLog(`request_url=${url}`)
  debugLog(`request_headers=${JSON.stringify({ "x-apisports-key": redactedSecretDescription(apiKey) })}`)

  const response = await fetch(url, {
    headers: {
      "x-apisports-key": apiKey,
    },
  })
  debugLog(`response_status=${response.status}`)

  const raw = await response.text()
  debugLog(`raw_response=${rawPreview(raw)}`)

  if (!response.ok) {
    throw new Error(`API-Football live fixtures failed: ${response.status}`)
  }

  const data = JSON.parse(raw)
  const fixtures = Array.isArray(data?.response) ? data.response : []
  counts.apiFootballRaw += fixtures.length
  debugLog(`raw_count=${fixtures.length}`)

  const normalized = fixtures.flatMap((item: unknown): LiveMatchUpsert[] => {
    const record = item as Record<string, any>
    const fixture = record?.fixture
    const teams = record?.teams
    const goals = record?.goals
    const league = record?.league
    const externalId = String(fixture?.id ?? "")
    const startTime = String(fixture?.date ?? "")
    const home = String(teams?.home?.name ?? "")
    const away = String(teams?.away?.name ?? "")
    if (!externalId || !startTime || !home || !away) return []

    return [{
      id: `api-football:${externalId}`,
      source: "api-football",
      external_id: externalId,
      sport: "Soccer",
      home_team: home,
      away_team: away,
      score_home: numberOrZero(goals?.home),
      score_away: numberOrZero(goals?.away),
      match_status: normalizeApiFootballStatus(fixture?.status?.short),
      minute: numberOrNull(fixture?.status?.elapsed),
      league: String(league?.name ?? "Soccer"),
      start_time: startTime,
      payload: record,
    }]
  })
  counts.apiFootballNormalized += normalized.length
  debugLog(`filtered_count=${normalized.length}`)
  return normalized
}

async function fetchTheSportsDBMatches(
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

function apiFootballUpcomingURL(matchWindow: MatchWindow): string {
  const limit = boundedIntegerEnv("API_FOOTBALL_UPCOMING_LIMIT", 100, 1, 200)
  const params = new URLSearchParams({
    next: String(limit),
  })
  const timezone = Deno.env.get("API_FOOTBALL_TIMEZONE")?.trim()
  if (timezone) params.set("timezone", timezone)
  debugLog(`api_football_upcoming_window=${dateOnly(matchWindow.start)}..${dateOnly(matchWindow.end)}`)
  return `https://v3.football.api-sports.io/fixtures?${params.toString()}`
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

function boundedIntegerEnv(name: string, fallback: number, min: number, max: number): number {
  const parsed = Number(Deno.env.get(name))
  if (!Number.isFinite(parsed)) return fallback
  return Math.max(min, Math.min(max, Math.trunc(parsed)))
}

function isWithinMatchWindow(rawStart: string, matchWindow: MatchWindow): boolean {
  const start = new Date(rawStart)
  return Number.isFinite(start.getTime()) && start >= matchWindow.start && start <= matchWindow.end
}

function dateOnly(date: Date): string {
  return date.toISOString().slice(0, 10)
}

function normalizeApiFootballStatus(raw: unknown): MatchStatus {
  const status = String(raw ?? "").toUpperCase()
  if (["1H", "2H", "ET", "BT", "P", "LIVE"].includes(status)) return "LIVE"
  if (status === "HT") return "HT"
  if (["FT", "AET", "PEN"].includes(status)) return "FT"
  return "SCHEDULED"
}

function normalizeSportsDBStatus(raw: unknown): MatchStatus {
  const status = String(raw ?? "").trim().toUpperCase()
  if (status.includes("HALF") || status === "HT") return "HT"
  if (status.includes("FT") || status.includes("FINAL") || status.includes("FINISHED")) return "FT"
  if (status.includes("LIVE") || status.includes("'") || status.includes("Q") || status.includes("PERIOD")) return "LIVE"
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
