-- Guest Discover: allow `anon` to SELECT public-safe rows for map pins, calendar dots, and locked previews.
-- Requires RLS to already be enabled on `public.venues` and `public.venue_events` in the target database
-- (policies cannot be created otherwise). `pickup_games` already enables RLS in earlier migrations.

-- ---------------------------------------------------------------------------
-- pickup_games: authenticated listing branch — allow NULL remove_after_at
-- (matches app PostgREST `or(remove_after_at.is.null,remove_after_at.gt.now)`).
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS pickup_games_select_authenticated ON public.pickup_games;
CREATE POLICY pickup_games_select_authenticated
  ON public.pickup_games
  FOR SELECT
  TO authenticated
  USING (
    creator_user_id = (SELECT auth.uid())
    OR (
      status = 'active'
      AND is_visible
      AND (remove_after_at IS NULL OR remove_after_at > now())
      AND approved_join_count < players_needed
    )
  );

DROP POLICY IF EXISTS pickup_games_select_public_guest_anon ON public.pickup_games;
CREATE POLICY pickup_games_select_public_guest_anon
  ON public.pickup_games
  FOR SELECT
  TO anon
  USING (
    status = 'active'
    AND is_visible = true
    AND game_start_at >= (now() - interval '1 day')
    AND (remove_after_at IS NULL OR remove_after_at > now())
  );

GRANT SELECT ON public.pickup_games TO anon;

-- ---------------------------------------------------------------------------
-- venues: anon map pins (active + coordinates)
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS venues_select_public_guest_anon ON public.venues;
CREATE POLICY venues_select_public_guest_anon
  ON public.venues
  FOR SELECT
  TO anon
  USING (
    lower(trim(coalesce(admin_status, ''))) = 'active'
    AND latitude IS NOT NULL
    AND longitude IS NOT NULL
  );

GRANT SELECT ON public.venues TO anon;

-- ---------------------------------------------------------------------------
-- venue_events: anon calendar dots / locked cards (active + recent dates)
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS venue_events_select_public_guest_anon ON public.venue_events;
CREATE POLICY venue_events_select_public_guest_anon
  ON public.venue_events
  FOR SELECT
  TO anon
  USING (
    lower(trim(coalesce(admin_status, ''))) = 'active'
    AND (event_date::date >= (CURRENT_DATE - interval '1 day'))
  );

GRANT SELECT ON public.venue_events TO anon;
