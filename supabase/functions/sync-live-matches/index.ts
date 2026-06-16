// Manual test: curl -X POST "$SUPABASE_URL/functions/v1/sync-live-matches" \
//   -H "Authorization: Bearer $SUPABASE_ANON_KEY" -H "Content-Type: application/json"
// Deploy: supabase functions deploy sync-live-matches

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const THESPORTSDB_V2_BASE = "https://www.thesportsdb.com/api/v2/json"
const THE_SPORTSDB_V1_FREE_API_KEY = "123"

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

type FeaturedEventRow = {
  slug: string
  title: string
  sport: string | null
  include_keywords: string[] | null
  exclude_keywords: string[] | null
  start_date: string
  end_date: string
  enabled: boolean
  priority: number | null
}

type FeaturedEventProviderConfig = {
  leagueId: string
  season: string
  sport: string | null
  league: string | null
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
  featured_event_slug: string | null
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

type SavedTimelineCounts = {
  savedTimelineFetched: number
  savedTimelineEmpty: number
  savedTimelineUpdated: number
  savedTimelineIds: string[]
  savedTimelineEmptyIds: string[]
  savedTimelineScoringEmptyIds: string[]
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

type CompletedMatchesCounts = {
  fetched: number
  normalized: number
  deduped: number
  upserted: number
  savedCandidateIds: number
  subscriptionCandidateIds: number
  leagueRowsFetched: number
  featuredRowsFetched: number
  errors: number
}

type FeaturedPreloadCounts = {
  featuredEventsChecked: number
  featuredFixturesFetched: number
  featuredFixturesNormalized: number
  featuredFixturesMatched: number
  featuredFixturesUpserted: number
  featuredPreloadSkippedReason: string | null
  apiCalls: number
  errors: number
}

type ScheduledLeagueConfig = {
  id: string
  sport: string
  league: string
}

type RecentCompletedCandidateRow = {
  live_match_id: string | null
  source: string | null
  external_id: string | null
  league: string | null
  sport: string | null
  start_time: string | null
}

type SavedProGameTimelineTarget = {
  savedGameId: string
  liveMatchExternalId: string | null
  providerEventIdUsedForTimeline: string
  sport: string | null
}

type SportsDBCompletedEvent = {
  event: Record<string, any>
  fallbackLeague: string
  syncKind: string
  featuredEvent?: FeaturedEventRow
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
}

const FEATURED_PRELOAD_LOOKAHEAD_DAYS = 180
const FEATURED_PRELOAD_COOLDOWN_MS = 6 * 60 * 60 * 1000
const HEAVY_ENRICHMENT_LOOKAHEAD_MS = 48 * 60 * 60 * 1000

let lastFeaturedPreloadAttemptAt = 0

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
    const featuredCounts: FeaturedPreloadCounts = {
      featuredEventsChecked: 0,
      featuredFixturesFetched: 0,
      featuredFixturesNormalized: 0,
      featuredFixturesMatched: 0,
      featuredFixturesUpserted: 0,
      featuredPreloadSkippedReason: null,
      apiCalls: 0,
      errors: 0,
    }
    const supabase = createClient(supabaseUrl, serviceRoleKey)
    const completedWindow = recentCompletedMatchWindow()
    const savedTimelineCounts: SavedTimelineCounts = {
      savedTimelineFetched: 0,
      savedTimelineEmpty: 0,
      savedTimelineUpdated: 0,
      savedTimelineIds: [],
      savedTimelineEmptyIds: [],
      savedTimelineScoringEmptyIds: [],
    }
    const completedCounts: CompletedMatchesCounts = {
      fetched: 0,
      normalized: 0,
      deduped: 0,
      upserted: 0,
      savedCandidateIds: 0,
      subscriptionCandidateIds: 0,
      leagueRowsFetched: 0,
      featuredRowsFetched: 0,
      errors: 0,
    }
    completedLog(`completedWindowFrom=${completedWindow.startISO}`)

    const fetchResult = await fetchNormalizedMatches(matchWindow, counts)
    const scheduledMatches = await fetchScheduledFixtureMatches(matchWindow, scheduledCounts)
    const completedMatches = await fetchRecentlyCompletedMatches(supabase, completedWindow, completedCounts)
    completedLog(`completedRowsFetched=${completedCounts.fetched}`)
    counts.pruned = await pruneStaleMatches(supabase, matchWindow)
    const protectedMatchIds = await fetchProtectedMatchIds(supabase, matchWindow)
    const featuredMatches = await fetchFeaturedEventFixtureMatches(supabase, featuredCounts)
    const featuredUpsertIds = new Set(featuredMatches.map((match) => match.id))
    const completedUpsertIds = new Set(completedMatches.map((match) => match.id))
    const scheduledOnlyMatches = scheduledMatches.filter((match) => !featuredUpsertIds.has(match.id))
    const matchesToUpsert = mergeLiveAndScheduledMatches(
      dedupeLiveMatchUpserts([...fetchResult.matches, ...completedMatches]),
      [...featuredMatches, ...scheduledOnlyMatches],
      protectedMatchIds,
      scheduledCounts,
    )
    await enrichMatchesWithTVBroadcasts(supabase, matchesToUpsert, counts)
    await enrichMatchesWithTimelineEvents(supabase, matchesToUpsert, counts)
    const scheduledUpsertIds = new Set(scheduledOnlyMatches.map((match) => match.id))

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
      featuredCounts.featuredFixturesUpserted = matchesToUpsert.filter((match) =>
        featuredUpsertIds.has(match.id) && match.match_status === "SCHEDULED"
      ).length
      completedCounts.upserted = matchesToUpsert.filter((match) =>
        completedUpsertIds.has(match.id) && match.match_status === "FT"
      ).length
      for (const match of matchesToUpsert) {
        if (completedUpsertIds.has(match.id) && match.match_status === "FT") {
          completedLog(`completedRowUpserted=${match.id} score=${match.score_away}-${match.score_home} start=${match.start_time}`)
        }
      }
    }
    scheduledLog(`upserted=${scheduledCounts.upserted}`)
    featuredLog(`upserted=${featuredCounts.featuredFixturesUpserted}`)

    // Saved Pro Game timelines are written after upsert so bulk upserts cannot wipe hydrated rows.
    await enrichSavedProGamesWithTimelineEvents(supabase, savedTimelineCounts)

    return json({
      success: true,
      source: fetchResult.source,
      window: {
        start: matchWindow.startISO,
        end: matchWindow.endISO,
      },
      counts,
      savedTimelineCounts,
      scheduledCounts,
      completedCounts,
      featuredCounts,
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

async function fetchFeaturedEventFixtureMatches(
  supabase: ReturnType<typeof createClient>,
  counts: FeaturedPreloadCounts,
): Promise<LiveMatchUpsert[]> {
  const now = Date.now()
  if (now - lastFeaturedPreloadAttemptAt < FEATURED_PRELOAD_COOLDOWN_MS) {
    counts.featuredPreloadSkippedReason = "cooldown"
    return []
  }
  lastFeaturedPreloadAttemptAt = now

  const lastPersistedPreloadAt = await fetchLastFeaturedPreloadUpdatedAt(supabase)
  if (lastPersistedPreloadAt && now - lastPersistedPreloadAt.getTime() < FEATURED_PRELOAD_COOLDOWN_MS) {
    counts.featuredPreloadSkippedReason = "cooldown"
    return []
  }

  const featuredEvents = await fetchActiveUpcomingFeaturedEvents(supabase, counts)
  counts.featuredEventsChecked = featuredEvents.length
  if (featuredEvents.length === 0) {
    counts.featuredPreloadSkippedReason = "no_active_upcoming_featured_events"
    return []
  }

  const apiKey = Deno.env.get("THESPORTSDB_API_KEY") ?? "123"
  const allMatches: LiveMatchUpsert[] = []
  const missingMappings: string[] = []

  for (const featuredEvent of featuredEvents) {
    const providerConfigs = configuredFeaturedEventProviderConfigs(featuredEvent)
    if (providerConfigs.length === 0) {
      missingMappings.push(featuredEvent.slug)
      featuredLog(`slug=${featuredEvent.slug} skipped=no_provider_mapping`)
      continue
    }

    const eventStart = parseDateOnly(featuredEvent.start_date)
    const eventEnd = endOfDateOnly(featuredEvent.end_date)
    if (!eventStart || !eventEnd) {
      counts.errors += 1
      featuredLog(`slug=${featuredEvent.slug} skipped=invalid_date_window`)
      continue
    }

    for (const config of providerConfigs) {
      const encodedLeagueId = encodeURIComponent(config.leagueId)
      const encodedSeason = encodeURIComponent(config.season)
      const url = `https://www.thesportsdb.com/api/v1/json/${apiKey}/eventsseason.php?id=${encodedLeagueId}&s=${encodedSeason}`
      const redactedURL = `https://www.thesportsdb.com/api/v1/json/redacted/eventsseason.php?id=${encodedLeagueId}&s=${encodedSeason}`
      featuredLog(`slug=${featuredEvent.slug} leagueId=${config.leagueId} season=${config.season}`)
      debugLog(`featured_request_url=${redactedURL}`)
      counts.apiCalls += 1

      try {
        const response = await fetch(url)
        debugLog(`featured_response_status=${response.status}`)
        if (!response.ok) throw new Error(`HTTP ${response.status}`)

        const raw = await response.text()
        debugLog(`featured_raw_response=${rawPreview(raw)}`)
        const data = JSON.parse(raw)
        const events = Array.isArray(data?.events) ? data.events : []
        counts.featuredFixturesFetched += events.length

        for (const event of events) {
          const normalized = normalizeSportsDBScheduledFixture(event, {
            id: config.leagueId,
            sport: config.sport ?? featuredEvent.sport ?? "Sports",
            league: config.league ?? String(event?.strLeague ?? config.leagueId),
          })
          if (!normalized) continue
          counts.featuredFixturesNormalized += 1

          const startTime = new Date(normalized.start_time)
          if (!Number.isFinite(startTime.getTime()) || startTime < eventStart || startTime > eventEnd) {
            continue
          }
          if (!featuredEventMatchesFixture(featuredEvent, normalized)) {
            continue
          }

          allMatches.push({
            ...normalized,
            featured_event_slug: featuredEvent.slug,
            payload: {
              ...(event && typeof event === "object" ? event : {}),
              fangeo_sync_kind: "featured_event_fixture",
              fangeo_featured_event_slug: featuredEvent.slug,
            },
          })
          counts.featuredFixturesMatched += 1
        }
      } catch (error) {
        counts.errors += 1
        const message = error instanceof Error ? error.message : String(error)
        featuredLog(`slug=${featuredEvent.slug} error=${message}`)
      }
    }
  }

  if (allMatches.length === 0 && missingMappings.length > 0) {
    counts.featuredPreloadSkippedReason = `missing_provider_mapping:${missingMappings.join(",")}`
  }

  return dedupeFeaturedMatches(allMatches)
}

async function fetchLastFeaturedPreloadUpdatedAt(
  supabase: ReturnType<typeof createClient>,
): Promise<Date | null> {
  const { data, error } = await supabase
    .from("live_matches")
    .select("updated_at")
    .not("featured_event_slug", "is", null)
    .order("updated_at", { ascending: false })
    .limit(1)
    .maybeSingle()

  if (error) {
    featuredLog(`cooldown_query_error=${error.message}`)
    return null
  }

  const updatedAt = new Date(String(data?.updated_at ?? ""))
  return Number.isFinite(updatedAt.getTime()) ? updatedAt : null
}

async function fetchActiveUpcomingFeaturedEvents(
  supabase: ReturnType<typeof createClient>,
  counts: FeaturedPreloadCounts,
): Promise<FeaturedEventRow[]> {
  const today = dateOnlyString(new Date())
  const lookaheadEnd = dateOnlyString(new Date(Date.now() + FEATURED_PRELOAD_LOOKAHEAD_DAYS * 24 * 60 * 60 * 1000))
  const { data, error } = await supabase
    .from("featured_events")
    .select("slug,title,sport,include_keywords,exclude_keywords,start_date,end_date,enabled,priority")
    .eq("enabled", true)
    .gte("end_date", today)
    .lte("start_date", lookaheadEnd)
    .order("priority", { ascending: false })

  if (error || !Array.isArray(data)) {
    counts.errors += 1
    counts.featuredPreloadSkippedReason = error ? `featured_events_query:${error.message}` : "featured_events_query:invalid_response"
    featuredLog(`error=${counts.featuredPreloadSkippedReason}`)
    return []
  }

  return data
    .map(normalizeFeaturedEventRow)
    .filter((event): event is FeaturedEventRow => event !== null)
}

function normalizeFeaturedEventRow(row: any): FeaturedEventRow | null {
  const slug = cleanString(row?.slug)
  const title = cleanString(row?.title) ?? slug
  const startDate = cleanString(row?.start_date)
  const endDate = cleanString(row?.end_date)
  if (!slug || !title || !startDate || !endDate) return null
  return {
    slug,
    title,
    sport: cleanString(row?.sport),
    include_keywords: stringArray(row?.include_keywords),
    exclude_keywords: stringArray(row?.exclude_keywords),
    start_date: startDate,
    end_date: endDate,
    enabled: row?.enabled === true,
    priority: numberOrNull(row?.priority),
  }
}

function configuredFeaturedEventProviderConfigs(featuredEvent: FeaturedEventRow): FeaturedEventProviderConfig[] {
  const envSuffix = normalizedEnvKey(featuredEvent.slug)
  const leagueIds = envList(`THESPORTSDB_FEATURED_EVENT_LEAGUE_IDS_${envSuffix}`, [])
  const seasons = envList(`THESPORTSDB_FEATURED_EVENT_SEASONS_${envSuffix}`, [])
  if (leagueIds.length === 0 || seasons.length === 0) return []

  const sport = cleanString(Deno.env.get(`THESPORTSDB_FEATURED_EVENT_SPORT_${envSuffix}`)) ?? featuredEvent.sport
  const league = cleanString(Deno.env.get(`THESPORTSDB_FEATURED_EVENT_LEAGUE_NAME_${envSuffix}`))
  const configs: FeaturedEventProviderConfig[] = []
  for (const leagueId of leagueIds) {
    for (const season of seasons) {
      configs.push({ leagueId, season, sport, league })
    }
  }
  return configs
}

function featuredEventMatchesFixture(featuredEvent: FeaturedEventRow, match: LiveMatchUpsert): boolean {
  if (featuredEvent.sport && !sportMatchesFeaturedEvent(match.sport, featuredEvent.sport)) {
    return false
  }

  const searchable = normalizedFeaturedText([
    match.sport,
    match.league,
    match.home_team,
    match.away_team,
    payloadString(match.payload, "strSport"),
    payloadString(match.payload, "strLeague"),
    payloadString(match.payload, "strLeagueAlternate"),
    payloadString(match.payload, "strEvent"),
  ].join(" "))

  const includeKeywords = (featuredEvent.include_keywords ?? [])
    .map(normalizedFeaturedText)
    .filter(Boolean)
  if (includeKeywords.length === 0) return false
  if (!includeKeywords.some((keyword) => searchable.includes(keyword))) return false

  const excludeKeywords = (featuredEvent.exclude_keywords ?? [])
    .map(normalizedFeaturedText)
    .filter(Boolean)
  return !excludeKeywords.some((keyword) => searchable.includes(keyword))
}

function sportMatchesFeaturedEvent(matchSport: string, featuredSport: string): boolean {
  const lhs = normalizedFeaturedText(matchSport)
  const rhs = normalizedFeaturedText(featuredSport)
  if (!rhs) return true
  if (rhs === "soccer" || rhs === "football" || rhs === "association football") {
    return lhs === "soccer" || lhs === "football" || lhs.includes("association football")
  }
  if (rhs === "basketball") return lhs === "basketball" || lhs === "nba"
  if (rhs === "baseball") return lhs === "baseball" || lhs === "mlb"
  if (rhs === "hockey" || rhs === "ice hockey") return lhs === "hockey" || lhs === "ice hockey" || lhs === "nhl"
  if (rhs === "american football" || rhs === "football") return lhs === "american football" || lhs === "nfl"
  return lhs === rhs || lhs.includes(rhs) || rhs.includes(lhs)
}

function dedupeFeaturedMatches(matches: LiveMatchUpsert[]): LiveMatchUpsert[] {
  const latestById = new Map<string, LiveMatchUpsert>()
  for (const match of matches) {
    latestById.set(match.id, match)
  }
  return [...latestById.values()].sort((lhs, rhs) => lhs.start_time.localeCompare(rhs.start_time))
}

async function fetchRecentlyCompletedMatches(
  supabase: ReturnType<typeof createClient>,
  completedWindow: MatchWindow,
  counts: CompletedMatchesCounts,
): Promise<LiveMatchUpsert[]> {
  const apiKey = Deno.env.get("THESPORTSDB_API_KEY") ?? "123"
  const completedEvents: SportsDBCompletedEvent[] = []
  const providerCandidates = await fetchRecentCompletedProviderCandidates(supabase, completedWindow, counts)

  for (const [externalId, fallbackLeague] of providerCandidates.entries()) {
    try {
      const events = await fetchTheSportsDBLookupEvents(apiKey, externalId)
      counts.fetched += events.length
      for (const event of events) {
        completedEvents.push({
          event,
          fallbackLeague,
          syncKind: "recent_completed_lookup",
        })
      }
    } catch (error) {
      counts.errors += 1
      const message = error instanceof Error ? error.message : String(error)
      completedLog(`lookupError event=${externalId} error=${message}`)
    }
  }

  for (const leagueConfig of configuredSportsDBCompletedLeagues()) {
    try {
      const events = await fetchTheSportsDBPastLeagueEvents(apiKey, leagueConfig.id)
      counts.fetched += events.length
      counts.leagueRowsFetched += events.length
      for (const event of events) {
        completedEvents.push({
          event,
          fallbackLeague: leagueConfig.league,
          syncKind: "recent_completed_league",
        })
      }
    } catch (error) {
      counts.errors += 1
      const message = error instanceof Error ? error.message : String(error)
      completedLog(`leagueError leagueId=${leagueConfig.id} error=${message}`)
    }
  }

  const featuredEvents = await fetchActiveUpcomingFeaturedEvents(supabase, {
    featuredEventsChecked: 0,
    featuredFixturesFetched: 0,
    featuredFixturesNormalized: 0,
    featuredFixturesMatched: 0,
    featuredFixturesUpserted: 0,
    featuredPreloadSkippedReason: null,
    apiCalls: 0,
    errors: 0,
  })
  for (const featuredEvent of featuredEvents) {
    for (const config of configuredFeaturedEventProviderConfigs(featuredEvent)) {
      try {
        const events = await fetchTheSportsDBSeasonEvents(apiKey, config.leagueId, config.season)
        counts.fetched += events.length
        counts.featuredRowsFetched += events.length
        for (const event of events) {
          completedEvents.push({
            event: {
              ...event,
              fangeo_featured_event_slug: featuredEvent.slug,
            },
            fallbackLeague: config.league ?? String(event?.strLeague ?? config.leagueId),
            syncKind: "recent_completed_featured",
            featuredEvent,
          })
        }
      } catch (error) {
        counts.errors += 1
        const message = error instanceof Error ? error.message : String(error)
        completedLog(`featuredError slug=${featuredEvent.slug} leagueId=${config.leagueId} error=${message}`)
      }
    }
  }

  const normalized: LiveMatchUpsert[] = []
  for (const completedEvent of completedEvents) {
    const match = normalizeSportsDBCompletedEvent(completedEvent, completedWindow)
    if (!match) continue
    normalized.push(match)
    counts.normalized += 1
  }

  const deduped = dedupeLiveMatchUpserts(normalized)
  counts.deduped += normalized.length - deduped.length
  return deduped
}

async function fetchRecentCompletedProviderCandidates(
  supabase: ReturnType<typeof createClient>,
  completedWindow: MatchWindow,
  counts: CompletedMatchesCounts,
): Promise<Map<string, string>> {
  const candidates = new Map<string, string>()
  const savedRows = await fetchRecentCompletedCandidateRows(supabase, "saved_pro_games", completedWindow)
  counts.savedCandidateIds = addSportsDBProviderCandidates(candidates, savedRows)

  const subscriptionRows = await fetchRecentCompletedCandidateRows(supabase, "pro_game_alert_subscriptions", completedWindow)
  counts.subscriptionCandidateIds = addSportsDBProviderCandidates(candidates, subscriptionRows)
  return candidates
}

async function fetchRecentCompletedCandidateRows(
  supabase: ReturnType<typeof createClient>,
  table: "saved_pro_games" | "pro_game_alert_subscriptions",
  completedWindow: MatchWindow,
): Promise<RecentCompletedCandidateRow[]> {
  const { data, error } = await supabase
    .from(table)
    .select("live_match_id,source,external_id,league,sport,start_time")
    .gte("start_time", completedWindow.startISO)
    .lte("start_time", completedWindow.endISO)
    .limit(1000)

  if (error || !Array.isArray(data)) {
    if (error) completedLog(`candidateQueryError table=${table} error=${error.message}`)
    return []
  }
  return data as RecentCompletedCandidateRow[]
}

function addSportsDBProviderCandidates(
  candidates: Map<string, string>,
  rows: RecentCompletedCandidateRow[],
): number {
  let added = 0
  for (const row of rows) {
    const externalId = sportsDBExternalIdFromCandidate(row)
    if (!externalId || candidates.has(externalId)) continue
    candidates.set(externalId, row.league?.trim() || "Sports")
    added += 1
  }
  return added
}

function sportsDBExternalIdFromCandidate(row: RecentCompletedCandidateRow): string | null {
  const fromLiveMatchId = sportsDBExternalIdFromLiveMatchId(cleanString(row.live_match_id))
  if (fromLiveMatchId) return fromLiveMatchId

  const source = String(row.source ?? "").trim().toLowerCase()
  const externalId = String(row.external_id ?? "").trim()
  if (source === "thesportsdb" && externalId) return externalId
  return null
}

async function fetchTheSportsDBLookupEvents(apiKey: string, externalId: string): Promise<Record<string, any>[]> {
  const encodedEventId = encodeURIComponent(externalId)
  const url = `https://www.thesportsdb.com/api/v1/json/${apiKey}/lookupevent.php?id=${encodedEventId}`
  const response = await fetch(url)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const data = await response.json()
  return Array.isArray(data?.events) ? data.events : []
}

async function fetchTheSportsDBPastLeagueEvents(apiKey: string, leagueId: string): Promise<Record<string, any>[]> {
  const encodedLeagueId = encodeURIComponent(leagueId)
  const url = `https://www.thesportsdb.com/api/v1/json/${apiKey}/eventspastleague.php?id=${encodedLeagueId}`
  const response = await fetch(url)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const data = await response.json()
  return Array.isArray(data?.events) ? data.events : []
}

async function fetchTheSportsDBSeasonEvents(
  apiKey: string,
  leagueId: string,
  season: string,
): Promise<Record<string, any>[]> {
  const encodedLeagueId = encodeURIComponent(leagueId)
  const encodedSeason = encodeURIComponent(season)
  const url = `https://www.thesportsdb.com/api/v1/json/${apiKey}/eventsseason.php?id=${encodedLeagueId}&s=${encodedSeason}`
  const response = await fetch(url)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const data = await response.json()
  return Array.isArray(data?.events) ? data.events : []
}

function normalizeSportsDBCompletedEvent(
  completedEvent: SportsDBCompletedEvent,
  completedWindow: MatchWindow,
): LiveMatchUpsert | null {
  const normalized = normalizeSportsDBEvent(completedEvent.event, completedEvent.fallbackLeague)
  if (!normalized) return null
  if (normalized.match_status !== "FT") return null
  if (!isWithinMatchWindow(normalized.start_time, completedWindow)) return null
  if (completedEvent.featuredEvent && !featuredEventMatchesFixture(completedEvent.featuredEvent, normalized)) return null

  return {
    ...normalized,
    match_status: "FT",
    minute: null,
    featured_event_slug: cleanString(completedEvent.event.fangeo_featured_event_slug) ?? normalized.featured_event_slug,
    payload: {
      ...completedEvent.event,
      fangeo_sync_kind: completedEvent.syncKind,
    },
  }
}

function dedupeLiveMatchUpserts(matches: LiveMatchUpsert[]): LiveMatchUpsert[] {
  const latestById = new Map<string, LiveMatchUpsert>()
  for (const match of matches) {
    const existing = latestById.get(match.id)
    if (!existing || liveMatchUpsertPriority(match) >= liveMatchUpsertPriority(existing)) {
      latestById.set(match.id, match)
    }
  }
  return [...latestById.values()].sort((lhs, rhs) => lhs.start_time.localeCompare(rhs.start_time))
}

function liveMatchUpsertPriority(match: LiveMatchUpsert): number {
  if (match.match_status === "FT") return 4
  if (match.match_status === "LIVE" || match.match_status === "HT") return 3
  return 1
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
    featured_event_slug: null,
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
    featured_event_slug: null,
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
  const mergedIds = new Set(liveMatches.map((match) => match.id))
  const merged = [...liveMatches]

  for (const match of scheduledMatches) {
    if (mergedIds.has(match.id) || protectedMatchIds.has(match.id)) {
      counts.protectedExisting += 1
      continue
    }
    merged.push(match)
    mergedIds.add(match.id)
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

    if (shouldSkipHeavyEnrichment(match)) {
      match.tv_broadcasts = cached?.tv_broadcasts ?? match.tv_broadcasts
      match.tv_updated_at = cached?.tv_updated_at ?? match.tv_updated_at
      if (cached) counts.tvCacheHits += 1
      tvLog(`event=${match.external_id} skipped=far_future`)
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

async function enrichSavedProGamesWithTimelineEvents(
  supabase: ReturnType<typeof createClient>,
  savedTimelineCounts: SavedTimelineCounts,
): Promise<void> {
  const targets = await fetchSavedProGameTimelineTargets(supabase)
  if (targets.length === 0) {
    timelineLog("saved_pro_game_targets=0")
    return
  }

  timelineLog(`saved_pro_game_targets=${targets.length}`)

  for (const target of targets) {
    const existingLiveMatch = await fetchSavedProGameLiveMatchRow(supabase, target.savedGameId)
    const liveMatchRowFound = existingLiveMatch != null
    const existingTimelineCountBefore = Array.isArray(existingLiveMatch?.timeline_events)
      ? existingLiveMatch.timeline_events.length
      : 0
    const homeTeam = cleanString(existingLiveMatch?.home_team as string | undefined) ?? ""
    const awayTeam = cleanString(existingLiveMatch?.away_team as string | undefined) ?? ""
    const sport = cleanString(existingLiveMatch?.sport as string | undefined) ?? target.sport

    timelineLog(
      `saved_pro_game savedGameId=${target.savedGameId} providerEventIdUsedForTimeline=${target.providerEventIdUsedForTimeline} liveMatchRowFound=${liveMatchRowFound} existingTimelineCountBefore=${existingTimelineCountBefore} cacheBypassed=true`,
    )
    console.log(`[ScoringEventDebug] savedGameId=${target.savedGameId}`)
    console.log(`[ScoringEventDebug] providerEventIdUsedForTimeline=${target.providerEventIdUsedForTimeline}`)
    console.log(`[ScoringEventDebug] liveMatchExternalId=${target.liveMatchExternalId ?? "nil"}`)
    console.log(`[ScoringEventDebug] liveMatchRowFound=${liveMatchRowFound}`)
    console.log(`[ScoringEventDebug] existingTimelineCountBefore=${existingTimelineCountBefore}`)
    console.log("[ScoringEventDebug] cacheBypassed=true")

    if (!liveMatchRowFound) {
      timelineLog(`saved_pro_game savedGameId=${target.savedGameId} liveMatchRowFound=false skipReason=no_live_match_row`)
      logScoringEventDebug({
        eventId: target.providerEventIdUsedForTimeline,
        savedGameId: target.savedGameId,
        liveMatchExternalId: target.liveMatchExternalId,
        providerEventIdUsedForTimeline: target.providerEventIdUsedForTimeline,
        timelineFetched: false,
        timelineCount: 0,
        rawSample: "null",
        scoringEventsCount: 0,
        renderedSummary: "none",
        fallbackReason: "savedProGameLiveMatchMissing",
        source: "saved_pro_game",
      })
      continue
    }

    try {
      const events = await fetchSavedProGameTimelineEventsV1(target.providerEventIdUsedForTimeline)
      const updatedAt = new Date().toISOString()
      const scoringEventsCount = countScoringTimelineEvents(events, sport ?? undefined)
      const renderedSummary = buildRenderedTimelineSummary(events, sport, homeTeam, awayTeam)
      const noGoalReason = events.length > 0 && scoringEventsCount === 0
        ? diagnoseNoScoringTimelineReason(events, sport ?? undefined)
        : null

      savedTimelineCounts.savedTimelineFetched += 1
      if (events.length === 0) {
        savedTimelineCounts.savedTimelineEmpty += 1
        savedTimelineCounts.savedTimelineEmptyIds.push(target.savedGameId)
      } else if (scoringEventsCount === 0) {
        savedTimelineCounts.savedTimelineScoringEmptyIds.push(target.savedGameId)
      }

      const { error: updateError } = await supabase
        .from("live_matches")
        .update({
          external_id: target.providerEventIdUsedForTimeline,
          timeline_events: events,
          timeline_updated_at: updatedAt,
        })
        .eq("id", target.savedGameId)

      if (updateError) {
        timelineLog(
          `saved_pro_game savedGameId=${target.savedGameId} dbUpdateError=${updateError.message}`,
        )
      } else {
        savedTimelineCounts.savedTimelineUpdated += 1
        savedTimelineCounts.savedTimelineIds.push(target.savedGameId)
      }

      timelineLog(
        `saved_pro_game savedGameId=${target.savedGameId} providerEventIdUsedForTimeline=${target.providerEventIdUsedForTimeline} timelineCount=${events.length} scoringEventsCount=${scoringEventsCount} renderedSummary=${renderedSummary} dbUpdated=${updateError ? "false" : "true"}${noGoalReason ? ` noGoalReason=${noGoalReason}` : ""}`,
      )
      logScoringEventDebug({
        eventId: target.providerEventIdUsedForTimeline,
        savedGameId: target.savedGameId,
        liveMatchExternalId: target.liveMatchExternalId,
        providerEventIdUsedForTimeline: target.providerEventIdUsedForTimeline,
        timelineFetched: true,
        timelineCount: events.length,
        rawSample: scoringTimelineRawSample(events),
        scoringEventsCount,
        renderedSummary,
        fallbackReason: events.length === 0
          ? "providerTimelineMissing"
          : scoringEventsCount === 0
          ? noGoalReason ?? "noScoringEventsInTimeline"
          : null,
        source: "saved_pro_game_v1",
      })
      logScoringTimelineDebug({
        gameId: target.savedGameId,
        scoreHome: numberOrZero(existingLiveMatch?.score_home),
        scoreAway: numberOrZero(existingLiveMatch?.score_away),
        homeTeam,
        awayTeam,
        sport,
        timelineEvents: events,
      })
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      timelineLog(
        `saved_pro_game savedGameId=${target.savedGameId} providerEventIdUsedForTimeline=${target.providerEventIdUsedForTimeline} error=${message}`,
      )
      const existingEvents = Array.isArray(existingLiveMatch?.timeline_events)
        ? existingLiveMatch.timeline_events as TimelineEventRow[]
        : []
      logScoringEventDebug({
        eventId: target.providerEventIdUsedForTimeline,
        savedGameId: target.savedGameId,
        liveMatchExternalId: target.liveMatchExternalId,
        providerEventIdUsedForTimeline: target.providerEventIdUsedForTimeline,
        timelineFetched: false,
        timelineCount: existingTimelineCountBefore,
        rawSample: scoringTimelineRawSample(existingEvents),
        scoringEventsCount: countScoringTimelineEvents(existingEvents, sport ?? undefined),
        renderedSummary: buildRenderedTimelineSummary(existingEvents, sport, homeTeam, awayTeam),
        fallbackReason: "providerTimelineFetchError",
        source: "saved_pro_game_v1",
      })
    }
  }
}

async function fetchSavedProGameLiveMatchRow(
  supabase: ReturnType<typeof createClient>,
  savedGameId: string,
): Promise<Record<string, unknown> | null> {
  const { data, error } = await supabase
    .from("live_matches")
    .select("id,home_team,away_team,sport,score_home,score_away,timeline_events")
    .eq("id", savedGameId)
    .maybeSingle()

  if (error) {
    timelineLog(`saved_pro_game_live_match_lookup_error id=${savedGameId} error=${error.message}`)
    return null
  }
  if (!data || typeof data !== "object") return null
  return data as Record<string, unknown>
}

async function fetchSavedProGameTimelineEventsV1(idEvent: string): Promise<TimelineEventRow[]> {
  timelineLog(`saved_pro_game_v1_request path=/api/v1/json/redacted/lookuptimeline.php?id=${encodeURIComponent(idEvent)}`)
  return await fetchTheSportsDBV1TimelineEvents(idEvent, THE_SPORTSDB_V1_FREE_API_KEY)
}

async function fetchSavedProGameTimelineTargets(
  supabase: ReturnType<typeof createClient>,
): Promise<SavedProGameTimelineTarget[]> {
  const { data, error } = await supabase
    .from("saved_pro_games")
    .select("live_match_id,source,external_id,sport")
    .or("source.eq.thesportsdb,live_match_id.ilike.thesportsdb:%")

  if (error || !Array.isArray(data)) {
    if (error) timelineLog(`saved_pro_game_target_query_error=${error.message}`)
    return []
  }

  const targets = new Map<string, SavedProGameTimelineTarget>()
  for (const row of data) {
    const savedGameId = cleanString(row?.live_match_id)
    const providerEventIdUsedForTimeline = resolveSavedProGameProviderEventId(
      savedGameId,
      cleanString(row?.external_id),
    )
    if (!savedGameId || !providerEventIdUsedForTimeline) continue
    targets.set(savedGameId, {
      savedGameId,
      liveMatchExternalId: cleanString(row?.external_id),
      providerEventIdUsedForTimeline,
      sport: cleanString(row?.sport),
    })
  }
  return [...targets.values()]
}

function resolveSavedProGameProviderEventId(
  liveMatchId: string | null,
  externalId: string | null,
): string | null {
  const fromLiveMatchId = sportsDBExternalIdFromLiveMatchId(liveMatchId)
  if (fromLiveMatchId) return fromLiveMatchId

  const cleanedExternalId = String(externalId ?? "").trim()
  if (/^\d+$/.test(cleanedExternalId)) return cleanedExternalId
  return null
}

function sportsDBExternalIdFromLiveMatchId(liveMatchId: string | null): string | null {
  const trimmed = String(liveMatchId ?? "").trim()
  if (!trimmed.toLowerCase().startsWith("thesportsdb:")) return null
  const providerId = trimmed.split(":").pop()?.trim() ?? ""
  return /^\d+$/.test(providerId) ? providerId : null
}

function buildRenderedTimelineSummary(
  events: TimelineEventRow[],
  sport: string | null | undefined,
  homeTeam: string,
  awayTeam: string,
): string {
  const sportKind = normalizedTimelineSportKind(sport ?? undefined)
  const scoringEvents = dedupeScoringTimelineEventRows(
    events.filter((event) => isScoringTimelineEvent(event, sportKind)),
  )
  if (scoringEvents.length === 0) return "none"

  const grouped = new Map<string, string[]>()
  for (const event of scoringEvents) {
    const side = timelineEventSideForSummary(event, homeTeam, awayTeam)
    const team = side === "home" ? homeTeam : side === "away" ? awayTeam : cleanString(event.strTeam) ?? "Goals"
    const player = cleanString(event.strPlayer) ?? "unknown"
    const clock = formatTimelineMinute(event) ?? cleanString(event.intTime) ?? ""
    const marker = timelineScoringMarker(event)
    const scorerClock = [player, marker, clock].filter(Boolean).join(" ").trim()
    grouped.set(team, [...(grouped.get(team) ?? []), scorerClock])
  }

  return [...grouped.entries()]
    .map(([team, scorers]) => `${team}: ${scorers.join(", ")}`)
    .join(" | ")
}

function diagnoseNoScoringTimelineReason(events: TimelineEventRow[], sport?: string): string {
  const sportKind = normalizedTimelineSportKind(sport)
  const rowTypes = [...new Set(events.map((event) => cleanString(event.strTimeline) ?? "unknown"))]
  const hasGoalText = events.some((event) => timelineEventSearchText(event).includes("goal"))
  const hasPenaltyMiss = events.some((event) => {
    const text = timelineEventSearchText(event)
    return text.includes("penalty") && (text.includes("miss") || text.includes("saved"))
  })
  if (hasPenaltyMiss && !hasGoalText) return "onlyPenaltyMissRows"
  if (rowTypes.every((type) => ["subst", "substitution", "card", "yellow card", "red card"].includes(type.toLowerCase()))) {
    return `nonGoalRowsOnly types=${rowTypes.join(",")}`
  }
  if (sportKind === "other") return `unsupportedSportForScoring sport=${sport ?? "unknown"} types=${rowTypes.join(",")}`
  return `nonGoalRowsOnly types=${rowTypes.join(",")}`
}

function timelineEventSideForSummary(
  event: TimelineEventRow,
  homeTeam: string,
  awayTeam: string,
): "home" | "away" | null {
  const homeFlag = String(event.strHome ?? "").trim().toLowerCase()
  if (["yes", "true", "1", "home"].includes(homeFlag)) return "home"
  if (["no", "false", "0", "away"].includes(homeFlag)) return "away"

  const team = normalizedTimelineTeamText(event.strTeam)
  if (!team) return null
  if (team === normalizedTimelineTeamText(homeTeam)) return "home"
  if (team === normalizedTimelineTeamText(awayTeam)) return "away"
  return null
}

function normalizedTimelineTeamText(raw: string | null | undefined): string {
  return String(raw ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
}

function formatTimelineMinute(event: TimelineEventRow): string | null {
  const minute = cleanString(event.intTime)
  if (!minute) return null
  return minute.endsWith("'") || minute.endsWith("’") ? minute.replace("’", "'") : `${minute}'`
}

function timelineScoringMarker(event: TimelineEventRow): string | null {
  const text = timelineEventSearchText(event)
  if (text.includes("own goal")) return "(OG)"
  if (text.includes("penalty") && !text.includes("miss")) return "(P)"
  return null
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
      logScoringEventDebug({
        eventId: match.external_id,
        timelineFetched: false,
        timelineCount: match.timeline_events.length,
        rawSample: scoringTimelineRawSample(match.timeline_events),
        scoringEventsCount: countScoringTimelineEvents(match.timeline_events, match.sport),
        fallbackReason: match.timeline_events.length === 0 ? "providerTimelineMissing" : null,
        source: "cache",
      })
      continue
    }

    if (shouldSkipHeavyEnrichment(match)) {
      match.timeline_events = cached?.timeline_events ?? match.timeline_events
      match.timeline_updated_at = cached?.timeline_updated_at ?? match.timeline_updated_at
      if (cached) counts.timelineCacheHits += 1
      timelineLog(`event=${match.external_id} skipped=far_future`)
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
      logScoringEventDebug({
        eventId: match.external_id,
        timelineFetched: true,
        timelineCount: events.length,
        rawSample: scoringTimelineRawSample(events),
        scoringEventsCount: countScoringTimelineEvents(events, match.sport),
        fallbackReason: events.length === 0 ? "providerTimelineMissing" : null,
        source: sportsDBKey ? "provider" : "provider_v1",
      })
      logScoringTimelineDebug({
        gameId: match.id,
        scoreHome: match.score_home,
        scoreAway: match.score_away,
        homeTeam: match.home_team,
        awayTeam: match.away_team,
        sport: match.sport,
        timelineEvents: events,
      })
    } catch (error) {
      counts.timelineErrors += 1
      const message = error instanceof Error ? error.message : String(error)
      timelineLog(`event=${match.external_id} error=${message}`)
      match.timeline_events = cached?.timeline_events ?? []
      match.timeline_updated_at = cached?.timeline_updated_at ?? null
      logScoringEventDebug({
        eventId: match.external_id,
        timelineFetched: false,
        timelineCount: match.timeline_events?.length ?? 0,
        rawSample: scoringTimelineRawSample(match.timeline_events ?? []),
        scoringEventsCount: countScoringTimelineEvents(match.timeline_events ?? [], match.sport),
        fallbackReason: "providerTimelineFetchError",
      })
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
  const cachedEvents = Array.isArray(cache.timeline_events) ? cache.timeline_events : []
  if (
    (match.match_status === "FT" || match.match_status === "AET" || match.match_status === "PEN")
    && cachedEvents.length === 0
  ) {
    return false
  }
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

function shouldSkipHeavyEnrichment(match: LiveMatchUpsert): boolean {
  if (match.match_status !== "SCHEDULED") return false
  const startTime = new Date(match.start_time).getTime()
  return Number.isFinite(startTime) && startTime > Date.now() + HEAVY_ENRICHMENT_LOOKAHEAD_MS
}

async function fetchTheSportsDBTimelineEvents(
  idEvent: string,
  apiKey: string | undefined,
): Promise<TimelineEventRow[]> {
  if (apiKey) {
    try {
      const v2Events = await fetchTheSportsDBV2TimelineEvents(idEvent, apiKey)
      if (v2Events.length > 0) return v2Events
      timelineLog(`v2_empty event=${idEvent} falling_back=v1 path=/api/v1/json/redacted/lookuptimeline.php?id=${encodeURIComponent(idEvent)}`)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      timelineLog(`v2_failed event=${idEvent} error=${message} falling_back=v1 path=/api/v1/json/redacted/lookuptimeline.php?id=${encodeURIComponent(idEvent)}`)
    }
  }
  return await fetchTheSportsDBV1TimelineEvents(idEvent, THE_SPORTSDB_V1_FREE_API_KEY)
}

async function fetchTheSportsDBV2TimelineEvents(idEvent: string, apiKey: string): Promise<TimelineEventRow[]> {
  const url = `${THESPORTSDB_V2_BASE}/lookup/event_timeline/${encodeURIComponent(idEvent)}`
  timelineLog(`v2_request path=/api/v2/json/lookup/event_timeline/${encodeURIComponent(idEvent)}`)
  const response = await fetch(url, {
    headers: { "X-API-KEY": apiKey },
  })
  if (!response.ok) throw new Error(`v2 HTTP ${response.status}`)
  const data = await response.json()
  return normalizeTimelineEventRows(data, idEvent)
}

async function fetchTheSportsDBV1TimelineEvents(
  idEvent: string,
  apiKey: string = THE_SPORTSDB_V1_FREE_API_KEY,
): Promise<TimelineEventRow[]> {
  const url = `https://www.thesportsdb.com/api/v1/json/${apiKey}/lookuptimeline.php?id=${encodeURIComponent(idEvent)}`
  timelineLog(`v1_request path=/api/v1/json/redacted/lookuptimeline.php?id=${encodeURIComponent(idEvent)}`)
  const response = await fetch(url)
  if (!response.ok) throw new Error(`v1 HTTP ${response.status}`)
  const data = await response.json()
  if (data && typeof data === "object" && typeof (data as Record<string, unknown>).Message === "string") {
    throw new Error(`v1 provider error: ${(data as Record<string, unknown>).Message}`)
  }
  return normalizeTimelineEventRows(data, idEvent)
}

function normalizeTimelineEventRows(data: unknown, fallbackEventId: string): TimelineEventRow[] {
  const rows = extractTimelineEventRows(data)
  const normalized = rows
    .map((row) => normalizeTimelineEventRow(row, fallbackEventId))
    .filter(isTimelineEventRow)
  return dedupeScoringTimelineEventRows(dedupeTimelineEventRows(normalized))
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

function dedupeTimelineEventRows(rows: TimelineEventRow[]): TimelineEventRow[] {
  const seen = new Set<string>()
  const deduped: TimelineEventRow[] = []
  for (const row of rows) {
    const providerId = cleanString(row.idTimeline)
    const key = providerId
      ? `provider:${providerId}`
      : [
        "fallback",
        row.idEvent,
        row.strTimeline,
        row.strTimelineDetail,
        row.strPlayer,
        row.strTeam,
        row.intTime,
      ].map((value) => cleanString(value) ?? "").join("|")
    if (seen.has(key)) continue
    seen.add(key)
    deduped.push(row)
  }
  return deduped
}

function dedupeScoringTimelineEventRows(rows: TimelineEventRow[]): TimelineEventRow[] {
  const seen = new Set<string>()
  const deduped: TimelineEventRow[] = []

  for (const row of rows) {
    if (!isScoringTimelineEvent(row)) {
      deduped.push(row)
      continue
    }

    const key = scoringTimelineDedupeKey(row)
    if (seen.has(key)) {
      timelineLog(
        `scoring_duplicate_removed player=${cleanString(row.strPlayer) ?? "unknown"} minute=${cleanString(row.intTime) ?? "unknown"} team=${cleanString(row.strTeam) ?? "unknown"} eventType=${cleanString(row.strTimeline) ?? cleanString(row.strTimelineDetail) ?? "unknown"}`,
      )
      continue
    }

    seen.add(key)
    deduped.push(row)
  }

  return deduped
}

function scoringTimelineDedupeKey(event: TimelineEventRow): string {
  const team = normalizeTimelineTeamKey(event.strTeam)
  const player = normalizeTimelineTeamKey(event.strPlayer)
  const minute = cleanString(event.intTime) ?? ""
  return `${team}|${player}|${minute}`
}

function normalizeTimelineTeamKey(value: string | null | undefined): string {
  return String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
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
      .or(`and(start_time.lt.${matchWindow.startISO},match_status.neq.FT),and(start_time.lt.${matchWindow.startISO},match_status.eq.FT,updated_at.lt.${new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()}),start_time.gt.${matchWindow.endISO}`)
      .is("featured_event_slug", null)

    if (deleteError) throw deleteError
    return count ?? 0
  }
  return typeof data === "number" ? data : 0
}

function currentMatchWindow(now = new Date()): MatchWindow {
  const start = new Date(now.getTime() - 24 * 60 * 60 * 1000)
  const end = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000)
  return {
    start,
    end,
    startISO: start.toISOString(),
    endISO: end.toISOString(),
  }
}

function recentCompletedMatchWindow(now = new Date()): MatchWindow {
  const start = new Date(now.getTime() - 14 * 24 * 60 * 60 * 1000)
  const end = new Date(now.getTime() + 15 * 60 * 1000)
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

function configuredSportsDBCompletedLeagues(): ScheduledLeagueConfig[] {
  const configuredIds = envList("THESPORTSDB_COMPLETED_LEAGUE_IDS", [])
  const ids = configuredIds.length > 0 ? configuredIds : configuredSportsDBUpcomingLeagueIds()
  const byId = new Map(configuredSportsDBScheduledLeagues().map((config) => [config.id, config]))
  return uniqueStrings(ids).map((id) => byId.get(id) ?? { id, sport: "Sports", league: id })
}

function uniqueStrings(values: string[]): string[] {
  return [...new Set(values.map((value) => value.trim()).filter(Boolean))]
}

function envList(name: string, fallback: string[]): string[] {
  const configured = Deno.env.get(name)
  const values = configured?.split(",").map((value) => value.trim()).filter(Boolean)
  return values && values.length > 0 ? values : fallback
}

function normalizedEnvKey(raw: string): string {
  return raw
    .trim()
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
}

function stringArray(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.map((entry) => String(entry ?? "").trim()).filter(Boolean)
  }
  const raw = String(value ?? "").trim()
  if (!raw) return []
  return raw.split(",").map((entry) => entry.trim()).filter(Boolean)
}

function dateOnlyString(date: Date): string {
  return date.toISOString().slice(0, 10)
}

function parseDateOnly(raw: string): Date | null {
  const date = new Date(`${raw.slice(0, 10)}T00:00:00Z`)
  return Number.isFinite(date.getTime()) ? date : null
}

function endOfDateOnly(raw: string): Date | null {
  const start = parseDateOnly(raw)
  if (!start) return null
  return new Date(start.getTime() + 24 * 60 * 60 * 1000 - 1)
}

function normalizedFeaturedText(raw: string): string {
  return raw
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
}

function payloadString(payload: unknown, key: string): string {
  if (!payload || typeof payload !== "object") return ""
  const value = (payload as Record<string, unknown>)[key]
  return String(value ?? "")
}

function isWithinMatchWindow(rawStart: string, matchWindow: MatchWindow): boolean {
  const start = new Date(rawStart)
  return Number.isFinite(start.getTime()) && start >= matchWindow.start && start <= matchWindow.end
}

function normalizeSportsDBStatus(raw: unknown): MatchStatus {
  const status = String(raw ?? "").trim().toUpperCase()
  const compact = status.replace(/[_-]+/g, " ")
  if (compact.includes("HALF") || compact === "HT") return "HT"
  if (
    compact.includes("FT") ||
    compact.includes("FINAL") ||
    compact.includes("FINISHED") ||
    compact.includes("COMPLETED") ||
    compact.includes("COMPLETE") ||
    compact.includes("ENDED") ||
    compact.includes("FULL TIME") ||
    compact.includes("AFTER FULL TIME") ||
    compact.includes("AFTER EXTRA TIME") ||
    compact.includes("PENALTIES FINISHED")
  ) return "FT"
  if (["1H", "2H", "ET", "BT", "P", "OT", "Q1", "Q2", "Q3", "Q4", "LIVE"].includes(status)) return "LIVE"
  if (
    compact.includes("LIVE") ||
    compact.includes("INPLAY") ||
    compact.includes("IN PROGRESS") ||
    compact.includes("IN PLAY") ||
    compact.includes("PLAYING") ||
    compact.includes("ACTIVE") ||
    compact.includes("STARTED") ||
    compact.includes("EXTRA INNING") ||
    compact.includes("'") ||
    compact.includes("Q") ||
    compact.includes("PERIOD") ||
    compact.includes("INNING")
  ) {
    return "LIVE"
  }
  if (compact === "NS" || compact.includes("SCHED") || compact.includes("NOT STARTED")) return "SCHEDULED"
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

function featuredLog(message: string): void {
  console.log(`[FeaturedFixturesSync] ${message}`)
}

function tvLog(message: string): void {
  console.log(`[TheSportsDBTV] ${message}`)
}

function timelineLog(message: string): void {
  console.log(`[TheSportsDBTimeline] ${message}`)
}

function logScoringTimelineDebug(input: {
  gameId: string
  scoreHome: number
  scoreAway: number
  homeTeam: string
  awayTeam: string
  sport?: string | null
  timelineEvents: TimelineEventRow[]
}): void {
  const sportKind = normalizedTimelineSportKind(input.sport ?? undefined)
  const rawGoalEvents = input.timelineEvents.filter((event) => isScoringTimelineEvent(event, sportKind))
  const dedupedGoalEvents = dedupeScoringTimelineEventRows(rawGoalEvents)
  const duplicatesRemoved = rawGoalEvents.length - dedupedGoalEvents.length

  console.log(`[ScoringTimelineDebug] gameId=${input.gameId}`)
  console.log(`[ScoringTimelineDebug] scoreHome=${input.scoreHome}`)
  console.log(`[ScoringTimelineDebug] scoreAway=${input.scoreAway}`)
  console.log(`[ScoringTimelineDebug] timelineCount=${input.timelineEvents.length}`)
  console.log(`[ScoringTimelineDebug] goalEventCount=${dedupedGoalEvents.length}`)
  if (duplicatesRemoved > 0) {
    console.log(`[ScoringTimelineDebug] duplicatesRemoved=${duplicatesRemoved}`)
  }

  for (const event of rawGoalEvents) {
    const team = cleanString(event.strTeam) ?? "unknown"
    const player = cleanString(event.strPlayer) ?? "unknown"
    const minute = cleanString(event.intTime) ?? "unknown"
    const eventType = cleanString(event.strTimeline) ?? cleanString(event.strTimelineDetail) ?? "unknown"
    console.log(
      `[ScoringTimelineDebug] player=${player} minute=${minute} team=${team} eventType=${eventType}`,
    )
  }

  for (const event of dedupedGoalEvents) {
    const team = cleanString(event.strTeam) ?? "unknown"
    const player = cleanString(event.strPlayer) ?? "unknown"
    const minute = cleanString(event.intTime) ?? "unknown"
    console.log(
      `[ScoringTimelineDebug] rendered player=${player} minute=${minute} team=${team}`,
    )
  }
}

function logScoringEventDebug(input: {
  eventId: string
  savedGameId?: string
  liveMatchExternalId?: string | null
  providerEventIdUsedForTimeline?: string
  timelineFetched: boolean
  timelineCount: number
  rawSample: string
  scoringEventsCount: number
  renderedSummary?: string
  fallbackReason: string | null
  source?: string
}): void {
  console.log("[ScoringEventDebug] provider=TheSportsDB")
  if (input.savedGameId) {
    console.log(`[ScoringEventDebug] savedGameId=${input.savedGameId}`)
    console.log(`[LiveScoringEventDebug] gameId=${input.savedGameId}`)
  }
  if (input.liveMatchExternalId !== undefined) {
    console.log(`[ScoringEventDebug] liveMatchExternalId=${input.liveMatchExternalId ?? "nil"}`)
  }
  if (input.providerEventIdUsedForTimeline) {
    console.log(`[ScoringEventDebug] providerEventIdUsedForTimeline=${input.providerEventIdUsedForTimeline}`)
  }
  console.log(`[ScoringEventDebug] eventId=${input.eventId}`)
  console.log(`[ScoringEventDebug] timelineFetched=${input.timelineFetched}`)
  if (input.source) {
    console.log(`[ScoringEventDebug] timelineSource=${input.source}`)
  }
  console.log(`[ScoringEventDebug] timelineCount=${input.timelineCount}`)
  console.log(`[LiveScoringEventDebug] timelineCount=${input.timelineCount}`)
  console.log(`[ScoringEventDebug] rawSample=${input.rawSample}`)
  console.log(`[ScoringEventDebug] scoringEventsCount=${input.scoringEventsCount}`)
  console.log(`[LiveScoringEventDebug] scoringEventsCount=${input.scoringEventsCount}`)
  const renderedSummary = input.renderedSummary ?? "none"
  console.log(`[LiveScoringEventDebug] renderedSummary=${renderedSummary}`)
  console.log(`[ScoringEventDebug] fallbackReason=${input.fallbackReason ?? "none"}`)
  console.log(`[LiveScoringEventDebug] fallbackReason=${input.fallbackReason ?? "none"}`)
}

function scoringTimelineRawSample(events: TimelineEventRow[]): string {
  const scoring = events.find((event) => isScoringTimelineEvent(event))
  const sample = scoring ?? events[0]
  if (!sample) return "null"
  return rawPreview(JSON.stringify(sample), 900)
}

function countScoringTimelineEvents(events: TimelineEventRow[], sport?: string): number {
  const sportKind = normalizedTimelineSportKind(sport)
  const scoringEvents = events.filter((event) => isScoringTimelineEvent(event, sportKind))
  return dedupeScoringTimelineEventRows(scoringEvents).length
}

function normalizedTimelineSportKind(sport?: string): "soccer" | "hockey" | "other" {
  const normalized = String(sport ?? "")
    .trim()
    .toLowerCase()
  if (normalized.includes("hockey") || normalized === "nhl") return "hockey"
  if (normalized.includes("soccer") || normalized.includes("football")) return "soccer"
  return "other"
}

function isScoringTimelineEvent(
  event: TimelineEventRow,
  sportKind: "soccer" | "hockey" | "other" = "soccer",
): boolean {
  const text = timelineEventSearchText(event)
  if (text.includes("miss") || text.includes("saved")) return false
  if (sportKind === "hockey") {
    return text.includes("goal")
  }
  if (sportKind === "other") {
    return text.includes("goal") || text.includes("score")
  }
  return text.includes("goal") || (text.includes("penalty") && !text.includes("missed"))
}

function timelineEventSearchText(event: TimelineEventRow): string {
  return [
    event.strTimeline,
    event.strTimelineDetail,
    event.strComment,
    event.strPlayer,
    event.strTeam,
    event.intTime,
  ]
    .map((value) => String(value ?? "").trim().toLowerCase())
    .filter(Boolean)
    .join(" ")
}

function completedLog(message: string): void {
  console.log(`[SyncLiveMatchesDebug] ${message}`)
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
