-- Cycle-only bonus hosted games for Regular businesses.
-- This does not change the permanent monthly_host_limit or Pro entitlement model.

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS hosted_game_cycle_bonus_games integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS hosted_game_cycle_bonus_cycle_start_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS hosted_game_cycle_bonus_reason text NULL,
  ADD COLUMN IF NOT EXISTS hosted_game_cycle_bonus_updated_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS hosted_game_cycle_bonus_updated_by text NULL;

DO $$
BEGIN
  IF to_regprocedure('public.get_business_entitlements_v2(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing required function public.get_business_entitlements_v2(uuid). Apply hosted-game cycle migration first.';
  END IF;

  IF to_regprocedure('public.business_hosted_game_cycle_window(timestamptz,timestamptz,timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'Missing required function public.business_hosted_game_cycle_window(timestamptz,timestamptz,timestamptz). Apply hosted-game cycle migration first.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'businesses'
      AND column_name IN (
        'hosted_game_cycle_anchor_at',
        'hosted_game_cycle_override_at',
        'hosted_game_cycle_bonus_games',
        'hosted_game_cycle_bonus_cycle_start_at'
      )
    GROUP BY table_schema, table_name
    HAVING count(*) = 4
  ) THEN
    RAISE EXCEPTION 'Missing required businesses hosted-game cycle/bonus columns.';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'businesses_hosted_game_cycle_bonus_games_check'
  ) THEN
    ALTER TABLE public.businesses
      ADD CONSTRAINT businesses_hosted_game_cycle_bonus_games_check
      CHECK (hosted_game_cycle_bonus_games >= 0);
  END IF;
END $$;

COMMENT ON COLUMN public.businesses.hosted_game_cycle_bonus_games IS
  'Admin-only extra hosted games for one hosted-game cycle. Applies only when hosted_game_cycle_bonus_cycle_start_at matches the current cycle start.';
COMMENT ON COLUMN public.businesses.hosted_game_cycle_bonus_cycle_start_at IS
  'Cycle start this bonus applies to. Old bonuses automatically stop applying when the hosted-game cycle advances.';
COMMENT ON COLUMN public.businesses.hosted_game_cycle_bonus_reason IS
  'Optional admin note explaining the current cycle-only hosted-game bonus.';
COMMENT ON COLUMN public.businesses.hosted_game_cycle_bonus_updated_at IS
  'Timestamp of the latest admin hosted-game cycle bonus update.';
COMMENT ON COLUMN public.businesses.hosted_game_cycle_bonus_updated_by IS
  'Admin email for the latest hosted-game cycle bonus update.';

DROP FUNCTION IF EXISTS public.can_business_create_venue(uuid);
DROP FUNCTION IF EXISTS public.can_business_host_game(uuid);
DROP FUNCTION IF EXISTS public.get_business_entitlements(uuid);
DROP FUNCTION IF EXISTS public.get_business_entitlements_v2(uuid);

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
  hosted_games_used_this_cycle integer,
  hosted_game_cycle_bonus_games integer,
  effective_monthly_host_limit integer
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
  v_base_monthly_host_limit integer;
  v_active_cycle_bonus integer := 0;
  v_effective_monthly_host_limit integer;
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

  v_base_monthly_host_limit := CASE
    WHEN v_unlimited_hosting THEN GREATEST(0, COALESCE(v_business.monthly_host_limit, 999999))
    ELSE GREATEST(0, COALESCE(v_business.monthly_host_limit, 5))
  END;

  IF NOT v_unlimited_hosting
     AND v_business.hosted_game_cycle_bonus_cycle_start_at IS NOT NULL
     AND v_business.hosted_game_cycle_bonus_cycle_start_at = v_cycle_start_at THEN
    v_active_cycle_bonus := GREATEST(0, COALESCE(v_business.hosted_game_cycle_bonus_games, 0));
  END IF;

  v_effective_monthly_host_limit := CASE
    WHEN v_unlimited_hosting THEN v_base_monthly_host_limit
    ELSE v_base_monthly_host_limit + v_active_cycle_bonus
  END;

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
    v_base_monthly_host_limit AS monthly_host_limit,
    COALESCE(v_venues_used, 0) AS venues_used,
    COALESCE(v_hosted_games_used, 0) AS hosted_games_this_month,
    v_business.hosted_game_cycle_anchor_at,
    v_business.hosted_game_cycle_override_at,
    v_cycle_start_at AS hosted_game_cycle_start_at,
    v_next_reset_at AS next_reset_at,
    COALESCE(v_hosted_games_used, 0) AS hosted_games_used_this_cycle,
    v_active_cycle_bonus AS hosted_game_cycle_bonus_games,
    v_effective_monthly_host_limit AS effective_monthly_host_limit;
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
    SELECT e.unlimited_hosting OR e.hosted_games_used_this_cycle < e.effective_monthly_host_limit
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

REVOKE ALL ON FUNCTION public.get_business_entitlements_v2(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_entitlements(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_business_host_game(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_business_create_venue(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_business_entitlements_v2(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_business_entitlements(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_business_host_game(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_business_create_venue(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_business_entitlements_v2(uuid) IS
  'Owner-scoped Business Pro entitlement snapshot with hosted-game cycle and active cycle-only bonus fields.';
COMMENT ON FUNCTION public.get_business_entitlements(uuid) IS
  'Owner-scoped Business Pro entitlement snapshot. Backward-compatible return shape with cycle-aware hosted_games_this_month.';
COMMENT ON FUNCTION public.can_business_host_game(uuid) IS
  'Returns whether a business can create another hosted game using cycle-aware base limit plus active cycle-only bonus.';

NOTIFY pgrst, 'reload schema';
