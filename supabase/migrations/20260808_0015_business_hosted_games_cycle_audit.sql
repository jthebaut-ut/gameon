-- Read-only audit list for hosted games counted in the current business hosted-game cycle.

DO $$
BEGIN
  IF to_regprocedure('public.business_entitlement_caller_can_read(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing required function public.business_entitlement_caller_can_read(uuid). Apply business entitlement migrations first.';
  END IF;

  IF to_regprocedure('public.business_hosted_game_cycle_window(timestamptz,timestamptz,timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'Missing required function public.business_hosted_game_cycle_window(timestamptz,timestamptz,timestamptz). Apply hosted-game cycle migration first.';
  END IF;

END $$;

DROP FUNCTION IF EXISTS public.get_business_hosted_games_this_cycle(uuid);

CREATE OR REPLACE FUNCTION public.get_business_hosted_games_this_cycle(p_business_id uuid)
RETURNS TABLE (
  business_id uuid,
  cycle_start_at timestamptz,
  cycle_end_at timestamptz,
  next_reset_at timestamptz,
  hosted_games_used_this_cycle integer,
  monthly_host_limit integer,
  is_unlimited_hosting boolean,
  venue_event_id uuid,
  title text,
  sport text,
  scheduled_start_at timestamptz,
  event_date text,
  event_time text,
  status text,
  venue_name text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_cycle_start_at timestamptz;
  v_next_reset_at timestamptz;
  v_hosted_games_used integer := 0;
  v_unlimited_hosting boolean := false;
BEGIN
  SELECT *
    INTO v_business
  FROM public.businesses
  WHERE id = p_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found: %', p_business_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    public.business_entitlement_caller_can_read(p_business_id)
    OR auth.role() = 'service_role'
    OR session_user IN ('postgres', 'service_role', 'supabase_admin')
  ) THEN
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '28000';
    END IF;
    RAISE EXCEPTION 'Not authorized to read business entitlements.' USING ERRCODE = '42501';
  END IF;

  SELECT w.cycle_start_at, w.next_reset_at
    INTO v_cycle_start_at, v_next_reset_at
  FROM public.business_hosted_game_cycle_window(
    v_business.hosted_game_cycle_anchor_at,
    v_business.hosted_game_cycle_override_at,
    now()
  ) w;

  v_unlimited_hosting := public.business_hosting_is_unlimited(v_business);

  WITH business_venues AS (
    SELECT v.id
    FROM public.venues v
    WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
  ),
  counted_ids AS (
    SELECT ve.id
    FROM public.venue_events ve
    LEFT JOIN public.venues v ON v.id = ve.venue_id
    WHERE ve.created_at >= v_cycle_start_at
      AND ve.created_at < v_next_reset_at
      AND lower(btrim(coalesce(ve.admin_status, 'active'))) = 'active'
      AND (
        ve.venue_id IN (SELECT id FROM business_venues)
        OR v.business_id = p_business_id
        OR (
          v_business.owner_email IS NOT NULL
          AND lower(btrim(coalesce(ve.owner_email, ''))) = lower(btrim(v_business.owner_email))
        )
      )
    UNION
    SELECT bgh.original_venue_event_id
    FROM public.business_game_history bgh
    WHERE bgh.business_id = p_business_id
      AND bgh.created_at >= v_cycle_start_at
      AND bgh.created_at < v_next_reset_at
      AND bgh.original_venue_event_id IS NOT NULL
  )
  SELECT count(DISTINCT id)::integer
    INTO v_hosted_games_used
  FROM counted_ids
  WHERE id IS NOT NULL;

  RETURN QUERY
  WITH business_venues AS (
    SELECT v.id
    FROM public.venues v
    WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
  ),
  counted_ids AS (
    SELECT
      ve.id AS counted_venue_event_id,
      0 AS source_priority
    FROM public.venue_events ve
    LEFT JOIN public.venues v ON v.id = ve.venue_id
    WHERE ve.created_at >= v_cycle_start_at
      AND ve.created_at < v_next_reset_at
      AND lower(btrim(coalesce(ve.admin_status, 'active'))) = 'active'
      AND (
        ve.venue_id IN (SELECT id FROM business_venues)
        OR v.business_id = p_business_id
        OR (
          v_business.owner_email IS NOT NULL
          AND lower(btrim(coalesce(ve.owner_email, ''))) = lower(btrim(v_business.owner_email))
        )
      )
    UNION ALL
    SELECT
      bgh.original_venue_event_id AS counted_venue_event_id,
      1 AS source_priority
    FROM public.business_game_history bgh
    WHERE bgh.business_id = p_business_id
      AND bgh.created_at >= v_cycle_start_at
      AND bgh.created_at < v_next_reset_at
      AND bgh.original_venue_event_id IS NOT NULL
  ),
  unique_counted_ids AS (
    SELECT DISTINCT ON (ci.counted_venue_event_id)
      ci.counted_venue_event_id,
      ci.source_priority
    FROM counted_ids ci
    WHERE ci.counted_venue_event_id IS NOT NULL
    ORDER BY ci.counted_venue_event_id, ci.source_priority
  ),
  active_rows AS (
    SELECT
      u.counted_venue_event_id AS venue_event_id,
      nullif(btrim(coalesce(ve.event_title, '')), '') AS title,
      nullif(btrim(coalesce(ve.sport, '')), '') AS sport,
      ve.scheduled_start_at,
      ve.event_date::text AS event_date,
      ve.event_time::text AS event_time,
      CASE
        WHEN ve.scheduled_start_at IS NULL THEN 'Scheduled'
        WHEN ve.scheduled_start_at > now() THEN 'Scheduled'
        WHEN ve.scheduled_start_at + make_interval(hours => coalesce(ve.cleanup_delay_hours, 12)) <= now() THEN 'Completed'
        ELSE 'Live'
      END AS status,
      nullif(btrim(coalesce(v.venue_name, ve.venue_name, '')), '') AS venue_name,
      ve.created_at,
      0 AS source_priority
    FROM unique_counted_ids u
    JOIN public.venue_events ve ON ve.id = u.counted_venue_event_id
    LEFT JOIN public.venues v ON v.id = ve.venue_id
    WHERE u.source_priority = 0
  ),
  history_rows AS (
    SELECT
      u.counted_venue_event_id AS venue_event_id,
      nullif(btrim(coalesce(bgh.event_title, '')), '') AS title,
      nullif(btrim(coalesce(bgh.sport, '')), '') AS sport,
      bgh.scheduled_start_at,
      bgh.event_date::text AS event_date,
      NULL::text AS event_time,
      'Completed'::text AS status,
      nullif(btrim(coalesce(bgh.venue_name, '')), '') AS venue_name,
      bgh.created_at,
      1 AS source_priority
    FROM unique_counted_ids u
    JOIN public.business_game_history bgh ON bgh.original_venue_event_id = u.counted_venue_event_id
    WHERE u.source_priority = 1
  ),
  display_rows AS (
    SELECT * FROM active_rows
    UNION ALL
    SELECT * FROM history_rows
  )
  SELECT
    p_business_id AS business_id,
    v_cycle_start_at AS cycle_start_at,
    v_next_reset_at AS cycle_end_at,
    v_next_reset_at AS next_reset_at,
    COALESCE(v_hosted_games_used, 0)::integer AS hosted_games_used_this_cycle,
    CASE
      WHEN v_unlimited_hosting THEN GREATEST(0, COALESCE(v_business.monthly_host_limit, 999999))
      ELSE GREATEST(0, COALESCE(v_business.monthly_host_limit, 5))
    END AS monthly_host_limit,
    v_unlimited_hosting AS is_unlimited_hosting,
    dr.venue_event_id,
    COALESCE(dr.title, 'Hosted game') AS title,
    dr.sport,
    dr.scheduled_start_at,
    dr.event_date,
    dr.event_time,
    dr.status,
    dr.venue_name,
    dr.created_at
  FROM (SELECT 1) anchor
  LEFT JOIN display_rows dr ON true
  ORDER BY dr.scheduled_start_at DESC NULLS LAST, dr.created_at DESC NULLS LAST, dr.title ASC NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.get_business_hosted_games_this_cycle(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_business_hosted_games_this_cycle(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_business_hosted_games_this_cycle(uuid) TO service_role;

COMMENT ON FUNCTION public.get_business_hosted_games_this_cycle(uuid) IS
  'Owner-scoped read-only audit list of hosted games counted in the current hosted-game cycle.';

NOTIFY pgrst, 'reload schema';
