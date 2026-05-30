-- Promotion redesign: global promo, Regular-business promo grants, and existing-Pro extensions.

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS admin_pro_promo_starts_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS admin_pro_promo_ends_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS admin_pro_promo_reason text NULL,
  ADD COLUMN IF NOT EXISTS admin_pro_promo_batch_id uuid NULL,
  ADD COLUMN IF NOT EXISTS admin_pro_promo_updated_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS admin_pro_promo_updated_by text NULL;

COMMENT ON COLUMN public.businesses.admin_pro_promo_starts_at IS
  'Admin bulk-grant Business Pro promo start for otherwise Regular businesses.';
COMMENT ON COLUMN public.businesses.admin_pro_promo_ends_at IS
  'Admin bulk-grant Business Pro promo end for otherwise Regular businesses.';
COMMENT ON COLUMN public.businesses.admin_pro_promo_batch_id IS
  'Business promotion batch that most recently set the admin Pro promo grant.';

CREATE TABLE IF NOT EXISTS public.business_promotion_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action_type text NOT NULL,
  promotion_key text NULL,
  admin_email text NOT NULL,
  reason text NULL,
  requested_months integer NULL,
  requested_ends_at timestamptz NULL,
  affected_count integer NOT NULL DEFAULT 0,
  skipped_count integer NOT NULL DEFAULT 0,
  preview_data jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'applied',
  rollback_reason text NULL,
  rolled_back_at timestamptz NULL,
  rolled_back_by text NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.business_promotion_batch_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.business_promotion_batches(id) ON DELETE CASCADE,
  business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  before_data jsonb NOT NULL,
  after_data jsonb NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (batch_id, business_id)
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'business_promotion_batches_action_type_check'
  ) THEN
    ALTER TABLE public.business_promotion_batches
      ADD CONSTRAINT business_promotion_batches_action_type_check
      CHECK (action_type IN (
        'regular_business_promo_grant',
        'existing_pro_business_extension',
        'rollback'
      ));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'business_promotion_batches_status_check'
  ) THEN
    ALTER TABLE public.business_promotion_batches
      ADD CONSTRAINT business_promotion_batches_status_check
      CHECK (status IN ('applied', 'rolled_back'));
  END IF;
END $$;

ALTER TABLE public.business_promotion_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_promotion_batch_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.business_promotion_batches FROM anon, authenticated;
REVOKE ALL ON TABLE public.business_promotion_batch_items FROM anon, authenticated;
GRANT ALL ON TABLE public.business_promotion_batches TO service_role;
GRANT ALL ON TABLE public.business_promotion_batch_items TO service_role;

CREATE INDEX IF NOT EXISTS idx_business_promotion_batches_created_at
  ON public.business_promotion_batches (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_business_promotion_batch_items_batch_id
  ON public.business_promotion_batch_items (batch_id);
CREATE INDEX IF NOT EXISTS idx_business_promotion_batch_items_business_id
  ON public.business_promotion_batch_items (business_id);

CREATE OR REPLACE FUNCTION public.business_promotion_business_is_active(b public.businesses)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT lower(btrim(coalesce(b.admin_status, 'active'))) = 'active'
    AND b.admin_archived_at IS NULL;
$$;

CREATE OR REPLACE FUNCTION public.business_individual_pro_is_active(b public.businesses)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT
    COALESCE(NULLIF(btrim(b.plan_status), ''), 'active') = 'active'
    AND (
      COALESCE(NULLIF(btrim(b.plan_type), ''), 'free') IN ('pro_promo', 'pro_paid', 'manual_pro')
      OR COALESCE(b.unlimited_venues, false)
      OR COALESCE(b.venue_limit, 5) >= 999999
    )
    AND (b.pro_expires_at IS NULL OR b.pro_expires_at > now());
$$;

CREATE OR REPLACE FUNCTION public.business_admin_pro_promo_is_active(b public.businesses)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT public.business_promotion_business_is_active(b)
    AND b.admin_pro_promo_ends_at IS NOT NULL
    AND (b.admin_pro_promo_starts_at IS NULL OR now() >= b.admin_pro_promo_starts_at)
    AND now() <= b.admin_pro_promo_ends_at;
$$;

CREATE OR REPLACE FUNCTION public.business_regular_promo_grant_target(b public.businesses)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT public.business_promotion_business_is_active(b)
    AND NOT public.business_individual_pro_is_active(b)
    AND NOT public.business_admin_pro_promo_is_active(b)
    AND COALESCE(NULLIF(btrim(b.plan_type), ''), 'free') NOT IN ('manual_pro', 'pro_paid');
$$;

CREATE OR REPLACE FUNCTION public.business_existing_pro_extension_target(b public.businesses, requested_ends_at timestamptz DEFAULT NULL)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT public.business_promotion_business_is_active(b)
    AND public.business_individual_pro_is_active(b)
    AND b.pro_expires_at IS NOT NULL
    AND (requested_ends_at IS NULL OR b.pro_expires_at < requested_ends_at);
$$;

CREATE OR REPLACE FUNCTION public.admin_venue_override_is_pro(b public.businesses)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT public.business_individual_pro_is_active(b)
    OR public.business_admin_pro_promo_is_active(b)
    OR public.global_business_pro_promotion_applies_to(b);
$$;

CREATE OR REPLACE FUNCTION public.business_hosting_is_unlimited(b public.businesses)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT public.business_individual_pro_is_active(b)
    OR public.business_admin_pro_promo_is_active(b)
    OR public.global_business_pro_promotion_applies_to(b);
$$;

CREATE OR REPLACE FUNCTION public.admin_business_promotion_preview()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  WITH classified AS (
    SELECT
      b.id,
      public.business_promotion_business_is_active(b) AS is_active,
      public.business_individual_pro_is_active(b) AS individual_pro_active,
      public.business_admin_pro_promo_is_active(b) AS admin_promo_active,
      public.global_business_pro_promotion_applies_to(b) AS global_promo_applies,
      public.business_regular_promo_grant_target(b) AS regular_grant_target,
      public.business_existing_pro_extension_target(b, NULL) AS existing_pro_extension_target,
      COALESCE(NULLIF(btrim(b.plan_type), ''), 'free') IN ('manual_pro', 'pro_paid') AS paid_or_manual
    FROM public.businesses b
  )
  SELECT jsonb_build_object(
    'activeBusinessCount', count(*) FILTER (WHERE is_active),
    'regularGrantTargetCount', count(*) FILTER (WHERE regular_grant_target),
    'existingProExtensionTargetCount', count(*) FILTER (WHERE existing_pro_extension_target),
    'paidManualProCount', count(*) FILTER (WHERE is_active AND paid_or_manual AND individual_pro_active),
    'individualPromoProCount', count(*) FILTER (WHERE is_active AND individual_pro_active AND NOT paid_or_manual),
    'activeAdminPromoGrantCount', count(*) FILTER (WHERE is_active AND admin_promo_active),
    'globalOnlyProCount', count(*) FILTER (WHERE is_active AND global_promo_applies AND NOT individual_pro_active AND NOT admin_promo_active),
    'archivedOrInactiveCount', count(*) FILTER (WHERE NOT is_active)
  )
  FROM classified;
$$;

CREATE OR REPLACE FUNCTION public.admin_apply_regular_business_promo_grant(
  p_admin_email text,
  p_ends_at timestamptz,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_batch_id uuid;
  v_affected integer := 0;
  v_business_id uuid;
  v_preview jsonb;
BEGIN
  IF p_ends_at IS NULL OR p_ends_at <= now() THEN
    RAISE EXCEPTION 'invalid_promotion_end_date' USING ERRCODE = '22023';
  END IF;

  v_preview := public.admin_business_promotion_preview();

  INSERT INTO public.business_promotion_batches (
    action_type,
    promotion_key,
    admin_email,
    reason,
    requested_ends_at,
    preview_data
  )
  VALUES (
    'regular_business_promo_grant',
    'regular_business_promo_grant',
    COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown'),
    NULLIF(btrim(COALESCE(p_reason, '')), ''),
    p_ends_at,
    v_preview
  )
  RETURNING id INTO v_batch_id;

  INSERT INTO public.business_promotion_batch_items (batch_id, business_id, before_data)
  SELECT
    v_batch_id,
    b.id,
    jsonb_build_object(
      'admin_pro_promo_starts_at', b.admin_pro_promo_starts_at,
      'admin_pro_promo_ends_at', b.admin_pro_promo_ends_at,
      'admin_pro_promo_reason', b.admin_pro_promo_reason,
      'admin_pro_promo_batch_id', b.admin_pro_promo_batch_id,
      'admin_pro_promo_updated_at', b.admin_pro_promo_updated_at,
      'admin_pro_promo_updated_by', b.admin_pro_promo_updated_by,
      'entitlement_updated_at', b.entitlement_updated_at
    )
  FROM public.businesses b
  WHERE public.business_regular_promo_grant_target(b);

  UPDATE public.businesses b
  SET
    admin_pro_promo_starts_at = now(),
    admin_pro_promo_ends_at = p_ends_at,
    admin_pro_promo_reason = NULLIF(btrim(COALESCE(p_reason, '')), ''),
    admin_pro_promo_batch_id = v_batch_id,
    admin_pro_promo_updated_at = now(),
    admin_pro_promo_updated_by = COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown'),
    entitlement_updated_at = now()
  WHERE EXISTS (
    SELECT 1
    FROM public.business_promotion_batch_items i
    WHERE i.batch_id = v_batch_id
      AND i.business_id = b.id
  );

  UPDATE public.business_promotion_batch_items i
  SET after_data = jsonb_build_object(
    'admin_pro_promo_starts_at', b.admin_pro_promo_starts_at,
    'admin_pro_promo_ends_at', b.admin_pro_promo_ends_at,
    'admin_pro_promo_reason', b.admin_pro_promo_reason,
    'admin_pro_promo_batch_id', b.admin_pro_promo_batch_id,
    'admin_pro_promo_updated_at', b.admin_pro_promo_updated_at,
    'admin_pro_promo_updated_by', b.admin_pro_promo_updated_by,
    'entitlement_updated_at', b.entitlement_updated_at
  )
  FROM public.businesses b
  WHERE i.batch_id = v_batch_id
    AND b.id = i.business_id;

  SELECT count(*)::integer
    INTO v_affected
  FROM public.business_promotion_batch_items
  WHERE batch_id = v_batch_id;

  UPDATE public.business_promotion_batches
  SET affected_count = v_affected,
      skipped_count = GREATEST(0, COALESCE((v_preview ->> 'activeBusinessCount')::integer, 0) - v_affected)
  WHERE id = v_batch_id;

  FOR v_business_id IN
    SELECT business_id
    FROM public.business_promotion_batch_items
    WHERE batch_id = v_batch_id
  LOOP
    PERFORM public.enforce_business_plan_venue_locks(v_business_id);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'batchId', v_batch_id, 'affectedCount', v_affected);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_apply_existing_pro_business_extension(
  p_admin_email text,
  p_extension_months integer,
  p_custom_ends_at timestamptz,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_batch_id uuid;
  v_affected integer := 0;
  v_business_id uuid;
  v_preview jsonb;
BEGIN
  IF p_extension_months IS NULL AND p_custom_ends_at IS NULL THEN
    RAISE EXCEPTION 'missing_extension_target' USING ERRCODE = '22023';
  END IF;

  IF p_extension_months IS NOT NULL AND p_extension_months NOT IN (1, 2, 3) THEN
    RAISE EXCEPTION 'invalid_extension_months' USING ERRCODE = '22023';
  END IF;

  IF p_custom_ends_at IS NOT NULL AND p_custom_ends_at <= now() THEN
    RAISE EXCEPTION 'invalid_promotion_end_date' USING ERRCODE = '22023';
  END IF;

  v_preview := public.admin_business_promotion_preview();

  INSERT INTO public.business_promotion_batches (
    action_type,
    promotion_key,
    admin_email,
    reason,
    requested_months,
    requested_ends_at,
    preview_data
  )
  VALUES (
    'existing_pro_business_extension',
    'existing_pro_business_extension',
    COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown'),
    NULLIF(btrim(COALESCE(p_reason, '')), ''),
    p_extension_months,
    p_custom_ends_at,
    v_preview
  )
  RETURNING id INTO v_batch_id;

  INSERT INTO public.business_promotion_batch_items (batch_id, business_id, before_data)
  SELECT
    v_batch_id,
    b.id,
    jsonb_build_object(
      'plan_type', b.plan_type,
      'plan_status', b.plan_status,
      'pro_expires_at', b.pro_expires_at,
      'statistics_enabled', b.statistics_enabled,
      'sponsored_enabled', b.sponsored_enabled,
      'unlimited_venues', b.unlimited_venues,
      'unlimited_hosting', b.unlimited_hosting,
      'venue_limit', b.venue_limit,
      'monthly_host_limit', b.monthly_host_limit,
      'entitlement_updated_at', b.entitlement_updated_at
    )
  FROM public.businesses b
  WHERE public.business_existing_pro_extension_target(b, p_custom_ends_at);

  UPDATE public.businesses b
  SET
    plan_status = 'active',
    pro_expires_at = CASE
      WHEN b.pro_expires_at IS NULL THEN NULL
      WHEN p_extension_months IS NOT NULL THEN b.pro_expires_at + make_interval(months => p_extension_months)
      ELSE GREATEST(b.pro_expires_at, p_custom_ends_at)
    END,
    statistics_enabled = true,
    sponsored_enabled = true,
    unlimited_venues = true,
    unlimited_hosting = true,
    venue_limit = 999999,
    monthly_host_limit = 999999,
    entitlement_updated_at = now()
  WHERE EXISTS (
    SELECT 1
    FROM public.business_promotion_batch_items i
    WHERE i.batch_id = v_batch_id
      AND i.business_id = b.id
  );

  UPDATE public.business_promotion_batch_items i
  SET after_data = jsonb_build_object(
    'plan_type', b.plan_type,
    'plan_status', b.plan_status,
    'pro_expires_at', b.pro_expires_at,
    'statistics_enabled', b.statistics_enabled,
    'sponsored_enabled', b.sponsored_enabled,
    'unlimited_venues', b.unlimited_venues,
    'unlimited_hosting', b.unlimited_hosting,
    'venue_limit', b.venue_limit,
    'monthly_host_limit', b.monthly_host_limit,
    'entitlement_updated_at', b.entitlement_updated_at
  )
  FROM public.businesses b
  WHERE i.batch_id = v_batch_id
    AND b.id = i.business_id;

  SELECT count(*)::integer
    INTO v_affected
  FROM public.business_promotion_batch_items
  WHERE batch_id = v_batch_id;

  UPDATE public.business_promotion_batches
  SET affected_count = v_affected,
      skipped_count = GREATEST(0, COALESCE((v_preview ->> 'existingProExtensionTargetCount')::integer, 0) - v_affected)
  WHERE id = v_batch_id;

  FOR v_business_id IN
    SELECT business_id
    FROM public.business_promotion_batch_items
    WHERE batch_id = v_batch_id
  LOOP
    PERFORM public.enforce_business_plan_venue_locks(v_business_id);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'batchId', v_batch_id, 'affectedCount', v_affected);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_rollback_business_promotion_batch(
  p_batch_id uuid,
  p_admin_email text,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_batch public.business_promotion_batches%ROWTYPE;
  v_restored integer := 0;
  v_business_id uuid;
BEGIN
  SELECT *
    INTO v_batch
  FROM public.business_promotion_batches
  WHERE id = p_batch_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'promotion_batch_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF v_batch.status = 'rolled_back' THEN
    RAISE EXCEPTION 'promotion_batch_already_rolled_back' USING ERRCODE = 'P0001';
  END IF;

  IF v_batch.action_type = 'regular_business_promo_grant' THEN
    UPDATE public.businesses b
    SET
      admin_pro_promo_starts_at = NULLIF(i.before_data ->> 'admin_pro_promo_starts_at', '')::timestamptz,
      admin_pro_promo_ends_at = NULLIF(i.before_data ->> 'admin_pro_promo_ends_at', '')::timestamptz,
      admin_pro_promo_reason = i.before_data ->> 'admin_pro_promo_reason',
      admin_pro_promo_batch_id = NULLIF(i.before_data ->> 'admin_pro_promo_batch_id', '')::uuid,
      admin_pro_promo_updated_at = NULLIF(i.before_data ->> 'admin_pro_promo_updated_at', '')::timestamptz,
      admin_pro_promo_updated_by = i.before_data ->> 'admin_pro_promo_updated_by',
      entitlement_updated_at = COALESCE(NULLIF(i.before_data ->> 'entitlement_updated_at', '')::timestamptz, now())
    FROM public.business_promotion_batch_items i
    WHERE i.batch_id = p_batch_id
      AND i.business_id = b.id;
  ELSIF v_batch.action_type = 'existing_pro_business_extension' THEN
    UPDATE public.businesses b
    SET
      plan_type = COALESCE(NULLIF(i.before_data ->> 'plan_type', ''), 'free'),
      plan_status = COALESCE(NULLIF(i.before_data ->> 'plan_status', ''), 'active'),
      pro_expires_at = NULLIF(i.before_data ->> 'pro_expires_at', '')::timestamptz,
      statistics_enabled = COALESCE((i.before_data ->> 'statistics_enabled')::boolean, false),
      sponsored_enabled = COALESCE((i.before_data ->> 'sponsored_enabled')::boolean, false),
      unlimited_venues = COALESCE((i.before_data ->> 'unlimited_venues')::boolean, false),
      unlimited_hosting = COALESCE((i.before_data ->> 'unlimited_hosting')::boolean, false),
      venue_limit = COALESCE((i.before_data ->> 'venue_limit')::integer, 5),
      monthly_host_limit = COALESCE((i.before_data ->> 'monthly_host_limit')::integer, 5),
      entitlement_updated_at = COALESCE(NULLIF(i.before_data ->> 'entitlement_updated_at', '')::timestamptz, now())
    FROM public.business_promotion_batch_items i
    WHERE i.batch_id = p_batch_id
      AND i.business_id = b.id;
  ELSE
    RAISE EXCEPTION 'promotion_batch_not_rollbackable' USING ERRCODE = 'P0001';
  END IF;

  GET DIAGNOSTICS v_restored = ROW_COUNT;

  UPDATE public.business_promotion_batches
  SET
    status = 'rolled_back',
    rollback_reason = NULLIF(btrim(COALESCE(p_reason, '')), ''),
    rolled_back_at = now(),
    rolled_back_by = COALESCE(NULLIF(btrim(p_admin_email), ''), 'unknown')
  WHERE id = p_batch_id;

  FOR v_business_id IN
    SELECT business_id
    FROM public.business_promotion_batch_items
    WHERE batch_id = p_batch_id
  LOOP
    PERFORM public.enforce_business_plan_venue_locks(v_business_id);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'batchId', p_batch_id, 'restoredCount', v_restored);
END;
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
  v_admin_promo_active boolean;
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
  v_individual_pro_active := public.business_individual_pro_is_active(v_business);
  v_admin_promo_active := public.business_admin_pro_promo_is_active(v_business);

  SELECT s.ends_at
    INTO v_global_promo_ends_at
  FROM public.business_promotion_settings s
  WHERE s.promotion_key = 'global_business_pro'
    AND s.enabled = true
    AND (s.starts_at IS NULL OR now() >= s.starts_at)
    AND (s.ends_at IS NULL OR now() <= s.ends_at)
  LIMIT 1;

  v_global_promo_applies := public.global_business_pro_promotion_applies_to(v_business);
  v_effective_pro_expires_at := CASE
    WHEN v_individual_pro_active THEN v_business.pro_expires_at
    WHEN v_admin_promo_active THEN v_business.admin_pro_promo_ends_at
    WHEN v_global_promo_applies THEN v_global_promo_ends_at
    ELSE v_business.pro_expires_at
  END;
  v_is_pro_active := v_individual_pro_active OR v_admin_promo_active OR v_global_promo_applies;
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
    WHEN v_unlimited_hosting AND NOT v_individual_pro_active THEN 999999
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
    CASE WHEN v_is_pro_active THEN COALESCE(v_business.statistics_enabled, false) OR v_admin_promo_active OR v_global_promo_applies ELSE false END AS statistics_enabled,
    CASE WHEN v_is_pro_active THEN COALESCE(v_business.sponsored_enabled, false) OR v_admin_promo_active OR v_global_promo_applies ELSE false END AS sponsored_enabled,
    v_is_pro_active AS unlimited_venues,
    v_unlimited_hosting AS unlimited_hosting,
    CASE
      WHEN v_is_pro_active AND NOT v_individual_pro_active THEN 999999
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

REVOKE ALL ON FUNCTION public.business_promotion_business_is_active(public.businesses) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.business_individual_pro_is_active(public.businesses) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.business_admin_pro_promo_is_active(public.businesses) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.business_regular_promo_grant_target(public.businesses) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.business_existing_pro_extension_target(public.businesses, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_business_promotion_preview() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_apply_regular_business_promo_grant(text, timestamptz, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_apply_existing_pro_business_extension(text, integer, timestamptz, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_rollback_business_promotion_batch(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_entitlements_v2(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_entitlements(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_business_host_game(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_business_create_venue(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_business_promotion_preview() TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_apply_regular_business_promo_grant(text, timestamptz, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_apply_existing_pro_business_extension(text, integer, timestamptz, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_rollback_business_promotion_batch(uuid, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_business_entitlements_v2(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_business_entitlements(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_business_host_game(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_business_create_venue(uuid) TO authenticated;

COMMENT ON FUNCTION public.admin_business_promotion_preview() IS
  'Admin-only preview counts for global, Regular grant, and existing-Pro extension promotion actions.';
COMMENT ON FUNCTION public.admin_apply_regular_business_promo_grant(text, timestamptz, text) IS
  'Bulk grants individual admin Pro promo fields to active Regular/free businesses only.';
COMMENT ON FUNCTION public.admin_apply_existing_pro_business_extension(text, integer, timestamptz, text) IS
  'Bulk extends dated existing individual Pro businesses without shortening or downgrading anyone.';
COMMENT ON FUNCTION public.admin_rollback_business_promotion_batch(uuid, text, text) IS
  'Restores business fields captured before a Regular grant or existing-Pro extension batch.';

NOTIFY pgrst, 'reload schema';
