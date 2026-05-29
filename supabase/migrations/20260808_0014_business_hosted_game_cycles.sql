-- Business hosted-game cycle tracking.
-- Backward-compatible: get_business_entitlements(uuid) keeps its existing return shape.

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS hosted_game_cycle_anchor_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS hosted_game_cycle_override_at timestamptz NULL;

DO $$
BEGIN
  IF to_regprocedure('public.business_entitlement_caller_can_read(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing required function public.business_entitlement_caller_can_read(uuid). Apply business entitlement migrations first.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_type t ON t.oid = p.proargtypes[0]
    JOIN pg_namespace tn ON tn.oid = t.typnamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'admin_venue_override_is_pro'
      AND p.pronargs = 1
      AND tn.nspname = 'public'
      AND t.typname = 'businesses'
  ) THEN
    RAISE EXCEPTION 'Missing required function public.admin_venue_override_is_pro(public.businesses). Apply admin venue activation override migration first.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'business_game_history'
      AND column_name IN ('business_id', 'created_at', 'original_venue_event_id')
    GROUP BY table_schema, table_name
    HAVING count(*) = 3
  ) THEN
    RAISE EXCEPTION 'Missing required business_game_history columns: business_id, created_at, original_venue_event_id.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'venue_events'
      AND column_name IN ('admin_status', 'venue_id', 'owner_email', 'created_at')
    GROUP BY table_schema, table_name
    HAVING count(*) = 4
  ) THEN
    RAISE EXCEPTION 'Missing required venue_events columns: admin_status, venue_id, owner_email, created_at.';
  END IF;
END $$;

WITH earliest_venue_events AS (
  SELECT
    coalesce(v.business_id, b.id) AS business_id,
    min(ve.created_at) AS first_created_at
  FROM public.venue_events ve
  LEFT JOIN public.venues v ON v.id = ve.venue_id
  LEFT JOIN public.businesses b
    ON b.owner_email IS NOT NULL
   AND lower(btrim(coalesce(ve.owner_email, ''))) = lower(btrim(b.owner_email))
  WHERE ve.created_at IS NOT NULL
    AND coalesce(v.business_id, b.id) IS NOT NULL
  GROUP BY coalesce(v.business_id, b.id)
),
earliest_history AS (
  SELECT
    business_id,
    min(created_at) AS first_created_at
  FROM public.business_game_history
  WHERE business_id IS NOT NULL
    AND created_at IS NOT NULL
  GROUP BY business_id
)
UPDATE public.businesses b
SET hosted_game_cycle_anchor_at = coalesce(
  b.hosted_game_cycle_anchor_at,
  eve.first_created_at,
  eh.first_created_at,
  b.created_at,
  now()
)
FROM earliest_venue_events eve
FULL OUTER JOIN earliest_history eh ON eh.business_id = eve.business_id
WHERE b.id = coalesce(eve.business_id, eh.business_id)
  AND b.hosted_game_cycle_anchor_at IS NULL;

UPDATE public.businesses
SET hosted_game_cycle_anchor_at = coalesce(hosted_game_cycle_anchor_at, created_at, now())
WHERE hosted_game_cycle_anchor_at IS NULL;

ALTER TABLE public.businesses
  ALTER COLUMN hosted_game_cycle_anchor_at SET DEFAULT now(),
  ALTER COLUMN hosted_game_cycle_anchor_at SET NOT NULL;

COMMENT ON COLUMN public.businesses.hosted_game_cycle_anchor_at IS
  'Canonical monthly hosted-game cycle anchor for Regular business hosted-game usage.';
COMMENT ON COLUMN public.businesses.hosted_game_cycle_override_at IS
  'Admin-set current-cycle anchor override. NULL means use hosted_game_cycle_anchor_at monthly cadence.';

CREATE OR REPLACE FUNCTION public.business_hosting_is_unlimited(b public.businesses)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT
    COALESCE(NULLIF(btrim(b.plan_status), ''), 'active') = 'active'
    AND (
      COALESCE(NULLIF(btrim(b.plan_type), ''), 'free') IN ('pro_promo', 'pro_paid', 'manual_pro')
      OR COALESCE(b.unlimited_hosting, false)
      OR COALESCE(b.monthly_host_limit, 5) >= 999999
    )
    AND (b.pro_expires_at IS NULL OR b.pro_expires_at > now());
$$;

CREATE OR REPLACE FUNCTION public.business_hosted_game_cycle_window(
  anchor_at timestamptz,
  override_at timestamptz,
  now_at timestamptz DEFAULT now()
)
RETURNS TABLE (
  cycle_start_at timestamptz,
  next_reset_at timestamptz
)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_anchor timestamptz := coalesce(override_at, anchor_at, now_at);
  v_start timestamptz;
  v_next timestamptz;
BEGIN
  IF v_anchor IS NULL THEN
    v_anchor := now_at;
  END IF;

  IF v_anchor > now_at THEN
    RETURN QUERY SELECT v_anchor, v_anchor + interval '1 month';
    RETURN;
  END IF;

  v_start := v_anchor;
  v_next := v_start + interval '1 month';

  WHILE v_next <= now_at LOOP
    v_start := v_next;
    v_next := v_start + interval '1 month';
  END LOOP;

  RETURN QUERY SELECT v_start, v_next;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_business_hosted_game_cycle_on_entitlement_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_unlimited boolean;
  v_new_unlimited boolean;
BEGIN
  v_old_unlimited := public.business_hosting_is_unlimited(OLD);
  v_new_unlimited := public.business_hosting_is_unlimited(NEW);

  IF v_old_unlimited AND NOT v_new_unlimited THEN
    NEW.hosted_game_cycle_anchor_at := now();
    NEW.hosted_game_cycle_override_at := COALESCE(NEW.hosted_game_cycle_override_at, OLD.hosted_game_cycle_override_at);
  END IF;

  IF NEW.hosted_game_cycle_anchor_at IS NULL THEN
    NEW.hosted_game_cycle_anchor_at := coalesce(NEW.created_at, now());
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_businesses_hosted_game_cycle_entitlement_change ON public.businesses;
CREATE TRIGGER trg_businesses_hosted_game_cycle_entitlement_change
BEFORE UPDATE OF plan_type, plan_status, pro_expires_at, unlimited_hosting, monthly_host_limit
ON public.businesses
FOR EACH ROW
EXECUTE FUNCTION public.trg_business_hosted_game_cycle_on_entitlement_change();

CREATE OR REPLACE FUNCTION public.get_business_entitlements_v2(p_business_id uuid)
RETURNS TABLE (
  business_id uuid,
  plan_type text,
  plan_status text,
  pro_expires_at timestamptz,
  is_pro_active boolean,
  days_remaining integer,
  statistics_enabled boolean,
  sponsored_enabled boolean,
  unlimited_venues boolean,
  unlimited_hosting boolean,
  venue_limit integer,
  monthly_host_limit integer,
  venues_used integer,
  hosted_games_this_month integer,
  hosted_game_cycle_anchor_at timestamptz,
  hosted_game_cycle_override_at timestamptz,
  hosted_game_cycle_start_at timestamptz,
  next_reset_at timestamptz,
  hosted_games_used_this_cycle integer
)
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_plan_type text;
  v_plan_status text;
  v_is_pro_active boolean;
  v_unlimited_hosting boolean;
  v_venues_used integer := 0;
  v_hosted_games_used integer := 0;
  v_cycle_start_at timestamptz;
  v_next_reset_at timestamptz;
  v_effective_venue_limit integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = '28000';
  END IF;

  SELECT *
    INTO v_business
  FROM public.businesses
  WHERE id = p_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found: %', p_business_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT public.business_entitlement_caller_can_read(p_business_id) THEN
    RAISE EXCEPTION 'Not authorized to read business entitlements.' USING ERRCODE = '42501';
  END IF;

  PERFORM public.enforce_business_plan_venue_locks(p_business_id);

  v_plan_type := COALESCE(NULLIF(btrim(v_business.plan_type), ''), 'free');
  v_plan_status := COALESCE(NULLIF(btrim(v_business.plan_status), ''), 'active');
  v_is_pro_active := public.admin_venue_override_is_pro(v_business);
  v_unlimited_hosting := public.business_hosting_is_unlimited(v_business);
  v_effective_venue_limit := public.admin_venue_override_effective_limit(
    v_is_pro_active,
    v_business.venue_limit,
    v_business.admin_active_venue_limit_override
  );

  SELECT w.cycle_start_at, w.next_reset_at
    INTO v_cycle_start_at, v_next_reset_at
  FROM public.business_hosted_game_cycle_window(
    v_business.hosted_game_cycle_anchor_at,
    v_business.hosted_game_cycle_override_at,
    now()
  ) w;

  SELECT count(*)::integer
    INTO v_venues_used
  FROM public.venues v
  WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
    AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active';

  WITH business_venues AS (
    SELECT v.id
    FROM public.venues v
    WHERE v.id IN (SELECT venue_id FROM public.admin_business_managed_venue_ids(p_business_id))
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
  ),
  event_ids AS (
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
  FROM event_ids
  WHERE id IS NOT NULL;

  RETURN QUERY
  SELECT
    v_business.id AS business_id,
    v_plan_type AS plan_type,
    v_plan_status AS plan_status,
    v_business.pro_expires_at AS pro_expires_at,
    v_is_pro_active AS is_pro_active,
    CASE
      WHEN v_business.pro_expires_at IS NULL THEN NULL
      WHEN v_is_pro_active THEN GREATEST(0, CEIL(EXTRACT(EPOCH FROM (v_business.pro_expires_at - now())) / 86400.0)::integer)
      ELSE 0
    END AS days_remaining,
    CASE WHEN v_is_pro_active THEN COALESCE(v_business.statistics_enabled, false) ELSE false END AS statistics_enabled,
    COALESCE(v_business.sponsored_enabled, true) AS sponsored_enabled,
    v_is_pro_active AS unlimited_venues,
    CASE WHEN v_unlimited_hosting THEN COALESCE(v_business.unlimited_hosting, true) ELSE false END AS unlimited_hosting,
    CASE WHEN v_is_pro_active THEN GREATEST(0, COALESCE(v_business.venue_limit, 999999)) ELSE COALESCE(v_effective_venue_limit, 5) END AS venue_limit,
    CASE WHEN v_unlimited_hosting THEN GREATEST(0, COALESCE(v_business.monthly_host_limit, 999999)) ELSE GREATEST(0, COALESCE(v_business.monthly_host_limit, 5)) END AS monthly_host_limit,
    COALESCE(v_venues_used, 0) AS venues_used,
    COALESCE(v_hosted_games_used, 0) AS hosted_games_this_month,
    v_business.hosted_game_cycle_anchor_at,
    v_business.hosted_game_cycle_override_at,
    v_cycle_start_at AS hosted_game_cycle_start_at,
    v_next_reset_at AS next_reset_at,
    COALESCE(v_hosted_games_used, 0) AS hosted_games_used_this_cycle;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_business_entitlements(p_business_id uuid)
RETURNS TABLE (
  business_id uuid,
  plan_type text,
  plan_status text,
  pro_expires_at timestamptz,
  is_pro_active boolean,
  days_remaining integer,
  statistics_enabled boolean,
  sponsored_enabled boolean,
  unlimited_venues boolean,
  unlimited_hosting boolean,
  venue_limit integer,
  monthly_host_limit integer,
  venues_used integer,
  hosted_games_this_month integer
)
LANGUAGE sql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
  SELECT
    e.business_id,
    e.plan_type,
    e.plan_status,
    e.pro_expires_at,
    e.is_pro_active,
    e.days_remaining,
    e.statistics_enabled,
    e.sponsored_enabled,
    e.unlimited_venues,
    e.unlimited_hosting,
    e.venue_limit,
    e.monthly_host_limit,
    e.venues_used,
    e.hosted_games_this_month
  FROM public.get_business_entitlements_v2(p_business_id) e;
$$;

CREATE OR REPLACE FUNCTION public.can_business_host_game(p_business_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
  SELECT COALESCE((
    SELECT e.unlimited_hosting OR e.hosted_games_used_this_cycle < e.monthly_host_limit
    FROM public.get_business_entitlements_v2(p_business_id) e
    LIMIT 1
  ), false);
$$;

CREATE OR REPLACE FUNCTION public.can_business_create_venue(p_business_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
  SELECT COALESCE((
    SELECT e.unlimited_venues OR e.venues_used < e.venue_limit
    FROM public.get_business_entitlements(p_business_id) e
    LIMIT 1
  ), false);
$$;

REVOKE ALL ON FUNCTION public.business_hosting_is_unlimited(public.businesses) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.business_hosted_game_cycle_window(timestamptz, timestamptz, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_business_hosted_game_cycle_on_entitlement_change() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_entitlements_v2(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_entitlements(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_business_host_game(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_business_create_venue(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_business_entitlements_v2(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_business_entitlements(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_business_host_game(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_business_create_venue(uuid) TO authenticated;

COMMENT ON FUNCTION public.business_hosted_game_cycle_window(timestamptz, timestamptz, timestamptz) IS
  'Returns the current hosted-game usage cycle window from a canonical anchor and optional admin override anchor.';
COMMENT ON FUNCTION public.get_business_entitlements_v2(uuid) IS
  'Owner-scoped Business Pro entitlement snapshot with hosted-game cycle fields.';
COMMENT ON FUNCTION public.get_business_entitlements(uuid) IS
  'Owner-scoped Business Pro entitlement snapshot. Backward-compatible return shape with cycle-aware hosted_games_this_month.';

NOTIFY pgrst, 'reload schema';
