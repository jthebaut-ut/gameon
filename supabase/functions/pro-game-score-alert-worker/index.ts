// Closed-app Pro Game score alerts.
//
// Deploy:
//   supabase functions deploy pro-game-score-alert-worker
//
// Required secrets:
//   PROJECT_URL / SUPABASE_URL
//   SERVICE_ROLE_KEY / SUPABASE_SERVICE_ROLE_KEY
//   PRO_SCORE_PUSH_WORKER_CRON_SECRET (optional; accepted via x-cron-secret)
//   APNS_KEY_ID
//   APNS_TEAM_ID
//   APNS_BUNDLE_ID
//   APNS_PRIVATE_KEY
//   APNS_ENVIRONMENT=sandbox|production
//
// Schedule this function every 1-2 minutes during active sports windows after
// validating on a physical iPhone / TestFlight APNs environment.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

type SupabaseClient = ReturnType<typeof createClient>

type TrackedGameSource = "saved" | "favorite_team"
type NotificationType = "kickoff" | "score" | "final"

type SavedProGameRow = {
  id: string
  user_id: string
  live_match_id: string
  source: string | null
  external_id: string | null
  home_team: string
  away_team: string
  league: string | null
  sport: string | null
  start_time: string
  match_status: string | null
  score_home: number | null
  score_away: number | null
  score_alerts_enabled: boolean
  final_score_alerts_enabled: boolean
  last_notified_scoreline: string | null
  last_notified_status: string | null
}

type FavoriteProGameSubscriptionRow = SavedProGameRow & {
  subscription_source: "favorite_team"
  favorite_team_id: string | null
  favorite_team_name: string | null
}

type TrackedGame = {
  table: "saved_pro_games" | "pro_game_alert_subscriptions"
  rowId: string
  userId: string
  liveMatchId: string
  source: string | null
  externalId: string | null
  homeTeam: string
  awayTeam: string
  league: string | null
  sport: string | null
  startTime: string
  snapshotScoreHome: number
  snapshotScoreAway: number
  scoreAlertsEnabled: boolean
  finalScoreAlertsEnabled: boolean
  lastNotifiedScoreline: string | null
  lastNotifiedStatus: string | null
  sourceKind: TrackedGameSource
}

type LiveMatchRow = {
  id: string
  source: string | null
  external_id: string | null
  sport: string
  home_team: string
  away_team: string
  score_home: number
  score_away: number
  match_status: string
  league: string
  start_time: string
}

type PushTokenRow = {
  id: string
  user_id: string
  token: string
  environment: "sandbox" | "production"
}

type UserPreferenceRow = {
  user_id: string
  pro_game_reminder_notifications_enabled: boolean
  pro_game_final_score_alerts_enabled: boolean
}

type WorkerCounts = {
  gamesChecked: number
  liveGamesChecked: number
  kickoffCandidates: number
  kickoffSent: number
  kickoffSkippedDuplicate: number
  kickoffSkippedSettings: number
  kickoffSkippedNoToken: number
  kickoffSkippedOutsideWindow: number
  scoreChangesFound: number
  scoreNotificationsSent: number
  scoreSkippedDuplicate: number
  scoreSkippedSettings: number
  scoreSkippedNoToken: number
  scoreSkippedNotLive: number
  scoreSkippedStaleLiveData: number
  finalChangesFound: number
  finalCandidates: number
  finalSent: number
  finalSkippedDuplicate: number
  finalSkippedSettings: number
  finalSkippedNoToken: number
  finalSkippedNotFinal: number
  notificationsSent: number
  skippedNoLiveMatch: number
  invalidTokens: number
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
}

const SCORE_WINDOW_PAST_HOURS = 6
const SCORE_WINDOW_FUTURE_HOURS = 8

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  const startedAt = Date.now()
  const counts: WorkerCounts = {
    gamesChecked: 0,
    liveGamesChecked: 0,
    kickoffCandidates: 0,
    kickoffSent: 0,
    kickoffSkippedDuplicate: 0,
    kickoffSkippedSettings: 0,
    kickoffSkippedNoToken: 0,
    kickoffSkippedOutsideWindow: 0,
    scoreChangesFound: 0,
    scoreNotificationsSent: 0,
    scoreSkippedDuplicate: 0,
    scoreSkippedSettings: 0,
    scoreSkippedNoToken: 0,
    scoreSkippedNotLive: 0,
    scoreSkippedStaleLiveData: 0,
    finalChangesFound: 0,
    finalCandidates: 0,
    finalSent: 0,
    finalSkippedDuplicate: 0,
    finalSkippedSettings: 0,
    finalSkippedNoToken: 0,
    finalSkippedNotFinal: 0,
    notificationsSent: 0,
    skippedNoLiveMatch: 0,
    invalidTokens: 0,
  }

  console.log("[ProScorePushWorker] run started")

  const supabaseUrl = Deno.env.get("PROJECT_URL") ?? Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ success: false, error: "Missing Supabase service env vars" }, 500)
  }

  const invocation = authorizeInvocation(req, serviceRoleKey)
  if (!invocation.accepted) {
    console.warn(`[ProScorePushWorker] Invocation rejected reason=${invocation.reason}`)
    return json({ success: false, error: "unauthorized" }, 401)
  }
  console.log(`[ProScorePushWorker] Invocation accepted source=${invocation.source}`)

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  })

  try {
    await refreshLiveMatchCache(supabaseUrl, serviceRoleKey)

    const windowStart = new Date(Date.now() - SCORE_WINDOW_PAST_HOURS * 60 * 60 * 1000).toISOString()
    const windowEnd = new Date(Date.now() + SCORE_WINDOW_FUTURE_HOURS * 60 * 60 * 1000).toISOString()

    const trackedGames = await loadTrackedGames(supabase, windowStart, windowEnd)
    counts.gamesChecked = trackedGames.length

    const liveMatches = await loadLiveMatches(supabase, windowStart, windowEnd)
    console.log(`[ProScorePushWorker] fresh live rows count=${liveMatches.length}`)
    const liveById = new Map(liveMatches.map((match) => [normalize(match.id), match]))
    const liveBySourceExternal = new Map(
      liveMatches
        .filter((match) => match.source && match.external_id)
        .map((match) => [`${normalize(match.source)}:${normalize(match.external_id)}`, match]),
    )

    const userIds = [...new Set(trackedGames.map((game) => game.userId))]
    const tokensByUser = await loadPushTokensByUser(supabase, userIds)
    const preferencesByUser = await loadUserPreferencesByUser(supabase, userIds)
    const apns = await ApnsClient.fromEnvironment()

    for (const game of trackedGames) {
      await maybeSendKickoffUpdate(supabase, apns, game, tokensByUser, preferencesByUser, counts)

      console.log(`[ProScorePushWorker] saved game live_match_id=${game.liveMatchId}`)
      const liveMatch = matchLiveRow(game, liveById, liveBySourceExternal, liveMatches)
      if (!liveMatch) {
        const staleLiveData = hasGameStarted(game)
        console.log(`[ProScorePushWorker] matched live row=none`)
        console.log(`[ProScorePushWorker] score skipped staleLiveData=${staleLiveData} reason=noMatchedLiveRow live_match_id=${game.liveMatchId}`)
        counts.skippedNoLiveMatch += 1
        if (staleLiveData) counts.scoreSkippedStaleLiveData += 1
        counts.scoreSkippedNotLive += 1
        counts.finalSkippedNotFinal += 1
        continue
      }

      const { match: live, matchedBy } = liveMatch
      const status = normalizeStatus(live.match_status)
      const treatedAsLive = status === "LIVE" || status === "HT"
      console.log(`[ProScorePushWorker] matched live row=${live.id} matchedBy=${matchedBy}`)
      console.log(`[ProScorePushWorker] rawStatus=${live.match_status}`)
      console.log(`[ProScorePushWorker] normalizedStatus=${status}`)
      console.log(`[ProScorePushWorker] treatedAsLive=${treatedAsLive}`)
      if (status === "LIVE" || status === "HT") {
        counts.liveGamesChecked += 1
        await maybeSendScoreUpdate(supabase, apns, game, live, tokensByUser, counts)
      } else {
        if (isLikelyStaleLiveData(game, live, status)) {
          counts.scoreSkippedStaleLiveData += 1
          console.log(`[ProScorePushWorker] score skipped staleLiveData=true live_match_id=${game.liveMatchId} matchedRow=${live.id} status=${live.match_status}`)
        }
        counts.scoreSkippedNotLive += 1
      }

      if (status === "FT") {
        await maybeSendFinalUpdate(supabase, apns, game, live, tokensByUser, preferencesByUser, counts)
      } else {
        counts.finalSkippedNotFinal += 1
      }
    }

    const durationMs = Date.now() - startedAt
    console.log(`[ProScorePushWorker] kickoff candidates=${counts.kickoffCandidates}`)
    console.log(`[ProScorePushWorker] kickoff sent=${counts.kickoffSent}`)
    console.log(`[ProScorePushWorker] kickoff skipped duplicate=${counts.kickoffSkippedDuplicate}`)
    console.log(`[ProScorePushWorker] kickoff skipped settings=${counts.kickoffSkippedSettings}`)
    console.log(`[ProScorePushWorker] kickoff skipped noToken=${counts.kickoffSkippedNoToken}`)
    console.log(`[ProScorePushWorker] kickoff skipped outsideWindow=${counts.kickoffSkippedOutsideWindow}`)
    console.log(`[ProScorePushWorker] score changes found=${counts.scoreChangesFound}`)
    console.log(`[ProScorePushWorker] score notifications sent=${counts.scoreNotificationsSent}`)
    console.log(`[ProScorePushWorker] score skipped duplicate=${counts.scoreSkippedDuplicate}`)
    console.log(`[ProScorePushWorker] score skipped settings=${counts.scoreSkippedSettings}`)
    console.log(`[ProScorePushWorker] score skipped noToken=${counts.scoreSkippedNoToken}`)
    console.log(`[ProScorePushWorker] score skipped notLive=${counts.scoreSkippedNotLive}`)
    console.log(`[ProScorePushWorker] score skipped staleLiveData=${counts.scoreSkippedStaleLiveData}`)
    console.log(`[ProScorePushWorker] final candidates=${counts.finalCandidates}`)
    console.log(`[ProScorePushWorker] final sent=${counts.finalSent}`)
    console.log(`[ProScorePushWorker] final skipped duplicate=${counts.finalSkippedDuplicate}`)
    console.log(`[ProScorePushWorker] final skipped settings=${counts.finalSkippedSettings}`)
    console.log(`[ProScorePushWorker] final skipped noToken=${counts.finalSkippedNoToken}`)
    console.log(`[ProScorePushWorker] final skipped notFinal=${counts.finalSkippedNotFinal}`)
    console.log(`[ProScorePushWorker] games checked=${counts.gamesChecked}`)
    console.log(`[ProScorePushWorker] live games checked=${counts.liveGamesChecked}`)
    console.log(`[ProScorePushWorker] notifications sent=${counts.notificationsSent}`)
    console.log(`[ProScorePushWorker] durationMs=${durationMs}`)

    return json({ success: true, counts, durationMs })
  } catch (error) {
    const durationMs = Date.now() - startedAt
    console.error("[ProScorePushWorker] failed", error)
    return json({ success: false, error: errorMessage(error), counts, durationMs }, 500)
  }
})

function authorizeInvocation(
  req: Request,
  serviceRoleKey: string,
): { accepted: true; source: string } | { accepted: false; reason: string } {
  if (req.method !== "POST") {
    return { accepted: false, reason: "method_not_allowed" }
  }

  const bearerToken = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "").trim()
  if (bearerToken && bearerToken === serviceRoleKey) {
    return { accepted: true, source: "service_role_bearer" }
  }

  const cronSecret = Deno.env.get("PRO_SCORE_PUSH_WORKER_CRON_SECRET")?.trim()
  const requestCronSecret = req.headers.get("x-cron-secret")?.trim()
    ?? req.headers.get("x-fangeo-cron-secret")?.trim()
  if (cronSecret && requestCronSecret === cronSecret) {
    return { accepted: true, source: "cron_secret" }
  }

  return { accepted: false, reason: bearerToken || requestCronSecret ? "invalid_secret" : "missing_secret" }
}

async function refreshLiveMatchCache(supabaseUrl: string, serviceRoleKey: string) {
  const url = `${supabaseUrl.replace(/\/$/, "")}/functions/v1/sync-live-matches`
  console.log("[ProScorePushWorker] refresh live matches started")
  const headers: Record<string, string> = {
    authorization: `Bearer ${serviceRoleKey}`,
    apikey: serviceRoleKey,
    "content-type": "application/json",
  }
  const cronSecret = Deno.env.get("PRO_SCORE_PUSH_WORKER_CRON_SECRET")?.trim()
  if (cronSecret) {
    headers["x-cron-secret"] = cronSecret
  }

  const response = await fetch(url, {
    method: "POST",
    headers,
  })
  const payload = await response.json().catch(() => null)
  console.log(`[ProScorePushWorker] refresh live matches success=${response.ok && payload?.success !== false}`)
  console.log(`[ProScorePushWorker] refresh live matches status=${response.status}`)
  if (payload) {
    console.log(`[ProScorePushWorker] refresh live matches source=${payload?.source ?? "unknown"} upserted=${payload?.counts?.upserted ?? "unknown"} raw=${payload?.counts?.sportsDBRaw ?? "unknown"} normalized=${payload?.counts?.sportsDBNormalized ?? "unknown"} error=${payload?.error ?? "none"}`)
  }
  if (!response.ok) {
    console.warn(`[ProScorePushWorker] skippedReason=sync-live-matches-failed status=${response.status}`)
  }
}

async function loadTrackedGames(
  supabase: SupabaseClient,
  windowStart: string,
  windowEnd: string,
): Promise<TrackedGame[]> {
  const saved = await supabase
    .from("saved_pro_games")
    .select("id,user_id,live_match_id,source,external_id,home_team,away_team,league,sport,start_time,match_status,score_home,score_away,score_alerts_enabled,final_score_alerts_enabled,last_notified_scoreline,last_notified_status")
    .gte("start_time", windowStart)
    .lte("start_time", windowEnd)
    .limit(1000)

  if (saved.error) throw saved.error

  const favorite = await supabase
    .from("pro_game_alert_subscriptions")
    .select("id,user_id,live_match_id,source,external_id,home_team,away_team,league,sport,start_time,match_status,last_notified_scoreline,last_notified_status,score_alerts_enabled,final_score_alerts_enabled,score_home,score_away,subscription_source,favorite_team_id,favorite_team_name")
    .gte("start_time", windowStart)
    .lte("start_time", windowEnd)
    .or("score_alerts_enabled.eq.true,final_score_alerts_enabled.eq.true")
    .limit(1000)

  if (favorite.error) throw favorite.error

  return [
    ...((saved.data ?? []) as SavedProGameRow[]).map((row) => trackedFromSaved(row)),
    ...((favorite.data ?? []) as FavoriteProGameSubscriptionRow[]).map((row) => trackedFromFavorite(row)),
  ]
}

async function loadLiveMatches(
  supabase: SupabaseClient,
  windowStart: string,
  windowEnd: string,
): Promise<LiveMatchRow[]> {
  const { data, error } = await supabase
    .from("live_matches")
    .select("id,source,external_id,sport,home_team,away_team,score_home,score_away,match_status,league,start_time")
    .gte("start_time", windowStart)
    .lte("start_time", windowEnd)
    .limit(2000)

  if (error) throw error
  return (data ?? []) as LiveMatchRow[]
}

async function loadPushTokensByUser(
  supabase: SupabaseClient,
  userIds: string[],
): Promise<Map<string, PushTokenRow[]>> {
  const byUser = new Map<string, PushTokenRow[]>()
  if (userIds.length === 0) return byUser

  const { data, error } = await supabase
    .from("user_push_tokens")
    .select("id,user_id,token,environment")
    .in("user_id", userIds)
    .eq("is_active", true)
    .eq("platform", "ios")

  if (error) throw error
  for (const token of (data ?? []) as PushTokenRow[]) {
    byUser.set(token.user_id, [...(byUser.get(token.user_id) ?? []), token])
  }
  return byUser
}

async function loadUserPreferencesByUser(
  supabase: SupabaseClient,
  userIds: string[],
): Promise<Map<string, UserPreferenceRow>> {
  const byUser = new Map<string, UserPreferenceRow>()
  if (userIds.length === 0) return byUser

  const { data, error } = await supabase
    .from("user_notification_preferences")
    .select("user_id,pro_game_reminder_notifications_enabled,pro_game_final_score_alerts_enabled")
    .in("user_id", userIds)

  if (error) throw error
  for (const pref of (data ?? []) as UserPreferenceRow[]) {
    byUser.set(pref.user_id, pref)
  }
  return byUser
}

async function maybeSendKickoffUpdate(
  supabase: SupabaseClient,
  apns: ApnsClient,
  game: TrackedGame,
  tokensByUser: Map<string, PushTokenRow[]>,
  preferencesByUser: Map<string, UserPreferenceRow>,
  counts: WorkerCounts,
) {
  if (game.sourceKind !== "saved") return

  counts.kickoffCandidates += 1
  const nowMs = Date.now()
  const startMs = Date.parse(game.startTime)
  const windowEndMs = startMs + 3 * 60 * 1000
  if (!Number.isFinite(startMs) || nowMs < startMs || nowMs > windowEndMs) {
    counts.kickoffSkippedOutsideWindow += 1
    return
  }

  const remindersEnabled = preferencesByUser.get(game.userId)?.pro_game_reminder_notifications_enabled ?? true
  if (!remindersEnabled) {
    counts.kickoffSkippedSettings += 1
    return
  }

  const tokens = tokensByUser.get(game.userId) ?? []
  if (tokens.length === 0) {
    counts.kickoffSkippedNoToken += 1
    return
  }

  const inserted = await insertDeliveryDedupe(supabase, game, "kickoff", "kickoff")
  if (!inserted) {
    counts.kickoffSkippedDuplicate += 1
    return
  }

  const title = kickoffTitle(game)
  const body = `${game.awayTeam} vs ${game.homeTeam} starts now.`
  const sent = await sendToUserTokens(supabase, apns, tokens, title, body, counts)
  if (sent > 0) {
    counts.kickoffSent += sent
    counts.notificationsSent += sent
  }
}

async function maybeSendScoreUpdate(
  supabase: SupabaseClient,
  apns: ApnsClient,
  game: TrackedGame,
  live: LiveMatchRow,
  tokensByUser: Map<string, PushTokenRow[]>,
  counts: WorkerCounts,
) {
  if (!game.scoreAlertsEnabled) {
    counts.scoreSkippedSettings += 1
    return
  }

  const previousScoreline = game.lastNotifiedScoreline ?? scoreline(game.snapshotScoreAway, game.snapshotScoreHome)
  const latestScoreline = scoreline(live.score_away, live.score_home)
  const changed = previousScoreline !== latestScoreline
  console.log(`[ProScorePushWorker] saved scoreline=${previousScoreline}`)
  console.log(`[ProScorePushWorker] provider scoreline=${latestScoreline}`)
  console.log(`[ProScorePushWorker] score changed=${changed}`)
  if (!changed) return

  counts.scoreChangesFound += 1
  const tokens = tokensByUser.get(game.userId) ?? []
  if (tokens.length === 0) {
    counts.scoreSkippedNoToken += 1
    return
  }

  const inserted = await insertDeliveryDedupe(supabase, game, "score", latestScoreline)
  if (!inserted) {
    counts.scoreSkippedDuplicate += 1
    console.log(`[ProScorePushWorker] score skipped duplicate=true live_match_id=${game.liveMatchId} scoreline=${latestScoreline}`)
    return
  }

  const title = scoringTitle(game, live, previousScoreline)
  const body = `${live.away_team} ${live.score_away} - ${live.score_home} ${live.home_team}`
  const sent = await sendToUserTokens(supabase, apns, tokens, title, body, counts)
  console.log(`[ProScorePushWorker] score notification sent=${sent}`)
  if (sent > 0) {
    counts.scoreNotificationsSent += sent
    counts.notificationsSent += sent
    await updateTrackedGameNotificationState(supabase, game, {
      last_notified_scoreline: latestScoreline,
      match_status: live.match_status,
      score_home: live.score_home,
      score_away: live.score_away,
    })
  }
}

async function maybeSendFinalUpdate(
  supabase: SupabaseClient,
  apns: ApnsClient,
  game: TrackedGame,
  live: LiveMatchRow,
  tokensByUser: Map<string, PushTokenRow[]>,
  preferencesByUser: Map<string, UserPreferenceRow>,
  counts: WorkerCounts,
) {
  const globalFinalEnabled = preferencesByUser.get(game.userId)?.pro_game_final_score_alerts_enabled ?? true
  counts.finalCandidates += 1
  if (!globalFinalEnabled || !game.finalScoreAlertsEnabled) {
    counts.finalSkippedSettings += 1
    return
  }
  if (normalizeStatus(game.lastNotifiedStatus) === "FT") {
    counts.finalSkippedDuplicate += 1
    return
  }

  counts.finalChangesFound += 1
  const finalScoreline = scoreline(live.score_away, live.score_home)
  const tokens = tokensByUser.get(game.userId) ?? []
  if (tokens.length === 0) {
    counts.finalSkippedNoToken += 1
    return
  }

  const inserted = await insertDeliveryDedupe(supabase, game, "final", finalScoreline)
  if (!inserted) {
    counts.finalSkippedDuplicate += 1
    return
  }

  const body = `${live.away_team} ${live.score_away} - ${live.score_home} ${live.home_team}`
  const sent = await sendToUserTokens(supabase, apns, tokens, "FanGeo: Final score", body, counts)
  if (sent > 0) {
    counts.finalSent += sent
    counts.notificationsSent += sent
    await updateTrackedGameNotificationState(supabase, game, {
      last_notified_scoreline: finalScoreline,
      last_notified_status: "FT",
      match_status: live.match_status,
      score_home: live.score_home,
      score_away: live.score_away,
    })
  }
}

async function sendToUserTokens(
  supabase: SupabaseClient,
  apns: ApnsClient,
  tokens: PushTokenRow[],
  title: string,
  body: string,
  counts: WorkerCounts,
): Promise<number> {
  let sent = 0
  for (const token of tokens) {
    const result = await apns.send(token, title, body)
    if (result.ok) {
      sent += 1
      continue
    }
    if (result.invalidate) {
      counts.invalidTokens += 1
      await supabase
        .from("user_push_tokens")
        .update({ is_active: false, invalidated_at: new Date().toISOString() })
        .eq("id", token.id)
    }
    console.warn(`[ProScorePushWorker] skippedReason=apns_${result.reason ?? "unknown"} tokenId=${token.id}`)
  }
  return sent
}

async function insertDeliveryDedupe(
  supabase: SupabaseClient,
  game: TrackedGame,
  notificationType: NotificationType,
  scorelineValue: string,
): Promise<boolean> {
  const { error } = await supabase
    .from("pro_game_score_notification_deliveries")
    .insert({
      user_id: game.userId,
      game_id: game.liveMatchId,
      notification_type: notificationType,
      scoreline: scorelineValue,
    })

  if (!error) return true
  const message = `${error.code ?? ""} ${error.message ?? ""}`.toLowerCase()
  if (message.includes("23505") || message.includes("duplicate")) return false
  throw error
}

async function updateTrackedGameNotificationState(
  supabase: SupabaseClient,
  game: TrackedGame,
  patch: Record<string, unknown>,
) {
  await supabase
    .from(game.table)
    .update(patch)
    .eq("id", game.rowId)
}

function matchLiveRow(
  game: TrackedGame,
  liveById: Map<string, LiveMatchRow>,
  liveBySourceExternal: Map<string, LiveMatchRow>,
  liveMatches: LiveMatchRow[],
): { match: LiveMatchRow; matchedBy: string } | undefined {
  const direct = liveById.get(normalize(game.liveMatchId))
  if (direct) return { match: direct, matchedBy: "live_match_id" }
  if (game.source && game.externalId) {
    const sourceExternal = liveBySourceExternal.get(`${normalize(game.source)}:${normalize(game.externalId)}`)
    if (sourceExternal) return { match: sourceExternal, matchedBy: "source+external_id" }
  }

  const fallbackMatches = liveMatches.filter((candidate) => isSafeTeamDateMatch(game, candidate))
  if (fallbackMatches.length === 1) {
    return { match: fallbackMatches[0], matchedBy: "teams+date" }
  }

  return undefined
}

function isSafeTeamDateMatch(game: TrackedGame, match: LiveMatchRow): boolean {
  const gameAway = normalizedTeamText(game.awayTeam)
  const gameHome = normalizedTeamText(game.homeTeam)
  const matchAway = normalizedTeamText(match.away_team)
  const matchHome = normalizedTeamText(match.home_team)
  if (!gameAway || !gameHome || gameAway !== matchAway || gameHome !== matchHome) return false

  const gameSport = normalizedTeamText(game.sport)
  const matchSport = normalizedTeamText(match.sport)
  if (gameSport && matchSport && gameSport !== matchSport) return false

  const gameStart = Date.parse(game.startTime)
  const matchStart = Date.parse(match.start_time)
  if (!Number.isFinite(gameStart) || !Number.isFinite(matchStart)) return false
  return Math.abs(gameStart - matchStart) <= 6 * 60 * 60 * 1000
}

function normalizedTeamText(raw: string | null | undefined): string {
  return (raw ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/&/g, " and ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
}

function isLikelyStaleLiveData(
  game: TrackedGame,
  live: LiveMatchRow,
  status: "LIVE" | "HT" | "FT" | "SCHEDULED" | "OTHER",
): boolean {
  if (status === "LIVE" || status === "HT" || status === "FT") return false
  const gameStart = Date.parse(game.startTime)
  const liveStart = Date.parse(live.start_time)
  const now = Date.now()
  const referenceStart = Number.isFinite(liveStart) ? liveStart : gameStart
  return Number.isFinite(referenceStart) && now >= referenceStart
}

function hasGameStarted(game: TrackedGame): boolean {
  const gameStart = Date.parse(game.startTime)
  return Number.isFinite(gameStart) && Date.now() >= gameStart
}

function trackedFromSaved(row: SavedProGameRow): TrackedGame {
  return {
    table: "saved_pro_games",
    rowId: row.id,
    userId: row.user_id,
    liveMatchId: row.live_match_id,
    source: row.source,
    externalId: row.external_id,
    homeTeam: row.home_team,
    awayTeam: row.away_team,
    league: row.league,
    sport: row.sport,
    startTime: row.start_time,
    snapshotScoreHome: row.score_home ?? 0,
    snapshotScoreAway: row.score_away ?? 0,
    scoreAlertsEnabled: row.score_alerts_enabled,
    finalScoreAlertsEnabled: row.final_score_alerts_enabled,
    lastNotifiedScoreline: row.last_notified_scoreline,
    lastNotifiedStatus: row.last_notified_status,
    sourceKind: "saved",
  }
}

function trackedFromFavorite(row: FavoriteProGameSubscriptionRow): TrackedGame {
  return {
    table: "pro_game_alert_subscriptions",
    rowId: row.id,
    userId: row.user_id,
    liveMatchId: row.live_match_id,
    source: row.source,
    externalId: row.external_id,
    homeTeam: row.home_team,
    awayTeam: row.away_team,
    league: row.league,
    sport: row.sport,
    startTime: row.start_time,
    snapshotScoreHome: row.score_home ?? 0,
    snapshotScoreAway: row.score_away ?? 0,
    scoreAlertsEnabled: row.score_alerts_enabled,
    finalScoreAlertsEnabled: row.final_score_alerts_enabled,
    lastNotifiedScoreline: row.last_notified_scoreline,
    lastNotifiedStatus: row.last_notified_status,
    sourceKind: "favorite_team",
  }
}

function scoringTitle(game: TrackedGame, live: LiveMatchRow, previousScoreline: string): string {
  const previous = parseScoreline(previousScoreline)
  if (!previous) return "Score update"
  if (live.score_away > previous.away && live.score_home <= previous.home) return `${live.away_team || game.awayTeam} scored`
  if (live.score_home > previous.home && live.score_away <= previous.away) return `${live.home_team || game.homeTeam} scored`
  return "Score update"
}

function kickoffTitle(game: TrackedGame): string {
  const league = (game.league ?? "").trim()
  if (league && !["pro game", "live", "sports"].includes(league.toLowerCase())) {
    return `FanGeo: ${league}`
  }
  return "FanGeo: Game starting"
}

function parseScoreline(raw: string): { away: number; home: number } | null {
  const match = raw.match(/^(\d+)-(\d+)$/)
  if (!match) return null
  return { away: Number(match[1]), home: Number(match[2]) }
}

function scoreline(away: number, home: number): string {
  return `${away}-${home}`
}

function normalizeStatus(raw: string | null): "LIVE" | "HT" | "FT" | "SCHEDULED" | "OTHER" {
  const status = normalize(raw)
  const compact = status.replace(/[_-]+/g, " ")
  if (["ht", "halftime", "half time"].includes(compact)) return "HT"
  if (
    ["ft", "final", "completed", "complete", "finished", "fulltime", "full time", "match finished", "after extra time", "penalties finished", "after penalties", "aet", "pen", "ended", "end", "game over"].includes(compact)
    || compact.includes("final")
    || compact.includes("finished")
    || compact.includes("completed")
    || compact.includes("full time")
  ) return "FT"
  if (
    ["live", "inplay", "in play", "in progress", "1h", "2h", "et", "bt", "p", "ot", "q1", "q2", "q3", "q4"].includes(compact)
    || compact.includes("live")
    || compact.includes("in progress")
    || compact.includes("in play")
    || compact.includes("playing")
    || compact.includes("active")
    || compact.includes("started")
    || compact.includes("extra inning")
    || compact.includes("'")
    || compact.includes("period")
    || compact.includes("inning")
  ) return "LIVE"
  if (["scheduled", "upcoming", "not started"].includes(compact)) return "SCHEDULED"
  return "OTHER"
}

function normalize(raw: string | null | undefined): string {
  return (raw ?? "").trim().toLowerCase()
}

class ApnsClient {
  private constructor(
    private readonly keyId: string,
    private readonly teamId: string,
    private readonly bundleId: string,
    private readonly defaultEnvironment: "sandbox" | "production",
    private readonly privateKey: CryptoKey,
    private jwt: { token: string; issuedAt: number } | null = null,
  ) {}

  static async fromEnvironment(): Promise<ApnsClient> {
    const keyId = requireEnv("APNS_KEY_ID")
    const teamId = requireEnv("APNS_TEAM_ID")
    const bundleId = requireEnv("APNS_BUNDLE_ID")
    const defaultEnvironment = normalizeApnsEnvironment(Deno.env.get("APNS_ENVIRONMENT"))
    const privateKeyPem = requireEnv("APNS_PRIVATE_KEY").replace(/\\n/g, "\n")
    const privateKey = await importPrivateKey(privateKeyPem)
    return new ApnsClient(keyId, teamId, bundleId, defaultEnvironment, privateKey)
  }

  async send(
    token: PushTokenRow,
    title: string,
    body: string,
  ): Promise<{ ok: boolean; reason?: string; invalidate?: boolean }> {
    const authorization = await this.authorizationHeader()
    const environment = token.environment ?? this.defaultEnvironment
    const host = environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com"
    const response = await fetch(`${host}/3/device/${token.token}`, {
      method: "POST",
      headers: {
        authorization,
        "apns-topic": this.bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        aps: {
          alert: { title, body },
          sound: "default",
        },
      }),
    })

    if (response.status === 200) return { ok: true }
    const payload = await response.json().catch(() => ({}))
    const reason = typeof payload?.reason === "string" ? payload.reason : `status_${response.status}`
    const invalidate = ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].includes(reason)
    return { ok: false, reason, invalidate }
  }

  private async authorizationHeader(): Promise<string> {
    const nowSeconds = Math.floor(Date.now() / 1000)
    if (this.jwt && nowSeconds - this.jwt.issuedAt < 50 * 60) {
      return `bearer ${this.jwt.token}`
    }

    const header = base64UrlJson({ alg: "ES256", kid: this.keyId })
    const payload = base64UrlJson({ iss: this.teamId, iat: nowSeconds })
    const signingInput = `${header}.${payload}`
    const signature = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      this.privateKey,
      new TextEncoder().encode(signingInput),
    )
    const token = `${signingInput}.${base64UrlBytes(new Uint8Array(signature))}`
    this.jwt = { token, issuedAt: nowSeconds }
    return `bearer ${token}`
  }
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "")
  const binary = Uint8Array.from(atob(base64), (char) => char.charCodeAt(0))
  return crypto.subtle.importKey(
    "pkcs8",
    binary.buffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  )
}

function base64UrlJson(value: unknown): string {
  return base64UrlBytes(new TextEncoder().encode(JSON.stringify(value)))
}

function base64UrlBytes(bytes: Uint8Array): string {
  let binary = ""
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "")
}

function requireEnv(name: string): string {
  const value = Deno.env.get(name)
  if (!value) throw new Error(`Missing required env var: ${name}`)
  return value
}

function normalizeApnsEnvironment(raw: string | null): "sandbox" | "production" {
  return raw === "production" ? "production" : "sandbox"
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json" },
  })
}
