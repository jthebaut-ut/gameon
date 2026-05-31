// Manual test: curl -X POST "$SUPABASE_URL/functions/v1/sync-live-matches" \
//   -H "Authorization: Bearer $SUPABASE_ANON_KEY" -H "Content-Type: application/json"
// Deploy: supabase functions deploy sync-live-matches

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const THESPORTSDB_V2_BASE = "https://www.thesportsdb.com/api/v2/json"

type MatchStatus = "LIVE" | "HT" | "FT" | "SCHEDULED"

type TVBroadcastRow = {
  idEvent: string | null
  strCountry: string | null
  strEventCountry: string | null
  strChannel: string | null
  strLogo: string | null
  strTime: string | null
  dateEvent: string | null
  strTimeStamp: string | null
}

type TVBroadcastCacheRow = {
  external_id: string
  tv_broadcasts: TVBroadcastRow[] | null
  tv_updated_at: string | null
}

type TimelineEventRow = {
  idTimeline: string | null
  idEvent: string | null
  strTimeline: string | null
  strTimelineDetail: string | null
  strHome: string | null
  idPlayer: string | null
  strPlayer: string | null
  idAssist: string | null
  strAssist: string | null
  intTime: string | null
  idTeam: string | null
  strTeam: string | null
  strComment: string | null
  dateEvent: string | null
  strSeason: string | null
}

type TimelineEventCacheRow = {
  external_id: string
  timeline_events: TimelineEventRow[] | null
  timeline_updated_at: string | null
}

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
  tv_broadcasts: TVBroadcastRow[] | null
  tv_updated_at: string | null
  timeline_events: TimelineEventRow[] | null
  timeline_updated_at: string | null
}

type SyncCounts = {
  sportsDBRaw: number
  sportsDBNormalized: number
  windowFiltered: number
  deduped: number
  upserted: number
  pruned: number
  tvCacheHits: number
  tvFetched: number
  tvEmpty: number
  tvErrors: number
  timelineCacheHits: number
  timelineFetched: number
  timelineEmpty: number
  timelineErrors: number
}

type ScheduledFixturesCounts = {
  fetched: number
  normalized: number
  windowFiltered: number
  deduped: number
  protectedExisting: number
  upserted: number
  errors: number
}

type ScheduledLeagueConfig = {
  id: string
  sport: string
  league: string
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
      tvCacheHits: 0,
      tvFetched: 0,
      tvEmpty: 0,
      tvErrors: 0,
      timelineCacheHits: 0,
      timelineFetched: 0,
      timelineEmpty: 0,
      timelineErrors: 0,
    }
    const scheduledCounts: ScheduledFixturesCounts = {
      fetched: 0,
      normalized: 0,
      windowFiltered: 0,
      deduped: 0,
      protectedExisting: 0,
      upserted: 0,
      errors: 0,
    }
    const fetchResult = await fetchNormalizedMatches(matchWindow, counts)
    const scheduledMatches = await fetchScheduledFixtureMatches(matchWindow, scheduledCounts)
    const supabase = createClient(supabaseUrl, serviceRoleKey)

    counts.pruned = await pruneStaleMatches(supabase, matchWindow)
    const protectedMatchIds = await fetchProtectedMatchIds(supabase, matchWindow)
    const matchesToUpsert = mergeLiveAndScheduledMatches(fetchResult.matches, scheduledMatches, protectedMatchIds, scheduledCounts)
    await enrichMatchesWithTVBroadcasts(supabase, matchesToUpsert, counts)
    await enrichMatchesWithTimelineEvents(supabase, matchesToUpsert, counts)
    const scheduledUpsertIds = new Set(scheduledMatches.map((match) => match.id))

    if (matchesToUpsert.length > 0) {
      const { error } = await supabase
        .from("live_matches")
        .upsert(matchesToUpsert, { onConflict: "id" })

      if (error) {
        scheduledLog(`error=upsert ${error.message}`)
        return json({ success: false, error: error.message }, 500)
      }
      counts.upserted = matchesToUpsert.length
      scheduledCounts.upserted = matchesToUpsert.filter((match) =>
        scheduledUpsertIds.has(match.id) && match.match_status === "SCHEDULED"
      ).length
    }
    scheduledLog(`upserted=${scheduledCounts.upserted}`)

    return json({
      success: true,
      source: fetchResult.source,
      window: {
        start: matchWindow.startISO,
        end: matchWindow.endISO,
      },
      counts,
      scheduledCounts,
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

async function fetchScheduledFixtureMatches(
  matchWindow: MatchWindow,
  counts: ScheduledFixturesCounts,
): Promise<LiveMatchUpsert[]> {
  const apiKey = Deno.env.get("THESPORTSDB_API_KEY") ?? "123"
  const allMatches: LiveMatchUpsert[] = []

  for (const leagueConfig of configuredSportsDBScheduledLeagues()) {
    const encodedLeagueId = encodeURIComponent(leagueConfig.id)
    const url = `https://www.thesportsdb.com/api/v1/json/${apiKey}/eventsnextleague.php?id=${encodedLeagueId}`
    const redactedURL = `https://www.thesportsdb.com/api/v1/json/redacted/eventsnextleague.php?id=${encodedLeagueId}`
    scheduledLog(`sport=${leagueConfig.sport}`)
    scheduledLog(`league=${leagueConfig.league}`)
    debugLog(`scheduled_request_url=${redactedURL}`)

    try {
      const response = await fetch(url)
      debugLog(`scheduled_response_status=${response.status}`)
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`)
      }

      const raw = await response.text()
      debugLog(`scheduled_raw_response=${rawPreview(raw)}`)
      const data = JSON.parse(raw)
      const events = Array.isArray(data?.events) ? data.events : []
      counts.fetched += events.length

      const fetchedByDate = new Map<string, number>()
      for (const event of events) {
        const date = String(event?.dateEvent ?? "unknown")
        fetchedByDate.set(date, (fetchedByDate.get(date) ?? 0) + 1)

        const normalized = normalizeSportsDBScheduledFixture(event, leagueConfig)
        if (normalized) {
          counts.normalized += 1
          allMatches.push(normalized)
        }
      }

      if (fetchedByDate.size === 0) {
        scheduledLog("date=none")
        scheduledLog("fetched=0")
      } else {
        for (const [date, fetched] of fetchedByDate.entries()) {
          scheduledLog(`date=${date}`)
          scheduledLog(`fetched=${fetched}`)
        }
      }
    } catch (error) {
      counts.errors += 1
      const message = error instanceof Error ? error.message : String(error)
      scheduledLog(`error=${message}`)
    }
  }

  return normalizeScheduledFixtureBatch(allMatches, matchWindow, counts)
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
    tv_broadcasts: null,
    tv_updated_at: null,
    timeline_events: null,
    timeline_updated_at: null,
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
    tv_broadcasts: null,
    tv_updated_at: null,
    timeline_events: null,
    timeline_updated_at: null,
  }
}

function normalizeSportsDBScheduledFixture(
  event: Record<string, any>,
  fallback: ScheduledLeagueConfig,
): LiveMatchUpsert | null {
  const normalized = normalizeSportsDBEvent(event, fallback.league)
  if (!normalized) return null

  const rawStatus = event?.strStatus ?? event?.strProgress
  const status = normalizeSportsDBStatus(rawStatus)
  if (status !== "SCHEDULED") return null

  return {
    ...normalized,
    sport: String(event?.strSport ?? "").trim() ? normalizeSportsDBSport(event?.strSport) : fallback.sport,
    league: String(event?.strLeague ?? fallback.league),
    score_home: 0,
    score_away: 0,
    match_status: "SCHEDULED",
    minute: null,
    payload: {
      ...event,
      fangeo_sync_kind: "scheduled_fixture",
    },
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

function normalizeScheduledFixtureBatch(
  matches: LiveMatchUpsert[],
  matchWindow: MatchWindow,
  counts: ScheduledFixturesCounts,
): LiveMatchUpsert[] {
  const now = new Date()
  const windowed = matches.filter((match) => {
    const start = new Date(match.start_time)
    return Number.isFinite(start.getTime()) && start >= now && start <= matchWindow.end
  })
  counts.windowFiltered += matches.length - windowed.length

  const latestById = new Map<string, LiveMatchUpsert>()
  for (const match of windowed) {
    latestById.set(match.id, match)
  }
  counts.deduped += windowed.length - latestById.size
  return [...latestById.values()].sort((lhs, rhs) => lhs.start_time.localeCompare(rhs.start_time))
}

async function fetchProtectedMatchIds(
  supabase: ReturnType<typeof createClient>,
  matchWindow: MatchWindow,
): Promise<Set<string>> {
  const { data, error } = await supabase
    .from("live_matches")
    .select("id")
    .in("match_status", ["LIVE", "HT", "FT"])
    .gte("start_time", matchWindow.startISO)
    .lte("start_time", matchWindow.endISO)

  if (error || !Array.isArray(data)) {
    if (error) scheduledLog(`error=protected_id_query ${error.message}`)
    return new Set()
  }

  return new Set(data.map((row) => String(row.id)).filter(Boolean))
}

function mergeLiveAndScheduledMatches(
  liveMatches: LiveMatchUpsert[],
  scheduledMatches: LiveMatchUpsert[],
  protectedMatchIds: Set<string>,
  counts: ScheduledFixturesCounts,
): LiveMatchUpsert[] {
  const liveIds = new Set(liveMatches.map((match) => match.id))
  const merged = [...liveMatches]

  for (const match of scheduledMatches) {
    if (liveIds.has(match.id) || protectedMatchIds.has(match.id)) {
      counts.protectedExisting += 1
      continue
    }
    merged.push(match)
  }

  return merged
}

async function enrichMatchesWithTVBroadcasts(
  supabase: ReturnType<typeof createClient>,
  matches: LiveMatchUpsert[],
  counts: SyncCounts,
): Promise<void> {
  const sportsDBMatches = matches.filter((match) =>
    match.source === "thesportsdb" && match.external_id
  )
  if (sportsDBMatches.length === 0) return

  const externalIds = [...new Set(sportsDBMatches.map((match) => match.external_id))]
  const cacheByEventId = await fetchTVBroadcastCache(supabase, externalIds)
  const fetchedByEventId = new Map<string, { broadcasts: TVBroadcastRow[]; updatedAt: string }>()
  const sportsDBKey = Deno.env.get("THESPORTSDB_API_KEY")?.trim()

  for (const match of sportsDBMatches) {
    const cached = cacheByEventId.get(match.external_id)
    if (cached && isTVBroadcastCacheFresh(cached, match)) {
      match.tv_broadcasts = cached.tv_broadcasts ?? []
      match.tv_updated_at = cached.tv_updated_at
      counts.tvCacheHits += 1
      continue
    }

    const runCached = fetchedByEventId.get(match.external_id)
    if (runCached) {
      match.tv_broadcasts = runCached.broadcasts
      match.tv_updated_at = runCached.updatedAt
      counts.tvCacheHits += 1
      continue
    }

    try {
      const broadcasts = await fetchTheSportsDBTVBroadcasts(match.external_id, sportsDBKey)
      const updatedAt = new Date().toISOString()
      fetchedByEventId.set(match.external_id, { broadcasts, updatedAt })
      match.tv_broadcasts = broadcasts
      match.tv_updated_at = updatedAt
      counts.tvFetched += 1
      if (broadcasts.length === 0) counts.tvEmpty += 1
      tvLog(`event=${match.external_id} fetched=${broadcasts.length}`)
    } catch (error) {
      counts.tvErrors += 1
      const message = error instanceof Error ? error.message : String(error)
      tvLog(`event=${match.external_id} error=${message}`)
      match.tv_broadcasts = cached?.tv_broadcasts ?? []
      match.tv_updated_at = cached?.tv_updated_at ?? null
    }
  }
}

async function fetchTVBroadcastCache(
  supabase: ReturnType<typeof createClient>,
  externalIds: string[],
): Promise<Map<string, TVBroadcastCacheRow>> {
  if (externalIds.length === 0) return new Map()

  const { data, error } = await supabase
    .from("live_matches")
    .select("external_id,tv_broadcasts,tv_updated_at")
    .eq("source", "thesportsdb")
    .in("external_id", externalIds)

  if (error || !Array.isArray(data)) {
    if (error) tvLog(`cache_query_error=${error.message}`)
    return new Map()
  }

  const rows = new Map<string, TVBroadcastCacheRow>()
  for (const row of data) {
    const externalId = String(row?.external_id ?? "")
    if (!externalId) continue
    rows.set(externalId, {
      external_id: externalId,
      tv_broadcasts: Array.isArray(row?.tv_broadcasts)
        ? row.tv_broadcasts.map((entry) => normalizeTVBroadcastRow(entry)).filter(isTVBroadcastRow)
        : null,
      tv_updated_at: typeof row?.tv_updated_at === "string" ? row.tv_updated_at : null,
    })
  }
  return rows
}

function isTVBroadcastCacheFresh(cache: TVBroadcastCacheRow, match: LiveMatchUpsert): boolean {
  if (!cache.tv_updated_at) return false
  const updatedAt = new Date(cache.tv_updated_at)
  if (!Number.isFinite(updatedAt.getTime())) return false
  return Date.now() - updatedAt.getTime() < tvBroadcastCacheTTLMilliseconds(match)
}

function tvBroadcastCacheTTLMilliseconds(match: LiveMatchUpsert): number {
  return match.match_status === "LIVE" || match.match_status === "HT"
    ? 30 * 60 * 1000
    : 6 * 60 * 60 * 1000
}

async function fetchTheSportsDBTVBroadcasts(
  idEvent: string,
  apiKey: string | undefined,
): Promise<TVBroadcastRow[]> {
  if (apiKey) {
    try {
      return await fetchTheSportsDBV2TVBroadcasts(idEvent, apiKey)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      tvLog(`v2_failed event=${idEvent} error=${message}`)
    }
  }
  return await fetchTheSportsDBV1TVBroadcasts(idEvent, apiKey ?? "123")
}

async function fetchTheSportsDBV2TVBroadcasts(
  idEvent: string,
  apiKey: string,
): Promise<TVBroadcastRow[]> {
  const url = `${THESPORTSDB_V2_BASE}/lookup/event_tv/${encodeURIComponent(idEvent)}`
  const response = await fetch(url, {
    headers: { "X-API-KEY": apiKey },
  })
  if (!response.ok) throw new Error(`v2 HTTP ${response.status}`)
  const data = await response.json()
  return normalizeTVBroadcastRows(data, idEvent)
}

async function fetchTheSportsDBV1TVBroadcasts(
  idEvent: string,
  apiKey: string,
): Promise<TVBroadcastRow[]> {
  const url = `https://www.thesportsdb.com/api/v1/json/${apiKey}/lookuptv.php?id=${encodeURIComponent(idEvent)}`
  const response = await fetch(url)
  if (!response.ok) throw new Error(`v1 HTTP ${response.status}`)
  const data = await response.json()
  return normalizeTVBroadcastRows(data, idEvent)
}

function normalizeTVBroadcastRows(data: unknown, fallbackEventId: string): TVBroadcastRow[] {
  const rows = extractTVBroadcastRows(data)
  return rows
    .map((row) => normalizeTVBroadcastRow(row, fallbackEventId))
    .filter(isTVBroadcastRow)
}

function extractTVBroadcastRows(data: unknown): unknown[] {
  if (Array.isArray(data)) return data
  if (!data || typeof data !== "object") return []
  const record = data as Record<string, unknown>
  for (const key of ["event_tv", "eventtv", "tvevent", "tvevents", "tv", "events"]) {
    const value = record[key]
    if (Array.isArray(value)) return value
  }
  return []
}

function normalizeTVBroadcastRow(row: unknown, fallbackEventId: string | null = null): TVBroadcastRow {
  const record = row && typeof row === "object" ? row as Record<string, unknown> : {}
  return {
    idEvent: cleanString(record.idEvent) ?? fallbackEventId,
    strCountry: cleanString(record.strCountry),
    strEventCountry: cleanString(record.strEventCountry),
    strChannel: cleanString(record.strChannel),
    strLogo: cleanString(record.strLogo),
    strTime: cleanString(record.strTime),
    dateEvent: cleanString(record.dateEvent),
    strTimeStamp: cleanString(record.strTimeStamp),
  }
}

function isTVBroadcastRow(row: TVBroadcastRow): boolean {
  return Boolean(row.strChannel)
}

function cleanString(value: unknown): string | null {
  const trimmed = String(value ?? "").trim()
  return trimmed.length > 0 ? trimmed : null
}

async function enrichMatchesWithTimelineEvents(
  supabase: ReturnType<typeof createClient>,
  matches: LiveMatchUpsert[],
  counts: SyncCounts,
): Promise<void> {
  const sportsDBMatches = matches.filter((match) =>
    match.source === "thesportsdb" && match.external_id
  )
  if (sportsDBMatches.length === 0) return

  const externalIds = [...new Set(sportsDBMatches.map((match) => match.external_id))]
  const cacheByEventId = await fetchTimelineEventCache(supabase, externalIds)
  const fetchedByEventId = new Map<string, { events: TimelineEventRow[]; updatedAt: string }>()
  const sportsDBKey = Deno.env.get("THESPORTSDB_API_KEY")?.trim()

  for (const match of sportsDBMatches) {
    const cached = cacheByEventId.get(match.external_id)
    if (cached && isTimelineEventCacheFresh(cached, match)) {
      match.timeline_events = cached.timeline_events ?? []
      match.timeline_updated_at = cached.timeline_updated_at
      counts.timelineCacheHits += 1
      continue
    }

    const runCached = fetchedByEventId.get(match.external_id)
    if (runCached) {
      match.timeline_events = runCached.events
      match.timeline_updated_at = runCached.updatedAt
      counts.timelineCacheHits += 1
      continue
    }

    try {
      const events = await fetchTheSportsDBTimelineEvents(match.external_id, sportsDBKey)
      const updatedAt = new Date().toISOString()
      fetchedByEventId.set(match.external_id, { events, updatedAt })
      match.timeline_events = events
      match.timeline_updated_at = updatedAt
      counts.timelineFetched += 1
      if (events.length === 0) counts.timelineEmpty += 1
      timelineLog(`event=${match.external_id} fetched=${events.length}`)
    } catch (error) {
      counts.timelineErrors += 1
      const message = error instanceof Error ? error.message : String(error)
      timelineLog(`event=${match.external_id} error=${message}`)
      match.timeline_events = cached?.timeline_events ?? []
      match.timeline_updated_at = cached?.timeline_updated_at ?? null
    }
  }
}

async function fetchTimelineEventCache(
  supabase: ReturnType<typeof createClient>,
  externalIds: string[],
): Promise<Map<string, TimelineEventCacheRow>> {
  if (externalIds.length === 0) return new Map()

  const { data, error } = await supabase
    .from("live_matches")
    .select("external_id,timeline_events,timeline_updated_at")
    .eq("source", "thesportsdb")
    .in("external_id", externalIds)

  if (error || !Array.isArray(data)) {
    if (error) timelineLog(`cache_query_error=${error.message}`)
    return new Map()
  }

  const rows = new Map<string, TimelineEventCacheRow>()
  for (const row of data) {
    const externalId = String(row?.external_id ?? "")
    if (!externalId) continue
    rows.set(externalId, {
      external_id: externalId,
      timeline_events: Array.isArray(row?.timeline_events)
        ? row.timeline_events.map((entry) => normalizeTimelineEventRow(entry)).filter(isTimelineEventRow)
        : null,
      timeline_updated_at: typeof row?.timeline_updated_at === "string" ? row.timeline_updated_at : null,
    })
  }
  return rows
}

function isTimelineEventCacheFresh(cache: TimelineEventCacheRow, match: LiveMatchUpsert): boolean {
  if (!cache.timeline_updated_at) return false
  const updatedAt = new Date(cache.timeline_updated_at)
  if (!Number.isFinite(updatedAt.getTime())) return false
  return Date.now() - updatedAt.getTime() < timelineEventCacheTTLMilliseconds(match)
}

function timelineEventCacheTTLMilliseconds(match: LiveMatchUpsert): number {
  return match.match_status === "LIVE" || match.match_status === "HT"
    ? 30 * 60 * 1000
    : 6 * 60 * 60 * 1000
}

async function fetchTheSportsDBTimelineEvents(
  idEvent: string,
  apiKey: string | undefined,
): Promise<TimelineEventRow[]> {
  if (apiKey) {
    try {
      return await fetchTheSportsDBV2TimelineEvents(idEvent, apiKey)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      timelineLog(`v2_failed event=${idEvent} error=${message}`)
    }
  }
  return await fetchTheSportsDBV1TimelineEvents(idEvent, apiKey ?? "123")
}

async function fetchTheSportsDBV2TimelineEvents(idEvent: string, apiKey: string): Promise<TimelineEventRow[]> {
  const url = `${THESPORTSDB_V2_BASE}/lookup/event_timeline/${encodeURIComponent(idEvent)}`
  const response = await fetch(url, {
    headers: { "X-API-KEY": apiKey },
  })
  if (!response.ok) throw new Error(`v2 HTTP ${response.status}`)
  const data = await response.json()
  return normalizeTimelineEventRows(data, idEvent)
}

async function fetchTheSportsDBV1TimelineEvents(idEvent: string, apiKey: string): Promise<TimelineEventRow[]> {
  const url = `https://www.thesportsdb.com/api/v1/json/${apiKey}/lookuptimeline.php?id=${encodeURIComponent(idEvent)}`
  const response = await fetch(url)
  if (!response.ok) throw new Error(`v1 HTTP ${response.status}`)
  const data = await response.json()
  return normalizeTimelineEventRows(data, idEvent)
}

function normalizeTimelineEventRows(data: unknown, fallbackEventId: string): TimelineEventRow[] {
  const rows = extractTimelineEventRows(data)
  return rows
    .map((row) => normalizeTimelineEventRow(row, fallbackEventId))
    .filter(isTimelineEventRow)
}

function extractTimelineEventRows(data: unknown): unknown[] {
  if (Array.isArray(data)) return data
  if (!data || typeof data !== "object") return []
  const record = data as Record<string, unknown>
  for (const key of ["timeline", "event_timeline", "eventtimeline", "timelines", "events"]) {
    const value = record[key]
    if (Array.isArray(value)) return value
  }
  return []
}

function normalizeTimelineEventRow(row: unknown, fallbackEventId: string | null = null): TimelineEventRow {
  const record = row && typeof row === "object" ? row as Record<string, unknown> : {}
  return {
    idTimeline: cleanString(record.idTimeline),
    idEvent: cleanString(record.idEvent) ?? fallbackEventId,
    strTimeline: cleanString(record.strTimeline),
    strTimelineDetail: cleanString(record.strTimelineDetail),
    strHome: cleanString(record.strHome),
    idPlayer: cleanString(record.idPlayer),
    strPlayer: cleanString(record.strPlayer),
    idAssist: cleanString(record.idAssist),
    strAssist: cleanString(record.strAssist),
    intTime: cleanString(record.intTime),
    idTeam: cleanString(record.idTeam),
    strTeam: cleanString(record.strTeam),
    strComment: cleanString(record.strComment),
    dateEvent: cleanString(record.dateEvent),
    strSeason: cleanString(record.strSeason),
  }
}

function isTimelineEventRow(row: TimelineEventRow): boolean {
  return Boolean(row.strTimeline || row.strPlayer || row.strTeam)
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

function configuredSportsDBScheduledLeagues(): ScheduledLeagueConfig[] {
  const known: Record<string, ScheduledLeagueConfig> = {
    "4387": { id: "4387", sport: "NBA", league: "NBA" },
    "4391": { id: "4391", sport: "NFL", league: "NFL" },
    "4424": { id: "4424", sport: "MLB", league: "MLB" },
    "4328": { id: "4328", sport: "Soccer", league: "English Premier League" },
  }
  return configuredSportsDBUpcomingLeagueIds().map((id) => known[id] ?? { id, sport: "Sports", league: id })
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
  if (
    status.includes("LIVE") ||
    status.includes("IN PROGRESS") ||
    status.includes("IN PLAY") ||
    status.includes("IN-PLAY") ||
    status.includes("PLAYING") ||
    status.includes("ACTIVE") ||
    status.includes("STARTED") ||
    status.includes("EXTRA INNING") ||
    status.includes("'") ||
    status.includes("Q") ||
    status.includes("PERIOD") ||
    status.includes("INNING")
  ) {
    return "LIVE"
  }
  if (status === "NS" || status.includes("SCHED") || status.includes("NOT STARTED")) return "SCHEDULED"
  return "SCHEDULED"
}

function normalizeSportsDBSport(raw: unknown): string {
  const sport = String(raw ?? "").trim()
  if (sport === "Basketball") return "NBA"
  if (sport === "American Football") return "NFL"
  if (sport === "Baseball") return "MLB"
  if (sport === "Breakdancing" || sport === "Breaking") return "Break Dance"
  if (sport === "Ballet") return "Ballet"
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

function scheduledLog(message: string): void {
  console.log(`[ScheduledFixturesSync] ${message}`)
}

function tvLog(message: string): void {
  console.log(`[TheSportsDBTV] ${message}`)
}

function timelineLog(message: string): void {
  console.log(`[TheSportsDBTimeline] ${message}`)
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
