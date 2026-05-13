-- Business game retention: scheduled_start_at, cleanup delay, purge_after_at, lightweight history, and purge RPC.
-- pg_cron is NOT enabled here (requires platform/superuser). Schedule purge_expired_venue_events() hourly via
-- Supabase Dashboard → Database → Cron, or an Edge Function with service_role. Manual test: SELECT public.purge_expired_venue_events();

-- ---------------------------------------------------------------------------
-- 1) venue_events: retention + purge scheduling
-- ---------------------------------------------------------------------------

ALTER TABLE public.venue_events
  ADD COLUMN IF NOT EXISTS cleanup_delay_hours integer NOT NULL DEFAULT 48,
  ADD COLUMN IF NOT EXISTS scheduled_start_at timestamptz,
  ADD COLUMN IF NOT EXISTS purged_at timestamptz,
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'venue_events_cleanup_delay_hours_check'
  ) THEN
    ALTER TABLE public.venue_events DROP CONSTRAINT venue_events_cleanup_delay_hours_check;
  END IF;
  ALTER TABLE public.venue_events
    ADD CONSTRAINT venue_events_cleanup_delay_hours_check
    CHECK (cleanup_delay_hours IN (24, 48, 72));
END $$;

COMMENT ON COLUMN public.venue_events.cleanup_delay_hours IS
  'Hours after scheduled_start_at when the game row and related fan data may be purged (24, 48, or 72).';

COMMENT ON COLUMN public.venue_events.scheduled_start_at IS
  'Canonical local instant for the listing (device/app writes timestamptz; used for retention).';

COMMENT ON COLUMN public.venue_events.purged_at IS
  'Reserved for soft-mark before hard delete; purge RPC hard-deletes rows after inserting business_game_history.';

-- Best-effort backfill for legacy rows (noon UTC on event_date when time is unknown).
UPDATE public.venue_events ve
SET scheduled_start_at = ((trim(ve.event_date::text))::date::timestamp AT TIME ZONE 'UTC') + interval '12 hours'
WHERE ve.scheduled_start_at IS NULL
  AND ve.event_date IS NOT NULL
  AND trim(ve.event_date::text) <> '';

-- Generated purge threshold (NULL when scheduled_start_at is NULL).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'venue_events'
      AND column_name = 'purge_after_at'
  ) THEN
    ALTER TABLE public.venue_events
      ADD COLUMN purge_after_at timestamptz
      GENERATED ALWAYS AS (
        CASE
          WHEN scheduled_start_at IS NULL THEN NULL
          ELSE scheduled_start_at + make_interval(hours => cleanup_delay_hours)
        END
      ) STORED;
  END IF;
END $$;

COMMENT ON COLUMN public.venue_events.purge_after_at IS
  'scheduled_start_at + cleanup_delay_hours; used by purge_expired_venue_events().';

CREATE INDEX IF NOT EXISTS idx_venue_events_purge_pending
  ON public.venue_events (purge_after_at)
  WHERE purged_at IS NULL AND purge_after_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2) business_game_history (metadata only; no comment text)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.business_game_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  original_venue_event_id uuid NOT NULL,
  business_id uuid,
  venue_id uuid,
  venue_name text,
  event_title text,
  sport text,
  scheduled_start_at timestamptz,
  event_date date,
  cleanup_delay_hours integer NOT NULL DEFAULT 48,
  attendance_count integer NOT NULL DEFAULT 0,
  comment_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  purged_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.business_game_history IS
  'Lightweight record after venue_events purge; no chat/comment bodies.';

CREATE INDEX IF NOT EXISTS idx_business_game_history_business_scheduled
  ON public.business_game_history (business_id, scheduled_start_at DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS idx_business_game_history_venue_scheduled
  ON public.business_game_history (venue_id, scheduled_start_at DESC NULLS LAST);

ALTER TABLE public.business_game_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS business_game_history_select_own ON public.business_game_history;

CREATE POLICY business_game_history_select_own
  ON public.business_game_history
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_game_history.business_id
        AND (
          (b.owner_user_id IS NOT NULL AND b.owner_user_id = auth.uid())
          OR (
            b.owner_email IS NOT NULL
            AND auth.jwt() ->> 'email' IS NOT NULL
            AND lower(b.owner_email) = lower(auth.jwt() ->> 'email')
          )
        )
    )
  );

GRANT SELECT ON public.business_game_history TO authenticated;
GRANT SELECT ON public.business_game_history TO service_role;

-- ---------------------------------------------------------------------------
-- 3) purge_expired_venue_events (SECURITY DEFINER; service_role only)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.purge_expired_venue_events()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ids uuid[];
BEGIN
  SELECT array_agg(ve.id)
    INTO v_ids
  FROM public.venue_events ve
  WHERE ve.purged_at IS NULL
    AND ve.purge_after_at IS NOT NULL
    AND ve.purge_after_at <= now();

  IF v_ids IS NULL OR cardinality(v_ids) = 0 THEN
    RETURN 0;
  END IF;

  -- Snapshot metadata (counts + join venue for business_id / venue_name).
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
    CASE
      WHEN ve.event_date IS NULL THEN NULL
      ELSE trim(ve.event_date::text)::date
    END,
    ve.cleanup_delay_hours,
    coalesce((
      SELECT count(*)::integer FROM public.venue_event_interests i WHERE i.venue_event_id = ve.id
    ), 0),
    coalesce((
      SELECT count(*)::integer FROM public.venue_event_comments c WHERE c.venue_event_id = ve.id
    ), 0),
    coalesce(ve.created_at, now()),
    now()
  FROM public.venue_events ve
  LEFT JOIN public.venues v ON v.id = ve.venue_id
  WHERE ve.id = ANY(v_ids);

  -- Child tables (explicit; FK cascades may not exist everywhere).
  DELETE FROM public.comment_reports cr
  WHERE cr.comment_id IN (
    SELECT c.id FROM public.venue_event_comments c WHERE c.venue_event_id = ANY(v_ids)
  );

  DELETE FROM public.comment_reports cr
  WHERE cr.venue_event_id IS NOT NULL
    AND cr.venue_event_id = ANY(v_ids);

  DELETE FROM public.venue_event_comments WHERE venue_event_id = ANY(v_ids);
  DELETE FROM public.venue_event_vibes WHERE venue_event_id = ANY(v_ids);
  DELETE FROM public.venue_event_interests WHERE venue_event_id = ANY(v_ids);

  DELETE FROM public.venue_events WHERE id = ANY(v_ids);

  RETURN coalesce(cardinality(v_ids), 0);
END;
$$;

COMMENT ON FUNCTION public.purge_expired_venue_events() IS
  'Hard-deletes expired venue_events (purge_after_at <= now), inserts business_game_history rows, removes comments/vibes/interests/reports. '
  'EXECUTE is granted to service_role only; schedule via pg_cron or Edge Function.';

REVOKE ALL ON FUNCTION public.purge_expired_venue_events() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_expired_venue_events() TO service_role;
