-- Global Business Pro promotion settings.
-- This keeps global promos out of individual business plan rows.

CREATE TABLE IF NOT EXISTS public.business_promotion_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  promotion_key text UNIQUE NOT NULL,
  promo_name text NOT NULL,
  enabled boolean NOT NULL DEFAULT false,
  starts_at timestamptz NULL,
  ends_at timestamptz NULL,
  reason text NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by text NULL
);

ALTER TABLE public.business_promotion_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.business_promotion_settings FROM anon, authenticated;
GRANT ALL ON TABLE public.business_promotion_settings TO service_role;

COMMENT ON TABLE public.business_promotion_settings IS
  'Admin-managed global business promotion switches. Individual business plan columns remain the source for manual/paid plan controls.';
COMMENT ON COLUMN public.business_promotion_settings.promotion_key IS
  'Stable identifier for promotion logic. global_business_pro grants temporary Business Pro entitlement to active businesses.';

INSERT INTO public.business_promotion_settings (
  promotion_key,
  promo_name,
  enabled,
  starts_at,
  ends_at,
  reason,
  updated_by
)
VALUES (
  'global_business_pro',
  'Global Business Pro Promotion',
  true,
  now(),
  '2026-11-30 23:59:59+00'::timestamptz,
  'Initial global Business Pro promotion seed.',
  'migration'
)
ON CONFLICT (promotion_key) DO UPDATE
SET
  promo_name = EXCLUDED.promo_name,
  enabled = true,
  starts_at = COALESCE(public.business_promotion_settings.starts_at, EXCLUDED.starts_at),
  ends_at = EXCLUDED.ends_at,
  reason = COALESCE(public.business_promotion_settings.reason, EXCLUDED.reason),
  updated_at = now(),
  updated_by = COALESCE(public.business_promotion_settings.updated_by, EXCLUDED.updated_by);

CREATE OR REPLACE FUNCTION public.active_global_business_pro_promotion()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.business_promotion_settings s
    WHERE s.promotion_key = 'global_business_pro'
      AND s.enabled = true
      AND (s.starts_at IS NULL OR now() >= s.starts_at)
      AND (s.ends_at IS NULL OR now() <= s.ends_at)
  );
$$;

CREATE OR REPLACE FUNCTION public.global_business_pro_promotion_applies_to(b public.businesses)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT
    public.active_global_business_pro_promotion()
    AND lower(btrim(coalesce(b.admin_status, 'active'))) = 'active'
    AND b.admin_archived_at IS NULL;
$$;

CREATE OR REPLACE FUNCTION public.admin_venue_override_is_pro(b public.businesses)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT
    (
      COALESCE(NULLIF(btrim(b.plan_status), ''), 'active') = 'active'
      AND (
        COALESCE(NULLIF(btrim(b.plan_type), ''), 'free') IN ('pro_promo', 'pro_paid', 'manual_pro')
        OR COALESCE(b.unlimited_venues, false)
        OR COALESCE(b.venue_limit, 5) >= 999999
      )
      AND (b.pro_expires_at IS NULL OR b.pro_expires_at > now())
    )
    OR public.global_business_pro_promotion_applies_to(b);
$$;

CREATE OR REPLACE FUNCTION public.business_hosting_is_unlimited(b public.businesses)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT
    (
      COALESCE(NULLIF(btrim(b.plan_status), ''), 'active') = 'active'
      AND (
        COALESCE(NULLIF(btrim(b.plan_type), ''), 'free') IN ('pro_promo', 'pro_paid', 'manual_pro')
        OR COALESCE(b.unlimited_hosting, false)
        OR COALESCE(b.monthly_host_limit, 5) >= 999999
      )
      AND (b.pro_expires_at IS NULL OR b.pro_expires_at > now())
    )
    OR public.global_business_pro_promotion_applies_to(b);
$$;

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
  v_individual_pro_active boolean;
  v_global_promo_applies boolean;
  v_global_promo_ends_at timestamptz;
  v_effective_pro_expires_at timestamptz;
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
  v_individual_pro_active :=
    v_plan_status = 'active'
    AND (
      v_plan_type IN ('pro_promo', 'pro_paid', 'manual_pro')
      OR COALESCE(v_business.unlimited_venues, false)
      OR COALESCE(v_business.venue_limit, 5) >= 999999
    )
    AND (v_business.pro_expires_at IS NULL OR v_business.pro_expires_at > now());

  SELECT s.ends_at
    INTO v_global_promo_ends_at
  FROM public.business_promotion_settings s
  WHERE s.promotion_key = 'global_business_pro'
    AND s.enabled = true
    AND (s.starts_at IS NULL OR now() >= s.starts_at)
    AND (s.ends_at IS NULL OR now() <= s.ends_at)
  LIMIT 1;

  v_global_promo_applies :=
    v_global_promo_ends_at IS NOT NULL
    OR public.global_business_pro_promotion_applies_to(v_business);

  v_global_promo_applies := v_global_promo_applies
    AND public.global_business_pro_promotion_applies_to(v_business);

  v_effective_pro_expires_at := CASE
    WHEN v_individual_pro_active THEN v_business.pro_expires_at
    WHEN v_global_promo_applies THEN v_global_promo_ends_at
    ELSE v_business.pro_expires_at
  END;
  v_is_pro_active := v_individual_pro_active OR v_global_promo_applies;
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
    WHEN v_unlimited_hosting AND v_global_promo_applies AND NOT v_individual_pro_active THEN 999999
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
    v_effective_pro_expires_at AS pro_expires_at,
    v_is_pro_active AS is_pro_active,
    CASE
      WHEN v_effective_pro_expires_at IS NULL THEN NULL
      WHEN v_is_pro_active THEN GREATEST(0, CEIL(EXTRACT(EPOCH FROM (v_effective_pro_expires_at - now())) / 86400.0)::integer)
      ELSE 0
    END AS days_remaining,
    CASE WHEN v_is_pro_active THEN COALESCE(v_business.statistics_enabled, false) OR v_global_promo_applies ELSE false END AS statistics_enabled,
    CASE WHEN v_is_pro_active THEN COALESCE(v_business.sponsored_enabled, false) OR v_global_promo_applies ELSE false END AS sponsored_enabled,
    v_is_pro_active AS unlimited_venues,
    v_unlimited_hosting AS unlimited_hosting,
    CASE
      WHEN v_is_pro_active AND v_global_promo_applies AND NOT v_individual_pro_active THEN 999999
      WHEN v_is_pro_active THEN GREATEST(0, COALESCE(v_business.venue_limit, 999999))
      ELSE COALESCE(v_effective_venue_limit, 5)
    END AS venue_limit,
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

CREATE OR REPLACE FUNCTION public.enforce_global_business_pro_promotion_venue_locks()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_business_id uuid;
  v_count integer := 0;
BEGIN
  FOR v_business_id IN
    SELECT b.id
    FROM public.businesses b
    WHERE lower(btrim(coalesce(b.admin_status, 'active'))) = 'active'
      AND b.admin_archived_at IS NULL
  LOOP
    PERFORM public.enforce_business_plan_venue_locks(v_business_id);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_business_promotion_settings_enforce_locks()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
BEGIN
  IF COALESCE(NEW.promotion_key, OLD.promotion_key) = 'global_business_pro' THEN
    PERFORM public.enforce_global_business_pro_promotion_venue_locks();
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_business_promotion_settings_global_pro_locks ON public.business_promotion_settings;
CREATE TRIGGER trg_business_promotion_settings_global_pro_locks
AFTER INSERT OR UPDATE OF enabled, starts_at, ends_at
ON public.business_promotion_settings
FOR EACH ROW
EXECUTE FUNCTION public.trg_business_promotion_settings_enforce_locks();

REVOKE ALL ON FUNCTION public.active_global_business_pro_promotion() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.global_business_pro_promotion_applies_to(public.businesses) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_venue_override_is_pro(public.businesses) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.business_hosting_is_unlimited(public.businesses) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_entitlements_v2(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_entitlements(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_business_host_game(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_business_create_venue(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enforce_global_business_pro_promotion_venue_locks() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_business_promotion_settings_enforce_locks() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.active_global_business_pro_promotion() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_business_entitlements_v2(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_business_entitlements(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_business_host_game(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_business_create_venue(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_global_business_pro_promotion_venue_locks() TO service_role;

COMMENT ON FUNCTION public.active_global_business_pro_promotion() IS
  'Returns true when the global Business Pro promotion is enabled and inside its optional schedule window.';
COMMENT ON FUNCTION public.global_business_pro_promotion_applies_to(public.businesses) IS
  'Returns true when the global Business Pro promotion grants Pro to an active business account.';
COMMENT ON FUNCTION public.get_business_entitlements_v2(uuid) IS
  'Owner-scoped Business Pro entitlement snapshot with hosted-game cycle fields and global promotion support.';
COMMENT ON FUNCTION public.enforce_global_business_pro_promotion_venue_locks() IS
  'Recalculates plan locks for all active businesses after a global Business Pro promotion change.';

NOTIFY pgrst, 'reload schema';
