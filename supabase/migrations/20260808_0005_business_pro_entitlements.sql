-- Server-controlled Business Pro entitlements.
-- Canonical launch-promo expiration: 2026-11-30 23:59:59 America/Denver.

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS plan_type text DEFAULT 'free',
  ADD COLUMN IF NOT EXISTS plan_status text DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS pro_expires_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS venue_limit integer DEFAULT 5,
  ADD COLUMN IF NOT EXISTS monthly_host_limit integer DEFAULT 5,
  ADD COLUMN IF NOT EXISTS statistics_enabled boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS sponsored_enabled boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS unlimited_venues boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS unlimited_hosting boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS entitlement_updated_at timestamptz DEFAULT now();

UPDATE public.businesses
SET
  plan_type = COALESCE(NULLIF(btrim(plan_type), ''), 'free'),
  plan_status = COALESCE(NULLIF(btrim(plan_status), ''), 'active'),
  venue_limit = COALESCE(venue_limit, 5),
  monthly_host_limit = COALESCE(monthly_host_limit, 5),
  statistics_enabled = COALESCE(statistics_enabled, false),
  sponsored_enabled = COALESCE(sponsored_enabled, false),
  unlimited_venues = COALESCE(unlimited_venues, false),
  unlimited_hosting = COALESCE(unlimited_hosting, false),
  entitlement_updated_at = COALESCE(entitlement_updated_at, now());

UPDATE public.businesses
SET plan_type = 'free'
WHERE plan_type NOT IN ('free', 'pro_promo', 'pro_paid', 'manual_pro');

UPDATE public.businesses
SET plan_status = 'active'
WHERE plan_status NOT IN ('active', 'paused', 'expired', 'cancelled');

ALTER TABLE public.businesses
  ALTER COLUMN plan_type SET DEFAULT 'free',
  ALTER COLUMN plan_type SET NOT NULL,
  ALTER COLUMN plan_status SET DEFAULT 'active',
  ALTER COLUMN plan_status SET NOT NULL,
  ALTER COLUMN venue_limit SET DEFAULT 5,
  ALTER COLUMN venue_limit SET NOT NULL,
  ALTER COLUMN monthly_host_limit SET DEFAULT 5,
  ALTER COLUMN monthly_host_limit SET NOT NULL,
  ALTER COLUMN statistics_enabled SET DEFAULT false,
  ALTER COLUMN statistics_enabled SET NOT NULL,
  ALTER COLUMN sponsored_enabled SET DEFAULT false,
  ALTER COLUMN sponsored_enabled SET NOT NULL,
  ALTER COLUMN unlimited_venues SET DEFAULT false,
  ALTER COLUMN unlimited_venues SET NOT NULL,
  ALTER COLUMN unlimited_hosting SET DEFAULT false,
  ALTER COLUMN unlimited_hosting SET NOT NULL,
  ALTER COLUMN entitlement_updated_at SET DEFAULT now(),
  ALTER COLUMN entitlement_updated_at SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'businesses_plan_type_check'
  ) THEN
    ALTER TABLE public.businesses
      ADD CONSTRAINT businesses_plan_type_check
      CHECK (plan_type IN ('free', 'pro_promo', 'pro_paid', 'manual_pro'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'businesses_plan_status_check'
  ) THEN
    ALTER TABLE public.businesses
      ADD CONSTRAINT businesses_plan_status_check
      CHECK (plan_status IN ('active', 'paused', 'expired', 'cancelled'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'businesses_entitlement_limits_check'
  ) THEN
    ALTER TABLE public.businesses
      ADD CONSTRAINT businesses_entitlement_limits_check
      CHECK (venue_limit >= 0 AND monthly_host_limit >= 0);
  END IF;
END $$;

UPDATE public.businesses
SET
  plan_type = 'pro_promo',
  plan_status = 'active',
  pro_expires_at = make_timestamptz(2026, 11, 30, 23, 59, 59, 'America/Denver'),
  statistics_enabled = true,
  sponsored_enabled = true,
  unlimited_venues = true,
  unlimited_hosting = true,
  venue_limit = 999999,
  monthly_host_limit = 999999,
  entitlement_updated_at = now()
WHERE lower(btrim(coalesce(admin_status, ''))) = 'active';

CREATE INDEX IF NOT EXISTS idx_businesses_plan_status
  ON public.businesses (plan_type, plan_status, pro_expires_at);

CREATE OR REPLACE FUNCTION public.business_entitlement_caller_can_read(p_business_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.id = p_business_id
      AND (
        b.owner_user_id = auth.uid()
        OR (
          NULLIF(btrim(coalesce(b.owner_email, '')), '') IS NOT NULL
          AND NULLIF(btrim(coalesce(auth.jwt() ->> 'email', '')), '') IS NOT NULL
          AND lower(btrim(b.owner_email)) = lower(btrim(auth.jwt() ->> 'email'))
        )
      )
  );
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
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_business public.businesses%ROWTYPE;
  v_plan_type text;
  v_plan_status text;
  v_is_pro_active boolean;
  v_venues_used integer := 0;
  v_hosted_games_this_month integer := 0;
  v_month_start timestamptz := date_trunc('month', now());
  v_month_end timestamptz := date_trunc('month', now()) + interval '1 month';
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

  v_plan_type := COALESCE(NULLIF(btrim(v_business.plan_type), ''), 'free');
  v_plan_status := COALESCE(NULLIF(btrim(v_business.plan_status), ''), 'active');
  v_is_pro_active :=
    v_plan_status = 'active'
    AND v_plan_type IN ('pro_promo', 'pro_paid', 'manual_pro')
    AND (v_business.pro_expires_at IS NULL OR v_business.pro_expires_at > now());

  SELECT count(*)::integer
    INTO v_venues_used
  FROM public.venues v
  WHERE lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
    AND (
      v.business_id = p_business_id
      OR (
        v_business.owner_email IS NOT NULL
        AND lower(btrim(coalesce(v.owner_email, ''))) = lower(btrim(v_business.owner_email))
      )
    );

  WITH business_venues AS (
    SELECT v.id
    FROM public.venues v
    WHERE v.business_id = p_business_id
      AND lower(btrim(coalesce(v.admin_status, 'active'))) = 'active'
  ),
  event_ids AS (
    SELECT ve.id
    FROM public.venue_events ve
    LEFT JOIN public.venues v ON v.id = ve.venue_id
    WHERE ve.created_at >= v_month_start
      AND ve.created_at < v_month_end
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
      AND bgh.created_at >= v_month_start
      AND bgh.created_at < v_month_end
      AND bgh.original_venue_event_id IS NOT NULL
  )
  SELECT count(DISTINCT id)::integer
    INTO v_hosted_games_this_month
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
    CASE WHEN v_is_pro_active THEN COALESCE(v_business.sponsored_enabled, false) ELSE false END AS sponsored_enabled,
    CASE WHEN v_is_pro_active THEN COALESCE(v_business.unlimited_venues, false) ELSE false END AS unlimited_venues,
    CASE WHEN v_is_pro_active THEN COALESCE(v_business.unlimited_hosting, false) ELSE false END AS unlimited_hosting,
    CASE WHEN v_is_pro_active THEN GREATEST(0, COALESCE(v_business.venue_limit, 5)) ELSE 5 END AS venue_limit,
    CASE WHEN v_is_pro_active THEN GREATEST(0, COALESCE(v_business.monthly_host_limit, 5)) ELSE 5 END AS monthly_host_limit,
    COALESCE(v_venues_used, 0) AS venues_used,
    COALESCE(v_hosted_games_this_month, 0) AS hosted_games_this_month;
END;
$$;

CREATE OR REPLACE FUNCTION public.can_business_create_venue(p_business_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT COALESCE((
    SELECT e.unlimited_venues OR e.venues_used < e.venue_limit
    FROM public.get_business_entitlements(p_business_id) e
    LIMIT 1
  ), false);
$$;

CREATE OR REPLACE FUNCTION public.can_business_host_game(p_business_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT COALESCE((
    SELECT e.unlimited_hosting OR e.hosted_games_this_month < e.monthly_host_limit
    FROM public.get_business_entitlements(p_business_id) e
    LIMIT 1
  ), false);
$$;

CREATE OR REPLACE FUNCTION public.can_business_access_statistics(p_business_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT COALESCE((
    SELECT e.statistics_enabled
    FROM public.get_business_entitlements(p_business_id) e
    LIMIT 1
  ), false);
$$;

REVOKE ALL ON FUNCTION public.business_entitlement_caller_can_read(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_entitlements(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_business_create_venue(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_business_host_game(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_business_access_statistics(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_business_entitlements(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_business_create_venue(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_business_host_game(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_business_access_statistics(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_business_entitlements(uuid) IS
  'Owner-scoped Business Pro entitlement snapshot. Computes active Pro access and effective free fallbacks server-side.';
COMMENT ON FUNCTION public.can_business_create_venue(uuid) IS
  'Owner-scoped server check for whether the business can create/request another venue.';
COMMENT ON FUNCTION public.can_business_host_game(uuid) IS
  'Owner-scoped server check for whether the business can host another game this month.';
COMMENT ON FUNCTION public.can_business_access_statistics(uuid) IS
  'Owner-scoped server check for whether the business can access statistics.';
