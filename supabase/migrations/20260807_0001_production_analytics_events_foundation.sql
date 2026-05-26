-- Production-safe FanGeo telemetry/event logging foundation.
--
-- Additive/compatible goals:
-- - standardize the canonical event column as event_type
-- - preserve the older event_name column when it already exists so current
--   admin-dashboard analytics queries keep working until they are migrated
-- - allow authenticated users to insert only their own events
-- - prevent public reads, updates, deletes, and anonymous writes
-- - provide a safe RPC wrapper for app clients

CREATE TABLE IF NOT EXISTS public.analytics_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  user_id uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  event_type text NOT NULL,
  entity_type text NULL,
  entity_id text NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  platform text NULL,
  app_version text NULL,
  session_id text NULL
);

ALTER TABLE public.analytics_events
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS user_id uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS event_type text,
  ADD COLUMN IF NOT EXISTS entity_type text,
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS platform text,
  ADD COLUMN IF NOT EXISTS app_version text,
  ADD COLUMN IF NOT EXISTS session_id text;

-- Existing installations may have entity_id as uuid from the first telemetry
-- draft. Convert to text so all entity identifiers can be logged safely.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'analytics_events'
      AND column_name = 'entity_id'
      AND data_type = 'uuid'
  ) THEN
    ALTER TABLE public.analytics_events
      ALTER COLUMN entity_id TYPE text USING entity_id::text;
  ELSIF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'analytics_events'
      AND column_name = 'entity_id'
  ) THEN
    ALTER TABLE public.analytics_events
      ADD COLUMN entity_id text;
  END IF;
END $$;

-- Backfill the canonical event_type from the older compatibility column if it
-- exists. Keep event_name for current admin queries; new code should use
-- event_type.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'analytics_events'
      AND column_name = 'event_name'
  ) THEN
    UPDATE public.analytics_events
    SET event_type = event_name
    WHERE event_type IS NULL
      AND event_name IS NOT NULL;
  END IF;
END $$;

UPDATE public.analytics_events
SET event_type = 'unknown'
WHERE event_type IS NULL;

ALTER TABLE public.analytics_events
  ALTER COLUMN event_type SET NOT NULL,
  ALTER COLUMN metadata SET DEFAULT '{}'::jsonb,
  ALTER COLUMN metadata SET NOT NULL,
  ALTER COLUMN created_at SET DEFAULT now(),
  ALTER COLUMN created_at SET NOT NULL;

CREATE INDEX IF NOT EXISTS analytics_events_created_at_desc_idx
  ON public.analytics_events (created_at DESC);

CREATE INDEX IF NOT EXISTS analytics_events_event_type_idx
  ON public.analytics_events (event_type);

CREATE INDEX IF NOT EXISTS analytics_events_user_id_idx
  ON public.analytics_events (user_id);

CREATE INDEX IF NOT EXISTS analytics_events_entity_type_entity_id_idx
  ON public.analytics_events (entity_type, entity_id);

ALTER TABLE public.analytics_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS analytics_events_service_role_full_access ON public.analytics_events;
CREATE POLICY analytics_events_service_role_full_access
  ON public.analytics_events
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS analytics_events_authenticated_insert_own_events ON public.analytics_events;
CREATE POLICY analytics_events_authenticated_insert_own_events
  ON public.analytics_events
  FOR INSERT
  TO authenticated
  WITH CHECK (
    user_id = (SELECT auth.uid())
  );

-- Replace/neutralize older policy names so clients cannot select analytics
-- rows. Service role still has full access through its own policy.
DROP POLICY IF EXISTS analytics_events_no_user_select ON public.analytics_events;
CREATE POLICY analytics_events_no_user_select
  ON public.analytics_events
  FOR SELECT
  TO authenticated
  USING (false);

REVOKE ALL ON public.analytics_events FROM PUBLIC;
REVOKE ALL ON public.analytics_events FROM anon;
REVOKE ALL ON public.analytics_events FROM authenticated;
GRANT INSERT ON public.analytics_events TO authenticated;
GRANT ALL ON public.analytics_events TO service_role;

CREATE OR REPLACE FUNCTION public.track_event(
  p_event_type text,
  p_entity_type text DEFAULT NULL,
  p_entity_id text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_event_type text := nullif(btrim(coalesce(p_event_type, '')), '');
  v_metadata jsonb := coalesce(p_metadata, '{}'::jsonb);
  v_event_id uuid;
  v_has_event_name boolean;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'track_event requires an authenticated user'
      USING ERRCODE = '28000';
  END IF;

  IF v_event_type IS NULL THEN
    RAISE EXCEPTION 'event_type is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'analytics_events'
      AND column_name = 'event_name'
  )
  INTO v_has_event_name;

  IF v_has_event_name THEN
    INSERT INTO public.analytics_events (
      user_id,
      event_type,
      event_name,
      entity_type,
      entity_id,
      metadata
    )
    VALUES (
      v_user_id,
      v_event_type,
      v_event_type,
      nullif(btrim(coalesce(p_entity_type, '')), ''),
      nullif(btrim(coalesce(p_entity_id, '')), ''),
      v_metadata
    )
    RETURNING id INTO v_event_id;
  ELSE
    INSERT INTO public.analytics_events (
      user_id,
      event_type,
      entity_type,
      entity_id,
      metadata
    )
    VALUES (
      v_user_id,
      v_event_type,
      nullif(btrim(coalesce(p_entity_type, '')), ''),
      nullif(btrim(coalesce(p_entity_id, '')), ''),
      v_metadata
    )
    RETURNING id INTO v_event_id;
  END IF;

  RETURN v_event_id;
END;
$$;

REVOKE ALL ON FUNCTION public.track_event(text, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.track_event(text, text, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.track_event(text, text, text, jsonb) TO service_role;

COMMENT ON TABLE public.analytics_events IS
  'Centralized FanGeo telemetry events for growth, engagement, onboarding, retention, and live operations analytics. Do not store private message bodies or sensitive personal data.';

COMMENT ON COLUMN public.analytics_events.event_type IS
  'Canonical event name, for example app_open, discover_view, game_created, game_joined, comment_posted, dm_sent.';

COMMENT ON FUNCTION public.track_event(text, text, text, jsonb) IS
  'Authenticated client helper that records an analytics event for auth.uid() without exposing read/update/delete access.';
