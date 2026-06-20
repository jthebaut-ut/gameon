// Manual test: curl -X POST "$SUPABASE_URL/functions/v1/sync-live-matches" \
//   -H "Authorization: Bearer $SUPABASE_ANON_KEY" -H "Content-Type: application/json"
// Deploy: supabase functions deploy sync-live-matches

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import { followedCatalogTeamIdsForMatch } from "./favorite-team-live-matcher.ts"

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

type TimelineFetchResult = {
  events: TimelineEventRow[]
  timelineEndpoint: string
  httpStatus: number | null
  rawTimelineResponse: string
  source: string
  providerEventId: string
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
  source: string | null
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
const LIVE_TIMELINE_ACTIVE_FOLLOWER_CACHE_TTL_MS = 60 * 1000
const LIVE_TIMELINE_DEFAULT_CACHE_TTL_MS = 3 * 60 * 1000
const NON_LIVE_TIMELINE_CACHE_TTL_MS = 6 * 60 * 60 * 1000
const MAX_TIMELINE_ACTIVE_FOLLOWER_MATCHES = 200
const MAX_TIMELINE_LOOKUP_KEYS = 800
const TIMELINE_LOOKUP_BATCH_SIZE = 200

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
    const requestBody = await req.json().catch(() => ({} as Record<string, unknown>))
    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    })

    const debugTimelineEventId = cleanString(requestBody?.debugTimelineEventId)
    if (debugTimelineEventId) {
      const sportsDBKey = Deno.env.get("THESPORTSDB_API_KEY")?.trim()
      const { data: row } = await supabase
        .from("live_matches")
        .select("id,external_id,home_team,away_team,sport,payload")
        .eq("source", "thesportsdb")
        .eq("external_id", debugTimelineEventId)
        .maybeSingle()

      const v2Result = sportsDBKey
        ? await fetchTheSportsDBV2TimelineEvents(debugTimelineEventId, sportsDBKey)
        : null
      const fetchResult = await fetchTimelineEventsForMatch({
        providerEventId: debugTimelineEventId,
        sportsDBKey,
        payload: row?.payload,
        homeTeam: cleanString(row?.home_team) ?? "",
        awayTeam: cleanString(row?.away_team) ?? "",
        sport: cleanString(row?.sport),
      })
      const apiFootballFixtureId = await resolveApiFootballFixtureIdForTimeline(
        debugTimelineEventId,
        row?.payload,
        sportsDBKey,
      )
      const apiFootballKey = Deno.env.get("API_FOOTBALL_KEY")?.trim()
      let apiFootballResult: TimelineFetchResult | null = null
      if (apiFootballFixtureId && apiFootballKey) {
        apiFootballResult = await fetchApiFootballTimelineEvents({
          fixtureId: apiFootballFixtureId,
          fallbackEventId: debugTimelineEventId,
          homeTeam: cleanString(row?.home_team) ?? "",
          awayTeam: cleanString(row?.away_team) ?? "",
          apiKey: apiFootballKey,
        })
      }

      return json({
        success: true,
        debugTimelineEventId,
        liveMatchId: cleanString(row?.id),
        sport: cleanString(row?.sport),
        timelineCount: fetchResult.events.length,
        scoringEventsCount: countScoringTimelineEvents(fetchResult.events, cleanString(row?.sport) ?? undefined),
        apiFootballFixtureId,
        apiFootballTimelineCount: apiFootballResult?.events.length ?? 0,
        v2Result,
        fetchResult,
        apiFootballResult,
      })
    }

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
    omitEmptyTimelineFieldsForUpsert(matchesToUpsert)
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
    await hydrateEmptyCompletedMatchTimelines(supabase, savedTimelineCounts)

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
    const existingLiveMatch = await fetchSavedProGameLiveMatchRow(
      supabase,
      target.savedGameId,
      target.source,
      target.liveMatchExternalId,
    )
    const liveMatchRowFound = existingLiveMatch != null
    const resolvedLiveMatchId = cleanString(existingLiveMatch?.id as string | undefined) ?? target.savedGameId
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
      const sportsDBKey = Deno.env.get("THESPORTSDB_API_KEY")?.trim()
      const matchStatus = cleanString(existingLiveMatch?.match_status as string | undefined) as MatchStatus | null
      const fetchResult = await fetchTimelineEventsForMatch({
        providerEventId: target.providerEventIdUsedForTimeline,
        sportsDBKey,
        payload: existingLiveMatch?.payload,
        homeTeam,
        awayTeam,
        sport,
        matchStatus,
        scoreHome: numberOrZero(existingLiveMatch?.score_home),
        scoreAway: numberOrZero(existingLiveMatch?.score_away),
        minute: numberOrNull(existingLiveMatch?.minute),
      })
      const events = mergeFetchedTimelineWithExisting(
        fetchResult.events,
        Array.isArray(existingLiveMatch?.timeline_events)
          ? existingLiveMatch.timeline_events as TimelineEventRow[]
          : [],
        target.providerEventIdUsedForTimeline,
        homeTeam,
        awayTeam,
        sport ?? undefined,
      )
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

      let updateSucceeded = false
      if (events.length > 0) {
        const { error: updateError } = await supabase
          .from("live_matches")
          .update({
            timeline_events: events,
            timeline_updated_at: updatedAt,
          })
          .eq("id", resolvedLiveMatchId)

        if (updateError) {
          timelineLog(
            `saved_pro_game savedGameId=${target.savedGameId} dbUpdateError=${updateError.message}`,
          )
        } else {
          updateSucceeded = true
          savedTimelineCounts.savedTimelineUpdated += 1
          savedTimelineCounts.savedTimelineIds.push(target.savedGameId)
        }
      } else {
        timelineLog(
          `saved_pro_game savedGameId=${target.savedGameId} skipReason=providerTimelineEmpty preserveExistingTimeline=true`,
        )
      }

      timelineLog(
        `saved_pro_game savedGameId=${target.savedGameId} providerEventIdUsedForTimeline=${target.providerEventIdUsedForTimeline} timelineCount=${events.length} scoringEventsCount=${scoringEventsCount} renderedSummary=${renderedSummary} dbUpdated=${updateSucceeded}${noGoalReason ? ` noGoalReason=${noGoalReason}` : ""}`,
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
        cardEventsCount: countCardTimelineEvents(events),
        timelineEvents: events,
        renderedSummary,
        fallbackReason: events.length === 0
          ? "providerTimelineMissing"
          : scoringEventsCount === 0
          ? noGoalReason ?? "noScoringEventsInTimeline"
          : null,
        source: fetchResult.source,
        providerEventId: fetchResult.providerEventId,
        timelineEndpoint: fetchResult.timelineEndpoint,
        httpStatus: fetchResult.httpStatus,
        rawTimelineResponse: fetchResult.rawTimelineResponse,
        updateLiveMatchId: resolvedLiveMatchId,
        updateSucceeded,
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
        source: "saved_pro_game",
        providerEventId: target.providerEventIdUsedForTimeline,
        timelineEndpoint: "error",
        httpStatus: null,
        rawTimelineResponse: message,
        updateLiveMatchId: resolvedLiveMatchId,
        updateSucceeded: false,
      })
    }
  }
}

async function fetchSavedProGameLiveMatchRow(
  supabase: ReturnType<typeof createClient>,
  savedGameId: string,
  source?: string | null,
  externalId?: string | null,
): Promise<Record<string, unknown> | null> {
  const selectColumns = "id,source,external_id,home_team,away_team,sport,score_home,score_away,timeline_events,timeline_updated_at,match_status,payload"

  const byId = await supabase
    .from("live_matches")
    .select(selectColumns)
    .eq("id", savedGameId)
    .maybeSingle()

  if (byId.error) {
    timelineLog(`saved_pro_game_live_match_lookup_error id=${savedGameId} error=${byId.error.message}`)
  } else if (byId.data && typeof byId.data === "object") {
    timelineLog(`saved_pro_game_live_match_lookup matchedBy=directId id=${savedGameId}`)
    return byId.data as Record<string, unknown>
  }

  const providerId = resolveSavedProGameProviderEventId(savedGameId, externalId ?? null)
  const normalizedSource = cleanString(source) ?? "thesportsdb"
  if (providerId) {
    const byExternal = await supabase
      .from("live_matches")
      .select(selectColumns)
      .eq("source", normalizedSource)
      .eq("external_id", providerId)
      .maybeSingle()

    if (byExternal.error) {
      timelineLog(`saved_pro_game_live_match_lookup_error source=${normalizedSource} externalId=${providerId} error=${byExternal.error.message}`)
    } else if (byExternal.data && typeof byExternal.data === "object") {
      timelineLog(`saved_pro_game_live_match_lookup matchedBy=directExternalId source=${normalizedSource} externalId=${providerId}`)
      return byExternal.data as Record<string, unknown>
    }
  }

  timelineLog(`saved_pro_game_live_match_lookup matchedBy=none savedGameId=${savedGameId}`)
  return null
}

async function fetchTimelineEventsForMatch(input: {
  providerEventId: string
  sportsDBKey?: string
  payload?: unknown
  homeTeam?: string
  awayTeam?: string
  sport?: string | null
  matchStatus?: MatchStatus | string | null
  scoreHome?: number | null
  scoreAway?: number | null
  minute?: number | null
}): Promise<TimelineFetchResult> {
  const homeTeam = input.homeTeam ?? ""
  const awayTeam = input.awayTeam ?? ""
  const primary = await fetchTheSportsDBTimelineEvents(input.providerEventId, input.sportsDBKey)
  let mergedEvents = finalizeTimelineEventRows(primary.events, input.providerEventId, homeTeam, awayTeam)
  let source = primary.source
  let timelineEndpoint = primary.timelineEndpoint
  let httpStatus = primary.httpStatus
  let rawTimelineResponse = primary.rawTimelineResponse

  const shouldMergeApiFootball = shouldFetchApiFootballTimelineMerge(input, mergedEvents)
  const shouldFallbackEmpty = mergedEvents.length === 0 && shouldUseApiFootballTimelineFallback(input.sport)

  if (shouldMergeApiFootball || shouldFallbackEmpty) {
    const providerCallReason = shouldMergeApiFootball ? "cards-merge" : "empty-timeline-fallback"
    const apiFootball = await fetchApiFootballTimelineIfConfigured({
      ...input,
      providerCallReason,
    })
    if (apiFootball && apiFootball.events.length > 0) {
      const apiEvents = finalizeTimelineEventRows(
        apiFootball.events,
        input.providerEventId,
        homeTeam,
        awayTeam,
      )
      mergedEvents = mergeAndDedupeTimelineEvents(
        mergedEvents,
        apiEvents,
        input.providerEventId,
        homeTeam,
        awayTeam,
      )
      source = mergedEvents.length > 0 && primary.events.length > 0
        ? "thesportsdb+api_football"
        : apiFootball.source
      timelineEndpoint = `${primary.timelineEndpoint}+${apiFootball.timelineEndpoint}`
      httpStatus = apiFootball.httpStatus ?? httpStatus
      rawTimelineResponse = rawPreview(
        JSON.stringify({
          thesportsdb: primary.rawTimelineResponse,
          apiFootball: apiFootball.rawTimelineResponse,
        }),
      )
      timelineLog(
        `timeline_merged providerEventId=${input.providerEventId} thesportsdbCount=${primary.events.length} apiFootballCount=${apiFootball.events.length} mergedCount=${mergedEvents.length} cardCount=${countCardTimelineEvents(mergedEvents)}`,
      )
    } else if (shouldFallbackEmpty) {
      timelineLog(
        `timeline_fallback_skipped providerEventId=${input.providerEventId} apiFootballFixtureId=${apiFootball?.fixtureId ?? "nil"} apiFootballKey=${Deno.env.get("API_FOOTBALL_KEY")?.trim() ? "present" : "missing"}`,
      )
    }
  } else if (!shouldUseApiFootballTimelineFallback(input.sport) && mergedEvents.length === 0) {
    timelineLog(
      `timeline_fallback_skipped providerEventId=${input.providerEventId} reason=non_soccer sport=${input.sport ?? "nil"}`,
    )
  }

  return {
    events: mergedEvents,
    timelineEndpoint,
    httpStatus,
    rawTimelineResponse,
    source,
    providerEventId: input.providerEventId,
  }
}

async function fetchApiFootballTimelineIfConfigured(input: {
  providerEventId: string
  sportsDBKey?: string
  payload?: unknown
  homeTeam?: string
  awayTeam?: string
  sport?: string | null
  providerCallReason?: string
}): Promise<(TimelineFetchResult & { fixtureId: string | null }) | null> {
  if (!shouldUseApiFootballTimelineFallback(input.sport)) return null

  const fixtureId = await resolveApiFootballFixtureIdForTimeline(
    input.providerEventId,
    input.payload,
    input.sportsDBKey,
  )
  const apiFootballKey = Deno.env.get("API_FOOTBALL_KEY")?.trim()
  if (!fixtureId || !apiFootballKey) {
    return { events: [], timelineEndpoint: "api_football_skipped", httpStatus: null, rawTimelineResponse: "skipped", source: "api_football_skipped", providerEventId: input.providerEventId, fixtureId }
  }

  console.log(
    `[ProviderCallDebug] provider=api-football reason=${input.providerCallReason ?? "timeline-fetch"} gameId=${input.providerEventId}`,
  )
  timelineLog(
    `timeline_fallback=api_football providerEventId=${input.providerEventId} fixtureId=${fixtureId}`,
  )
  try {
    const fallback = await fetchApiFootballTimelineEvents({
      fixtureId,
      fallbackEventId: input.providerEventId,
      homeTeam: input.homeTeam ?? "",
      awayTeam: input.awayTeam ?? "",
      apiKey: apiFootballKey,
    })
    return { ...fallback, fixtureId }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    timelineLog(`timeline_fallback_error providerEventId=${input.providerEventId} error=${message}`)
    return { events: [], timelineEndpoint: "api_football_error", httpStatus: null, rawTimelineResponse: message, source: "api_football_error", providerEventId: input.providerEventId, fixtureId }
  }
}

function shouldFetchApiFootballTimelineMerge(
  input: {
    sport?: string | null
    matchStatus?: MatchStatus | string | null
    scoreHome?: number | null
    scoreAway?: number | null
  },
  events: TimelineEventRow[],
): boolean {
  if (!shouldUseApiFootballTimelineFallback(input.sport)) return false

  const status = String(input.matchStatus ?? "").trim().toUpperCase()
  if (status === "LIVE" || status === "HT") return true
  if (timelineHasGoalsWithoutCards(events, input.sport ?? undefined)) return true
  if (timelineAppearsPartial(events, input)) return true
  return false
}

function timelineHasGoalsWithoutCards(events: TimelineEventRow[], sport?: string): boolean {
  const scoringCount = countScoringTimelineEvents(events, sport)
  if (scoringCount === 0) return false
  return countCardTimelineEvents(events) === 0
}

function timelineAppearsPartial(
  events: TimelineEventRow[],
  input: {
    sport?: string | null
    scoreHome?: number | null
    scoreAway?: number | null
  },
): boolean {
  const totalGoals = numberOrZero(input.scoreHome) + numberOrZero(input.scoreAway)
  if (totalGoals <= 0) return false
  const scoringCount = countScoringTimelineEvents(events, input.sport ?? undefined)
  return scoringCount < totalGoals
}

function countCardTimelineEvents(events: TimelineEventRow[]): number {
  return dedupeTimelineEventRowsByStableIdentity(
    events.filter(isCardTimelineEvent),
    events[0]?.idEvent ?? "unknown",
  ).length
}

function isCardTimelineEvent(event: TimelineEventRow): boolean {
  const text = timelineEventSearchText(event)
  if (!text) return false
  if (text.includes("second yellow") || text.includes("yellow-red") || text.includes("yellow red") || text.includes("2nd yellow")) {
    return true
  }
  if (text.includes("yellow card") || text.includes("yellowcard") || text.includes("booking")) {
    return true
  }
  if (text.includes("red card") || text.includes("redcard") || text.includes("sent off")) {
    return true
  }
  return text.includes("card") && (text.includes("yellow") || text.includes("red"))
}

function timelineEventTypeToken(row: TimelineEventRow): string {
  const text = timelineEventSearchText(row)
  if (isCardTimelineEvent(row)) {
    if (text.includes("second yellow") || text.includes("yellow-red") || text.includes("yellow red") || text.includes("2nd yellow")) {
      return "second_yellow"
    }
    if (text.includes("red card") || text.includes("redcard") || text.includes("sent off")) {
      return "red"
    }
    if (text.includes("yellow card") || text.includes("yellowcard") || text.includes("booking")) {
      return "yellow"
    }
    return "card"
  }
  if (isScoringTimelineEvent(row)) return "goal"
  return cleanString(row.strTimeline) ?? cleanString(row.strTimelineDetail) ?? "event"
}

function stableTimelineEventIdentityKey(row: TimelineEventRow, gameId: string): string {
  const minute = cleanString(row.intTime) ?? ""
  const team = normalizeTimelineTeamKey(row.strTeam)
  const player = normalizeTimelineTeamKey(row.strPlayer)
  return [gameId, minute, timelineEventTypeToken(row), team, player].join("|")
}

function mergeAndDedupeTimelineEvents(
  primary: TimelineEventRow[],
  secondary: TimelineEventRow[],
  gameId: string,
  homeTeam: string,
  awayTeam: string,
): TimelineEventRow[] {
  const combined = [
    ...enrichCardTimelineRows(primary, homeTeam, awayTeam),
    ...enrichCardTimelineRows(secondary, homeTeam, awayTeam),
  ]
  return finalizeTimelineEventRows(combined, gameId, homeTeam, awayTeam)
}

function finalizeTimelineEventRows(
  rows: TimelineEventRow[],
  gameId: string,
  homeTeam: string,
  awayTeam: string,
): TimelineEventRow[] {
  const enriched = enrichCardTimelineRows(rows, homeTeam, awayTeam)
  const deduped = dedupeTimelineEventRowsByStableIdentity(enriched, gameId)
  return dedupeScoringTimelineEventRows(dedupeTimelineEventRows(deduped))
}

function dedupeTimelineEventRowsByStableIdentity(rows: TimelineEventRow[], gameId: string): TimelineEventRow[] {
  const seen = new Set<string>()
  const deduped: TimelineEventRow[] = []
  for (const row of rows) {
    const key = stableTimelineEventIdentityKey(row, gameId)
    if (seen.has(key)) continue
    seen.add(key)
    deduped.push(row)
  }
  return deduped
}

function enrichCardTimelineRows(
  rows: TimelineEventRow[],
  homeTeam: string,
  awayTeam: string,
): TimelineEventRow[] {
  return rows.map((row) => enrichCardTimelineRow(row, homeTeam, awayTeam))
}

function enrichCardTimelineRow(
  row: TimelineEventRow,
  homeTeam: string,
  awayTeam: string,
): TimelineEventRow {
  if (!isCardTimelineEvent(row)) return row
  const existingTeam = cleanString(row.strTeam)
  if (existingTeam) return row

  const homeFlag = String(row.strHome ?? "").trim().toLowerCase()
  if (["yes", "true", "1", "home"].includes(homeFlag) && homeTeam) {
    return { ...row, strTeam: homeTeam }
  }
  if (["no", "false", "0", "away"].includes(homeFlag) && awayTeam) {
    return { ...row, strTeam: awayTeam }
  }
  return row
}

function preserveCachedCardTimelineEvents(
  cachedEvents: TimelineEventRow[],
  mergedEvents: TimelineEventRow[],
  gameId: string,
  homeTeam: string,
  awayTeam: string,
): TimelineEventRow[] {
  const cachedCards = cachedEvents.filter(isCardTimelineEvent)
  if (cachedCards.length === 0) return mergedEvents

  const mergedCardKeys = new Set(
    mergedEvents
      .filter(isCardTimelineEvent)
      .map((row) => stableTimelineEventIdentityKey(row, gameId)),
  )
  const missingCards = cachedCards.filter((row) => {
    const key = stableTimelineEventIdentityKey(row, gameId)
    return !mergedCardKeys.has(key)
  })
  if (missingCards.length === 0) return mergedEvents

  timelineLog(
    `timeline_preserve_cached_cards gameId=${gameId} cachedCardCount=${cachedCards.length} restoredMissingCards=${missingCards.length}`,
  )
  return mergeAndDedupeTimelineEvents(mergedEvents, missingCards, gameId, homeTeam, awayTeam)
}

function timelineRichnessScore(events: TimelineEventRow[], sport?: string): number {
  const scoringCount = countScoringTimelineEvents(events, sport)
  const cardCount = countCardTimelineEvents(events)
  return events.length + (scoringCount * 2) + (cardCount * 3)
}

function extractApiFootballErrors(data: unknown): string | null {
  const errors = (data as Record<string, unknown>)?.errors
  if (!errors || typeof errors !== "object") return null
  const messages = Object.values(errors as Record<string, unknown>)
    .map((value) => String(value ?? "").trim())
    .filter(Boolean)
  return messages.length > 0 ? messages.join("; ") : null
}

function shouldUseApiFootballTimelineFallback(sport?: string | null): boolean {
  return normalizedTimelineSportKind(sport ?? undefined) === "soccer"
}

function resolveApiFootballFixtureId(payload: unknown): string | null {
  if (!payload || typeof payload !== "object") return null
  const record = payload as Record<string, unknown>
  return cleanString(record.idAPIfootball)
}

async function resolveApiFootballFixtureIdForTimeline(
  providerEventId: string,
  payload: unknown,
  sportsDBKey?: string,
): Promise<string | null> {
  const fromPayload = resolveApiFootballFixtureId(payload)
  if (fromPayload) return fromPayload

  const apiKey = sportsDBKey?.trim()
    || Deno.env.get("THESPORTSDB_API_KEY")?.trim()
    || THE_SPORTSDB_V1_FREE_API_KEY
  const lookupPath = `/api/v1/json/redacted/lookupevent.php?id=${encodeURIComponent(providerEventId)}`
  timelineLog(`api_football_fixture_lookup path=${lookupPath}`)
  try {
    const url = `https://www.thesportsdb.com/api/v1/json/${apiKey}/lookupevent.php?id=${encodeURIComponent(providerEventId)}`
    const response = await fetch(url)
    if (!response.ok) {
      timelineLog(`api_football_fixture_lookup_failed http=${response.status}`)
      return null
    }
    const data = await response.json()
    const event = Array.isArray(data?.events) ? data.events[0] : null
    const fixtureId = cleanString(event?.idAPIfootball)
    timelineLog(`api_football_fixture_lookup providerEventId=${providerEventId} fixtureId=${fixtureId ?? "nil"}`)
    return fixtureId
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    timelineLog(`api_football_fixture_lookup_error=${message}`)
    return null
  }
}

async function fetchApiFootballTimelineEvents(input: {
  fixtureId: string
  fallbackEventId: string
  homeTeam: string
  awayTeam: string
  apiKey: string
}): Promise<TimelineFetchResult> {
  const eventsEndpoint = `/fixtures/events?fixture=${encodeURIComponent(input.fixtureId)}`
  const eventsResult = await fetchApiFootballTimelineFromEndpoint({
    ...input,
    timelineEndpoint: `api-football:${eventsEndpoint}`,
    url: `https://v3.football.api-sports.io${eventsEndpoint}`,
    rowsSelector: (data) => Array.isArray((data as Record<string, unknown>)?.response)
      ? (data as Record<string, unknown>).response as unknown[]
      : [],
  })
  if (eventsResult.events.length > 0) return eventsResult

  const fixtureEndpoint = `/fixtures?id=${encodeURIComponent(input.fixtureId)}`
  return await fetchApiFootballTimelineFromEndpoint({
    ...input,
    timelineEndpoint: `api-football:${fixtureEndpoint}`,
    url: `https://v3.football.api-sports.io${fixtureEndpoint}`,
    rowsSelector: (data) => {
      const response = Array.isArray((data as Record<string, unknown>)?.response)
        ? (data as Record<string, unknown>).response as Record<string, unknown>[]
        : []
      const fixture = response[0]
      return Array.isArray(fixture?.events) ? fixture.events as unknown[] : []
    },
  })
}

async function fetchApiFootballTimelineFromEndpoint(input: {
  fixtureId: string
  fallbackEventId: string
  homeTeam: string
  awayTeam: string
  apiKey: string
  timelineEndpoint: string
  url: string
  rowsSelector: (data: unknown) => unknown[]
}): Promise<TimelineFetchResult> {
  const response = await fetch(input.url, {
    headers: {
      "x-apisports-key": input.apiKey,
      Accept: "application/json",
    },
  })
  const rawTimelineResponse = await response.text()
  if (!response.ok) {
    timelineLog(
      `api_football_timeline_failed endpoint=${input.timelineEndpoint} http=${response.status} body=${rawPreview(rawTimelineResponse)}`,
    )
    return {
      events: [],
      timelineEndpoint: input.timelineEndpoint,
      httpStatus: response.status,
      rawTimelineResponse: rawPreview(rawTimelineResponse),
      source: "api_football_error",
      providerEventId: input.fallbackEventId,
    }
  }

  let data: unknown
  try {
    data = JSON.parse(rawTimelineResponse)
  } catch {
    timelineLog(`api_football_timeline_invalid_json endpoint=${input.timelineEndpoint}`)
    return {
      events: [],
      timelineEndpoint: input.timelineEndpoint,
      httpStatus: response.status,
      rawTimelineResponse: rawPreview(rawTimelineResponse),
      source: "api_football_invalid_json",
      providerEventId: input.fallbackEventId,
    }
  }

  const rows = input.rowsSelector(data)
  const apiFootballError = extractApiFootballErrors(data)
  if (apiFootballError) {
    timelineLog(`api_football_timeline_provider_error endpoint=${input.timelineEndpoint} error=${apiFootballError}`)
  }
  const events = normalizeApiFootballTimelineEventRows(
    rows,
    input.fixtureId,
    input.fallbackEventId,
    input.homeTeam,
    input.awayTeam,
  )

  return {
    events,
    timelineEndpoint: input.timelineEndpoint,
    httpStatus: response.status,
    rawTimelineResponse: rawPreview(rawTimelineResponse),
    source: "api_football",
    providerEventId: input.fallbackEventId,
  }
}

function normalizeApiFootballTimelineEventRows(
  rows: unknown[],
  fixtureId: string,
  fallbackEventId: string,
  homeTeam: string,
  awayTeam: string,
): TimelineEventRow[] {
  const normalized = rows.map((row, index) => {
    const record = row && typeof row === "object" ? row as Record<string, unknown> : {}
    const time = record.time && typeof record.time === "object"
      ? record.time as Record<string, unknown>
      : {}
    const elapsed = cleanString(time.elapsed)
    const extra = cleanString(time.extra)
    const minute = elapsed
      ? extra
        ? `${elapsed}+${extra}`
        : elapsed
      : null
    const type = cleanString(record.type)
    const detail = cleanString(record.detail)
    const player = record.player && typeof record.player === "object"
      ? record.player as Record<string, unknown>
      : {}
    const assist = record.assist && typeof record.assist === "object"
      ? record.assist as Record<string, unknown>
      : {}
    const team = record.team && typeof record.team === "object"
      ? record.team as Record<string, unknown>
      : {}
    const teamName = cleanString(team.name)
    const normalizedHome = normalizeTimelineTeamKey(homeTeam)
    const normalizedAway = normalizeTimelineTeamKey(awayTeam)
    const normalizedTeam = normalizeTimelineTeamKey(teamName)
    const isHome = normalizedTeam.length > 0 && (
      normalizedTeam === normalizedHome
      || normalizedTeam.includes(normalizedHome)
      || normalizedHome.includes(normalizedTeam)
    )
    const isAway = normalizedTeam.length > 0 && (
      normalizedTeam === normalizedAway
      || normalizedTeam.includes(normalizedAway)
      || normalizedAway.includes(normalizedTeam)
    )

    return {
      idTimeline: `apifootball:${fixtureId}:${index}`,
      idEvent: fallbackEventId,
      strTimeline: type === "Goal" ? "Goal" : type,
      strTimelineDetail: detail,
      strHome: isHome ? "Yes" : isAway ? "No" : null,
      idPlayer: cleanString(player.id),
      strPlayer: cleanString(player.name),
      idAssist: cleanString(assist.id),
      strAssist: cleanString(assist.name),
      intTime: minute,
      idTeam: cleanString(team.id),
      strTeam: teamName,
      strComment: null,
      dateEvent: null,
      strSeason: null,
    } satisfies TimelineEventRow
  })

  return finalizeTimelineEventRows(
    normalized.map((row) => normalizeTimelineEventRow(row, fallbackEventId)).filter(isTimelineEventRow),
    fallbackEventId,
    homeTeam,
    awayTeam,
  )
}

function omitEmptyTimelineFieldsForUpsert(matches: LiveMatchUpsert[]): void {
  for (const match of matches) {
    if (!Array.isArray(match.timeline_events) || match.timeline_events.length === 0) {
      delete (match as Record<string, unknown>).timeline_events
      delete (match as Record<string, unknown>).timeline_updated_at
    }
  }
}

function mergeFetchedTimelineWithExisting(
  fetchedEvents: TimelineEventRow[],
  existingEvents: TimelineEventRow[],
  gameId: string,
  homeTeam: string,
  awayTeam: string,
  sport?: string,
): TimelineEventRow[] {
  const cachedEvents = enrichCardTimelineRows(existingEvents, homeTeam, awayTeam)
  if (fetchedEvents.length === 0) return cachedEvents

  let merged = mergeAndDedupeTimelineEvents(cachedEvents, fetchedEvents, gameId, homeTeam, awayTeam)
  if (cachedEvents.length > 0) {
    const cachedScore = timelineRichnessScore(cachedEvents, sport)
    const mergedScore = timelineRichnessScore(merged, sport)
    if (cachedScore > mergedScore) {
      merged = mergeAndDedupeTimelineEvents(cachedEvents, fetchedEvents, gameId, homeTeam, awayTeam)
    }
  }
  return preserveCachedCardTimelineEvents(cachedEvents, merged, gameId, homeTeam, awayTeam)
}

function applyTimelineFromFetch(
  match: LiveMatchUpsert,
  fetchResult: TimelineFetchResult,
  cached: TimelineEventCacheRow | undefined,
): TimelineEventRow[] {
  const cachedEvents = Array.isArray(cached?.timeline_events)
    ? cached.timeline_events as TimelineEventRow[]
    : []
  const merged = mergeFetchedTimelineWithExisting(
    fetchResult.events,
    cachedEvents,
    match.external_id,
    match.home_team,
    match.away_team,
    match.sport,
  )

  if (merged.length > 0) {
    match.timeline_events = merged
    match.timeline_updated_at = new Date().toISOString()
    return merged
  }
  delete (match as Record<string, unknown>).timeline_events
  delete (match as Record<string, unknown>).timeline_updated_at
  return []
}

async function hydrateEmptyCompletedMatchTimelines(
  supabase: ReturnType<typeof createClient>,
  savedTimelineCounts: SavedTimelineCounts,
): Promise<void> {
  const windowStart = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString()
  const { data, error } = await supabase
    .from("live_matches")
    .select("id,source,external_id,home_team,away_team,sport,score_home,score_away,match_status,start_time,payload,timeline_events")
    .eq("source", "thesportsdb")
    .eq("match_status", "FT")
    .gte("start_time", windowStart)
    .or("score_home.gt.0,score_away.gt.0")

  if (error || !Array.isArray(data)) {
    if (error) timelineLog(`empty_timeline_hydration_query_error=${error.message}`)
    return
  }

  const candidates = data
    .filter((row) => {
      const existingCount = Array.isArray(row.timeline_events) ? row.timeline_events.length : 0
      return existingCount === 0
    })
    .sort((lhs, rhs) => String(rhs.start_time ?? "").localeCompare(String(lhs.start_time ?? "")))
    .slice(0, 20)

  const sportsDBKey = Deno.env.get("THESPORTSDB_API_KEY")?.trim()
  for (const row of candidates) {
    const externalId = cleanString(row.external_id)
    const liveMatchId = cleanString(row.id)
    if (!externalId || !liveMatchId) continue

    const homeTeam = cleanString(row.home_team) ?? ""
    const awayTeam = cleanString(row.away_team) ?? ""
    const sport = cleanString(row.sport)
    timelineLog(`empty_timeline_hydration liveMatchId=${liveMatchId} providerEventId=${externalId}`)

    try {
      const fetchResult = await fetchTimelineEventsForMatch({
        providerEventId: externalId,
        sportsDBKey,
        payload: row.payload,
        homeTeam,
        awayTeam,
        sport,
      })
      const scoringEventsCount = countScoringTimelineEvents(fetchResult.events, sport ?? undefined)
      logScoringEventDebug({
        eventId: externalId,
        timelineFetched: true,
        timelineCount: fetchResult.events.length,
        rawSample: scoringTimelineRawSample(fetchResult.events),
        scoringEventsCount,
        renderedSummary: buildRenderedTimelineSummary(fetchResult.events, sport, homeTeam, awayTeam),
        fallbackReason: fetchResult.events.length === 0 ? "providerTimelineMissing" : null,
        source: fetchResult.source,
        providerEventId: fetchResult.providerEventId,
        timelineEndpoint: fetchResult.timelineEndpoint,
        httpStatus: fetchResult.httpStatus,
        rawTimelineResponse: fetchResult.rawTimelineResponse,
        updateLiveMatchId: liveMatchId,
        updateSucceeded: false,
      })

      if (fetchResult.events.length === 0) continue

      const updatedAt = new Date().toISOString()
      const { error: updateError } = await supabase
        .from("live_matches")
        .update({
          timeline_events: fetchResult.events,
          timeline_updated_at: updatedAt,
        })
        .eq("id", liveMatchId)

      const updateSucceeded = !updateError
      if (updateError) {
        timelineLog(`empty_timeline_hydration_update_error liveMatchId=${liveMatchId} error=${updateError.message}`)
      } else {
        savedTimelineCounts.savedTimelineUpdated += 1
        savedTimelineCounts.savedTimelineIds.push(liveMatchId)
      }
      console.log(`[ScoringEventDebug] updateLiveMatchId=${liveMatchId}`)
      console.log(`[ScoringEventDebug] updateSucceeded=${updateSucceeded}`)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      timelineLog(`empty_timeline_hydration_error liveMatchId=${liveMatchId} error=${message}`)
    }
  }
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
      source: cleanString(row?.source),
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
  const liveTimelineMatches = sportsDBMatches
    .filter(isLiveOrHalftimeMatch)
    .slice(0, MAX_TIMELINE_ACTIVE_FOLLOWER_MATCHES)
  const activeFollowerIndex = await buildTimelineActiveFollowerIndex(supabase, liveTimelineMatches)

  for (const match of sportsDBMatches) {
    const cached = cacheByEventId.get(match.external_id)
    if (cached && isTimelineEventCacheFresh(cached, match, activeFollowerIndex)) {
      logTimelineCacheDebug(match, activeFollowerIndex, { cacheHit: true })
      const cachedEvents = cached.timeline_events ?? []
      if (cachedEvents.length > 0) {
        match.timeline_events = cachedEvents
        match.timeline_updated_at = cached.timeline_updated_at
      } else {
        delete (match as Record<string, unknown>).timeline_events
        delete (match as Record<string, unknown>).timeline_updated_at
      }
      counts.timelineCacheHits += 1
      logScoringEventDebug({
        eventId: match.external_id,
        timelineFetched: false,
        timelineCount: cachedEvents.length,
        rawSample: scoringTimelineRawSample(cachedEvents),
        scoringEventsCount: countScoringTimelineEvents(cachedEvents, match.sport),
        fallbackReason: cachedEvents.length === 0 ? "providerTimelineMissing" : null,
        source: "cache",
        providerEventId: match.external_id,
        timelineEndpoint: "cache",
        httpStatus: null,
        rawTimelineResponse: cachedEvents.length > 0 ? scoringTimelineRawSample(cachedEvents) : "null",
        updateLiveMatchId: match.id,
        updateSucceeded: false,
      })
      continue
    }

    logTimelineCacheDebug(match, activeFollowerIndex, { cacheHit: false })

    if (shouldSkipHeavyEnrichment(match)) {
      if (cached?.timeline_events && cached.timeline_events.length > 0) {
        match.timeline_events = cached.timeline_events
        match.timeline_updated_at = cached.timeline_updated_at
      } else {
        delete (match as Record<string, unknown>).timeline_events
        delete (match as Record<string, unknown>).timeline_updated_at
      }
      if (cached) counts.timelineCacheHits += 1
      timelineLog(`event=${match.external_id} skipped=far_future`)
      continue
    }

    const runCached = fetchedByEventId.get(match.external_id)
    if (runCached) {
      if (runCached.events.length > 0) {
        match.timeline_events = runCached.events
        match.timeline_updated_at = runCached.updatedAt
      } else {
        delete (match as Record<string, unknown>).timeline_events
        delete (match as Record<string, unknown>).timeline_updated_at
      }
      counts.timelineCacheHits += 1
      continue
    }

    try {
      const fetchResult = await fetchTimelineEventsForMatch({
        providerEventId: match.external_id,
        sportsDBKey,
        payload: match.payload,
        homeTeam: match.home_team,
        awayTeam: match.away_team,
        sport: match.sport,
        matchStatus: match.match_status,
        scoreHome: match.score_home,
        scoreAway: match.score_away,
        minute: match.minute,
      })
      const updatedAt = new Date().toISOString()
      fetchedByEventId.set(match.external_id, { events: fetchResult.events, updatedAt })
      const events = applyTimelineFromFetch(match, fetchResult, cached)
      counts.timelineFetched += 1
      if (fetchResult.events.length === 0) counts.timelineEmpty += 1
      timelineLog(`event=${match.external_id} fetched=${fetchResult.events.length}`)
      logScoringEventDebug({
        eventId: match.external_id,
        timelineFetched: true,
        timelineCount: events.length,
        rawSample: scoringTimelineRawSample(events),
        scoringEventsCount: countScoringTimelineEvents(events, match.sport),
        cardEventsCount: countCardTimelineEvents(events),
        timelineEvents: events,
        fallbackReason: fetchResult.events.length === 0 ? "providerTimelineMissing" : null,
        source: fetchResult.source,
        providerEventId: fetchResult.providerEventId,
        timelineEndpoint: fetchResult.timelineEndpoint,
        httpStatus: fetchResult.httpStatus,
        rawTimelineResponse: fetchResult.rawTimelineResponse,
        updateLiveMatchId: match.id,
        updateSucceeded: false,
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
      const preservedEvents = cached?.timeline_events ?? []
      if (preservedEvents.length > 0) {
        match.timeline_events = preservedEvents
        match.timeline_updated_at = cached?.timeline_updated_at ?? null
      } else {
        delete (match as Record<string, unknown>).timeline_events
        delete (match as Record<string, unknown>).timeline_updated_at
      }
      logScoringEventDebug({
        eventId: match.external_id,
        timelineFetched: false,
        timelineCount: preservedEvents.length,
        rawSample: scoringTimelineRawSample(preservedEvents),
        scoringEventsCount: countScoringTimelineEvents(preservedEvents, match.sport),
        fallbackReason: "providerTimelineFetchError",
        providerEventId: match.external_id,
        timelineEndpoint: "error",
        httpStatus: null,
        rawTimelineResponse: message,
        updateLiveMatchId: match.id,
        updateSucceeded: false,
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

type TimelineActiveFollowerStatus = {
  active: boolean
  reasons: string[]
}

type TimelineActiveFollowerIndex = {
  byExternalId: Map<string, TimelineActiveFollowerStatus>
  lookupFailed: boolean
}

function isLiveOrHalftimeMatch(match: LiveMatchUpsert): boolean {
  return match.match_status === "LIVE" || match.match_status === "HT"
}

function collectTimelineLookupKeysForMatch(match: LiveMatchUpsert): string[] {
  const keys = new Set<string>()
  const id = cleanString(match.id)
  const externalId = cleanString(match.external_id)
  const source = cleanString(match.source)
  if (id) keys.add(id)
  if (externalId) keys.add(externalId)
  if (source && externalId) keys.add(`${source}:${externalId}`)
  if (externalId && (source === "thesportsdb" || id?.toLowerCase().startsWith("thesportsdb:"))) {
    keys.add(`thesportsdb:${externalId}`)
  }
  return [...keys]
}

function matchHasAnyLookupKey(keys: string[], found: Set<string>): boolean {
  return keys.some((key) => found.has(key))
}

async function fetchDistinctSavedProGameKeys(
  supabase: ReturnType<typeof createClient>,
  keys: string[],
): Promise<Set<string>> {
  const found = new Set<string>()
  if (keys.length === 0) return found

  for (let offset = 0; offset < keys.length; offset += TIMELINE_LOOKUP_BATCH_SIZE) {
    const slice = keys.slice(offset, offset + TIMELINE_LOOKUP_BATCH_SIZE)
    const { data, error } = await supabase
      .from("saved_pro_games")
      .select("live_match_id")
      .in("live_match_id", slice)
    if (error) throw error
    for (const row of data ?? []) {
      const liveMatchId = cleanString(row?.live_match_id)
      if (liveMatchId) found.add(liveMatchId)
    }
  }
  return found
}

async function fetchDistinctProGamePredictionKeys(
  supabase: ReturnType<typeof createClient>,
  keys: string[],
): Promise<Set<string>> {
  const found = new Set<string>()
  if (keys.length === 0) return found

  for (let offset = 0; offset < keys.length; offset += TIMELINE_LOOKUP_BATCH_SIZE) {
    const slice = keys.slice(offset, offset + TIMELINE_LOOKUP_BATCH_SIZE)
    const { data, error } = await supabase
      .from("pro_game_predictions")
      .select("pro_game_id")
      .in("pro_game_id", slice)
    if (error) throw error
    for (const row of data ?? []) {
      const proGameId = cleanString(row?.pro_game_id)
      if (proGameId) found.add(proGameId)
    }
  }
  return found
}

async function fetchDistinctFavoriteTeamIds(
  supabase: ReturnType<typeof createClient>,
): Promise<Set<string>> {
  const { data, error } = await supabase
    .from("user_favorite_teams")
    .select("team_id")
  if (error) throw error

  const ids = new Set<string>()
  for (const row of data ?? []) {
    const teamId = cleanString(row?.team_id)
    if (teamId) ids.add(teamId)
  }
  return ids
}

async function buildTimelineActiveFollowerIndex(
  supabase: ReturnType<typeof createClient>,
  liveMatches: LiveMatchUpsert[],
): Promise<TimelineActiveFollowerIndex> {
  const byExternalId = new Map<string, TimelineActiveFollowerStatus>()
  if (liveMatches.length === 0) {
    return { byExternalId, lookupFailed: false }
  }

  const keysForMatch = new Map<string, string[]>()
  const allKeys = new Set<string>()
  for (const match of liveMatches) {
    const keys = collectTimelineLookupKeysForMatch(match)
    keysForMatch.set(match.external_id, keys)
    for (const key of keys) {
      if (allKeys.size >= MAX_TIMELINE_LOOKUP_KEYS) break
      allKeys.add(key)
    }
  }

  try {
    const lookupKeys = [...allKeys].slice(0, MAX_TIMELINE_LOOKUP_KEYS)
    const [savedKeys, predictionKeys, followedTeamIds] = await Promise.all([
      fetchDistinctSavedProGameKeys(supabase, lookupKeys),
      fetchDistinctProGamePredictionKeys(supabase, lookupKeys),
      fetchDistinctFavoriteTeamIds(supabase),
    ])

    for (const match of liveMatches) {
      const keys = keysForMatch.get(match.external_id) ?? []
      const reasons: string[] = []

      if (matchHasAnyLookupKey(keys, savedKeys)) reasons.push("saved")
      if (matchHasAnyLookupKey(keys, predictionKeys)) reasons.push("prediction")
      if (cleanString(match.featured_event_slug)) reasons.push("featured")
      if (
        followedCatalogTeamIdsForMatch(match.home_team, match.away_team, followedTeamIds).length > 0
      ) {
        reasons.push("favorite_team")
      }

      byExternalId.set(match.external_id, {
        active: reasons.length > 0,
        reasons,
      })
    }

    timelineLog(
      `active_follower_index liveMatches=${liveMatches.length} activeCount=${[...byExternalId.values()].filter((row) => row.active).length}`,
    )
    return { byExternalId, lookupFailed: false }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    timelineLog(`active_follower_index_failed error=${message}`)
    return { byExternalId, lookupFailed: true }
  }
}

function timelineCacheDebugReason(
  match: LiveMatchUpsert,
  activeFollowerIndex: TimelineActiveFollowerIndex,
): string {
  if (activeFollowerIndex.lookupFailed) return "lookup_failed_default_ttl"
  if (!isLiveOrHalftimeMatch(match)) return "non_live_default_ttl"
  const status = activeFollowerIndex.byExternalId.get(match.external_id)
  if (status?.active) {
    return `active_followers:${status.reasons.join("+") || "unknown"}`
  }
  return "no_active_followers"
}

function logTimelineCacheDebug(
  match: LiveMatchUpsert,
  activeFollowerIndex: TimelineActiveFollowerIndex,
  context: { cacheHit: boolean },
): void {
  if (!isLiveOrHalftimeMatch(match)) return

  const status = activeFollowerIndex.byExternalId.get(match.external_id)
  const activeFollowers = activeFollowerIndex.lookupFailed
    ? false
    : status?.active ?? false
  const ttlSeconds = Math.round(timelineEventCacheTTLMilliseconds(match, activeFollowerIndex) / 1000)
  const reason = timelineCacheDebugReason(match, activeFollowerIndex)
  const cacheState = context.cacheHit ? "hit" : "miss"

  console.log(`[TimelineCacheDebug] gameId=${match.external_id}`)
  console.log(`[TimelineCacheDebug] matchStatus=${match.match_status}`)
  console.log(`[TimelineCacheDebug] activeFollowers=${activeFollowers}`)
  console.log(`[TimelineCacheDebug] ttlSeconds=${ttlSeconds}`)
  console.log(`[TimelineCacheDebug] reason=${reason}`)
  console.log(`[TimelineCacheDebug] cache=${cacheState}`)
}

function isTimelineEventCacheFresh(
  cache: TimelineEventCacheRow,
  match: LiveMatchUpsert,
  activeFollowerIndex: TimelineActiveFollowerIndex,
): boolean {
  const cachedEvents = Array.isArray(cache.timeline_events) ? cache.timeline_events : []
  if (cachedEvents.length === 0) {
    if (match.match_status === "FT" || match.match_status === "AET" || match.match_status === "PEN") {
      return false
    }
    if (
      (match.match_status === "LIVE" || match.match_status === "HT")
      && ((match.score_home ?? 0) > 0 || (match.score_away ?? 0) > 0)
    ) {
      return false
    }
  }
  if (match.match_status === "LIVE" || match.match_status === "HT") {
    if (timelineHasGoalsWithoutCards(cachedEvents, match.sport)) return false
    if (timelineAppearsPartial(cachedEvents, match)) return false
  }
  if (!cache.timeline_updated_at) return false
  const updatedAt = new Date(cache.timeline_updated_at)
  if (!Number.isFinite(updatedAt.getTime())) return false
  return Date.now() - updatedAt.getTime() < timelineEventCacheTTLMilliseconds(match, activeFollowerIndex)
}

function timelineEventCacheTTLMilliseconds(
  match: LiveMatchUpsert,
  activeFollowerIndex: TimelineActiveFollowerIndex,
): number {
  if (!isLiveOrHalftimeMatch(match)) {
    return NON_LIVE_TIMELINE_CACHE_TTL_MS
  }
  if (activeFollowerIndex.lookupFailed) {
    return LIVE_TIMELINE_DEFAULT_CACHE_TTL_MS
  }
  const status = activeFollowerIndex.byExternalId.get(match.external_id)
  if (status?.active) {
    return LIVE_TIMELINE_ACTIVE_FOLLOWER_CACHE_TTL_MS
  }
  return LIVE_TIMELINE_DEFAULT_CACHE_TTL_MS
}

function shouldSkipHeavyEnrichment(match: LiveMatchUpsert): boolean {
  if (match.match_status !== "SCHEDULED") return false
  const startTime = new Date(match.start_time).getTime()
  return Number.isFinite(startTime) && startTime > Date.now() + HEAVY_ENRICHMENT_LOOKAHEAD_MS
}

async function fetchTheSportsDBTimelineEvents(
  idEvent: string,
  apiKey: string | undefined,
): Promise<TimelineFetchResult> {
  if (apiKey) {
    const v2Result = await fetchTheSportsDBV2TimelineEvents(idEvent, apiKey)
    if (v2Result.events.length > 0) return v2Result
    if (v2Result.httpStatus && v2Result.httpStatus >= 400) {
      timelineLog(`v2_failed event=${idEvent} http=${v2Result.httpStatus} falling_back=v1`)
    } else {
      timelineLog(`v2_empty event=${idEvent} falling_back=v1 path=/api/v1/json/redacted/lookuptimeline.php?id=${encodeURIComponent(idEvent)}`)
    }
  }
  return await fetchTheSportsDBV1TimelineEvents(idEvent, apiKey ?? THE_SPORTSDB_V1_FREE_API_KEY)
}

async function fetchTheSportsDBV2TimelineEvents(idEvent: string, apiKey: string): Promise<TimelineFetchResult> {
  const timelineEndpoint = `/api/v2/json/lookup/event_timeline/${encodeURIComponent(idEvent)}`
  const url = `${THESPORTSDB_V2_BASE}/lookup/event_timeline/${encodeURIComponent(idEvent)}`
  timelineLog(`v2_request path=${timelineEndpoint}`)
  try {
    const response = await fetch(url, {
      headers: { "X-API-KEY": apiKey },
    })
    const rawTimelineResponse = await response.text()
    if (!response.ok) {
      return {
        events: [],
        timelineEndpoint,
        httpStatus: response.status,
        rawTimelineResponse: rawPreview(rawTimelineResponse),
        source: "thesportsdb_v2_error",
        providerEventId: idEvent,
      }
    }
    let data: unknown
    try {
      data = JSON.parse(rawTimelineResponse)
    } catch {
      return {
        events: [],
        timelineEndpoint,
        httpStatus: response.status,
        rawTimelineResponse: rawPreview(rawTimelineResponse),
        source: "thesportsdb_v2_invalid_json",
        providerEventId: idEvent,
      }
    }
    const events = normalizeTimelineEventRows(data, idEvent)
    return {
      events,
      timelineEndpoint,
      httpStatus: response.status,
      rawTimelineResponse: rawPreview(rawTimelineResponse),
      source: "thesportsdb_v2",
      providerEventId: idEvent,
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    timelineLog(`v2_request_error event=${idEvent} error=${message}`)
    return {
      events: [],
      timelineEndpoint,
      httpStatus: null,
      rawTimelineResponse: message,
      source: "thesportsdb_v2_error",
      providerEventId: idEvent,
    }
  }
}

async function fetchTheSportsDBV1TimelineEvents(
  idEvent: string,
  apiKey: string = THE_SPORTSDB_V1_FREE_API_KEY,
): Promise<TimelineFetchResult> {
  const timelineEndpoint = `/api/v1/json/redacted/lookuptimeline.php?id=${encodeURIComponent(idEvent)}`
  const url = `https://www.thesportsdb.com/api/v1/json/${apiKey}/lookuptimeline.php?id=${encodeURIComponent(idEvent)}`
  timelineLog(`v1_request path=${timelineEndpoint}`)
  try {
    const response = await fetch(url)
    const rawTimelineResponse = await response.text()
    if (!response.ok) {
      return {
        events: [],
        timelineEndpoint,
        httpStatus: response.status,
        rawTimelineResponse: rawPreview(rawTimelineResponse),
        source: "thesportsdb_v1_error",
        providerEventId: idEvent,
      }
    }
    let data: unknown
    try {
      data = JSON.parse(rawTimelineResponse)
    } catch {
      return {
        events: [],
        timelineEndpoint,
        httpStatus: response.status,
        rawTimelineResponse: rawPreview(rawTimelineResponse),
        source: "thesportsdb_v1_invalid_json",
        providerEventId: idEvent,
      }
    }
    if (data && typeof data === "object" && typeof (data as Record<string, unknown>).Message === "string") {
      const message = (data as Record<string, unknown>).Message as string
      return {
        events: [],
        timelineEndpoint,
        httpStatus: response.status,
        rawTimelineResponse: rawPreview(rawTimelineResponse),
        source: "thesportsdb_v1_provider_error",
        providerEventId: idEvent,
      }
    }
    const events = normalizeTimelineEventRows(data, idEvent)
    return {
      events,
      timelineEndpoint,
      httpStatus: response.status,
      rawTimelineResponse: rawPreview(rawTimelineResponse),
      source: "thesportsdb_v1",
      providerEventId: idEvent,
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    timelineLog(`v1_request_error event=${idEvent} error=${message}`)
    return {
      events: [],
      timelineEndpoint,
      httpStatus: null,
      rawTimelineResponse: message,
      source: "thesportsdb_v1_error",
      providerEventId: idEvent,
    }
  }
}

function normalizeTimelineEventRows(data: unknown, fallbackEventId: string, homeTeam = "", awayTeam = ""): TimelineEventRow[] {
  const rows = extractTimelineEventRows(data)
  const normalized = rows
    .map((row) => normalizeTimelineEventRow(row, fallbackEventId))
    .filter(isTimelineEventRow)
  return finalizeTimelineEventRows(normalized, fallbackEventId, homeTeam, awayTeam)
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
  if (row.strTimeline || row.strPlayer || row.strTeam) return true
  return isCardTimelineEvent(row)
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
  cardEventsCount?: number
  timelineEvents?: TimelineEventRow[]
  renderedSummary?: string
  fallbackReason: string | null
  source?: string
  providerEventId?: string
  timelineEndpoint?: string
  httpStatus?: number | null
  rawTimelineResponse?: string
  updateLiveMatchId?: string
  updateSucceeded?: boolean
}): void {
  const cardEventsCount = input.cardEventsCount
    ?? countCardTimelineEvents(input.timelineEvents ?? [])
  const rawPayload = input.rawTimelineResponse ?? input.rawSample
  const rawIncludesCards = rawIncludesCardMarkers(rawPayload)
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
  const providerEventId = input.providerEventId ?? input.eventId
  console.log(`[ScoringEventDebug] providerEventId=${providerEventId}`)
  console.log(`[ScoringEventDebug] eventId=${input.eventId}`)
  console.log(`[ScoringEventDebug] timelineFetched=${input.timelineFetched}`)
  if (input.source) {
    console.log(`[ScoringEventDebug] timelineSource=${input.source}`)
  }
  console.log(`[ScoringEventDebug] timelineEndpoint=${input.timelineEndpoint ?? "unknown"}`)
  console.log(`[ScoringEventDebug] httpStatus=${input.httpStatus ?? "nil"}`)
  console.log(`[ScoringEventDebug] rawTimelineResponse=${input.rawTimelineResponse ?? input.rawSample}`)
  console.log(`[ScoringEventDebug] timelineCount=${input.timelineCount}`)
  console.log(`[LiveScoringEventDebug] timelineCount=${input.timelineCount}`)
  console.log(`[ScoringEventDebug] cardEventsCount=${cardEventsCount}`)
  console.log(`[ScoringEventDebug] rawTimelineIncludesCards=${rawIncludesCards}`)
  console.log(`[ScoringEventDebug] rawSample=${input.rawSample}`)
  console.log(`[ScoringEventDebug] scoringEventsCount=${input.scoringEventsCount}`)
  console.log(`[LiveScoringEventDebug] scoringEventsCount=${input.scoringEventsCount}`)
  const renderedSummary = input.renderedSummary ?? "none"
  console.log(`[LiveScoringEventDebug] renderedSummary=${renderedSummary}`)
  console.log(`[ScoringEventDebug] fallbackReason=${input.fallbackReason ?? "none"}`)
  console.log(`[LiveScoringEventDebug] fallbackReason=${input.fallbackReason ?? "none"}`)
  if (input.updateLiveMatchId) {
    console.log(`[ScoringEventDebug] updateLiveMatchId=${input.updateLiveMatchId}`)
  }
  if (input.updateSucceeded !== undefined) {
    console.log(`[ScoringEventDebug] updateSucceeded=${input.updateSucceeded}`)
  }
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

function rawIncludesCardMarkers(raw: string): boolean {
  const text = String(raw ?? "").toLowerCase()
  return text.includes("yellow card")
    || text.includes("red card")
    || text.includes("second yellow")
    || text.includes("yellowcard")
    || text.includes("redcard")
    || text.includes("booking")
    || text.includes("sent off")
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
