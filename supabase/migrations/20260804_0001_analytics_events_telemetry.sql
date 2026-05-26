-- FanGeo telemetry foundation.
--
-- Additive only:
-- - tracks lightweight app activity for admin analytics
-- - does not expose analytics events to clients for reads
-- - does not log message bodies or sensitive personal content

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS last_active_at timestamptz;

CREATE INDEX IF NOT EXISTS user_profiles_last_active_at_idx
  ON public.user_profiles (last_active_at DESC);

CREATE TABLE IF NOT EXISTS public.analytics_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  event_name text NOT NULL,
  entity_type text NULL,
  entity_id uuid NULL,
  city text NULL,
  region text NULL,
  country text NULL,
  sport text NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS analytics_events_event_name_created_at_idx
  ON public.analytics_events (event_name, created_at DESC);

CREATE INDEX IF NOT EXISTS analytics_events_user_id_created_at_idx
  ON public.analytics_events (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS analytics_events_created_at_idx
  ON public.analytics_events (created_at DESC);

CREATE INDEX IF NOT EXISTS analytics_events_city_region_sport_idx
  ON public.analytics_events (city, region, sport);

ALTER TABLE public.analytics_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS analytics_events_insert_own_events ON public.analytics_events;
CREATE POLICY analytics_events_insert_own_events
  ON public.analytics_events
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = (SELECT auth.uid())
  );

DROP POLICY IF EXISTS analytics_events_no_user_select ON public.analytics_events;
CREATE POLICY analytics_events_no_user_select
  ON public.analytics_events
  FOR SELECT
  TO authenticated
  USING (false);

DROP POLICY IF EXISTS analytics_events_service_role_select ON public.analytics_events;
CREATE POLICY analytics_events_service_role_select
  ON public.analytics_events
  FOR SELECT
  TO service_role
  USING (true);

GRANT INSERT ON public.analytics_events TO authenticated;
GRANT SELECT ON public.analytics_events TO service_role;

COMMENT ON COLUMN public.user_profiles.last_active_at IS
  'Best-effort app activity timestamp for admin analytics and live operations. Updated by authenticated clients without blocking UI.';

COMMENT ON TABLE public.analytics_events IS
  'Lightweight app activity events for FanGeo admin analytics. Do not store private message bodies or sensitive personal data.';
