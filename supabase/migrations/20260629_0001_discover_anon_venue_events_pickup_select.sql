-- Guest Discover: anon/public read for venue_events + pickup_games (dots/cards stay login-gated in the app).
-- Writes: anon keeps SELECT only (no INSERT/UPDATE/DELETE grants here).
--
-- If `select count(*)` as anon still returns 0 but service_role shows rows, confirm RLS is enabled
-- and these policies exist (Dashboard → Authentication → Policies, or pg_policies).
--
-- Post-deploy checks (Supabase SQL editor; use service_role or postgres, not the mobile anon key for counts):
--   select count(*) from public.venue_events;
--   select count(*) from public.pickup_games;
--
-- To approximate anon visibility (optional):
--   set local role anon;
--   select count(*) from public.venue_events;
--   select count(*) from public.pickup_games;
--   reset role;

-- ---------------------------------------------------------------------------
-- public.venue_events — anon SELECT (Discover)
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS venue_events_select_public_guest_anon ON public.venue_events;

CREATE POLICY venue_events_select_public_guest_anon
  ON public.venue_events
  FOR SELECT
  TO anon
  USING (
    admin_status = 'active'
    AND event_date IS NOT NULL
    AND event_date::date >= (CURRENT_DATE - interval '1 day')
  );

GRANT SELECT ON public.venue_events TO anon;

-- ---------------------------------------------------------------------------
-- public.pickup_games — anon SELECT (Discover)
-- ---------------------------------------------------------------------------
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
-- public.venues — ensure Discover pins stay readable (idempotent)
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS venues_select_public_guest_anon ON public.venues;

CREATE POLICY venues_select_public_guest_anon
  ON public.venues
  FOR SELECT
  TO anon
  USING (
    admin_status = 'active'
    AND latitude IS NOT NULL
    AND longitude IS NOT NULL
  );

GRANT SELECT ON public.venues TO anon;
