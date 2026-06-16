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
  subscription_source: "manual" | "favorite_team_auto"
  alert_override: "inherit" | "on" | "off" | "muted" | null
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
  subscriptionSource: "manual" | "favorite_team_auto" | null
  alertOverride: "inherit" | "on" | "off" | "muted"
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
  timeline_events: TimelineEventRow[] | null
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

type PushTokenRow = {
  id: string
  user_id: string
  token: string
  environment: "sandbox" | "production"
}

type ApnsSendResult = {
  ok: boolean
  status: number
  endpoint: string
  tokenEnvironment: "sandbox" | "production"
  reason?: string
  invalidate?: boolean
}

type PushAlertContent = {
  title: string
  subtitle?: string
  body: string
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

const SCORE_WINDOW_PAST_HOURS = 24
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
    .select("id,user_id,live_match_id,source,external_id,home_team,away_team,league,sport,start_time,match_status,last_notified_scoreline,last_notified_status,score_alerts_enabled,final_score_alerts_enabled,score_home,score_away,subscription_source,alert_override,favorite_team_id,favorite_team_name")
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
    .select("id,source,external_id,sport,home_team,away_team,score_home,score_away,match_status,league,start_time,timeline_events")
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
  counts.kickoffCandidates += 1
  const nowMs = Date.now()
  const startMs = Date.parse(game.startTime)
  const windowEndMs = startMs + 3 * 60 * 1000
  if (!Number.isFinite(startMs) || nowMs < startMs || nowMs > windowEndMs) {
    counts.kickoffSkippedOutsideWindow += 1
    return
  }

  if (isMutedFavoriteTeamAutoAlert(game)) {
    counts.kickoffSkippedSettings += 1
    console.log(`[ProScorePushWorker] kickoff skipped settings=true reason=mutedFavoriteTeamAuto live_match_id=${game.liveMatchId}`)
    return
  }

  const remindersEnabled = game.sourceKind === "favorite_team"
    ? true
    : preferencesByUser.get(game.userId)?.pro_game_reminder_notifications_enabled ?? true
  if (!remindersEnabled) {
    counts.kickoffSkippedSettings += 1
    return
  }

  const tokens = tokensByUser.get(game.userId) ?? []
  if (tokens.length === 0) {
    counts.kickoffSkippedNoToken += 1
    return
  }

  const duplicate = await deliveryDedupeExists(supabase, game, "kickoff", "kickoff")
  if (duplicate) {
    counts.kickoffSkippedDuplicate += 1
    return
  }

  const sent = await sendToUserTokens(supabase, apns, tokens, kickoffNotificationContent(game), counts)
  if (sent > 0) {
    const recorded = await insertDeliveryDedupe(supabase, game, "kickoff", "kickoff")
    logDeliveryRecorded("kickoff", game, "kickoff", recorded)
    if (recorded) {
      counts.kickoffSent += sent
      counts.notificationsSent += sent
    } else {
      counts.kickoffSkippedDuplicate += 1
    }
  } else {
    logDeliveryRecorded("kickoff", game, "kickoff", false)
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
  if (isMutedFavoriteTeamAutoAlert(game)) {
    counts.scoreSkippedSettings += 1
    console.log(`[ProScorePushWorker] score skipped settings=true reason=mutedFavoriteTeamAuto live_match_id=${game.liveMatchId}`)
    return
  }

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

  const duplicate = await deliveryDedupeExists(supabase, game, "score", latestScoreline)
  if (duplicate) {
    counts.scoreSkippedDuplicate += 1
    console.log(`[ProScorePushWorker] score skipped duplicate=true live_match_id=${game.liveMatchId} scoreline=${latestScoreline}`)
    return
  }

  const liveWithTimeline = await hydrateLiveMatchWithTimeline(supabase, game, live)
  const alert = scoringNotificationContent(game, liveWithTimeline, previousScoreline)
  const sent = await sendToUserTokens(supabase, apns, tokens, alert, counts)
  console.log(`[ProScorePushWorker] score notification sent=${sent}`)
  if (sent > 0) {
    const recorded = await insertDeliveryDedupe(supabase, game, "score", latestScoreline)
    logDeliveryRecorded("score", game, latestScoreline, recorded)
    if (recorded) {
      counts.scoreNotificationsSent += sent
      counts.notificationsSent += sent
      await updateTrackedGameNotificationState(supabase, game, {
        last_notified_scoreline: latestScoreline,
        match_status: live.match_status,
        score_home: live.score_home,
        score_away: live.score_away,
      })
    } else {
      counts.scoreSkippedDuplicate += 1
    }
  } else {
    logDeliveryRecorded("score", game, latestScoreline, false)
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
  if (isMutedFavoriteTeamAutoAlert(game)) {
    counts.finalSkippedSettings += 1
    console.log(`[ProScorePushWorker] final skipped settings=true reason=mutedFavoriteTeamAuto live_match_id=${game.liveMatchId}`)
    return
  }
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

  const duplicate = await deliveryDedupeExists(supabase, game, "final", finalScoreline)
  if (duplicate) {
    counts.finalSkippedDuplicate += 1
    return
  }

  const sent = await sendToUserTokens(supabase, apns, tokens, finalNotificationContent(game, live), counts)
  if (sent > 0) {
    const recorded = await insertDeliveryDedupe(supabase, game, "final", finalScoreline)
    logDeliveryRecorded("final", game, finalScoreline, recorded)
    if (recorded) {
      counts.finalSent += sent
      counts.notificationsSent += sent
      await updateTrackedGameNotificationState(supabase, game, {
        last_notified_scoreline: finalScoreline,
        last_notified_status: "FT",
        match_status: live.match_status,
        score_home: live.score_home,
        score_away: live.score_away,
      })
    } else {
      counts.finalSkippedDuplicate += 1
    }
  } else {
    logDeliveryRecorded("final", game, finalScoreline, false)
  }
}

async function sendToUserTokens(
  supabase: SupabaseClient,
  apns: ApnsClient,
  tokens: PushTokenRow[],
  alert: PushAlertContent,
  counts: WorkerCounts,
): Promise<number> {
  let sent = 0
  for (const token of tokens) {
    const result = await apns.send(token, alert)
    if (result.ok) {
      sent += 1
      continue
    }
    console.warn(`[ProScorePushWorker] apns endpoint=${result.endpoint}`)
    console.warn(`[ProScorePushWorker] apns tokenEnvironment=${result.tokenEnvironment}`)
    console.warn(`[ProScorePushWorker] apns status=${result.status}`)
    console.warn(`[ProScorePushWorker] apns reason=${result.reason ?? "unknown"}`)
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

async function deliveryDedupeExists(
  supabase: SupabaseClient,
  game: TrackedGame,
  notificationType: NotificationType,
  scorelineValue: string,
): Promise<boolean> {
  const { data, error } = await supabase
    .from("pro_game_score_notification_deliveries")
    .select("id")
    .eq("user_id", game.userId)
    .eq("game_id", game.liveMatchId)
    .eq("notification_type", notificationType)
    .eq("scoreline", scorelineValue)
    .limit(1)

  if (error) throw error
  return (data ?? []).length > 0
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

function logDeliveryRecorded(
  notificationType: NotificationType,
  game: TrackedGame,
  scorelineValue: string,
  recorded: boolean,
) {
  console.log(
    `[ProScorePushWorker] delivery recorded=${recorded} type=${notificationType} ` +
      `gameId=${game.liveMatchId} scoreline=${scorelineValue}`,
  )
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
    subscriptionSource: null,
    alertOverride: "inherit",
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
    subscriptionSource: row.subscription_source,
    alertOverride: favoriteTeamAlertOverride(row.alert_override),
  }
}

function isMutedFavoriteTeamAutoAlert(game: TrackedGame): boolean {
  return game.sourceKind === "favorite_team"
    && game.subscriptionSource === "favorite_team_auto"
    && ["off", "muted"].includes(game.alertOverride)
}

function favoriteTeamAlertOverride(
  raw: FavoriteProGameSubscriptionRow["alert_override"],
): TrackedGame["alertOverride"] {
  if (raw === "on" || raw === "off" || raw === "muted") return raw
  return "inherit"
}

type ScoringSide = "home" | "away"
type ProScoreSportKind = "soccer" | "hockey" | "football" | "baseball" | "basketball" | "other"

type ScoringEventMatch = {
  player: string | null
  gameClock: string | null
  detail: string | null
  summary: string | null
  scoringTeam: string
  scoringTeamPlain: string
  scoringSide: ScoringSide
  raw: TimelineEventRow
}

function scoringNotificationContent(game: TrackedGame, live: LiveMatchRow, previousScoreline: string): PushAlertContent {
  const fallback = fallbackScoreNotificationContent(game, live, previousScoreline)
  const timelineEvents = normalizeTimelineEventsForWorker(live.timeline_events)
  const scoreAfter = scoreline(live.score_away, live.score_home)
  const sportKind = proScoreSportKind(game, live)
  const scoringEventsCount = timelineEvents.filter((event) => isScoringTimelineEvent(event, sportKind)).length
  goalNotificationLog(`gameId=${game.liveMatchId}`)
  goalNotificationLog(`sport=${sportKind}`)
  goalNotificationLog(`timelineCount=${timelineEvents.length}`)
  goalNotificationLog(`scoringEventsCount=${scoringEventsCount}`)
  goalNotificationLog(`scoreBefore=${previousScoreline}`)
  goalNotificationLog(`scoreAfter=${scoreAfter}`)

  const previous = parseScoreline(previousScoreline)
  if (!previous) {
    logScoringEventFallback("missingPreviousScoreline", null, fallback, "unknown", timelineEvents, sportKind)
    logPushFormat("score", game, live, fallback)
    return fallback
  }

  const scoringSide = scoringSideForScoreChange(previous, live)
  if (!scoringSide) {
    logScoringEventFallback("ambiguousScoreChange", null, fallback, "unknown", timelineEvents, sportKind)
    logPushFormat("score", game, live, fallback)
    return fallback
  }
  const scoringTeamPlain = teamNameForSide(live, scoringSide)
  goalNotificationLog(`scoringTeam=${scoringTeamPlain}`)

  const scoringEventResult = mostRecentScoringEvent(game, live, timelineEvents, scoringSide, sportKind, {
    previous,
    scoreAfter,
  })
  const scoringEvent = scoringEventResult.event
  if (!scoringEvent) {
    logScoringEventFallback(
      scoringEventResult.fallbackReason,
      null,
      fallback,
      scoringTeamPlain,
      timelineEvents,
      sportKind,
    )
    logPushFormat("score", game, live, fallback)
    return fallback
  }

  console.log("[ProScorePushWorker] scoringEventMatched=true")
  console.log(`[ProScorePushWorker] scoringEventPlayer=${scoringEvent.player ?? "unknown"}`)
  console.log(`[ProScorePushWorker] scoringEventTime=${scoringEvent.gameClock ?? "unknown"}`)
  console.log("[ProScorePushWorker] scoringEventFallback=false")
  goalNotificationLog(`fallbackReason=none`)
  goalNotificationLog(`selectedScoringEvent=${timelineEventDebugSummary(scoringEvent.raw)}`)
  goalNotificationLog(`scoringTeam=${scoringEvent.scoringTeamPlain}`)
  goalNotificationLog(`scorer=${scoringEvent.player ?? "unknown"}`)
  goalNotificationLog(`gameClock=${scoringEvent.gameClock ?? "unknown"}`)
  const subtitle = scoringEventSubtitle(scoringEvent, sportKind)
  if ((sportKind === "soccer" || sportKind === "hockey") && !subtitle) {
    logScoringEventFallback("missingSubtitle", scoringEvent, fallback, scoringTeamPlain, timelineEvents, sportKind)
    logPushFormat("score", game, live, fallback)
    return fallback
  }
  const alert = {
    title: scoringEventNotificationTitle(game, live, scoringEvent, sportKind),
    subtitle,
    body: scoreNotificationBody(game, live),
  }
  goalNotificationLog(`notificationTitle=${alert.title}`)
  goalNotificationLog(`notificationSubtitle=${alert.subtitle ?? "nil"}`)
  logPushFormat("score", game, live, alert)
  return alert
}

function kickoffNotificationContent(game: TrackedGame): PushAlertContent {
  const alert = {
    title: `${sportIconForGame(game) ?? ""} ${formattedTeamName(game.awayTeam)} vs ${formattedTeamName(game.homeTeam)}`.trim(),
    body: "Starting now",
  }
  logPushFormat("kickoff", game, null, alert)
  return alert
}

function fallbackScoreNotificationContent(game: TrackedGame, live: LiveMatchRow, previousScoreline: string): PushAlertContent {
  const previous = parseScoreline(previousScoreline)
  const scoringSide = previous ? scoringSideForScoreChange(previous, live) : null
  const scoringTeamPlain = scoringSide ? teamNameForSide(live, scoringSide) : null
  const sportKind = proScoreSportKind(game, live)
  const sportIcon = sportIconForGame(game, live)
  const title = scoringTeamPlain
    ? goalNotificationTitle(scoringTeamPlain, sportKind, sportIcon)
    : `${sportIcon ?? ""} Score update`.trim()
  const alert = {
    title,
    body: scoreNotificationBody(game, live),
  }
  return alert
}

function goalNotificationTitle(
  scoringTeamPlain: string,
  sportKind: ProScoreSportKind,
  sportIcon: string | null,
): string {
  const teamWithFlag = formattedTeamName(scoringTeamPlain)
  if (sportKind === "soccer") return `${sportIcon ?? "⚽"} GOAL! ${teamWithFlag}`.trim()
  if (sportKind === "hockey") return `${sportIcon ?? "🏒"} GOAL! ${teamWithFlag}`.trim()
  return `${sportIcon ?? ""} ${teamWithFlag} scored`.trim()
}

async function hydrateLiveMatchWithTimeline(
  supabase: SupabaseClient,
  game: TrackedGame,
  live: LiveMatchRow,
): Promise<LiveMatchRow> {
  const fetched = await fetchTimelineEventsForNotification(supabase, game, live)
  const embedded = normalizeTimelineEventsForWorker(live.timeline_events)
  const timeline_events = fetched.length > 0 ? fetched : embedded
  goalNotificationLog(`timelineFetchCount=${fetched.length}`)
  goalNotificationLog(`timelineEmbeddedCount=${embedded.length}`)
  goalNotificationLog(`timelineUsedCount=${timeline_events.length}`)
  return {
    ...live,
    timeline_events,
  }
}

async function fetchTimelineEventsForNotification(
  supabase: SupabaseClient,
  game: TrackedGame,
  live: LiveMatchRow,
): Promise<TimelineEventRow[]> {
  const lookupIds = [...new Set([
    game.liveMatchId,
    live.id,
  ].map((value) => value.trim()).filter(Boolean))]

  for (const id of lookupIds) {
    const { data, error } = await supabase
      .from("live_matches")
      .select("id,timeline_events")
      .eq("id", id)
      .maybeSingle()

    if (error) {
      goalNotificationLog(`timelineFetchError id=${id} message=${error.message}`)
      continue
    }

    const events = normalizeTimelineEventsForWorker(data?.timeline_events)
    if (events.length > 0) {
      goalNotificationLog(`timelineFetchSource=id id=${data?.id ?? id}`)
      return events
    }
  }

  if (game.source && game.externalId) {
    const { data, error } = await supabase
      .from("live_matches")
      .select("id,timeline_events")
      .eq("source", game.source)
      .eq("external_id", game.externalId)
      .maybeSingle()

    if (error) {
      goalNotificationLog(`timelineFetchError source=${game.source} externalId=${game.externalId} message=${error.message}`)
    } else {
      const events = normalizeTimelineEventsForWorker(data?.timeline_events)
      if (events.length > 0) {
        goalNotificationLog(`timelineFetchSource=sourceExternal id=${data?.id ?? "unknown"}`)
        return events
      }
    }
  }

  if (live.source && live.external_id) {
    const { data, error } = await supabase
      .from("live_matches")
      .select("id,timeline_events")
      .eq("source", live.source)
      .eq("external_id", live.external_id)
      .maybeSingle()

    if (error) {
      goalNotificationLog(`timelineFetchError liveSource=${live.source} liveExternalId=${live.external_id} message=${error.message}`)
    } else {
      const events = normalizeTimelineEventsForWorker(data?.timeline_events)
      if (events.length > 0) {
        goalNotificationLog(`timelineFetchSource=liveSourceExternal id=${data?.id ?? "unknown"}`)
        return events
      }
    }
  }

  return []
}

function normalizeTimelineEventsForWorker(raw: unknown): TimelineEventRow[] {
  if (!Array.isArray(raw)) return []
  return raw
    .map((row) => normalizeTimelineEventRow(row))
    .filter(isTimelineEventRow)
}

function normalizeTimelineEventRow(row: unknown): TimelineEventRow {
  const record = row && typeof row === "object" ? row as Record<string, unknown> : {}
  return {
    idTimeline: cleanTimelineText(typeof record.idTimeline === "string" ? record.idTimeline : null),
    idEvent: cleanTimelineText(typeof record.idEvent === "string" ? record.idEvent : null),
    strTimeline: cleanTimelineText(typeof record.strTimeline === "string" ? record.strTimeline : null),
    strTimelineDetail: cleanTimelineText(typeof record.strTimelineDetail === "string" ? record.strTimelineDetail : null,
    ),
    strHome: cleanTimelineText(typeof record.strHome === "string" ? record.strHome : null),
    idPlayer: cleanTimelineText(typeof record.idPlayer === "string" ? record.idPlayer : null),
    strPlayer: cleanTimelineText(typeof record.strPlayer === "string" ? record.strPlayer : null),
    idAssist: cleanTimelineText(typeof record.idAssist === "string" ? record.idAssist : null),
    strAssist: cleanTimelineText(typeof record.strAssist === "string" ? record.strAssist : null),
    intTime: cleanTimelineText(typeof record.intTime === "string" || typeof record.intTime === "number"
      ? String(record.intTime)
      : null),
    idTeam: cleanTimelineText(typeof record.idTeam === "string" ? record.idTeam : null),
    strTeam: cleanTimelineText(typeof record.strTeam === "string" ? record.strTeam : null),
    strComment: cleanTimelineText(typeof record.strComment === "string" ? record.strComment : null),
    dateEvent: cleanTimelineText(typeof record.dateEvent === "string" ? record.dateEvent : null),
    strSeason: cleanTimelineText(typeof record.strSeason === "string" ? record.strSeason : null),
  }
}

function isTimelineEventRow(row: TimelineEventRow): boolean {
  return Boolean(row.strTimeline || row.strPlayer || row.strTeam)
}

function finalNotificationContent(game: TrackedGame, live: LiveMatchRow): PushAlertContent {
  const alert = {
    title: "🏁 Final Score",
    body: scoreNotificationBody(game, live),
  }
  logPushFormat("final", game, live, alert)
  return alert
}

function scoreNotificationBody(game: TrackedGame, live: LiveMatchRow): string {
  return `${formattedTeamName(live.away_team || game.awayTeam)} ${live.score_away} - ${live.score_home} ${formattedTeamName(live.home_team || game.homeTeam)}`
}

function teamNameForSide(live: LiveMatchRow, side: ScoringSide): string {
  return side === "away" ? live.away_team : live.home_team
}

function sportIconForGame(game: TrackedGame, live?: LiveMatchRow | null): string | null {
  const text = normalize([
    game.sport,
    live?.sport,
    game.league,
    live?.league,
  ].filter(Boolean).join(" "))
  if (!text) return null
  if (text.includes("american football") || text.includes("nfl")) return "🏈"
  if (text.includes("basketball") || text.includes("nba")) return "🏀"
  if (text.includes("hockey") || text.includes("nhl")) return "🏒"
  if (text.includes("baseball") || text.includes("mlb")) return "⚾"
  if (text.includes("softball")) return "🥎"
  if (text.includes("tennis")) return "🎾"
  if (
    text.includes("soccer")
    || text.includes("football")
    || text.includes("world cup")
    || text.includes("fifa")
    || text.includes("uefa")
    || text.includes("friendly")
    || text.includes("nations league")
  ) return "⚽"
  return null
}

function formattedTeamName(teamName: string | null | undefined): string {
  const name = (teamName ?? "").trim()
  if (!name) return ""
  const flag = flagEmojiForTeam(name)
  return flag ? `${flag} ${name}` : name
}

function flagEmojiForTeam(teamName: string | null | undefined): string | null {
  const regionCode = iso2RegionCodeForTeam(teamName)
  return regionCode ? flagEmojiForRegionCode(regionCode) : null
}

function iso2RegionCodeForTeam(teamName: string | null | undefined): string | null {
  const trimmed = (teamName ?? "").trim()
  if (!trimmed) return null

  const upper = trimmed.toUpperCase()
  if (upper.length === 2 && /^[A-Z]{2}$/.test(upper)) {
    return supportedIso2RegionCodes.has(upper) ? upper : null
  }
  if (upper.length === 3 && /^[A-Z]{3}$/.test(upper)) {
    return fifaOrIso3RegionCode[upper] ?? null
  }

  const normalizedName = normalizeCountryText(trimmed)
  if (!normalizedName) return null
  const withoutSuffix = normalizedCountryTeamSuffixRemoved(normalizedName)
  return countryNameRegionCode[withoutSuffix] ?? countryNameRegionCode[normalizedName] ?? null
}

const fifaOrIso3RegionCode: Record<string, string | null> = {
  COD: "CD",
  CIV: "CI",
  CZE: "CZ",
  CUW: "CW",
  ENG: null,
  GER: "DE",
  KOR: "KR",
  MEX: "MX",
  NED: "NL",
  NIR: null,
  PRK: "KP",
  SCO: null,
  UAE: "AE",
  USA: "US",
  WAL: null,
}

const countryNameRegionCode: Record<string, string> = {
  argentina: "AR",
  australia: "AU",
  belgium: "BE",
  bolivia: "BO",
  brazil: "BR",
  brasil: "BR",
  canada: "CA",
  chile: "CL",
  china: "CN",
  colombia: "CO",
  "costa rica": "CR",
  curacao: "CW",
  "cote d ivoire": "CI",
  "czech republic": "CZ",
  czechia: "CZ",
  "democratic republic of congo": "CD",
  denmark: "DK",
  "dr congo": "CD",
  "d r congo": "CD",
  ecuador: "EC",
  egypt: "EG",
  france: "FR",
  germany: "DE",
  deutschland: "DE",
  ghana: "GH",
  haiti: "HT",
  holland: "NL",
  iran: "IR",
  iraq: "IQ",
  "ivory coast": "CI",
  japan: "JP",
  jordan: "JO",
  korea: "KR",
  "korea dpr": "KP",
  mexico: "MX",
  morocco: "MA",
  netherlands: "NL",
  "north korea": "KP",
  norway: "NO",
  panama: "PA",
  peru: "PE",
  poland: "PL",
  portugal: "PT",
  qatar: "QA",
  "republic of korea": "KR",
  russia: "RU",
  "saudi arabia": "SA",
  senegal: "SN",
  serbia: "RS",
  "south africa": "ZA",
  "south korea": "KR",
  spain: "ES",
  sweden: "SE",
  switzerland: "CH",
  tunisia: "TN",
  turkey: "TR",
  turkiye: "TR",
  uae: "AE",
  "united arab emirates": "AE",
  "united states": "US",
  "united states of america": "US",
  uruguay: "UY",
  usa: "US",
  uzbekistan: "UZ",
}

const supportedIso2RegionCodes = new Set([
  ...Object.values(countryNameRegionCode),
  ...Object.values(fifaOrIso3RegionCode).filter((code): code is string => Boolean(code)),
])

function normalizedCountryTeamSuffixRemoved(normalizedName: string): string {
  const suffixes = [
    " national team",
    " women",
    " men",
    " womens",
    " mens",
    " u17",
    " u18",
    " u19",
    " u20",
    " u21",
    " u23",
  ]
  const suffix = suffixes.find((candidate) => normalizedName.endsWith(candidate))
  if (!suffix) return normalizedName
  return normalizedName.slice(0, -suffix.length).trim()
}

function normalizeCountryText(value: string): string {
  return value
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .replace(/&/g, " and ")
    .replace(/[^a-zA-Z0-9]+/g, " ")
    .trim()
    .toLowerCase()
}

function flagEmojiForRegionCode(regionCode: string): string | null {
  const code = regionCode.trim().toUpperCase()
  if (!/^[A-Z]{2}$/.test(code)) return null
  return [...code]
    .map((letter) => String.fromCodePoint(127397 + letter.charCodeAt(0)))
    .join("")
}

function logPushFormat(context: string, game: TrackedGame, live: LiveMatchRow | null, alert: PushAlertContent): void {
  const sportIcon = context === "final" ? "🏁" : sportIconForGame(game, live)
  const homeTeam = live?.home_team || game.homeTeam
  const awayTeam = live?.away_team || game.awayTeam
  console.log(`[PushFormatDebug] context=${context}`)
  console.log(`[PushFormatDebug] sportIcon=${sportIcon ?? ""}`)
  console.log(`[PushFormatDebug] homeFlag=${flagEmojiForTeam(homeTeam) ?? ""}`)
  console.log(`[PushFormatDebug] awayFlag=${flagEmojiForTeam(awayTeam) ?? ""}`)
  console.log(`[PushFormatDebug] formattedTitle=${alert.title}`)
  console.log(`[PushFormatDebug] formattedBody=${alert.body}`)
}

function proScoreSportKind(game: TrackedGame, live: LiveMatchRow): ProScoreSportKind {
  const text = normalize(`${game.sport ?? ""} ${live.sport ?? ""} ${game.league ?? ""} ${live.league ?? ""}`)
  if (text.includes("american football") || text.includes("nfl") || text.includes("gridiron")) return "football"
  if (text.includes("hockey") || text.includes("nhl")) return "hockey"
  if (text.includes("baseball") || text.includes("mlb")) return "baseball"
  if (text.includes("basketball") || text.includes("nba")) return "basketball"
  if (
    text.includes("soccer")
    || text.includes("football")
    || text.includes("fifa")
    || text.includes("uefa")
    || text.includes("friendly")
    || text.includes("world cup")
    || text.includes("nations league")
  ) return "soccer"
  return "other"
}

function scoringSideForScoreChange(
  previous: { away: number; home: number },
  live: LiveMatchRow,
): ScoringSide | null {
  const awayDelta = live.score_away - previous.away
  const homeDelta = live.score_home - previous.home
  if (awayDelta > 0 && homeDelta <= 0) return "away"
  if (homeDelta > 0 && awayDelta <= 0) return "home"
  return null
}

function mostRecentScoringEvent(
  game: TrackedGame,
  live: LiveMatchRow,
  events: TimelineEventRow[],
  scoringSide: ScoringSide,
  sportKind: ProScoreSportKind,
  scoreContext: {
    previous: { away: number; home: number }
    scoreAfter: string
  },
): { event: ScoringEventMatch | null; fallbackReason: string } {
  if (events.length === 0) {
    return { event: null, fallbackReason: "noTimelineEvents" }
  }

  const scoringEvents = events
    .map((event, index) => ({ event, index }))
    .filter(({ event }) => isScoringTimelineEvent(event, sportKind))

  if (scoringEvents.length === 0) {
    return {
      event: null,
      fallbackReason: sportKind === "basketball" ? "basketballNoMeaningfulScoringSummary" : "noScoringEventsInTimeline",
    }
  }

  const scoringTeamName = normalizeTeamText(teamNameForSide(live, scoringSide))
  let candidates = scoringEvents.filter(({ event }) =>
    timelineEventMatchesScoringTeam(event, live, scoringSide)
  )

  if (candidates.length === 0 && scoringTeamName) {
    candidates = scoringEvents.filter(({ event }) =>
      normalizeTeamText(event.strTeam) === scoringTeamName
    )
    if (candidates.length > 0) {
      goalNotificationLog(`fallbackReason=teamNameMatchUsed team=${scoringTeamName}`)
    }
  }

  candidates = candidates.sort((lhs, rhs) => {
      const lhsMinute = timelineEventMinuteNumber(lhs.event)
      const rhsMinute = timelineEventMinuteNumber(rhs.event)
      if (lhsMinute !== rhsMinute) return rhsMinute - lhsMinute
      return rhs.index - lhs.index
    })

  const match = candidates[0]?.event
  if (!match) {
    goalNotificationLog(
      `fallbackReason=noScoringEventForScoringSide expectedSide=${scoringSide} scoreBefore=${scoreContext.previous.away}-${scoreContext.previous.home} scoreAfter=${scoreContext.scoreAfter}`,
    )
    return { event: null, fallbackReason: "noScoringEventForScoringSide" }
  }

  const event = buildScoringEventMatch(game, live, match, scoringSide, sportKind)
  if (!event) {
    return { event: null, fallbackReason: missingScoringEventDataReason(match, sportKind) }
  }

  return { event, fallbackReason: "none" }
}

function buildScoringEventMatch(
  game: TrackedGame,
  live: LiveMatchRow,
  match: TimelineEventRow,
  scoringSide: ScoringSide,
  sportKind: ProScoreSportKind,
): ScoringEventMatch | null {
  const player = cleanTimelineText(match.strPlayer)
  const gameClock = scoringEventGameClock(match, sportKind)
  const detail = soccerScoringEventDetail(match)
  const summary = scoringPlaySummary(match)
  const scoringTeamPlain = teamNameForSide(live, scoringSide)
  const scoringTeam = formattedTeamName(scoringTeamPlain)

  if (sportKind === "soccer") {
    if (!player || !gameClock) return null
  } else if (sportKind === "hockey") {
    if (!player || !gameClock) return null
  } else if (!summary) {
    return null
  }

  return {
    player: cleanTimelineText(match.strPlayer),
    gameClock,
    detail,
    summary: scoringEventSummaryForSport(game, match, sportKind) ?? summary,
    scoringTeam,
    scoringTeamPlain,
    scoringSide,
    raw: match,
  }
}

function missingScoringEventDataReason(event: TimelineEventRow, sportKind: ProScoreSportKind): string {
  const player = cleanTimelineText(event.strPlayer)
  const gameClock = scoringEventGameClock(event, sportKind)
  const summary = scoringPlaySummary(event)
  if ((sportKind === "soccer" || sportKind === "hockey") && !player) return "missingScorer"
  if ((sportKind === "soccer" || sportKind === "hockey") && !gameClock) return "missingGameClock"
  if (!summary) return "missingScoringPlaySummary"
  return "missingScoringEventData"
}

function isScoringTimelineEvent(event: TimelineEventRow, sportKind: ProScoreSportKind): boolean {
  if (sportKind === "basketball") return isMeaningfulBasketballScoringEvent(event)
  if (sportKind === "soccer") return isGoalTimelineEvent(event, true)
  if (sportKind === "hockey") return isGoalTimelineEvent(event, false)
  return isScoringPlayTimelineEvent(event)
}

function isGoalTimelineEvent(event: TimelineEventRow, allowPenaltyOnly: boolean): boolean {
  const text = [
    event.strTimeline,
    event.strTimelineDetail,
    event.strComment,
  ].map((value) => normalize(value)).join(" ")
  if (text.includes("miss") || text.includes("saved")) return false
  return text.includes("goal") || (allowPenaltyOnly && text.includes("penalty"))
}

function isScoringPlayTimelineEvent(event: TimelineEventRow): boolean {
  const text = timelineSearchText(event)
  if (text.includes("miss") || text.includes("saved")) return false
  const scoringTerms = [
    "goal",
    "touchdown",
    "field goal",
    "extra point",
    "two point",
    "2 point",
    "safety",
    "home run",
    "grand slam",
    "rbi",
    "scores",
    "scored",
    "sacrifice fly",
  ]
  return scoringTerms.some((term) => text.includes(term))
}

function isMeaningfulBasketballScoringEvent(event: TimelineEventRow): boolean {
  const text = timelineSearchText(event)
  const meaningfulTerms = [
    "buzzer",
    "game winner",
    "game-winning",
    "go ahead",
    "go-ahead",
    "lead change",
    "ties the game",
    "run",
    "milestone",
    "end of quarter",
    "end of period",
  ]
  return meaningfulTerms.some((term) => text.includes(term))
}

function timelineEventMatchesScoringTeam(
  event: TimelineEventRow,
  live: LiveMatchRow,
  scoringSide: ScoringSide,
): boolean {
  if (timelineEventMatchesScoringSide(event, live, scoringSide)) return true

  const scoringTeamName = normalizeTeamText(teamNameForSide(live, scoringSide))
  const eventTeam = normalizeTeamText(event.strTeam)
  return Boolean(scoringTeamName && eventTeam && scoringTeamName === eventTeam)
}

function timelineEventMatchesScoringSide(
  event: TimelineEventRow,
  live: LiveMatchRow,
  scoringSide: ScoringSide,
): boolean {
  const side = timelineEventSide(event, live)
  if (!side) return true
  if (side === scoringSide) return true

  // Some feeds attach own goals to the player/team that conceded.
  return soccerScoringEventDetail(event) === "OG" && side !== scoringSide
}

function timelineEventSide(event: TimelineEventRow, live: LiveMatchRow): ScoringSide | null {
  const homeFlag = normalize(event.strHome)
  if (["yes", "true", "1", "home"].includes(homeFlag)) return "home"
  if (["no", "false", "0", "away"].includes(homeFlag)) return "away"

  const team = normalizeTeamText(event.strTeam)
  if (!team) return null
  if (team === normalizeTeamText(live.home_team)) return "home"
  if (team === normalizeTeamText(live.away_team)) return "away"
  return null
}

function scoringEventNotificationTitle(
  game: TrackedGame,
  live: LiveMatchRow,
  event: ScoringEventMatch,
  sportKind: ProScoreSportKind,
): string {
  return goalNotificationTitle(event.scoringTeamPlain, sportKind, sportIconForGame(game, live))
}

function scoringEventSubtitle(event: ScoringEventMatch, sportKind: ProScoreSportKind): string | undefined {
  if (sportKind === "soccer") {
    const detail = event.detail ? ` (${event.detail})` : ""
    if (event.gameClock && event.player) {
      return `${event.gameClock} ${event.player}${detail}`.trim()
    }
  }

  if (sportKind === "hockey") {
    if (event.gameClock && event.player) {
      return `${event.gameClock} · ${event.player}`.trim()
    }
  }

  const summary = event.summary ?? event.player
  const clock = event.gameClock ? ` · ${event.gameClock}` : ""
  const fallback = `${summary ?? ""}${clock}`.trim()
  return fallback.length > 0 ? fallback : undefined
}

function soccerScoringEventDetail(event: TimelineEventRow): string | null {
  const detail = `${event.strTimeline ?? ""} ${event.strTimelineDetail ?? ""} ${event.strComment ?? ""}`.toLowerCase()
  if (detail.includes("own goal")) return "OG"
  if (detail.includes("penalty")) return "P"
  return null
}

function scoringEventGameClock(event: TimelineEventRow, sportKind: ProScoreSportKind): string | null {
  if (sportKind === "soccer") return formatSoccerMinute(event)
  if (sportKind === "hockey") return formatPeriodClock(event)
  return formatPeriodClock(event) ?? formatSoccerMinute(event)
}

function formatSoccerMinute(event: TimelineEventRow): string | null {
  const minute = cleanTimelineText(event.intTime)
  if (minute) return minute.endsWith("'") || minute.endsWith("’") ? minute.replace("’", "'") : `${minute}'`
  const text = timelineText(event)
  const match = text.match(/(^|\D)(\d{1,3})\s*['’]/)
  return match?.[2] ? `${match[2]}'` : null
}

function formatPeriodClock(event: TimelineEventRow): string | null {
  const text = timelineText(event)
  const period = firstPeriodText(text)
  const clock = firstClockText(text)
  if (period && clock) return `${period} ${clock}`
  return period ?? clock ?? null
}

function firstClockText(text: string): string | null {
  return text.match(/\b\d{1,2}:\d{2}\b/)?.[0] ?? null
}

function firstPeriodText(text: string): string | null {
  const direct = text.match(/\b(1st|2nd|3rd|4th|5th)\b/i)?.[1]
  if (direct) return direct
  const numbered = text.match(/\b(?:period|per|p|quarter|q|inning|inn)\s*(\d+)\b/i)?.[1]
  if (!numbered) return null
  return ordinalPeriodText(Number(numbered))
}

function ordinalPeriodText(value: number): string {
  if (value === 1) return "1st"
  if (value === 2) return "2nd"
  if (value === 3) return "3rd"
  return `${value}th`
}

function scoringEventSummaryForSport(
  game: TrackedGame,
  event: TimelineEventRow,
  sportKind: ProScoreSportKind,
): string | null {
  if (sportKind === "soccer" || sportKind === "hockey") return null
  const summary = scoringPlaySummary(event)
  if (!summary) return null
  const team = cleanTimelineText(event.strTeam)
  if (team && normalizeTeamText(team) !== normalizeTeamText(game.homeTeam) && normalizeTeamText(team) !== normalizeTeamText(game.awayTeam)) {
    return summary
  }
  return summary
}

function scoringPlaySummary(event: TimelineEventRow): string | null {
  const values = [
    cleanTimelineText(event.strComment),
    cleanTimelineText(event.strTimelineDetail),
    cleanTimelineText(event.strTimeline),
  ].filter((value): value is string => Boolean(value))
  const summary = values.find((value) => {
    const normalized = normalize(value)
    return !["goal", "score", "scoring play"].includes(normalized)
  })
  return summary ?? cleanTimelineText(event.strPlayer)
}

function timelineEventMinuteNumber(event: TimelineEventRow): number {
  const text = `${event.intTime ?? ""} ${timelineText(event)}`
  const firstNumber = text.match(/\d+/)?.[0]
  return firstNumber ? Number(firstNumber) : -1
}

function cleanTimelineText(raw: string | null): string | null {
  const trimmed = (raw ?? "").trim()
  return trimmed.length > 0 ? trimmed : null
}

function timelineText(event: TimelineEventRow): string {
  return [
    event.strTimeline,
    event.strTimelineDetail,
    event.strComment,
    event.strPlayer,
    event.strTeam,
    event.intTime,
  ].map((value) => cleanTimelineText(value)).filter(Boolean).join(" ")
}

function timelineSearchText(event: TimelineEventRow): string {
  return normalize(timelineText(event))
}

function normalizeTeamText(raw: string | null | undefined): string {
  return normalize(raw).replace(/[^a-z0-9]+/g, " ").trim()
}

function logScoringEventFallback(
  reason: string,
  event: ScoringEventMatch | null,
  alert: PushAlertContent,
  fallbackScoringTeam = "unknown",
  timelineEvents: TimelineEventRow[] = [],
  sportKind: ProScoreSportKind = "soccer",
) {
  console.log(`[ProScorePushWorker] scoringEventMatched=false`)
  console.log(`[ProScorePushWorker] scoringEventPlayer=${event?.player ?? "unknown"}`)
  console.log(`[ProScorePushWorker] scoringEventTime=${event?.gameClock ?? "unknown"}`)
  console.log(`[ProScorePushWorker] scoringEventFallback=${reason}`)
  goalNotificationLog(`fallbackReason=${reason}`)
  goalNotificationLog(`selectedScoringEvent=${event?.raw ? timelineEventDebugSummary(event.raw) : "none"}`)
  goalNotificationLog(`scoringTeam=${event?.scoringTeamPlain ?? fallbackScoringTeam}`)
  goalNotificationLog(`scorer=${event?.player ?? "unknown"}`)
  goalNotificationLog(`gameClock=${event?.gameClock ?? "unknown"}`)
  goalNotificationLog(`notificationTitle=${alert.title}`)
  goalNotificationLog(`notificationSubtitle=${alert.subtitle ?? "nil"}`)
  if (timelineEvents.length > 0) {
    goalNotificationLog(`scoringEventsCount=${timelineEvents.filter((row) => isScoringTimelineEvent(row, sportKind)).length}`)
  }
}

function timelineEventDebugSummary(event: TimelineEventRow): string {
  return [
    `id=${event.idTimeline ?? "nil"}`,
    `timeline=${event.strTimeline ?? "nil"}`,
    `detail=${event.strTimelineDetail ?? "nil"}`,
    `player=${event.strPlayer ?? "nil"}`,
    `time=${event.intTime ?? "nil"}`,
    `team=${event.strTeam ?? "nil"}`,
    `home=${event.strHome ?? "nil"}`,
    `comment=${event.strComment ?? "nil"}`,
  ].join(" ")
}

function goalNotificationLog(message: string): void {
  console.log(`[GoalNotificationDebug] ${message}`)
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
    || compact.includes("complete")
    || compact.includes("ended")
    || compact.includes("full time")
    || compact.includes("after full time")
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
    alert: PushAlertContent,
  ): Promise<ApnsSendResult> {
    const authorization = await this.authorizationHeader()
    const environment = normalizeApnsEnvironment(token.environment ?? this.defaultEnvironment)
    const host = environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com"
    console.log(`[ProScorePushWorker] apns endpoint=${host}`)
    console.log(`[ProScorePushWorker] apns tokenEnvironment=${environment}`)
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
          alert: compactAlertPayload(alert),
          sound: "default",
        },
      }),
    })

    if (response.status === 200) {
      console.log("[ProScorePushWorker] apns status=200")
      console.log("[ProScorePushWorker] apns reason=success")
      return {
        ok: true,
        status: response.status,
        endpoint: host,
        tokenEnvironment: environment,
      }
    }
    const payload = await response.json().catch(() => ({}))
    const reason = typeof payload?.reason === "string" ? payload.reason : `status_${response.status}`
    console.warn(`[ProScorePushWorker] apns status=${response.status}`)
    console.warn(`[ProScorePushWorker] apns reason=${reason}`)
    const invalidate = ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].includes(reason)
    return {
      ok: false,
      status: response.status,
      endpoint: host,
      tokenEnvironment: environment,
      reason,
      invalidate,
    }
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

function compactAlertPayload(alert: PushAlertContent): Record<string, string> {
  const payload: Record<string, string> = {
    title: alert.title,
    body: alert.body,
  }
  if (alert.subtitle?.trim()) {
    payload.subtitle = alert.subtitle.trim()
  }
  return payload
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
