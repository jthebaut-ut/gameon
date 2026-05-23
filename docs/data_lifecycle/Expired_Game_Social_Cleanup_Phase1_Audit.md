# FanGeo Expired Game/Social Cleanup Phase 1 Audit

Last updated: May 22, 2026

Scope: audit and non-destructive proposal only. This document does not apply a migration, schedule a cron job, delete production data, change app UI, or change account deletion logic.

## 1. Current Table And Schema Findings

### `public.live_matches`

- Defined in `supabase/migrations/20260730_0001_live_matches.sql`.
- Short-lived sports cache with `id`, `source`, `external_id`, teams, score/status, `start_time`, `payload`, `created_at`, and `updated_at`.
- Existing `public.prune_live_matches_cache(window_start, window_end)` deletes rows outside the default window `now() - interval '2 hours'` through `now() + interval '7 days'`.
- RLS already limits client reads to the same bounded window.
- `sync-live-matches` Edge Function already calls the prune RPC before upserting the latest provider rows.

### `public.venue_events`

- Retention columns are added in `supabase/migrations/20260618_0001_business_game_purge_history.sql`:
  - `cleanup_delay_hours`
  - `scheduled_start_at`
  - `purged_at`
  - `created_at`
  - generated `purge_after_at = scheduled_start_at + cleanup_delay_hours`
- `supabase/migrations/20260716_0001_venue_events_cleanup_delay_6_12_18.sql` allows `cleanup_delay_hours IN (6, 12, 18, 24, 48, 72)`.
- App code (`VenueGameExpiration`) treats `purge_after_at` as the clear window and hides venue games from Discover surfaces after that time.
- Existing `public.purge_expired_venue_events()` hard-deletes expired `venue_events` and child social rows.

### `public.venue_event_comments`

- Legacy Fan Chat shape currently used by app selects:
  - `id`
  - `venue_event_id`
  - `user_email`
  - `comment`
  - `created_at`
  - `is_moderation_hidden`
- Moderation fields are added later:
  - `is_moderation_hidden`
  - `moderation_report_count`
  - `moderation_last_reported_at`
  - `moderation_alert_sent_at`
- Comments are temporary social content tied to `venue_events`, but reported/moderated content must preserve enough audit context before any comment deletion.

### `public.venue_event_interests`

- Used for Going/Interested state.
- Has `user_email`, `venue_event_id`, and `interest_status`.
- `interest_status` is constrained to `going` or `interested`.
- Unique and lookup indexes exist for `(user_email, venue_event_id)` and event lookups.
- This is temporary event-specific social state and should be removed/hidden when the event lifecycle expires.

### `public.venue_event_vibes`

- Used for temporary crowd reaction/social energy around a venue event.
- Indexed by `venue_event_id`; unique event/user/vibe index exists.
- This is temporary event-specific social state and should be removed with the event lifecycle.

### `public.venue_event_comment_likes`

- Legacy likes table retained for rollback/older clients.
- Has no FK to `venue_event_comments` in its table definition, so cleanup must explicitly delete likes for comments being purged.
- Temporary reaction state; not a moderation record.

### `public.venue_event_comment_reactions`

- Current thumbs up/down reactions.
- `comment_id` references `venue_event_comments(id) ON DELETE CASCADE`.
- Temporary reaction state; not a moderation record.

### `public.pickup_games`

- Base table defined in `20260514_0002_pickup_games.sql`.
- Current retention is enforced to 12 hours:
  - `PickupGameAutoRemoval.hoursAfterGameStart = 12`
  - `cleanup_delay_hours = 12`
  - `remove_after_at = game_start_at + interval '12 hours'`
- Existing `public.purge_expired_pickup_games()` hard-deletes rows where `remove_after_at <= now()`.
- Public/Calendar app filtering already hides inactive, invisible, or expired pickup games.

### `public.pickup_game_requests`

- FK to `pickup_games(id) ON DELETE CASCADE`.
- Existing pickup purge cascades join requests.
- These are temporary participation requests tied to a pickup game lifecycle.

### Saved/favorite game tables

- No `saved_games`, `favorite_games`, or saved venue-event table was found in code or migrations.
- Current favorites are venue-based (`favorite_venues`) and team-based (`user_favorite_teams`), not game-based.
- Going/Interested rows currently act as the event-specific saved/attendance state.

### Notifications tied to expired games

- No persistent game notification table with `venue_event_id` or `pickup_game_id` was found.
- App reminder notifications are local iOS `UNUserNotificationCenter` requests (`GameReminderNotificationService`) with identifiers prefixed by `fangeo.gameReminder.`.
- `request_delete_my_account()` has schema-defensive cleanup for a `notifications` table if one exists, but no table definition was found in this repo.

### DMs

- Direct messages and direct conversations are not part of this cleanup and should stay excluded.

## 2. Existing Cleanup Logic

### Existing and acceptable

- `live_matches`:
  - `prune_live_matches_cache()` keeps the table bounded to `now() - 2 hours` through `now() + 7 days`.
  - `sync-live-matches` invokes pruning as part of sync.
- `pickup_games`:
  - `remove_after_at` is enforced at `game_start_at + 12 hours`.
  - `purge_expired_pickup_games()` deletes expired pickup games and cascades `pickup_game_requests`.

### Existing but unsafe for current requirements

`public.purge_expired_venue_events()` currently:

- Inserts lightweight `business_game_history`.
- Deletes `comment_reports` tied to expired comments/events.
- Deletes `venue_event_comments`.
- Deletes `venue_event_vibes`.
- Deletes `venue_event_interests`.
- Deletes `venue_events`.

This conflicts with the requested safety exclusion: do not delete reports or moderation audit. Before scheduling or relying on this function, replace it with a safety-preserving version.

## 3. Proposed Retention Windows

Use existing app/database behavior where present:

- Live matches: keep current bounded cache, `now() - 2 hours` to `now() + 7 days`; prune every 5-15 minutes as part of sync or cron.
- Venue games: honor per-row `cleanup_delay_hours` and generated `purge_after_at`.
  - New owner-created venue games should continue using 6 / 12 / 18 hour choices where exposed by the app.
  - Default recommendation: 12 hours after scheduled start when no owner selection is available.
  - Legacy 24 / 48 / 72 hour values may remain valid until rows are edited or migrated by a later approved phase.
- Fan Chat/comments for venue games: expire with `venue_events.purge_after_at`, but preserve report/moderation audit first.
- Going/Interested (`venue_event_interests`): expire with `venue_events.purge_after_at`.
- Vibes/reactions (`venue_event_vibes`, `venue_event_comment_likes`, `venue_event_comment_reactions`): expire with the venue game/comment lifecycle.
- Pickup games: keep current 12 hours after `game_start_at`.
- Pickup game requests: cascade/remove with `pickup_games`.
- Notifications: if a persistent table exists later, remove/hide notifications tied to expired `venue_event_id` / `pickup_game_id`; local iOS pending reminders should be cancelled by app code when the user removes a reminder or all reminders.

## 4. Proposed SQL Cleanup Function

Do not run this yet. This is a draft for a future migration after approval.

Key design changes versus the current venue purge:

- Default to `p_dry_run = true`.
- Return counts before deleting anything.
- Preserve `comment_reports` and moderation audit.
- Archive reported comment context before deleting Fan Chat rows.
- Exclude DMs entirely.
- Explicitly clean temporary social rows.
- Do not touch account deletion logic.

```sql
-- Draft only. Do not apply until approved.

CREATE TABLE IF NOT EXISTS public.expired_venue_event_moderation_archive (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  original_venue_event_id uuid NOT NULL,
  original_comment_id uuid,
  reporter_email text,
  report_reason text,
  comment_text_snapshot text,
  commenter_email_snapshot text,
  moderation_report_count integer,
  moderation_last_reported_at timestamptz,
  moderation_alert_sent_at timestamptz,
  admin_resolution_status text,
  admin_resolved_at timestamptz,
  admin_resolved_by text,
  admin_resolution_note text,
  archived_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_expired_venue_event_moderation_archive_event
  ON public.expired_venue_event_moderation_archive (original_venue_event_id, archived_at DESC);

CREATE OR REPLACE FUNCTION public.cleanup_expired_game_social_phase2(
  p_now timestamptz DEFAULT now(),
  p_limit integer DEFAULT 500,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event_ids uuid[] := ARRAY[]::uuid[];
  v_comment_ids uuid[] := ARRAY[]::uuid[];
  v_counts jsonb := '{}'::jsonb;
  v_count integer := 0;
BEGIN
  SELECT coalesce(array_agg(id), ARRAY[]::uuid[])
  INTO v_event_ids
  FROM (
    SELECT ve.id
    FROM public.venue_events ve
    WHERE ve.purged_at IS NULL
      AND ve.purge_after_at IS NOT NULL
      AND ve.purge_after_at <= p_now
    ORDER BY ve.purge_after_at ASC
    LIMIT greatest(1, p_limit)
  ) expired;

  SELECT coalesce(array_agg(c.id), ARRAY[]::uuid[])
  INTO v_comment_ids
  FROM public.venue_event_comments c
  WHERE c.venue_event_id = ANY(v_event_ids);

  v_counts := v_counts || jsonb_build_object(
    'dry_run', p_dry_run,
    'venue_events_targeted', cardinality(v_event_ids),
    'venue_event_comments_targeted', cardinality(v_comment_ids)
  );

  SELECT count(*)::integer INTO v_count
  FROM public.venue_event_interests
  WHERE venue_event_id = ANY(v_event_ids);
  v_counts := v_counts || jsonb_build_object('venue_event_interests_targeted', v_count);

  SELECT count(*)::integer INTO v_count
  FROM public.venue_event_vibes
  WHERE venue_event_id = ANY(v_event_ids);
  v_counts := v_counts || jsonb_build_object('venue_event_vibes_targeted', v_count);

  SELECT count(*)::integer INTO v_count
  FROM public.venue_event_comment_reactions
  WHERE comment_id = ANY(v_comment_ids);
  v_counts := v_counts || jsonb_build_object('venue_event_comment_reactions_targeted', v_count);

  SELECT count(*)::integer INTO v_count
  FROM public.venue_event_comment_likes
  WHERE comment_id = ANY(v_comment_ids);
  v_counts := v_counts || jsonb_build_object('venue_event_comment_likes_targeted', v_count);

  SELECT count(*)::integer INTO v_count
  FROM public.comment_reports
  WHERE comment_id = ANY(v_comment_ids)
     OR venue_event_id = ANY(v_event_ids);
  v_counts := v_counts || jsonb_build_object('comment_reports_preserved', v_count);

  IF p_dry_run THEN
    RETURN v_counts;
  END IF;

  -- Preserve moderation/report context before comment rows are removed.
  INSERT INTO public.expired_venue_event_moderation_archive (
    original_venue_event_id,
    original_comment_id,
    reporter_email,
    report_reason,
    comment_text_snapshot,
    commenter_email_snapshot,
    moderation_report_count,
    moderation_last_reported_at,
    moderation_alert_sent_at,
    admin_resolution_status,
    admin_resolved_at,
    admin_resolved_by,
    admin_resolution_note
  )
  SELECT
    coalesce(cr.venue_event_id, c.venue_event_id),
    cr.comment_id,
    cr.reporter_email,
    cr.reason,
    c.comment,
    c.user_email,
    c.moderation_report_count,
    c.moderation_last_reported_at,
    c.moderation_alert_sent_at,
    cr.admin_resolution_status,
    cr.admin_resolved_at,
    cr.admin_resolved_by,
    cr.admin_resolution_note
  FROM public.comment_reports cr
  LEFT JOIN public.venue_event_comments c ON c.id = cr.comment_id
  WHERE cr.comment_id = ANY(v_comment_ids)
     OR cr.venue_event_id = ANY(v_event_ids);

  -- Optional: keep comment_reports rows. If FK constraints require removal,
  -- first add nullable archive pointers or snapshot columns in an approved migration.
  -- Do not DELETE FROM public.comment_reports in this cleanup function.

  DELETE FROM public.venue_event_comment_reactions
  WHERE comment_id = ANY(v_comment_ids);

  DELETE FROM public.venue_event_comment_likes
  WHERE comment_id = ANY(v_comment_ids);

  DELETE FROM public.venue_event_comments
  WHERE venue_event_id = ANY(v_event_ids);

  DELETE FROM public.venue_event_vibes
  WHERE venue_event_id = ANY(v_event_ids);

  DELETE FROM public.venue_event_interests
  WHERE venue_event_id = ANY(v_event_ids);

  -- Saved/favorite game cleanup placeholder for future tables:
  -- DELETE FROM public.saved_games WHERE venue_event_id = ANY(v_event_ids);
  -- DELETE FROM public.favorite_games WHERE venue_event_id = ANY(v_event_ids);

  -- Persistent notification cleanup placeholder, if table/columns exist:
  -- DELETE FROM public.notifications WHERE venue_event_id = ANY(v_event_ids);

  INSERT INTO public.business_game_history (
    original_venue_event_id,
    business_id,
    venue_id,
    venue_name,
    event_title,
    sport,
    scheduled_start_at,
    event_date,
    cleanup_delay_hours,
    attendance_count,
    comment_count,
    created_at,
    purged_at
  )
  SELECT
    ve.id,
    v.business_id,
    ve.venue_id,
    coalesce(nullif(trim(v.venue_name), ''), nullif(trim(ve.venue_name), '')),
    ve.event_title,
    ve.sport,
    ve.scheduled_start_at,
    CASE WHEN ve.event_date IS NULL THEN NULL ELSE trim(ve.event_date::text)::date END,
    ve.cleanup_delay_hours,
    0,
    0,
    coalesce(ve.created_at, now()),
    now()
  FROM public.venue_events ve
  LEFT JOIN public.venues v ON v.id = ve.venue_id
  WHERE ve.id = ANY(v_event_ids)
  ON CONFLICT DO NOTHING;

  DELETE FROM public.venue_events
  WHERE id = ANY(v_event_ids);

  RETURN v_counts || jsonb_build_object('purged_at', now());
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_expired_game_social_phase2(timestamptz, integer, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_game_social_phase2(timestamptz, integer, boolean) TO service_role;
```

## 5. Proposed Scheduled Job / Edge Function

Do not schedule yet.

Recommended future schedule after approval:

- `sync-live-matches`: keep current behavior; run every 5-15 minutes during active sports windows. It already prunes stale live cache rows.
- `cleanup_expired_game_social_phase2(p_dry_run := true)`: run manually first and compare counts.
- After approval and validation, run `cleanup_expired_game_social_phase2(p_dry_run := false)` every hour with `service_role`.
- `purge_expired_pickup_games()`: if already scheduled, keep hourly. If not scheduled, add hourly service-role schedule.

Edge Function draft:

```ts
// Draft only. Do not deploy until approved.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

serve(async () => {
  const supabase = createClient(
    Deno.env.get("PROJECT_URL") ?? Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  )

  const { data: venueCleanup, error: venueError } = await supabase.rpc(
    "cleanup_expired_game_social_phase2",
    { p_dry_run: false, p_limit: 500 },
  )
  if (venueError) return new Response(JSON.stringify({ success: false, venueError }), { status: 500 })

  const { data: pickupDeleted, error: pickupError } = await supabase.rpc("purge_expired_pickup_games")
  if (pickupError) return new Response(JSON.stringify({ success: false, pickupError }), { status: 500 })

  return new Response(JSON.stringify({
    success: true,
    venueCleanup,
    pickupDeleted,
  }), { headers: { "Content-Type": "application/json" } })
})
```

## 6. Safety Exclusions

Must not delete:

- `direct_messages`
- `direct_conversations`
- `conversation_reports`
- `message_reports`
- `comment_reports` unless a separate approved migration first snapshots and preserves their audit value elsewhere
- user/account deletion state
- moderation/admin resolution audit fields
- business account deletion/audit records

Must preserve:

- Report identity/context needed for moderation.
- Admin resolution status and notes.
- Reported comment snapshots before any comment row is deleted.
- `business_game_history` for expired venue games.

## 7. Exact Implementation Plan

Phase 1 (this document):

1. Audit current schema and cleanup behavior.
2. Identify safety gap: existing `purge_expired_venue_events()` deletes `comment_reports`.
3. Propose a safe replacement and dry-run path.
4. Do not apply cleanup migrations or schedules.

Phase 2A (approval required):

1. Add a moderation archive table or add snapshot columns to `comment_reports`.
2. Create a dry-run-only RPC for expired venue game cleanup counts.
3. Run dry-run in production and review row counts by table.
4. Verify no FK prevents preserving `comment_reports` while deleting expired comments, or adjust schema with nullable archive references.

Phase 2B (approval required):

1. Replace `purge_expired_venue_events()` with safety-preserving cleanup.
2. Keep `comment_reports` / moderation audit, archive reported comment context, then remove temporary social data.
3. Add guards for optional future tables:
   - `saved_games`
   - `favorite_games`
   - `notifications.venue_event_id`
   - `notifications.pickup_game_id`
4. Run one manual cleanup with a small `p_limit`.
5. Verify counts and app behavior.

Phase 2C (approval required):

1. Schedule the cleanup Edge Function or Supabase Cron hourly.
2. Monitor counts, errors, and table growth.
3. Add operational dashboard/logging for purged venue events, preserved reports, pickup purges, and live-match prune counts.

## 8. Recommendation

Do not schedule the current `purge_expired_venue_events()` until it is patched or replaced, because it deletes `comment_reports`. Keep live-match pruning and pickup-game purging as separate, already-established cleanup paths. The first approved implementation should be a dry-run RPC that reports exact target counts before any destructive operation is enabled.
